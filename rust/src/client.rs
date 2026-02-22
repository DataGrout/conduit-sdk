//! Main client implementation

use crate::error::{Error, Result};
use crate::identity::ConduitIdentity;
use crate::oauth::OAuthTokenProvider;
use crate::protocol::*;
use crate::transport::{AuthConfig, JsonRpcTransport, McpTransport, Transport, TransportTrait};
use crate::types::*;
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
    url.contains("datagrout.ai") || url.contains("datagrout.dev")
}

/// Conduit client
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
}

// Manual Debug implementation since TransportTrait doesn't implement Debug
impl std::fmt::Debug for Client {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("Client")
            .field("next_id", &self.next_id)
            .field("initialized", &self.initialized)
            .field("use_intelligent_interface", &self.use_intelligent_interface)
            .field("is_dg", &self.is_dg)
            .field("max_retries", &self.max_retries)
            .finish_non_exhaustive()
    }
}

impl Client {
    /// Create a new client builder
    pub fn builder() -> ClientBuilder {
        ClientBuilder::default()
    }

    /// Connect and initialize the session
    pub async fn connect(&self) -> Result<()> {
        // Connect transport
        let mut transport = self.transport.write().await;
        transport.connect().await?;
        drop(transport);

        // Send initialize request
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

        let request = self.build_request(
            "initialize",
            Some(serde_json::to_value(params)?),
        )?;

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

    /// Disconnect from server
    pub async fn disconnect(&self) -> Result<()> {
        let mut transport = self.transport.write().await;
        transport.disconnect().await?;

        let mut initialized = self.initialized.write().await;
        *initialized = false;

        Ok(())
    }

    /// Check if initialized
    pub async fn is_initialized(&self) -> bool {
        *self.initialized.read().await
    }

    /// Get server info
    pub async fn server_info(&self) -> Option<ServerInfo> {
        self.server_info.read().await.clone()
    }

    // ========================================================================
    // Standard MCP Methods
    // ========================================================================

    /// List available tools
    pub async fn list_tools(&self) -> Result<Vec<Tool>> {
        self.ensure_initialized().await?;

        let mut all_tools = Vec::new();
        let mut cursor: Option<String> = None;

        // Handle pagination
        loop {
            let params = ListToolsParams {
                cursor: cursor.clone(),
            };

            let request = self.build_request(
                "tools/list",
                Some(serde_json::to_value(params)?),
            )?;

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
            all_tools.into_iter().filter(|t| !t.name.contains('@')).collect()
        } else {
            all_tools
        };

        Ok(all_tools)
    }

    /// Call a tool
    pub async fn call_tool(&self, name: impl Into<String>, arguments: Value) -> Result<Value> {
        self.ensure_initialized().await?;

        let params = CallToolParams {
            name: name.into(),
            arguments: Some(arguments),
        };

        let request = self.build_request(
            "tools/call",
            Some(serde_json::to_value(params)?),
        )?;

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

    /// List available resources
    pub async fn list_resources(&self) -> Result<Vec<Value>> {
        self.ensure_initialized().await?;

        let params = ListResourcesParams::default();
        let request = self.build_request(
            "resources/list",
            Some(serde_json::to_value(params)?),
        )?;

        let response = self.send_with_retry(request).await?;

        if let Some(result) = response.result {
            let list_result: ListResourcesResult = serde_json::from_value(result)?;
            Ok(list_result.resources)
        } else {
            Ok(Vec::new())
        }
    }

    /// Read a resource
    pub async fn read_resource(&self, uri: impl Into<String>) -> Result<Vec<Value>> {
        self.ensure_initialized().await?;

        let params = ReadResourceParams { uri: uri.into() };
        let request = self.build_request(
            "resources/read",
            Some(serde_json::to_value(params)?),
        )?;

        let response = self.send_with_retry(request).await?;

        if let Some(result) = response.result {
            let read_result: ReadResourceResult = serde_json::from_value(result)?;
            Ok(read_result.contents)
        } else {
            Ok(Vec::new())
        }
    }

    /// List available prompts
    pub async fn list_prompts(&self) -> Result<Vec<Value>> {
        self.ensure_initialized().await?;

        let params = ListPromptsParams::default();
        let request = self.build_request(
            "prompts/list",
            Some(serde_json::to_value(params)?),
        )?;

        let response = self.send_with_retry(request).await?;

        if let Some(result) = response.result {
            let list_result: ListPromptsResult = serde_json::from_value(result)?;
            Ok(list_result.prompts)
        } else {
            Ok(Vec::new())
        }
    }

    /// Get a prompt
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

        let request = self.build_request(
            "prompts/get",
            Some(serde_json::to_value(params)?),
        )?;

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

    /// Create a discovery builder
    pub fn discover(&self) -> DiscoverBuilder<'_> {
        self.warn_if_not_dg("discover");
        DiscoverBuilder::new(self)
    }

    /// Create a perform builder
    pub fn perform(&self, tool: impl Into<String>) -> PerformBuilder<'_> {
        self.warn_if_not_dg("perform");
        PerformBuilder::new(self, tool.into())
    }

