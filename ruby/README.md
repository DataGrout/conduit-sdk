# DataGrout Conduit SDK for Ruby

Production-ready MCP client with mTLS, OAuth 2.1, and semantic discovery.

Connect to remote MCP and JSONRPC servers, invoke tools, discover capabilities with natural language, and track costs — all with enterprise-grade security.

## Installation

Add to your Gemfile:

```ruby
gem "datagrout-conduit", "~> 0.1"
```

Or install directly:

```sh
gem install datagrout-conduit
```

## Quick Start

```ruby
require "datagrout_conduit"

# Create a client
client = DatagroutConduit::Client.new(
  url: "https://gateway.datagrout.ai/servers/{uuid}/mcp",
  auth: { bearer: "your-token" }
)

# Connect and initialize the MCP session
client.connect

# List available tools
tools = client.list_tools
puts "Found #{tools.size} tools"

# Call a tool
result = client.call_tool("salesforce@1/get_lead@1", { id: "123" })
puts result

# Disconnect
client.disconnect
```

## Authentication

### Bearer Token

```ruby
client = DatagroutConduit::Client.new(
  url: "https://gateway.datagrout.ai/servers/{uuid}/mcp",
  auth: { bearer: "your-token" }
)
```

### API Key

```ruby
client = DatagroutConduit::Client.new(
  url: "https://gateway.datagrout.ai/servers/{uuid}/mcp",
  auth: { api_key: "your-api-key" }
)
```

### OAuth 2.1 (Client Credentials)

```ruby
provider = DatagroutConduit::OAuth::TokenProvider.new(
  client_id: "my_client_id",
  client_secret: "my_client_secret",
  token_endpoint: "https://app.datagrout.ai/servers/{uuid}/oauth/token"
)

client = DatagroutConduit::Client.new(
  url: "https://gateway.datagrout.ai/servers/{uuid}/mcp",
  auth: { oauth: provider }
)
```

The token endpoint is auto-derived from MCP URLs — `/mcp` becomes `/oauth/token`. Tokens are cached and refreshed 60 seconds before expiry.

### mTLS (Mutual TLS)

```ruby
# Auto-discover identity from standard locations
identity = DatagroutConduit::Identity.try_discover

# Or load explicitly
identity = DatagroutConduit::Identity.from_paths("cert.pem", "key.pem", ca_path: "ca.pem")

# Or from PEM strings
identity = DatagroutConduit::Identity.from_pem(cert_pem, key_pem, ca_pem: ca_pem)

# Or from environment variables
identity = DatagroutConduit::Identity.from_env

client = DatagroutConduit::Client.new(
  url: "https://gateway.datagrout.ai/servers/{uuid}/mcp",
  identity: identity
)
```

Identity auto-discovery order:

1. `override_dir` (if provided)
2. `CONDUIT_MTLS_CERT` + `CONDUIT_MTLS_KEY` env vars
3. `CONDUIT_IDENTITY_DIR` env var
4. `~/.conduit/identity.pem` + `identity_key.pem`
5. `.conduit/` relative to cwd

For DataGrout URLs, identity discovery happens automatically.

### Identity Registration & Bootstrap

Bootstrap a new mTLS identity with a one-time access token:

```ruby
client = DatagroutConduit::Client.bootstrap_identity(
  url: "https://gateway.datagrout.ai/servers/{uuid}/mcp",
  auth_token: "your-one-time-token",
  name: "my-agent"
)
```

Or with OAuth client credentials:

```ruby
client = DatagroutConduit::Client.bootstrap_identity_oauth(
  url: "https://gateway.datagrout.ai/servers/{uuid}/mcp",
  client_id: "id",
  client_secret: "secret",
  name: "my-agent"
)
```

After bootstrap, subsequent runs auto-discover the saved identity — no tokens needed.

You can also use the registration class directly:

```ruby
private_pem, public_pem = DatagroutConduit::Registration.generate_keypair
response = DatagroutConduit::Registration.register_identity(public_pem, auth_token: "token")
paths = DatagroutConduit::Registration.save_identity(response.cert_pem, private_pem, "~/.conduit", ca_pem: response.ca_cert_pem)
ca_pem = DatagroutConduit::Registration.fetch_ca_cert
```

## Transports

### MCP (default)

