//! Deliverables namespace — work product tracking and retrieval.

use crate::error::Result;
use crate::Client;
use serde_json::{json, Value};

/// Work product registration, listing, and retrieval.
///
/// Obtained via [`Client::deliverables`].
pub struct Deliverables<'a>(pub(crate) &'a Client);

impl<'a> Deliverables<'a> {
    /// Register a work product (`data-grout/deliverables.register`).
    pub async fn register(&self, params: Value) -> Result<Value> {
        self.0.warn_if_not_dg("deliverables.register");
        self.0.ensure_initialized().await?;
        self.0
            .call_dg_tool("data-grout/deliverables.register", params)
            .await
    }

    /// List deliverables with optional semantic search (`data-grout/deliverables.list`).
    pub async fn list(&self, params: Value) -> Result<Value> {
        self.0.warn_if_not_dg("deliverables.list");
        self.0.ensure_initialized().await?;
        self.0
            .call_dg_tool("data-grout/deliverables.list", params)
            .await
    }

    /// Get a specific deliverable by reference (`data-grout/deliverables.get`).
    pub async fn get(&self, ref_id: impl Into<String>) -> Result<Value> {
        self.0.warn_if_not_dg("deliverables.get");
        self.0.ensure_initialized().await?;
        let params = json!({ "ref": ref_id.into() });
        self.0
            .call_dg_tool("data-grout/deliverables.get", params)
            .await
    }
}
