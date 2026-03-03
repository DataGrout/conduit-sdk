"""Tests for DataGrout Conduit client."""

import pytest
import httpx
from unittest.mock import AsyncMock, MagicMock, patch

from datagrout.conduit import Client, RateLimitError, extract_meta
from datagrout.conduit.transports.jsonrpc_transport import (
    RateLimitError,
    _parse_rate_limit_status,
)
from datagrout.conduit.types import (
    RateLimitPerHour,
    RateLimitStatus,
)

# ─── Real server _datagrout receipt fixture (matches DG gateway output) ─────────

RECEIPT_META = {
    "_datagrout": {
        "receipt": {
            "receipt_id": "rcp_123",
            "timestamp": "2026-02-13T00:00:00Z",
            "estimated_credits": 5.0,
            "actual_credits": 4.5,
            "net_credits": 4.5,
            "savings": 0.5,
            "savings_bonus": 0.0,
            "breakdown": {"base": 4.5},
            "byok": {"enabled": False, "discount_applied": 0.0, "discount_rate": 0.0},
            "balance_before": 1000.0,
            "balance_after": 995.5,
        },
        "credit_estimate": {
            "estimated_total": 5.0,
            "actual_total": 4.5,
            "net_total": 4.5,
            "breakdown": {"base": 4.5},
        },
    }
}


@pytest.fixture
def mock_transport():
    transport = AsyncMock()
    transport.connect = AsyncMock()
    transport.disconnect = AsyncMock()
    transport.list_tools = AsyncMock(return_value=[])
    transport.call_tool = AsyncMock(return_value={})
    return transport


# ─── Client initialisation ────────────────────────────────────────────────────


@pytest.mark.asyncio
async def test_client_initialization():
    client = Client("https://gateway.datagrout.ai/servers/test/mcp")
    assert client.url == "https://gateway.datagrout.ai/servers/test/mcp"
    assert client.use_intelligent_interface is True

    client2 = Client("https://my-mcp-server.example.com/mcp")
    assert client2.use_intelligent_interface is False


@pytest.mark.asyncio
async def test_dg_url_detection():
    dg_client = Client("https://gateway.datagrout.ai/servers/test/mcp")
    assert dg_client._is_dg is True

    other_client = Client("https://my-mcp-server.example.com/mcp")
    assert other_client._is_dg is False


# ─── _ensure_initialized ──────────────────────────────────────────────────────


@pytest.mark.asyncio
async def test_ensure_initialized_raises_before_connect():
    """All public methods should raise RuntimeError before connect() is called."""
    with patch("datagrout.conduit.client.MCPTransport") as mock_cls:
        mock_transport = AsyncMock()
        mock_cls.return_value = mock_transport

        client = Client("https://gateway.datagrout.ai/servers/test/mcp")

        with pytest.raises(RuntimeError, match="not initialized"):
            await client.list_tools()
        with pytest.raises(RuntimeError, match="not initialized"):
            await client.call_tool("t", {})
        with pytest.raises(RuntimeError, match="not initialized"):
            await client.list_resources()
        with pytest.raises(RuntimeError, match="not initialized"):
            await client.read_resource("uri://x")
        with pytest.raises(RuntimeError, match="not initialized"):
            await client.list_prompts()
        with pytest.raises(RuntimeError, match="not initialized"):
            await client.get_prompt("p")


@pytest.mark.asyncio
async def test_ensure_initialized_ok_after_connect():
    """After connect(), methods should not raise RuntimeError."""
    with patch("datagrout.conduit.client.MCPTransport") as mock_cls:
        mock_transport = AsyncMock()
        mock_transport.connect = AsyncMock()
        mock_transport.list_tools = AsyncMock(return_value=[])
        mock_cls.return_value = mock_transport

        client = Client("https://my-mcp-server.example.com/mcp")
        await client.connect()
        tools = await client.list_tools()
        assert tools == []


@pytest.mark.asyncio
async def test_ensure_initialized_raises_after_disconnect():
    """After disconnect(), methods should raise again."""
    with patch("datagrout.conduit.client.MCPTransport") as mock_cls:
        mock_transport = AsyncMock()
        mock_transport.connect = AsyncMock()
        mock_transport.disconnect = AsyncMock()
        mock_cls.return_value = mock_transport

        client = Client("https://my-mcp-server.example.com/mcp")
        await client.connect()
        await client.disconnect()

        with pytest.raises(RuntimeError, match="not initialized"):
            await client.list_tools()


# ─── _send_with_retry ─────────────────────────────────────────────────────────


