//! Autonomous agent self-registration (onramp) for DataGrout.
//!
//! The onramp flow lets a machine intelligence register itself with DG
//! without a human in the loop, using only plain HTTP JSON — no MCP client
//! required. This matters because many agent harnesses gate or restrict MCP
//! connections but allow arbitrary HTTP requests.
//!
//! # Flow
//!
//! 1. POST to `/onramp` with agent identity metadata (no auth).
//! 2. DG returns a short-lived `session_token` (5 minutes).
//! 3. POST to `/onramp/complete` with `Authorization: Bearer <session_token>`.
//! 4. DG issues provisional `client_id` + `client_secret` (restricted scopes).
//!
//! The two-step handshake stops fire-and-forget scripts from bulk-registering
//! without completing the flow.
//!
//! The credentials returned by [`register_only`] can be passed directly to
//! [`ClientBuilder::bootstrap_identity_oauth`][crate::ClientBuilder::bootstrap_identity_oauth]
//! or the all-in-one
//! [`ClientBuilder::bootstrap_onramp`][crate::ClientBuilder::bootstrap_onramp].
//!
//! # Example
//!
//! ```rust,no_run
//! use datagrout_conduit::onramp::{register_only, OnrampOptions};
//! use datagrout_conduit::ClientBuilder;
//!
//! # #[tokio::main]
//! # async fn main() -> Result<(), Box<dyn std::error::Error>> {
//! // One-shot convenience — full onramp + mTLS bootstrap in a single call.
//! let client = ClientBuilder::new()
//!     .bootstrap_onramp(OnrampOptions {
//!         gateway: "https://app.datagrout.ai".into(),
//!         agent_name: "my-research-agent".into(),
//!         agent_type: Some("claude-sonnet-4-6".into()),
//!         intended_use: Some("Summarise documents and extract entities.".into()),
//!         access_code: None,
//!     })
//!     .await?
//!     .build()?;
//!
//! client.connect().await?;
//! # Ok(()) }
//! ```

use serde::{Deserialize, Serialize};

// ---------------------------------------------------------------------------
// Public types
// ---------------------------------------------------------------------------

/// Options for the autonomous agent onramp flow.
#[derive(Debug, Clone)]
pub struct OnrampOptions {
    /// DataGrout gateway base URL (e.g. `"https://app.datagrout.ai"`).
    pub gateway: String,
    /// Human-readable name for this agent instance.
    pub agent_name: String,
    /// Model or framework identifier (e.g. `"claude-sonnet-4-6"`, `"gpt-4o"`).
    pub agent_type: Option<String>,
    /// Plain-language description of what the agent intends to do.
    pub intended_use: Option<String>,
    /// Optional access code from the server owner — reserved for scope elevation.
    pub access_code: Option<String>,
}

/// Provisional credentials returned by the DG onramp complete endpoint.
///
/// Store `client_id` and `client_secret` securely — the secret is shown
/// exactly once and cannot be recovered after this point.
///
/// `mcp_url` and `rpc_url` are provisioned as part of the identity
/// registration step and may be absent from the initial onramp response.
/// Use [`ClientBuilder::bootstrap_onramp`][crate::ClientBuilder::bootstrap_onramp]
/// for the all-in-one flow that handles this transparently.
#[derive(Debug, Clone, Deserialize)]
pub struct OnrampCredentials {
    /// OAuth client ID.
    pub client_id: String,
    /// OAuth client secret. Store this securely — shown once.
    pub client_secret: String,
    /// Token endpoint for the `client_credentials` grant.
    pub token_url: String,
    /// JSON-RPC endpoint for tool calls.
    /// Absent until the agent's Substrate identity has been registered.
    #[serde(default)]
    pub rpc_url: Option<String>,
    /// MCP endpoint (for MCP-capable harnesses).
    /// Absent until the agent's Substrate identity has been registered.
    #[serde(default)]
    pub mcp_url: Option<String>,
    /// Granted OAuth scopes.
    pub scopes: Vec<String>,
    /// Provisional credential TTL in seconds.
    pub expires_in: u64,
}

// ---------------------------------------------------------------------------
// Errors
// ---------------------------------------------------------------------------

/// Errors from the onramp flow.
#[derive(Debug, thiserror::Error)]
pub enum OnrampError {
    /// HTTP transport error communicating with the DG gateway.
    #[error("HTTP error: {0}")]
    Http(String),
    /// The init step was rejected (rate limited or IP blocked).
    #[error("onramp init rejected (HTTP {status}): {body}")]
    InitRejected {
        /// HTTP status code.
        status: u16,
        /// Response body from the server.
        body: String,
    },
    /// The complete step was rejected (expired or already-used session token).
    #[error("onramp complete rejected (HTTP {status}): {body}")]
    CompleteRejected {
        /// HTTP status code.
        status: u16,
        /// Response body from the server.
        body: String,
    },
    /// The OAuth token exchange failed after onramp succeeded.
    #[error("token exchange failed (HTTP {status}): {body}")]
    TokenExchange {
        /// HTTP status code.
        status: u16,
        /// Response body from the server.
        body: String,
    },
}

