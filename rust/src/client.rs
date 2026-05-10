//! Main client implementation

use crate::error::{Error, Result};
use crate::identity::ConduitIdentity;
use crate::oauth::OAuthTokenProvider;
use crate::protocol::*;
use crate::transport::{AuthConfig, JsonRpcTransport, McpTransport, Transport, TransportTrait};
use crate::types::*;
use crate::ws_transport::WsTransport;
use serde_json::{json, Value};
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::Arc;
use tokio::sync::RwLock;

/// Returns `true` when `url` points at a DataGrout-managed endpoint.
///
/// Used to decide whether to auto-enable mTLS discovery and whether to warn
/// when DG-specific methods (discover, guide, flow.into, …) are called against
/// a non-DG server.
pub fn is_dg_url(url: &str) -> bool {
    url.contains("datagrout.ai")
        || url.contains("datagrout.dev")
        // Allow integration tests running against localhost to signal they are
        // connected to a DataGrout server via an env var.
        || std::env::var("CONDUIT_IS_DG").is_ok()
}

/// Rewrite an HTTP-style DG URL (`/mcp` or `/rpc` suffix) into a `wss://…/ws`
/// URL suitable for the WebSocket transport. Already-`ws[s]://` URLs are
/// returned untouched.
pub(crate) fn rewrite_to_ws(url: &str) -> String {
    if url.starts_with("ws://") || url.starts_with("wss://") {
        return url.to_string();
    }

    let scheme_swap = if let Some(rest) = url.strip_prefix("https://") {
        format!("wss://{rest}")
    } else if let Some(rest) = url.strip_prefix("http://") {
        format!("ws://{rest}")
    } else {
        url.to_string()
    };

    // Swap a trailing /mcp or /rpc for /ws so callers can keep their existing
    // base URL configuration.
    if let Some(stripped) = scheme_swap.strip_suffix("/mcp") {
        format!("{stripped}/ws")
    } else if let Some(stripped) = scheme_swap.strip_suffix("/rpc") {
        format!("{stripped}/ws")
    } else if scheme_swap.ends_with("/ws") {
        scheme_swap
    } else {
        format!("{}/ws", scheme_swap.trim_end_matches('/'))
    }
}

/// High-level MCP + DataGrout client.
///
/// Create one via [`ClientBuilder`] and call [`connect`](Self::connect) before
/// making any requests.  The client is cheaply [`Clone`]able — all state is
/// held behind `Arc`.
///
/// # Standard MCP methods
/// [`list_tools`](Self::list_tools), [`call_tool`](Self::call_tool),
/// [`list_resources`](Self::list_resources), [`read_resource`](Self::read_resource),
/// [`list_prompts`](Self::list_prompts), [`get_prompt`](Self::get_prompt)
///
/// # DataGrout extensions
/// [`discover`](Self::discover), [`perform`](Self::perform),
/// [`guide`](Self::guide), [`plan`](Self::plan),
/// [`dg`](Self::dg) (generic hook)
///
/// # Namespaced tool families
/// [`prism`](Self::prism) — data transformation, charting, rendering, export
/// [`logic`](Self::logic) — agent memory (facts, constraints, hypotheticals)
/// [`warden`](Self::warden) — safety checks, intent verification, consensus
/// [`deliverables`](Self::deliverables) — work product tracking
/// [`ephemerals`](Self::ephemerals) — cache management
/// [`flow`](Self::flow) — orchestration, routing, approvals, execution history
#[derive(Clone)]
pub struct Client {
    transport: Arc<RwLock<Box<dyn TransportTrait>>>,
    next_id: Arc<AtomicU64>,
    initialized: Arc<RwLock<bool>>,
    server_info: Arc<RwLock<Option<ServerInfo>>>,
    use_intelligent_interface: bool,
    max_retries: usize,
    /// Whether this client is connected to a DataGrout-managed endpoint.
    /// When `false`, calling DG-specific methods logs a one-time warning.
    is_dg: bool,
    /// Whether DG-specific method warnings have already been emitted.
    dg_warned: Arc<std::sync::atomic::AtomicBool>,
    /// Whether the underlying transport is JSONRPC (stateless) rather than
    /// MCP (stateful with initialize/disconnect handshakes).
    is_jsonrpc: bool,
}

// Manual Debug implementation since TransportTrait doesn't implement Debug
impl std::fmt::Debug for Client {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("Client")
            .field("next_id", &self.next_id)
            .field("initialized", &self.initialized)
            .field("use_intelligent_interface", &self.use_intelligent_interface)
            .field("is_dg", &self.is_dg)
            .field("is_jsonrpc", &self.is_jsonrpc)
            .field("max_retries", &self.max_retries)
            .finish_non_exhaustive()
    }
}

impl Client {
    /// Create a new client builder (alias for [`ClientBuilder::new`]).
    pub fn builder() -> ClientBuilder {
        ClientBuilder::default()
    }

    /// Connect to the server and perform the MCP `initialize` handshake.
    ///
    /// Must be called once before any other method.  Calling it again on an
    /// already-connected client will re-initialize the session (useful after
    /// a network disruption).
    pub async fn connect(&self) -> Result<()> {
        // Connect transport
        let mut transport = self.transport.write().await;
        transport.connect().await?;
        drop(transport);

        // JSONRPC is stateless — no MCP initialize handshake needed.
        // Just mark the client as ready.
        if self.is_jsonrpc {
            let mut initialized = self.initialized.write().await;
            *initialized = true;
            return Ok(());
        }

        // Send MCP initialize request
        let params = InitializeParams {
            protocol_version: "2025-03-26".to_string(),
            client_info: ClientInfo {
                name: "datagrout-conduit-rust".to_string(),
                version: env!("CARGO_PKG_VERSION").to_string(),
            },
            capabilities: Capabilities {
                tools: Some(ToolsCapability::default()),
                ..Default::default()
            },
        };

        let request = self.build_request("initialize", Some(serde_json::to_value(params)?))?;

        let transport = self.transport.read().await;
        let response = transport.send_request(request).await?;
        drop(transport);

        // Parse initialize response
        if let Some(result) = response.result {
            let init_result: InitializeResult = serde_json::from_value(result)?;

            // Store server info
            let mut server_info = self.server_info.write().await;
            *server_info = Some(init_result.server_info);
            drop(server_info);

            // Send initialized notification
            let notification = JsonRpcRequest::notification("notifications/initialized", None);
            let transport = self.transport.read().await;
            // Notifications don't expect responses, so we send without waiting
            let _ = transport.send_request(notification).await;
            drop(transport);

            // Mark as initialized
            let mut initialized = self.initialized.write().await;
            *initialized = true;

            Ok(())
        } else {
            Err(Error::init("Initialize response missing result"))
        }
    }

    /// Disconnect from the server and reset the session state.
    pub async fn disconnect(&self) -> Result<()> {
        let mut transport = self.transport.write().await;
        transport.disconnect().await?;

        let mut initialized = self.initialized.write().await;
        *initialized = false;

        Ok(())
    }

    /// Returns `true` when [`connect`](Self::connect) has been called and the
    /// MCP handshake completed successfully.
    pub async fn is_initialized(&self) -> bool {
        *self.initialized.read().await
    }

    /// Returns the server info received during the MCP `initialize` handshake,
    /// or `None` if the client is not yet connected.
    pub async fn server_info(&self) -> Option<ServerInfo> {
        self.server_info.read().await.clone()
    }

    // ========================================================================
    // Standard MCP Methods
    // ========================================================================

    /// Fetch the list of tools available on the server (`tools/list`).
    ///
    /// Handles cursor-based pagination automatically and returns a flat list.
    ///
    /// When the *intelligent interface* is enabled (the default for DataGrout
    /// URLs), third-party integration tools (names containing `@`) are filtered
    /// out so that only DataGrout's own semantic tools are returned.  Disable
    /// this behaviour with
    /// [`ClientBuilder::use_intelligent_interface(false)`](ClientBuilder::use_intelligent_interface).
    pub async fn list_tools(&self) -> Result<Vec<Tool>> {
        self.ensure_initialized().await?;

        let mut all_tools = Vec::new();
        let mut cursor: Option<String> = None;

        // Handle pagination
        loop {
            let params = ListToolsParams {
                cursor: cursor.clone(),
            };

            let request = self.build_request("tools/list", Some(serde_json::to_value(params)?))?;

            let response = self.send_with_retry(request).await?;

            if let Some(result) = response.result {
                let list_result: ListToolsResult = serde_json::from_value(result)?;

                // Parse tools
                for tool_value in list_result.tools {
                    let tool: Tool = serde_json::from_value(tool_value)?;
                    all_tools.push(tool);
                }

                // Check for next page
                if let Some(next) = list_result.next_cursor {
                    cursor = Some(next);
                } else {
                    break;
                }
            } else {
                break;
            }
        }

        // When the intelligent interface is active, keep only DataGrout's own semantic
        // tools (discover, perform, guide) and drop all third-party integration tools.
        // Third-party tools use the "integration@version/tool@version" naming scheme; DG's
        // own tools do not contain "@".
        let all_tools = if self.use_intelligent_interface {
            all_tools
                .into_iter()
                .filter(|t| !t.name.contains('@'))
                .collect()
        } else {
            all_tools
        };

        Ok(all_tools)
    }

