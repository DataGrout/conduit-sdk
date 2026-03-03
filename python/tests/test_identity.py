"""Tests for ConduitIdentity (mTLS identity plane).

Cert fixtures are minimal self-signed PEM blobs — they are syntactically
valid PEM but not semantically valid X.509.  That is fine because these
tests exercise the parsing / validation / routing logic, not the TLS stack.

Tests that require a real SSL handshake (integration tests) are marked with
``@pytest.mark.integration`` and skipped in the normal test run.
"""

from __future__ import annotations

import os
import ssl
import textwrap
from datetime import datetime, timedelta, timezone
from pathlib import Path
from unittest.mock import AsyncMock, MagicMock, patch

import pytest

from datagrout.conduit import Client, ConduitIdentity
from datagrout.conduit.identity import _has_private_key_header, _temp_pem
from datagrout.conduit.transports.jsonrpc_transport import JSONRPCTransport


# ─── PEM fixtures ─────────────────────────────────────────────────────────────

# Syntactically correct PEM blocks (not real certs — labels matter, content not).
CERT_PEM = textwrap.dedent("""\
    -----BEGIN CERTIFICATE-----
    MIIBpTCCAQ6gAwIBAgIUZ2F0ZXdheS1jbGllbnQtMDAxMCAXDTI1MDEwMTAwMDAw
    MFoYDzIwMzUwMTAxMDAwMDAwWjAWMRQwEgYDVQQDDAtleGFtcGxlLmNvbTCBnzAN
    BgkqhkiG9w0BAQEFAAOBjQAwgYkCgYEA2a2rwplBQLzm3sXbgkPHtOhVyFw5lA1B
    GLHE/4z5PSs5zStQSyEOqJaqNbDEL0PYBCGtDM6x9BfLHNbmMTcb7TJ9uHnElk0i
    ZDR+dqtplz1P1oCEthOzLy0dADEhqp+ePOkfmhWP2F+3QzIWPRUPNEjECAwEAAaNT
    MFEwHQYDVR0OBBYEFHoHCVGvTCCMRgTyFnyKuWDHnVFqMB8GA1UdIwQYMBaAFHoH
    CVGvTCCMRgTyFnyKuWDHnVFqMA8GA1UdEwEB/wQFMAMBAf8=
    -----END CERTIFICATE-----
""")

KEY_PEM = textwrap.dedent("""\
    -----BEGIN PRIVATE KEY-----
    MIIEvQIBADANBgkqhkiG9w0BAQEFAASCBKcwggSjAgEAAoIBAQDZravCmUFAsXb1
    qbKDKQQyZjPT4pyPdtkJmQ8e06FXIXDmUDUEYscT/jPk9KznNK1BLJQ6olqo1sM
    QvQ9gEIa0MzrH0F8sc1uYxNxvtMn24ecSWTSJkNH52q2mXPU/WgIS2E7MvLR0AMS
    GqmZ486R+aFY/YX7dDMhY9FQ80SMEB4CAwEAAQ==
    -----END PRIVATE KEY-----
""")

RSA_KEY_PEM = textwrap.dedent("""\
    -----BEGIN RSA PRIVATE KEY-----
    MIIEowIBAAKCAQEA2a2rwplBQLF29amygykEMmYz0+Kcj3bZCZkPHtOhVyFw5lA1
    BGLHEfake==
    -----END RSA PRIVATE KEY-----
""")

EC_KEY_PEM = textwrap.dedent("""\
    -----BEGIN EC PRIVATE KEY-----
    MHQCAQEEIPfake/key/bytes/here==
    -----END EC PRIVATE KEY-----
""")

CA_PEM = textwrap.dedent("""\
    -----BEGIN CERTIFICATE-----
    MIIBpzCCAQ+gAwIBAgIUWENnSElGTGgtY2EtMDAxIDAXDTI1MDEwMTAwMDAwMFoY
    DzIwMzUwMTAxMDAwMDAwWjAXMRUwEwYDVQQDDAxleGFtcGxlLWNhLTEwgZ8=
    -----END CERTIFICATE-----
""")

BAD_PEM = "this is definitely not a PEM"
# A private key PEM used where a certificate is expected — wrong label
BAD_KEY = textwrap.dedent("""\
    -----BEGIN PRIVATE KEY-----
    MIIEvQIBADANBgkqhkiG9w0BAQEFAASCBKcwggSjAgEAAoIBAQDZfake==
    -----END PRIVATE KEY-----
""")


