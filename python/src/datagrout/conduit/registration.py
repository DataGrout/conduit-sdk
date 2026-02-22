"""Substrate identity registration with the DataGrout CA.

The registration flow mirrors the Rust SDK exactly (Rust is the reference spec):

1. :func:`generate_keypair` — generate an ECDSA P-256 keypair locally.
   Returns a :class:`~datagrout.conduit.ConduitIdentity` holding the private
   key and a **temporary self-signed certificate** (placeholder only).
   The private key never leaves the client.

2. :func:`register_identity` — send only the public key to DataGrout.
   DG signs the cert and returns a DG-CA-signed certificate.
   The returned identity replaces the placeholder cert with the real one.

3. :func:`save_identity` — persist the returned identity to ``~/.conduit/``
   for auto-discovery by :meth:`~datagrout.conduit.ConduitIdentity.try_default`.

4. :func:`rotate_identity` — on renewal (cert near expiry), present the
   *existing* client cert over mTLS (no API key needed) to get a new one.

CA cert refresh
---------------
:func:`fetch_dg_ca_cert` fetches the current DataGrout CA certificate from
``https://ca.datagrout.ai/ca.pem``. This uses the system trust store, so
there is no circularity. Call :func:`refresh_ca_cert` at startup to pick up
CA rotations without re-registering.
"""

from __future__ import annotations

import datetime
from dataclasses import dataclass
from pathlib import Path
from typing import Optional, Tuple

import httpx

from .identity import ConduitIdentity

#: Canonical URL for the DataGrout CA certificate.
DG_CA_URL = "https://ca.datagrout.ai/ca.pem"

#: Default local identity directory.
DEFAULT_IDENTITY_DIR = Path.home() / ".conduit"


# ─── Receipt / meta types ─────────────────────────────────────────────────────


@dataclass
class Byok:
    """BYOK discount details embedded in a receipt."""
    enabled: bool = False
    discount_applied: float = 0.0
    discount_rate: float = 0.0


@dataclass
class Receipt:
    """Cost receipt attached to every DG tool-call result under ``_meta.receipt``.

    Use :func:`extract_meta` to pull this out of any tool-call result dict.
    """
    receipt_id: str
    timestamp: str
    estimated_credits: float
    actual_credits: float
    net_credits: float
    savings: float
    savings_bonus: float
    breakdown: dict
    byok: Byok
    transaction_id: Optional[str] = None
    balance_before: Optional[float] = None
    balance_after: Optional[float] = None


@dataclass
class CreditEstimate:
    """Pre-execution credit estimate under ``_meta.credit_estimate``."""
    estimated_total: float
    actual_total: float
    net_total: float
    breakdown: dict


@dataclass
class ToolMeta:
    """The ``_meta`` block DataGrout appends to every tool-call result.

    Example::

        result = await client.call_tool("salesforce@v1/get_lead@v1", {...})
        meta = extract_meta(result)
        if meta:
            print(f"Charged {meta.receipt.net_credits} credits")
    """
    receipt: Receipt
    credit_estimate: Optional[CreditEstimate] = None


def extract_meta(result: dict) -> Optional[ToolMeta]:
    """Extract the DataGrout metadata block from a tool-call result dict.

    Checks ``_datagrout`` first (current format), then falls back to ``_meta``
    for backward compatibility with older gateway responses.

    Returns ``None`` when the result contains neither key (e.g. upstream
    servers not routed through the DG gateway).
    """
    raw_meta = None
    if isinstance(result, dict):
        raw_meta = result.get("_datagrout") or result.get("_meta")
    if not raw_meta:
        return None

    raw_receipt = raw_meta.get("receipt", {})
    receipt = Receipt(
        receipt_id=raw_receipt.get("receipt_id", ""),
        timestamp=raw_receipt.get("timestamp", ""),
        estimated_credits=raw_receipt.get("estimated_credits", 0.0),
        actual_credits=raw_receipt.get("actual_credits", 0.0),
        net_credits=raw_receipt.get("net_credits", 0.0),
        savings=raw_receipt.get("savings", 0.0),
        savings_bonus=raw_receipt.get("savings_bonus", 0.0),
        breakdown=raw_receipt.get("breakdown", {}),
        byok=Byok(**raw_receipt.get("byok", {})),
        transaction_id=raw_receipt.get("transaction_id"),
        balance_before=raw_receipt.get("balance_before"),
        balance_after=raw_receipt.get("balance_after"),
    )

    raw_est = raw_meta.get("credit_estimate")
    credit_estimate = (
        CreditEstimate(
            estimated_total=raw_est.get("estimated_total", 0.0),
            actual_total=raw_est.get("actual_total", 0.0),
            net_total=raw_est.get("net_total", 0.0),
            breakdown=raw_est.get("breakdown", {}),
        )
        if raw_est
        else None
    )

    return ToolMeta(receipt=receipt, credit_estimate=credit_estimate)


# ─── Registration response ─────────────────────────────────────────────────────