    /// Invoke a tool by name (`tools/call`).
    ///
    /// `name` is the exact tool name from `list_tools()` (e.g.
    /// `"salesforce@1/get_lead@1"`).  Returns the first content item from the
    /// server response, or `null` when the server returns an empty content
    /// array.
    pub async fn call_tool(&self, name: impl Into<String>, arguments: Value) -> Result<Value> {
        self.ensure_initialized().await?;

        let params = CallToolParams {
            name: name.into(),
            arguments: Some(arguments),
        };

        let request = self.build_request("tools/call", Some(serde_json::to_value(params)?))?;

        let response = self.send_with_retry(request).await?;

        if let Some(result) = response.result {
            let call_result: CallToolResult = serde_json::from_value(result)?;

            // Return first content item
            if let Some(content) = call_result.content.first() {
                Ok(content.clone())
            } else {
                Ok(json!(null))
            }
        } else {
            Err(Error::Other("Tool call returned no result".to_string()))
        }
    }

    /// List available resources (`resources/list`).
    pub async fn list_resources(&self) -> Result<Vec<Value>> {
        self.ensure_initialized().await?;

        let params = ListResourcesParams::default();
        let request = self.build_request("resources/list", Some(serde_json::to_value(params)?))?;

        let response = self.send_with_retry(request).await?;

        if let Some(result) = response.result {
            let list_result: ListResourcesResult = serde_json::from_value(result)?;
            Ok(list_result.resources)
        } else {
            Ok(Vec::new())
        }
    }

    /// Read a resource by URI (`resources/read`).
    pub async fn read_resource(&self, uri: impl Into<String>) -> Result<Vec<Value>> {
        self.ensure_initialized().await?;

        let params = ReadResourceParams { uri: uri.into() };
        let request = self.build_request("resources/read", Some(serde_json::to_value(params)?))?;

        let response = self.send_with_retry(request).await?;

        if let Some(result) = response.result {
            let read_result: ReadResourceResult = serde_json::from_value(result)?;
            Ok(read_result.contents)
        } else {
            Ok(Vec::new())
        }
    }

    /// List available prompt templates (`prompts/list`).
    pub async fn list_prompts(&self) -> Result<Vec<Value>> {
        self.ensure_initialized().await?;

        let params = ListPromptsParams::default();
        let request = self.build_request("prompts/list", Some(serde_json::to_value(params)?))?;

        let response = self.send_with_retry(request).await?;

        if let Some(result) = response.result {
            let list_result: ListPromptsResult = serde_json::from_value(result)?;
            Ok(list_result.prompts)
        } else {
            Ok(Vec::new())
        }
    }

    /// Render a prompt template by name (`prompts/get`).
    ///
    /// `arguments` can be `None` or a JSON object of template substitutions.
    pub async fn get_prompt(
        &self,
        name: impl Into<String>,
        arguments: Option<Value>,
    ) -> Result<Vec<Value>> {
        self.ensure_initialized().await?;

        let params = GetPromptParams {
            name: name.into(),
            arguments,
        };

        let request = self.build_request("prompts/get", Some(serde_json::to_value(params)?))?;

        let response = self.send_with_retry(request).await?;

        if let Some(result) = response.result {
            let get_result: GetPromptResult = serde_json::from_value(result)?;
            Ok(get_result.messages)
        } else {
            Ok(Vec::new())
        }
    }

    // ========================================================================
    // DataGrout Extensions
    // ========================================================================