# ─── from_pem ────────────────────────────────────────────────────────────────


class TestFromPem:
    def test_accepts_valid_cert_and_key(self) -> None:
        identity = ConduitIdentity.from_pem(CERT_PEM, KEY_PEM)
        assert identity.cert_pem == CERT_PEM
        assert identity.key_pem == KEY_PEM
        assert identity.ca_pem is None
        assert identity.expires_at is None

    def test_accepts_optional_ca(self) -> None:
        identity = ConduitIdentity.from_pem(CERT_PEM, KEY_PEM, CA_PEM)
        assert identity.ca_pem == CA_PEM

    def test_raises_when_cert_is_not_a_certificate(self) -> None:
        with pytest.raises(ValueError, match="certificate"):
            ConduitIdentity.from_pem(BAD_PEM, KEY_PEM)

    def test_raises_when_cert_label_is_wrong(self) -> None:
        with pytest.raises(ValueError, match="certificate"):
            ConduitIdentity.from_pem(BAD_KEY, KEY_PEM)

    def test_raises_when_key_is_missing(self) -> None:
        with pytest.raises(ValueError, match="private key"):
            ConduitIdentity.from_pem(CERT_PEM, BAD_PEM)

    def test_raises_when_cert_used_as_key(self) -> None:
        with pytest.raises(ValueError, match="private key"):
            ConduitIdentity.from_pem(CERT_PEM, CERT_PEM)

    def test_accepts_rsa_private_key_header(self) -> None:
        identity = ConduitIdentity.from_pem(CERT_PEM, RSA_KEY_PEM)
        assert identity.key_pem == RSA_KEY_PEM

    def test_accepts_ec_private_key_header(self) -> None:
        identity = ConduitIdentity.from_pem(CERT_PEM, EC_KEY_PEM)
        assert identity.key_pem == EC_KEY_PEM


# ─── from_paths ───────────────────────────────────────────────────────────────


class TestFromPaths:
    def test_loads_cert_and_key_from_files(self, tmp_path: Path) -> None:
        cert_path = tmp_path / "cert.pem"
        key_path = tmp_path / "key.pem"
        cert_path.write_text(CERT_PEM)
        key_path.write_text(KEY_PEM)

        identity = ConduitIdentity.from_paths(cert_path, key_path)
        assert identity.cert_pem == CERT_PEM
        assert identity.key_pem == KEY_PEM
        assert identity.ca_pem is None

    def test_loads_ca_when_provided(self, tmp_path: Path) -> None:
        cert_path = tmp_path / "cert.pem"
        key_path = tmp_path / "key.pem"
        ca_path = tmp_path / "ca.pem"
        cert_path.write_text(CERT_PEM)
        key_path.write_text(KEY_PEM)
        ca_path.write_text(CA_PEM)

        identity = ConduitIdentity.from_paths(cert_path, key_path, ca_path)
        assert identity.ca_pem == CA_PEM

    def test_raises_when_file_missing(self) -> None:
        with pytest.raises(FileNotFoundError):
            ConduitIdentity.from_paths("/nonexistent/cert.pem", "/nonexistent/key.pem")

    def test_raises_when_file_has_bad_content(self, tmp_path: Path) -> None:
        cert_path = tmp_path / "cert.pem"
        key_path = tmp_path / "key.pem"
        cert_path.write_text(BAD_PEM)
        key_path.write_text(KEY_PEM)

        with pytest.raises(ValueError, match="certificate"):
            ConduitIdentity.from_paths(cert_path, key_path)

    def test_accepts_string_paths(self, tmp_path: Path) -> None:
        cert_path = tmp_path / "cert.pem"
        key_path = tmp_path / "key.pem"
        cert_path.write_text(CERT_PEM)
        key_path.write_text(KEY_PEM)

        identity = ConduitIdentity.from_paths(str(cert_path), str(key_path))
        assert identity.cert_pem == CERT_PEM


# ─── from_env ────────────────────────────────────────────────────────────────