@pytest.mark.asyncio
async def test_send_with_retry_retries_on_not_initialized():
    """_send_with_retry should reconnect and retry on 'not initialized' errors."""
    with patch("datagrout.conduit.client.MCPTransport") as mock_cls:
        call_count = 0

        async def _call_tool(name, args, **kw):
            nonlocal call_count
            call_count += 1
            if call_count == 1:
                raise Exception("Server session not initialized")
            return {"ok": True}

        mock_transport = AsyncMock()
        mock_transport.connect = AsyncMock()
        mock_transport.call_tool = AsyncMock(side_effect=_call_tool)
        mock_cls.return_value = mock_transport

        client = Client("https://gateway.datagrout.ai/servers/test/mcp")
        await client.connect()

        result = await client.call_tool("test-tool", {})
        assert result == {"ok": True}
        assert call_count == 2
        assert mock_transport.connect.call_count == 2  # initial + retry


@pytest.mark.asyncio
async def test_send_with_retry_retries_on_code_minus_32002():
    """_send_with_retry should reconnect on error code -32002."""
    with patch("datagrout.conduit.client.MCPTransport") as mock_cls:
        call_count = 0

        async def _call_tool(name, args, **kw):
            nonlocal call_count
            call_count += 1
            if call_count == 1:
                err = Exception("session expired")
                err.code = -32002  # type: ignore[attr-defined]
                raise err
            return {"ok": True}

        mock_transport = AsyncMock()
        mock_transport.connect = AsyncMock()
        mock_transport.call_tool = AsyncMock(side_effect=_call_tool)
        mock_cls.return_value = mock_transport

        client = Client("https://gateway.datagrout.ai/servers/test/mcp")
        await client.connect()

        result = await client.call_tool("test-tool", {})
        assert result == {"ok": True}
        assert call_count == 2


@pytest.mark.asyncio
async def test_send_with_retry_does_not_retry_unrelated_errors():
    """Unrelated errors should propagate without retry."""
    with patch("datagrout.conduit.client.MCPTransport") as mock_cls:
        mock_transport = AsyncMock()
        mock_transport.connect = AsyncMock()
        mock_transport.call_tool = AsyncMock(side_effect=ValueError("bad input"))
        mock_cls.return_value = mock_transport

        client = Client("https://gateway.datagrout.ai/servers/test/mcp")
        await client.connect()

        with pytest.raises(ValueError, match="bad input"):
            await client.call_tool("test-tool", {})

        assert mock_transport.connect.call_count == 1  # only initial connect


# ─── list_tools — intelligent interface filter ────────────────────────────────


@pytest.mark.asyncio
async def test_list_tools_no_filter_by_default():
    """Without use_intelligent_interface, all tools are returned unchanged."""
    with patch("datagrout.conduit.client.MCPTransport") as mock_cls:
        mock_transport = AsyncMock()
        mock_transport.connect = AsyncMock()
        mock_transport.disconnect = AsyncMock()
        mock_transport.list_tools = AsyncMock(return_value=[
            {"name": "salesforce@v1/get_lead@v1", "description": "Get a lead"},
            {"name": "arbiter_check_policy", "description": "Check policy"},
        ])
        mock_cls.return_value = mock_transport

        client = Client(
            "https://gateway.datagrout.ai/servers/test/mcp",
            use_intelligent_interface=False,
        )
        async with client:
            tools = await client.list_tools()

    assert len(tools) == 2
    names = [t["name"] for t in tools]
    assert "salesforce@v1/get_lead@v1" in names
    assert "arbiter_check_policy" in names


@pytest.mark.asyncio
async def test_list_tools_filters_integration_tools_when_intelligent_interface():
    """use_intelligent_interface=True removes tools whose name contains '@'."""
    with patch("datagrout.conduit.client.MCPTransport") as mock_cls:
        mock_transport = AsyncMock()
        mock_transport.connect = AsyncMock()
        mock_transport.disconnect = AsyncMock()
        mock_transport.list_tools = AsyncMock(return_value=[
            {"name": "salesforce@v1/get_lead@v1", "description": "Integration tool"},
            {"name": "arbiter_check_policy", "description": "DG tool"},
            {"name": "governor_enable", "description": "DG tool"},
            {"name": "hubspot@v1/create_contact@v1", "description": "Integration tool"},
        ])
        mock_cls.return_value = mock_transport

        client = Client(
            "https://gateway.datagrout.ai/servers/test/mcp",
            use_intelligent_interface=True,
        )
        async with client:
            tools = await client.list_tools()

    names = [t["name"] for t in tools]
    assert "salesforce@v1/get_lead@v1" not in names
    assert "hubspot@v1/create_contact@v1" not in names
    assert "arbiter_check_policy" in names
    assert "governor_enable" in names


# ─── call_tool uses standard MCP path ────────────────────────────────────────