    /// Create a guide builder
    pub fn guide(&self) -> GuideBuilder<'_> {
        self.warn_if_not_dg("guide");
        GuideBuilder::new(self)
    }

    /// Execute multi-step workflow
    pub fn flow_into(&self, plan: Vec<Value>) -> FlowIntoBuilder<'_> {
        self.warn_if_not_dg("flow_into");
        FlowIntoBuilder::new(self, plan)
    }

    /// Semantic type transformation
    pub fn prism_focus(&self) -> PrismFocusBuilder<'_> {
        self.warn_if_not_dg("prism_focus");
        PrismFocusBuilder::new(self)
    }

    /// Estimate cost before execution
    pub async fn estimate_cost(&self, tool: impl Into<String>, args: Value) -> Result<Value> {
        self.ensure_initialized().await?;

        let mut estimate_args = args;
        if let Some(obj) = estimate_args.as_object_mut() {
            obj.insert("estimate_only".to_string(), json!(true));
        }

        let request = self.build_request(
            tool.into(),
            Some(estimate_args),
        )?;

        let response = self.send_with_retry(request).await?;

        if let Some(result) = response.result {
            Ok(result)
        } else {
            Err(Error::Other("Estimate returned no result".to_string()))
        }
    }

    // ========================================================================
    // DG-awareness helpers
    // ========================================================================

    /// Emit a one-time warning when a DG-specific method is called against a
    /// non-DataGrout server.  Safe to call from every DG-specific method — the
    /// warning fires at most once per `Client` instance.
    fn warn_if_not_dg(&self, method: &str) {
        if !self.is_dg
            && !self
                .dg_warned
                .swap(true, std::sync::atomic::Ordering::Relaxed)
        {
            eprintln!(
                "[conduit] warning: `{}` is a DataGrout-specific extension. \
                 The connected server ({}) may not support it. \
                 Standard MCP methods (list_tools, call_tool, …) work on any server.",
                method, "non-DG endpoint"
            );
        }
    }

    // ========================================================================
    // Internal helpers
    // ========================================================================

    fn build_request(&self, method: impl Into<String>, params: Option<Value>) -> Result<JsonRpcRequest> {
        let id = self.next_id.fetch_add(1, Ordering::SeqCst).to_string();
        Ok(JsonRpcRequest::new(id, method, params))
    }

    async fn ensure_initialized(&self) -> Result<()> {
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

/// Client builder
pub struct ClientBuilder {
    url: Option<String>,
    transport: Option<Transport>,
    auth: Option<AuthConfig>,
    identity: Option<ConduitIdentity>,
    use_intelligent_interface: bool,
    max_retries: usize,
    /// When `true`, never attempt mTLS even on DG URLs.
    disable_mtls: bool,
    /// Pending OAuth credentials resolved into `AuthConfig::ClientCredentials`
    /// during `build()` once the URL is known.
    _pending_oauth_creds: Option<(String, String, Option<String>, Option<String>)>,
}

impl Default for ClientBuilder {
    fn default() -> Self {
        Self {
            url: None,
            transport: None,
            auth: None,
            identity: None,
            use_intelligent_interface: false,
            max_retries: 3,
            disable_mtls: false,
            _pending_oauth_creds: None,
        }
    }
}

impl ClientBuilder {
    /// Create a new builder
    pub fn new() -> Self {
        Self::default()
    }

    /// Set the server URL
    pub fn url(mut self, url: impl Into<String>) -> Self {
        self.url = Some(url.into());
        self
    }

    /// Set the transport mode
    pub fn transport(mut self, transport: Transport) -> Self {
        self.transport = Some(transport);
        self
    }

    /// Set bearer token authentication
    pub fn auth_bearer(mut self, token: impl Into<String>) -> Self {
        self.auth = Some(AuthConfig::Bearer(token.into()));
        self
    }

    /// Set API key authentication
    pub fn auth_api_key(mut self, key: impl Into<String>) -> Self {
        self.auth = Some(AuthConfig::ApiKey(key.into()));
        self
    }

    /// Set basic authentication
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
        self._pending_oauth_creds =
            Some((client_id.into(), client_secret.into(), None, None));
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
    /// Checks env vars → `~/.conduit/` → `.conduit/` in the cwd.  If nothing
    /// is found this is a no-op: the client falls back to token auth silently.
    pub fn with_identity_auto(mut self) -> Self {
        self.identity = ConduitIdentity::try_default();
        self
    }

    /// Hide third-party tools (only show DataGrout tools)
    /// Enable the intelligent interface (DataGrout `discover` / `perform` only).
    ///
    /// When `true`, `list_tools()` returns only the DataGrout semantic discovery
    /// and execution tools instead of the raw tool list from the MCP server.
    /// This mirrors the `use_intelligent_interface` setting on the server.
    pub fn use_intelligent_interface(mut self, enabled: bool) -> Self {
        self.use_intelligent_interface = enabled;
        self
    }

    /// Set maximum retries for "not initialized" errors
    pub fn max_retries(mut self, retries: usize) -> Self {
        self.max_retries = retries;
        self
    }

    /// Disable mTLS even when connecting to a DataGrout URL.
    ///
    /// By default, DG URLs (`*.datagrout.ai`) automatically attempt to discover
    /// an mTLS identity via the auto-discovery chain.  Call this to opt out —
    /// useful in environments where you cannot persist certificates to disk or
    /// where you are intentionally using token-only auth.
    pub fn no_mtls(mut self) -> Self {
        self.disable_mtls = true;
        self.identity = None;
        self
    }

    /// Bootstrap an mTLS identity seamlessly.
    ///
    /// Checks the auto-discovery chain first (`~/.conduit/`, env vars).  If an
    /// existing identity is found and not near expiry it is used as-is.  If not
    /// found (or near expiry), a new keypair is generated, registered with
    /// DataGrout via the Arbiter API key, saved to `~/.conduit/`, and loaded
    /// as the active identity.
    ///
    /// This is the zero-friction path — call it once with the API key and the
    /// client handles everything automatically on every subsequent run.
    ///
    /// Requires the `registration` feature flag.
    ///
    /// # Example
    ///
    /// ```rust,no_run
    /// # use datagrout_conduit::ClientBuilder;
    /// # async fn example() -> Result<(), Box<dyn std::error::Error>> {
    /// let client = ClientBuilder::new()
    ///     .url("https://app.datagrout.ai/servers/{uuid}/mcp")
    ///     .bootstrap_identity(
    ///         std::env::var("ARBITER_API_KEY")?,
    ///         "my-agent",
    ///         "https://app.datagrout.ai/api/v1/substrate/identity",
    ///     )
    ///     .await?
    ///     .build()?;
    /// # Ok(())
    /// # }
    /// ```
    #[cfg(feature = "registration")]
    pub async fn bootstrap_identity(
        mut self,
        api_key: impl Into<String>,
        name: impl Into<String>,
        substrate_endpoint: impl Into<String>,
    ) -> crate::error::Result<Self> {
        use crate::registration::{
            default_identity_dir, generate_keypair, register_identity,
            save_identity_to_dir, RegistrationOptions,
        };

        // Fast path: existing identity that doesn't need rotation.
        if let Some(existing) = ConduitIdentity::try_default() {
            if !existing.needs_rotation(7) {
                self.identity = Some(existing);
                return Ok(self);
            }
        }

        // Slow path: generate and register a new identity.
        let name_str = name.into();
        let keypair = generate_keypair(&name_str)?;
        let opts = RegistrationOptions {
            endpoint: substrate_endpoint.into(),
            api_key: api_key.into(),
            name: name_str,
        };
        let (identity, _resp) = register_identity(&keypair, &opts).await?;

        // Persist so future runs skip registration.
        if let Some(dir) = default_identity_dir() {
            let _ = save_identity_to_dir(&identity, &dir);
        }

        self.identity = Some(identity);
        Ok(self)
    }

    /// Build the client
    pub fn build(self) -> Result<Client> {
        let url = self.url.ok_or_else(|| Error::invalid_config("URL is required"))?;
        let dg = is_dg_url(&url);

        let transport_mode = self.transport.unwrap_or(Transport::JsonRpc);

        // Resolve OAuth credentials now that the URL is known.
        let auth = if let Some((client_id, client_secret, endpoint, scope)) =
            self._pending_oauth_creds
        {
            let token_endpoint = endpoint
                .unwrap_or_else(|| OAuthTokenProvider::derive_token_endpoint(&url));
            AuthConfig::ClientCredentials(OAuthTokenProvider::new(
                client_id,
                client_secret,
                token_endpoint,
                scope,
            ))
        } else {
            self.auth.unwrap_or(AuthConfig::None)
        };

        // For DG URLs, silently try auto-discovering an mTLS identity if none was
        // explicitly set and mTLS wasn't disabled. Non-DG URLs never auto-discover.
        let identity = if dg && !self.disable_mtls && self.identity.is_none() {
            ConduitIdentity::try_default()
        } else {
            self.identity
        };

        let identity_ref = identity.as_ref();

        let transport: Box<dyn TransportTrait> = match transport_mode {
            Transport::Mcp => Box::new(McpTransport::with_identity(url, auth, identity_ref)?),
            Transport::JsonRpc => {
                Box::new(JsonRpcTransport::with_identity(url, auth, identity_ref)?)
            }
        };

        Ok(Client {
            transport: Arc::new(RwLock::new(transport)),
            next_id: Arc::new(AtomicU64::new(1)),
            initialized: Arc::new(RwLock::new(false)),
            server_info: Arc::new(RwLock::new(None)),
            use_intelligent_interface: self.use_intelligent_interface,
            max_retries: self.max_retries,
            is_dg: dg,
            dg_warned: Arc::new(std::sync::atomic::AtomicBool::new(false)),
        })
    }
}

/// Discovery builder
pub struct DiscoverBuilder<'a> {
    client: &'a Client,
    options: DiscoverOptions,
}

