# DataGrout Conduit — Rust SDK

Production-ready MCP client with mTLS identity, OAuth 2.1, semantic discovery, and cost tracking.

[![Crates.io](https://img.shields.io/crates/v/datagrout-conduit.svg)](https://crates.io/crates/datagrout-conduit)
[![Documentation](https://docs.rs/datagrout-conduit/badge.svg)](https://docs.rs/datagrout-conduit)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)

## Features

- **MCP Protocol Compliance**: Full JSON-RPC 2.0 over HTTP/SSE support
- **mTLS Identity**: Auto-discovery, bootstrap, and rotation of client certificates
- **OAuth 2.1**: Built-in `client_credentials` token management with auto-refresh
- **DataGrout Extensions**: Semantic discovery, guided workflows, cost tracking
- **Type-Safe**: Strongly typed Rust APIs with comprehensive error handling
- **Async/Await**: Built on Tokio for high performance

## Installation

Add to your `Cargo.toml`:

```toml
[dependencies]
datagrout-conduit = "0.1.0"
tokio = { version = "1", features = ["full"] }
serde_json = "1.0"
```

## Quick Start

```rust
use datagrout_conduit::{ClientBuilder, Transport};
use serde_json::json;

#[tokio::main]
async fn main() -> Result<(), Box<dyn std::error::Error>> {
    // Create client
    let client = ClientBuilder::new()
        .url("https://gateway.datagrout.ai/servers/{uuid}/mcp")
        .transport(Transport::Mcp)
        .auth_bearer("your-token")
        .build()?;

    // Connect and initialize
    client.connect().await?;

    // List tools
    let tools = client.list_tools().await?;
    println!("Found {} tools", tools.len());

    // Call a tool
    let result = client
        .call_tool("salesforce@1/get_lead@1", json!({"id": "123"}))
        .await?;

    Ok(())
}
```

## DataGrout Extensions

### Semantic Discovery

```rust
// 10-100x token efficiency via semantic search
let results = client.discover()
    .query("get lead by email")
    .integration("salesforce")
    .limit(10)
    .min_score(0.7)
    .execute()
    .await?;

for tool in results.tools {
    println!("{} (score: {:.2})", tool.tool.name, tool.score);
}
```

### Guided Workflows

```rust
// Step-by-step workflow with user choices
let mut session = client.guide()
    .goal("create invoice from lead")
    .execute()
    .await?;

while session.status() != "completed" {
    if let Some(options) = session.options() {
        // Show options to user and get choice
        let chosen = options[0].id.clone();
        session = session.choose(&chosen).await?;
    }
}

let result = session.complete().await?;
```

### Direct Tool Execution

```rust
// Execute with tracking and receipts
let result = client.perform("salesforce@1/get_lead@1")
    .args(json!({"email": "john@example.com"}))
    .demux(false)
    .execute()
    .await?;

// Get cost breakdown
if let Some(receipt) = client.last_receipt().await {
    println!("Cost: {} credits", receipt.total_cost);
}
```

## Transports

### MCP Transport (Official Protocol)

```rust
let client = ClientBuilder::new()
    .url("https://gateway.datagrout.ai/servers/{uuid}/mcp")
    .transport(Transport::Mcp)  // Full MCP protocol over SSE
    .build()?;
```

**Features:**
- Server-Sent Events (SSE)
- Real-time notifications
- Persistent connection
- Full MCP compliance

### JSON-RPC Transport (HTTP)

```rust
let client = ClientBuilder::new()
    .url("https://api.example.com/rpc")
    .transport(Transport::JsonRpc)  // Simple HTTP POST
    .build()?;
```

**Features:**
- Lightweight HTTP POST
- Stateless requests
- Easier debugging
- Lower overhead

## Authentication

### Bearer Token

```rust
let client = ClientBuilder::new()
    .url("...")
    .auth_bearer("your-token")
    .build()?;
```

### API Key

```rust
let client = ClientBuilder::new()
    .url("...")
    .auth_api_key("your-key")
    .build()?;
```

### Basic Auth

```rust
let client = ClientBuilder::new()
    .url("...")
    .auth_basic("username", "password")
    .build()?;
```

### OAuth 2.1 (client_credentials)

```rust
let client = ClientBuilder::new()
    .url("https://gateway.datagrout.ai/servers/{uuid}/mcp")
    .auth_client_credentials("my_client_id", "my_client_secret")
    .build()?;
```

The SDK automatically fetches, caches, and refreshes JWTs before they expire.

### mTLS (Mutual TLS)

After bootstrapping, the client certificate handles authentication at the TLS layer — no tokens needed.

```rust
// Auto-discover from env vars, CONDUIT_IDENTITY_DIR, or ~/.conduit/
let client = ClientBuilder::new()
    .url("https://gateway.datagrout.ai/servers/{uuid}/mcp")
    .with_identity_auto()
    .build()?;

// Multiple agents on one machine
let client = ClientBuilder::new()
    .url("...")
    .identity_dir("/opt/agents/agent-a/.conduit")
    .with_identity_auto()
    .build()?;
```

#### Identity Auto-Discovery Order

1. `CONDUIT_MTLS_CERT` + `CONDUIT_MTLS_KEY` environment variables (inline PEM)
2. `CONDUIT_IDENTITY_DIR` environment variable (directory path)
3. `~/.conduit/identity.pem` + `~/.conduit/identity_key.pem`
4. `.conduit/` relative to the current working directory

For DataGrout URLs (`*.datagrout.ai`), auto-discovery runs silently in `build()`.

#### Bootstrapping an mTLS Identity

First-run provisioning — generates a keypair, registers with the DataGrout CA, and saves certs locally. After this, the token is never needed again. Requires the `registration` feature.

```rust
// First run: token needed for registration
let client = ClientBuilder::new()
    .url("https://gateway.datagrout.ai/servers/{uuid}/mcp")
    .bootstrap_identity("your-access-token", "my-laptop")
    .await?
    .build()?;

// Or bootstrap with OAuth 2.1 client_credentials
let client = ClientBuilder::new()
    .url("https://gateway.datagrout.ai/servers/{uuid}/mcp")
    .bootstrap_identity_oauth("client_id", "client_secret", "my-laptop")
    .await?
    .build()?;

// Subsequent runs: no token needed, mTLS auto-discovered
let client = ClientBuilder::new()
    .url("https://gateway.datagrout.ai/servers/{uuid}/mcp")
    .build()?;
```

## Error Handling

```rust
use datagrout_conduit::error::{Error, Result};

match client.call_tool("tool", json!({})).await {
    Ok(result) => println!("Success: {:?}", result),
    Err(Error::Mcp { code, message, .. }) => {
        eprintln!("MCP error {}: {}", code, message);
    }
    Err(Error::NotInitialized) => {
        eprintln!("Call connect() first");
    }
    Err(e) if e.is_retriable() => {
        eprintln!("Retriable error: {}", e);
        // Retry logic here
    }
    Err(e) => eprintln!("Fatal error: {}", e),
}
```

## Advanced Usage

### Retry Configuration

```rust
let client = ClientBuilder::new()
    .url("...")
    .max_retries(5)  // Retry up to 5 times on "not initialized"
    .build()?;
```

### Intelligent Interface (semantic discovery only)

```rust
let client = ClientBuilder::new()
    .url("...")
    .use_intelligent_interface(true)  // Expose only semantic discovery tools
    .build()?;
```

### Resource Management

```rust
// List resources
let resources = client.list_resources().await?;

// Read a resource
let contents = client.read_resource("file://path/to/file").await?;
```

### Prompts

```rust
// List prompts
let prompts = client.list_prompts().await?;

// Get a prompt
let messages = client.get_prompt(
    "template_name",
    Some(json!({"var": "value"}))
).await?;
```

## Examples

See the [`examples/`](examples/) directory:

- [`basic.rs`](examples/basic.rs) - Basic MCP operations
- [`discovery.rs`](examples/discovery.rs) - Semantic discovery and perform
- [`guided_workflow.rs`](examples/guided_workflow.rs) - Step-by-step workflows

Run examples:

```bash
cargo run --example basic
cargo run --example discovery
cargo run --example guided_workflow
```

## Testing

```bash
# Run unit tests
cargo test

# Run integration tests (requires server)
cargo test --ignored

# Run with logging
RUST_LOG=debug cargo test
```

## Performance

Benchmarks on M1 Max:

- **Client creation**: 50μs
- **Request serialization**: 2μs
- **Response parsing**: 3μs
- **Full round-trip**: 15-50ms (network-bound)

## Architecture

```
┌──────────────────────┐
│   Your Application   │
└──────────┬───────────┘
           │
           ▼
┌──────────────────────┐
│  Conduit Client      │
│  • Builder           │
│  • MCP Protocol      │
│  • Extensions        │
└──────────┬───────────┘
           │
    ┌──────┴──────┐
    ▼             ▼
┌─────────┐  ┌──────────┐
│   MCP   │  │ JSON-RPC │
│Transport│  │Transport │
└────┬────┘  └─────┬────┘
     │             │
     └──────┬──────┘
            ▼
┌───────────────────────┐
│  DataGrout Gateway    │
│  (MCP Server)         │
└───────────────────────┘
```

## Comparison with Other Languages

| Feature | Rust | Python | TypeScript |
|---------|------|--------|------------|
| **mTLS Identity** | ✅ Full | ✅ Full | ✅ Full |
| **OAuth 2.1** | ✅ Full | ✅ Full | ✅ Full |
| **Bootstrap** | ✅ Token + OAuth | ✅ Token + OAuth | ✅ Token |
| **Type Safety** | ✅ Strong | ⚠️ Runtime | ✅ Compile-time |
| **Async** | ✅ Tokio | ✅ asyncio | ✅ Promises |

## Contributing

Contributions welcome! Please read [CONTRIBUTING.md](../CONTRIBUTING.md).

## License

MIT License - see [LICENSE](../LICENSE) for details.

## Links

- **Documentation**: https://docs.rs/datagrout-conduit
- **Repository**: https://github.com/datagrout/conduit
- **Homepage**: https://conduit.datagrout.dev
- **MCP Spec**: https://modelcontextprotocol.io

## Support

- **Issues**: https://github.com/datagrout/conduit/issues
- **Discord**: https://discord.gg/datagrout
- **Email**: hello@datagrout.ai

---

**Made with ❤️ by DataGrout**
