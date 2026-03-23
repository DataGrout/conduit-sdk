# DataGrout Conduit

**Production-Ready MCP Client with mTLS, OAuth 2.1, and Semantic Discovery**

Drop-in replacement for standard MCP clients. Swap one import line and your agent gains semantic discovery, cost tracking, mTLS identity management, and OAuth 2.1 — without changing any other code.

[![CI](https://github.com/DataGrout/conduit-sdk/actions/workflows/ci.yml/badge.svg)](https://github.com/DataGrout/conduit-sdk/actions/workflows/ci.yml)
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
| **Elixir** | `datagrout_conduit` | `{:datagrout_conduit, "~> 0.3.0"}` |
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
# and presented directly to the same server's /mcp endpoint
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
2. The public key is sent to the target server's DG identity bootstrap endpoint along with a one-time access token or OAuth machine token.
3. DataGrout signs a certificate binding your public key to a Substrate identity (e.g., `CN=conduit-my-agent`) and associates it with that specific MCP server.
4. The signed certificate and CA chain are returned and saved to disk.

From that point on, every request presents the client certificate. The server verifies it against the CA chain and the registered server-scoped identity — no tokens, no secrets in environment variables, no credentials to rotate manually. The SDK handles certificate renewal automatically before expiry.

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

Beyond standard MCP `tools/call`, every SDK exposes the full DataGrout server API as typed, namespaced methods. Domain-specific tools are organized into six namespaces:

| Namespace | Purpose |
|-----------|---------|
| `prism` | Data transformation, charting, rendering, export, type bridging |
| `logic` | Persistent agent memory backed by a Prolog logic cell |
| `warden` | Safety gates, intent verification, multi-model consensus |
| `deliverables` | Work product registration, listing, retrieval |
| `ephemerals` | Cache management — list and inspect cached results |
| `flow` | Workflow orchestration, routing, human-in-the-loop, execution history |

Core discovery methods (`discover`, `perform`, `guide`, `plan`, `dg`) remain directly on the client.

### Discovery & Planning

```python
results = await client.discover(query="find unpaid invoices", limit=5)
plan = await client.plan(goal="onboard a new enterprise customer")
result = await client.perform("salesforce@1/get_lead@1", args={"id": "123"})
session = await client.guide(goal="create invoice from opportunity")
```

### Prism: Data Transformation & Visualisation

```python
transformed = await client.prism.refract(goal="group invoices by customer", payload=raw_data)

chart = await client.prism.chart(goal="bar chart of outstanding amounts", payload=invoice_data,
                                 chart_type="bar", x_label="Customer", y_label="Amount (USD)")

focused = await client.prism.focus(data=payload, source_type="invoice_list",
                                   target_type="crm_opportunity_list")

rendered = await client.prism.render(goal="executive summary", payload=data)
exported = await client.prism.export(content=data, format="csv")
```

### Logic Cell (Agent Memory)

```python
await client.logic.remember(statement="Customer Acme Corp has net-30 payment terms")
facts = await client.logic.query(question="What are Acme Corp's payment terms?")
await client.logic.forget(handles=[fact.handle])
await client.logic.constrain(rule="never schedule calls outside business hours")
snapshot = await client.logic.reflect()
```

### Warden: Safety & Verification

```python
check = await client.warden.canary({"action": "delete_all", "scope": "production"})
intent = await client.warden.verify_intent({"action": "transfer_funds", "amount": 50000})
verdict = await client.warden.adjudicate({"claim": "user authorized bulk delete"})
consensus = await client.warden.ensemble({"question": "Is this action safe?", "models": 3})
```

### Flow: Workflow Orchestration

```python
outcome = await client.flow.run(plan=[
    {"tool": "salesforce@1/get_lead@1", "args": {"id": "123"}},
    {"tool": "quickbooks@1/create_invoice@1", "args": {"$prev.result": True}}
])

matched = await client.flow.route(
    branches=[{"when": "amount > 1000", "then": "approval"}, {"when": "True", "then": "auto"}],
    payload={"amount": 1500}
)

await client.flow.request_approval(action="delete customer record", reason="GDPR request")
await client.flow.request_feedback(missing_fields=["email"], reason="Required for notification")
history = await client.flow.history(limit=20)
details = await client.flow.details(execution_id="exec-abc123")
```

### Higher-Order Workflows

DataGrout supports **higher-order workflows** — a functional programming concept where flows are passed as parameters to other tool calls. This enables composable, reusable automation.

#### Named Flows (Skills)

When you save a flow with `save_as_skill=True`, it becomes a named skill that can be referenced by other flows:

```python
await client.flow.run(
    plan=[
        {"tool": "salesforce@1/get_lead@1", "args": {"id": "$input.lead_id"}},
        {"tool": "data-grout/prism.refract", "args": {"goal": "extract contact info", "payload": "$prev.result"}}
    ],
    save_as_skill=True,
    input_data={"lead_id": "123"}
)
```

Once saved, a skill can be invoked by name inside another flow's plan, treating it as a first-class callable:

```python
await client.flow.run(plan=[
    {"tool": "my-saved-skill", "args": {"lead_id": "456"}},
    {"tool": "slack@1/send_message@1", "args": {"channel": "#sales", "text": "$prev.result"}}
])
```

#### Unnamed Flows (Inline Plans / Lambdas)

You can embed an unnamed flow inline using `$compute` — the functional equivalent of a lambda or anonymous function:

```python
await client.flow.run(plan=[
    {"tool": "data-grout/data.query", "args": {"query": "SELECT * FROM leads WHERE status = 'new'"}},
    {"tool": "data-grout/prism.refract", "args": {
        "goal": "enrich each lead",
        "payload": "$prev.result",
        "transform": {"$compute": [
            {"tool": "clearbit@1/enrich@1", "args": {"email": "$item.email"}},
            {"tool": "data-grout/prism.refract", "args": {"goal": "merge enrichment", "payload": "$prev.result"}}
        ]}
    }}
])
```

#### Conditional Routing

Use `flow.route` for predicate-based dispatch — routing payloads to different branches based on conditions:

```python
matched = await client.flow.route(
    branches=[
        {"when": "amount > 10000", "then": "high-value-onboarding"},
        {"when": "amount > 1000", "then": "standard-onboarding"},
        {"when": "True", "then": "self-serve"}
    ],
    payload={"amount": 5000, "customer": "Acme Corp"}
)
```

#### Human-in-the-Loop

Insert approval gates or feedback requests at any point in a flow:

```python
await client.flow.request_approval(
    action="send bulk email to 10,000 contacts",
    reason="Campaign launch requires manager approval",
    details={"template": "spring-promo", "count": 10000}
)

await client.flow.request_feedback(
    missing_fields=["billing_email", "tax_id"],
    reason="Required for invoice generation",
    suggestions={"billing_email": "finance@acme.com"}
)
```

### Deliverables & Ephemerals

```python
await client.deliverables.register({"type": "report", "title": "Q1 Summary", "content": report})
items = await client.deliverables.list()
item = await client.deliverables.get("ref-abc123")

cached = await client.ephemerals.list()
entry = await client.ephemerals.inspect("cache-ref-xyz")
```

### Generic Hook

For any DataGrout tool not yet covered by a namespace method, use the generic `dg()` hook:

```python
facts = await client.dg("invariant.code_lens", {"source": source_code, "language": "python"})
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

- [MCP Inspector](https://inspectors.datagrout.ai/mcp) — debug any MCP server with full auth support
- [JSONRPC Inspector](https://inspectors.datagrout.ai/jsonrpc) — test any JSON-RPC 2.0 endpoint with Bearer, OAuth 2.1, and mTLS

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