impl<'a> DiscoverBuilder<'a> {
    fn new(client: &'a Client) -> Self {
        Self {
            client,
            options: DiscoverOptions {
                limit: 10,
                min_score: 0.0,
                ..Default::default()
            },
        }
    }

    /// Set search query
    pub fn query(mut self, query: impl Into<String>) -> Self {
        self.options.query = Some(query.into());
        self
    }

    /// Set natural language goal
    pub fn goal(mut self, goal: impl Into<String>) -> Self {
        self.options.goal = Some(goal.into());
        self
    }

    /// Set result limit
    pub fn limit(mut self, limit: usize) -> Self {
        self.options.limit = limit;
        self
    }

    /// Set minimum score
    pub fn min_score(mut self, score: f64) -> Self {
        self.options.min_score = score;
        self
    }

    /// Filter by integration
    pub fn integration(mut self, integration: impl Into<String>) -> Self {
        self.options.integrations.push(integration.into());
        self
    }

    /// Filter by server
    pub fn server(mut self, server: impl Into<String>) -> Self {
        self.options.servers.push(server.into());
        self
    }

    /// Execute discovery
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

        let request = self.client.build_request(
            "data-grout/discovery.discover",
            Some(params),
        )?;

        let response = self.client.send_with_retry(request).await?;

