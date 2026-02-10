"""Tests for DataGrout Conduit client."""

import pytest
from unittest.mock import AsyncMock, MagicMock, patch

from datagrout.conduit import Client
from datagrout.conduit.types import Receipt


@pytest.fixture
def mock_transport():
    """Create a mock transport."""
    transport = AsyncMock()
    transport.connect = AsyncMock()
    transport.disconnect = AsyncMock()
    transport.list_tools = AsyncMock(return_value=[])
    transport.call_tool = AsyncMock(return_value={})
    return transport


@pytest.mark.asyncio
async def test_client_initialization():
    """Test client initialization."""
    client = Client("https://gateway.datagrout.ai/servers/test/mcp")
    assert client.url == "https://gateway.datagrout.ai/servers/test/mcp"
    assert client.hide_3rd_party_tools is True


@pytest.mark.asyncio
async def test_list_tools_filtered():
    """Test list_tools returns filtered tools when hide_3rd_party_tools=True."""
    client = Client(
        "https://gateway.datagrout.ai/servers/test/mcp",
        hide_3rd_party_tools=True
    )
    
    async with client:
        tools = await client.list_tools()
        
        # Should return DataGrout tools only
        assert len(tools) > 0
        tool_names = [t["name"] for t in tools]
        assert "data-grout/discovery.discover" in tool_names
        assert "data-grout/discovery.perform" in tool_names


@pytest.mark.asyncio
async def test_call_tool_routes_through_perform():
    """Test that call_tool routes through discovery.perform."""
    with patch("datagrout.conduit.client.JSONRPCTransport") as mock_transport_class:
        mock_instance = AsyncMock()
        mock_instance.connect = AsyncMock()
        mock_instance.call_tool = AsyncMock(return_value={"success": True})
        mock_transport_class.return_value = mock_instance
        
        client = Client("https://gateway.datagrout.ai/servers/test/mcp")
        
        async with client:
            result = await client.call_tool("test-tool", {"arg": "value"})
            
            # Should have called discovery.perform
            mock_instance.call_tool.assert_called_once()
            call_args = mock_instance.call_tool.call_args
            assert call_args[0][0] == "data-grout/discovery.perform"


@pytest.mark.asyncio
async def test_discover():
    """Test discover method."""
    with patch("datagrout.conduit.client.JSONRPCTransport") as mock_transport_class:
        mock_instance = AsyncMock()
        mock_instance.connect = AsyncMock()
        mock_instance.call_tool = AsyncMock(return_value={
            "query_used": "test query",
            "results": [],
            "total": 0,
            "limit": 10
        })
        mock_transport_class.return_value = mock_instance
        
        client = Client("https://gateway.datagrout.ai/servers/test/mcp")
        
        async with client:
            result = await client.discover(query="test query", limit=10)
            
            assert result.query_used == "test query"
            assert result.total == 0


@pytest.mark.asyncio
async def test_receipt_tracking():
    """Test that receipts are tracked automatically."""
    with patch("datagrout.conduit.client.JSONRPCTransport") as mock_transport_class:
        mock_instance = AsyncMock()
        mock_instance.connect = AsyncMock()
        mock_instance.call_tool = AsyncMock(return_value={
            "result": "success",
            "_receipt": {
                "receipt_id": "rcp_123",
                "estimated_credits": 5.0,
                "actual_credits": 4.5,
                "net_credits": 4.5,
                "savings": 0.5,
                "savings_bonus": 0.0,
                "breakdown": {},
                "byok": {}
            }
        })
        mock_transport_class.return_value = mock_instance
        
        client = Client("https://gateway.datagrout.ai/servers/test/mcp")
        
        async with client:
            await client.perform(tool="test-tool", args={})
            
            receipt = client.get_last_receipt()
            assert receipt is not None
            assert receipt.receipt_id == "rcp_123"
            assert receipt.actual_credits == 4.5


@pytest.mark.asyncio
async def test_guided_session():
    """Test guided workflow session."""
    with patch("datagrout.conduit.client.JSONRPCTransport") as mock_transport_class:
        mock_instance = AsyncMock()
        mock_instance.connect = AsyncMock()
        mock_instance.call_tool = AsyncMock(return_value={
            "session_id": "guide_abc123",
            "step": "1",
            "message": "Choose a path",
            "status": "ready",
            "options": [
                {"id": "1.1", "label": "Option 1", "cost": 2.5, "viable": True}
            ],
            "path_taken": [],
            "total_cost": 0.0
        })
        mock_transport_class.return_value = mock_instance
        
        client = Client("https://gateway.datagrout.ai/servers/test/mcp")
        
        async with client:
            session = await client.guide(goal="test goal")
            
            assert session.session_id == "guide_abc123"
            assert session.status == "ready"
            assert len(session.options) == 1
