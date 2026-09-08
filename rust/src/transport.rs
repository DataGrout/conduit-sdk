//! Transport layer for MCP communication

use crate::error::{Error, RateLimit, Result};
use crate::identity::ConduitIdentity;
use crate::oauth::OAuthTokenProvider;
use crate::protocol::{JsonRpcRequest, JsonRpcResponse};
use crate::ws_transport::Subscription;
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
    /// JSON-RPC 2.0 over WebSocket (`datagrout-jsonrpc.v1` subprotocol).
    ///
    /// Bidirectional; supports server-pushed notifications via
    /// `subscribe`/`unsubscribe` topic methods. Recommended for any client
    /// that wants real-time agent / tool / governor events without
    /// polling. See [`crate::ws_transport`] for protocol details.
    Ws,
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

    /// OAuth 2.1 **authorization code + PKCE** grant — a user's browser
    /// consent, rather than a machine credential.
    ///
    /// Behaves like [`ClientCredentials`](Self::ClientCredentials) from the
    /// transport's point of view: the token is fetched asynchronously per
    /// request and refreshed (via the refresh token) before it expires.
    #[cfg(feature = "authcode")]
    AuthorizationCode(crate::authcode::AuthCodeProvider),
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

    /// Subscribe to a server-push topic.
    ///
    /// Returns a [`Subscription`] whose `events` receiver fires every time
    /// the server pushes a notification matching the topic.
    ///
    /// Only implemented on the WS transport; other transports return
    /// `Err(Error::Network("subscribe requires WS transport"))`.
    async fn subscribe(&self, _topic: String) -> Result<Subscription> {
        Err(Error::Network(
            "subscribe is only supported on the WS transport".into(),
        ))
    }

    /// Cancel a subscription by id.
    ///
    /// Only implemented on the WS transport.
    async fn unsubscribe(&self, _subscription_id: String) -> Result<()> {
        Err(Error::Network(
            "unsubscribe is only supported on the WS transport".into(),
        ))
    }
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
            tracing::warn!("conduit: mTLS certificate expires within 30 days — consider rotating");
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
            if let Ok(value) = header::HeaderValue::from_str(&format!("Basic {}", credentials)) {
                headers.insert(header::AUTHORIZATION, value);
            }
        }
        // Token is fetched asynchronously and injected in send_request.
        AuthConfig::ClientCredentials(_) | AuthConfig::None => {}
        #[cfg(feature = "authcode")]
        AuthConfig::AuthorizationCode(_) => {}
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

/// Invalidate a cached OAuth token so the next request fetches a fresh one.
///
/// Returns whether this auth mode has a token worth retrying with — the 401
/// retry path is only worth taking when a refresh could plausibly change the
/// outcome. A static bearer or API key is rejected for a reason retrying will
/// not fix.
async fn invalidate_oauth(auth: &AuthConfig) -> bool {
    match auth {
        AuthConfig::ClientCredentials(provider) => {
            provider.invalidate().await;
            true
        }
        #[cfg(feature = "authcode")]
        AuthConfig::AuthorizationCode(provider) => {
            provider.invalidate().await;
            true
        }
        _ => false,
    }
}

