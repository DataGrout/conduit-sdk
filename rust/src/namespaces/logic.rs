//! Logic Cell namespace — agent memory, facts, constraints, and hypotheticals.

use crate::error::Result;
use crate::Client;
use serde_json::{json, Value};

/// Persistent agent memory backed by a Prolog logic cell.
///
/// Obtained via [`Client::logic`].
pub struct Logic<'a>(pub(crate) &'a Client);

impl<'a> Logic<'a> {
    /// Assert a single fact (`data-grout/logic.remember`).
    pub async fn remember(&self, statement: impl Into<String>) -> Result<Value> {
        self.0.warn_if_not_dg("logic.remember");
        self.0.ensure_initialized().await?;
        let params = json!({ "statement": statement.into() });
        self.0
            .call_dg_tool("data-grout/logic.remember", params)
            .await
    }

    /// Assert multiple facts in a single call (`data-grout/logic.remember`).
    pub async fn remember_facts(&self, facts: Value) -> Result<Value> {
        self.0.warn_if_not_dg("logic.remember");
        self.0.ensure_initialized().await?;
        let params = json!({ "facts": facts });
        self.0
            .call_dg_tool("data-grout/logic.remember", params)
            .await
    }

    /// Query with a natural language question (`data-grout/logic.query`).
    pub async fn query(&self, question: impl Into<String>) -> Result<Value> {
        self.0.warn_if_not_dg("logic.query");
        self.0.ensure_initialized().await?;
        let params = json!({ "question": question.into() });
        self.0.call_dg_tool("data-grout/logic.query", params).await
    }

    /// Query with an upper bound on returned results (`data-grout/logic.query`).
    pub async fn query_with_limit(&self, question: impl Into<String>, limit: u32) -> Result<Value> {
        self.0.warn_if_not_dg("logic.query");
        self.0.ensure_initialized().await?;
        let params = json!({ "question": question.into(), "limit": limit });
        self.0.call_dg_tool("data-grout/logic.query", params).await
    }

    /// Query using an explicit pattern list (`data-grout/logic.query`).
    pub async fn query_patterns(&self, patterns: Value) -> Result<Value> {
        self.0.warn_if_not_dg("logic.query");
        self.0.ensure_initialized().await?;
        let params = json!({ "patterns": patterns });
        self.0.call_dg_tool("data-grout/logic.query", params).await
    }

    /// Remove specific facts by their opaque handles (`data-grout/logic.forget`).
    pub async fn forget(&self, handles: Vec<String>) -> Result<Value> {
        self.0.warn_if_not_dg("logic.forget");
        self.0.ensure_initialized().await?;
        let params = json!({ "handles": handles });
        self.0.call_dg_tool("data-grout/logic.forget", params).await
    }

    /// Remove all facts matching a pattern (`data-grout/logic.forget`).
    pub async fn forget_pattern(&self, pattern: impl Into<String>) -> Result<Value> {
        self.0.warn_if_not_dg("logic.forget");
        self.0.ensure_initialized().await?;
        let params = json!({ "pattern": pattern.into() });
        self.0.call_dg_tool("data-grout/logic.forget", params).await
    }

    /// Add a constraint rule (`data-grout/logic.constrain`).
    pub async fn constrain(&self, rule: impl Into<String>) -> Result<Value> {
        self.0.warn_if_not_dg("logic.constrain");
        self.0.ensure_initialized().await?;
        let params = json!({ "rule": rule.into() });
        self.0
            .call_dg_tool("data-grout/logic.constrain", params)
            .await
    }

    /// Add a tagged constraint rule (`data-grout/logic.constrain`).
    pub async fn constrain_tagged(
        &self,
        rule: impl Into<String>,
        tag: impl Into<String>,
    ) -> Result<Value> {
        self.0.warn_if_not_dg("logic.constrain");
        self.0.ensure_initialized().await?;
        let params = json!({ "rule": rule.into(), "tag": tag.into() });
        self.0
            .call_dg_tool("data-grout/logic.constrain", params)
            .await
    }

    /// Reflect on everything the logic cell currently knows (`data-grout/logic.reflect`).
    pub async fn reflect(&self) -> Result<Value> {
        self.0.warn_if_not_dg("logic.reflect");
        self.0.ensure_initialized().await?;
        self.0
            .call_dg_tool("data-grout/logic.reflect", json!({}))
            .await
    }

    /// Reflect on a specific entity (`data-grout/logic.reflect`).
    pub async fn reflect_entity(
        &self,
        entity: impl Into<String>,
        summary_only: bool,
    ) -> Result<Value> {
        self.0.warn_if_not_dg("logic.reflect");
        self.0.ensure_initialized().await?;
        let params = json!({ "entity": entity.into(), "summary_only": summary_only });
        self.0
            .call_dg_tool("data-grout/logic.reflect", params)
            .await
    }

    /// Hydrate the logic cell from external data (`data-grout/logic.hydrate`).
    pub async fn hydrate(&self, params: Value) -> Result<Value> {
        self.0.warn_if_not_dg("logic.hydrate");
        self.0.ensure_initialized().await?;
        self.0
            .call_dg_tool("data-grout/logic.hydrate", params)
            .await
    }

    /// Export the logic cell contents (`data-grout/logic.export`).
    pub async fn export_cell(&self, params: Value) -> Result<Value> {
        self.0.warn_if_not_dg("logic.export");
        self.0.ensure_initialized().await?;
        self.0.call_dg_tool("data-grout/logic.export", params).await
    }

    /// Import facts into the logic cell (`data-grout/logic.import`).
    pub async fn import_cell(&self, params: Value) -> Result<Value> {
        self.0.warn_if_not_dg("logic.import");
        self.0.ensure_initialized().await?;
        self.0.call_dg_tool("data-grout/logic.import", params).await
    }

    /// Tabulate logic cell contents into a structured table (`data-grout/logic.tabulate`).
    pub async fn tabulate(&self, params: Value) -> Result<Value> {
        self.0.warn_if_not_dg("logic.tabulate");
        self.0.ensure_initialized().await?;
        self.0
            .call_dg_tool("data-grout/logic.tabulate", params)
            .await
    }

    /// Manage hypothetical worlds / scenarios (`data-grout/logic.worlds`).
    pub async fn worlds(&self, params: Value) -> Result<Value> {
        self.0.warn_if_not_dg("logic.worlds");
        self.0.ensure_initialized().await?;
        self.0.call_dg_tool("data-grout/logic.worlds", params).await
    }
}
