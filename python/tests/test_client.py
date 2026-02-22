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
    # Default: intelligent interface off (same as Rust spec)
    assert client.use_intelligent_interface is False


@pytest.mark.asyncio
async def test_dg_url_detection():
    dg_client = Client("https://gateway.datagrout.ai/servers/test/mcp")
    assert dg_client._is_dg is True

    other_client = Client("https://my-mcp-server.example.com/mcp")
    assert other_client._is_dg is False


# ─── list_tools — intelligent interface filter ────────────────────────────────


@pytest.mark.asyncio
async def test_list_tools_no_filter_by_default():
    """Without use_intelligent_interface, all tools are returned unchanged."""
    with patch("datagrout.conduit.client.JSONRPCTransport") as mock_cls:
        mock_transport = AsyncMock()
        mock_transport.connect = AsyncMock()
        mock_transport.list_tools = AsyncMock(return_value=[
            {"name": "salesforce@v1/get_lead@v1", "description": "Get a lead"},
            {"name": "arbiter_check_policy", "description": "Check policy"},
        ])
        mock_cls.return_value = mock_transport

        client = Client(
            "https://gateway.datagrout.ai/servers/test/mcp",
            use_intelligent_interface=False,
        )
        tools = await client.list_tools()

    assert len(tools) == 2
    names = [t["name"] for t in tools]
    assert "salesforce@v1/get_lead@v1" in names
    assert "arbiter_check_policy" in names


@pytest.mark.asyncio
async def test_list_tools_filters_integration_tools_when_intelligent_interface():
    """use_intelligent_interface=True removes tools whose name contains '@'."""
    with patch("datagrout.conduit.client.JSONRPCTransport") as mock_cls:
        mock_transport = AsyncMock()
        mock_transport.connect = AsyncMock()
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
        tools = await client.list_tools()

    names = [t["name"] for t in tools]
    assert "salesforce@v1/get_lead@v1" not in names
    assert "hubspot@v1/create_contact@v1" not in names
    assert "arbiter_check_policy" in names
    assert "governor_enable" in names


# ─── call_tool routes through perform ────────────────────────────────────────


@pytest.mark.asyncio
async def test_call_tool_routes_through_perform():
    with patch("datagrout.conduit.client.JSONRPCTransport") as mock_cls:
        mock_transport = AsyncMock()
        mock_transport.connect = AsyncMock()
        mock_transport.call_tool = AsyncMock(return_value={"success": True})
        mock_cls.return_value = mock_transport

        client = Client("https://gateway.datagrout.ai/servers/test/mcp")
        async with client:
            await client.call_tool("test-tool", {"arg": "value"})

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
    with patch("datagrout.conduit.client.JSONRPCTransport") as mock_cls:
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
    with patch("datagrout.conduit.client.JSONRPCTransport") as mock_cls:
        mock_transport = AsyncMock()
        mock_transport.connect = AsyncMock()
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
    with patch("datagrout.conduit.client.JSONRPCTransport") as mock_cls:
        mock_transport = AsyncMock()
        mock_transport.connect = AsyncMock()
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
    with patch("datagrout.conduit.client.JSONRPCTransport") as mock_cls:
        mock_transport = AsyncMock()
        mock_transport.connect = AsyncMock()
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
    with patch("datagrout.conduit.client.JSONRPCTransport") as mock_cls:
        mock_transport = AsyncMock()
        mock_transport.connect = AsyncMock()
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