    /// Semantic tool discovery (`data-grout/discovery.discover`).
    ///
    /// Returns a [`DiscoverBuilder`] — chain `.query()` or `.goal()`,
    /// optional `.integration()` / `.server()` filters, then call `.execute()`.
    ///
    /// ```rust,no_run
    /// # use datagrout_conduit::{Client, ClientBuilder};
    /// # async fn example(client: Client) -> Result<(), Box<dyn std::error::Error>> {
    /// let results = client.discover()
    ///     .query("get lead by email")
    ///     .integration("salesforce")
    ///     .limit(5)
    ///     .execute()
    ///     .await?;
    /// # Ok(())
    /// # }
    /// ```
    pub fn discover(&self) -> DiscoverBuilder<'_> {
        self.warn_if_not_dg("discover");
        DiscoverBuilder::new(self)
    }

    /// Execute a tool discovered via [`discover`](Self::discover)
    /// (`data-grout/discovery.perform`).
    ///
    /// `tool` is the fully-qualified tool name (e.g.
    /// `"salesforce@1/get_lead@1"`).  Chain `.args()` and optionally
    /// `.demux()` before calling `.execute()`.
    pub fn perform(&self, tool: impl Into<String>) -> PerformBuilder<'_> {
        self.warn_if_not_dg("perform");
        PerformBuilder::new(self, tool.into())
    }

    /// Execute multiple tool calls in a single gateway request
    /// (`data-grout/discovery.perform`).
    ///
    /// Each element should be a JSON object with `"tool"` and `"args"` keys.
    /// Returns a list of results in the same order as the input calls.
    ///
    /// ```no_run
    /// # use serde_json::json;
    /// # async fn example(client: &datagrout_conduit::Client) -> datagrout_conduit::Result<()> {
    /// let results = client.perform_batch(vec![
    ///     json!({"tool": "data-grout/data.count", "args": {"data": [1, 2, 3]}}),
    ///     json!({"tool": "data-grout/data.keys",  "args": {"data": {"a": 1}}}),
    /// ]).await?;
    /// # Ok(())
    /// # }
    /// ```
    pub async fn perform_batch(&self, calls: Vec<Value>) -> Result<Vec<Value>> {
        self.warn_if_not_dg("perform_batch");
        self.ensure_initialized().await?;
        let result = self
            .call_dg_tool("data-grout/discovery.perform", Value::Array(calls))
            .await?;
        match result {
            Value::Array(arr) => Ok(arr),
            other => Ok(vec![other]),
        }
    }

    /// Start or advance a guided multi-step workflow
    /// (`data-grout/discovery.guide`).
    ///
    /// Returns a [`GuideBuilder`].  Set a natural language `.goal()` to begin
    /// a new session, or chain `.session_id()` + `.choice()` to advance an
    /// existing one.  Calling `.execute()` returns a [`GuidedSession`] that
    /// exposes the current step options and final result.
    pub fn guide(&self) -> GuideBuilder<'_> {
        self.warn_if_not_dg("guide");
        GuideBuilder::new(self)
    }

    /// AI-driven workflow planner (`data-grout/discovery.plan`).
    ///
    /// Returns a [`PlanBuilder`].  At least one of `.goal()` or `.query()`
    /// must be set before calling `.execute()`, or the call returns
    /// [`Error::InvalidConfig`](crate::error::Error::InvalidConfig).
    pub fn plan(&self) -> PlanBuilder<'_> {
        self.warn_if_not_dg("plan");
        PlanBuilder::new(self)
    }

    /// Pre-execution credit estimation for a DataGrout tool.
    ///
    /// Sends the given `args` enriched with `estimate_only: true` to the
    /// specified `tool` method (e.g. `"data-grout/discovery.discover"`).
    /// Returns the server's raw estimate JSON.
    pub async fn estimate_cost(&self, tool: impl Into<String>, args: Value) -> Result<Value> {
        self.ensure_initialized().await?;

        let mut estimate_args = args;
        if let Some(obj) = estimate_args.as_object_mut() {
            obj.insert("estimate_only".to_string(), json!(true));
        }

        self.call_dg_tool(&tool.into(), estimate_args).await
    }

    // ========================================================================
    // Namespaced tool families
    // ========================================================================

    /// Data transformation, charting, rendering, and type bridging.
    pub fn prism(&self) -> crate::namespaces::Prism<'_> {
        crate::namespaces::Prism(self)
    }

    /// Persistent agent memory backed by a Prolog logic cell.
    pub fn logic(&self) -> crate::namespaces::Logic<'_> {
        crate::namespaces::Logic(self)
    }

    /// Safety gates, intent verification, and multi-model consensus.
    pub fn warden(&self) -> crate::namespaces::Warden<'_> {
        crate::namespaces::Warden(self)
    }

    /// Work product registration, listing, and retrieval.
    pub fn deliverables(&self) -> crate::namespaces::Deliverables<'_> {
        crate::namespaces::Deliverables(self)
    }

    /// Cache listing and inspection for ephemeral tool results.
    pub fn ephemerals(&self) -> crate::namespaces::Ephemerals<'_> {
        crate::namespaces::Ephemerals(self)
    }

    /// Multi-step orchestration, conditional routing, approvals, and history.
    pub fn flow(&self) -> crate::namespaces::Flow<'_> {
        crate::namespaces::Flow(self)
    }

    // ========================================================================
    // Internal: DataGrout tool dispatch
    // ========================================================================

    /// Route a DataGrout first-party tool call through the standard MCP
    /// `tools/call` path.
    pub(crate) async fn call_dg_tool(&self, name: &str, args: Value) -> Result<Value> {
        let params = json!({
            "name":      name,
            "arguments": args,
        });
        let request = self.build_request("tools/call", Some(params))?;
        let response = self.send_with_retry(request).await?;
        let raw = response
            .result
            .ok_or_else(|| Error::Other(format!("`{}` returned no result", name)))?;

        // MCP tool responses wrap the actual result in a `content` array.
        // Both the MCP transport and the DG JSONRPC endpoint return:
        //   {"content": [{"type": "text", "text": "<json-encoded result>"}]}
        // Unwrap one level so callers receive the actual tool output.
        if let Some(content) = raw.get("content").and_then(|c| c.as_array()) {
            if let Some(first) = content.first() {
                if let Some(text) = first.get("text").and_then(|t| t.as_str()) {
                    if let Ok(parsed) = serde_json::from_str::<Value>(text) {
                        return Ok(parsed);
                    }
                }
            }
        }

        // If there's no content envelope (e.g. raw JSON result), return as-is.
        Ok(raw)
    }

    // ========================================================================
    // Generic DataGrout Hook
    // ========================================================================

    /// Call any DataGrout first-party tool by its short name.
    ///
    /// The short name (e.g. `"discovery.discover"`) is prefixed with
    /// `"data-grout/"` automatically, so callers never need to hard-code the
    /// full method path.
    ///
    /// This is the escape hatch for DG tools that do not yet have a typed
    /// builder on `Client`.
    ///
    /// # Example
    ///
    /// ```rust,no_run
    /// # use datagrout_conduit::ClientBuilder;
    /// # use serde_json::json;
    /// # async fn example() -> Result<(), Box<dyn std::error::Error>> {
    /// let client = ClientBuilder::new()
    ///     .url("https://app.datagrout.ai/servers/{uuid}/mcp")
    ///     .build()?;
    /// client.connect().await?;
    /// let result = client.dg("discovery.discover", json!({"query": "test", "limit": 1})).await?;
    /// # Ok(())
    /// # }
    /// ```
    pub async fn dg(&self, tool_short_name: &str, args: Value) -> Result<Value> {
        self.warn_if_not_dg(tool_short_name);
        self.ensure_initialized().await?;
        let name = format!("data-grout/{}", tool_short_name);
        self.call_dg_tool(&name, args).await
    }

    // ========================================================================
    // DG-awareness helpers
    // ========================================================================

    /// Emit a one-time warning when a DG-specific method is called against a
    /// non-DataGrout server.  Safe to call from every DG-specific method — the
    /// warning fires at most once per `Client` instance.
    pub(crate) fn warn_if_not_dg(&self, method: &str) {
        if !self.is_dg
            && !self
                .dg_warned
                .swap(true, std::sync::atomic::Ordering::Relaxed)
        {
            eprintln!(
                "[conduit] warning: `{method}` is a DataGrout-specific extension. \
                 The connected server (non-DG endpoint) may not support it. \
                 Standard MCP methods (list_tools, call_tool, …) work on any server.",
            );
        }
    }

    // ========================================================================
    // Internal helpers
    // ========================================================================

    fn build_request(
        &self,
        method: impl Into<String>,
        params: Option<Value>,
    ) -> Result<JsonRpcRequest> {
        let id = self.next_id.fetch_add(1, Ordering::SeqCst).to_string();
        Ok(JsonRpcRequest::new(id, method, params))
    }

    pub(crate) async fn ensure_initialized(&self) -> Result<()> {
        if !self.is_initialized().await {
            return Err(Error::NotInitialized);
        }
        Ok(())
    }

    async fn send_with_retry(&self, request: JsonRpcRequest) -> Result<JsonRpcResponse> {
        let mut retries = self.max_retries;

        loop {
            let transport = self.transport.read().await;
            let response = transport.send_request(request.clone()).await;
            drop(transport);

            match response {
                Ok(resp) => return Ok(resp),
                Err(e) if e.is_not_initialized() && retries > 0 => {
                    // Re-initialize and retry
                    tracing::warn!("Server not initialized, retrying ({} left)...", retries);
                    self.connect().await?;
                    retries -= 1;
                    tokio::time::sleep(std::time::Duration::from_millis(500)).await;
                    continue;
                }
                Err(e) => return Err(e),
            }
        }
    }
}

/// Builder for [`Client`].
///
/// ```rust,no_run
/// use datagrout_conduit::{ClientBuilder, Transport};
///
/// let client = ClientBuilder::new()
///     .url("https://gateway.datagrout.ai/servers/{uuid}/mcp")
///     .transport(Transport::Mcp)
///     .auth_bearer("your-token")
///     .build()
///     .unwrap();
/// ```
pub struct ClientBuilder {
    url: Option<String>,
    transport: Option<Transport>,
    auth: Option<AuthConfig>,
    identity: Option<ConduitIdentity>,
    use_intelligent_interface: Option<bool>,
    max_retries: usize,
    /// Custom directory for identity storage/discovery (overrides `~/.conduit/`).
    identity_dir: Option<std::path::PathBuf>,
    /// Pending OAuth credentials resolved into `AuthConfig::ClientCredentials`
    /// during `build()` once the URL is known.
    _pending_oauth_creds: Option<(String, String, Option<String>, Option<String>)>,
    /// Days before cert expiry at which proactive rotation is triggered.
    /// Defaults to 7 — rotate when the cert has fewer than 7 days remaining.
    rotation_days: u64,
}

impl Default for ClientBuilder {
    fn default() -> Self {
        Self {
            url: None,
            transport: None,
            auth: None,
            identity: None,
            use_intelligent_interface: None,
            max_retries: 3,
            identity_dir: None,
            _pending_oauth_creds: None,
            rotation_days: 7,
        }
    }
}

impl ClientBuilder {
    /// Create a new builder with default settings.
    pub fn new() -> Self {
        Self::default()
    }

    /// Set the MCP server URL (required).
    pub fn url(mut self, url: impl Into<String>) -> Self {
        self.url = Some(url.into());
        self
    }

    /// Set the transport mode (default: [`Transport::Mcp`] for SSE-based MCP).
    pub fn transport(mut self, transport: Transport) -> Self {
        self.transport = Some(transport);
        self
    }

    /// Authenticate with a static bearer token.
    pub fn auth_bearer(mut self, token: impl Into<String>) -> Self {
        self.auth = Some(AuthConfig::Bearer(token.into()));
        self
    }

    /// Authenticate with an API key (sent as `X-API-Key` header).
    pub fn auth_api_key(mut self, key: impl Into<String>) -> Self {
        self.auth = Some(AuthConfig::ApiKey(key.into()));
        self
    }

    /// Authenticate with HTTP Basic credentials.
    pub fn auth_basic(mut self, username: impl Into<String>, password: impl Into<String>) -> Self {
        self.auth = Some(AuthConfig::Basic {
            username: username.into(),
            password: password.into(),
        });
        self
    }

    /// Authenticate using OAuth 2.1 `client_credentials`.
    ///
    /// The SDK automatically fetches a short-lived JWT from the DataGrout
    /// token endpoint on the first request and refreshes it before it expires.
    /// Application code never handles tokens directly.
    ///
    /// The `token_endpoint` URL is derived from `url` automatically if not
    /// provided — pass `None` for the standard DataGrout endpoint.
    ///
    /// # Example
    ///
    /// ```rust,no_run
    /// # use datagrout_conduit::ClientBuilder;
    /// let client = ClientBuilder::new()
    ///     .url("https://app.datagrout.ai/servers/{uuid}/mcp")
    ///     .auth_client_credentials("my_client_id", "my_client_secret")
    ///     .build()
    ///     .unwrap();
    /// ```
    pub fn auth_client_credentials(
        mut self,
        client_id: impl Into<String>,
        client_secret: impl Into<String>,
    ) -> Self {
        self._pending_oauth_creds = Some((client_id.into(), client_secret.into(), None, None));
        self
    }

