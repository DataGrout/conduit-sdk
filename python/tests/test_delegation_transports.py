"""Every transport must authenticate with a delegated token.

The two HTTP transports resolve the provider on the way out and invalidate it
on a 401 — the whole reason an expired delegated token recovers by exchanging
again instead of surfacing to the caller as an auth failure. Covered for both,
since the two build their headers and handle 401 independently.

The WebSocket case is separate and load-bearing: fetching a token is
asynchronous while building upgrade headers is not, so the bearer has to be
resolved *before* the handshake. These drive the real ``connect()`` and read
the headers handed to ``websockets``, because that is exactly the wiring a
stubbed transport skips.
"""

from __future__ import annotations

import time
from typing import Any, Dict, List, Optional
from unittest.mock import AsyncMock, patch
from urllib.parse import parse_qsl

import httpx
import pytest

from datagrout.conduit.authcode import Grant
from datagrout.conduit.delegation import (
    GRANT_TYPE,
    DelegatedProvider,
    DelegationRequest,
    TokenSource,
)
from datagrout.conduit.errors import AuthError, InvalidConfigError
from datagrout.conduit.transports.jsonrpc_transport import JSONRPCTransport
from datagrout.conduit.transports.mcp_transport import MCPTransport
from datagrout.conduit.transports.ws_transport import WsTransport

ENDPOINT = "https://example.com/mcp"
TOKEN_ENDPOINT = "https://gateway.datagrout.ai/oauth/token"

HTTP_TRANSPORTS = [JSONRPCTransport, MCPTransport]


def _provider() -> DelegatedProvider:
    return DelegatedProvider(
        DelegationRequest(
            token_endpoint=TOKEN_ENDPOINT,
            client_id="agent_client",
            client_secret="agent_secret",
            resource="https://gateway.datagrout.ai/connect",
        ),
        subject=TokenSource.static_token("user_at"),
        actor=TokenSource.static_token("agent_at"),
    )


def _exchange_body(access_token: str = "delegated_1") -> Dict[str, Any]:
    return {
        "access_token": access_token,
        "issued_token_type": "urn:ietf:params:oauth:token-type:access_token",
        "token_type": "Bearer",
        "expires_in": 900,
    }


def _mock_client(handler: Any) -> httpx.AsyncClient:
    # The JSONRPC transport posts to a relative path against the client's base
    # URL, so the stand-in client needs the same base URL the real one gets.
    return httpx.AsyncClient(base_url=ENDPOINT, transport=httpx.MockTransport(handler))


async def _send(transport: Any) -> Any:
    if isinstance(transport, JSONRPCTransport):
        return await transport._call_with_retry("tools/list", {}, is_retry=False)
    return await transport._send_with_retry("tools/list", {}, is_retry=False)


# ─── header building ─────────────────────────────────────────────────────────


@pytest.mark.parametrize("transport_cls", HTTP_TRANSPORTS)
async def test_a_delegated_token_becomes_a_bearer_header(transport_cls: Any):
    forms: List[Dict[str, str]] = []

    def handler(request: httpx.Request) -> httpx.Response:
        assert str(request.url) == TOKEN_ENDPOINT
        forms.append(dict(parse_qsl(request.content.decode())))
        return httpx.Response(200, json=_exchange_body())

    transport = transport_cls(ENDPOINT, auth={"delegation": _provider()})
    transport._client = _mock_client(handler)

    headers = await transport._build_auth_headers()
    assert headers["Authorization"] == "Bearer delegated_1"
    # The exchange really carried both tokens and the resource.
    assert forms[0]["grant_type"] == GRANT_TYPE
    assert forms[0]["subject_token"] == "user_at"
    assert forms[0]["actor_token"] == "agent_at"
    assert forms[0]["resource"] == "https://gateway.datagrout.ai/connect"


@pytest.mark.parametrize("transport_cls", HTTP_TRANSPORTS)
async def test_a_caller_owned_provider_is_used_as_is(transport_cls: Any):
    provider = _provider()
    transport = transport_cls(ENDPOINT, auth={"delegation": provider})
    assert transport._delegation is provider


