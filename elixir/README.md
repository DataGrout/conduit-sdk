# DataGrout Conduit — Elixir SDK

Production-ready MCP client with mTLS, OAuth 2.1, and semantic discovery for Elixir/OTP.

This is a **client** library. It connects to remote MCP and JSON-RPC servers over HTTP/HTTPS, sends requests, and parses responses. It does not run any server, accept connections, or handle incoming requests.

## Installation

Add `datagrout_conduit` to your `mix.exs` dependencies:

```elixir
def deps do
  [
    {:datagrout_conduit, "~> 0.1.0"}
  ]
end
```

## Quick Start

```elixir
# Connect to a DataGrout MCP server
{:ok, client} = DatagroutConduit.Client.start_link(
  url: "https://gateway.datagrout.ai/servers/{uuid}/mcp",
  auth: {:bearer, "your-api-key"}
)

# List available tools
{:ok, tools} = DatagroutConduit.Client.list_tools(client)

# Call a tool
{:ok, result} = DatagroutConduit.Client.call_tool(client, "get_invoices", %{status: "unpaid"})

# Extract cost metadata
meta = DatagroutConduit.extract_meta(result)
IO.inspect(meta.receipt)
```

## Authentication

### Bearer Token

```elixir
{:ok, client} = DatagroutConduit.Client.start_link(
  url: "https://gateway.datagrout.ai/servers/{uuid}/mcp",
  auth: {:bearer, "your-token"}
)
```

### OAuth 2.1 (Client Credentials)

```elixir
{:ok, oauth} = DatagroutConduit.OAuth.start_link(
  client_id: "your-client-id",
  client_secret: "your-secret",
  token_endpoint: "https://gateway.datagrout.ai/servers/{uuid}/oauth/token"
)

{:ok, client} = DatagroutConduit.Client.start_link(
  url: "https://gateway.datagrout.ai/servers/{uuid}/mcp",
  auth: {:oauth, oauth}
)
```

Token endpoint can be auto-derived from the MCP URL:

```elixir
endpoint = DatagroutConduit.OAuth.derive_token_endpoint("https://gateway.datagrout.ai/servers/{uuid}/mcp")
# => "https://gateway.datagrout.ai/servers/{uuid}/oauth/token"
```

Tokens are cached and refreshed automatically 60 seconds before expiry.

### mTLS Client Certificates

```elixir
# Auto-discover identity (searches standard locations)
identity = DatagroutConduit.Identity.try_discover()

# Or from explicit paths
{:ok, identity} = DatagroutConduit.Identity.from_paths("cert.pem", "key.pem", "ca.pem")

# Or from PEM data
{:ok, identity} = DatagroutConduit.Identity.from_pem(cert_pem, key_pem, ca_pem)

# Use with client
{:ok, client} = DatagroutConduit.Client.start_link(
  url: "https://gateway.datagrout.ai/servers/{uuid}/mcp",
  auth: {:bearer, "token"},
  identity: identity
)
```

Discovery order:
1. `override_dir` option
2. `CONDUIT_MTLS_CERT` + `CONDUIT_MTLS_KEY` environment variables
3. `CONDUIT_IDENTITY_DIR` environment variable
4. `~/.conduit/identity.pem` + `identity_key.pem`
5. `.conduit/` relative to current working directory

Check certificate rotation:

```elixir
if DatagroutConduit.Identity.needs_rotation?(identity, threshold_days: 30) do
  Logger.warning("mTLS certificate expires within 30 days")
end
```

For DataGrout URLs (`datagrout.ai`, `datagrout.dev`), mTLS identity is auto-discovered.

### Identity Registration & Bootstrap

Bootstrap a new mTLS identity with a one-time access token:

```elixir
{:ok, client} = DatagroutConduit.Client.bootstrap_identity(
  url: "https://gateway.datagrout.ai/servers/{uuid}/mcp",
  auth_token: "your-one-time-token",
  name: "my-agent"
)
```

Or with OAuth client credentials:

```elixir
{:ok, client} = DatagroutConduit.Client.bootstrap_identity_oauth(
  url: "https://gateway.datagrout.ai/servers/{uuid}/mcp",
  client_id: "id",
  client_secret: "secret",
  name: "my-agent"
)
```

After bootstrap, subsequent runs auto-discover the saved identity — no tokens needed.

You can also use the registration module directly:

```elixir
{:ok, {private_pem, public_pem}} = DatagroutConduit.Registration.generate_keypair()
{:ok, response} = DatagroutConduit.Registration.register_identity(public_pem, auth_token: "token")
{:ok, paths} = DatagroutConduit.Registration.save_identity(response.cert_pem, private_pem, response.ca_cert_pem, "~/.conduit")
{:ok, ca_pem} = DatagroutConduit.Registration.fetch_ca_cert()
```

## Transports

### MCP (Streamable HTTP) — Default

```elixir
{:ok, client} = DatagroutConduit.Client.start_link(
  url: "https://example.com/mcp",
  transport: :mcp
)
```

Sends HTTP POST with JSON-RPC 2.0 bodies and MCP-specific headers. Handles both direct JSON and SSE response formats.

