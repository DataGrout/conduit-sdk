//! Transport layer for MCP communication

use crate::error::{Error, RateLimit, Result};
use crate::identity::ConduitIdentity;
use crate::oauth::OAuthTokenProvider;
use crate::protocol::{JsonRpcRequest, JsonRpcResponse};
use async_trait::async_trait;
use base64::{engine::general_purpose, Engine as _};
use reqwest::{header, Client as HttpClient, Response, StatusCode};
use std::sync::Arc;
use tokio::sync::RwLock;

/// Transport mode
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Transport {
    /// MCP over SSE
    Mcp,
    /// JSON-RPC over HTTP POST
    JsonRpc,
}

/// Authentication configuration
#[derive(Debug, Clone)]
pub enum AuthConfig {
    /// No authentication — works for public utilities like the inspectors.
    /// Anonymous visitors are subject to an hourly rate cap server-side.
    None,
    /// Bearer token — grants unlimited inspector access for DG users.
    Bearer(String),
    /// API key
    ApiKey(String),
    /// Basic auth (e.g. site-wide basic auth protecting the inspectors)
    Basic {
        /// Username
        username: String,
        /// Password
        password: String,
    },
    /// OAuth 2.1 `client_credentials` grant.
    ///
    /// The transport fetches a short-lived JWT from the DataGrout token
    /// endpoint on the first request and automatically refreshes it before
    /// it expires.  Application code never handles tokens directly.
    ClientCredentials(OAuthTokenProvider),
}

/// Base transport trait
#[async_trait]
pub trait TransportTrait: Send + Sync {
    /// Connect to server
    async fn connect(&mut self) -> Result<()>;

    /// Disconnect from server
    async fn disconnect(&mut self) -> Result<()>;

    /// Send request and wait for response
    async fn send_request(&self, request: JsonRpcRequest) -> Result<JsonRpcResponse>;

    /// Check if connected
    fn is_connected(&self) -> bool;
}

// ─── Shared HTTP helpers ────────────────────────────────────────────────────

/// Build a `reqwest::Client`, optionally configured for mTLS.
///
/// When `identity` is `Some`, the client presents its certificate during every
/// TLS handshake.  If the identity also carries a custom CA, that CA is added
/// as a trusted root so the *server* cert can be verified against it.
fn build_http_client(identity: Option<&ConduitIdentity>) -> Result<HttpClient> {
    let mut builder = HttpClient::builder().timeout(std::time::Duration::from_secs(60));

    if let Some(id) = identity {
        let reqwest_id = id.to_reqwest_identity()?;
        builder = builder.identity(reqwest_id);

        if let Some(ca) = id.to_reqwest_ca()? {
            builder = builder.add_root_certificate(ca);
        }

        if id.needs_rotation(30) {
            tracing::warn!(
                "conduit: mTLS certificate expires within 30 days — consider rotating"
            );
        }
    }

    builder.build().map_err(Error::from)
}

fn build_headers(auth: &AuthConfig) -> header::HeaderMap {
    let mut headers = header::HeaderMap::new();
    headers.insert(
        header::CONTENT_TYPE,
        header::HeaderValue::from_static("application/json"),
    );
    headers.insert(
        header::ACCEPT,
        header::HeaderValue::from_static("application/json, text/event-stream"),
    );

    match auth {
        AuthConfig::Bearer(token) => {
            if let Ok(value) = header::HeaderValue::from_str(&format!("Bearer {}", token)) {
                headers.insert(header::AUTHORIZATION, value);
            }
        }
        AuthConfig::ApiKey(key) => {
            if let Ok(value) = header::HeaderValue::from_str(key) {
                headers.insert("X-API-Key", value);
            }
        }
        AuthConfig::Basic { username, password } => {
            let credentials =
                general_purpose::STANDARD.encode(format!("{}:{}", username, password));
            if let Ok(value) =
                header::HeaderValue::from_str(&format!("Basic {}", credentials))
            {
                headers.insert(header::AUTHORIZATION, value);
            }
        }
        // Token is fetched asynchronously and injected in send_request.
        AuthConfig::ClientCredentials(_) | AuthConfig::None => {}
    }

    headers
}

