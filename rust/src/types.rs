//! DataGrout-specific types and extensions

use serde::{Deserialize, Serialize};
use serde_json::Value;

/// Tool definition
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Tool {
    /// Tool name
    pub name: String,
    /// Tool description
    #[serde(skip_serializing_if = "Option::is_none")]
    pub description: Option<String>,
    /// Input schema
    #[serde(rename = "inputSchema", skip_serializing_if = "Option::is_none")]
    pub input_schema: Option<Value>,
    /// Tool annotations
    #[serde(skip_serializing_if = "Option::is_none")]
    pub annotations: Option<Value>,
}

/// BYOK (Bring Your Own Key) discount details embedded in a receipt.
#[derive(Debug, Clone, Default, Serialize, Deserialize)]
pub struct Byok {
    /// Whether the user has BYOK enabled for this server.
    pub enabled: bool,
    /// Absolute discount applied (in credits).
    pub discount_applied: f64,
    /// Discount rate as a fraction (0.0–1.0).
    pub discount_rate: f64,
}

/// Cost receipt attached to every tool-call result under `result["_datagrout"]["receipt"]`.
///
/// DG embeds this in the `_datagrout` sibling key of the tool result JSON.
/// Use [`extract_meta`] to pull it out cleanly.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Receipt {
    /// DG-internal receipt identifier (`rcp_…`).
    pub receipt_id: String,
    /// DB transaction ID (set only when a user account was charged).
    #[serde(skip_serializing_if = "Option::is_none")]
    pub transaction_id: Option<String>,
    /// ISO-8601 timestamp of the charge.
    pub timestamp: String,
    /// Pre-execution credit estimate.
    pub estimated_credits: f64,
    /// Actual credits charged after execution.
    pub actual_credits: f64,
    /// Net credits after discounts.
    pub net_credits: f64,
    /// Credits saved via caching or BYOK.
    pub savings: f64,
    /// Bonus savings (e.g. loyalty tier).
    pub savings_bonus: f64,
    /// Account balance before the charge (set only when a user was charged).
    #[serde(skip_serializing_if = "Option::is_none")]
    pub balance_before: Option<f64>,
    /// Account balance after the charge.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub balance_after: Option<f64>,
    /// Per-component credit breakdown (`{ "base": 1.0, "semantic_guard": 0.5, … }`).
    pub breakdown: Value,
    /// BYOK discount details.
    #[serde(default)]
    pub byok: Byok,
}

/// Pre-execution credit estimate embedded under `result["_datagrout"]["credit_estimate"]`.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct CreditEstimate {
    /// Total estimated credits before execution.
    pub estimated_total: f64,
    /// Actual credits charged.
    pub actual_total: f64,
    /// Net credits after discounts.
    pub net_total: f64,
    /// Per-component breakdown.
    pub breakdown: Value,
}

/// The `_datagrout` block that DataGrout appends to every tool-call result.
///
/// # Example
///
/// ```rust,no_run
/// use datagrout_conduit::extract_meta;
/// # use serde_json::json;
/// # let result = json!({"value": 42, "_datagrout": {"receipt": {"receipt_id": "rcp_abc", "timestamp": "2026-01-01T00:00:00Z", "estimated_credits": 1.0, "actual_credits": 1.0, "net_credits": 1.0, "savings": 0.0, "savings_bonus": 0.0, "breakdown": {}, "byok": {"enabled": false, "discount_applied": 0.0, "discount_rate": 0.0}}, "credit_estimate": {"estimated_total": 1.0, "actual_total": 1.0, "net_total": 1.0, "breakdown": {}}}});
/// if let Some(meta) = extract_meta(&result) {
///     println!("Charged {} credits", meta.receipt.net_credits);
///     println!("Remaining balance: {:?}", meta.receipt.balance_after);
/// }
/// ```
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ToolMeta {
    /// Charge receipt for the tool call.
    pub receipt: Receipt,
    /// Pre-execution estimate (present when estimation was requested).
    #[serde(skip_serializing_if = "Option::is_none")]
    pub credit_estimate: Option<CreditEstimate>,
}

/// Extract the DataGrout metadata block from a tool-call result.
///
/// Checks `_datagrout` first (current format), then falls back to `_meta`
/// for backward compatibility with older gateway responses.
///
/// Returns `None` when the result contains neither key (e.g. upstream
/// servers that don't go through the DG gateway).
pub fn extract_meta(result: &Value) -> Option<ToolMeta> {
    result
        .get("_datagrout")
        .or_else(|| result.get("_meta"))
        .and_then(|m| serde_json::from_value(m.clone()).ok())
}

/// Discovery options
#[derive(Debug, Clone, Default)]
pub struct DiscoverOptions {
    /// Search query
    pub query: Option<String>,
    /// Natural language goal
    pub goal: Option<String>,
    /// Maximum results to return
    pub limit: usize,
    /// Minimum semantic score (0.0-1.0)
    pub min_score: f64,
    /// Filter by integrations
    pub integrations: Vec<String>,
    /// Filter by servers
    pub servers: Vec<String>,
}

/// Discovery result — matches the response shape of `data-grout/discovery.discover`.
///
/// DG returns `results` (not `tools`) and `goal_used` (not `query`), so we use
/// serde rename attributes to keep the Rust API idiomatic while matching the wire.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct DiscoverResult {
    /// Matching tools (wire key: `results`)
    #[serde(rename = "results", default)]
    pub tools: Vec<DiscoveredTool>,
    /// Goal / query used (wire key: `goal_used`)
    #[serde(rename = "goal_used")]
    pub query: Option<String>,
    /// Human-readable instruction for how to use the results
    #[serde(skip_serializing_if = "Option::is_none")]
    pub instruction: Option<String>,
}

