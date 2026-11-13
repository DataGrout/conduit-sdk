"""The WS transport against a real ``wss://`` server that demands a client
certificate.

``_build_ssl_context`` called ``cert_pem_bytes()`` / ``key_pem_bytes()``,
which ``ConduitIdentity`` has never had, so a ``wss://`` connection with an
identity raised ``AttributeError`` before the handshake. Nothing exercised the
path: every other WS test connects without an identity. This one completes a
real mTLS handshake with the shared fixtures in ``testdata/mtls``.
"""

from __future__ import annotations

import ssl
from pathlib import Path
from typing import Any, Dict, List

import pytest
from websockets.asyncio.server import serve

from datagrout.conduit.identity import ConduitIdentity
from datagrout.conduit.transports.ws_transport import WsTransport

FIXTURES = Path(__file__).resolve().parents[2] / "testdata" / "mtls"


def _fixture(name: str) -> str:
    return (FIXTURES / name).read_text()


def _server_context() -> ssl.SSLContext:
    ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    ctx.load_cert_chain(FIXTURES / "server.pem", FIXTURES / "server-key.pem")
    ctx.load_verify_locations(FIXTURES / "ca.pem")
    ctx.verify_mode = ssl.CERT_REQUIRED
    return ctx


def _identity() -> ConduitIdentity:
    return ConduitIdentity.from_pem(
        _fixture("client.pem"), _fixture("client-key.pem"), _fixture("ca.pem")
    )


async def _start(seen: List[Dict[str, Any]]):
    async def handler(conn):
        peer = conn.transport.get_extra_info("peercert") or {}
        subject = dict(item for rdn in peer.get("subject", ()) for item in rdn)
        seen.append(
            {
                "peer_cn": subject.get("commonName"),
                "authorization": conn.request.headers.get("Authorization"),
            }
        )
        await conn.wait_closed()

    server = await serve(handler, "127.0.0.1", 0, ssl=_server_context())
    port = server.sockets[0].getsockname()[1]
    return server, f"wss://localhost:{port}/ws"


async def test_presents_the_client_certificate_and_the_upgrade_headers():
    seen: List[Dict[str, Any]] = []
    server, url = await _start(seen)
    try:
        t = WsTransport(url, auth={"bearer": "loopback"}, identity=_identity())
        await t.connect()
        await t.disconnect()
    finally:
        server.close()
        await server.wait_closed()

    assert seen == [{"peer_cn": "conduit-sdk test client", "authorization": "Bearer loopback"}]


async def test_cannot_connect_without_an_identity_when_the_server_demands_one():
    seen: List[Dict[str, Any]] = []
    server, url = await _start(seen)
    try:
        t = WsTransport(url, auth={"bearer": "loopback"})
        with pytest.raises(Exception):
            await t.connect()
    finally:
        server.close()
        await server.wait_closed()

    assert seen == []


def test_the_identity_ca_is_added_to_the_system_roots():
    # A DataGrout identity carries the DataGrout CA while the gateway presents
    # a public certificate, so the CA must widen the trust store, not replace it.
    ctx = WsTransport("wss://example.invalid/ws", identity=_identity())._build_ssl_context()
    baseline = ssl.create_default_context().cert_store_stats()["x509_ca"]

    assert ctx.verify_mode == ssl.CERT_REQUIRED
    assert ctx.check_hostname
    assert ctx.cert_store_stats()["x509_ca"] == baseline + 1