class TestFromEnv:
    def test_returns_none_when_cert_not_set(self, monkeypatch: pytest.MonkeyPatch) -> None:
        monkeypatch.delenv("CONDUIT_MTLS_CERT", raising=False)
        assert ConduitIdentity.from_env() is None

    def test_loads_from_env_vars(self, monkeypatch: pytest.MonkeyPatch) -> None:
        monkeypatch.setenv("CONDUIT_MTLS_CERT", CERT_PEM)
        monkeypatch.setenv("CONDUIT_MTLS_KEY", KEY_PEM)
        monkeypatch.delenv("CONDUIT_MTLS_CA", raising=False)

        identity = ConduitIdentity.from_env()
        assert identity is not None
        assert identity.cert_pem == CERT_PEM
        assert identity.key_pem == KEY_PEM
        assert identity.ca_pem is None

    def test_includes_ca_when_set(self, monkeypatch: pytest.MonkeyPatch) -> None:
        monkeypatch.setenv("CONDUIT_MTLS_CERT", CERT_PEM)
        monkeypatch.setenv("CONDUIT_MTLS_KEY", KEY_PEM)
        monkeypatch.setenv("CONDUIT_MTLS_CA", CA_PEM)

        identity = ConduitIdentity.from_env()
        assert identity is not None
        assert identity.ca_pem == CA_PEM

    def test_raises_when_key_missing(self, monkeypatch: pytest.MonkeyPatch) -> None:
        monkeypatch.setenv("CONDUIT_MTLS_CERT", CERT_PEM)
        monkeypatch.delenv("CONDUIT_MTLS_KEY", raising=False)

        with pytest.raises(ValueError, match="CONDUIT_MTLS_KEY"):
            ConduitIdentity.from_env()

    def test_empty_cert_env_treated_as_not_set(self, monkeypatch: pytest.MonkeyPatch) -> None:
        monkeypatch.setenv("CONDUIT_MTLS_CERT", "")
        assert ConduitIdentity.from_env() is None


# ─── try_default ─────────────────────────────────────────────────────────────


class TestTryDefault:
    def test_returns_none_when_nothing_configured(
        self, monkeypatch: pytest.MonkeyPatch, tmp_path: Path
    ) -> None:
        monkeypatch.delenv("CONDUIT_MTLS_CERT", raising=False)
        # Point HOME to an empty directory so ~/.conduit/ doesn't exist
        monkeypatch.setenv("HOME", str(tmp_path))
        monkeypatch.chdir(tmp_path)

        result = ConduitIdentity.try_default()
        assert result is None

    def test_picks_up_env_vars(self, monkeypatch: pytest.MonkeyPatch) -> None:
        monkeypatch.setenv("CONDUIT_MTLS_CERT", CERT_PEM)
        monkeypatch.setenv("CONDUIT_MTLS_KEY", KEY_PEM)

        result = ConduitIdentity.try_default()
        assert result is not None
        assert result.cert_pem == CERT_PEM

    def test_loads_from_home_conduit_dir(
        self, monkeypatch: pytest.MonkeyPatch, tmp_path: Path
    ) -> None:
        monkeypatch.delenv("CONDUIT_MTLS_CERT", raising=False)
        fake_home = tmp_path / "fake_home"
        dot_conduit = fake_home / ".conduit"
        dot_conduit.mkdir(parents=True)
        (dot_conduit / "identity.pem").write_text(CERT_PEM)
        (dot_conduit / "identity_key.pem").write_text(KEY_PEM)

        monkeypatch.setenv("HOME", str(fake_home))

        result = ConduitIdentity.try_default()
        assert result is not None
        assert result.cert_pem == CERT_PEM

    def test_loads_ca_from_home_conduit_dir(
        self, monkeypatch: pytest.MonkeyPatch, tmp_path: Path
    ) -> None:
        monkeypatch.delenv("CONDUIT_MTLS_CERT", raising=False)
        fake_home = tmp_path / "fake_home2"
        dot_conduit = fake_home / ".conduit"
        dot_conduit.mkdir(parents=True)
        (dot_conduit / "identity.pem").write_text(CERT_PEM)
        (dot_conduit / "identity_key.pem").write_text(KEY_PEM)
        (dot_conduit / "ca.pem").write_text(CA_PEM)

        monkeypatch.setenv("HOME", str(fake_home))

        result = ConduitIdentity.try_default()
        assert result is not None
        assert result.ca_pem == CA_PEM

    def test_loads_from_cwd_conduit_dir(
        self, monkeypatch: pytest.MonkeyPatch, tmp_path: Path
    ) -> None:
        monkeypatch.delenv("CONDUIT_MTLS_CERT", raising=False)
        # Use a home with no .conduit/ so we reach cwd fallback
        empty_home = tmp_path / "empty_home"
        empty_home.mkdir()
        monkeypatch.setenv("HOME", str(empty_home))

        dot_conduit = tmp_path / ".conduit"
        dot_conduit.mkdir()
        (dot_conduit / "identity.pem").write_text(CERT_PEM)
        (dot_conduit / "identity_key.pem").write_text(KEY_PEM)

        monkeypatch.chdir(tmp_path)

        result = ConduitIdentity.try_default()
        assert result is not None
        assert result.cert_pem == CERT_PEM

    def test_env_takes_priority_over_filesystem(
        self, monkeypatch: pytest.MonkeyPatch, tmp_path: Path
    ) -> None:
        different_cert = CERT_PEM.replace("MIIBpTCCAQ6g", "DIFFERENT_PREFIX")
        dot_conduit = tmp_path / ".conduit"
        dot_conduit.mkdir()
        (dot_conduit / "identity.pem").write_text(different_cert)
        (dot_conduit / "identity_key.pem").write_text(KEY_PEM)

        monkeypatch.setenv("CONDUIT_MTLS_CERT", CERT_PEM)
        monkeypatch.setenv("CONDUIT_MTLS_KEY", KEY_PEM)
        monkeypatch.setenv("HOME", str(tmp_path))

        result = ConduitIdentity.try_default()
        assert result is not None
        assert result.cert_pem == CERT_PEM  # from env, not filesystem


