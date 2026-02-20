//! OAuth 2.1 `client_credentials` token provider.
//!
//! Handles fetching and caching short-lived JWT tokens from the DataGrout
//! machine-client token endpoint so that application code never has to
//! think about token lifecycle.
//!
//! # Usage
//!
//! ```rust,no_run
//! use datagrout_conduit::{ClientBuilder, Transport};
//!
//! # #[tokio::main]
//! # async fn main() -> Result<(), Box<dyn std::error::Error>> {
//! let client = ClientBuilder::new()
//!     .url("https://app.datagrout.ai/servers/{uuid}/mcp")
//!     .auth_client_credentials(
//!         "my_client_id",
//!         "my_client_secret",
//!     )
//!     .build()?;
//!
//! client.connect().await?;
//! # Ok(())
//! # }
//! ```

use crate::error::{Error, Result};
use serde::Deserialize;
use std::time::{Duration, Instant};
use tokio::sync::RwLock;

// ─── Token response from DataGrout ───────────────────────────────────────────

#[derive(Debug, Deserialize)]
struct TokenResponse {
    access_token: String,
    token_type: String,
    expires_in: Option<u64>,
    scope: Option<String>,
}

// ─── Cached token ─────────────────────────────────────────────────────────────

struct CachedToken {
    access_token: String,
    expires_at: Instant,
}

// ─── Provider ─────────────────────────────────────────────────────────────────

/// Lazily fetches and caches OAuth 2.1 `client_credentials` tokens.
///
/// Thread-safe and cheaply cloneable (`Arc`-backed).
#[derive(Clone)]
pub struct OAuthTokenProvider {
    client_id: String,
    client_secret: String,
    token_endpoint: String,
    scope: Option<String>,
    cached: std::sync::Arc<RwLock<Option<CachedToken>>>,
}

impl std::fmt::Debug for OAuthTokenProvider {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("OAuthTokenProvider")
            .field("client_id", &self.client_id)
            .field("token_endpoint", &self.token_endpoint)
            .finish_non_exhaustive()
    }
}

impl OAuthTokenProvider {
    /// Create a new provider.
    ///
    /// `token_endpoint` is the full URL, e.g.
    /// `https://app.datagrout.ai/servers/{uuid}/oauth/token`.
    pub fn new(
        client_id: impl Into<String>,
        client_secret: impl Into<String>,
        token_endpoint: impl Into<String>,
        scope: Option<String>,
    ) -> Self {
        Self {
            client_id: client_id.into(),
            client_secret: client_secret.into(),
            token_endpoint: token_endpoint.into(),
            scope,
            cached: std::sync::Arc::new(RwLock::new(None)),
        }
    }

    /// Derive the token endpoint from a DataGrout MCP URL.
    ///
    /// Strips `/mcp` and replaces it with `/oauth/token`.  Works for both
    /// `…/servers/{uuid}/mcp` and `…/servers/{uuid}/mcp/anything` paths.
    ///
    /// Example:
    ///
    /// ```text
    /// https://app.datagrout.ai/servers/abc/mcp  →  https://app.datagrout.ai/servers/abc/oauth/token
    /// ```
    pub fn derive_token_endpoint(mcp_url: &str) -> String {
        // Strip `/mcp` suffix (and anything after it).
        let base = if let Some(idx) = mcp_url.find("/mcp") {
            &mcp_url[..idx]
        } else {
            mcp_url.trim_end_matches('/')
        };

        format!("{}/oauth/token", base)
    }

    /// Return the current bearer token, fetching a fresh one if necessary.
    ///
    /// Refreshes proactively when the cached token has less than 60 seconds
    /// remaining.
    pub async fn get_token(&self, http_client: &reqwest::Client) -> Result<String> {
        // Fast path — check cache under a read lock.
        {
            let guard = self.cached.read().await;

            if let Some(cached) = &*guard {
                let remaining = cached.expires_at.checked_duration_since(Instant::now());
                if remaining.map(|r| r.as_secs() > 60).unwrap_or(false) {
                    return Ok(cached.access_token.clone());
                }
            }
        }

        // Slow path — fetch a new token under a write lock to prevent stampedes.
        let mut guard = self.cached.write().await;

        // Re-check after acquiring the write lock.
        if let Some(cached) = &*guard {
            let remaining = cached.expires_at.checked_duration_since(Instant::now());
            if remaining.map(|r| r.as_secs() > 60).unwrap_or(false) {
                return Ok(cached.access_token.clone());
            }
        }

        let token = self.fetch_token(http_client).await?;
        *guard = Some(token);
        Ok(guard.as_ref().unwrap().access_token.clone())
    }

    /// Force-invalidate the cached token (call on receipt of a 401).
    pub async fn invalidate(&self) {
        let mut guard = self.cached.write().await;
        *guard = None;
    }

    // ─── Private ──────────────────────────────────────────────────────────

    async fn fetch_token(&self, http_client: &reqwest::Client) -> Result<CachedToken> {
        let mut form = vec![
            ("grant_type", "client_credentials"),
            ("client_id", &self.client_id),
            ("client_secret", &self.client_secret),
        ];

        let scope_str;
        if let Some(scope) = &self.scope {
            scope_str = scope.clone();
            form.push(("scope", &scope_str));
        }

        let resp = http_client
            .post(&self.token_endpoint)
            .form(&form)
            .send()
            .await
            .map_err(|e| Error::Connection(format!("OAuth token request failed: {e}")))?;

        let status = resp.status();

        if !status.is_success() {
            let body: String = resp.text().await.unwrap_or_default();
            return Err(Error::Auth(format!(
                "OAuth token endpoint returned {status}: {body}"
            )));
        }

        let token_resp: TokenResponse = resp.json().await.map_err(|e| {
            Error::Connection(format!("failed to parse OAuth token response: {e}"))
        })?;

        let expires_in = token_resp.expires_in.unwrap_or(3600);

        // Build the cached token with a 60-second buffer before the real expiry.
        let expires_at =
            Instant::now() + Duration::from_secs(expires_in.saturating_sub(60).max(30));

        tracing::debug!(
            "conduit: fetched OAuth token for client_id={} (expires_in={}s scope={:?})",
            self.client_id,
            expires_in,
            token_resp.scope
        );

        Ok(CachedToken {
            access_token: token_resp.access_token,
            expires_at,
        })
    }
}
