"""Tests for the OAuth 2.1 token provider."""

import asyncio
import time
from unittest.mock import AsyncMock, MagicMock, patch

import pytest
import httpx

from datagrout.conduit.oauth import OAuthTokenProvider, derive_token_endpoint


# ─── derive_token_endpoint ────────────────────────────────────────────────────


def test_derive_strips_mcp():
    assert (
        derive_token_endpoint("https://app.datagrout.ai/servers/abc/mcp")
        == "https://app.datagrout.ai/servers/abc/oauth/token"
    )


def test_derive_strips_mcp_with_suffix():
    assert (
        derive_token_endpoint("https://app.datagrout.ai/servers/abc/mcp/something")
        == "https://app.datagrout.ai/servers/abc/oauth/token"
    )


def test_derive_url_without_mcp():
    assert (
        derive_token_endpoint("https://app.datagrout.ai/servers/abc")
        == "https://app.datagrout.ai/servers/abc/oauth/token"
    )


def test_derive_url_with_trailing_slash():
    assert (
        derive_token_endpoint("https://app.datagrout.ai/servers/abc/")
        == "https://app.datagrout.ai/servers/abc/oauth/token"
    )


# ─── OAuthTokenProvider ───────────────────────────────────────────────────────

TOKEN_RESPONSE = {
    "access_token": "eyJtest.token.here",
    "token_type": "Bearer",
    "expires_in": 3600,
    "scope": "mcp",
}


def make_provider(scope: str | None = "mcp") -> OAuthTokenProvider:
    return OAuthTokenProvider(
        client_id="test_id",
        client_secret="test_secret",
        token_endpoint="https://app.datagrout.ai/servers/abc/oauth/token",
        scope=scope,
    )


def mock_http_client(response_data: dict, status_code: int = 200) -> httpx.AsyncClient:
    """Build a mock httpx.AsyncClient that returns `response_data`."""
    mock_response = MagicMock(spec=httpx.Response)
    mock_response.status_code = status_code
    mock_response.json.return_value = response_data
    mock_response.text = str(response_data)
    mock_response.headers = {}

    if status_code >= 400:
        mock_response.raise_for_status.side_effect = httpx.HTTPStatusError(
            message=f"HTTP {status_code}",
            request=MagicMock(),
            response=mock_response,
        )
    else:
        mock_response.raise_for_status.return_value = None

    client = AsyncMock(spec=httpx.AsyncClient)
    client.post.return_value = mock_response
    return client


@pytest.mark.asyncio
async def test_fetches_token_on_first_call():
    provider = make_provider()
    client = mock_http_client(TOKEN_RESPONSE)

    token = await provider.get_token(client)

    assert token == "eyJtest.token.here"
    client.post.assert_called_once()

    call_kwargs = client.post.call_args
    assert "data" in call_kwargs.kwargs
    data = call_kwargs.kwargs["data"]
    assert data["grant_type"] == "client_credentials"
    assert data["client_id"] == "test_id"
    assert data["client_secret"] == "test_secret"
    assert data["scope"] == "mcp"


@pytest.mark.asyncio
async def test_returns_cached_token_on_second_call():
    provider = make_provider()
    client = mock_http_client(TOKEN_RESPONSE)

    await provider.get_token(client)
    token = await provider.get_token(client)

    assert token == "eyJtest.token.here"
    # Only one HTTP call despite two `get_token` calls.
    client.post.assert_called_once()


@pytest.mark.asyncio
async def test_fetches_new_token_after_invalidate():
    provider = make_provider()
    client = mock_http_client(TOKEN_RESPONSE)

    await provider.get_token(client)
    provider.invalidate()
    await provider.get_token(client)

    assert client.post.call_count == 2


@pytest.mark.asyncio
async def test_raises_on_http_error():
    provider = make_provider()
    client = mock_http_client({"error": "invalid_client"}, status_code=401)

    with pytest.raises(RuntimeError, match="401"):
        await provider.get_token(client)


@pytest.mark.asyncio
async def test_omits_scope_when_none():
    provider = make_provider(scope=None)
    client = mock_http_client(TOKEN_RESPONSE)

    await provider.get_token(client)

    data = client.post.call_args.kwargs["data"]
    assert "scope" not in data


@pytest.mark.asyncio
async def test_concurrent_calls_share_one_fetch():
    provider = make_provider()

    # We'll use an asyncio.Event to control when the first fetch completes.
    fetch_done = asyncio.Event()

    async def slow_post(*_args, **_kwargs):
        await fetch_done.wait()
        mock_response = MagicMock(spec=httpx.Response)
        mock_response.status_code = 200
        mock_response.json.return_value = TOKEN_RESPONSE
        mock_response.raise_for_status.return_value = None
        return mock_response

    client = AsyncMock(spec=httpx.AsyncClient)
    client.post.side_effect = slow_post

    async def get():
        return await provider.get_token(client)

    # Start two concurrent getToken calls.
    t1 = asyncio.create_task(get())
    t2 = asyncio.create_task(get())

    # Let them both hit the lock, then release the slow fetch.
    await asyncio.sleep(0)
    fetch_done.set()

    r1, r2 = await asyncio.gather(t1, t2)
    assert r1 == r2 == "eyJtest.token.here"

    # fetch should have been called exactly once.
    assert client.post.call_count == 1
