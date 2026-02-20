"""Identity and mTLS support for Conduit connections.

A :class:`ConduitIdentity` holds the client certificate and private key used for
mutual TLS.  When present, every connection presents the certificate during the
TLS handshake — the server can verify the caller's identity without a separate
application-layer token exchange.

Auto-discovery order
--------------------
:meth:`ConduitIdentity.try_default` walks the following chain and returns the
first identity it finds:

1. ``CONDUIT_MTLS_CERT`` + ``CONDUIT_MTLS_KEY`` (+ optional ``CONDUIT_MTLS_CA``)
   environment variables (PEM strings).
2. ``~/.conduit/identity.pem`` + ``~/.conduit/identity_key.pem``
   (+ optional ``~/.conduit/ca.pem``).
3. ``.conduit/identity.pem`` relative to the current working directory.

If nothing is found, :meth:`try_default` returns ``None`` — the transport falls
back to bearer token / API key auth silently.

Rotation awareness
------------------
Attach a known expiry with :meth:`with_expiry` and call :meth:`needs_rotation`
to check whether the cert is within ``threshold_days`` of expiry.
"""

from __future__ import annotations

import logging
import os
import ssl
import tempfile
from contextlib import contextmanager
from datetime import datetime, timezone
from pathlib import Path
from typing import Generator, Optional

logger = logging.getLogger(__name__)


