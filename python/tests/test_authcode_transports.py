"""The HTTP transports must authenticate with an authorization-code grant.

Both transports resolve a provider on the way out and invalidate it on a 401,
which is the whole reason an expired access token recovers by refreshing
instead of surfacing to the caller as an auth failure. Covered for both, since
the two build their headers and handle 401 independently.
"""

from __future__ import annotations

import time
from typing import Any, List

import httpx
import pytest

from datagrout.conduit.authcode import AuthCodeProvider, Grant
from datagrout.conduit.transports.jsonrpc_transport import JSONRPCTransport
from datagrout.conduit.transports.mcp_transport import MCPTransport

TOKEN_ENDPOINT = "https://gateway.datagrout.ai/oauth/token"
ENDPOINT = "https://example.com/mcp"


def _grant(*, expires_in: int = 3600, refresh: str | None = "rt") -> Grant:
    return Grant(
        access_token="user_access_token",
        client_id="client_abc",
        token_endpoint=TOKEN_ENDPOINT,
        refresh_token=refresh,
        expires_at=int(time.time()) + expires_in,
    )


def _mock_client(handler: Any) -> httpx.AsyncClient:
    # The transports post to a relative path against the client's base URL, so
    # the stand-in client needs the same base URL the real one is built with.
    return httpx.AsyncClient(base_url=ENDPOINT, transport=httpx.MockTransport(handler))


# ─── header building ─────────────────────────────────────────────────────────


@pytest.mark.parametrize("transport_cls", [JSONRPCTransport, MCPTransport])
async def test_authorization_code_becomes_a_bearer_header(transport_cls: Any):
    transport = transport_cls(
        ENDPOINT,
        auth={"authorization_code": _grant()},
    )
    # The provider needs the transport's client only if it has to refresh; a
    # live grant is served straight from memory.
    transport._client = _mock_client(lambda r: httpx.Response(200, json={}))

    headers = await transport._build_auth_headers()
    assert headers["Authorization"] == "Bearer user_access_token"


@pytest.mark.parametrize("transport_cls", [JSONRPCTransport, MCPTransport])
async def test_a_grant_dict_is_accepted(transport_cls: Any):
    # A grant loaded straight from JSON, without constructing the dataclass.
    transport = transport_cls(
        ENDPOINT,
        auth={"authorization_code": _grant().to_dict()},
    )
    transport._client = _mock_client(lambda r: httpx.Response(200, json={}))

    headers = await transport._build_auth_headers()
    assert headers["Authorization"] == "Bearer user_access_token"


@pytest.mark.parametrize("transport_cls", [JSONRPCTransport, MCPTransport])
async def test_a_caller_owned_provider_is_used_as_is(transport_cls: Any):
    provider = AuthCodeProvider(_grant())
    transport = transport_cls(
        ENDPOINT,
        auth={"authorization_code": provider},
    )
    assert transport._authcode is provider


@pytest.mark.parametrize("transport_cls", [JSONRPCTransport, MCPTransport])
async def test_client_credentials_still_wins_when_both_are_given(transport_cls: Any):
    # Not a configuration to recommend, but the precedence must be defined
    # rather than depend on dict ordering.
    transport = transport_cls(
        ENDPOINT,
        auth={
            "client_credentials": {
                "client_id": "id",
                "client_secret": "secret",
                "token_endpoint": TOKEN_ENDPOINT,
            },
            "authorization_code": _grant(),
        },
    )
    transport._client = _mock_client(
        lambda r: httpx.Response(200, json={"access_token": "machine", "expires_in": 3600})
    )

    headers = await transport._build_auth_headers()
    assert headers["Authorization"] == "Bearer machine"


@pytest.mark.parametrize("transport_cls", [JSONRPCTransport, MCPTransport])
async def test_an_expired_grant_is_refreshed_before_the_request(transport_cls: Any):
    def handler(request: httpx.Request) -> httpx.Response:
        assert str(request.url) == TOKEN_ENDPOINT
        return httpx.Response(200, json={"access_token": "refreshed", "expires_in": 3600})

    transport = transport_cls(
        ENDPOINT,
        auth={"authorization_code": _grant(expires_in=-10)},
    )
    transport._client = _mock_client(handler)

    headers = await transport._build_auth_headers()
    assert headers["Authorization"] == "Bearer refreshed"