/// Inject an `Mcp-Session-Id` header when a session is active.
fn inject_session_id(session_id: &Option<String>, headers: &mut header::HeaderMap) {
    if let Some(ref sid) = *session_id {
        if let Ok(value) = header::HeaderValue::from_str(sid) {
            headers.insert("Mcp-Session-Id", value);
        }
    }
}

/// Capture the `mcp-session-id` response header and store it.
async fn capture_session_id(response: &Response, session_id: &RwLock<Option<String>>) {
    if let Some(value) = response.headers().get("mcp-session-id") {
        if let Ok(sid) = value.to_str() {
            let mut lock = session_id.write().await;
            *lock = Some(sid.to_owned());
        }
    }
}

/// Parse a response body that may be JSON or SSE, returning a `JsonRpcResponse`.
///
/// - `application/json` (or no Content-Type) → deserialize directly.
/// - `text/event-stream` → split on double-newlines, extract `data:` lines,
///   JSON-decode each one, and return the last JSON-RPC result message.
async fn parse_response(response: Response) -> Result<JsonRpcResponse> {
    let is_sse = response
        .headers()
        .get(header::CONTENT_TYPE)
        .and_then(|v| v.to_str().ok())
        .map(|ct| ct.contains("text/event-stream"))
        .unwrap_or(false);

    if is_sse {
        let body = response.text().await?;
        parse_sse_body(&body)
    } else {
        Ok(response.json().await?)
    }
}

/// Extract the last JSON-RPC result from an SSE body.
pub fn parse_sse_body(body: &str) -> Result<JsonRpcResponse> {
    let mut last_response: Option<JsonRpcResponse> = None;

    for event in body.split("\n\n") {
        for line in event.lines() {
            let data = if let Some(rest) = line.strip_prefix("data: ") {
                rest
            } else if let Some(rest) = line.strip_prefix("data:") {
                rest
            } else {
                continue;
            };

            let trimmed = data.trim();
            if trimmed.is_empty() {
                continue;
            }
            if let Ok(resp) = serde_json::from_str::<JsonRpcResponse>(trimmed) {
                last_response = Some(resp);
            }
        }
    }

    last_response.ok_or_else(|| Error::Protocol("No JSON-RPC message found in SSE stream".into()))
}

/// Build an empty "accepted" response for HTTP 202.
fn accepted_response(request: &JsonRpcRequest) -> JsonRpcResponse {
    JsonRpcResponse {
        jsonrpc: "2.0".to_string(),
        id: request.id.clone().unwrap_or_default(),
        result: Some(serde_json::Value::Null),
        error: None,
    }
}

/// Inject the OAuth bearer token from a `ClientCredentials` provider into an
/// existing header map.  Returns `Ok(())` if auth is not `ClientCredentials`.
async fn inject_oauth_token(
    auth: &AuthConfig,
    http_client: &HttpClient,
    headers: &mut header::HeaderMap,
) -> Result<()> {
    if let AuthConfig::ClientCredentials(provider) = auth {
        let token = provider.get_token(http_client).await?;
        if let Ok(value) = header::HeaderValue::from_str(&format!("Bearer {}", token)) {
            headers.insert(header::AUTHORIZATION, value);
        }
    }
    Ok(())
}

/// Inspect an HTTP response for rate-limit status and surface a typed error
/// when the server signals that the caller has been throttled.
///
/// The DataGrout inspector uses the following convention:
/// - HTTP 429 — rate limit exceeded
/// - `Retry-After` header — seconds until the window resets (optional)
/// - `X-RateLimit-Used` / `X-RateLimit-Limit` — quota details (optional)
/// - `X-RateLimit-Limit: unlimited` — authenticated DG users (never throttled)
fn check_rate_limit(response: &reqwest::Response) -> Option<Error> {
    if response.status() != StatusCode::TOO_MANY_REQUESTS {
        return None;
    }

    let retry_after: Option<u64> = response
        .headers()
        .get("Retry-After")
        .and_then(|v| v.to_str().ok())
        .and_then(|s| s.parse().ok());

    let used: u32 = response
        .headers()
        .get("X-RateLimit-Used")
        .and_then(|v| v.to_str().ok())
        .and_then(|s| s.parse().ok())
        .unwrap_or(0);

    let limit_str = response
        .headers()
        .get("X-RateLimit-Limit")
        .and_then(|v| v.to_str().ok())
        .unwrap_or("50");

    let limit = if limit_str.eq_ignore_ascii_case("unlimited") {
        RateLimit::Unlimited
    } else {
        RateLimit::PerHour(limit_str.parse().unwrap_or(50))
    };

    Some(Error::RateLimit { retry_after, used, limit })
}

