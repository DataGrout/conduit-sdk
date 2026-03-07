# DataGrout Conduit

**Production-Ready MCP Client with mTLS, OAuth 2.1, and Semantic Discovery**

Drop-in replacement for standard MCP clients. Swap one import line and your agent gains semantic discovery, cost tracking, mTLS identity management, and OAuth 2.1 — without changing any other code.

[![PyPI](https://img.shields.io/pypi/v/datagrout-conduit?label=PyPI&color=3775A9)](https://pypi.org/project/datagrout-conduit)
[![npm](https://img.shields.io/npm/v/@datagrout/conduit?label=npm&color=CB3837)](https://www.npmjs.com/package/@datagrout/conduit)
[![crates.io](https://img.shields.io/crates/v/datagrout-conduit?label=crates.io&color=f74c00)](https://crates.io/crates/datagrout-conduit)
[![Hex.pm](https://img.shields.io/hexpm/v/datagrout_conduit?label=hex.pm&color=6E4A7E)](https://hex.pm/packages/datagrout_conduit)
[![RubyGems](https://img.shields.io/gem/v/datagrout-conduit?label=RubyGems&color=CC342D)](https://rubygems.org/gems/datagrout-conduit)

## Available Languages

| Language | Package | Install |
|----------|---------|---------|
| **Python** | `datagrout-conduit` | `pip install datagrout-conduit` |
| **TypeScript** | `@datagrout/conduit` | `npm install @datagrout/conduit` |
| **Rust** | `datagrout-conduit` | `cargo add datagrout-conduit` |
| **Elixir** | `datagrout_conduit` | `{:datagrout_conduit, "~> 0.1.0"}` |
| **Ruby** | `datagrout-conduit` | `gem install datagrout-conduit` |

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

### Elixir

```elixir
{:ok, client} = DatagroutConduit.Client.start_link(
  url: "https://gateway.datagrout.ai/servers/{uuid}/mcp",
  auth: {:bearer, "your-token"}
)

{:ok, tools} = DatagroutConduit.Client.list_tools(client)
{:ok, result} = DatagroutConduit.Client.call_tool(client, "salesforce@1/get_lead@1", %{"id" => "123"})
```

### Ruby

```ruby
client = DatagroutConduit::Client.new(
  url: "https://gateway.datagrout.ai/servers/{uuid}/mcp",
  auth: { bearer: "your-token" }
)
client.connect

tools = client.list_tools
result = client.call_tool("salesforce@1/get_lead@1", { id: "123" })
```

---

## Authentication

All five SDKs support the same authentication methods:

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

Identity auto-discovery searches (in order):

1. `override_dir` / `identity_dir` option (if provided)
2. `CONDUIT_MTLS_CERT` + `CONDUIT_MTLS_KEY` env vars (inline PEM)
3. `CONDUIT_IDENTITY_DIR` env var (directory path)
4. `~/.conduit/identity.pem` + `~/.conduit/identity_key.pem`
5. `.conduit/` relative to cwd

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

DataGrout exposes the same interface — the same tools, same schemas, same features — over both transports. mTLS, OAuth 2.1, and bearer token authentication all work identically regardless of which transport you choose.

| Transport | Protocol | Use When |
|-----------|----------|----------|
| `mcp` (default) | MCP over Streamable HTTP / SSE | Full MCP protocol — streaming, notifications, drop-in compatible |
| `jsonrpc` | JSON-RPC 2.0 over HTTP POST | Simpler protocol, stateless, one request = one response |

```python
# MCP (default) — full protocol compliance, streaming support
client = Client(url)

# JSONRPC — same tools, same auth, simpler protocol
client = Client(url, transport="jsonrpc")
```

The entire MCP interface is also available over JSONRPC — same tools, same arguments, same responses. JSONRPC can be a good fit for lightweight agents that don't need streaming or server-pushed notifications.

---

## Key Features

### Intelligent Interface

When connecting to a DataGrout server, the **Intelligent Interface** is enabled by default — replacing the entire tool surface with just two tools: `data-grout@1/discovery.discover@1` and `data-grout@1/discovery.perform@1`. Your agent describes what it wants in natural language, and DataGrout handles tool resolution, multiplexing, data transformation, charting, and more behind the scenes. Pass `use_intelligent_interface=False` to opt out and see all raw tools.

This is a significant context window optimization. Instead of your agent reasoning over hundreds or thousands of tool schemas, it sees two. The standard `tools/list` response is replaced with the simplified interface automatically when enabled. Under the hood, `perform` supports the full capability set — demux (fan-out across integrations), refract (data transformation), chart generation, and any other server-side operation — all through a single natural-language entry point.

```python
# With Intelligent Interface enabled, tools/list returns only 2 tools
tools = await client.list_tools()
# → [data-grout@1/discovery.discover@1, data-grout@1/discovery.perform@1]

# discover: semantic search for relevant tools by goal
results = await client.call_tool("data-grout@1/discovery.discover@1", {
    "goal": "find unpaid invoices",
    "limit": 10
})

# perform: execute a discovered tool by name with its args
result = await client.call_tool("data-grout@1/discovery.perform@1", {
    "tool": "quickbooks@1/get_invoices@1",
    "args": {"status": "unpaid"}
})

# perform also supports demux, refract, and chart as optional parameters:
result = await client.call_tool("data-grout@1/discovery.perform@1", {
    "tool": "quickbooks@1/get_invoices@1",
    "args": {"status": "unpaid"},
    "demux": True,          # fan-out across all connected servers with this tool
    "refract": "summarize by customer with totals",  # transform the output
    "chart": "bar chart of outstanding amounts by customer"  # generate a chart
})
```

### Semantic Discovery

When not using the Intelligent Interface, `discovery.discover` is still available as a standalone tool alongside all your other tools. It searches by semantic similarity to a goal rather than requiring exact tool names:

```python
results = await client.call_tool("data-grout@1/discovery.discover@1", {
    "goal": "find unpaid invoices",
    "limit": 5
})
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

## DataGrout First-Party Tools

Beyond standard MCP `tools/call`, every SDK exposes the full DataGrout server API as typed methods. These use direct JSON-RPC calls to the server — no extra round-trips.

### Discovery & Planning

```python
# Find and rank tools by intent
results = await client.discover(query="find unpaid invoices", limit=5)

# Generate a ranked workflow plan from a goal
plan = await client.plan(goal="onboard a new enterprise customer")

# Execute a discovered tool with tracking
result = await client.perform("salesforce@1/get_lead@1", args={"id": "123"})

# Interactive multi-step workflow
session = await client.guide(goal="create invoice from opportunity")

# Execute the resulting workflow plan
outcome = await client.flow_into(plan_id=session.plan_id, steps=session.steps)
```

### Prism: Data Transformation & Visualisation

```python
# Transform a data payload toward a natural-language goal (plan compiled and cached on first use)
transformed = await client.refract(goal="group invoices by customer", payload=raw_data)

# Visualise as a chart (SVG, sparkline, Unicode)
chart = await client.chart(goal="bar chart of outstanding amounts", payload=invoice_data,
                           chart_type="bar", x_label="Customer", y_label="Amount (USD)")

# Semantic type bridge between semio types
focused = await client.prism_focus(data=payload, source_type="invoice_list",
                                   target_type="crm_opportunity_list")

# Estimate credits before running an expensive tool
estimate = await client.estimate_cost("prism.refract", {"goal": "...", "payload": large_data})
```

### Logic Cell (Agent Memory)

```python
# Persist facts across sessions
await client.remember(statement="Customer Acme Corp has net-30 payment terms")

# Query stored facts
facts = await client.query_cell(question="What are Acme Corp's payment terms?")

# Retract a fact by handle
await client.forget(handles=[fact.handle])

# Add a rule/policy
await client.constrain(rule="never schedule calls outside business hours")

# Introspect all known facts
snapshot = await client.reflect()
```

### Generic Hook

For any DataGrout tool not yet covered by a typed method, use the generic `dg()` hook:

```python
# e.g. generate a report from structured data
report = await client.dg("prism.render", {"goal": "executive summary", "payload": data})

# Pause for human approval before a destructive step
await client.dg("flow.request-approval", {"action": "delete customer record", "id": "123"})

# Code analysis
facts = await client.dg("prism.code_lens", {"source": source_code, "language": "python"})
```

---

## Documentation

- [Python SDK](./python/README.md)
- [TypeScript SDK](./typescript/README.md)
- [Rust SDK](./rust/README.md)
- [Elixir SDK](./elixir/README.md)
- [Ruby SDK](./ruby/README.md)
- [DataGrout Library](https://library.datagrout.ai)
- [Security](https://app.datagrout.ai/security)
### Free Web Tools

These run entirely in your browser — no account required, no data stored. Provided as a public service for the MCP and AI tooling community.

- [MCP Inspector](https://app.datagrout.ai/inspector) — debug any MCP server with full auth support
- [JSONRPC Inspector](https://app.datagrout.ai/jsonrpc-inspector) — test any JSON-RPC 2.0 endpoint with Bearer, OAuth 2.1, and mTLS

### Labs

DataGrout Labs publishes research papers on the systems that Conduit interacts with. If you want to understand the "why" behind the SDK's features:

- [Cognitive Trust Certificates](https://labs.datagrout.ai/papers/ctc) — formal verification proofs for agent workflows
- [Consequential Analysis](https://labs.datagrout.ai/papers/consequential_analysis) — semantic code verification via structural facts + intent inference
- [Policy & Semantic Guards](https://labs.datagrout.ai/papers/policy) — runtime policy enforcement and dynamic redaction
- [Semio](https://labs.datagrout.ai/papers/semio) — the semantic interface layer for typed tool contracts
- [Credits & Virtual Economy](https://labs.datagrout.ai/papers/credits) — how cost tracking and credit estimation work
- [AI Link Layer](https://labs.datagrout.ai/papers/ail) — machine-readable content discovery protocol

---

## License

MIT
