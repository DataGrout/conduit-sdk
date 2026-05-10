"""Tests for the autonomous agent onramp flow."""

from unittest.mock import AsyncMock, MagicMock, patch

import pytest
import httpx

from datagrout.conduit.onramp import (
    OnrampOptions,
    OnrampCredentials,
    OnrampError,
    _register,
    _exchange_token,
    register_only,
    register_and_exchange,
)


# ─── Fixtures ─────────────────────────────────────────────────────────────────

INIT_RESPONSE = {"session_token": "sess_abc123"}

COMPLETE_RESPONSE = {
    "client_id": "agt_abc123",
    "client_secret": "sk_xyz789",
    "token_url": "https://app.datagrout.ai/servers/abc/oauth/token",
    "mcp_url": "https://app.datagrout.ai/servers/abc/mcp",
    "rpc_url": "https://app.datagrout.ai/servers/abc/rpc",
    "scopes": ["mcp:read", "tools:call"],
    "expires_in": 2592000,
}

TOKEN_RESPONSE = {"access_token": "tok_live123"}

DEFAULT_OPTS = OnrampOptions(
    gateway="https://app.datagrout.ai",
    agent_name="test-agent",
    agent_type="claude-sonnet-4-6",
    intended_use="Testing.",
)


def make_http_client(responses: list) -> AsyncMock:
    """Build an httpx.AsyncClient mock that returns responses in order."""
    client = AsyncMock(spec=httpx.AsyncClient)
    mocks = []
    for data, status in responses:
        r = MagicMock(spec=httpx.Response)
        r.status_code = status
        r.is_success = status < 400
        r.json.return_value = data
        r.text = str(data)
        mocks.append(r)
    client.post.side_effect = mocks
    return client


# ─── OnrampOptions ─────────────────────────────────────────────────────────────

def test_onramp_options_required_fields():
    opts = OnrampOptions(gateway="https://app.datagrout.ai", agent_name="my-agent")
    assert opts.gateway == "https://app.datagrout.ai"
    assert opts.agent_name == "my-agent"
    assert opts.agent_type is None
    assert opts.intended_use is None
    assert opts.access_code is None


def test_onramp_options_all_fields():
    opts = OnrampOptions(
        gateway="https://app.datagrout.ai",
        agent_name="my-agent",
        agent_type="gpt-4o",
        intended_use="Data extraction.",
        access_code="code123",
    )
    assert opts.agent_type == "gpt-4o"
    assert opts.intended_use == "Data extraction."
    assert opts.access_code == "code123"


# ─── OnrampCredentials ────────────────────────────────────────────────────────

def test_onramp_credentials_fields():
    creds = OnrampCredentials(
        client_id="agt_abc",
        client_secret="sk_xyz",
        token_url="https://app.datagrout.ai/servers/abc/oauth/token",
        scopes=["mcp:read"],
        expires_in=2592000,
        mcp_url="https://app.datagrout.ai/servers/abc/mcp",
        rpc_url="https://app.datagrout.ai/servers/abc/rpc",
    )
    assert creds.client_id == "agt_abc"
    assert creds.mcp_url == "https://app.datagrout.ai/servers/abc/mcp"
    assert creds.expires_in == 2592000


def test_onramp_credentials_defaults():
    creds = OnrampCredentials(
        client_id="x", client_secret="y", token_url="https://example.com/token"
    )
    assert creds.scopes == []
    assert creds.expires_in == 0
    assert creds.mcp_url is None
    assert creds.rpc_url is None


# ─── _register ────────────────────────────────────────────────────────────────

@pytest.mark.asyncio
async def test_register_sends_init_then_complete():
    http = make_http_client([
        (INIT_RESPONSE, 200),
        (COMPLETE_RESPONSE, 200),
    ])

    creds = await _register(http, DEFAULT_OPTS)

    assert http.post.call_count == 2
    init_call, complete_call = http.post.call_args_list

    assert "onramp" in init_call.args[0]
    init_body = init_call.kwargs["json"]
    assert init_body["agent_name"] == "test-agent"
    assert init_body["agent_type"] == "claude-sonnet-4-6"

    assert "onramp/complete" in complete_call.args[0]
    assert "Bearer sess_abc123" in complete_call.kwargs["headers"]["Authorization"]

    assert creds.client_id == "agt_abc123"
    assert creds.client_secret == "sk_xyz789"
    assert creds.mcp_url == "https://app.datagrout.ai/servers/abc/mcp"
    assert creds.scopes == ["mcp:read", "tools:call"]


@pytest.mark.asyncio
async def test_register_omits_none_optional_fields():
    opts = OnrampOptions(gateway="https://app.datagrout.ai", agent_name="bare")
    http = make_http_client([
        (INIT_RESPONSE, 200),
        (COMPLETE_RESPONSE, 200),
    ])
    await _register(http, opts)
    init_body = http.post.call_args_list[0].kwargs["json"]
    assert "agent_type" not in init_body
    assert "intended_use" not in init_body
    assert "access_code" not in init_body