@pytest.mark.asyncio
async def test_call_tool_uses_standard_path():
    """call_tool should go through _transport.call_tool directly, not discovery.perform."""
    with patch("datagrout.conduit.client.MCPTransport") as mock_cls:
        mock_transport = AsyncMock()
        mock_transport.connect = AsyncMock()
        mock_transport.disconnect = AsyncMock()
        mock_transport.call_tool = AsyncMock(return_value={"success": True})
        mock_cls.return_value = mock_transport

        client = Client("https://gateway.datagrout.ai/servers/test/mcp")
        async with client:
            await client.call_tool("test-tool", {"arg": "value"})

        call_args = mock_transport.call_tool.call_args
        assert call_args[0][0] == "test-tool"
        assert call_args[0][1] == {"arg": "value"}


@pytest.mark.asyncio
async def test_perform_routes_through_discovery_perform():
    """perform() should route through discovery.perform for DG tracking."""
    with patch("datagrout.conduit.client.MCPTransport") as mock_cls:
        mock_transport = AsyncMock()
        mock_transport.connect = AsyncMock()
        mock_transport.disconnect = AsyncMock()
        mock_transport.call_tool = AsyncMock(return_value={"success": True})
        mock_cls.return_value = mock_transport

        client = Client("https://gateway.datagrout.ai/servers/test/mcp")
        async with client:
            await client.perform(tool="test-tool", args={"arg": "value"})

        call_args = mock_transport.call_tool.call_args
        assert call_args[0][0] == "data-grout/discovery.perform"


# ─── Receipt — extract_meta ───────────────────────────────────────────────────


def test_extract_meta_parses_receipt():
    """extract_meta() pulls the _meta block from a tool result dict."""
    result = {"value": 42, **RECEIPT_META}
    meta = extract_meta(result)

    assert meta is not None
    assert meta.receipt.receipt_id == "rcp_123"
    assert meta.receipt.actual_credits == 4.5
    assert meta.receipt.net_credits == 4.5
    assert meta.receipt.balance_before == 1000.0
    assert meta.receipt.balance_after == 995.5
    assert meta.receipt.byok.enabled is False


def test_extract_meta_returns_none_when_no_meta():
    """extract_meta() returns None for results without _meta (non-DG servers)."""
    result = {"value": 42}
    assert extract_meta(result) is None


def test_extract_meta_credit_estimate():
    """extract_meta() also parses the credit_estimate block."""
    result = {"value": 42, **RECEIPT_META}
    meta = extract_meta(result)

    assert meta is not None
    assert meta.credit_estimate is not None
    assert meta.credit_estimate.estimated_total == 5.0
    assert meta.credit_estimate.net_total == 4.5


@pytest.mark.asyncio
async def test_perform_result_contains_embedded_meta():
    """perform() returns the raw result dict; callers use extract_meta() for receipt."""
    with patch("datagrout.conduit.client.MCPTransport") as mock_cls:
        mock_transport = AsyncMock()
        mock_transport.connect = AsyncMock()
        tool_result = {"result": "success", **RECEIPT_META}
        mock_transport.call_tool = AsyncMock(return_value=tool_result)
        mock_cls.return_value = mock_transport

        client = Client("https://gateway.datagrout.ai/servers/test/mcp")
        async with client:
            result = await client.perform(tool="test-tool", args={})

    meta = extract_meta(result)
    assert meta is not None
    assert meta.receipt.receipt_id == "rcp_123"


# ─── Discover ────────────────────────────────────────────────────────────────


@pytest.mark.asyncio
async def test_discover():
    with patch("datagrout.conduit.client.MCPTransport") as mock_cls:
        mock_transport = AsyncMock()
        mock_transport.connect = AsyncMock()
        mock_transport.disconnect = AsyncMock()
        mock_transport.call_tool = AsyncMock(return_value={
            "query_used": "test query",
            "results": [],
            "total": 0,
            "limit": 10,
        })
        mock_cls.return_value = mock_transport

        client = Client("https://gateway.datagrout.ai/servers/test/mcp")
        async with client:
            result = await client.discover(query="test query", limit=10)

    assert result.query_used == "test query"
    assert result.total == 0


# ─── Guide session ───────────────────────────────────────────────────────────


@pytest.mark.asyncio
async def test_guided_session():
    with patch("datagrout.conduit.client.MCPTransport") as mock_cls:
        mock_transport = AsyncMock()
        mock_transport.connect = AsyncMock()
        mock_transport.disconnect = AsyncMock()
        mock_transport.call_tool = AsyncMock(return_value={
            "session_id": "guide_abc123",
            "step": "1",
            "message": "Choose a path",
            "status": "ready",
            "options": [{"id": "1.1", "label": "Option 1", "cost": 2.5, "viable": True}],
            "path_taken": [],
            "total_cost": 0.0,
        })
        mock_cls.return_value = mock_transport

        client = Client("https://gateway.datagrout.ai/servers/test/mcp")
        async with client:
            session = await client.guide(goal="test goal")

    assert session.session_id == "guide_abc123"
    assert session.status == "ready"
    assert len(session.options) == 1


