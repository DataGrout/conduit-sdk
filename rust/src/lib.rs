//! # DataGrout Conduit SDK for Rust
//!
//! Production-ready MCP client with enterprise features.
//!
//! ## Features
//!
//! - **MCP Protocol Compliance**: Full JSON-RPC 2.0 over HTTP/SSE support
//! - **DataGrout Extensions**: Semantic discovery, guided workflows, cost tracking
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

#![warn(missing_docs)]
#![warn(rust_2018_idioms)]

pub mod client;
pub mod error;
pub mod protocol;
pub mod transport;
pub mod types;

pub use client::{Client, ClientBuilder, GuidedSession};
pub use error::{Error, Result};
pub use transport::Transport;
pub use types::{
    DiscoverOptions, DiscoverResult, GuideOptions, GuideState, PerformOptions, Receipt, Tool,
};

/// Re-export commonly used types
pub mod prelude {
    pub use crate::client::{Client, ClientBuilder};
    pub use crate::error::{Error, Result};
    pub use crate::transport::Transport;
    pub use crate::types::*;
}
