//! Ephemerals namespace — cache management and inspection.

use crate::error::Result;
use crate::Client;
use serde_json::{json, Value};

/// Cache listing and inspection for ephemeral (cached) tool results.
///
/// Obtained via [`Client::ephemerals`].
pub struct Ephemerals<'a>(pub(crate) &'a Client);

impl<'a> Ephemerals<'a> {
    /// List cached results (`data-grout/ephemerals.list`).
    pub async fn list(&self, params: Value) -> Result<Value> {
        self.0.warn_if_not_dg("ephemerals.list");
        self.0.ensure_initialized().await?;
        self.0
            .call_dg_tool("data-grout/ephemerals.list", params)
            .await
    }

    /// Inspect a specific cache entry (`data-grout/ephemerals.inspect`).
    pub async fn inspect(&self, cache_ref: impl Into<String>) -> Result<Value> {
        self.0.warn_if_not_dg("ephemerals.inspect");
        self.0.ensure_initialized().await?;
        let params = json!({ "cache_ref": cache_ref.into() });
        self.0
            .call_dg_tool("data-grout/ephemerals.inspect", params)
            .await
    }
}