# ─── Rotation awareness ───────────────────────────────────────────────────────


class TestRotation:
    def test_needs_rotation_false_when_no_expiry(self) -> None:
        identity = ConduitIdentity.from_pem(CERT_PEM, KEY_PEM)
        assert identity.needs_rotation(30) is False
        assert identity.needs_rotation(0) is False

    def test_needs_rotation_true_when_already_expired(self) -> None:
        past = datetime.now(tz=timezone.utc) - timedelta(seconds=1)
        identity = ConduitIdentity.from_pem(CERT_PEM, KEY_PEM).with_expiry(past)
        assert identity.needs_rotation(0) is True

    def test_needs_rotation_true_within_threshold(self) -> None:
        soon = datetime.now(tz=timezone.utc) + timedelta(days=10)
        identity = ConduitIdentity.from_pem(CERT_PEM, KEY_PEM).with_expiry(soon)
        assert identity.needs_rotation(30) is True   # threshold 30d → within
        assert identity.needs_rotation(5) is False   # threshold 5d → not within

    def test_needs_rotation_false_when_far_future(self) -> None:
        far = datetime.now(tz=timezone.utc) + timedelta(days=365 * 5)
        identity = ConduitIdentity.from_pem(CERT_PEM, KEY_PEM).with_expiry(far)
        assert identity.needs_rotation(90) is False

    def test_with_expiry_returns_new_object(self) -> None:
        original = ConduitIdentity.from_pem(CERT_PEM, KEY_PEM)
        expiry = datetime(2035, 1, 1, tzinfo=timezone.utc)
        updated = original.with_expiry(expiry)

        assert original.expires_at is None
        assert updated.expires_at == expiry
        assert updated.cert_pem == original.cert_pem  # unchanged

    def test_needs_rotation_handles_naive_datetime(self) -> None:
        """Naive datetimes are treated as UTC."""
        past_naive = datetime.utcnow() - timedelta(seconds=1)
        identity = ConduitIdentity.from_pem(CERT_PEM, KEY_PEM).with_expiry(past_naive)
        assert identity.needs_rotation(0) is True


# ─── build_ssl_context ────────────────────────────────────────────────────────


class TestBuildSslContext:
    def test_returns_ssl_context(self) -> None:
        """build_ssl_context should return an ssl.SSLContext without raising.

        We can't load a fake cert into a real SSLContext, so we mock
        load_cert_chain to avoid the actual crypto call.
        """
        identity = ConduitIdentity.from_pem(CERT_PEM, KEY_PEM)

        with patch.object(ssl.SSLContext, "load_cert_chain"):
            ctx = identity.build_ssl_context()

        assert isinstance(ctx, ssl.SSLContext)

    def test_loads_ca_when_provided(self) -> None:
        identity = ConduitIdentity.from_pem(CERT_PEM, KEY_PEM, CA_PEM)

        with (
            patch.object(ssl.SSLContext, "load_cert_chain"),
            patch.object(ssl.SSLContext, "load_verify_locations") as mock_verify,
        ):
            identity.build_ssl_context()

        mock_verify.assert_called_once_with(cadata=CA_PEM)

    def test_uses_default_certs_when_no_ca(self) -> None:
        identity = ConduitIdentity.from_pem(CERT_PEM, KEY_PEM)

        with (
            patch.object(ssl.SSLContext, "load_cert_chain"),
            patch.object(ssl.SSLContext, "load_default_certs") as mock_default,
        ):
            identity.build_ssl_context()

        mock_default.assert_called_once()

    def test_warns_when_cert_near_expiry(self, caplog: pytest.LogCaptureFixture) -> None:
        soon = datetime.now(tz=timezone.utc) + timedelta(days=5)
        identity = ConduitIdentity.from_pem(CERT_PEM, KEY_PEM).with_expiry(soon)

        with (
            patch.object(ssl.SSLContext, "load_cert_chain"),
            caplog.at_level("WARNING", logger="datagrout.conduit.identity"),
        ):
            identity.build_ssl_context()

        assert any("30 days" in r.message for r in caplog.records)