# ─── 401 recovery ────────────────────────────────────────────────────────────
#
# The two transports carry independent copies of this path, so both are driven.
# They differ only in the name of the entry point.


async def _send(transport: Any) -> Any:
    if isinstance(transport, JSONRPCTransport):
        return await transport._call_with_retry("tools/list", {}, is_retry=False)
    return await transport._send_with_retry("tools/list", {}, is_retry=False)


@pytest.mark.parametrize("transport_cls", [JSONRPCTransport, MCPTransport])
async def test_a_401_refreshes_the_grant_and_retries_once(transport_cls: Any):
    calls: List[str] = []

    def handler(request: httpx.Request) -> httpx.Response:
        if str(request.url) == TOKEN_ENDPOINT:
            calls.append("token")
            return httpx.Response(200, json={"access_token": "refreshed", "expires_in": 3600})

        auth = request.headers.get("authorization")
        calls.append(f"rpc:{auth}")
        if auth == "Bearer user_access_token":
            # Stale access token — what a rotated or revoked one looks like.
            return httpx.Response(401, json={"error": "unauthorized"})
        return httpx.Response(200, json={"jsonrpc": "2.0", "id": 1, "result": {"ok": True}})

    transport = transport_cls(ENDPOINT, auth={"authorization_code": _grant()})
    transport._client = _mock_client(handler)

    assert await _send(transport) == {"ok": True}

    # First attempt with the stale token, a refresh, then one retry — and no
    # third attempt, so a genuinely bad credential cannot loop.
    assert calls == [
        "rpc:Bearer user_access_token",
        "token",
        "rpc:Bearer refreshed",
    ]


@pytest.mark.parametrize("transport_cls", [JSONRPCTransport, MCPTransport])
async def test_a_401_that_survives_a_refresh_raises(transport_cls: Any):
    from datagrout.conduit.errors import AuthError

    attempts = 0

    def handler(request: httpx.Request) -> httpx.Response:
        nonlocal attempts
        if str(request.url) == TOKEN_ENDPOINT:
            return httpx.Response(200, json={"access_token": "still_bad", "expires_in": 3600})
        attempts += 1
        return httpx.Response(401, json={"error": "unauthorized"})

    transport = transport_cls(ENDPOINT, auth={"authorization_code": _grant()})
    transport._client = _mock_client(handler)

    with pytest.raises(AuthError):
        await _send(transport)
    # Exactly one retry: a revoked grant fails fast instead of recursing.
    assert attempts == 2


@pytest.mark.parametrize("transport_cls", [JSONRPCTransport, MCPTransport])
async def test_a_401_without_any_provider_raises_immediately(transport_cls: Any):
    from datagrout.conduit.errors import AuthError

    attempts = 0

    def handler(request: httpx.Request) -> httpx.Response:
        nonlocal attempts
        attempts += 1
        return httpx.Response(401, json={})

    transport = transport_cls(ENDPOINT, auth={"bearer": "static"})
    transport._client = _mock_client(handler)

    # Nothing to refresh, so there is nothing to retry.
    with pytest.raises(AuthError):
        await _send(transport)
    assert attempts == 1


@pytest.mark.parametrize("transport_cls", [JSONRPCTransport, MCPTransport])
async def test_a_401_refreshes_a_client_credentials_token_too(transport_cls: Any):
    # The machine grant had this behaviour first; adding the user grant must
    # not have displaced it.
    calls: List[str] = []
    tokens = 0

    def handler(request: httpx.Request) -> httpx.Response:
        nonlocal tokens
        if str(request.url) == TOKEN_ENDPOINT:
            tokens += 1
            calls.append("token")
            return httpx.Response(
                200,
                json={"access_token": f"machine_{tokens}", "expires_in": 3600},
            )
        auth = request.headers.get("authorization")
        calls.append(f"rpc:{auth}")
        if auth == "Bearer machine_1":
            return httpx.Response(401, json={})
        return httpx.Response(200, json={"jsonrpc": "2.0", "id": 1, "result": {"ok": True}})

    transport = transport_cls(
        ENDPOINT,
        auth={
            "client_credentials": {
                "client_id": "id",
                "client_secret": "secret",
                "token_endpoint": TOKEN_ENDPOINT,
            }
        },
    )
    transport._client = _mock_client(handler)

    assert await _send(transport) == {"ok": True}
    assert calls == [
        "token",
        "rpc:Bearer machine_1",
        "token",
        "rpc:Bearer machine_2",
    ]