// ---------------------------------------------------------------------------
// Internal types
// ---------------------------------------------------------------------------

#[derive(Serialize)]
struct InitRequest<'a> {
    agent_name: &'a str,
    #[serde(skip_serializing_if = "Option::is_none")]
    agent_type: Option<&'a str>,
    #[serde(skip_serializing_if = "Option::is_none")]
    intended_use: Option<&'a str>,
    #[serde(skip_serializing_if = "Option::is_none")]
    access_code: Option<&'a str>,
}

#[derive(Deserialize)]
struct InitResponse {
    session_token: String,
}

#[derive(Deserialize)]
struct TokenResponse {
    access_token: String,
}

// ---------------------------------------------------------------------------
// Public API
// ---------------------------------------------------------------------------

/// Perform the onramp handshake and return the provisional OAuth credentials.
///
/// This is the low-level entry point. Most callers should use
/// [`ClientBuilder::bootstrap_onramp`][crate::ClientBuilder::bootstrap_onramp]
/// instead, which chains onramp → token exchange → mTLS identity bootstrap in
/// a single builder call.
///
/// The returned [`OnrampCredentials`] contain the `client_id` and
/// `client_secret` needed for [`ClientBuilder::bootstrap_identity_oauth`][crate::ClientBuilder::bootstrap_identity_oauth].
pub async fn register_only(opts: &OnrampOptions) -> Result<OnrampCredentials, OnrampError> {
    let http = reqwest::Client::new();
    register(&http, opts).await
}

/// Perform the full onramp handshake and OAuth token exchange.
///
/// Returns the provisional credentials alongside a short-lived access token
/// ready for use with
/// [`ClientBuilder::bootstrap_identity`][crate::ClientBuilder::bootstrap_identity].
///
/// Useful when you want to persist credentials in a vault or inspect them
/// before building a client. For the all-in-one path use
/// [`ClientBuilder::bootstrap_onramp`][crate::ClientBuilder::bootstrap_onramp].
pub async fn register_and_exchange(
    opts: &OnrampOptions,
) -> Result<(OnrampCredentials, String), OnrampError> {
    let http = reqwest::Client::new();
    let creds = register(&http, opts).await?;
    let token = exchange_token(&http, &creds).await?;
    Ok((creds, token))
}

// ---------------------------------------------------------------------------
// Crate-internal helpers (used by ClientBuilder::bootstrap_onramp)
// ---------------------------------------------------------------------------

pub(crate) async fn register(
    http: &reqwest::Client,
    opts: &OnrampOptions,
) -> Result<OnrampCredentials, OnrampError> {
    let base = opts.gateway.trim_end_matches('/');

    let init_url = format!("{base}/onramp");
    let body = InitRequest {
        agent_name: &opts.agent_name,
        agent_type: opts.agent_type.as_deref(),
        intended_use: opts.intended_use.as_deref(),
        access_code: opts.access_code.as_deref(),
    };

    let resp = http
        .post(&init_url)
        .json(&body)
        .send()
        .await
        .map_err(|e| OnrampError::Http(e.to_string()))?;

    let status = resp.status();
    if !status.is_success() {
        let body = resp.text().await.unwrap_or_default();
        return Err(OnrampError::InitRejected {
            status: status.as_u16(),
            body,
        });
    }

    let init_resp = resp
        .json::<InitResponse>()
        .await
        .map_err(|e| OnrampError::Http(format!("failed to parse init response: {e}")))?;

    let complete_url = format!("{base}/onramp/complete");

    let resp = http
        .post(&complete_url)
        .header(
            "Authorization",
            format!("Bearer {}", init_resp.session_token),
        )
        .send()
        .await
        .map_err(|e| OnrampError::Http(format!("onramp complete request failed: {e}")))?;

    let status = resp.status();
    if !status.is_success() {
        let body = resp.text().await.unwrap_or_default();
        return Err(OnrampError::CompleteRejected {
            status: status.as_u16(),
            body,
        });
    }

    resp.json::<OnrampCredentials>()
        .await
        .map_err(|e| OnrampError::Http(format!("failed to parse complete response: {e}")))
}