/// Discovered tool with semantic similarity score.
///
/// DG returns `tool_name` (not `name`), `input_contract` (not `input_schema`),
/// so we use serde rename to preserve a stable Rust API.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct DiscoveredTool {
    /// Canonical tool name (wire key: `tool_name`)
    #[serde(rename = "tool_name")]
    pub name: String,
    /// Semantic similarity score (0.0 – 1.0)
    pub score: f64,
    /// Cosine distance from the query embedding
    #[serde(default)]
    pub distance: f64,
    /// Human-readable description
    #[serde(default)]
    pub description: String,
    /// Integration / provider name
    #[serde(skip_serializing_if = "Option::is_none")]
    pub integration: Option<String>,
    /// Server ID (present for multiplexed tools)
    #[serde(skip_serializing_if = "Option::is_none")]
    pub server: Option<String>,
    /// Input schema (wire key: `input_contract`)
    #[serde(rename = "input_contract", skip_serializing_if = "Option::is_none")]
    pub input_schema: Option<serde_json::Value>,
    /// Output schema (wire key: `output_contract`)
    #[serde(rename = "output_contract", skip_serializing_if = "Option::is_none")]
    pub output_schema: Option<serde_json::Value>,
}

/// Perform (tool execution) options
#[derive(Debug, Clone, Default)]
pub struct PerformOptions {
    /// Enable demultiplexing
    pub demux: bool,
    /// Demux mode ("strict" or "fuzzy")
    pub demux_mode: String,
}

/// Guide (workflow) options
#[derive(Debug, Clone, Default)]
pub struct GuideOptions {
    /// Natural language goal
    pub goal: Option<String>,
    /// Session ID (for continuing)
    pub session_id: Option<String>,
    /// Choice ID (for advancing)
    pub choice: Option<String>,
}

/// Guide state (workflow session)
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct GuideState {
    /// Session ID
    pub session_id: String,
    /// Current status
    pub status: String,
    /// Available options
    #[serde(skip_serializing_if = "Option::is_none")]
    pub options: Option<Vec<GuideOption>>,
    /// Final result (if completed)
    #[serde(skip_serializing_if = "Option::is_none")]
    pub result: Option<Value>,
    /// Current step
    #[serde(skip_serializing_if = "Option::is_none")]
    pub step: Option<usize>,
}

/// Guide option (user choice)
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct GuideOption {
    /// Option ID
    pub id: String,
    /// Display label
    pub label: String,
    /// Description
    #[serde(skip_serializing_if = "Option::is_none")]
    pub description: Option<String>,
}

/// Flow options
#[derive(Debug, Clone, Default)]
pub struct FlowOptions {
    /// Target semantic type
    pub target_type: String,
    /// Source data
    pub source_data: Value,
}

/// Flow result
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct FlowResult {
    /// Transformed data
    pub result: Value,
    /// Transformations applied
    pub transformations: Vec<String>,
}

/// Prism focus options
#[derive(Debug, Clone, Default)]
pub struct PrismFocusOptions {
    /// Source data
    pub data: Value,
    /// Lens type
    pub lens: String,
}

/// Prism focus result
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct PrismFocusResult {
    /// Focused data
    pub result: Value,
    /// Metadata
    pub metadata: Value,
}

/// Plan options (used by `PlanBuilder`)
#[derive(Debug, Clone, Default)]
pub struct PlanOptions {
    /// Natural language goal
    pub goal: Option<String>,
    /// Semantic query string
    pub query: Option<String>,
    /// Scope to a specific server ID
    pub server: Option<String>,
    /// Number of candidate steps to consider
    pub k: Option<u32>,
    /// Governance policy object
    pub policy: Option<Value>,
    /// Pre-existing knowledge / context hints
    pub have: Option<Value>,
    /// Whether the result should include call handles for each step
    pub return_call_handles: bool,
    /// Whether virtual skills should be surfaced in the plan
    pub expose_virtual_skills: bool,
    /// Per-step LLM model overrides
    pub model_overrides: Option<Value>,
}

/// Raw JSON plan result from `data-grout/discovery.plan`
pub type PlanResult = Value;

/// Refract options (used by `RefractBuilder`)
#[derive(Debug, Clone)]
pub struct RefractOptions {
    /// Natural language goal describing the desired transformation
    pub goal: String,
    /// Input payload to refract
    pub payload: Value,
    /// Emit verbose intermediate reasoning
    pub verbose: bool,
    /// Include a chart representation when applicable
    pub chart: bool,
}

/// Raw JSON result from `data-grout/prism.refract`
pub type RefractResult = Value;

/// Chart options (used by `ChartBuilder`)
#[derive(Debug, Clone)]
pub struct ChartOptions {
    /// Natural language description of what to chart
    pub goal: String,
    /// Input data payload
    pub payload: Value,
    /// Output format (e.g. `"svg"`, `"png"`, `"json"`)
    pub format: Option<String>,
    /// Chart type hint (e.g. `"bar"`, `"line"`, `"pie"`)
    pub chart_type: Option<String>,
    /// Chart title
    pub title: Option<String>,
    /// X-axis label
    pub x_label: Option<String>,
    /// Y-axis label
    pub y_label: Option<String>,
    /// Width in pixels
    pub width: Option<u32>,
    /// Height in pixels
    pub height: Option<u32>,
}

/// Raw JSON result from `data-grout/prism.chart`
pub type ChartResult = Value;