# ─── _temp_pem context manager ───────────────────────────────────────────────


class TestTempPem:
    def test_creates_temp_file_with_content(self) -> None:
        content = "-----BEGIN CERTIFICATE-----\ntest\n-----END CERTIFICATE-----\n"
        with _temp_pem(content) as path:
            assert os.path.exists(path)
            with open(path) as f:
                assert f.read() == content

    def test_deletes_temp_file_after_context(self) -> None:
        with _temp_pem("content") as path:
            pass
        assert not os.path.exists(path)

    def test_deletes_temp_file_on_exception(self) -> None:
        saved_path: list[str] = []
        try:
            with _temp_pem("content") as path:
                saved_path.append(path)
                raise ValueError("intentional")
        except ValueError:
            pass
        assert not os.path.exists(saved_path[0])


# ─── _has_private_key_header helper ──────────────────────────────────────────


class TestHasPrivateKeyHeader:
    def test_accepts_pkcs8_header(self) -> None:
        assert _has_private_key_header("-----BEGIN PRIVATE KEY-----")

    def test_accepts_rsa_header(self) -> None:
        assert _has_private_key_header("-----BEGIN RSA PRIVATE KEY-----")

    def test_accepts_ec_header(self) -> None:
        assert _has_private_key_header("-----BEGIN EC PRIVATE KEY-----")

    def test_accepts_encrypted_header(self) -> None:
        assert _has_private_key_header("-----BEGIN ENCRYPTED PRIVATE KEY-----")

    def test_rejects_certificate_header(self) -> None:
        assert not _has_private_key_header("-----BEGIN CERTIFICATE-----")

    def test_rejects_garbage(self) -> None:
        assert not _has_private_key_header("not a pem at all")


# ─── Transport integration ───────────────────────────────────────────────────


class TestJSONRPCTransportWithIdentity:
    def test_constructs_without_identity(self) -> None:
        transport = JSONRPCTransport("https://gateway.example.com/mcp")
        assert transport.identity is None

    def test_constructs_with_identity(self) -> None:
        identity = ConduitIdentity.from_pem(CERT_PEM, KEY_PEM)
        transport = JSONRPCTransport("https://gateway.example.com/mcp", identity=identity)
        assert transport.identity is identity

    def test_warns_when_cert_near_expiry(self, caplog: pytest.LogCaptureFixture) -> None:
        soon = datetime.now(tz=timezone.utc) + timedelta(days=5)
        identity = ConduitIdentity.from_pem(CERT_PEM, KEY_PEM).with_expiry(soon)

        with caplog.at_level("WARNING", logger="datagrout.conduit.transports.jsonrpc_transport"):
            JSONRPCTransport("https://gateway.example.com/mcp", identity=identity)

        assert any("30 days" in r.message for r in caplog.records)

    @pytest.mark.asyncio
    async def test_connect_uses_ssl_context_when_identity_present(self) -> None:
        identity = ConduitIdentity.from_pem(CERT_PEM, KEY_PEM)
        transport = JSONRPCTransport("https://gateway.example.com/mcp", identity=identity)

        mock_ssl_ctx = MagicMock(spec=ssl.SSLContext)

        with (
            patch.object(identity, "build_ssl_context", return_value=mock_ssl_ctx) as mock_build,
            patch("datagrout.conduit.transports.jsonrpc_transport.httpx.AsyncClient") as mock_client_cls,
        ):
            mock_client_cls.return_value = MagicMock()
            await transport.connect()

        mock_build.assert_called_once()
        call_kwargs = mock_client_cls.call_args.kwargs
        assert call_kwargs["verify"] is mock_ssl_ctx

    @pytest.mark.asyncio
    async def test_connect_without_identity_no_verify_kwarg(self) -> None:
        transport = JSONRPCTransport("https://gateway.example.com/mcp")

        with patch(
            "datagrout.conduit.transports.jsonrpc_transport.httpx.AsyncClient"
        ) as mock_client_cls:
            mock_client_cls.return_value = MagicMock()
            await transport.connect()

        call_kwargs = mock_client_cls.call_args.kwargs
        assert "verify" not in call_kwargs