// ─── MCP transport (SSE-based) ──────────────────────────────────────────────

/// MCP transport (SSE-based)
pub struct McpTransport {
    url: String,
    auth: AuthConfig,
    client: HttpClient,
    connected: Arc<RwLock<bool>>,
    session_id: Arc<RwLock<Option<String>>>,
}

impl McpTransport {
    /// Create new MCP transport without mTLS.
    pub fn new(url: String, auth: AuthConfig) -> Result<Self> {
        Self::with_identity(url, auth, None)
    }

    /// Create new MCP transport, optionally presenting a client certificate.
    pub fn with_identity(
        url: String,
        auth: AuthConfig,
        identity: Option<&ConduitIdentity>,
    ) -> Result<Self> {
        let client = build_http_client(identity)?;
        Ok(Self {
            url,
            auth,
            client,
            connected: Arc::new(RwLock::new(false)),
            session_id: Arc::new(RwLock::new(None)),
        })
    }
}

#[async_trait]
impl TransportTrait for McpTransport {
    async fn connect(&mut self) -> Result<()> {
        let _ = url::Url::parse(&self.url).map_err(|e| Error::invalid_url(e.to_string()))?;
        let mut connected = self.connected.write().await;
        *connected = true;
        Ok(())
    }

    async fn disconnect(&mut self) -> Result<()> {
        let mut connected = self.connected.write().await;
        *connected = false;
        Ok(())
    }

    async fn send_request(&self, request: JsonRpcRequest) -> Result<JsonRpcResponse> {
        if !self.is_connected() {
            return Err(Error::NotInitialized);
        }

        let mut headers = build_headers(&self.auth);
        inject_oauth_token(&self.auth, &self.client, &mut headers).await?;
        {
            let sid = self.session_id.read().await;
            inject_session_id(&sid, &mut headers);
        }

        let response = self
            .client
            .post(&self.url)
            .headers(headers)
            .json(&request)
            .send()
            .await?;

        if let Some(rl_err) = check_rate_limit(&response) {
            return Err(rl_err);
        }

        // On 401, invalidate the cached OAuth token and retry once.
        if response.status() == StatusCode::UNAUTHORIZED {
            if let AuthConfig::ClientCredentials(provider) = &self.auth {
                provider.invalidate().await;
                let mut retry_headers = build_headers(&self.auth);
                inject_oauth_token(&self.auth, &self.client, &mut retry_headers).await?;
                {
                    let sid = self.session_id.read().await;
                    inject_session_id(&sid, &mut retry_headers);
                }
                let retry_resp = self
                    .client
                    .post(&self.url)
                    .headers(retry_headers)
                    .json(&request)
                    .send()
                    .await?;
                if let Some(rl_err) = check_rate_limit(&retry_resp) {
                    return Err(rl_err);
                }
                if !retry_resp.status().is_success() {
                    return Err(Error::Auth("OAuth token rejected after refresh".into()));
                }
                capture_session_id(&retry_resp, &self.session_id).await;
                let json_resp = parse_response(retry_resp).await?;
                if let Some(error) = json_resp.error {
                    return Err(Error::server(error.code, error.message, error.data));
                }
                return Ok(json_resp);
            }
        }

        capture_session_id(&response, &self.session_id).await;

        if response.status() == StatusCode::ACCEPTED {
            return Ok(accepted_response(&request));
        }

        if !response.status().is_success() {
            return Err(Error::network(format!(
                "HTTP {} error",
                response.status()
            )));
        }

        let json_response = parse_response(response).await?;

        if let Some(error) = json_response.error {
            return Err(Error::server(error.code, error.message, error.data));
        }

        Ok(json_response)
    }

