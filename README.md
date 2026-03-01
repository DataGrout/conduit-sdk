# DataGrout Conduit

**Production-Ready MCP Client with mTLS, OAuth 2.1, and Semantic Discovery**

Drop-in replacement for standard MCP clients. Swap one import line and your agent gains semantic discovery, cost tracking, mTLS identity management, and OAuth 2.1 — without changing any other code.

## Available Languages

| Language | Package | Install |
|----------|---------|---------|
| **Python** | `datagrout-conduit` | `pip install datagrout-conduit` |
| **TypeScript** | `@datagrout/conduit` | `npm install @datagrout/conduit` |
| **Rust** | `datagrout-conduit` | `cargo add datagrout-conduit` |

## Quick Start

### Python

```python
from datagrout.conduit import Client

async with Client("https://gateway.datagrout.ai/servers/{uuid}/mcp") as client:
    tools = await client.list_tools()
    result = await client.call_tool("salesforce@1/get_lead@1", {"id": "123"})

    results = await client.discover(query="find unpaid invoices", limit=10)
    session = await client.guide(goal="create invoice from lead")
```

### TypeScript

```typescript
import { Client } from '@datagrout/conduit';

const client = new Client('https://gateway.datagrout.ai/servers/{uuid}/mcp');
await client.connect();

const tools = await client.listTools();
const result = await client.callTool('salesforce@1/get_lead@1', { id: '123' });

await client.disconnect();
```

### Rust

```rust
use datagrout_conduit::ClientBuilder;

let client = ClientBuilder::new()
    .url("https://gateway.datagrout.ai/servers/{uuid}/mcp")
    .auth_bearer("your-token")
    .build()?;

client.connect().await?;
let tools = client.list_tools().await?;
```

---

## Authentication

All three SDKs support the same authentication methods:

### Bearer Token

```python
client = Client("...", auth={"bearer": "your-token"})
```

### OAuth 2.1 (client_credentials)

```python
client = Client("...", client_id="id", client_secret="secret")
```

The SDK fetches, caches, and auto-refreshes JWTs.

### mTLS (Mutual TLS)

After a one-time bootstrap, the client certificate handles authentication — no tokens needed.

```python
# First run: bootstrap identity with a one-time token
client = await Client.bootstrap_identity(
    url="https://gateway.datagrout.ai/servers/{uuid}/mcp",
    auth_token="your-access-token",
    name="my-agent",
)

# All subsequent runs: mTLS auto-discovered from ~/.conduit/
client = Client("https://gateway.datagrout.ai/servers/{uuid}/mcp")
```

Identity auto-discovery searches:

1. `CONDUIT_MTLS_CERT` + `CONDUIT_MTLS_KEY` env vars (inline PEM)
2. `CONDUIT_IDENTITY_DIR` env var (directory path)
3. `~/.conduit/identity.pem` + `~/.conduit/identity_key.pem`
4. `.conduit/` relative to cwd

For multiple agents on one machine, use `identity_dir` to give each its own certificate directory.

---

## Transport Modes

| Transport | Protocol | Use When |
|-----------|----------|----------|
| `jsonrpc` (default) | JSON-RPC 2.0 over HTTP POST | Lightweight, supports mTLS |
| `mcp` | MCP over Streamable HTTP / SSE | Full MCP protocol compliance |

```python
# JSONRPC (default)
client = Client(url, transport="jsonrpc")

# MCP
client = Client(url, transport="mcp")
```

---

## Key Features

### Semantic Discovery

Solve the N×M tool problem. Instead of listing thousands of raw tools, agents search by intent:

```python
results = await client.discover(query="find unpaid invoices", limit=5)
```

### Cost Tracking

Every tool call returns a receipt with credit usage:

```python
from datagrout.conduit import extract_meta

result = await client.call_tool("salesforce@1/get_lead@1", {"id": "123"})
meta = extract_meta(result)
if meta:
    print(f"Credits: {meta.receipt.net_credits}")
```

### Guided Workflows

Build multi-step workflows interactively:

```python
session = await client.guide(goal="create invoice from lead")
```

### Cognitive Trust Certificates

Cryptographic proof that workflows are cycle-free, type-safe, policy-compliant, and budget-respecting.

---

## Documentation

- [Python SDK](./python/README.md)
- [TypeScript SDK](./typescript/README.md)
- [Rust SDK](./rust/README.md)
- [DataGrout Library](https://docs.datagrout.ai)

---

## License

MIT