/// Inject an asynchronously-resolved OAuth bearer token into an existing header
/// map.  A no-op for auth modes whose header is built synchronously.
///
/// This is the single place a token provider becomes an `Authorization` header,
/// which is why adding a grant type touches so little: implement `get_token`
/// and add an arm here.
async fn inject_oauth_token(
    auth: &AuthConfig,
    http_client: &HttpClient,
    headers: &mut header::HeaderMap,
) -> Result<()> {
    let token = match auth {
        AuthConfig::ClientCredentials(provider) => Some(provider.get_token(http_client).await?),
        #[cfg(feature = "authcode")]
        AuthConfig::AuthorizationCode(provider) => Some(provider.get_token(http_client).await?),
        _ => None,
    };

    if let Some(token) = token {
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

    Some(Error::RateLimit {
        retry_after,
        used,
        limit,
    })
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
        if response.status() == StatusCode::UNAUTHORIZED && invalidate_oauth(&self.auth).await {
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

        capture_session_id(&response, &self.session_id).await;

        if response.status() == StatusCode::ACCEPTED {
            return Ok(accepted_response(&request));
        }

        if !response.status().is_success() {
            return Err(Error::network(format!("HTTP {} error", response.status())));
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
        if response.status() == StatusCode::UNAUTHORIZED && invalidate_oauth(&self.auth).await {
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

        capture_session_id(&response, &self.session_id).await;

        if response.status() == StatusCode::ACCEPTED {
            return Ok(accepted_response(&request));
        }

        if !response.status().is_success() {
            return Err(Error::network(format!("HTTP {} error", response.status())));
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

#[cfg(test)]
mod tests {
    use super::*;

    // This module had no tests at all, so the 401-retry path — the one place a
    // provider-backed grant gets a second chance — was never exercised in Rust,
    // for either grant. The other four SDKs grew transport-level auth tests when
    // the authorization-code grant landed; this closes the gap in the reference.

    fn unix_secs() -> u64 {
        std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .map(|d| d.as_secs())
            .unwrap_or(0)
    }

    #[cfg(feature = "authcode")]
    fn grant(expires_at: u64, token_endpoint: &str) -> crate::authcode::Grant {
        crate::authcode::Grant {
            access_token: "user_access_token".into(),
            refresh_token: Some("rt".into()),
            expires_at: Some(expires_at),
            client_id: "client_abc".into(),
            token_endpoint: token_endpoint.into(),
            scope: None,
            resource: None,
        }
    }

    fn request() -> JsonRpcRequest {
        JsonRpcRequest {
            jsonrpc: "2.0".into(),
            id: Some("1".into()),
            method: "tools/list".into(),
            params: None,
        }
    }

    fn header_value(headers: &header::HeaderMap, name: header::HeaderName) -> Option<String> {
        headers
            .get(name)
            .and_then(|v| v.to_str().ok())
            .map(str::to_string)
    }

    // ─── inject_oauth_token ──────────────────────────────────────────────

    #[cfg(feature = "authcode")]
    #[tokio::test]
    async fn inject_oauth_token_sets_a_bearer_for_an_authorization_code_grant() {
        let provider = crate::authcode::AuthCodeProvider::new(grant(
            unix_secs() + 3600,
            "https://gateway.example.com/oauth/token",
        ));
        let auth = AuthConfig::AuthorizationCode(provider);

        let mut headers = header::HeaderMap::new();
        inject_oauth_token(&auth, &HttpClient::new(), &mut headers)
            .await
            .unwrap();

        assert_eq!(
            header_value(&headers, header::AUTHORIZATION).as_deref(),
            Some("Bearer user_access_token")
        );
    }

    #[tokio::test]
    async fn inject_oauth_token_is_a_no_op_for_synchronous_auth() {
        // These build their header in `build_headers`; there is nothing to
        // fetch, and injecting an empty bearer would overwrite it.
        for auth in [
            AuthConfig::None,
            AuthConfig::Bearer("static".into()),
            AuthConfig::ApiKey("k".into()),
        ] {
            let mut headers = header::HeaderMap::new();
            inject_oauth_token(&auth, &HttpClient::new(), &mut headers)
                .await
                .unwrap();
            assert!(headers.get(header::AUTHORIZATION).is_none());
        }
    }

    // ─── invalidate_oauth ────────────────────────────────────────────────

    #[tokio::test]
    async fn invalidate_oauth_reports_whether_a_retry_could_help() {
        // The 401 retry is only worth taking when a refresh could change the
        // outcome. A static credential was rejected for a reason retrying will
        // not fix.
        assert!(!invalidate_oauth(&AuthConfig::None).await);
        assert!(!invalidate_oauth(&AuthConfig::Bearer("static".into())).await);
        assert!(!invalidate_oauth(&AuthConfig::ApiKey("k".into())).await);

        let provider = OAuthTokenProvider::new(
            "id",
            "secret",
            "https://gateway.example.com/oauth/token",
            None,
        );
        assert!(invalidate_oauth(&AuthConfig::ClientCredentials(provider)).await);
    }

    #[cfg(feature = "authcode")]
    #[tokio::test]
    async fn invalidate_oauth_covers_the_authorization_code_grant_too() {
        let provider = crate::authcode::AuthCodeProvider::new(grant(
            unix_secs() + 3600,
            "https://gateway.example.com/oauth/token",
        ));
        assert!(invalidate_oauth(&AuthConfig::AuthorizationCode(provider)).await);
    }

    // ─── the 401 retry ───────────────────────────────────────────────────

    #[cfg(feature = "authcode")]
    #[tokio::test]
    async fn a_401_refreshes_an_authorization_code_grant_and_retries_once() {
        let mut server = mockito::Server::new_async().await;

        // Matching on the bearer is what makes this deterministic: the first
        // attempt carries the stale token, the retry must carry the fresh one.
        let stale = server
            .mock("POST", "/mcp")
            .match_header("authorization", "Bearer user_access_token")
            .with_status(401)
            .with_body("unauthorized")
            .expect(1)
            .create_async()
            .await;

        let refreshed = server
            .mock("POST", "/mcp")
            .match_header("authorization", "Bearer refreshed")
            .with_status(200)
            .with_header("content-type", "application/json")
            .with_body(r#"{"jsonrpc":"2.0","id":"1","result":{"ok":true}}"#)
            .expect(1)
            .create_async()
            .await;

        let token = server
            .mock("POST", "/oauth/token")
            .with_status(200)
            .with_body(r#"{"access_token":"refreshed","token_type":"Bearer","expires_in":3600}"#)
            .expect(1)
            .create_async()
            .await;

        // Live by the clock: an already-expired grant would be refreshed
        // before the first request and never earn a 401. The case the retry
        // path exists for is a token rotated or revoked server-side.
        let provider = crate::authcode::AuthCodeProvider::new(grant(
            unix_secs() + 3600,
            &format!("{}/oauth/token", server.url()),
        ));

        let mut transport = McpTransport::new(
            format!("{}/mcp", server.url()),
            AuthConfig::AuthorizationCode(provider),
        )
        .unwrap();
        transport.connect().await.unwrap();

        let response = transport.send_request(request()).await.unwrap();
        assert_eq!(response.result.unwrap()["ok"], serde_json::json!(true));

        // One stale attempt, one refresh, one retry — and no third attempt.
        stale.assert_async().await;
        token.assert_async().await;
        refreshed.assert_async().await;
    }

    #[tokio::test]
    async fn a_401_on_a_static_bearer_is_not_retried() {
        let mut server = mockito::Server::new_async().await;
        let rpc = server
            .mock("POST", "/mcp")
            .with_status(401)
            .with_body("unauthorized")
            .expect(1)
            .create_async()
            .await;

        let mut transport = McpTransport::new(
            format!("{}/mcp", server.url()),
            AuthConfig::Bearer("static".into()),
        )
        .unwrap();
        transport.connect().await.unwrap();

        // Nothing to refresh, so nothing to retry.
        assert!(transport.send_request(request()).await.is_err());
        rpc.assert_async().await;
    }

    #[cfg(feature = "authcode")]
    #[tokio::test]
    async fn a_401_that_survives_the_refresh_is_reported_as_an_auth_error() {
        let mut server = mockito::Server::new_async().await;
        let rpc = server
            .mock("POST", "/mcp")
            .with_status(401)
            .with_body("unauthorized")
            .expect(2)
            .create_async()
            .await;

        let _token = server
            .mock("POST", "/oauth/token")
            .with_status(200)
            .with_body(r#"{"access_token":"still_bad","token_type":"Bearer","expires_in":3600}"#)
            .create_async()
            .await;

        let provider = crate::authcode::AuthCodeProvider::new(grant(
            unix_secs() + 3600,
            &format!("{}/oauth/token", server.url()),
        ));

        let mut transport = JsonRpcTransport::new(
            format!("{}/mcp", server.url()),
            AuthConfig::AuthorizationCode(provider),
        )
        .unwrap();
        transport.connect().await.unwrap();

        let err = transport.send_request(request()).await.unwrap_err();
        assert!(matches!(err, Error::Auth(_)), "got {err:?}");
        // Exactly one retry: a revoked grant fails fast instead of recursing.
        rpc.assert_async().await;
    }
}
