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

#### The DataGrout CA

mTLS identities are X.509 certificates signed by the **DataGrout Certificate Authority** (`ca.datagrout.ai`). DataGrout operates its own CA rather than relying on a third-party provider because agent identity has different requirements than browser identity — agents need rapid programmatic issuance, automated rotation, and machine-to-machine trust without human ceremony.

When you call `bootstrap_identity`, here's what happens:

1. The SDK generates an ECDSA P-256 key pair locally — the private key never leaves your machine.
2. The public key is sent to the DataGrout CA along with a one-time access token.
3. The CA signs a certificate binding your public key to a Substrate identity (e.g., `CN=conduit-my-agent`).
4. The signed certificate and CA chain are returned and saved to disk.

From that point on, every request presents the client certificate. The server verifies it against the CA chain — no tokens, no secrets in environment variables, no credentials to rotate manually. The SDK handles certificate renewal automatically before expiry.

The CA private key is stored in an HSM-backed AWS KMS key (FIPS 140-2 Level 2), so the signing key is never exposed in memory or on disk. The CA certificate itself is publicly available at `https://ca.datagrout.ai/ca.pem` for any client that needs to verify the chain independently.

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

### Intelligent Interface

When connecting to a DataGrout server, you can enable the **Intelligent Interface** — a mode that replaces the entire tool surface with just two tools: `discover` and `perform`. Your agent describes what it wants in natural language, and DataGrout handles tool resolution, multiplexing, data transformation, charting, and more behind the scenes.

This is a significant context window optimization. Instead of your agent reasoning over hundreds or thousands of tool schemas, it sees two. The standard `tools/list` response is replaced with the simplified interface automatically when enabled. Under the hood, `perform` supports the full capability set — demux (fan-out across integrations), refract (data transformation), chart generation, and any other server-side operation — all through a single natural-language entry point.

```python
# With Intelligent Interface enabled, your agent sees only 2 tools
tools = await client.list_tools()  # returns: [discover, perform]

# discover finds relevant capabilities by intent
results = await client.call_tool("discover", {"query": "find unpaid invoices"})

# perform executes — DataGrout resolves the right tools, multiplexes, transforms
result = await client.call_tool("perform", {"action": "get all open invoices from QuickBooks and Stripe"})
```

### Semantic Discovery

When not using the Intelligent Interface, semantic discovery is available as a standalone feature. Solve the N×M tool problem by searching by intent instead of listing raw tools:

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

Cryptographic proof that workflows are cycle-free, type-safe, policy-compliant, and budget-respecting. CTCs are signed by the same DataGrout CA that issues Substrate identities, creating a unified trust chain from agent identity through workflow verification.

---

## Documentation

- [Python SDK](./python/README.md)
- [TypeScript SDK](./typescript/README.md)
- [Rust SDK](./rust/README.md)
- [DataGrout Library](https://library.datagrout.ai)
- [Security](https://app.datagrout.ai/security)

### Free Web Tools

These run entirely in your browser — no account required, no data stored. Provided as a public service for the MCP and AI tooling community.

- [MCP Inspector](https://inspectors.datagrout.ai/mcp) — debug any MCP server with full auth support
- [JSONRPC Inspector](https://inspectors.datagrout.ai/jsonrpc) — test any JSON-RPC 2.0 endpoint with Bearer, OAuth 2.1, and mTLS

### Labs

DataGrout Labs publishes research papers on the systems that Conduit interacts with. If you want to understand the "why" behind the SDK's features:

- [Cognitive Trust Certificates](https://labs.datagrout.ai/ctc) — formal verification proofs for agent workflows
- [Consequential Analysis](https://labs.datagrout.ai/consequential-analysis) — semantic code verification via structural facts + intent inference
- [Policy & Semantic Guards](https://labs.datagrout.ai/policy) — runtime policy enforcement and dynamic redaction
- [Semio](https://labs.datagrout.ai/semio) — the semantic interface layer for typed tool contracts
- [Credits & Virtual Economy](https://labs.datagrout.ai/credits) — how cost tracking and credit estimation work
- [AI Link Layer](https://labs.datagrout.ai/ail) — machine-readable content discovery protocol

---

## License

MIT