        if let Some(result) = response.result {
            Ok(serde_json::from_value(result)?)
        } else {
            Err(Error::Other("Discovery returned no result".to_string()))
        }
    }
}

/// Perform builder
pub struct PerformBuilder<'a> {
    client: &'a Client,
    tool: String,
    args: Option<Value>,
    options: PerformOptions,
}

impl<'a> PerformBuilder<'a> {
    fn new(client: &'a Client, tool: String) -> Self {
        Self {
            client,
            tool,
            args: None,
            options: PerformOptions::default(),
        }
    }

    /// Set tool arguments
    pub fn args(mut self, args: Value) -> Self {
        self.args = Some(args);
        self
    }

    /// Enable demultiplexing
    pub fn demux(mut self, enabled: bool) -> Self {
        self.options.demux = enabled;
        self
    }

    /// Set demux mode
    pub fn demux_mode(mut self, mode: impl Into<String>) -> Self {
        self.options.demux_mode = mode.into();
        self
    }

    /// Execute tool call
    pub async fn execute(self) -> Result<Value> {
        self.client.ensure_initialized().await?;

        let params = json!({
            "tool": self.tool,
            "args": self.args.unwrap_or(json!({})),
            "demux": self.options.demux,
            "demux_mode": self.options.demux_mode,
        });

        let request = self.client.build_request(
            "data-grout/discovery.perform",
            Some(params),
        )?;

        let response = self.client.send_with_retry(request).await?;

        if let Some(result) = response.result {
            Ok(result)
        } else {
            Err(Error::Other("Perform returned no result".to_string()))
        }
    }
}

/// Guide builder
pub struct GuideBuilder<'a> {
    client: &'a Client,
    options: GuideOptions,
}

impl<'a> GuideBuilder<'a> {
    fn new(client: &'a Client) -> Self {
        Self {
            client,
            options: GuideOptions::default(),
        }
    }