pub(crate) async fn exchange_token(
    http: &reqwest::Client,
    creds: &OnrampCredentials,
) -> Result<String, OnrampError> {
    let resp = http
        .post(&creds.token_url)
        .form(&[
            ("grant_type", "client_credentials"),
            ("client_id", &creds.client_id),
            ("client_secret", &creds.client_secret),
        ])
        .send()
        .await
        .map_err(|e| OnrampError::Http(format!("token exchange request failed: {e}")))?;

    let status = resp.status();
    if !status.is_success() {
        let body = resp.text().await.unwrap_or_default();
        return Err(OnrampError::TokenExchange {
            status: status.as_u16(),
            body,
        });
    }

    let token_resp = resp
        .json::<TokenResponse>()
        .await
        .map_err(|e| OnrampError::Http(format!("failed to parse token response: {e}")))?;

    Ok(token_resp.access_token)
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn onramp_options_fields_accessible() {
        let opts = OnrampOptions {
            gateway: "https://app.datagrout.ai".into(),
            agent_name: "test-agent".into(),
            agent_type: Some("claude-sonnet-4-6".into()),
            intended_use: Some("testing".into()),
            access_code: None,
        };
        assert_eq!(opts.agent_name, "test-agent");
        assert_eq!(opts.agent_type.as_deref(), Some("claude-sonnet-4-6"));
        assert!(opts.access_code.is_none());
    }

    #[test]
    fn onramp_error_init_rejected_display() {
        let e = OnrampError::InitRejected {
            status: 429,
            body: "rate_limited".into(),
        };
        assert!(e.to_string().contains("429"));
        assert!(e.to_string().contains("rate_limited"));
    }

    #[test]
    fn onramp_error_complete_rejected_display() {
        let e = OnrampError::CompleteRejected {
            status: 410,
            body: "session token expired".into(),
        };
        assert!(e.to_string().contains("410"));
        assert!(e.to_string().contains("session token expired"));
    }

    #[test]
    fn onramp_error_token_exchange_display() {
        let e = OnrampError::TokenExchange {
            status: 401,
            body: "invalid_client".into(),
        };
        assert!(e.to_string().contains("401"));
        assert!(e.to_string().contains("invalid_client"));
    }

    #[test]
    fn onramp_credentials_deserializes_full_response() {
        let json = serde_json::json!({
            "client_id": "agt_abc123",
            "client_secret": "sk_xyz789",
            "token_url": "https://app.datagrout.ai/servers/abc/oauth/token",
            "rpc_url": "https://app.datagrout.ai/servers/abc/rpc",
            "mcp_url": "https://app.datagrout.ai/servers/abc/mcp",
            "scopes": ["mcp:read", "tools:call"],
            "expires_in": 2592000
        });
        let creds: OnrampCredentials = serde_json::from_value(json).unwrap();
        assert_eq!(creds.client_id, "agt_abc123");
        assert_eq!(creds.client_secret, "sk_xyz789");
        assert_eq!(
            creds.mcp_url.as_deref(),
            Some("https://app.datagrout.ai/servers/abc/mcp")
        );
        assert_eq!(
            creds.rpc_url.as_deref(),
            Some("https://app.datagrout.ai/servers/abc/rpc")
        );
        assert_eq!(creds.scopes, ["mcp:read", "tools:call"]);
        assert_eq!(creds.expires_in, 2592000);
    }

    #[test]
    fn onramp_credentials_deserializes_without_mcp_url() {
        // Server response before Substrate provisioning — mcp_url absent.
        let json = serde_json::json!({
            "client_id": "agt_abc123",
            "client_secret": "sk_xyz789",
            "token_url": "https://app.datagrout.ai/servers/abc/oauth/token",
            "scopes": ["mcp:read", "tools:call"],
            "expires_in": 2592000
        });
        let creds: OnrampCredentials = serde_json::from_value(json).unwrap();
        assert_eq!(creds.client_id, "agt_abc123");
        assert!(
            creds.mcp_url.is_none(),
            "mcp_url should be None when absent"
        );
        assert!(
            creds.rpc_url.is_none(),
            "rpc_url should be None when absent"
        );
    }

    #[test]
    fn init_request_skips_none_fields() {
        let req = InitRequest {
            agent_name: "my-agent",
            agent_type: None,
            intended_use: None,
            access_code: None,
        };
        let json = serde_json::to_value(&req).unwrap();
        assert_eq!(json["agent_name"], "my-agent");
        assert!(json.get("agent_type").is_none());
        assert!(json.get("intended_use").is_none());
        assert!(json.get("access_code").is_none());
    }

    #[test]
    fn init_request_includes_present_fields() {
        let req = InitRequest {
            agent_name: "my-agent",
            agent_type: Some("claude-sonnet-4-6"),
            intended_use: Some("testing"),
            access_code: Some("code123"),
        };
        let json = serde_json::to_value(&req).unwrap();
        assert_eq!(json["agent_type"], "claude-sonnet-4-6");
        assert_eq!(json["intended_use"], "testing");
        assert_eq!(json["access_code"], "code123");
    }
}