```ruby
client = DatagroutConduit::Client.new(
  url: "https://gateway.datagrout.ai/servers/{uuid}/mcp",
  auth: { bearer: "token" },
  transport: :mcp
)
```

### JSONRPC

```ruby
client = DatagroutConduit::Client.new(
  url: "https://gateway.datagrout.ai/servers/{uuid}/jsonrpc",
  auth: { bearer: "token" },
  transport: :jsonrpc
)
```

Both transports send JSON-RPC 2.0 requests via HTTP POST. MCP uses the MCP Streamable HTTP framing. Both configure Faraday SSL with mTLS client certificates when an identity is present.

## Standard MCP Methods

```ruby
client.connect

# Tools
tools = client.list_tools
result = client.call_tool("tool-name", { arg: "value" })

# Resources
resources = client.list_resources
content = client.read_resource("resource://uri")

# Prompts
prompts = client.list_prompts
messages = client.get_prompt("prompt-name", { key: "value" })

client.disconnect
```

## DataGrout Extensions

### Semantic Discovery

Find tools by natural language — 10-100x more token-efficient than listing all tools.

```ruby
results = client.discover(goal: "find unpaid invoices", limit: 10)
results.tools.each do |tool|
  puts "#{tool.name} (score: #{tool.score})"
end
```

### Intelligent Tool Execution

```ruby
result = client.perform("salesforce@1/get_lead@1", { email: "john@example.com" }, demux: false)
```

### Guided Workflows

```ruby
session = client.guide(goal: "create invoice from lead")
puts session.status        # => "in_progress"
puts session.options       # => available choices

session = session.choose("option_a")
result = session.complete  # => final result when status == "completed"
```

### Flow Orchestration

```ruby
plan = [
  { "tool" => "get_lead", "args" => { "email" => "john@example.com" } },
  { "tool" => "create_invoice", "args" => { "lead_id" => "$prev.id" } }
]
result = client.flow_into(plan)
```

### Prism Focus

```ruby
result = client.prism_focus(data: raw_data, lens: "summary")
```

### Cost Estimation

```ruby
estimate = client.estimate_cost("salesforce@1/get_lead@1", { id: "123" })
```

## Cost Tracking

Every tool-call result from DataGrout includes a cost receipt:

```ruby
result = client.call_tool("salesforce@1/get_lead@1", { id: "123" })

meta = DatagroutConduit.extract_meta(result)
if meta
  puts "Credits charged: #{meta.receipt.net_credits}"
  puts "Receipt ID: #{meta.receipt.receipt_id}"
  puts "Balance: #{meta.receipt.balance_after}"

  if meta.receipt.byok.enabled
    puts "BYOK discount: #{meta.receipt.byok.discount_applied}"
  end
end
```

## Behaviors

- **DataGrout URL detection**: `DatagroutConduit.dg_url?(url)` returns `true` for `datagrout.ai` or `datagrout.dev` domains
- **Intelligent interface**: Automatically enabled for DG URLs — `list_tools` filters to non-`@` tools (DG semantic tools only). Disable with `use_intelligent_interface: false`
- **Auto mTLS**: DG URLs automatically attempt identity discovery
- **DG extension warnings**: Non-DG URLs log a one-time warning when DG-specific methods are called
- **Default transport**: `:mcp`

## Error Handling

```ruby
begin
  client.list_tools
rescue DatagroutConduit::NotInitializedError
  client.connect
  retry
rescue DatagroutConduit::McpError => e
  puts "MCP error #{e.code}: #{e.message}"
rescue DatagroutConduit::RateLimitedError => e
  puts "Rate limited: #{e.used}/#{e.limit}"
rescue DatagroutConduit::AuthError => e
  puts "Authentication failed: #{e.message}"
rescue DatagroutConduit::ConnectionError => e
  puts "Connection error: #{e.message}"
rescue DatagroutConduit::ConfigError => e
  puts "Configuration error: #{e.message}"
end
```

## Links

- [DataGrout Library](https://library.datagrout.ai) — Browse and discover integrations
- [Security](https://app.datagrout.ai/security) — Security documentation
- [MCP Inspector](https://app.datagrout.ai/inspector) — Interactive MCP testing
- [JSONRPC Inspector](https://app.datagrout.ai/jsonrpc-inspector) — Interactive JSONRPC testing
- [Labs Papers](https://datagrout.ai/labs) — Research and whitepapers

## License

MIT License. Copyright (c) DataGrout.
