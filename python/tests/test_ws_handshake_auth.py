"""The WebSocket upgrade must carry the resolved OAuth bearer.

Fetching a token is asynchronous while building request headers is not, so
before this was fixed a provider-backed token could never reach the upgrade: an
OAuth client authenticated over WS only if it also happened to present an mTLS
identity. These tests drive the real ``connect()`` and read the headers handed
to ``websockets``, because the bug lived in exactly the wiring that a stubbed
transport skips.
"""

from __future__ import annotations

from typing import Any, Dict, Optional
from unittest.mock import AsyncMock, patch

import httpx

from datagrout.conduit.authcode import AuthCodeProvider, Grant
from datagrout.conduit.transports.ws_transport import WsTransport


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

    token_requests: list[httpx.Request] = []

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


def _live_grant() -> Grant:
    import time

    return Grant(
        access_token="user_access_token",
        client_id="client_abc",
        token_endpoint="https://gateway.datagrout.ai/oauth/token",
        refresh_token="rt",
        # Far future, so the provider serves it without refreshing.
        expires_at=int(time.time()) + 3600,
    )


async def test_upgrade_carries_an_authorization_code_bearer():
    transport = WsTransport(
        "wss://gateway.datagrout.ai/ws",
        auth={"authorization_code": _live_grant()},
    )
    captured = await _connect_capturing(transport)

    headers = captured["additional_headers"]
    assert headers["Authorization"] == "Bearer user_access_token"


async def test_upgrade_accepts_a_grant_dict():
    # A grant loaded straight from JSON, without constructing the dataclass.
    transport = WsTransport(
        "wss://gateway.datagrout.ai/ws",
        auth={"authorization_code": _live_grant().to_dict()},
    )
    captured = await _connect_capturing(transport)
    assert captured["additional_headers"]["Authorization"] == "Bearer user_access_token"


async def test_upgrade_accepts_a_caller_owned_provider():
    provider = AuthCodeProvider(_live_grant())
    transport = WsTransport(
        "wss://gateway.datagrout.ai/ws",
        auth={"authorization_code": provider},
    )
    captured = await _connect_capturing(transport)
    assert captured["additional_headers"]["Authorization"] == "Bearer user_access_token"


async def test_upgrade_carries_a_client_credentials_bearer():
    # The grant that shipped first and never authenticated over WS.
    transport = WsTransport(
        "wss://gateway.datagrout.ai/ws",
        auth={
            "client_credentials": {
                "client_id": "id",
                "client_secret": "secret",
                "token_endpoint": "https://gateway.datagrout.ai/oauth/token",
            }
        },
    )
    captured = await _connect_capturing(
        transport,
        token_response={
            "access_token": "machine_token",
            "token_type": "Bearer",
            "expires_in": 3600,
        },
    )

    assert captured["additional_headers"]["Authorization"] == "Bearer machine_token"


async def test_token_endpoint_is_derived_as_http_not_ws():
    transport = WsTransport(
        "wss://app.datagrout.ai/servers/abc/mcp",
        auth={"client_credentials": {"client_id": "id", "client_secret": "secret"}},
    )
    captured = await _connect_capturing(
        transport, token_response={"access_token": "derived", "expires_in": 3600}
    )

    requests = captured["_token_requests"]
    assert requests, "the provider should have fetched a token"
    # A ws:// token endpoint is nonsense; the scheme has to map across.
    assert str(requests[0].url) == "https://app.datagrout.ai/servers/abc/oauth/token"


async def test_ws_scheme_maps_to_http_for_the_token_endpoint():
    transport = WsTransport(
        "ws://localhost:4000/servers/abc/mcp",
        auth={"client_credentials": {"client_id": "id", "client_secret": "secret"}},
    )
    captured = await _connect_capturing(
        transport, token_response={"access_token": "derived", "expires_in": 3600}
    )
    assert (
        str(captured["_token_requests"][0].url) == "http://localhost:4000/servers/abc/oauth/token"
    )


async def test_upgrade_still_carries_a_static_bearer():
    transport = WsTransport("wss://gateway.datagrout.ai/ws", auth={"bearer": "static"})
    captured = await _connect_capturing(transport)
    assert captured["additional_headers"]["Authorization"] == "Bearer static"


async def test_upgrade_sends_no_authorization_header_without_auth():
    transport = WsTransport("wss://gateway.datagrout.ai/ws")
    captured = await _connect_capturing(transport)
    assert "Authorization" not in captured["additional_headers"]


async def test_disconnect_closes_the_token_client():
    transport = WsTransport(
        "wss://gateway.datagrout.ai/ws",
        auth={"authorization_code": _live_grant()},
    )
    await _connect_capturing(transport)
    # The transport created that client, so it must not outlive the transport.
    assert transport._token_http is None
