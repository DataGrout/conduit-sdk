# DataGrout Conduit — Python SDK

Production-ready MCP client with mTLS identity, OAuth 2.1, semantic discovery, and cost tracking.

## Installation

```bash
pip install datagrout-conduit
```

## Quick Start

```python
from datagrout.conduit import Client

async with Client("https://gateway.datagrout.ai/servers/{uuid}/mcp") as client:
    tools = await client.list_tools()
    result = await client.call_tool("salesforce@1/get_lead@1", {"id": "123"})
```

## Authentication

### Bearer Token

```python
client = Client(
    "https://gateway.datagrout.ai/servers/{uuid}/mcp",
    auth={"bearer": "your-access-token"},
)
```

### OAuth 2.1 (client_credentials)

```python
client = Client(
    "https://gateway.datagrout.ai/servers/{uuid}/mcp",
    client_id="your-client-id",
    client_secret="your-client-secret",
)
```

The SDK automatically fetches, caches, and refreshes JWTs before they expire.

### mTLS (Mutual TLS)

After bootstrapping, the client certificate handles authentication at the TLS layer — no tokens needed.

```python
from datagrout.conduit import Client, ConduitIdentity

# Auto-discover from env vars, CONDUIT_IDENTITY_DIR, or ~/.conduit/
client = Client("https://gateway.datagrout.ai/servers/{uuid}/mcp", identity_auto=True)

# Explicit identity from files
identity = ConduitIdentity.from_paths("certs/client.pem", "certs/client_key.pem")
client = Client("...", identity=identity)

# Multiple agents on one machine
client = Client("...", identity_dir="/opt/agents/agent-a/.conduit", identity_auto=True)
```

#### Identity Auto-Discovery Order

1. `CONDUIT_MTLS_CERT` + `CONDUIT_MTLS_KEY` environment variables (inline PEM)
2. `CONDUIT_IDENTITY_DIR` environment variable (directory path)
3. `~/.conduit/identity.pem` + `~/.conduit/identity_key.pem`
4. `.conduit/` relative to the current working directory

For DataGrout URLs (`*.datagrout.ai`), auto-discovery runs silently even without `identity_auto=True`.

#### Bootstrapping an mTLS Identity

First-run provisioning — generates a keypair, registers with the DataGrout CA, and saves certs locally. After this, the token is never needed again.

```python
# First run: token needed for registration
client = await Client.bootstrap_identity(
    url="https://gateway.datagrout.ai/servers/{uuid}/mcp",
    auth_token="your-access-token",
    name="my-laptop",
)

# Or bootstrap with OAuth 2.1 client_credentials
client = await Client.bootstrap_identity_oauth(
    url="https://gateway.datagrout.ai/servers/{uuid}/mcp",
    client_id="your-client-id",
    client_secret="your-client-secret",
    name="my-laptop",
)

# Subsequent runs: no token needed, mTLS auto-discovered
client = Client("https://gateway.datagrout.ai/servers/{uuid}/mcp")
```

## Semantic Discovery

When `use_intelligent_interface` is enabled, `list_tools()` returns only DataGrout's meta-tools. Agents use semantic search instead of enumerating raw integrations:

```python
client = Client("...", use_intelligent_interface=True)

# Semantic search across all connected integrations
results = await client.discover(query="find unpaid invoices", limit=5)

# Direct execution with cost tracking
result = await client.perform(
    tool="salesforce@1/get_lead@1",
    args={"id": "123"},
)
```

## Cost Tracking

Every tool call returns a receipt with credit usage:

```python
from datagrout.conduit import extract_meta

result = await client.call_tool("salesforce@1/get_lead@1", {"id": "123"})
meta = extract_meta(result)

if meta:
    print(f"Credits: {meta.receipt.net_credits}")
    print(f"Savings: {meta.receipt.savings}")
```

## Transports

```python
# JSONRPC (default) — lightweight, supports mTLS
client = Client(url, transport="jsonrpc")

# MCP — full MCP protocol over Streamable HTTP
client = Client(url, transport="mcp")
```

## API Reference

### Client Options

```python
Client(
    url: str,
    auth: dict = None,                    # {"bearer": "..."} or {"client_credentials": {...}}
    transport: str = "jsonrpc",           # "jsonrpc" or "mcp"
    use_intelligent_interface: bool = False,
    identity: ConduitIdentity = None,     # explicit mTLS identity
    identity_auto: bool = False,          # auto-discover identity
    identity_dir: str = None,             # custom identity directory
    disable_mtls: bool = False,           # opt out of mTLS auto-discovery
    client_id: str = None,               # OAuth shorthand
    client_secret: str = None,           # OAuth shorthand
)
```

### Standard MCP Methods

| Method | Description |
|---|---|
| `list_tools()` | List available tools |
| `call_tool(name, args)` | Execute a tool |
| `list_resources()` | List resources |
| `read_resource(uri)` | Read a resource |
| `list_prompts()` | List prompts |
| `get_prompt(name, args)` | Get a prompt |

### DataGrout Extensions

| Method | Description |
|---|---|
| `discover(query, limit, integrations)` | Semantic tool search |
| `perform(tool, args, demux)` | Direct tool execution with tracking |
| `perform_batch(calls)` | Parallel tool execution |
| `guide(goal, policy, session_id)` | Guided multi-step workflow |
| `flow_into(plan, ...)` | Workflow orchestration |
| `prism_focus(data, source_type, target_type)` | Type transformation |
| `estimate_cost(tool, args)` | Pre-execution credit estimate |

### Bootstrap Methods

| Method | Description |
|---|---|
| `Client.bootstrap_identity(url, auth_token, name)` | Bootstrap mTLS with access token |
| `Client.bootstrap_identity_oauth(url, client_id, client_secret, name)` | Bootstrap mTLS with OAuth 2.1 |

## Requirements

- Python 3.10+
- `httpx` (for JSONRPC transport)
- `mcp` package (optional, for MCP transport mode)

## License

MIT