    /// Like [`auth_client_credentials`](Self::auth_client_credentials) but
    /// with an explicit `token_endpoint` URL and optional `scope`.
    pub fn auth_client_credentials_with_opts(
        mut self,
        client_id: impl Into<String>,
        client_secret: impl Into<String>,
        token_endpoint: impl Into<String>,
        scope: Option<String>,
    ) -> Self {
        self._pending_oauth_creds = Some((
            client_id.into(),
            client_secret.into(),
            Some(token_endpoint.into()),
            scope,
        ));
        self
    }

    /// Provide an explicit mTLS identity (client certificate + key).
    ///
    /// When set, every connection will present this certificate during the TLS
    /// handshake.  You can still layer a bearer token or API key on top — it
    /// will be included as a request header as usual.
    pub fn with_identity(mut self, identity: ConduitIdentity) -> Self {
        self.identity = Some(identity);
        self
    }

    /// Try to load an mTLS identity using the auto-discovery chain.
    ///
    /// Checks `identity_dir` (if set) → env vars → `CONDUIT_IDENTITY_DIR` →
    /// `~/.conduit/` → `.conduit/` in the cwd.  If nothing is found this is
    /// a no-op: the client falls back to token auth silently.
    ///
    /// Also reads the saved `server_url` file from the same directory so that
    /// agents bootstrapped with [`bootstrap_onramp`](Self::bootstrap_onramp) can
    /// reconnect without knowing their URL in advance:
    ///
    /// ```rust,no_run
    /// # use datagrout_conduit::ClientBuilder;
    /// # fn example() -> Result<(), Box<dyn std::error::Error>> {
    /// // First run: bootstrap_onramp saves identity + server_url to ~/.conduit/.
    /// // Subsequent runs: both are recovered automatically.
    /// let client = ClientBuilder::new()
    ///     .with_identity_auto()
    ///     .build()?;
    /// # Ok(())
    /// # }
    /// ```
    pub fn with_identity_auto(mut self) -> Self {
        self.identity = ConduitIdentity::try_discover(self.identity_dir.as_deref());
        // Mirror the discovery order for the URL: explicit identity_dir first,
        // then the default ~/.conduit/ fallback.
        if self.url.is_none() {
            let default = crate::registration::default_identity_dir();
            let dir = self.identity_dir.as_deref().or(default.as_deref());
            self.url = crate::registration::try_read_server_url(dir);
        }
        self
    }

    /// Set a custom directory for identity storage and discovery.
    ///
    /// This overrides the default `~/.conduit/` directory.  Useful for running
    /// multiple agents on the same machine — each gets its own identity dir.
    ///
    /// Affects both [`with_identity_auto`](Self::with_identity_auto) and
    /// [`bootstrap_identity`](Self::bootstrap_identity).
    pub fn identity_dir(mut self, dir: impl Into<std::path::PathBuf>) -> Self {
        self.identity_dir = Some(dir.into());
        self
    }

    /// Set how many days before cert expiry to trigger proactive rotation.
    ///
    /// The default is **7 days** — the cert is rotated when it has fewer than
    /// this many days of validity remaining.  Agents with strict uptime
    /// requirements may want a higher value; agents that are short-lived can
    /// reduce it to avoid unnecessary rotation traffic.
    ///
    /// This threshold is checked by
    /// [`bootstrap_identity`](Self::bootstrap_identity) and
    /// [`bootstrap_onramp`](Self::bootstrap_onramp) on every startup.
    pub fn rotation_days(mut self, days: u64) -> Self {
        self.rotation_days = days;
        self
    }

    /// Enable or disable the intelligent interface (DataGrout `discover` / `perform` only).
    ///
    /// When `true`, `list_tools()` returns only the DataGrout semantic discovery
    /// and execution tools instead of the raw tool list from the MCP server.
    /// Defaults to `true` for DataGrout URLs, `false` otherwise.
    pub fn use_intelligent_interface(mut self, enabled: bool) -> Self {
        self.use_intelligent_interface = Some(enabled);
        self
    }

    /// Set maximum retries on "server not initialized" errors (default: 3).
    pub fn max_retries(mut self, retries: usize) -> Self {
        self.max_retries = retries;
        self
    }

    /// Clear any mTLS identity, ensuring token-only auth.
    ///
    /// mTLS auto-discovery is opt-in via [`with_identity_auto`](Self::with_identity_auto),
    /// so calling this is only necessary if an explicit identity was previously set
    /// and you want to remove it.
    ///
    /// This method is kept for backward compatibility; it is otherwise a no-op on
    /// fresh builders where no identity has been configured.
    pub fn no_mtls(mut self) -> Self {
        self.identity = None;
        self
    }

    /// Bootstrap an mTLS identity seamlessly.
    ///
    /// Checks the auto-discovery chain first (respecting [`identity_dir`] if
    /// set, then `~/.conduit/`, env vars).  If an existing identity is found
    /// and not near expiry it is used as-is.  If not found (or near expiry), a
    /// new keypair is generated, registered with DataGrout using the provided
    /// bearer token, saved to the identity directory, and loaded as the active
    /// identity.
    ///
    /// After the first successful bootstrap the identity is persisted locally
    /// and auto-discovered on subsequent runs — no token or API key is needed
    /// again.
    ///
    /// Requires the `registration` feature flag.
    ///
    /// # Example
    ///
    /// ```rust,no_run
    /// # use datagrout_conduit::ClientBuilder;
    /// # async fn example() -> Result<(), Box<dyn std::error::Error>> {
    /// // First run: token is needed for registration
    /// let client = ClientBuilder::new()
    ///     .url("https://gateway.datagrout.ai/servers/{uuid}/mcp")
    ///     .bootstrap_identity("my-access-token", "my-laptop")
    ///     .await?
    ///     .build()?;
    ///
    /// // Subsequent runs: identity auto-discovered, no token needed
    /// let client = ClientBuilder::new()
    ///     .url("https://gateway.datagrout.ai/servers/{uuid}/mcp")
    ///     .build()?;
    /// # Ok(())
    /// # }
    /// ```
    #[cfg(feature = "registration")]
    pub async fn bootstrap_identity(
        self,
        auth_token: impl Into<String>,
        name: impl Into<String>,
    ) -> crate::error::Result<Self> {
        let url = self
            .url
            .as_deref()
            .ok_or_else(|| Error::invalid_config("URL must be set before bootstrap_identity"))?
            .to_string();

        self.bootstrap_identity_with_endpoint(
            auth_token,
            name,
            crate::registration::derive_identity_endpoint(&url),
        )
        .await
    }

    /// Like [`bootstrap_identity`](Self::bootstrap_identity) but with an
    /// explicit registration endpoint URL.
    #[cfg(feature = "registration")]
    pub async fn bootstrap_identity_with_endpoint(
        mut self,
        auth_token: impl Into<String>,
        name: impl Into<String>,
        substrate_endpoint: impl Into<String>,
    ) -> crate::error::Result<Self> {
        use crate::registration::{
            default_identity_dir, generate_keypair, register_identity, rotate_identity,
            save_identity_to_dir, save_server_url, RegistrationOptions, RenewalOptions,
        };

        let endpoint = substrate_endpoint.into();

        // Fast path: existing identity that doesn't need rotation.
        if let Some(existing) = ConduitIdentity::try_discover(self.identity_dir.as_deref()) {
            if !existing.needs_rotation(self.rotation_days) {
                self.identity = Some(existing);
                return Ok(self);
            }

            let name_str = name.into();
            let new_keypair = generate_keypair(&name_str)?;
            let rotate_opts = RenewalOptions {
                endpoint: endpoint.clone(),
                name: name_str.clone(),
                save_to: self.identity_dir.clone(),
            };

            let identity = match rotate_identity(&existing, &new_keypair, &rotate_opts).await {
                Ok((identity, _resp)) => identity,
                Err(_) => {
                    let opts = RegistrationOptions {
                        endpoint: endpoint.clone(),
                        auth_token: auth_token.into(),
                        name: name_str,
                    };
                    let (identity, _resp) = register_identity(&new_keypair, &opts).await?;
                    identity
                }
            };

            let save_dir = self.identity_dir.clone().or_else(default_identity_dir);
            if let Some(ref dir) = save_dir {
                let _ = save_identity_to_dir(&identity, dir);
                // Re-save the URL so the file stays current after rotation.
                if let Some(ref url) = self.url {
                    let _ = save_server_url(dir, url);
                }
            }

            self.identity = Some(identity);
            return Ok(self);
        }

        // Slow path: generate and register a new identity.
        let name_str = name.into();
        let keypair = generate_keypair(&name_str)?;
        let opts = RegistrationOptions {
            endpoint,
            auth_token: auth_token.into(),
            name: name_str,
        };
        let (identity, reg_resp) = register_identity(&keypair, &opts).await?;

        self.identity = Some(identity);

        // When the registration response includes an mcp_url (server was
        // provisioned during this call), set it on the builder so the caller
        // doesn't need to know the URL in advance.
        if self.url.is_none() {
            if let Some(mcp_url) = reg_resp.mcp_url {
                self.url = Some(mcp_url);
            }
        }

        // Persist identity and URL so future runs are zero-config.
        let save_dir = self.identity_dir.clone().or_else(default_identity_dir);
        if let Some(ref dir) = save_dir {
            if let Some(ref id) = self.identity {
                let _ = save_identity_to_dir(id, dir);
            }
            if let Some(ref url) = self.url {
                let _ = save_server_url(dir, url);
            }
        }

        Ok(self)
    }