# ─── Non-DG warning ──────────────────────────────────────────────────────────


@pytest.mark.asyncio
async def test_dg_method_warns_on_non_dg_url(recwarn):
    """DG-specific methods emit a one-time UserWarning on non-DG URLs."""
    with patch("datagrout.conduit.client.MCPTransport") as mock_cls:
        mock_transport = AsyncMock()
        mock_transport.connect = AsyncMock()
        mock_transport.disconnect = AsyncMock()
        mock_transport.call_tool = AsyncMock(return_value={
            "query_used": "q", "results": [], "total": 0, "limit": 5
        })
        mock_cls.return_value = mock_transport

        client = Client("https://my-custom-mcp.example.com/mcp")
        async with client:
            await client.discover(query="test")

    warnings = [w for w in recwarn.list if issubclass(w.category, UserWarning)]
    assert len(warnings) == 1
    assert "DataGrout-specific" in str(warnings[0].message)


@pytest.mark.asyncio
async def test_dg_method_no_warning_on_dg_url(recwarn):
    """DG-specific methods do NOT warn when connected to a DG URL."""
    with patch("datagrout.conduit.client.MCPTransport") as mock_cls:
        mock_transport = AsyncMock()
        mock_transport.connect = AsyncMock()
        mock_transport.disconnect = AsyncMock()
        mock_transport.call_tool = AsyncMock(return_value={
            "query_used": "q", "results": [], "total": 0, "limit": 5
        })
        mock_cls.return_value = mock_transport

        client = Client("https://gateway.datagrout.ai/servers/test/mcp")
        async with client:
            await client.discover(query="test")

    dg_warnings = [w for w in recwarn.list if issubclass(w.category, UserWarning)
                   and "DataGrout-specific" in str(w.message)]
    assert len(dg_warnings) == 0


# ─── Rate limiting ────────────────────────────────────────────────────────────


def make_httpx_response(status_code: int, headers: dict) -> httpx.Response:
    return httpx.Response(status_code, headers=headers, content=b"")


class TestRateLimitStatus:
    def test_unlimited_factory(self):
        s = RateLimitStatus.unlimited()
        assert s.limit == "unlimited"
        assert s.used == 0
        assert not s.is_limited
        assert s.remaining is None

    def test_from_headers_capped(self):
        s = RateLimitStatus.from_headers(used=10, limit_str="50")
        assert s.limit == RateLimitPerHour(per_hour=50)
        assert s.used == 10
        assert s.remaining == 40
        assert not s.is_limited

    def test_from_headers_at_cap(self):
        s = RateLimitStatus.from_headers(used=50, limit_str="50")
        assert s.is_limited
        assert s.remaining == 0

    def test_from_headers_unlimited_string(self):
        s = RateLimitStatus.from_headers(used=5, limit_str="unlimited")
        assert s.limit == "unlimited"
        assert not s.is_limited
        assert s.remaining is None


class TestParseRateLimitStatus:
    def test_parses_capped_headers(self):
        resp = make_httpx_response(
            429, {"X-RateLimit-Used": "10", "X-RateLimit-Limit": "50"}
        )
        status = _parse_rate_limit_status(resp)
        assert status.used == 10
        assert status.limit == RateLimitPerHour(per_hour=50)
        assert status.remaining == 40

    def test_parses_unlimited_header(self):
        resp = make_httpx_response(
            429, {"X-RateLimit-Used": "0", "X-RateLimit-Limit": "unlimited"}
        )
        status = _parse_rate_limit_status(resp)
        assert status.limit == "unlimited"

    def test_defaults_when_headers_missing(self):
        resp = make_httpx_response(200, {})
        status = _parse_rate_limit_status(resp)
        assert status.used == 0
        assert status.limit == RateLimitPerHour(per_hour=50)


class TestRateLimitError:
    def test_error_message_for_capped(self):
        status = RateLimitStatus.from_headers(used=50, limit_str="50")
        err = RateLimitError(status)
        assert "50" in str(err)
        assert "50/hour" in str(err)
        assert isinstance(err, Exception)

    def test_error_message_for_unlimited(self):
        err = RateLimitError(RateLimitStatus.unlimited())
        assert "unlimited" in str(err)

    def test_status_attached(self):
        status = RateLimitStatus.from_headers(used=50, limit_str="50")
        err = RateLimitError(status)
        assert err.status is status

    @pytest.mark.asyncio
    async def test_transport_raises_on_429(self):
        from datagrout.conduit.transports.jsonrpc_transport import JSONRPCTransport

        transport = JSONRPCTransport("https://gateway.datagrout.ai/servers/test/mcp")

        mock_response = make_httpx_response(
            429, {"X-RateLimit-Used": "50", "X-RateLimit-Limit": "50"}
        )
        mock_client = MagicMock()
        mock_client.post = AsyncMock(return_value=mock_response)
        transport._client = mock_client

        with pytest.raises(RateLimitError) as exc_info:
            await transport.list_tools()

        assert exc_info.value.status.is_limited
        assert exc_info.value.status.used == 50