    fn is_connected(&self) -> bool {
        if let Ok(connected) = self.connected.try_read() {
            *connected
        } else {
            false
        }
    }
}

// ─── JSON-RPC transport (HTTP POST) ────────────────────────────────────────

/// JSON-RPC transport (HTTP POST-based)
pub struct JsonRpcTransport {
    url: String,
    auth: AuthConfig,
    client: HttpClient,
    connected: Arc<RwLock<bool>>,
    session_id: Arc<RwLock<Option<String>>>,
}

impl JsonRpcTransport {
    /// Create new JSON-RPC transport without mTLS.
    pub fn new(url: String, auth: AuthConfig) -> Result<Self> {
        Self::with_identity(url, auth, None)
    }

    /// Create new JSON-RPC transport, optionally presenting a client certificate.
    pub fn with_identity(
        url: String,
        auth: AuthConfig,
        identity: Option<&ConduitIdentity>,
    ) -> Result<Self> {
        let client = build_http_client(identity)?;
        Ok(Self {
            url,
            auth,
            client,
            connected: Arc::new(RwLock::new(false)),
            session_id: Arc::new(RwLock::new(None)),
        })
    }
}

#[async_trait]
impl TransportTrait for JsonRpcTransport {
    async fn connect(&mut self) -> Result<()> {
        let _ = url::Url::parse(&self.url).map_err(|e| Error::invalid_url(e.to_string()))?;
        let mut connected = self.connected.write().await;
        *connected = true;
        Ok(())
    }

    async fn disconnect(&mut self) -> Result<()> {
        let mut connected = self.connected.write().await;
        *connected = false;
        Ok(())
    }

    async fn send_request(&self, request: JsonRpcRequest) -> Result<JsonRpcResponse> {
        if !self.is_connected() {
            return Err(Error::NotInitialized);
        }

        let mut headers = build_headers(&self.auth);
        inject_oauth_token(&self.auth, &self.client, &mut headers).await?;
        {
            let sid = self.session_id.read().await;
            inject_session_id(&sid, &mut headers);
        }

        let response = self
            .client
            .post(&self.url)
            .headers(headers)
            .json(&request)
            .send()
            .await?;

        if let Some(rl_err) = check_rate_limit(&response) {
            return Err(rl_err);
        }

        // On 401, invalidate the cached OAuth token and retry once.
        if response.status() == StatusCode::UNAUTHORIZED {
            if let AuthConfig::ClientCredentials(provider) = &self.auth {
                provider.invalidate().await;
                let mut retry_headers = build_headers(&self.auth);
                inject_oauth_token(&self.auth, &self.client, &mut retry_headers).await?;
                {
                    let sid = self.session_id.read().await;
                    inject_session_id(&sid, &mut retry_headers);
                }
                let retry_resp = self
                    .client
                    .post(&self.url)
                    .headers(retry_headers)
                    .json(&request)
                    .send()
                    .await?;
                if let Some(rl_err) = check_rate_limit(&retry_resp) {
                    return Err(rl_err);
                }
                if !retry_resp.status().is_success() {
                    return Err(Error::Auth("OAuth token rejected after refresh".into()));
                }
                capture_session_id(&retry_resp, &self.session_id).await;
                let json_resp = parse_response(retry_resp).await?;
                if let Some(error) = json_resp.error {
                    return Err(Error::server(error.code, error.message, error.data));
                }
                return Ok(json_resp);
            }
        }

        capture_session_id(&response, &self.session_id).await;

        if response.status() == StatusCode::ACCEPTED {
            return Ok(accepted_response(&request));
        }

        if !response.status().is_success() {
            return Err(Error::network(format!(
                "HTTP {} error",
                response.status()
            )));
        }

        let json_response = parse_response(response).await?;

        if let Some(error) = json_response.error {
            return Err(Error::server(error.code, error.message, error.data));
        }

        Ok(json_response)
    }

    fn is_connected(&self) -> bool {
        if let Ok(connected) = self.connected.try_read() {
            *connected
        } else {
            false
        }
    }
}
