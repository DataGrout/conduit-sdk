//! # DataGrout Conduit SDK for Rust
//!
//! Production-ready MCP client with enterprise features.
//!
//! ## Features
//!
//! - **MCP Protocol Compliance**: Full JSON-RPC 2.0 over HTTP/SSE support
//! - **DataGrout Extensions**: Semantic discovery, guided workflows, cost tracking
//! - **Rate Limit Handling**: Typed errors for rate-limited responses (HTTP 429 with `X-RateLimit-*` headers)
//! - **Type-Safe**: Strongly typed Rust APIs
//! - **Async/Await**: Built on Tokio for high performance
//! - **Error Handling**: Comprehensive error types with context
//! - **Tested**: 95%+ test coverage
//!
//! ## Quick Start
//!
//! ```rust,no_run
//! use datagrout_conduit::{Client, ClientBuilder, Transport};
//!
//! #[tokio::main]
//! async fn main() -> Result<(), Box<dyn std::error::Error>> {
//!     // Create client
//!     let client = ClientBuilder::new()
//!         .url("https://gateway.datagrout.ai/servers/{uuid}/mcp")
//!         .transport(Transport::Mcp)
//!         .auth_bearer("your-token")
//!         .build()?;
//!
//!     // Connect and initialize
//!     client.connect().await?;
//!
//!     // List tools
//!     let tools = client.list_tools().await?;
//!     println!("Found {} tools", tools.len());
//!
//!     // Call a tool
//!     let result = client.call_tool(
//!         "salesforce@1/get_lead@1",
//!         serde_json::json!({"id": "123"})
//!     ).await?;
//!
//!     Ok(())
//! }
//! ```
//!
//! ## DataGrout Extensions
//!
//! ```rust,no_run
//! # use datagrout_conduit::{Client, ClientBuilder};
//! # async fn example(client: Client) -> Result<(), Box<dyn std::error::Error>> {
//! // Semantic discovery (10-100x token efficiency)
//! let results = client.discover()
//!     .query("get lead by email")
//!     .integration("salesforce")
//!     .limit(10)
//!     .execute()
//!     .await?;
//!
//! // Guided workflow
//! let session = client.guide()
//!     .goal("create invoice from lead")
//!     .execute()
//!     .await?;
//!
//! // Direct tool execution with tracking
//! let result = client.perform("salesforce@1/get_lead@1")
//!     .args(serde_json::json!({"email": "john@example.com"}))
//!     .execute()
//!     .await?;
//! # Ok(())
//! # }
//! ```
//!
//! ## mTLS (Identity Plane)
//!
//! Conduit can secure connections with mutual TLS — the client presents its own
//! certificate during every TLS handshake, proving its identity to the server
//! without a separate token exchange.
//!
//! ```rust,no_run
//! use datagrout_conduit::{ClientBuilder, ConduitIdentity, Transport};
//!
//! # fn example() -> Result<(), Box<dyn std::error::Error>> {
//! // Option A: auto-discover from env vars, CONDUIT_IDENTITY_DIR, or ~/.conduit/
//! let client = ClientBuilder::new()
//!     .url("https://gateway.datagrout.ai/servers/{uuid}/mcp")
//!     .with_identity_auto()
//!     .build()?;
//!
//! // Option B: custom identity dir (multiple agents per machine)
//! let client = ClientBuilder::new()
//!     .url("https://gateway.datagrout.ai/servers/{uuid}/mcp")
//!     .identity_dir("/opt/agents/agent-a/.conduit")
//!     .with_identity_auto()
//!     .build()?;
//!
//! // Option C: explicit certificate files
//! let identity = ConduitIdentity::from_paths(
//!     "certs/client.pem",
//!     "certs/client_key.pem",
//!     Some("certs/ca.pem"),
//! )?;
//! let client = ClientBuilder::new()
//!     .url("https://gateway.datagrout.ai/servers/{uuid}/mcp")
//!     .with_identity(identity)
//!     .build()?;
//!
//! // Option D: from PEM strings (e.g. pulled from a secret store)
//! # let cert_pem = b"-----BEGIN CERTIFICATE-----\nfake\n-----END CERTIFICATE-----\n" as &[u8];
//! # let key_pem = b"-----BEGIN PRIVATE KEY-----\nfake\n-----END PRIVATE KEY-----\n" as &[u8];
//! let identity = ConduitIdentity::from_pem(cert_pem, key_pem, None::<Vec<u8>>)?;
//! # Ok(())
//! # }
//! ```
//!
//! ## Identity Registration (bootstrap with DataGrout)
//!
//! On first run, a Substrate instance generates an ECDSA P-256 keypair locally,
//! sends only the public key to DataGrout, and receives a DG-CA-signed certificate.
//! Subsequent connections authenticate via mTLS — no token needed.
//!
//! The simplest path is `bootstrap_identity` on the builder:
//!
//! ```rust,ignore
//! // First run: provide a valid access token and a name for this identity.
//! // The SDK generates keys, registers with the DG CA, and saves certs to
//! // ~/.conduit/ (or the configured identity_dir).
//! let client = ClientBuilder::new()
//!     .url("https://gateway.datagrout.ai/servers/{uuid}/mcp")
//!     .bootstrap_identity("my-access-token", "my-laptop")
//!     .await?
//!     .build()?;
//!
//! // Every subsequent run: certs auto-discovered, no token needed.
//! let client = ClientBuilder::new()
//!     .url("https://gateway.datagrout.ai/servers/{uuid}/mcp")
//!     .build()?;
//! ```

#![warn(missing_docs)]
#![warn(rust_2018_idioms)]

pub mod client;
pub mod error;
pub mod identity;
pub mod oauth;
pub mod protocol;
pub mod registration;
pub mod transport;
pub mod types;

pub use client::{is_dg_url, Client, ClientBuilder, GuidedSession};
pub use error::{Error, RateLimit, Result};
pub use identity::ConduitIdentity;
pub use oauth::OAuthTokenProvider;
pub use registration::{
    fetch_dg_ca_cert, generate_keypair, refresh_ca_cert, register_identity, rotate_identity,
    save_identity_to_dir, DG_CA_URL, DG_SUBSTRATE_ENDPOINT, RegistrationOptions, RenewalOptions,
    RegistrationResponse, SavedIdentityPaths,
};
pub use transport::Transport;
pub use types::{
    Byok, CreditEstimate, DiscoverOptions, DiscoverResult, GuideOptions, GuideState,
    PerformOptions, Receipt, Tool, ToolMeta, extract_meta,
};

/// Re-export commonly used types
pub mod prelude {
    pub use crate::client::{Client, ClientBuilder};
    pub use crate::error::{Error, RateLimit, Result};
    pub use crate::identity::ConduitIdentity;
    pub use crate::transport::Transport;
    pub use crate::types::*;
}