# ─── list_tools pagination ───────────────────────────────────────────────────


@pytest.mark.asyncio
async def test_list_tools_pagination():
    """list_tools should follow nextCursor to collect all pages."""
    with patch("datagrout.conduit.client.MCPTransport") as mock_cls:
        mock_transport = AsyncMock()
        mock_transport.connect = AsyncMock()
        mock_transport.disconnect = AsyncMock()
        page_count = 0

        async def paginated_list_tools(**kwargs):
            nonlocal page_count
            page_count += 1
            if page_count == 1:
                return {
                    "tools": [{"name": "tool_a"}, {"name": "tool_b"}],
                    "nextCursor": "page2",
                }
            else:
                return {
                    "tools": [{"name": "tool_c"}],
                }

        mock_transport.list_tools = AsyncMock(side_effect=paginated_list_tools)
        mock_cls.return_value = mock_transport

        client = Client(
            "https://my-mcp-server.example.com/mcp",
            use_intelligent_interface=False,
        )
        async with client:
            tools = await client.list_tools()

    assert len(tools) == 3
    names = [t["name"] for t in tools]
    assert names == ["tool_a", "tool_b", "tool_c"]


@pytest.mark.asyncio
async def test_list_tools_pagination_with_plain_list():
    """When transport returns a plain list (no pagination), it should work."""
    with patch("datagrout.conduit.client.MCPTransport") as mock_cls:
        mock_transport = AsyncMock()
        mock_transport.connect = AsyncMock()
        mock_transport.disconnect = AsyncMock()
        mock_transport.list_tools = AsyncMock(
            return_value=[{"name": "tool_a"}, {"name": "tool_b"}]
        )
        mock_cls.return_value = mock_transport

        client = Client(
            "https://my-mcp-server.example.com/mcp",
            use_intelligent_interface=False,
        )
        async with client:
            tools = await client.list_tools()

    assert len(tools) == 2


# ─── Explicit connect/disconnect ─────────────────────────────────────────────


@pytest.mark.asyncio
async def test_explicit_connect_disconnect():
    """Client supports explicit connect()/disconnect() outside of context manager."""
    with patch("datagrout.conduit.client.MCPTransport") as mock_cls:
        mock_transport = AsyncMock()
        mock_transport.connect = AsyncMock()
        mock_transport.disconnect = AsyncMock()
        mock_transport.list_tools = AsyncMock(return_value=[])
        mock_cls.return_value = mock_transport

        client = Client("https://my-mcp-server.example.com/mcp")
        await client.connect()
        assert client._initialized is True

        tools = await client.list_tools()
        assert tools == []

        await client.disconnect()
        assert client._initialized is False

    mock_transport.connect.assert_called_once()
    mock_transport.disconnect.assert_called_once()


# ─── MCPTransport auth headers ───────────────────────────────────────────────


class TestMCPTransportAuth:
    def test_bearer_auth_header(self):
        import asyncio
        from datagrout.conduit.transports.mcp_transport import MCPTransport

        transport = MCPTransport(
            "https://example.com/mcp",
            auth={"bearer": "tok_test"},
        )
        headers = asyncio.run(transport._build_auth_headers())
        assert headers["Authorization"] == "Bearer tok_test"

    def test_api_key_header(self):
        import asyncio
        from datagrout.conduit.transports.mcp_transport import MCPTransport

        transport = MCPTransport(
            "https://example.com/mcp",
            auth={"api_key": "key_test"},
        )
        headers = asyncio.run(transport._build_auth_headers())
        assert headers["X-API-Key"] == "key_test"

    def test_basic_auth_header(self):
        import asyncio
        import base64
        from datagrout.conduit.transports.mcp_transport import MCPTransport

        transport = MCPTransport(
            "https://example.com/mcp",
            auth={"basic": {"username": "user", "password": "pass"}},
        )
        headers = asyncio.run(transport._build_auth_headers())
        expected = base64.b64encode(b"user:pass").decode()
        assert headers["Authorization"] == f"Basic {expected}"

    def test_no_auth_returns_empty(self):
        import asyncio
        from datagrout.conduit.transports.mcp_transport import MCPTransport

        transport = MCPTransport("https://example.com/mcp")
        headers = asyncio.run(transport._build_auth_headers())
        assert headers == {}

    def test_identity_stored(self):
        from datagrout.conduit.transports.mcp_transport import MCPTransport

        identity = MagicMock()
        identity.needs_rotation = MagicMock(return_value=False)
        transport = MCPTransport(
            "https://example.com/mcp",
            identity=identity,
        )
        assert transport.identity is identity