# ─── Client integration ───────────────────────────────────────────────────────


class TestClientWithIdentity:
    def test_accepts_explicit_identity(self) -> None:
        identity = ConduitIdentity.from_pem(CERT_PEM, KEY_PEM)
        client = Client(
            "https://gateway.datagrout.ai/servers/test/mcp",
            identity=identity,
        )
        assert client is not None

    def test_identity_auto_no_error_when_nothing_found(
        self, monkeypatch: pytest.MonkeyPatch, tmp_path: Path
    ) -> None:
        monkeypatch.delenv("CONDUIT_MTLS_CERT", raising=False)
        monkeypatch.setenv("HOME", str(tmp_path))

        client = Client(
            "https://gateway.datagrout.ai/servers/test/mcp",
            identity_auto=True,
        )
        assert client is not None

    def test_explicit_identity_takes_precedence_over_auto(
        self, monkeypatch: pytest.MonkeyPatch
    ) -> None:
        monkeypatch.setenv("CONDUIT_MTLS_CERT", CERT_PEM)
        monkeypatch.setenv("CONDUIT_MTLS_KEY", KEY_PEM)

        explicit_identity = ConduitIdentity.from_pem(CERT_PEM, KEY_PEM)

        try_default_called = []

        def fake_try_default() -> ConduitIdentity | None:
            try_default_called.append(True)
            return None

        with patch.object(ConduitIdentity, "try_default", staticmethod(fake_try_default)):
            client = Client(
                "https://gateway.datagrout.ai/servers/test/mcp",
                identity=explicit_identity,
                identity_auto=True,
            )

        # try_default should NOT have been called — explicit wins
        assert not try_default_called

    def test_identity_and_bearer_token_compose(self) -> None:
        identity = ConduitIdentity.from_pem(CERT_PEM, KEY_PEM)
        client = Client(
            "https://gateway.datagrout.ai/servers/test/mcp",
            auth={"bearer": "tok_test"},
            identity=identity,
        )
        assert client is not None

    @pytest.mark.asyncio
    async def test_full_flow_with_mocked_transport(self) -> None:
        from datagrout.conduit import extract_meta

        identity = ConduitIdentity.from_pem(CERT_PEM, KEY_PEM)

        with patch("datagrout.conduit.client.JSONRPCTransport") as mock_cls:
            mock_transport = AsyncMock()
            mock_transport.call_tool = AsyncMock(return_value={
                "result": "ok",
                "_datagrout": {
                    "receipt": {
                        "receipt_id": "rcp_mtls_test",
                        "timestamp": "2026-02-13T00:00:00Z",
                        "estimated_credits": 1.0,
                        "actual_credits": 0.9,
                        "net_credits": 0.9,
                        "savings": 0.1,
                        "savings_bonus": 0.0,
                        "breakdown": {},
                        "byok": {"enabled": False, "discount_applied": 0.0, "discount_rate": 0.0},
                        "balance_before": 100.0,
                        "balance_after": 99.1,
                    },
                    "credit_estimate": {
                        "estimated_total": 1.0,
                        "actual_total": 0.9,
                        "net_total": 0.9,
                        "breakdown": {},
                    },
                },
            })
            mock_transport.connect = AsyncMock()
            mock_transport.disconnect = AsyncMock()
            mock_cls.return_value = mock_transport

            client = Client(
                "https://gateway.datagrout.ai/servers/test/mcp",
                transport="jsonrpc",
                identity=identity,
            )

            async with client:
                result = await client.perform(tool="test-tool", args={})

            # Verify identity was passed to the transport constructor
            _, kwargs = mock_cls.call_args
            assert kwargs.get("identity") is identity

        # Verify receipt can be extracted with extract_meta
        meta = extract_meta(result)
        assert meta is not None
        assert meta.receipt.receipt_id == "rcp_mtls_test"
        assert meta.receipt.actual_credits == 0.9
