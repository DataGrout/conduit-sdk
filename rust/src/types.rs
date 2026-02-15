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

/// Receipt for cost tracking
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Receipt {
    /// Receipt ID
    pub id: String,
    /// Tool calls made
    pub tool_calls: Vec<ToolCall>,
    /// Total cost in credits
    pub total_cost: u64,
    /// Timestamp
    pub timestamp: String,
}

/// Tool call record
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ToolCall {
    /// Tool name
    pub name: String,
    /// Arguments
    pub arguments: Value,
    /// Result
    pub result: Value,
    /// Cost in credits
    pub cost: u64,
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

/// Discovery result
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct DiscoverResult {
    /// Matching tools
    pub tools: Vec<DiscoveredTool>,
    /// Query used
    pub query: Option<String>,
    /// Total count
    pub total: usize,
}

/// Discovered tool with score
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct DiscoveredTool {
    /// Tool definition
    #[serde(flatten)]
    pub tool: Tool,
    /// Semantic similarity score
    pub score: f64,
    /// Integration name
    #[serde(skip_serializing_if = "Option::is_none")]
    pub integration: Option<String>,
    /// Server ID
    #[serde(skip_serializing_if = "Option::is_none")]
    pub server: Option<String>,
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