# ─── prism_focus wire protocol ────────────────────────────────────────────────


@pytest.mark.asyncio
async def test_prism_focus_sends_correct_params():
    """prism_focus() must send source_type/target_type, NOT lens."""
    with patch("datagrout.conduit.client.MCPTransport") as mock_cls:
        mock_transport = AsyncMock()
        mock_transport.connect = AsyncMock()
        mock_transport.disconnect = AsyncMock()
        mock_transport.call_tool = AsyncMock(return_value={"result": "ok"})
        mock_cls.return_value = mock_transport

        client = Client("https://gateway.datagrout.ai/servers/test/mcp")
        async with client:
            await client.prism_focus(
                data={"name": "Acme"},
                source_type="crm.lead@1",
                target_type="billing.customer@1",
            )

    call_args = mock_transport.call_tool.call_args
    assert call_args[0][0] == "data-grout/prism.focus"
    sent_params = call_args[0][1]
    assert sent_params["source_type"] == "crm.lead@1"
    assert sent_params["target_type"] == "billing.customer@1"
    assert sent_params["data"] == {"name": "Acme"}
    assert "lens" not in sent_params


@pytest.mark.asyncio
async def test_prism_focus_optional_params():
    """prism_focus() includes optional params only when provided."""
    with patch("datagrout.conduit.client.MCPTransport") as mock_cls:
        mock_transport = AsyncMock()
        mock_transport.connect = AsyncMock()
        mock_transport.call_tool = AsyncMock(return_value={})
        mock_cls.return_value = mock_transport

        client = Client("https://gateway.datagrout.ai/servers/test/mcp")
        async with client:
            await client.prism_focus(
                data={"x": 1},
                source_type="a@1",
                target_type="b@1",
                source_annotations={"key": "v"},
                context="sales context",
            )

    sent_params = mock_transport.call_tool.call_args[0][1]
    assert sent_params["source_annotations"] == {"key": "v"}
    assert sent_params["context"] == "sales context"
    assert "target_annotations" not in sent_params


# ─── plan / refract / chart ───────────────────────────────────────────────────


@pytest.mark.asyncio
async def test_plan_sends_correct_method():
    """plan() routes to data-grout/discovery.plan."""
    with patch("datagrout.conduit.client.MCPTransport") as mock_cls:
        mock_transport = AsyncMock()
        mock_transport.connect = AsyncMock()
        mock_transport.call_tool = AsyncMock(return_value={"steps": []})
        mock_cls.return_value = mock_transport

        client = Client("https://gateway.datagrout.ai/servers/test/mcp")
        async with client:
            await client.plan(goal="send invoice to all VIP customers")

    call_args = mock_transport.call_tool.call_args
    assert call_args[0][0] == "data-grout/discovery.plan"
    assert call_args[0][1]["goal"] == "send invoice to all VIP customers"


@pytest.mark.asyncio
async def test_plan_with_query_param():
    """plan() accepts query instead of goal."""
    with patch("datagrout.conduit.client.MCPTransport") as mock_cls:
        mock_transport = AsyncMock()
        mock_transport.connect = AsyncMock()
        mock_transport.call_tool = AsyncMock(return_value={})
        mock_cls.return_value = mock_transport

        client = Client("https://gateway.datagrout.ai/servers/test/mcp")
        async with client:
            await client.plan(query="invoice VIP", k=5)

    sent_params = mock_transport.call_tool.call_args[0][1]
    assert sent_params["query"] == "invoice VIP"
    assert sent_params["k"] == 5
    assert "goal" not in sent_params


@pytest.mark.asyncio
async def test_plan_requires_goal_or_query():
    """plan() raises ValueError when neither goal nor query is given."""
    with patch("datagrout.conduit.client.MCPTransport") as mock_cls:
        mock_transport = AsyncMock()
        mock_transport.connect = AsyncMock()
        mock_cls.return_value = mock_transport

        client = Client("https://gateway.datagrout.ai/servers/test/mcp")
        async with client:
            with pytest.raises(ValueError, match="goal.*query"):
                await client.plan()