    /// Full autonomous onboarding: onramp handshake + mTLS identity bootstrap.
    ///
    /// The most hands-off path for machine-native DG access. No credentials are
    /// required upfront — the agent presents identity metadata and receives a
    /// fully-authenticated mTLS [`Client`] in return.
    ///
    /// Internally chains:
    /// 1. Two-step onramp handshake → provisional `client_id` + `client_secret`.
    /// 2. OAuth `client_credentials` grant → access token.
    /// 3. [`bootstrap_identity`](Self::bootstrap_identity) → DG-CA-signed cert persisted to disk.
    ///
    /// After the first run the mTLS identity is saved to `~/.conduit/` (or
    /// `identity_dir` if set), so subsequent builds auto-discover it without
    /// any credentials.
    ///
    /// Requires the `bootstrap` feature flag.
    ///
    /// # Example
    ///
    /// ```rust,no_run
    /// use datagrout_conduit::{ClientBuilder, onramp::OnrampOptions};
    ///
    /// # async fn example() -> Result<(), Box<dyn std::error::Error>> {
    /// // First run: autonomous registration, no prior credentials needed.
    /// let client = ClientBuilder::new()
    ///     .bootstrap_onramp(OnrampOptions {
    ///         gateway: "https://app.datagrout.ai".into(),
    ///         agent_name: "my-research-agent".into(),
    ///         agent_type: Some("claude-sonnet-4-6".into()),
    ///         intended_use: None,
    ///         access_code: None,
    ///     })
    ///     .await?
    ///     .build()?;
    ///
    /// // Subsequent runs: identity auto-discovered, no credentials needed.
    /// let client = ClientBuilder::new()
    ///     .with_identity_auto()
    ///     .build()?;
    /// # Ok(())
    /// # }
    /// ```
    #[cfg(feature = "bootstrap")]
    pub async fn bootstrap_onramp(
        mut self,
        opts: crate::onramp::OnrampOptions,
    ) -> crate::error::Result<Self> {
        use crate::registration::{
            default_identity_dir, derive_identity_endpoint, generate_keypair, rotate_identity,
            save_credentials, save_identity_to_dir, save_server_url, try_load_credentials,
            try_read_server_url, RenewalOptions, SavedCredentials, DG_SUBSTRATE_ENDPOINT,
        };

        let identity_dir_owned = self.identity_dir.clone();
        let default_dir = default_identity_dir();
        let dir: Option<&std::path::Path> =
            identity_dir_owned.as_deref().or(default_dir.as_deref());

        // ── Fast path A: non-expiring cert on disk ──────────────────────────
        // Skip everything. No new account, no network call.
        if let Some(existing) =
            crate::identity::ConduitIdentity::try_discover(self.identity_dir.as_deref())
        {
            if !existing.needs_rotation(self.rotation_days) {
                if self.url.is_none() {
                    self.url = try_read_server_url(dir);
                }
                self.identity = Some(existing);
                return Ok(self);
            }
            // Cert is close to expiry — try mTLS rotation before touching credentials.
            let name_str = opts.agent_name.clone();
            if let Ok(new_keypair) = generate_keypair(&name_str) {
                let endpoint = self
                    .url
                    .as_deref()
                    .map(derive_identity_endpoint)
                    .unwrap_or_else(|| {
                        try_read_server_url(dir)
                            .as_deref()
                            .map(derive_identity_endpoint)
                            .unwrap_or_else(|| DG_SUBSTRATE_ENDPOINT.to_string())
                    });
                let rotate_opts = RenewalOptions {
                    endpoint,
                    name: name_str,
                    save_to: self.identity_dir.clone(),
                };

                match rotate_identity(&existing, &new_keypair, &rotate_opts).await {
                    Ok((identity, _)) => {
                        // ── Fast path C: mTLS rotation succeeded ──────────
                        if self.url.is_none() {
                            self.url = try_read_server_url(dir);
                        }
                        if let Some(d) = dir {
                            let _ = save_identity_to_dir(&identity, d);
                            if let Some(ref url) = self.url {
                                let _ = save_server_url(d, url);
                            }
                        }
                        self.identity = Some(identity);
                        return Ok(self);
                    }
                    Err(e) => {
                        tracing::warn!(
                            "mTLS rotation of expiring cert failed ({}); \
                             trying credential recovery or fresh onramp",
                            e
                        );
                    }
                }
            }
        }

        // ── Fast path B: cert missing but saved credentials on disk ─────────
        // Re-register a fresh cert for the same machine account without creating
        // a new one. If the saved credentials have expired, log a warning and
        // fall through to a fresh onramp (which will create a new account).
        if let Some(saved) = try_load_credentials(dir) {
            let http = reqwest::Client::new();
            let provider = OAuthTokenProvider::new(
                &saved.client_id,
                &saved.client_secret,
                &saved.token_url,
                None,
            );

            match provider.get_token(&http).await {
                Ok(token) => {
                    // Recover the server URL from disk (or from what the caller set).
                    if self.url.is_none() {
                        self.url = try_read_server_url(dir);
                    }
                    let endpoint = self
                        .url
                        .as_deref()
                        .map(derive_identity_endpoint)
                        .unwrap_or_else(|| DG_SUBSTRATE_ENDPOINT.to_string());

                    return self
                        .bootstrap_identity_with_endpoint(token, opts.agent_name, endpoint)
                        .await;
                }
                Err(e) => {
                    // Credentials rejected (likely expired after 30-day TTL).
                    // Fall through to fresh onramp which will create a new account.
                    tracing::warn!(
                        "saved credentials for {} rejected ({}); \
                         falling back to fresh onramp registration",
                        saved.client_id,
                        e
                    );
                }
            }
        }

        // ── Slow path: full two-step onramp handshake ───────────────────────
        let http = reqwest::Client::new();

        let creds = crate::onramp::register(&http, &opts)
            .await
            .map_err(|e| Error::Onramp {
                stage: "registration",
                source: e,
            })?;

        let token = crate::onramp::exchange_token(&http, &creds)
            .await
            .map_err(|e| Error::Onramp {
                stage: "token_exchange",
                source: e,
            })?;

        // Persist credentials so cert-loss recovery works on future startups.
        if let Some(d) = dir {
            let _ = save_credentials(
                d,
                &SavedCredentials {
                    client_id: creds.client_id.clone(),
                    client_secret: creds.client_secret.clone(),
                    token_url: creds.token_url.clone(),
                    saved_at: {
                        // Use a simple UTC timestamp without pulling in chrono.
                        let secs = std::time::SystemTime::now()
                            .duration_since(std::time::UNIX_EPOCH)
                            .unwrap_or_default()
                            .as_secs();
                        format!("{secs}")
                    },
                },
            );
        }

        // Route through bootstrap_identity{,_with_endpoint} which handles
        // identity registration and URL resolution.
        match creds.mcp_url {
            Some(ref url) => {
                self.url(url)
                    .bootstrap_identity(token, opts.agent_name)
                    .await
            }
            None => {
                self.bootstrap_identity_with_endpoint(token, opts.agent_name, DG_SUBSTRATE_ENDPOINT)
                    .await
            }
        }
    }