@dataclass
class RegistrationResponse:
    """Response body from ``POST /api/v1/substrate/identity/register`` or ``/rotate``."""
    id: str
    cert_pem: str
    fingerprint: str
    name: str
    registered_at: str
    ca_cert_pem: Optional[str] = None
    valid_until: Optional[str] = None


@dataclass
class SavedIdentityPaths:
    """Paths written by :func:`save_identity`."""
    cert_path: Path
    key_path: Path
    ca_path: Optional[Path] = None


# ─── CA cert fetching ─────────────────────────────────────────────────────────


async def fetch_dg_ca_cert(url: str = DG_CA_URL) -> str:
    """Fetch the current DataGrout CA certificate from ``ca.datagrout.ai``.

    Uses the system trust store for HTTPS — no circularity with the DG CA.

    Returns:
        PEM-encoded CA certificate string.
    """
    async with httpx.AsyncClient() as client:
        resp = await client.get(url, headers={"Accept": "application/x-pem-file, text/plain"})
        resp.raise_for_status()
        pem = resp.text

    if "-----BEGIN CERTIFICATE-----" not in pem:
        raise ValueError(f"Response from {url} does not look like a PEM certificate")

    return pem


async def refresh_ca_cert(
    identity_dir: Path = DEFAULT_IDENTITY_DIR,
    url: str = DG_CA_URL,
) -> Path:
    """Refresh the locally-cached DG CA certificate.

    Fetches the current CA cert and writes it to ``{identity_dir}/ca.pem``.
    Call at application startup to pick up CA rotations transparently.

    Returns:
        Path to the written ``ca.pem`` file.
    """
    pem = await fetch_dg_ca_cert(url)
    identity_dir.mkdir(parents=True, exist_ok=True)
    ca_path = identity_dir / "ca.pem"
    ca_path.write_text(pem)
    return ca_path


# ─── Keypair generation ───────────────────────────────────────────────────────


def generate_keypair(name: str) -> ConduitIdentity:
    """Generate an ECDSA P-256 keypair for Substrate identity registration.

    Returns a :class:`~datagrout.conduit.ConduitIdentity` holding the private
    key and a **temporary self-signed certificate** (placeholder only).  Pass
    the returned object to :func:`register_identity` to exchange the placeholder
    for a DG-CA-signed certificate.

    The private key is generated entirely locally and never transmitted.

    Args:
        name: Human-readable label embedded in the self-signed cert CN.

    Returns:
        A :class:`ConduitIdentity` with a placeholder cert; call
        :func:`register_identity` to get the real DG-signed identity.
    """
    from cryptography import x509
    from cryptography.hazmat.primitives import hashes, serialization
    from cryptography.hazmat.primitives.asymmetric import ec
    from cryptography.x509.oid import NameOID

    private_key = ec.generate_private_key(ec.SECP256R1())

    subject = x509.Name([x509.NameAttribute(NameOID.COMMON_NAME, name)])
    now = datetime.datetime.now(datetime.timezone.utc)

    cert = (
        x509.CertificateBuilder()
        .subject_name(subject)
        .issuer_name(subject)
        .public_key(private_key.public_key())
        .serial_number(x509.random_serial_number())
        .not_valid_before(now)
        .not_valid_after(now + datetime.timedelta(days=1))
        .sign(private_key, hashes.SHA256())
    )

    cert_pem = cert.public_bytes(serialization.Encoding.PEM).decode()
    key_pem = private_key.private_bytes(
        serialization.Encoding.PEM,
        serialization.PrivateFormat.PKCS8,
        serialization.NoEncryption(),
    ).decode()

    return ConduitIdentity(cert_pem=cert_pem, key_pem=key_pem)


# ─── Registration ─────────────────────────────────────────────────────────────


async def register_identity(
    keypair: ConduitIdentity,
    *,
    endpoint: str,
    api_key: str,
    name: str,
    ca_url: str = DG_CA_URL,
) -> Tuple[ConduitIdentity, RegistrationResponse]:
    """Register a Substrate keypair with the DataGrout CA.

    Sends only the public key to DataGrout and receives back a DG-CA-signed
    certificate.  The private key in *keypair* is reused — it never leaves
    the client.

    Args:
        keypair: A keypair generated by :func:`generate_keypair`.
        endpoint: Base URL for the substrate identity API,
                  e.g. ``https://app.datagrout.ai/api/v1/substrate/identity``.
        api_key: Arbiter API key for bootstrap authentication.
        name: Human-readable label for this Substrate instance.
        ca_url: URL to fetch the DG CA cert from (default: :data:`DG_CA_URL`).

    Returns:
        Tuple of ``(registered ConduitIdentity, RegistrationResponse)``.
        The identity contains the same private key as *keypair* but with the
        DG-signed certificate replacing the placeholder.
    """
    from cryptography.hazmat.primitives import serialization
    from cryptography.hazmat.primitives.asymmetric.ec import EllipticCurvePrivateKey

    # Load the private key from the keypair PEM so we can export the public key.
    from cryptography.hazmat.primitives.serialization import load_pem_private_key
    private_key = load_pem_private_key(keypair.key_pem.encode(), password=None)
    public_key_pem = private_key.public_key().public_bytes(
        serialization.Encoding.PEM,
        serialization.PublicFormat.SubjectPublicKeyInfo,
    ).decode()

    url = endpoint.rstrip("/") + "/register"
    async with httpx.AsyncClient() as client:
        resp = await client.post(
            url,
            headers={"Authorization": f"Bearer {api_key}"},
            json={"public_key_pem": public_key_pem, "name": name},
        )
        resp.raise_for_status()
        body = resp.json()

    ca_pem: Optional[str] = body.get("ca_cert_pem")
    if not ca_pem:
        try:
            ca_pem = await fetch_dg_ca_cert(ca_url)
        except Exception:
            ca_pem = None

    registered = ConduitIdentity(
        cert_pem=body["cert_pem"],
        key_pem=keypair.key_pem,
        ca_pem=ca_pem,
    )
    response = RegistrationResponse(
        id=body["id"],
        cert_pem=body["cert_pem"],
        ca_cert_pem=ca_pem,
        fingerprint=body["fingerprint"],
        name=body.get("name", name),
        registered_at=body.get("registered_at", ""),
        valid_until=body.get("valid_until"),
    )
    return registered, response


