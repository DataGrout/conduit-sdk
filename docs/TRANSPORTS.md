# Conduit Transport Layers

Conduit supports multiple transport protocols for connecting to DataGrout servers and MCP-compatible systems.

## Supported Transports

### 1. MCP Transport (Official SDK)

Uses Anthropic's official `mcp` Python SDK for standards-compliant MCP communication.

**Supported URL schemes:**
- `stdio://command args` - Local process via stdio
- `http://` or `https://` - SSE over HTTP/HTTPS

**Example:**

```python
from datagrout.conduit import Client

# HTTP/SSE transport
async with Client(
    url="https://gateway.datagrout.ai/servers/{uuid}/mcp",
    transport="mcp",
    auth={"bearer": "your-token"}
) as client:
    tools = await client.list_tools()
    result = await client.call_tool("salesforce@1/get_lead@1", {"id": "123"})

# Local stdio process
async with Client(
    url="stdio://python -m my_mcp_server",
    transport="mcp"
) as client:
    tools = await client.list_tools()
```

**Features:**
- Full MCP protocol compliance
- Stdio and SSE transports
- Automatic reconnection
- Proper session lifecycle

**Requirements:**
- `mcp>=1.0.0` (included in dependencies)

---

### 2. JSONRPC Transport (Lightweight)

Simple JSONRPC-over-HTTP transport for lightweight scenarios.

**Supported URL schemes:**
- `http://` or `https://` - JSONRPC over HTTP

**Example:**

```python
from datagrout.conduit import Client

async with Client(
    url="https://api.example.com/rpc",
    transport="jsonrpc",
    auth={"api_key": "your-key"},
    timeout=60.0
) as client:
    tools = await client.list_tools()
    result = await client.call_tool("my_tool", {"arg": "value"})
```

**Features:**
- Lightweight HTTP-only transport
- Simple JSONRPC 2.0 protocol
- Lower overhead than full MCP
- Configurable timeouts

**Use cases:**
- HTTP-only environments
- Simple request/response patterns
- Minimal dependencies

---

## Choosing a Transport

| Feature | MCP | JSONRPC |
|---------|-----|---------|
| Protocol | MCP (official) | JSONRPC 2.0 |
| Transports | stdio, SSE/HTTP | HTTP only |
| Standards compliance | Full MCP | Custom |
| Overhead | Higher | Lower |
| Use case | Full MCP compatibility | Simple HTTP APIs |

**Recommendation:**
- Use **MCP** for connecting to official MCP servers and DataGrout Gateway
- Use **JSONRPC** for lightweight HTTP-only scenarios or when MCP is overkill

---

## Authentication

Both transports support standard authentication patterns:

```python
# Bearer token
Client(url="...", auth={"bearer": "token"})

# API key
Client(url="...", auth={"api_key": "key"})
```

**MCP:** Adds `Authorization: Bearer <token>` or `X-API-Key: <key>` headers

**JSONRPC:** Adds same headers to all HTTP requests

---

## Custom Transports

You can implement custom transports by extending the `Transport` base class:

```python
from datagrout.conduit.transports import Transport

class MyTransport(Transport):
    async def connect(self) -> None:
        # Custom connection logic
        pass
    
    async def call_tool(self, name: str, arguments: dict) -> Any:
        # Custom tool call logic
        pass
    
    # Implement other abstract methods...

# Use custom transport
client = Client(url="...", transport=MyTransport())
```

---

## Error Handling

Both transports raise standard Python exceptions:

```python
from httpx import HTTPError
from mcp import MCPError

try:
    async with Client(url="...", transport="mcp") as client:
        result = await client.call_tool("tool", {})
except HTTPError as e:
    print(f"Network error: {e}")
except RuntimeError as e:
    print(f"Protocol error: {e}")
```

---

## Performance

**MCP Transport:**
- Persistent SSE connection (low latency)
- Connection pooling
- Automatic backoff/retry

**JSONRPC Transport:**
- HTTP/2 multiplexing (via httpx)
- Connection pooling
- Configurable timeouts

Both transports are production-ready and handle concurrency efficiently.
