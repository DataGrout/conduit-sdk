//! Prism namespace — data transformation, charting, rendering, and export.

use crate::client::{ChartBuilder, PrismFocusBuilder, RefractBuilder};
use crate::error::Result;
use crate::Client;
use serde_json::Value;

/// Data transformation, charting, rendering, and type bridging.
///
/// Obtained via [`Client::prism`].
pub struct Prism<'a>(pub(crate) &'a Client);

impl<'a> Prism<'a> {
    /// AI-driven data transformation / normalisation (`data-grout/prism.refract`).
    ///
    /// Returns a [`RefractBuilder`].  `goal` describes the desired
    /// transformation in natural language; `payload` is the raw input data.
    pub fn refract(&self, goal: impl Into<String>, payload: Value) -> RefractBuilder<'a> {
        self.0.warn_if_not_dg("prism.refract");
        RefractBuilder::new(self.0, goal.into(), payload)
    }

    /// AI-driven charting (`data-grout/prism.chart`).
    ///
    /// Returns a [`ChartBuilder`].  `goal` is a natural language description
    /// of what to visualise; `payload` is the input data.
    pub fn chart(&self, goal: impl Into<String>, payload: Value) -> ChartBuilder<'a> {
        self.0.warn_if_not_dg("prism.chart");
        ChartBuilder::new(self.0, goal.into(), payload)
    }

    /// Generate a document toward a natural-language goal (`data-grout/prism.render`).
    ///
    /// Params typically include `goal`, `payload`, `format` (e.g. `"markdown"`,
    /// `"html"`, `"pdf"`), and optionally `sections`.
    pub async fn render(&self, params: Value) -> Result<Value> {
        self.0.warn_if_not_dg("prism.render");
        self.0.ensure_initialized().await?;
        self.0.call_dg_tool("data-grout/prism.render", params).await
    }

    /// Convert content to another format (`data-grout/prism.export`).
    ///
    /// Params: `content`, `format` (e.g. `"csv"`, `"xlsx"`, `"pdf"`), and
    /// optionally `style`, `metadata`.
    pub async fn export(&self, params: Value) -> Result<Value> {
        self.0.warn_if_not_dg("prism.export");
        self.0.ensure_initialized().await?;
        self.0.call_dg_tool("data-grout/prism.export", params).await
    }

    /// Semantic type transformation (`data-grout/prism.focus`).
    ///
    /// Returns a [`PrismFocusBuilder`].  Set `.data()`, `.source_type()`, and
    /// `.target_type()` then call `.execute()`.
    pub fn focus(&self) -> PrismFocusBuilder<'a> {
        self.0.warn_if_not_dg("prism.focus");
        PrismFocusBuilder::new(self.0)
    }
}