# ─── Rotation ─────────────────────────────────────────────────────────────────


async def rotate_identity(
    current_identity: ConduitIdentity,
    *,
    endpoint: str,
    name: str,
    ca_url: str = DG_CA_URL,
) -> Tuple[ConduitIdentity, RegistrationResponse]:
    """Rotate the Substrate identity by presenting the current cert over mTLS.

    Generates a new keypair and sends the public key to the ``/rotate``
    endpoint, authenticated with the *existing* client certificate over mTLS
    — no API key needed.

    Args:
        current_identity: The currently-active identity (used for mTLS).
        endpoint: Base URL for the substrate identity API.
        name: Human-readable label for the renewed identity.
        ca_url: URL to fetch the DG CA cert from.

    Returns:
        Tuple of ``(new ConduitIdentity, RegistrationResponse)``.
    """
    new_keypair = generate_keypair(name)

    from cryptography.hazmat.primitives import serialization
    from cryptography.hazmat.primitives.serialization import load_pem_private_key
    private_key = load_pem_private_key(new_keypair.key_pem.encode(), password=None)
    public_key_pem = private_key.public_key().public_bytes(
        serialization.Encoding.PEM,
        serialization.PublicFormat.SubjectPublicKeyInfo,
    ).decode()

    url = endpoint.rstrip("/") + "/rotate"
    ssl_context = current_identity.build_ssl_context()

    async with httpx.AsyncClient(verify=ssl_context) as client:
        resp = await client.post(
            url,
            json={"public_key_pem": public_key_pem, "name": name},
        )
        resp.raise_for_status()
        body = resp.json()

    ca_pem: Optional[str] = body.get("ca_cert_pem")
    if not ca_pem:
        try:
            ca_pem = await fetch_dg_ca_cert(ca_url)
        except Exception:
            ca_pem = None

    registered = ConduitIdentity(
        cert_pem=body["cert_pem"],
        key_pem=new_keypair.key_pem,
        ca_pem=ca_pem,
    )
    response = RegistrationResponse(
        id=body["id"],
        cert_pem=body["cert_pem"],
        ca_cert_pem=ca_pem,
        fingerprint=body["fingerprint"],
        name=body.get("name", name),
        registered_at=body.get("registered_at", ""),
        valid_until=body.get("valid_until"),
    )
    return registered, response


# ─── Persistence ──────────────────────────────────────────────────────────────


def save_identity(
    identity: ConduitIdentity,
    directory: Path = DEFAULT_IDENTITY_DIR,
) -> SavedIdentityPaths:
    """Save a registered identity to a directory for auto-discovery.

    Writes:
    - ``{dir}/identity.pem``     — DG-signed certificate
    - ``{dir}/identity_key.pem`` — private key (chmod 600)
    - ``{dir}/ca.pem``           — DG CA certificate (if present)

    Args:
        identity: The registered identity to persist.
        directory: Target directory (default: ``~/.conduit/``).

    Returns:
        :class:`SavedIdentityPaths` with the written file paths.
    """
    directory.mkdir(parents=True, exist_ok=True)

    cert_path = directory / "identity.pem"
    key_path = directory / "identity_key.pem"

    cert_path.write_text(identity.cert_pem)
    key_path.write_text(identity.key_pem)
    key_path.chmod(0o600)

    ca_path: Optional[Path] = None
    if identity.ca_pem:
        ca_path = directory / "ca.pem"
        ca_path.write_text(identity.ca_pem)

    return SavedIdentityPaths(cert_path=cert_path, key_path=key_path, ca_path=ca_path)


def default_identity_dir() -> Path:
    """Return the default Conduit identity directory (``~/.conduit/``)."""
    return DEFAULT_IDENTITY_DIR