@pytest.mark.asyncio
async def test_refract_sends_correct_method():
    """refract() routes to data-grout/prism.refract."""
    with patch("datagrout.conduit.client.MCPTransport") as mock_cls:
        mock_transport = AsyncMock()
        mock_transport.connect = AsyncMock()
        mock_transport.call_tool = AsyncMock(return_value={"analysis": "ok"})
        mock_cls.return_value = mock_transport

        client = Client("https://gateway.datagrout.ai/servers/test/mcp")
        async with client:
            await client.refract(goal="summarise revenue", payload={"q1": 100})

    call_args = mock_transport.call_tool.call_args
    assert call_args[0][0] == "data-grout/prism.refract"
    sent_params = call_args[0][1]
    assert sent_params["goal"] == "summarise revenue"
    assert sent_params["payload"] == {"q1": 100}
    assert sent_params["verbose"] is False
    assert sent_params["chart"] is False


@pytest.mark.asyncio
async def test_chart_sends_correct_method():
    """chart() routes to data-grout/prism.chart."""
    with patch("datagrout.conduit.client.MCPTransport") as mock_cls:
        mock_transport = AsyncMock()
        mock_transport.connect = AsyncMock()
        mock_transport.call_tool = AsyncMock(return_value={"url": "https://..."})
        mock_cls.return_value = mock_transport

        client = Client("https://gateway.datagrout.ai/servers/test/mcp")
        async with client:
            await client.chart(
                goal="bar chart of monthly revenue",
                payload={"jan": 10, "feb": 20},
                chart_type="bar",
                title="Revenue",
            )

    call_args = mock_transport.call_tool.call_args
    assert call_args[0][0] == "data-grout/prism.chart"
    sent_params = call_args[0][1]
    assert sent_params["goal"] == "bar chart of monthly revenue"
    assert sent_params["payload"] == {"jan": 10, "feb": 20}
    assert sent_params["chart_type"] == "bar"
    assert sent_params["title"] == "Revenue"


# ─── Logic cell method names ──────────────────────────────────────────────────


@pytest.mark.asyncio
async def test_remember_sends_correct_method():
    """remember() routes to data-grout/logic.remember."""
    with patch("datagrout.conduit.client.MCPTransport") as mock_cls:
        mock_transport = AsyncMock()
        mock_transport.connect = AsyncMock()
        mock_transport.call_tool = AsyncMock(return_value={"handles": [], "count": 1})
        mock_cls.return_value = mock_transport

        client = Client("https://gateway.datagrout.ai/servers/test/mcp")
        async with client:
            await client.remember("Acme is a VIP customer", tag="crm")

    call_args = mock_transport.call_tool.call_args
    assert call_args[0][0] == "data-grout/logic.remember"
    assert call_args[0][1]["statement"] == "Acme is a VIP customer"
    assert call_args[0][1]["tag"] == "crm"


@pytest.mark.asyncio
async def test_query_cell_sends_correct_method():
    """query_cell() routes to data-grout/logic.query."""
    with patch("datagrout.conduit.client.MCPTransport") as mock_cls:
        mock_transport = AsyncMock()
        mock_transport.connect = AsyncMock()
        mock_transport.call_tool = AsyncMock(return_value={"results": [], "total": 0})
        mock_cls.return_value = mock_transport

        client = Client("https://gateway.datagrout.ai/servers/test/mcp")
        async with client:
            await client.query_cell("who are our VIP customers?")

    call_args = mock_transport.call_tool.call_args
    assert call_args[0][0] == "data-grout/logic.query"
    assert call_args[0][1]["question"] == "who are our VIP customers?"


@pytest.mark.asyncio
async def test_forget_sends_correct_method():
    """forget() routes to data-grout/logic.forget."""
    with patch("datagrout.conduit.client.MCPTransport") as mock_cls:
        mock_transport = AsyncMock()
        mock_transport.connect = AsyncMock()
        mock_transport.call_tool = AsyncMock(return_value={"retracted": 1})
        mock_cls.return_value = mock_transport

        client = Client("https://gateway.datagrout.ai/servers/test/mcp")
        async with client:
            await client.forget(handles=["fact_abc123"])

    call_args = mock_transport.call_tool.call_args
    assert call_args[0][0] == "data-grout/logic.forget"
    assert call_args[0][1]["handles"] == ["fact_abc123"]


@pytest.mark.asyncio
async def test_constrain_sends_correct_method():
    """constrain() routes to data-grout/logic.constrain."""
    with patch("datagrout.conduit.client.MCPTransport") as mock_cls:
        mock_transport = AsyncMock()
        mock_transport.connect = AsyncMock()
        mock_transport.call_tool = AsyncMock(return_value={"handle": "c_1"})
        mock_cls.return_value = mock_transport

        client = Client("https://gateway.datagrout.ai/servers/test/mcp")
        async with client:
            await client.constrain("VIP customers have ARR > $500K")

    call_args = mock_transport.call_tool.call_args
    assert call_args[0][0] == "data-grout/logic.constrain"
    assert call_args[0][1]["rule"] == "VIP customers have ARR > $500K"