    /// Set natural language goal
    pub fn goal(mut self, goal: impl Into<String>) -> Self {
        self.options.goal = Some(goal.into());
        self
    }

    /// Continue existing session
    pub fn session_id(mut self, id: impl Into<String>) -> Self {
        self.options.session_id = Some(id.into());
        self
    }

    /// Make a choice
    pub fn choice(mut self, choice: impl Into<String>) -> Self {
        self.options.choice = Some(choice.into());
        self
    }

    /// Execute guided workflow
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

        let request = self.client.build_request(
            "data-grout/discovery.guide",
            Some(params),
        )?;

        let response = self.client.send_with_retry(request).await?;

        if let Some(result) = response.result {
            let state: GuideState = serde_json::from_value(result)?;
            Ok(GuidedSession::new(self.client, state))
        } else {
            Err(Error::Other("Guide returned no result".to_string()))
        }
    }
}

/// Guided session (workflow)
pub struct GuidedSession<'a> {
    client: &'a Client,
    state: GuideState,
}

impl<'a> GuidedSession<'a> {
    fn new(client: &'a Client, state: GuideState) -> Self {
        Self { client, state }
    }

    /// Get session ID
    pub fn session_id(&self) -> &str {
        &self.state.session_id
    }

    /// Get current status
    pub fn status(&self) -> &str {
        &self.state.status
    }

    /// Get available options
    pub fn options(&self) -> Option<&[GuideOption]> {
        self.state.options.as_deref()
    }

    /// Get final result (if completed)
    pub fn result(&self) -> Option<&Value> {
        self.state.result.as_ref()
    }

    /// Get full state
    pub fn state(&self) -> &GuideState {
        &self.state
    }

    /// Make a choice and advance workflow
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

    /// Wait for completion and return final result
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

/// FlowInto builder
pub struct FlowIntoBuilder<'a> {
    client: &'a Client,
    plan: Vec<Value>,
    validate_ctc: bool,
    save_as_skill: bool,
    input_data: Option<Value>,
}

impl<'a> FlowIntoBuilder<'a> {
    fn new(client: &'a Client, plan: Vec<Value>) -> Self {
        Self {
            client,
            plan,
            validate_ctc: true,
            save_as_skill: false,
            input_data: None,
        }
    }

    /// Enable/disable CTC validation
    pub fn validate_ctc(mut self, validate: bool) -> Self {
        self.validate_ctc = validate;
        self
    }

    /// Save workflow as reusable skill
    pub fn save_as_skill(mut self, save: bool) -> Self {
        self.save_as_skill = save;
        self
    }

    /// Set initial input data
    pub fn input_data(mut self, data: Value) -> Self {
        self.input_data = Some(data);
        self
    }

    /// Execute workflow
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

        let request = self.client.build_request(
            "data-grout/flow.into",
            Some(params),
        )?;

        let response = self.client.send_with_retry(request).await?;

        if let Some(result) = response.result {
            // Receipt is embedded in result["_datagrout"]["receipt"] — callers can use
            // extract_meta(&result) to access it without any client-side state.
            Ok(result)
        } else {
            Err(Error::Other("Flow.into returned no result".to_string()))
        }
    }
}

/// PrismFocus builder
pub struct PrismFocusBuilder<'a> {
    client: &'a Client,
    data: Option<Value>,
    source_type: Option<String>,
    target_type: Option<String>,
}

impl<'a> PrismFocusBuilder<'a> {
    fn new(client: &'a Client) -> Self {
        Self {
            client,
            data: None,
            source_type: None,
            target_type: None,
        }
    }

    /// Set data to transform
    pub fn data(mut self, data: Value) -> Self {
        self.data = Some(data);
        self
    }

    /// Set source semantic type
    pub fn source_type(mut self, type_name: impl Into<String>) -> Self {
        self.source_type = Some(type_name.into());
        self
    }

    /// Set target semantic type
    pub fn target_type(mut self, type_name: impl Into<String>) -> Self {
        self.target_type = Some(type_name.into());
        self
    }

    /// Execute type transformation
    pub async fn execute(self) -> Result<Value> {
        self.client.ensure_initialized().await?;

        let data = self.data.ok_or_else(|| Error::invalid_config("data is required"))?;
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

        let request = self.client.build_request(
            "data-grout/prism.focus",
            Some(params),
        )?;

        let response = self.client.send_with_retry(request).await?;

        if let Some(result) = response.result {
            Ok(result)
        } else {
            Err(Error::Other("Prism.focus returned no result".to_string()))
        }
    }
}