    /// Bootstrap an mTLS identity using OAuth 2.1 `client_credentials`.
    ///
    /// Like [`bootstrap_identity`](Self::bootstrap_identity) but instead of
    /// requiring a pre-obtained token, performs the OAuth token exchange
    /// inline using the provided `client_id` and `client_secret`.
    ///
    /// # Example
    ///
    /// ```rust,no_run
    /// # use datagrout_conduit::ClientBuilder;
    /// # async fn example() -> Result<(), Box<dyn std::error::Error>> {
    /// let client = ClientBuilder::new()
    ///     .url("https://gateway.datagrout.ai/servers/{uuid}/mcp")
    ///     .bootstrap_identity_oauth(
    ///         "my_client_id",
    ///         "my_client_secret",
    ///         "my-laptop",
    ///     )
    ///     .await?
    ///     .build()?;
    /// # Ok(())
    /// # }
    /// ```
    /// Bootstrap an mTLS identity using OAuth 2.1 `client_credentials`.
    ///
    /// Like [`bootstrap_identity`](Self::bootstrap_identity) but instead of
    /// requiring a pre-obtained token, performs the OAuth token exchange
    /// inline using the provided `client_id` and `client_secret`.
    ///
    /// The token endpoint is **derived from the MCP URL** (strips `/mcp`, appends
    /// `/oauth/token`).  Use [`bootstrap_identity_oauth_at`](Self::bootstrap_identity_oauth_at)
    /// when you have an explicit token endpoint URL and want to avoid the
    /// derivation heuristic.
    ///
    /// # Example
    ///
    /// ```rust,no_run
    /// # use datagrout_conduit::ClientBuilder;
    /// # async fn example() -> Result<(), Box<dyn std::error::Error>> {
    /// let client = ClientBuilder::new()
    ///     .url("https://gateway.datagrout.ai/servers/{uuid}/mcp")
    ///     .bootstrap_identity_oauth(
    ///         "my_client_id",
    ///         "my_client_secret",
    ///         "my-laptop",
    ///     )
    ///     .await?
    ///     .build()?;
    /// # Ok(())
    /// # }
    /// ```
    #[cfg(feature = "registration")]
    pub async fn bootstrap_identity_oauth(
        self,
        client_id: impl Into<String>,
        client_secret: impl Into<String>,
        name: impl Into<String>,
    ) -> crate::error::Result<Self> {
        let url = self.url.as_deref().ok_or_else(|| {
            Error::invalid_config("URL must be set before bootstrap_identity_oauth")
        })?;
        let token_endpoint = OAuthTokenProvider::derive_token_endpoint(url);
        self.bootstrap_identity_oauth_at(client_id, client_secret, token_endpoint, name)
            .await
    }

    /// Like [`bootstrap_identity_oauth`](Self::bootstrap_identity_oauth) but
    /// accepts an explicit `token_url` instead of deriving it from the MCP URL.
    ///
    /// Prefer this variant when you have the token URL available directly (e.g.
    /// from the onramp `token_url` field or a saved credentials file) to avoid
    /// relying on the URL-structure heuristic.
    ///
    /// # Requirements
    ///
    /// `.url()` must be set on the builder before calling this method (or the
    /// URL must be recoverable from a saved `server_url` file).  If the URL is
    /// absent, [`build`](Self::build) will return
    /// [`Error::InvalidConfig`](crate::error::Error::InvalidConfig).
    ///
    /// # Example
    ///
    /// ```rust,no_run
    /// # use datagrout_conduit::ClientBuilder;
    /// # async fn example() -> Result<(), Box<dyn std::error::Error>> {
    /// let client = ClientBuilder::new()
    ///     .url("https://gateway.datagrout.ai/servers/{uuid}/mcp")
    ///     .bootstrap_identity_oauth_at(
    ///         "my_client_id",
    ///         "my_client_secret",
    ///         "https://gateway.datagrout.ai/servers/{uuid}/oauth/token",
    ///         "my-laptop",
    ///     )
    ///     .await?
    ///     .build()?;
    /// # Ok(())
    /// # }
    /// ```
    #[cfg(feature = "registration")]
    pub async fn bootstrap_identity_oauth_at(
        self,
        client_id: impl Into<String>,
        client_secret: impl Into<String>,
        token_url: impl Into<String>,
        name: impl Into<String>,
    ) -> crate::error::Result<Self> {
        let provider = OAuthTokenProvider::new(client_id, client_secret, token_url.into(), None);
        let http = reqwest::Client::new();
        let token = provider.get_token(&http).await?;
        self.bootstrap_identity(token, name).await
    }

    /// Consume the builder and produce a [`Client`].
    ///
    /// Returns [`Error::InvalidConfig`](crate::error::Error::InvalidConfig)
    /// when required fields (e.g. `url`) are missing.
    pub fn build(mut self) -> Result<Client> {
        // Last-chance URL recovery: if the caller didn't set a URL explicitly
        // and didn't call with_identity_auto(), try reading it from the saved
        // server_url file in identity_dir (or ~/.conduit/).  This allows:
        //   ClientBuilder::new().identity_dir("/opt/agent/.conduit").build()
        // to work after a prior bootstrap_onramp run.
        if self.url.is_none() {
            let default = crate::registration::default_identity_dir();
            let dir = self.identity_dir.as_deref().or(default.as_deref());
            self.url = crate::registration::try_read_server_url(dir);
        }

        let url = self
            .url
            .ok_or_else(|| Error::invalid_config("URL is required"))?;
        let dg = is_dg_url(&url);

        let transport_mode = self.transport.unwrap_or(Transport::Mcp);

        // Resolve OAuth credentials now that the URL is known.
        let auth =
            if let Some((client_id, client_secret, endpoint, scope)) = self._pending_oauth_creds {
                let token_endpoint =
                    endpoint.unwrap_or_else(|| OAuthTokenProvider::derive_token_endpoint(&url));
                AuthConfig::ClientCredentials(OAuthTokenProvider::new(
                    client_id,
                    client_secret,
                    token_endpoint,
                    scope,
                ))
            } else {
                self.auth.unwrap_or(AuthConfig::None)
            };

        // Identity is explicit or set via with_identity_auto(); never implicitly discovered.
        let identity = self.identity;

        let identity_ref = identity.as_ref();

        let transport: Box<dyn TransportTrait> = match transport_mode {
            Transport::Mcp => Box::new(McpTransport::with_identity(url, auth, identity_ref)?),
            Transport::JsonRpc => {
                // When the user passes an MCP URL (ending in `/mcp`) and explicitly
                // selects JSONRPC transport, transparently rewrite the path to the
                // DG JSONRPC endpoint (`/rpc`).  This lets callers use the same base
                // URL regardless of transport without needing to know the suffix.
                let rpc_url = if url.ends_with("/mcp") {
                    format!("{}/rpc", url.trim_end_matches("/mcp"))
                } else {
                    url
                };
                Box::new(JsonRpcTransport::with_identity(
                    rpc_url,
                    auth,
                    identity_ref,
                )?)
            }
            Transport::Ws => {
                // Caller may pass an HTTPS-style URL (`/mcp` or `/rpc` suffix)
                // and we'll transparently switch to the matching WS endpoint
                // (`/ws`) over `wss://`. This lets the same base URL drive
                // every transport.
                let ws_url = rewrite_to_ws(&url);
                Box::new(WsTransport::with_identity(ws_url, auth, identity_ref)?)
            }
        };

        Ok(Client {
            transport: Arc::new(RwLock::new(transport)),
            next_id: Arc::new(AtomicU64::new(1)),
            initialized: Arc::new(RwLock::new(false)),
            server_info: Arc::new(RwLock::new(None)),
            use_intelligent_interface: self.use_intelligent_interface.unwrap_or(dg),
            max_retries: self.max_retries,
            is_dg: dg,
            dg_warned: Arc::new(std::sync::atomic::AtomicBool::new(false)),
            is_jsonrpc: matches!(transport_mode, Transport::JsonRpc),
        })
    }
}

// ============================================================================
// Builder types
// ============================================================================

/// Builder for semantic tool discovery (`data-grout/discovery.discover`).
///
/// Obtained via [`Client::discover`].  Call `.execute()` to send the request.
pub struct DiscoverBuilder<'a> {
    client: &'a Client,
    options: DiscoverOptions,
}

impl<'a> DiscoverBuilder<'a> {
    pub(crate) fn new(client: &'a Client) -> Self {
        Self {
            client,
            options: DiscoverOptions {
                limit: 10,
                min_score: 0.0,
                ..Default::default()
            },
        }
    }

    /// Filter tools by a free-text search query.
    pub fn query(mut self, query: impl Into<String>) -> Self {
        self.options.query = Some(query.into());
        self
    }

    /// Filter tools by a natural language goal description.
    pub fn goal(mut self, goal: impl Into<String>) -> Self {
        self.options.goal = Some(goal.into());
        self
    }

    /// Maximum number of results to return (default: 10).
    pub fn limit(mut self, limit: usize) -> Self {
        self.options.limit = limit;
        self
    }

    /// Minimum semantic similarity score threshold (0.0–1.0, default: 0.0).
    pub fn min_score(mut self, score: f64) -> Self {
        self.options.min_score = score;
        self
    }