@pytest.mark.asyncio
async def test_register_strips_trailing_slash_from_gateway():
    opts = OnrampOptions(gateway="https://app.datagrout.ai/", agent_name="a")
    http = make_http_client([
        (INIT_RESPONSE, 200),
        (COMPLETE_RESPONSE, 200),
    ])
    await _register(http, opts)
    url = http.post.call_args_list[0].args[0]
    assert url == "https://app.datagrout.ai/onramp"


@pytest.mark.asyncio
async def test_register_raises_on_init_rejected():
    http = make_http_client([
        ({"error": "rate_limited"}, 429),
    ])
    with pytest.raises(OnrampError, match="429"):
        await _register(http, DEFAULT_OPTS)


@pytest.mark.asyncio
async def test_register_raises_on_complete_rejected():
    http = make_http_client([
        (INIT_RESPONSE, 200),
        ({"error": "expired"}, 410),
    ])
    with pytest.raises(OnrampError, match="410"):
        await _register(http, DEFAULT_OPTS)


@pytest.mark.asyncio
async def test_register_handles_absent_mcp_url():
    response = {**COMPLETE_RESPONSE}
    del response["mcp_url"]
    del response["rpc_url"]
    http = make_http_client([(INIT_RESPONSE, 200), (response, 200)])
    creds = await _register(http, DEFAULT_OPTS)
    assert creds.mcp_url is None
    assert creds.rpc_url is None


# ─── _exchange_token ──────────────────────────────────────────────────────────

@pytest.mark.asyncio
async def test_exchange_token_posts_client_credentials():
    creds = OnrampCredentials(
        client_id="agt_abc",
        client_secret="sk_xyz",
        token_url="https://app.datagrout.ai/servers/abc/oauth/token",
    )
    http = make_http_client([(TOKEN_RESPONSE, 200)])
    token = await _exchange_token(http, creds)
    assert token == "tok_live123"

    call = http.post.call_args
    assert call.args[0] == creds.token_url
    form_data = call.kwargs["data"]
    assert form_data["grant_type"] == "client_credentials"
    assert form_data["client_id"] == "agt_abc"
    assert form_data["client_secret"] == "sk_xyz"


@pytest.mark.asyncio
async def test_exchange_token_raises_on_failure():
    creds = OnrampCredentials(
        client_id="x", client_secret="y",
        token_url="https://app.datagrout.ai/servers/abc/oauth/token",
    )
    http = make_http_client([({}, 401)])
    with pytest.raises(OnrampError, match="401"):
        await _exchange_token(http, creds)


# ─── Public API ───────────────────────────────────────────────────────────────

@pytest.mark.asyncio
async def test_register_only_returns_credentials():
    with patch("datagrout.conduit.onramp.httpx.AsyncClient") as mock_cls:
        mock_ctx = AsyncMock()
        mock_cls.return_value.__aenter__ = AsyncMock(return_value=mock_ctx)
        mock_cls.return_value.__aexit__ = AsyncMock(return_value=False)

        init_resp = MagicMock(spec=httpx.Response)
        init_resp.is_success = True
        init_resp.json.return_value = INIT_RESPONSE

        complete_resp = MagicMock(spec=httpx.Response)
        complete_resp.is_success = True
        complete_resp.json.return_value = COMPLETE_RESPONSE

        mock_ctx.post.side_effect = [init_resp, complete_resp]

        creds = await register_only(DEFAULT_OPTS)
        assert creds.client_id == "agt_abc123"
        assert mock_ctx.post.call_count == 2


@pytest.mark.asyncio
async def test_register_and_exchange_returns_creds_and_token():
    with patch("datagrout.conduit.onramp.httpx.AsyncClient") as mock_cls:
        mock_ctx = AsyncMock()
        mock_cls.return_value.__aenter__ = AsyncMock(return_value=mock_ctx)
        mock_cls.return_value.__aexit__ = AsyncMock(return_value=False)

        def make_resp(data, success=True):
            r = MagicMock(spec=httpx.Response)
            r.is_success = success
            r.status_code = 200 if success else 401
            r.json.return_value = data
            r.text = str(data)
            return r

        mock_ctx.post.side_effect = [
            make_resp(INIT_RESPONSE),
            make_resp(COMPLETE_RESPONSE),
            make_resp(TOKEN_RESPONSE),
        ]

        creds, token = await register_and_exchange(DEFAULT_OPTS)
        assert creds.client_id == "agt_abc123"
        assert token == "tok_live123"
        assert mock_ctx.post.call_count == 3
