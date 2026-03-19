//! Flow namespace — orchestration, routing, approvals, and execution history.

use crate::client::FlowIntoBuilder;
use crate::error::Result;
use crate::Client;
use serde_json::{json, Value};

/// Multi-step orchestration, conditional routing, human-in-the-loop gates,
/// and execution history.
///
/// Obtained via [`Client::flow`].
pub struct Flow<'a>(pub(crate) &'a Client);

impl<'a> Flow<'a> {
    /// Execute a pre-built multi-step workflow plan (`data-grout/flow.into`).
    ///
    /// `plan` is the ordered list of tool-call steps.  Returns a
    /// [`FlowIntoBuilder`] for optional configuration before execution.
    pub fn run(&self, plan: Vec<Value>) -> FlowIntoBuilder<'a> {
        self.0.warn_if_not_dg("flow.into");
        FlowIntoBuilder::new(self.0, plan)
    }

    /// Conditional dispatch with predicate-based branching (`data-grout/flow.route`).
    ///
    /// `branches` is an ordered array of `{ when, then }` objects.  The first
    /// branch whose `when` predicate matches the `payload` (or `cache_ref`
    /// result) fires its `then` target — which can be any tool name, including
    /// another `flow.into` plan or a saved skill.
    ///
    /// # Parameters
    ///
    /// - `branches` (required) — ordered predicate/target pairs
    /// - `payload` — inline data to evaluate predicates against
    /// - `cache_ref` — reference to a cached result to evaluate instead
    /// - `else_target` — fallback tool when no branch matches
    pub async fn route(&self, params: Value) -> Result<Value> {
        self.0.warn_if_not_dg("flow.route");
        self.0.ensure_initialized().await?;
        self.0.call_dg_tool("data-grout/flow.route", params).await
    }

    /// Pause workflow for human approval (`data-grout/flow.request-approval`).
    ///
    /// Params: `action`, and optionally `details`, `reason`, `context`.
    pub async fn request_approval(&self, params: Value) -> Result<Value> {
        self.0.warn_if_not_dg("flow.request-approval");
        self.0.ensure_initialized().await?;
        self.0
            .call_dg_tool("data-grout/flow.request-approval", params)
            .await
    }

    /// Request user clarification for missing fields (`data-grout/flow.request-feedback`).
    ///
    /// Params: `missing_fields` (array), `reason`, and optionally `current_data`,
    /// `suggestions`, `context`.
    pub async fn request_feedback(&self, params: Value) -> Result<Value> {
        self.0.warn_if_not_dg("flow.request-feedback");
        self.0.ensure_initialized().await?;
        self.0
            .call_dg_tool("data-grout/flow.request-feedback", params)
            .await
    }

    /// List recent tool executions (`data-grout/inspect.execution-history`).
    ///
    /// Params: optional `limit`, `offset`, `status`, `refractions_only`.
    pub async fn history(&self, params: Value) -> Result<Value> {
        self.0.warn_if_not_dg("inspect.execution-history");
        self.0.ensure_initialized().await?;
        self.0
            .call_dg_tool("data-grout/inspect.execution-history", params)
            .await
    }

    /// Get details for a specific execution (`data-grout/inspect.execution-details`).
    pub async fn details(&self, execution_id: impl Into<String>) -> Result<Value> {
        self.0.warn_if_not_dg("inspect.execution-details");
        self.0.ensure_initialized().await?;
        let params = json!({ "execution_id": execution_id.into() });
        self.0
            .call_dg_tool("data-grout/inspect.execution-details", params)
            .await
    }
}