    /// Restrict results to a specific integration (e.g. `"salesforce"`).
    /// May be called multiple times to allow several integrations.
    pub fn integration(mut self, integration: impl Into<String>) -> Self {
        self.options.integrations.push(integration.into());
        self
    }

    /// Restrict results to a specific server ID.
    /// May be called multiple times to allow several servers.
    pub fn server(mut self, server: impl Into<String>) -> Self {
        self.options.servers.push(server.into());
        self
    }

    /// Execute the discovery request and return matching tools with scores.
    pub async fn execute(self) -> Result<DiscoverResult> {
        self.client.ensure_initialized().await?;

        let mut params = json!({
            "limit": self.options.limit,
            "min_score": self.options.min_score,
        });

        if let Some(query) = self.options.query {
            params["query"] = json!(query);
        }
        if let Some(goal) = self.options.goal {
            params["goal"] = json!(goal);
        }
        if !self.options.integrations.is_empty() {
            params["integrations"] = json!(self.options.integrations);
        }
        if !self.options.servers.is_empty() {
            params["servers"] = json!(self.options.servers);
        }

        let result = self
            .client
            .call_dg_tool("data-grout/discovery.discover", params)
            .await?;
        Ok(serde_json::from_value(result)?)
    }
}

/// Builder for tool execution (`data-grout/discovery.perform`).
///
/// Obtained via [`Client::perform`].  Call `.execute()` to send the request.
pub struct PerformBuilder<'a> {
    client: &'a Client,
    tool: String,
    args: Option<Value>,
    options: PerformOptions,
}

impl<'a> PerformBuilder<'a> {
    pub(crate) fn new(client: &'a Client, tool: String) -> Self {
        Self {
            client,
            tool,
            args: None,
            options: PerformOptions::default(),
        }
    }

    /// Set the tool arguments as a JSON object.
    pub fn args(mut self, args: Value) -> Self {
        self.args = Some(args);
        self
    }

    /// Enable or disable output demultiplexing (default: disabled).
    pub fn demux(mut self, enabled: bool) -> Self {
        self.options.demux = enabled;
        self
    }

    /// Set the demux mode (`"strict"` or `"fuzzy"`).
    pub fn demux_mode(mut self, mode: impl Into<String>) -> Self {
        self.options.demux_mode = mode.into();
        self
    }

    /// Execute the tool call.
    pub async fn execute(self) -> Result<Value> {
        self.client.ensure_initialized().await?;

        let params = json!({
            "tool": self.tool,
            "args": self.args.unwrap_or(json!({})),
            "demux": self.options.demux,
            "demux_mode": self.options.demux_mode,
        });

        self.client
            .call_dg_tool("data-grout/discovery.perform", params)
            .await
    }
}

/// Builder for guided multi-step workflows (`data-grout/discovery.guide`).
///
/// Obtained via [`Client::guide`].  Call `.execute()` to send the request and
/// receive a [`GuidedSession`].
pub struct GuideBuilder<'a> {
    client: &'a Client,
    options: GuideOptions,
}

impl<'a> GuideBuilder<'a> {
    pub(crate) fn new(client: &'a Client) -> Self {
        Self {
            client,
            options: GuideOptions::default(),
        }
    }

    /// Set the natural language goal to start a new workflow session.
    pub fn goal(mut self, goal: impl Into<String>) -> Self {
        self.options.goal = Some(goal.into());
        self
    }

    /// Resume an existing session by its ID.
    pub fn session_id(mut self, id: impl Into<String>) -> Self {
        self.options.session_id = Some(id.into());
        self
    }

    /// Advance the session by making a choice from the options list.
    pub fn choice(mut self, choice: impl Into<String>) -> Self {
        self.options.choice = Some(choice.into());
        self
    }

    /// Execute and return the current workflow state.
    pub async fn execute(self) -> Result<GuidedSession<'a>> {
        self.client.ensure_initialized().await?;

        let mut params = json!({});

        if let Some(goal) = self.options.goal {
            params["goal"] = json!(goal);
        }
        if let Some(session_id) = self.options.session_id {
            params["session_id"] = json!(session_id);
        }
        if let Some(choice) = self.options.choice {
            params["choice"] = json!(choice);
        }

        let result = self
            .client
            .call_dg_tool("data-grout/discovery.guide", params)
            .await?;
        let state: GuideState = serde_json::from_value(result)?;
        Ok(GuidedSession::new(self.client, state))
    }
}

/// An active guided workflow session.
///
/// Returned by [`GuideBuilder::execute`].  Inspect [`status`](Self::status)
/// and [`options`](Self::options) then call [`choose`](Self::choose) to
/// advance the workflow.
pub struct GuidedSession<'a> {
    client: &'a Client,
    state: GuideState,
}

impl<'a> GuidedSession<'a> {
    pub(crate) fn new(client: &'a Client, state: GuideState) -> Self {
        Self { client, state }
    }

    /// Opaque session identifier — pass to `guide().session_id()` to resume.
    pub fn session_id(&self) -> &str {
        &self.state.session_id
    }

    /// Current workflow status (e.g. `"pending"`, `"completed"`, `"failed"`).
    pub fn status(&self) -> &str {
        &self.state.status
    }

    /// Available next steps, or `None` when the workflow is complete.
    pub fn options(&self) -> Option<&[GuideOption]> {
        self.state.options.as_deref()
    }

    /// Final result value when `status == "completed"`.
    pub fn result(&self) -> Option<&Value> {
        self.state.result.as_ref()
    }

    /// Full raw server state.
    pub fn state(&self) -> &GuideState {
        &self.state
    }

    /// Make a choice and return the updated session state.
    pub async fn choose(&self, option_id: impl Into<String>) -> Result<GuidedSession<'a>> {
        let session = self
            .client
            .guide()
            .session_id(&self.state.session_id)
            .choice(option_id)
            .execute()
            .await?;

        Ok(session)
    }

    /// Return the final result, or an error if the workflow is not yet complete.
    pub async fn complete(&self) -> Result<Value> {
        if self.status() == "completed" {
            if let Some(result) = self.result() {
                return Ok(result.clone());
            }
        }

        Err(Error::Other(format!(
            "Workflow not complete (status: {}). Call choose() with an option.",
            self.status()
        )))
    }
}

/// Builder for executing a multi-step workflow plan (`data-grout/flow.into`).
///
/// Obtained via [`Client::flow_into`].  Call `.execute()` to run the plan.
pub struct FlowIntoBuilder<'a> {
    client: &'a Client,
    plan: Vec<Value>,
    validate_ctc: bool,
    save_as_skill: bool,
    input_data: Option<Value>,
}

impl<'a> FlowIntoBuilder<'a> {
    pub(crate) fn new(client: &'a Client, plan: Vec<Value>) -> Self {
        Self {
            client,
            plan,
            validate_ctc: true,
            save_as_skill: false,
            input_data: None,
        }
    }

    /// Enable or disable CTC validation before execution (default: enabled).
    pub fn validate_ctc(mut self, validate: bool) -> Self {
        self.validate_ctc = validate;
        self
    }

    /// Save the executed workflow as a reusable skill on the server.
    pub fn save_as_skill(mut self, save: bool) -> Self {
        self.save_as_skill = save;
        self
    }

    /// Provide initial input data injected at the first step.
    pub fn input_data(mut self, data: Value) -> Self {
        self.input_data = Some(data);
        self
    }

    /// Execute the workflow plan.  The result JSON may contain a
    /// `_datagrout.receipt` key — use [`extract_meta`](crate::types::extract_meta) to read it.
    pub async fn execute(self) -> Result<Value> {
        self.client.ensure_initialized().await?;

        let mut params = json!({
            "plan": self.plan,
            "validate_ctc": self.validate_ctc,
            "save_as_skill": self.save_as_skill,
        });

        if let Some(input_data) = self.input_data {
            params["input_data"] = input_data;
        }

        // Receipt is embedded in result["_datagrout"]["receipt"] — callers can use
        // extract_meta(&result) to access it without any client-side state.
        self.client
            .call_dg_tool("data-grout/flow.into", params)
            .await
    }
}

/// Builder for the AI workflow planner (`data-grout/discovery.plan`).
///
/// Obtained via [`Client::plan`].  At least one of `.goal()` or `.query()`
/// must be set before calling `.execute()`.
pub struct PlanBuilder<'a> {
    client: &'a Client,
    options: PlanOptions,
}

impl<'a> PlanBuilder<'a> {
    pub(crate) fn new(client: &'a Client) -> Self {
        Self {
            client,
            options: PlanOptions::default(),
        }
    }