class ConduitIdentity:
    """A Conduit client identity — the cert + key pair used for mTLS.

    Construct via :meth:`from_pem`, :meth:`from_paths`, :meth:`from_env`, or
    :meth:`try_default`.
    """

    def __init__(
        self,
        cert_pem: str,
        key_pem: str,
        ca_pem: Optional[str] = None,
        expires_at: Optional[datetime] = None,
    ) -> None:
        # Validate PEM labels immediately so errors are raised close to the call site.
        if "-----BEGIN CERTIFICATE-----" not in cert_pem:
            raise ValueError(
                "cert_pem does not appear to contain a PEM certificate "
                '(missing "-----BEGIN CERTIFICATE-----")'
            )
        if not _has_private_key_header(key_pem):
            raise ValueError(
                "key_pem does not appear to contain a PEM private key "
                "(expected PRIVATE KEY, RSA PRIVATE KEY, or EC PRIVATE KEY header)"
            )
        self._cert_pem = cert_pem
        self._key_pem = key_pem
        self._ca_pem = ca_pem
        self._expires_at = expires_at

    # ─── Constructors ─────────────────────────────────────────────────────────

    @classmethod
    def from_pem(
        cls,
        cert_pem: str,
        key_pem: str,
        ca_pem: Optional[str] = None,
    ) -> "ConduitIdentity":
        """Build an identity from PEM strings already in memory.

        Args:
            cert_pem: PEM-encoded X.509 client certificate.
            key_pem: PEM-encoded private key (PKCS#8 or PKCS#1).
            ca_pem: PEM-encoded CA certificate(s) for verifying the *server*
                cert.  When ``None`` the system trust store is used.

        Raises:
            ValueError: if the PEM strings do not look like a certificate or
                private key.
        """
        return cls(cert_pem, key_pem, ca_pem)

    @classmethod
    def from_paths(
        cls,
        cert_path: str | os.PathLike[str],
        key_path: str | os.PathLike[str],
        ca_path: Optional[str | os.PathLike[str]] = None,
    ) -> "ConduitIdentity":
        """Build an identity by reading PEM files from disk.

        Args:
            cert_path: Path to the PEM-encoded client certificate file.
            key_path: Path to the PEM-encoded private key file.
            ca_path: Optional path to the PEM-encoded CA certificate file.

        Raises:
            FileNotFoundError: if any of the required files do not exist.
            ValueError: if a file's content is not valid PEM.
        """
        cert_pem = Path(cert_path).read_text(encoding="utf-8")
        key_pem = Path(key_path).read_text(encoding="utf-8")
        ca_pem = Path(ca_path).read_text(encoding="utf-8") if ca_path else None
        return cls(cert_pem, key_pem, ca_pem)

    @classmethod
    def from_env(cls) -> Optional["ConduitIdentity"]:
        """Build an identity from environment variables.

        Reads:
        - ``CONDUIT_MTLS_CERT`` — PEM string for the client certificate
        - ``CONDUIT_MTLS_KEY``  — PEM string for the private key
        - ``CONDUIT_MTLS_CA``   — PEM string for the CA (optional)

        Returns:
            ``None`` if ``CONDUIT_MTLS_CERT`` is not set.

        Raises:
            ValueError: if ``CONDUIT_MTLS_CERT`` is set but ``CONDUIT_MTLS_KEY``
                is missing.
        """
        cert_pem = os.environ.get("CONDUIT_MTLS_CERT")
        if not cert_pem:
            return None

        key_pem = os.environ.get("CONDUIT_MTLS_KEY")
        if not key_pem:
            raise ValueError(
                "CONDUIT_MTLS_CERT is set but CONDUIT_MTLS_KEY is missing"
            )

        ca_pem = os.environ.get("CONDUIT_MTLS_CA") or None
        return cls(cert_pem, key_pem, ca_pem)

    @classmethod
    def try_default(cls) -> Optional["ConduitIdentity"]:
        """Try to locate an identity using the auto-discovery chain.

        Returns:
            A :class:`ConduitIdentity` if one is found, otherwise ``None``.
            Never raises — loading errors for individual locations are logged
            at DEBUG level and skipped.
        """
        # 1. Environment variables
        try:
            identity = cls.from_env()
            if identity is not None:
                logger.debug("conduit: loaded mTLS identity from environment variables")
                return identity
        except ValueError:
            pass  # Missing KEY — don't fall through silently; caller should use from_env()

        # 2. ~/.conduit/
        home = Path.home()
        if home:
            identity = cls._try_load_from_dir(home / ".conduit")
            if identity is not None:
                logger.debug("conduit: loaded mTLS identity from %s/.conduit/", home)
                return identity

        # 3. .conduit/ relative to cwd
        identity = cls._try_load_from_dir(Path.cwd() / ".conduit")
        if identity is not None:
            logger.debug("conduit: loaded mTLS identity from .conduit/ in cwd")
            return identity

        logger.debug("conduit: no mTLS identity found, using token auth")
        return None

    # ─── Builder-style setters ────────────────────────────────────────────────

    def with_expiry(self, expires_at: datetime) -> "ConduitIdentity":
        """Return a copy of this identity with the expiry timestamp set.

        Args:
            expires_at: The certificate's ``notAfter`` date (timezone-aware or
                naive UTC).
        """
        return ConduitIdentity(
            self._cert_pem,
            self._key_pem,
            self._ca_pem,
            expires_at,
        )

    # ─── Introspection ────────────────────────────────────────────────────────

    def needs_rotation(self, threshold_days: int = 30) -> bool:
        """Return ``True`` if the certificate expires within *threshold_days*.

        Always returns ``False`` when no expiry is set — call :meth:`with_expiry`
        or use the DataGrout registration flow to populate this field.

        Args:
            threshold_days: How many days before expiry to start warning.
        """
        if self._expires_at is None:
            return False
        from datetime import timedelta

        now = datetime.now(tz=timezone.utc)
        expiry = (
            self._expires_at
            if self._expires_at.tzinfo is not None
            else self._expires_at.replace(tzinfo=timezone.utc)
        )
        return now + timedelta(days=threshold_days) > expiry

    @property
    def cert_pem(self) -> str:
        """PEM-encoded client certificate."""
        return self._cert_pem

    @property
    def key_pem(self) -> str:
        """PEM-encoded private key."""
        return self._key_pem

    @property
    def ca_pem(self) -> Optional[str]:
        """PEM-encoded CA certificate(s), if any."""
        return self._ca_pem

    @property
    def expires_at(self) -> Optional[datetime]:
        """Certificate expiry, if known."""
        return self._expires_at

    def __repr__(self) -> str:
        return (
            f"ConduitIdentity("
            f"has_ca={self._ca_pem is not None}, "
            f"expires_at={self._expires_at!r})"
        )

    # ─── httpx / ssl integration ──────────────────────────────────────────────

    def build_ssl_context(self) -> ssl.SSLContext:
        """Build an ``ssl.SSLContext`` with this identity loaded.

        The context is configured for TLS 1.2+ with server certificate
        verification enabled (using either the provided CA or the system
        trust store).

        Python's ``ssl`` module requires certificate material on disk, so
        this method writes temporary files, loads them, and then deletes
        them before returning.

        Returns:
            A configured :class:`ssl.SSLContext` suitable for
            ``httpx.AsyncClient(verify=ctx)``.
        """
        if self.needs_rotation(30):
            logger.warning(
                "conduit: mTLS certificate expires within 30 days — consider rotating"
            )

        ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_CLIENT)
        ctx.minimum_version = ssl.TLSVersion.TLSv1_2
        ctx.check_hostname = True
        ctx.verify_mode = ssl.CERT_REQUIRED

        with _temp_pem(self._cert_pem, suffix="-cert.pem") as cert_file, \
             _temp_pem(self._key_pem, suffix="-key.pem") as key_file:
            ctx.load_cert_chain(certfile=cert_file, keyfile=key_file)

        if self._ca_pem:
            ctx.load_verify_locations(cadata=self._ca_pem)
        else:
            ctx.load_default_certs()

        return ctx

    # ─── Private helpers ──────────────────────────────────────────────────────

    @classmethod
    def _try_load_from_dir(cls, directory: Path) -> Optional["ConduitIdentity"]:
        cert_path = directory / "identity.pem"
        key_path = directory / "identity_key.pem"
        if not cert_path.exists() or not key_path.exists():
            return None

        ca_path: Optional[Path] = directory / "ca.pem"
        if not ca_path.exists():  # type: ignore[union-attr]
            ca_path = None

        try:
            return cls.from_paths(cert_path, key_path, ca_path)
        except Exception as exc:
            logger.debug("conduit: identity at %s is invalid: %s", directory, exc)
            return None


# ─── Internal helpers ─────────────────────────────────────────────────────────


def _has_private_key_header(pem: str) -> bool:
    return any(
        header in pem
        for header in (
            "-----BEGIN PRIVATE KEY-----",
            "-----BEGIN RSA PRIVATE KEY-----",
            "-----BEGIN EC PRIVATE KEY-----",
            "-----BEGIN ENCRYPTED PRIVATE KEY-----",
        )
    )


@contextmanager
def _temp_pem(content: str, suffix: str = ".pem") -> Generator[str, None, None]:
    """Write *content* to a named temp file, yield its path, then delete it."""
    fd, path = tempfile.mkstemp(suffix=suffix)
    try:
        with os.fdopen(fd, "w") as f:
            f.write(content)
        yield path
    finally:
        try:
            os.unlink(path)
        except OSError:
            pass