@pytest.mark.parametrize("transport_cls", HTTP_TRANSPORTS)
async def test_the_delegated_token_is_exchanged_once_across_requests(transport_cls: Any):
    exchanges = 0

    def handler(request: httpx.Request) -> httpx.Response:
        nonlocal exchanges
        if str(request.url) == TOKEN_ENDPOINT:
            exchanges += 1
            return httpx.Response(200, json=_exchange_body())
        return httpx.Response(200, json={"jsonrpc": "2.0", "id": 1, "result": {"ok": True}})

    transport = transport_cls(ENDPOINT, auth={"delegation": _provider()})
    transport._client = _mock_client(handler)

    assert await _send(transport) == {"ok": True}
    assert await _send(transport) == {"ok": True}
    # The provider caches; a live token is not re-exchanged per request.
    assert exchanges == 1


@pytest.mark.parametrize("transport_cls", HTTP_TRANSPORTS)
async def test_delegation_wins_over_the_two_plain_grants(transport_cls: Any):
    # Not a configuration to recommend, but the precedence must be defined
    # rather than depend on dict ordering — and it must not silently drop the
    # user's identity by falling back to the agent's machine token.
    def handler(request: httpx.Request) -> httpx.Response:
        if str(request.url) == TOKEN_ENDPOINT:
            body = dict(parse_qsl(request.content.decode()))
            if body["grant_type"] == GRANT_TYPE:
                return httpx.Response(200, json=_exchange_body())
            return httpx.Response(200, json={"access_token": "machine", "expires_in": 3600})
        return httpx.Response(200, json={})

    transport = transport_cls(
        ENDPOINT,
        auth={
            "client_credentials": {
                "client_id": "id",
                "client_secret": "secret",
                "token_endpoint": TOKEN_ENDPOINT,
            },
            "authorization_code": Grant(
                access_token="user_access_token",
                client_id="client_abc",
                token_endpoint=TOKEN_ENDPOINT,
                expires_at=int(time.time()) + 3600,
            ),
            "delegation": _provider(),
        },
    )
    transport._client = _mock_client(handler)

    headers = await transport._build_auth_headers()
    assert headers["Authorization"] == "Bearer delegated_1"


@pytest.mark.parametrize("transport_cls", HTTP_TRANSPORTS)
def test_a_delegation_entry_that_is_not_a_provider_is_rejected(transport_cls: Any):
    # There is no serialized form of a delegation — it is a live pair of token
    # sources — so a dict is a configuration mistake, not something to coerce.
    with pytest.raises(InvalidConfigError):
        transport_cls(ENDPOINT, auth={"delegation": {"client_id": "agent_client"}})


# ─── 401 recovery ────────────────────────────────────────────────────────────


@pytest.mark.parametrize("transport_cls", HTTP_TRANSPORTS)
async def test_a_401_re_exchanges_the_delegated_token_and_retries_once(transport_cls: Any):
    calls: List[str] = []
    exchanges = 0

    def handler(request: httpx.Request) -> httpx.Response:
        nonlocal exchanges
        if str(request.url) == TOKEN_ENDPOINT:
            exchanges += 1
            calls.append("exchange")
            return httpx.Response(200, json=_exchange_body(f"delegated_{exchanges}"))

        auth = request.headers.get("authorization")
        calls.append(f"rpc:{auth}")
        if auth == "Bearer delegated_1":
            # A stale delegated token — what a revoked or rotated one looks like.
            return httpx.Response(401, json={"error": "unauthorized"})
        return httpx.Response(200, json={"jsonrpc": "2.0", "id": 1, "result": {"ok": True}})

    transport = transport_cls(ENDPOINT, auth={"delegation": _provider()})
    transport._client = _mock_client(handler)

    assert await _send(transport) == {"ok": True}

    # One exchange, the stale attempt, a re-exchange, then one retry — and no
    # third attempt, so a genuinely bad credential cannot loop.
    assert calls == [
        "exchange",
        "rpc:Bearer delegated_1",
        "exchange",
        "rpc:Bearer delegated_2",
    ]