    /// Describe the desired outcome in natural language (preferred).
    pub fn goal(mut self, goal: impl Into<String>) -> Self {
        self.options.goal = Some(goal.into());
        self
    }

    /// Provide a semantic query string as an alternative to `goal`.
    pub fn query(mut self, query: impl Into<String>) -> Self {
        self.options.query = Some(query.into());
        self
    }

    /// Restrict planning to a specific server ID.
    pub fn server(mut self, server: impl Into<String>) -> Self {
        self.options.server = Some(server.into());
        self
    }

    /// Number of candidate steps the planner considers (higher = more thorough).
    pub fn k(mut self, k: u32) -> Self {
        self.options.k = Some(k);
        self
    }

    /// Governance policy object applied to the generated plan.
    pub fn policy(mut self, policy: Value) -> Self {
        self.options.policy = Some(policy);
        self
    }

    /// Pre-existing knowledge / context hints fed to the planner.
    pub fn have(mut self, have: Value) -> Self {
        self.options.have = Some(have);
        self
    }

    /// When `true`, each plan step includes an opaque call handle for auditing.
    pub fn return_call_handles(mut self, enabled: bool) -> Self {
        self.options.return_call_handles = enabled;
        self
    }

    /// When `true`, virtual skills are surfaced alongside concrete tools.
    pub fn expose_virtual_skills(mut self, enabled: bool) -> Self {
        self.options.expose_virtual_skills = enabled;
        self
    }

    /// Per-step LLM model overrides (JSON object mapping step indices to model IDs).
    pub fn model_overrides(mut self, overrides: Value) -> Self {
        self.options.model_overrides = Some(overrides);
        self
    }

    /// Execute planning — at least one of `goal` or `query` must be set.
    ///
    /// Returns [`Error::InvalidConfig`](crate::error::Error::InvalidConfig) when
    /// neither `goal` nor `query` has been set.
    pub async fn execute(self) -> Result<PlanResult> {
        self.client.ensure_initialized().await?;

        if self.options.goal.is_none() && self.options.query.is_none() {
            return Err(Error::invalid_config(
                "plan() requires at least one of `goal` or `query`",
            ));
        }

        let mut params = json!({
            "return_call_handles": self.options.return_call_handles,
            "expose_virtual_skills": self.options.expose_virtual_skills,
        });

        if let Some(goal) = self.options.goal {
            params["goal"] = json!(goal);
        }
        if let Some(query) = self.options.query {
            params["query"] = json!(query);
        }
        if let Some(server) = self.options.server {
            params["server"] = json!(server);
        }
        if let Some(k) = self.options.k {
            params["k"] = json!(k);
        }
        if let Some(policy) = self.options.policy {
            params["policy"] = policy;
        }
        if let Some(have) = self.options.have {
            params["have"] = have;
        }
        if let Some(model_overrides) = self.options.model_overrides {
            params["model_overrides"] = model_overrides;
        }

        self.client
            .call_dg_tool("data-grout/discovery.plan", params)
            .await
    }
}

/// Builder for AI-driven data transformation (`data-grout/prism.refract`).
///
/// Obtained via [`Client::refract`].  Call `.execute()` to send the request.
pub struct RefractBuilder<'a> {
    client: &'a Client,
    options: RefractOptions,
}

impl<'a> RefractBuilder<'a> {
    pub(crate) fn new(client: &'a Client, goal: String, payload: Value) -> Self {
        Self {
            client,
            options: RefractOptions {
                goal,
                payload,
                verbose: false,
                chart: false,
            },
        }
    }

    /// Emit verbose intermediate reasoning steps in the response.
    pub fn verbose(mut self, enabled: bool) -> Self {
        self.options.verbose = enabled;
        self
    }

    /// Request a chart representation alongside the transformed data.
    pub fn chart(mut self, enabled: bool) -> Self {
        self.options.chart = enabled;
        self
    }

    /// Execute the data transformation.
    pub async fn execute(self) -> Result<RefractResult> {
        self.client.ensure_initialized().await?;

        let params = json!({
            "goal": self.options.goal,
            "payload": self.options.payload,
            "verbose": self.options.verbose,
            "chart": self.options.chart,
        });

        self.client
            .call_dg_tool("data-grout/prism.refract", params)
            .await
    }
}

/// Builder for AI-driven charting (`data-grout/prism.chart`).
///
/// Obtained via [`Client::chart`].  Call `.execute()` to send the request.
pub struct ChartBuilder<'a> {
    client: &'a Client,
    options: ChartOptions,
}

impl<'a> ChartBuilder<'a> {
    pub(crate) fn new(client: &'a Client, goal: String, payload: Value) -> Self {
        Self {
            client,
            options: ChartOptions {
                goal,
                payload,
                format: None,
                chart_type: None,
                title: None,
                x_label: None,
                y_label: None,
                width: None,
                height: None,
            },
        }
    }

    /// Output format: `"svg"`, `"png"`, `"json"`, etc. (default: server decides).
    pub fn format(mut self, format: impl Into<String>) -> Self {
        self.options.format = Some(format.into());
        self
    }

    /// Chart type hint: `"bar"`, `"line"`, `"pie"`, etc. (default: server decides).
    pub fn chart_type(mut self, chart_type: impl Into<String>) -> Self {
        self.options.chart_type = Some(chart_type.into());
        self
    }

    /// Chart title rendered above the visualisation.
    pub fn title(mut self, title: impl Into<String>) -> Self {
        self.options.title = Some(title.into());
        self
    }

    /// X-axis label.
    pub fn x_label(mut self, label: impl Into<String>) -> Self {
        self.options.x_label = Some(label.into());
        self
    }

    /// Y-axis label.
    pub fn y_label(mut self, label: impl Into<String>) -> Self {
        self.options.y_label = Some(label.into());
        self
    }

    /// Width of the output image in pixels.
    pub fn width(mut self, width: u32) -> Self {
        self.options.width = Some(width);
        self
    }

    /// Height of the output image in pixels.
    pub fn height(mut self, height: u32) -> Self {
        self.options.height = Some(height);
        self
    }

    /// Execute the charting request.
    pub async fn execute(self) -> Result<ChartResult> {
        self.client.ensure_initialized().await?;

        let mut params = json!({
            "goal": self.options.goal,
            "payload": self.options.payload,
        });

        if let Some(format) = self.options.format {
            params["format"] = json!(format);
        }
        if let Some(chart_type) = self.options.chart_type {
            params["chart_type"] = json!(chart_type);
        }
        if let Some(title) = self.options.title {
            params["title"] = json!(title);
        }
        if let Some(x_label) = self.options.x_label {
            params["x_label"] = json!(x_label);
        }
        if let Some(y_label) = self.options.y_label {
            params["y_label"] = json!(y_label);
        }
        if let Some(width) = self.options.width {
            params["width"] = json!(width);
        }
        if let Some(height) = self.options.height {
            params["height"] = json!(height);
        }

        self.client
            .call_dg_tool("data-grout/prism.chart", params)
            .await
    }
}

/// Builder for semantic type transformation (`data-grout/prism.focus`).
///
/// Obtained via [`Client::prism_focus`].  Set `.data()`, `.source_type()`,
/// and `.target_type()` then call `.execute()`.
pub struct PrismFocusBuilder<'a> {
    client: &'a Client,
    data: Option<Value>,
    source_type: Option<String>,
    target_type: Option<String>,
}

impl<'a> PrismFocusBuilder<'a> {
    pub(crate) fn new(client: &'a Client) -> Self {
        Self {
            client,
            data: None,
            source_type: None,
            target_type: None,
        }
    }

    /// The data to transform (required).
    pub fn data(mut self, data: Value) -> Self {
        self.data = Some(data);
        self
    }

    /// Source semantic type label (required), e.g. `"salesforce.Lead"`.
    pub fn source_type(mut self, type_name: impl Into<String>) -> Self {
        self.source_type = Some(type_name.into());
        self
    }

    /// Target semantic type label (required), e.g. `"stripe.Customer"`.
    pub fn target_type(mut self, type_name: impl Into<String>) -> Self {
        self.target_type = Some(type_name.into());
        self
    }

    /// Execute the type transformation.
    pub async fn execute(self) -> Result<Value> {
        self.client.ensure_initialized().await?;

        let data = self
            .data
            .ok_or_else(|| Error::invalid_config("data is required"))?;
        let source_type = self
            .source_type
            .ok_or_else(|| Error::invalid_config("source_type is required"))?;
        let target_type = self
            .target_type
            .ok_or_else(|| Error::invalid_config("target_type is required"))?;

        let params = json!({
            "data": data,
            "source_type": source_type,
            "target_type": target_type,
        });

        self.client
            .call_dg_tool("data-grout/prism.focus", params)
            .await
    }
}