@pytest.mark.asyncio
async def test_reflect_sends_correct_method():
    """reflect() routes to data-grout/logic.reflect."""
    with patch("datagrout.conduit.client.MCPTransport") as mock_cls:
        mock_transport = AsyncMock()
        mock_transport.connect = AsyncMock()
        mock_transport.call_tool = AsyncMock(return_value={"summary": {}})
        mock_cls.return_value = mock_transport

        client = Client("https://gateway.datagrout.ai/servers/test/mcp")
        async with client:
            await client.reflect()

    call_args = mock_transport.call_tool.call_args
    assert call_args[0][0] == "data-grout/logic.reflect"


# ─── dg() generic hook ───────────────────────────────────────────────────────


@pytest.mark.asyncio
async def test_dg_sends_correct_method():
    """dg('prism.render', {}) routes to data-grout/prism.render."""
    with patch("datagrout.conduit.client.MCPTransport") as mock_cls:
        mock_transport = AsyncMock()
        mock_transport.connect = AsyncMock()
        mock_transport.call_tool = AsyncMock(return_value={"html": "<p>ok</p>"})
        mock_cls.return_value = mock_transport

        client = Client("https://gateway.datagrout.ai/servers/test/mcp")
        async with client:
            result = await client.dg("prism.render", {"payload": {"x": 1}, "goal": "summary"})

    call_args = mock_transport.call_tool.call_args
    assert call_args[0][0] == "data-grout/prism.render"
    assert call_args[0][1] == {"payload": {"x": 1}, "goal": "summary"}
    assert result == {"html": "<p>ok</p>"}


@pytest.mark.asyncio
async def test_dg_with_no_params():
    """dg() defaults to empty params dict when none given."""
    with patch("datagrout.conduit.client.MCPTransport") as mock_cls:
        mock_transport = AsyncMock()
        mock_transport.connect = AsyncMock()
        mock_transport.call_tool = AsyncMock(return_value={})
        mock_cls.return_value = mock_transport

        client = Client("https://gateway.datagrout.ai/servers/test/mcp")
        async with client:
            await client.dg("logic.reflect")

    call_args = mock_transport.call_tool.call_args
    assert call_args[0][0] == "data-grout/logic.reflect"
    assert call_args[0][1] == {}


@pytest.mark.asyncio
async def test_dg_requires_initialization():
    """dg() raises RuntimeError before connect()."""
    with patch("datagrout.conduit.client.MCPTransport") as mock_cls:
        mock_transport = AsyncMock()
        mock_cls.return_value = mock_transport

        client = Client("https://gateway.datagrout.ai/servers/test/mcp")
        with pytest.raises(RuntimeError, match="not initialized"):
            await client.dg("prism.render", {})


# ─── Parity fix tests ────────────────────────────────────────────────────────


@pytest.mark.asyncio
async def test_max_retries_configurable():
    """Client accepts max_retries parameter."""
    client = Client("https://gateway.datagrout.ai/servers/test/mcp", max_retries=5)
    assert client._max_retries == 5


@pytest.mark.asyncio
async def test_max_retries_default():
    """Default max_retries is 3."""
    client = Client("https://gateway.datagrout.ai/servers/test/mcp")
    assert client._max_retries == 3


@pytest.mark.asyncio
async def test_retry_exhausts_max_retries():
    """After max_retries, the error is raised."""
    with patch("datagrout.conduit.client.MCPTransport") as mock_cls:
        call_count = 0

        async def _always_fail(name, args, **kw):
            nonlocal call_count
            call_count += 1
            err = Exception("Server session not initialized")
            err.code = -32002  # type: ignore[attr-defined]
            raise err

        mock_transport = AsyncMock()
        mock_transport.connect = AsyncMock()
        mock_transport.call_tool = AsyncMock(side_effect=_always_fail)
        mock_cls.return_value = mock_transport

        client = Client("https://gateway.datagrout.ai/servers/test/mcp", max_retries=2)
        await client.connect()

        with pytest.raises(Exception, match="not initialized"):
            await client.call_tool("test-tool", {})

        assert call_count == 3  # initial + 2 retries


@pytest.mark.asyncio
async def test_discover_sends_min_score():
    """discover() sends min_score (snake_case) to match server wire protocol."""
    with patch("datagrout.conduit.client.MCPTransport") as mock_cls:
        mock_transport = AsyncMock()
        mock_transport.connect = AsyncMock()
        mock_transport.call_tool = AsyncMock(return_value={
            "query_used": "q", "results": [], "total": 0, "limit": 5,
        })
        mock_cls.return_value = mock_transport

        client = Client("https://gateway.datagrout.ai/servers/test/mcp")
        async with client:
            await client.discover(query="test", min_score=0.5)

    sent_params = mock_transport.call_tool.call_args[0][1]
    assert sent_params["min_score"] == 0.5
    assert "minScore" not in sent_params