@pytest.mark.parametrize("transport_cls", HTTP_TRANSPORTS)
async def test_a_401_that_survives_a_re_exchange_raises(transport_cls: Any):
    attempts = 0

    def handler(request: httpx.Request) -> httpx.Response:
        nonlocal attempts
        if str(request.url) == TOKEN_ENDPOINT:
            return httpx.Response(200, json=_exchange_body("still_bad"))
        attempts += 1
        return httpx.Response(401, json={"error": "unauthorized"})

    transport = transport_cls(ENDPOINT, auth={"delegation": _provider()})
    transport._client = _mock_client(handler)

    with pytest.raises(AuthError):
        await _send(transport)
    # Exactly one retry: a revoked delegation fails fast instead of recursing.
    assert attempts == 2


# ─── the WebSocket upgrade ───────────────────────────────────────────────────


async def _mock_ws() -> Any:
    ws = AsyncMock()
    ws.send = AsyncMock()
    ws.close = AsyncMock()

    async def _aiter(self_):  # pragma: no cover - never iterated in these tests
        if False:
            yield ""

    ws.__aiter__ = _aiter
    return ws


async def _connect_capturing(
    transport: WsTransport, token_response: Optional[Dict[str, Any]] = None
) -> Dict[str, Any]:
    """Run the real ``connect()`` and return the kwargs passed to websockets."""
    captured: Dict[str, Any] = {}

    async def fake_connect(url: str, **kwargs: Any) -> Any:
        captured.update(kwargs)
        captured["url"] = url
        return await _mock_ws()

    token_requests: List[httpx.Request] = []

    def token_handler(request: httpx.Request) -> httpx.Response:
        token_requests.append(request)
        return httpx.Response(200, json=token_response or {})

    # The transport creates its own httpx client for token fetches; hand it a
    # mock-transport one so nothing leaves the process.
    real_init = httpx.AsyncClient.__init__

    def patched_init(self: httpx.AsyncClient, *args: Any, **kwargs: Any) -> None:
        kwargs.setdefault("transport", httpx.MockTransport(token_handler))
        real_init(self, *args, **kwargs)

    with patch(
        "datagrout.conduit.transports.ws_transport.ws_connect",
        side_effect=fake_connect,
    ):
        httpx.AsyncClient.__init__ = patched_init  # type: ignore[method-assign]
        try:
            await transport.connect()
        finally:
            httpx.AsyncClient.__init__ = real_init  # type: ignore[method-assign]

    await transport.disconnect()
    captured["_token_requests"] = token_requests
    return captured


async def test_the_ws_upgrade_carries_the_exchanged_bearer():
    transport = WsTransport(
        "wss://gateway.datagrout.ai/ws",
        auth={"delegation": _provider()},
    )
    captured = await _connect_capturing(transport, token_response=_exchange_body())

    assert captured["additional_headers"]["Authorization"] == "Bearer delegated_1"

    # The exchange happened before the handshake, and carried both tokens.
    requests = captured["_token_requests"]
    assert len(requests) == 1
    assert str(requests[0].url) == TOKEN_ENDPOINT
    form = dict(parse_qsl(requests[0].content.decode()))
    assert form["grant_type"] == GRANT_TYPE
    assert form["subject_token"] == "user_at"
    assert form["actor_token"] == "agent_at"


async def test_the_ws_upgrade_prefers_a_delegated_bearer_over_a_machine_token():
    transport = WsTransport(
        "wss://gateway.datagrout.ai/ws",
        auth={
            "client_credentials": {
                "client_id": "id",
                "client_secret": "secret",
                "token_endpoint": TOKEN_ENDPOINT,
            },
            "delegation": _provider(),
        },
    )
    captured = await _connect_capturing(transport, token_response=_exchange_body())

    assert captured["additional_headers"]["Authorization"] == "Bearer delegated_1"
    # Only the exchange was made; the machine grant was never fetched.
    assert len(captured["_token_requests"]) == 1


async def test_the_ws_transport_closes_its_own_token_client():
    transport = WsTransport(
        "wss://gateway.datagrout.ai/ws",
        auth={"delegation": _provider()},
    )
    await _connect_capturing(transport, token_response=_exchange_body())
    # The transport created that client, so it must not outlive the transport.
    assert transport._token_http is None
