//! Warden namespace — safety checks, intent verification, and consensus.

use crate::error::Result;
use crate::Client;
use serde_json::Value;

/// Safety gates, intent verification, and multi-model consensus.
///
/// Obtained via [`Client::warden`].
pub struct Warden<'a>(pub(crate) &'a Client);

impl<'a> Warden<'a> {
    /// Run a canary safety check (`data-grout/warden.canary`).
    pub async fn canary(&self, params: Value) -> Result<Value> {
        self.0.warn_if_not_dg("warden.canary");
        self.0.ensure_initialized().await?;
        self.0
            .call_dg_tool("data-grout/warden.canary", params)
            .await
    }

    /// Verify intent before executing an action (`data-grout/warden.intent`).
    pub async fn verify_intent(&self, params: Value) -> Result<Value> {
        self.0.warn_if_not_dg("warden.intent");
        self.0.ensure_initialized().await?;
        self.0
            .call_dg_tool("data-grout/warden.intent", params)
            .await
    }

    /// Adjudicate a dispute or ambiguity (`data-grout/warden.adjudicate`).
    pub async fn adjudicate(&self, params: Value) -> Result<Value> {
        self.0.warn_if_not_dg("warden.adjudicate");
        self.0.ensure_initialized().await?;
        self.0
            .call_dg_tool("data-grout/warden.adjudicate", params)
            .await
    }

    /// Multi-model ensemble consensus check (`data-grout/warden.ensemble`).
    pub async fn ensemble(&self, params: Value) -> Result<Value> {
        self.0.warn_if_not_dg("warden.ensemble");
        self.0.ensure_initialized().await?;
        self.0
            .call_dg_tool("data-grout/warden.ensemble", params)
            .await
    }
}