### JSON-RPC 2.0

```elixir
{:ok, client} = DatagroutConduit.Client.start_link(
  url: "https://example.com/jsonrpc",
  transport: :jsonrpc
)
```

Standard JSON-RPC 2.0 over HTTP POST.

## MCP Protocol Methods

```elixir
# Tools
{:ok, tools} = DatagroutConduit.Client.list_tools(client)
{:ok, result} = DatagroutConduit.Client.call_tool(client, "tool-name", %{arg: "val"})

# Resources
{:ok, resources} = DatagroutConduit.Client.list_resources(client)
{:ok, content} = DatagroutConduit.Client.read_resource(client, "resource://uri")

# Prompts
{:ok, prompts} = DatagroutConduit.Client.list_prompts(client)
{:ok, messages} = DatagroutConduit.Client.get_prompt(client, "prompt-name", %{})
```

## DataGrout Extensions

When connected to a DataGrout server, additional capabilities are available:

### Semantic Discovery

Find tools that match a natural-language goal:

```elixir
{:ok, results} = DatagroutConduit.Client.discover(client, goal: "find unpaid invoices", limit: 10)
# => %DiscoverResult{tools: [%DiscoveredTool{tool: %Tool{...}, score: 0.95, ...}], query: "...", total: 10}
```

### Perform (Enhanced Tool Execution)

Execute tools with demuxing, refraction, and charting:

```elixir
{:ok, result} = DatagroutConduit.Client.perform(client, "get_data", %{query: "..."}, demux: true)
```

### Guided Execution

Create and execute multi-step plans:

```elixir
{:ok, plan} = DatagroutConduit.Client.guide(client, goal: "create invoice from lead")
{:ok, result} = DatagroutConduit.Client.flow_into(client, plan)
```

Or use the interactive `GuidedSession`:

```elixir
{:ok, session} = DatagroutConduit.GuidedSession.start(client, goal: "create invoice from lead")
IO.inspect(DatagroutConduit.GuidedSession.options(session))

{:ok, session} = DatagroutConduit.GuidedSession.choose(session, 0)
{:ok, result} = DatagroutConduit.GuidedSession.complete(session)
```

### Prism Focus

Transform data through a lens:

```elixir
{:ok, result} = DatagroutConduit.Client.prism_focus(client, data: my_data, lens: "summary")
```

### Cost Estimation

```elixir
{:ok, estimate} = DatagroutConduit.Client.estimate_cost(client, "expensive-tool", %{})
# => %CreditEstimate{estimated_total: 2.5, net_total: 2.0, breakdown: %{...}}
```

## Cost Tracking

Every tool call returns metadata with credit receipts:

```elixir
{:ok, result} = DatagroutConduit.Client.call_tool(client, "analyze", %{data: "..."})
meta = DatagroutConduit.extract_meta(result)

case meta.receipt do
  %{net_credits: credits, receipt_id: id} ->
    Logger.info("Charged #{credits} credits (receipt: #{id})")
  nil ->
    :ok
end
```

## Intelligent Interface

For DataGrout URLs, the client automatically enables the _intelligent interface_:
- `list_tools/1` filters out integration tools (those containing `@` like `salesforce@1/get_lead@1`), exposing only `data-grout@1/discovery.discover@1` and `data-grout@1/discovery.perform@1`
- DG extension methods (`discover`, `perform`, `guide`, etc.) call direct JSON-RPC methods behind the scenes

Override this behavior:

```elixir
{:ok, client} = DatagroutConduit.Client.start_link(
  url: "https://gateway.datagrout.ai/servers/{uuid}/mcp",
  auth: {:bearer, "token"},
  use_intelligent_interface: false  # show all tools including @-prefixed
)
```

## DG URL Detection

```elixir
DatagroutConduit.is_dg_url?("https://gateway.datagrout.ai/servers/123/mcp")
# => true

DatagroutConduit.is_dg_url?("https://example.com/mcp")
# => false
```

## Links

- [DataGrout Library](https://library.datagrout.ai) — Browse and connect to MCP servers
- [Security](https://app.datagrout.ai/security) — Security policies and audit logs
- [MCP Inspector](https://app.datagrout.ai/inspector) — Interactive MCP protocol debugger
- [JSONRPC Inspector](https://app.datagrout.ai/jsonrpc-inspector) — JSON-RPC protocol debugger

### Labs Papers

- [CTC (Cryptographic Trust Chain)](https://library.datagrout.ai/labs/ctc) — Verifiable AI execution receipts
- [Consequential Analysis](https://library.datagrout.ai/labs/consequential-analysis) — Impact assessment for AI tool calls
- [Policy](https://library.datagrout.ai/labs/policy) — Governance frameworks for AI agents
- [Semio](https://library.datagrout.ai/labs/semio) — Semantic guard rails
- [Credits](https://library.datagrout.ai/labs/credits) — Cost tracking and billing
- [AIL (AI Intermediate Language)](https://library.datagrout.ai/labs/ail) — Portable AI workflow format

## License

MIT — DataGrout <hello@datagrout.ai>
