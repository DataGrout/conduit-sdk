//! OAuth 2.1 **authorization code + PKCE** — browser-consent sign-in.
//!
//! The `client_credentials` grant in [`crate::oauth`] authenticates a *machine*:
//! it needs a client secret that was issued out of band. This module
//! authenticates a *person*: the app opens a browser, the user consents at the
//! gateway, and the app receives a grant bound to that user's account. It is
//! what a desktop or CLI application needs, and the only way to use
//! `https://gateway.datagrout.ai/connect`, where the server binding is chosen
//! at consent time and lives in the token rather than the URL.
//!
//! # Flow
//!
//! 1. [`AuthCodeFlow::discover`] — fetch protected-resource metadata, then the
//!    authorization server's metadata.
//! 2. [`AuthCodeFlow::register`] — RFC 7591 dynamic client registration, as a
//!    **public client** (no secret; PKCE takes its place).
//! 3. [`AuthCodeFlow::authorize_url`] — build the consent URL and hold the PKCE
//!    verifier and CSRF state in a [`PendingAuthorization`].
//! 4. The caller opens that URL and captures the redirect. With the
//!    `authcode-loopback` feature, [`loopback`] does the capturing.
//! 5. [`AuthCodeFlow::exchange`] — trade the code for a [`Grant`].
//!
//! ```rust,no_run
//! use datagrout_conduit::authcode::AuthCodeFlow;
//! use datagrout_conduit::ClientBuilder;
//!
//! # #[tokio::main]
//! # async fn main() -> Result<(), Box<dyn std::error::Error>> {
//! let mut flow = AuthCodeFlow::discover("https://gateway.datagrout.ai/connect").await?;
//! flow.register("My App", "http://127.0.0.1:8765/callback").await?;
//!
//! let (url, pending) = flow.authorize_url()?;
//! println!("Open: {url}");
//!
//! # let (code, state) = (String::new(), String::new());
//! let grant = flow.exchange(pending, &code, &state).await?;
//!
//! let client = ClientBuilder::new()
//!     .url("https://gateway.datagrout.ai/connect")
//!     .auth_authorization_code(grant)
//!     .build()?;
//! # Ok(()) }
//! ```
//!
//! # Persisting the grant
//!
//! This module owns the [`Grant`] shape and its refresh logic; it deliberately
//! does **not** choose where a grant is stored. That is the application's
//! decision — an OS keychain, a config file, a vault — and baking a filesystem
//! opinion into an SDK makes it wrong for half its callers.
//!
//! [`Grant::expires_at`] is Unix seconds rather than a monotonic instant
//! precisely so a grant survives serialization: it is written by one process
//! and read by another, possibly in a different language.

use std::time::{SystemTime, UNIX_EPOCH};

use base64::{engine::general_purpose, Engine as _};
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use tokio::sync::RwLock;

use crate::error::{Error, Result};

#[cfg(feature = "authcode-loopback")]
pub mod loopback;

/// Scopes requested when the caller does not specify.
///
/// Matches the authorization server's own registration default rather than
/// inventing a finer-grained vocabulary: DataGrout splits the scope string on
/// whitespace and stores what it is given, so a made-up scope is accepted
/// silently and then means nothing.
pub const DEFAULT_SCOPE: &str = "mcp tools";

/// Refresh this many seconds before the token actually expires.
const REFRESH_SKEW_SECS: u64 = 60;

// ---------------------------------------------------------------------------
// Errors
// ---------------------------------------------------------------------------

/// Errors from the authorization-code flow.
///
/// The taxonomy is part of the cross-language contract: every conduit SDK
/// distinguishes these same cases, so callers can branch identically.
#[derive(Debug, thiserror::Error)]
pub enum AuthCodeError {
    /// Metadata discovery failed or returned something unusable.
    #[error("OAuth discovery failed: {0}")]
    Discovery(String),

    /// The authorization server does not advertise dynamic client registration.
    #[error("authorization server has no registration endpoint — register a client manually and use AuthCodeFlow::with_client_id")]
    NoRegistrationEndpoint,

    /// Dynamic client registration was rejected.
    #[error("client registration rejected (HTTP {status}): {body}")]
    RegistrationRejected {
        /// HTTP status code.
        status: u16,
        /// Response body.
        body: String,
    },

    /// `authorize_url` was called before a client id was known.
    #[error("no client_id — call register() or with_client_id() first")]
    NoClientId,

    /// The server does not support PKCE with S256.
    ///
    /// Downgrading to `plain`, or to no PKCE at all, would defeat the point of
    /// the flow for a public client, so this is refused rather than negotiated.
    #[error("authorization server does not support PKCE S256; refusing to downgrade")]
    PkceUnsupported,

    /// The `state` returned by the redirect did not match the one sent.
    ///
    /// A CSRF signal: the response belongs to a different authorization
    /// request. Never proceed past this.
    #[error("state mismatch — the authorization response does not match this request")]
    StateMismatch,

    /// The token endpoint rejected the exchange or refresh.
    #[error("token exchange failed (HTTP {status}): {body}")]
    TokenExchange {
        /// HTTP status code.
        status: u16,
        /// Response body.
        body: String,
    },

    /// The grant has no refresh token, so it cannot be renewed.
    #[error("grant has expired and carries no refresh_token — re-authorize")]
    NotRefreshable,

    /// The authorization server returned an error at the redirect.
    #[error("authorization denied: {error}{}", .description.as_deref().map(|d| format!(" — {d}")).unwrap_or_default())]
    Denied {
        /// OAuth error code, e.g. `access_denied`.
        error: String,
        /// Human-readable description, when provided.
        description: Option<String>,
    },

    /// Transport failure talking to the authorization server.
    #[error("HTTP error: {0}")]
    Http(String),
}

impl From<AuthCodeError> for Error {
    fn from(e: AuthCodeError) -> Self {
        Error::Auth(e.to_string())
    }
}

// ---------------------------------------------------------------------------
// Metadata
// ---------------------------------------------------------------------------

/// RFC 8414 authorization server metadata (the fields this flow uses).
#[derive(Debug, Clone, Deserialize)]
pub struct AuthServerMetadata {
    /// Issuer identifier.
    #[serde(default)]
    pub issuer: String,
    /// Where the user is sent to consent.
    pub authorization_endpoint: String,
    /// Where codes and refresh tokens are exchanged.
    pub token_endpoint: String,
    /// RFC 7591 dynamic client registration endpoint, when offered.
    #[serde(default)]
    pub registration_endpoint: Option<String>,
    /// PKCE methods, e.g. `["S256"]`.
    #[serde(default)]
    pub code_challenge_methods_supported: Vec<String>,
    /// Supported grant types.
    #[serde(default)]
    pub grant_types_supported: Vec<String>,
    /// Supported scopes.
    #[serde(default)]
    pub scopes_supported: Vec<String>,
}

impl AuthServerMetadata {
    fn supports_s256(&self) -> bool {
        // An empty list means the server did not advertise. RFC 8414 makes the
        // field optional, and DataGrout omits it on some paths, so absence is
        // treated as "assume S256" rather than as a refusal — a server that
        // truly cannot do S256 will reject the authorize request anyway.
        self.code_challenge_methods_supported.is_empty()
            || self
                .code_challenge_methods_supported
                .iter()
                .any(|m| m.eq_ignore_ascii_case("S256"))
    }
}

/// RFC 9728 protected-resource metadata.
#[derive(Debug, Clone, Deserialize)]
struct ProtectedResourceMetadata {
    #[serde(default)]
    authorization_servers: Vec<String>,
}

// ---------------------------------------------------------------------------
// Grant
// ---------------------------------------------------------------------------

/// A dynamically-registered client: the id **and** the redirect URI it is
/// bound to.
///
/// These travel together because an authorization server matches the redirect
/// URI **exactly** against the value registered — there is no loopback-port
/// exemption to rely on. Persisting the id alone means a later re-authorization
/// on a freshly-chosen port is rejected as `invalid_redirect_uri`, and the
/// failure only shows up once the first grant can no longer be refreshed.
///
/// Persist this next to the [`Grant`] and restore it with
/// [`AuthCodeFlow::with_registered_client`].
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct RegisteredClient {
    /// The issued client id.
    pub client_id: String,
    /// The exact redirect URI registered for it.
    pub redirect_uri: String,
}

/// A user's authorization, ready to persist.
///
/// The serialized shape is part of the cross-language contract: a grant written
/// by one conduit SDK must be readable by another. Field names and types are
/// therefore fixed, and `expires_at` is Unix seconds — never a monotonic clock
/// value, which is meaningless once written to disk.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Grant {
    /// The bearer token.
    pub access_token: String,
    /// Refresh token, when the server issued one.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub refresh_token: Option<String>,
    /// Absolute expiry, Unix seconds. `None` means the server did not say.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub expires_at: Option<u64>,
    /// The client id this grant belongs to — needed to refresh it.
    pub client_id: String,
    /// Token endpoint that issued it — needed to refresh it.
    pub token_endpoint: String,
    /// Granted scopes, as returned by the server.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub scope: Option<String>,
    /// The resource this grant is bound to (RFC 8707).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub resource: Option<String>,
}

impl Grant {
    /// True when the access token is expired, or within the refresh skew of it.
    ///
    /// A grant with no stated expiry is treated as live: the server chose not
    /// to say, and guessing an expiry would throw away working tokens.
    pub fn is_expired(&self) -> bool {
        match self.expires_at {
            None => false,
            Some(at) => now_secs() + REFRESH_SKEW_SECS >= at,
        }
    }

    /// Whether this grant can renew itself without user interaction.
    pub fn is_refreshable(&self) -> bool {
        self.refresh_token.is_some()
    }

    /// Exchange the refresh token for a fresh grant.
    ///
    /// Returns a new `Grant`; the old one should be discarded. DataGrout
    /// rotates refresh tokens, so keeping the previous grant around and using
    /// it again can invalidate the whole family.
    pub async fn refresh(
        &self,
        http: &reqwest::Client,
    ) -> std::result::Result<Grant, AuthCodeError> {
        let refresh_token = self
            .refresh_token
            .as_deref()
            .ok_or(AuthCodeError::NotRefreshable)?;

        let mut form = vec![
            ("grant_type", "refresh_token"),
            ("refresh_token", refresh_token),
            ("client_id", self.client_id.as_str()),
        ];
        if let Some(resource) = &self.resource {
            form.push(("resource", resource.as_str()));
        }

        let token: TokenResponse = post_form(http, &self.token_endpoint, &form).await?;

        Ok(Grant {
            access_token: token.access_token,
            // A server that does not rotate returns no new refresh token; keep
            // the existing one rather than silently making the grant
            // unrefreshable from here on.
            refresh_token: token.refresh_token.or_else(|| self.refresh_token.clone()),
            expires_at: token.expires_in.map(|s| now_secs() + s),
            client_id: self.client_id.clone(),
            token_endpoint: self.token_endpoint.clone(),
            scope: token.scope.or_else(|| self.scope.clone()),
            resource: self.resource.clone(),
        })
    }
}

#[derive(Debug, Deserialize)]
struct TokenResponse {
    access_token: String,
    #[serde(default)]
    refresh_token: Option<String>,
    #[serde(default)]
    expires_in: Option<u64>,
    #[serde(default)]
    scope: Option<String>,
}

// ---------------------------------------------------------------------------
// Pending authorization
// ---------------------------------------------------------------------------

/// The secrets held between building the consent URL and redeeming the code.
///
/// Not `Clone`: [`AuthCodeFlow::exchange`] consumes it, so a verifier cannot be
/// replayed against a second code.
#[derive(Debug)]
pub struct PendingAuthorization {
    code_verifier: String,
    state: String,
    redirect_uri: String,
}

impl PendingAuthorization {
    /// The CSRF state sent to the authorization server.
    ///
    /// Compare it against the `state` on the redirect before redeeming — or let
    /// [`AuthCodeFlow::exchange`] do it, which is the safer default.
    pub fn state(&self) -> &str {
        &self.state
    }

    /// The redirect URI this authorization was bound to.
    pub fn redirect_uri(&self) -> &str {
        &self.redirect_uri
    }
}

// ---------------------------------------------------------------------------
// The flow
// ---------------------------------------------------------------------------

/// Drives discovery, registration, consent, and exchange.
pub struct AuthCodeFlow {
    http: reqwest::Client,
    metadata: AuthServerMetadata,
    /// The protected resource this grant will be bound to (RFC 8707).
    resource: String,
    client_id: Option<String>,
    redirect_uri: Option<String>,
    scope: String,
}

impl AuthCodeFlow {
    /// Discover the authorization server protecting `resource_url`.
    ///
    /// `resource_url` is the MCP endpoint being connected to — for DataGrout,
    /// `https://gateway.datagrout.ai/connect` or a
    /// `.../servers/{uuid}/mcp` URL.
    ///
    /// Tries RFC 9728 protected-resource metadata first, then RFC 8414
    /// authorization-server metadata on whatever that names. Falls back to the
    /// resource's own origin, which is where DataGrout serves it.
    pub async fn discover(resource_url: &str) -> std::result::Result<Self, AuthCodeError> {
        Self::discover_with(reqwest::Client::new(), resource_url).await
    }

    /// [`discover`](Self::discover) with a caller-supplied HTTP client.
    pub async fn discover_with(
        http: reqwest::Client,
        resource_url: &str,
    ) -> std::result::Result<Self, AuthCodeError> {
        let resource = resource_url.trim_end_matches('/').to_string();

        let issuer = match fetch_resource_metadata(&http, &resource).await {
            Some(prm) if !prm.authorization_servers.is_empty() => {
                prm.authorization_servers[0].clone()
            }
            // No PRM, or it named no servers: DataGrout serves AS metadata at
            // the origin, so try there before giving up.
            _ => origin_of(&resource)
                .ok_or_else(|| AuthCodeError::Discovery(format!("not a URL: {resource}")))?,
        };

        let metadata = fetch_as_metadata(&http, &issuer).await?;

        if !metadata.supports_s256() {
            return Err(AuthCodeError::PkceUnsupported);
        }

        Ok(Self {
            http,
            metadata,
            resource,
            client_id: None,
            redirect_uri: None,
            scope: DEFAULT_SCOPE.to_string(),
        })
    }

    /// Use a client id registered out of band, skipping dynamic registration.
    pub fn with_client_id(
        mut self,
        client_id: impl Into<String>,
        redirect_uri: impl Into<String>,
    ) -> Self {
        self.client_id = Some(client_id.into());
        self.redirect_uri = Some(redirect_uri.into());
        self
    }

    /// Request scopes other than [`DEFAULT_SCOPE`].
    pub fn with_scope(mut self, scope: impl Into<String>) -> Self {
        self.scope = scope.into();
        self
    }

    /// The discovered metadata.
    pub fn metadata(&self) -> &AuthServerMetadata {
        &self.metadata
    }

    /// The client id, once registered or supplied.
    pub fn client_id(&self) -> Option<&str> {
        self.client_id.as_deref()
    }

    /// The redirect URI this flow is bound to.
    pub fn redirect_uri(&self) -> Option<&str> {
        self.redirect_uri.as_deref()
    }

    /// Reuse a client registered on a previous run.
    ///
    /// Prefer this over [`with_client_id`](Self::with_client_id): it carries
    /// the redirect URI with the id, which is not optional bookkeeping — an
    /// authorization server matches the redirect URI **exactly** against what
    /// was registered, so a client id reused with a different URI is rejected.
    pub fn with_registered_client(self, client: RegisteredClient) -> Self {
        self.with_client_id(client.client_id, client.redirect_uri)
    }

    /// Register this application via RFC 7591 dynamic client registration.
    ///
    /// Registers a **public client** — `token_endpoint_auth_method: "none"`,
    /// no secret issued. A desktop or CLI application cannot keep a secret, and
    /// PKCE is what stands in for one.
    ///
    /// Returns a [`RegisteredClient`]: the id **and** the redirect URI it is
    /// bound to. Persist the pair and restore it with
    /// [`with_registered_client`](Self::with_registered_client) — re-registering
    /// on every launch creates a new client record each time, and reusing an id
    /// against a different redirect URI is rejected.
    pub async fn register(
        &mut self,
        client_name: impl Into<String>,
        redirect_uri: impl Into<String>,
    ) -> std::result::Result<RegisteredClient, AuthCodeError> {
        let client_name = client_name.into();
        let redirect_uri = redirect_uri.into();

        let endpoint = self
            .metadata
            .registration_endpoint
            .clone()
            .ok_or(AuthCodeError::NoRegistrationEndpoint)?;

        let body = serde_json::json!({
            "client_name": client_name,
            "redirect_uris": [redirect_uri],
            "grant_types": ["authorization_code", "refresh_token"],
            "response_types": ["code"],
            "token_endpoint_auth_method": "none",
            "application_type": "native",
        });

        let resp = self
            .http
            .post(&endpoint)
            .json(&body)
            .send()
            .await
            .map_err(|e| AuthCodeError::Http(e.to_string()))?;

        let status = resp.status();
        if !status.is_success() {
            let body = resp.text().await.unwrap_or_default();
            return Err(AuthCodeError::RegistrationRejected {
                status: status.as_u16(),
                body,
            });
        }

        #[derive(Deserialize)]
        struct RegistrationResponse {
            client_id: String,
        }

        let reg: RegistrationResponse = resp
            .json()
            .await
            .map_err(|e| AuthCodeError::Http(format!("bad registration response: {e}")))?;

        self.client_id = Some(reg.client_id.clone());
        self.redirect_uri = Some(redirect_uri.clone());

        Ok(RegisteredClient {
            client_id: reg.client_id,
            redirect_uri,
        })
    }

    /// Build the consent URL, plus the [`PendingAuthorization`] needed to
    /// redeem the resulting code.
    ///
    /// The caller opens the URL however suits it — a browser, a printed
    /// instruction, a QR code. This crate does not launch browsers.
    pub fn authorize_url(
        &self,
    ) -> std::result::Result<(String, PendingAuthorization), AuthCodeError> {
        let client_id = self.client_id.as_deref().ok_or(AuthCodeError::NoClientId)?;
        let redirect_uri = self
            .redirect_uri
            .as_deref()
            .ok_or(AuthCodeError::NoClientId)?;

        let code_verifier = generate_verifier();
        let code_challenge = challenge_s256(&code_verifier);
        let state = generate_state();

        let query = [
            ("response_type", "code"),
            ("client_id", client_id),
            ("redirect_uri", redirect_uri),
            ("scope", self.scope.as_str()),
            ("state", state.as_str()),
            ("code_challenge", code_challenge.as_str()),
            ("code_challenge_method", "S256"),
            // RFC 8707: bind the token to this resource so it cannot be
            // replayed against a different one.
            ("resource", self.resource.as_str()),
        ]
        .iter()
        .map(|(k, v)| format!("{}={}", k, urlencode(v)))
        .collect::<Vec<_>>()
        .join("&");

        let separator = if self.metadata.authorization_endpoint.contains('?') {
            '&'
        } else {
            '?'
        };
        let url = format!(
            "{}{}{}",
            self.metadata.authorization_endpoint, separator, query
        );

        Ok((
            url,
            PendingAuthorization {
                code_verifier,
                state,
                redirect_uri: redirect_uri.to_string(),
            },
        ))
    }

    /// Redeem an authorization code for a [`Grant`].
    ///
    /// `returned_state` is the `state` parameter from the redirect. It is
    /// checked against the pending request before anything is sent: a mismatch
    /// means the response belongs to a different authorization request, and the
    /// exchange is refused rather than attempted.
    pub async fn exchange(
        &self,
        pending: PendingAuthorization,
        code: &str,
        returned_state: &str,
    ) -> std::result::Result<Grant, AuthCodeError> {
        if !constant_time_eq(pending.state.as_bytes(), returned_state.as_bytes()) {
            return Err(AuthCodeError::StateMismatch);
        }

        let client_id = self.client_id.as_deref().ok_or(AuthCodeError::NoClientId)?;

        let form = vec![
            ("grant_type", "authorization_code"),
            ("code", code),
            ("redirect_uri", pending.redirect_uri.as_str()),
            ("client_id", client_id),
            ("code_verifier", pending.code_verifier.as_str()),
            ("resource", self.resource.as_str()),
        ];

        let token: TokenResponse =
            post_form(&self.http, &self.metadata.token_endpoint, &form).await?;

        Ok(Grant {
            access_token: token.access_token,
            refresh_token: token.refresh_token,
            expires_at: token.expires_in.map(|s| now_secs() + s),
            client_id: client_id.to_string(),
            token_endpoint: self.metadata.token_endpoint.clone(),
            scope: token.scope,
            resource: Some(self.resource.clone()),
        })
    }
}

// ---------------------------------------------------------------------------
// Provider
// ---------------------------------------------------------------------------

/// Holds a [`Grant`] and keeps its access token fresh.
///
/// Mirrors [`crate::oauth::OAuthTokenProvider`] so both grant types reach the
/// transports through the same path — `get_token` on the way out, `invalidate`
/// on a 401.
#[derive(Clone)]
pub struct AuthCodeProvider {
    grant: std::sync::Arc<RwLock<Grant>>,
    /// Set when a refresh produced a new grant, so the application can persist
    /// it. Rotating refresh tokens make this important: a stored grant that is
    /// never updated goes stale and eventually invalidates the family.
    dirty: std::sync::Arc<std::sync::atomic::AtomicBool>,
    /// Serializes refreshes so concurrent callers make one request rather than
    /// a stampede. Deliberately separate from `grant`: this one is held across
    /// the network call, that one never is.
    refreshing: std::sync::Arc<tokio::sync::Mutex<()>>,
    /// The settled outcome of the most recent refresh attempt, so a caller that
    /// queued behind a failing one can take its result instead of launching
    /// another against an endpoint just seen to fail.
    outcome: std::sync::Arc<std::sync::Mutex<RefreshOutcome>>,
}

/// Bookkeeping for the last settled refresh. Never held across an `.await`.
#[derive(Debug, Default)]
struct RefreshOutcome {
    /// Bumped once per settled attempt, success or failure.
    attempt: u64,
    /// The failure message of the attempt that just settled, if it failed.
    last_error: Option<String>,
}

impl std::fmt::Debug for AuthCodeProvider {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        // Never print the tokens.
        f.debug_struct("AuthCodeProvider").finish_non_exhaustive()
    }
}

impl AuthCodeProvider {
    /// Wrap a grant.
    pub fn new(grant: Grant) -> Self {
        Self {
            grant: std::sync::Arc::new(RwLock::new(grant)),
            dirty: std::sync::Arc::new(std::sync::atomic::AtomicBool::new(false)),
            refreshing: std::sync::Arc::new(tokio::sync::Mutex::new(())),
            outcome: std::sync::Arc::new(std::sync::Mutex::new(RefreshOutcome::default())),
        }
    }

    /// The current access token, refreshing first if it is at or near expiry.
    pub async fn get_token(&self, http: &reqwest::Client) -> Result<String> {
        {
            let guard = self.grant.read().await;
            if !guard.is_expired() {
                return Ok(guard.access_token.clone());
            }
        }

        // Which attempt was current before we queued. If a different one
        // settles while we wait, its outcome is ours too.
        let seen = self.attempt();

        // One refresh at a time. Waiters re-check on entry, so a leader that
        // succeeded spares them the request entirely.
        let _refreshing = self.refreshing.lock().await;

        let stale = {
            let guard = self.grant.read().await;
            if !guard.is_expired() {
                return Ok(guard.access_token.clone());
            }
            guard.clone()
        };

        {
            // An attempt settled while we queued and left the grant expired, so
            // it failed. Share that rather than hammering an endpoint we have
            // just watched fail — a dead one should cost one request, not one
            // per waiter.
            let outcome = self.outcome_lock();
            if outcome.attempt != seen {
                if let Some(message) = &outcome.last_error {
                    return Err(Error::Auth(message.clone()));
                }
            }
        }

        // The state lock is released across the request. Holding it here would
        // stall `grant()` and `take_if_dirty()` for the whole round trip — and
        // a persistence loop calling the latter is exactly the documented use.
        match stale.refresh(http).await {
            Ok(refreshed) => {
                let token = refreshed.access_token.clone();
                *self.grant.write().await = refreshed;
                self.dirty.store(true, std::sync::atomic::Ordering::Release);

                let mut outcome = self.outcome_lock();
                outcome.attempt += 1;
                outcome.last_error = None;
                drop(outcome);

                tracing::debug!("conduit: refreshed authorization-code grant");
                Ok(token)
            }
            Err(err) => {
                // Recorded as the message rather than the error, because
                // `Error` is not `Clone` and every waiter must see the same
                // thing the leader saw.
                let message = err.to_string();
                let mut outcome = self.outcome_lock();
                outcome.attempt += 1;
                outcome.last_error = Some(message.clone());
                drop(outcome);

                Err(Error::Auth(message))
            }
        }
    }

    fn attempt(&self) -> u64 {
        self.outcome_lock().attempt
    }

    /// Poison-tolerant: this guards two plain fields and is never held across
    /// an `.await`, so a poisoned lock still holds usable bookkeeping.
    fn outcome_lock(&self) -> std::sync::MutexGuard<'_, RefreshOutcome> {
        self.outcome
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
    }

    /// A snapshot of the current grant, for persisting.
    pub async fn grant(&self) -> Grant {
        self.grant.read().await.clone()
    }

    /// Whether the grant changed since the last [`take_if_dirty`](Self::take_if_dirty).
    pub fn is_dirty(&self) -> bool {
        self.dirty.load(std::sync::atomic::Ordering::Acquire)
    }

    /// Return the grant if it has changed since the last call, clearing the flag.
    ///
    /// The intended use is a persistence loop: call periodically and write
    /// whatever comes back, so a rotated refresh token is never lost.
    pub async fn take_if_dirty(&self) -> Option<Grant> {
        if self.dirty.swap(false, std::sync::atomic::Ordering::AcqRel) {
            Some(self.grant.read().await.clone())
        } else {
            None
        }
    }

    /// Force the next [`get_token`](Self::get_token) to refresh. Call on a 401.
    pub async fn invalidate(&self) {
        let mut guard = self.grant.write().await;
        // Expire in the past rather than clearing the token: the refresh token
        // is what matters, and dropping the grant would make recovery
        // impossible.
        guard.expires_at = Some(0);
    }
}

// ---------------------------------------------------------------------------
// PKCE and helpers
// ---------------------------------------------------------------------------

/// Generate an RFC 7636 code verifier: 43 characters of base64url.
///
/// Randomness comes from two v4 UUIDs (32 bytes) rather than a new `rand`
/// dependency — `uuid` is already required, and v4 is CSPRNG-backed.
pub fn generate_verifier() -> String {
    let mut bytes = Vec::with_capacity(32);
    bytes.extend_from_slice(uuid::Uuid::new_v4().as_bytes());
    bytes.extend_from_slice(uuid::Uuid::new_v4().as_bytes());
    general_purpose::URL_SAFE_NO_PAD.encode(bytes)
}

/// The S256 challenge for a verifier: `base64url(sha256(verifier))`.
pub fn challenge_s256(verifier: &str) -> String {
    let digest = Sha256::digest(verifier.as_bytes());
    general_purpose::URL_SAFE_NO_PAD.encode(digest)
}

fn generate_state() -> String {
    general_purpose::URL_SAFE_NO_PAD.encode(uuid::Uuid::new_v4().as_bytes())
}

fn now_secs() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_secs())
        .unwrap_or(0)
}

/// Length-independent comparison, so a state check cannot be timed.
fn constant_time_eq(a: &[u8], b: &[u8]) -> bool {
    if a.len() != b.len() {
        return false;
    }
    a.iter().zip(b).fold(0u8, |acc, (x, y)| acc | (x ^ y)) == 0
}

/// Percent-encode a query parameter value.
///
/// Unreserved set per RFC 3986. Everything else is escaped — including `/` and
/// `:`, which appear in redirect URIs and resource URLs and must not be taken
/// as structure by the authorization server.
fn urlencode(value: &str) -> String {
    let mut out = String::with_capacity(value.len());
    for byte in value.as_bytes() {
        match byte {
            b'A'..=b'Z' | b'a'..=b'z' | b'0'..=b'9' | b'-' | b'.' | b'_' | b'~' => {
                out.push(*byte as char)
            }
            _ => out.push_str(&format!("%{byte:02X}")),
        }
    }
    out
}

fn origin_of(url: &str) -> Option<String> {
    let parsed = url::Url::parse(url).ok()?;
    let host = parsed.host_str()?;
    let scheme = parsed.scheme();
    Some(match parsed.port() {
        Some(port) => format!("{scheme}://{host}:{port}"),
        None => format!("{scheme}://{host}"),
    })
}

async fn fetch_resource_metadata(
    http: &reqwest::Client,
    resource: &str,
) -> Option<ProtectedResourceMetadata> {
    // Path-appended form first (what MCP servers with a path segment use),
    // then the origin-level one.
    let candidates = [
        format!("{resource}/.well-known/oauth-protected-resource"),
        format!(
            "{}/.well-known/oauth-protected-resource",
            origin_of(resource)?
        ),
    ];

    for url in candidates {
        if let Ok(resp) = http.get(&url).send().await {
            if resp.status().is_success() {
                if let Ok(prm) = resp.json::<ProtectedResourceMetadata>().await {
                    return Some(prm);
                }
            }
        }
    }
    None
}

async fn fetch_as_metadata(
    http: &reqwest::Client,
    issuer: &str,
) -> std::result::Result<AuthServerMetadata, AuthCodeError> {
    let base = issuer.trim_end_matches('/');
    let candidates = [
        format!("{base}/.well-known/oauth-authorization-server"),
        format!("{base}/.well-known/openid-configuration"),
    ];

    let mut last = String::new();
    for url in &candidates {
        match http.get(url).send().await {
            Ok(resp) if resp.status().is_success() => {
                return resp
                    .json::<AuthServerMetadata>()
                    .await
                    .map_err(|e| AuthCodeError::Discovery(format!("bad metadata at {url}: {e}")));
            }
            Ok(resp) => last = format!("{url} → HTTP {}", resp.status()),
            Err(e) => last = format!("{url} → {e}"),
        }
    }

    Err(AuthCodeError::Discovery(format!(
        "no authorization server metadata found (last attempt: {last})"
    )))
}

async fn post_form(
    http: &reqwest::Client,
    endpoint: &str,
    form: &[(&str, &str)],
) -> std::result::Result<TokenResponse, AuthCodeError> {
    let resp = http
        .post(endpoint)
        .form(form)
        .send()
        .await
        .map_err(|e| AuthCodeError::Http(e.to_string()))?;

    let status = resp.status();
    if !status.is_success() {
        let body = resp.text().await.unwrap_or_default();
        return Err(AuthCodeError::TokenExchange {
            status: status.as_u16(),
            body,
        });
    }

    resp.json::<TokenResponse>()
        .await
        .map_err(|e| AuthCodeError::Http(format!("bad token response: {e}")))
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

#[cfg(test)]
mod tests {
    use super::*;

    fn metadata() -> AuthServerMetadata {
        AuthServerMetadata {
            issuer: "https://gateway.datagrout.ai".into(),
            authorization_endpoint: "https://gateway.datagrout.ai/oauth/authorize".into(),
            token_endpoint: "https://gateway.datagrout.ai/oauth/token".into(),
            registration_endpoint: Some("https://gateway.datagrout.ai/register".into()),
            code_challenge_methods_supported: vec!["S256".into()],
            grant_types_supported: vec!["authorization_code".into(), "refresh_token".into()],
            scopes_supported: vec![],
        }
    }

    fn flow() -> AuthCodeFlow {
        AuthCodeFlow {
            http: reqwest::Client::new(),
            metadata: metadata(),
            resource: "https://gateway.datagrout.ai/connect".into(),
            client_id: Some("client_abc".into()),
            redirect_uri: Some("http://127.0.0.1:8765/callback".into()),
            scope: DEFAULT_SCOPE.into(),
        }
    }

    // ─── PKCE ────────────────────────────────────────────────────────────

    #[test]
    fn verifier_meets_rfc7636_length_and_alphabet() {
        let v = generate_verifier();
        assert_eq!(v.len(), 43, "32 bytes of base64url is 43 chars");
        assert!(v.len() >= 43 && v.len() <= 128);
        assert!(
            v.chars()
                .all(|c| c.is_ascii_alphanumeric() || "-._~".contains(c)),
            "verifier must be unreserved characters only: {v}"
        );
    }

    #[test]
    fn verifiers_are_unique() {
        assert_ne!(generate_verifier(), generate_verifier());
    }

    #[test]
    fn challenge_matches_the_rfc7636_test_vector() {
        // RFC 7636 Appendix B.
        let verifier = "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk";
        assert_eq!(
            challenge_s256(verifier),
            "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM"
        );
    }

    #[test]
    fn challenge_is_unpadded_base64url() {
        let c = challenge_s256("anything");
        assert!(!c.contains('='), "must not be padded");
        assert!(!c.contains('+') && !c.contains('/'), "must be url-safe");
    }

    // ─── authorize URL ───────────────────────────────────────────────────

    #[test]
    fn authorize_url_carries_every_required_parameter() {
        let (url, pending) = flow().authorize_url().unwrap();

        assert!(url.starts_with("https://gateway.datagrout.ai/oauth/authorize?"));
        assert!(url.contains("response_type=code"));
        assert!(url.contains("client_id=client_abc"));
        assert!(url.contains("code_challenge_method=S256"));
        assert!(url.contains(&format!("state={}", urlencode(pending.state()))));
        // The challenge travels; the verifier never does.
        assert!(url.contains(&format!(
            "code_challenge={}",
            challenge_s256(&pending.code_verifier)
        )));
        assert!(
            !url.contains(&pending.code_verifier),
            "the verifier must never appear in the authorization URL"
        );
    }

    #[test]
    fn authorize_url_percent_encodes_redirect_and_resource() {
        let (url, _) = flow().authorize_url().unwrap();
        assert!(url.contains("redirect_uri=http%3A%2F%2F127.0.0.1%3A8765%2Fcallback"));
        assert!(url.contains("resource=https%3A%2F%2Fgateway.datagrout.ai%2Fconnect"));
    }

    #[test]
    fn authorize_url_binds_the_token_to_the_resource() {
        // RFC 8707 — without this a token could be replayed at another server.
        let (url, _) = flow().authorize_url().unwrap();
        assert!(url.contains("resource="));
    }

    #[test]
    fn authorize_url_requires_a_client_id() {
        let mut f = flow();
        f.client_id = None;
        assert!(matches!(f.authorize_url(), Err(AuthCodeError::NoClientId)));
    }

    #[test]
    fn authorize_url_appends_when_the_endpoint_already_has_a_query() {
        let mut f = flow();
        f.metadata.authorization_endpoint = "https://example.com/authorize?foo=1".into();
        let (url, _) = f.authorize_url().unwrap();
        assert!(url.contains("/authorize?foo=1&response_type=code"));
    }

    // ─── state / CSRF ────────────────────────────────────────────────────

    #[tokio::test]
    async fn exchange_refuses_a_mismatched_state() {
        let f = flow();
        let (_, pending) = f.authorize_url().unwrap();

        let err = f
            .exchange(pending, "the_code", "not_the_state")
            .await
            .unwrap_err();

        assert!(matches!(err, AuthCodeError::StateMismatch));
    }

    #[tokio::test]
    async fn exchange_refuses_an_empty_state() {
        let f = flow();
        let (_, pending) = f.authorize_url().unwrap();
        assert!(matches!(
            f.exchange(pending, "code", "").await.unwrap_err(),
            AuthCodeError::StateMismatch
        ));
    }

    #[test]
    fn constant_time_eq_is_correct() {
        assert!(constant_time_eq(b"abc", b"abc"));
        assert!(!constant_time_eq(b"abc", b"abd"));
        assert!(!constant_time_eq(b"abc", b"ab"));
        assert!(constant_time_eq(b"", b""));
    }

    // ─── Grant ───────────────────────────────────────────────────────────

    fn grant(expires_at: Option<u64>, refresh: Option<&str>) -> Grant {
        Grant {
            access_token: "at".into(),
            refresh_token: refresh.map(str::to_string),
            expires_at,
            client_id: "client_abc".into(),
            token_endpoint: "https://gateway.datagrout.ai/oauth/token".into(),
            scope: None,
            resource: None,
        }
    }

    #[test]
    fn a_grant_with_no_stated_expiry_is_not_expired() {
        assert!(!grant(None, None).is_expired());
    }

    #[test]
    fn a_grant_expires_early_by_the_refresh_skew() {
        // Expires in 30s, skew is 60s → already due for refresh.
        assert!(grant(Some(now_secs() + 30), Some("rt")).is_expired());
        assert!(!grant(Some(now_secs() + 600), Some("rt")).is_expired());
    }

    #[tokio::test]
    async fn refreshing_without_a_refresh_token_is_a_typed_error() {
        let err = grant(Some(0), None)
            .refresh(&reqwest::Client::new())
            .await
            .unwrap_err();
        assert!(matches!(err, AuthCodeError::NotRefreshable));
    }

    #[test]
    fn grant_round_trips_through_json_with_stable_field_names() {
        // The serialized shape is a cross-language contract — a grant written
        // by one SDK must be readable by another.
        let g = grant(Some(1_800_000_000), Some("rt"));
        let json = serde_json::to_value(&g).unwrap();

        assert_eq!(json["access_token"], "at");
        assert_eq!(json["refresh_token"], "rt");
        assert_eq!(json["expires_at"], 1_800_000_000u64);
        assert_eq!(json["client_id"], "client_abc");
        assert!(json["token_endpoint"].is_string());

        let back: Grant = serde_json::from_value(json).unwrap();
        assert_eq!(back.access_token, g.access_token);
        assert_eq!(back.expires_at, g.expires_at);
    }

    #[test]
    fn grant_deserializes_a_minimal_payload() {
        let json = serde_json::json!({
            "access_token": "at",
            "client_id": "c",
            "token_endpoint": "https://example.com/token"
        });
        let g: Grant = serde_json::from_value(json).unwrap();
        assert!(g.refresh_token.is_none());
        assert!(!g.is_expired());
        assert!(!g.is_refreshable());
    }

    #[test]
    fn grant_omits_absent_optionals_when_serialized() {
        let json = serde_json::to_value(grant(None, None)).unwrap();
        assert!(json.get("refresh_token").is_none());
        assert!(json.get("expires_at").is_none());
    }

    // ─── provider ────────────────────────────────────────────────────────

    #[tokio::test]
    async fn provider_returns_a_live_token_without_refreshing() {
        let p = AuthCodeProvider::new(grant(Some(now_secs() + 3600), Some("rt")));
        assert_eq!(p.get_token(&reqwest::Client::new()).await.unwrap(), "at");
        assert!(!p.is_dirty());
    }

    #[tokio::test]
    async fn provider_invalidate_forces_the_next_fetch_to_refresh() {
        let p = AuthCodeProvider::new(grant(Some(now_secs() + 3600), None));
        p.invalidate().await;
        // No refresh token, so the forced refresh surfaces as NotRefreshable
        // rather than silently returning the stale token.
        assert!(p.get_token(&reqwest::Client::new()).await.is_err());
    }

    #[tokio::test]
    async fn take_if_dirty_is_empty_until_something_changes() {
        let p = AuthCodeProvider::new(grant(Some(now_secs() + 3600), Some("rt")));
        assert!(p.take_if_dirty().await.is_none());
    }

    #[tokio::test]
    async fn provider_state_stays_readable_while_a_refresh_is_in_flight() {
        // A token endpoint that accepts the connection and never answers, so
        // the refresh is reliably still in flight when we probe the state.
        let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
        let addr = listener.local_addr().unwrap();
        tokio::spawn(async move {
            let mut open = Vec::new();
            while let Ok((socket, _)) = listener.accept().await {
                open.push(socket);
            }
        });

        let mut stale = grant(Some(0), Some("rt"));
        stale.token_endpoint = format!("http://{addr}/oauth/token");

        let provider = AuthCodeProvider::new(stale);
        let refreshing = provider.clone();
        tokio::spawn(async move {
            let _ = refreshing.get_token(&reqwest::Client::new()).await;
        });

        // Let the request reach the socket.
        tokio::time::sleep(std::time::Duration::from_millis(150)).await;

        // Held across the request, the state lock would block both of these
        // until the HTTP timeout — and a persistence loop calling
        // `take_if_dirty` is the documented use.
        let read = tokio::time::timeout(std::time::Duration::from_millis(500), async {
            let g = provider.grant().await;
            let taken = provider.take_if_dirty().await;
            (g, taken)
        })
        .await;

        let (g, taken) = read.expect("state blocked while a refresh was in flight");
        assert_eq!(g.access_token, "at");
        assert!(taken.is_none());
    }

    #[tokio::test]
    async fn provider_shares_a_failing_refresh_with_every_waiter() {
        use std::sync::atomic::AtomicUsize;
        use tokio::io::{AsyncReadExt, AsyncWriteExt};

        // A token endpoint that fails, slowly. The delay is what guarantees
        // the other callers are queued behind the leader rather than racing
        // it, so the count means what the test says it means.
        let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
        let addr = listener.local_addr().unwrap();
        let hits = std::sync::Arc::new(AtomicUsize::new(0));

        let counted = hits.clone();
        tokio::spawn(async move {
            while let Ok((mut socket, _)) = listener.accept().await {
                counted.fetch_add(1, std::sync::atomic::Ordering::SeqCst);
                tokio::spawn(async move {
                    let mut buf = [0u8; 2048];
                    let _ = socket.read(&mut buf).await;
                    tokio::time::sleep(std::time::Duration::from_millis(400)).await;
                    let _ = socket
                        .write_all(
                            b"HTTP/1.1 400 Bad Request\r\ncontent-length: 4\r\n\
                              connection: close\r\n\r\nnope",
                        )
                        .await;
                });
            }
        });

        let mut stale = grant(Some(0), Some("rt"));
        stale.token_endpoint = format!("http://{addr}/oauth/token");

        let provider = AuthCodeProvider::new(stale);
        let http = reqwest::Client::new();

        let waiters: Vec<_> = (0..5)
            .map(|_| {
                let p = provider.clone();
                let h = http.clone();
                tokio::spawn(async move { p.get_token(&h).await })
            })
            .collect();

        for waiter in waiters {
            assert!(waiter.await.unwrap().is_err(), "every waiter should fail");
        }

        // One request, not five: the leader's failure is shared.
        assert_eq!(hits.load(std::sync::atomic::Ordering::SeqCst), 1);
    }

    #[tokio::test]
    async fn provider_retries_on_a_later_call_rather_than_replaying_a_failure() {
        // The shared failure is only for callers that queued behind that
        // attempt. Once it has settled, the next call must try again.
        let mut server = mockito::Server::new_async().await;
        let failed = server
            .mock("POST", "/oauth/token")
            .with_status(400)
            .with_body("nope")
            .expect(1)
            .create_async()
            .await;

        let mut stale = grant(Some(0), Some("rt"));
        stale.token_endpoint = format!("{}/oauth/token", server.url());

        let provider = AuthCodeProvider::new(stale);
        let http = reqwest::Client::new();

        assert!(provider.get_token(&http).await.is_err());
        failed.assert_async().await;

        let ok = server
            .mock("POST", "/oauth/token")
            .with_status(200)
            .with_body(r#"{"access_token":"at_2","expires_in":3600}"#)
            .create_async()
            .await;

        assert_eq!(provider.get_token(&http).await.unwrap(), "at_2");
        ok.assert_async().await;
    }

    #[test]
    fn provider_debug_never_prints_tokens() {
        let p = AuthCodeProvider::new(grant(None, Some("super-secret-refresh")));
        let rendered = format!("{p:?}");
        assert!(!rendered.contains("super-secret-refresh"));
        assert!(!rendered.contains("at"));
    }

    // ─── metadata / discovery helpers ────────────────────────────────────

    #[test]
    fn s256_support_is_assumed_when_unadvertised() {
        let mut m = metadata();
        m.code_challenge_methods_supported = vec![];
        assert!(m.supports_s256());
    }

    #[test]
    fn a_server_advertising_only_plain_is_refused() {
        let mut m = metadata();
        m.code_challenge_methods_supported = vec!["plain".into()];
        assert!(!m.supports_s256());
    }

    #[test]
    fn origin_strips_paths_and_keeps_ports() {
        assert_eq!(
            origin_of("https://gateway.datagrout.ai/connect").as_deref(),
            Some("https://gateway.datagrout.ai")
        );
        assert_eq!(
            origin_of("http://localhost:4000/servers/abc/mcp").as_deref(),
            Some("http://localhost:4000")
        );
        assert_eq!(origin_of("not a url"), None);
    }

    #[test]
    fn metadata_parses_a_datagrout_style_document() {
        let json = serde_json::json!({
            "issuer": "https://gateway.datagrout.ai",
            "authorization_endpoint": "https://gateway.datagrout.ai/oauth/authorize",
            "token_endpoint": "https://gateway.datagrout.ai/oauth/token",
            "registration_endpoint": "https://gateway.datagrout.ai/register",
            "response_types_supported": ["code"],
            "grant_types_supported": ["authorization_code", "client_credentials", "refresh_token"],
            "code_challenge_methods_supported": ["S256"]
        });
        let m: AuthServerMetadata = serde_json::from_value(json).unwrap();
        assert!(m.supports_s256());
        assert_eq!(
            m.registration_endpoint.as_deref(),
            Some("https://gateway.datagrout.ai/register")
        );
    }

    #[test]
    fn metadata_tolerates_a_missing_registration_endpoint() {
        let json = serde_json::json!({
            "authorization_endpoint": "https://e.com/a",
            "token_endpoint": "https://e.com/t"
        });
        let m: AuthServerMetadata = serde_json::from_value(json).unwrap();
        assert!(m.registration_endpoint.is_none());
    }

    #[test]
    fn urlencode_escapes_structure_characters() {
        assert_eq!(urlencode("a b"), "a%20b");
        assert_eq!(urlencode("http://x/y"), "http%3A%2F%2Fx%2Fy");
        assert_eq!(urlencode("safe-._~"), "safe-._~");
    }

    #[test]
    fn default_scope_matches_the_servers_own_vocabulary() {
        // Inventing finer-grained scopes is worse than useless here: the
        // server splits on whitespace and stores what it is handed, so a
        // made-up scope is accepted silently and then means nothing.
        assert_eq!(DEFAULT_SCOPE, "mcp tools");
    }

    #[test]
    fn registered_client_round_trips_and_keeps_the_pair_together() {
        let client = RegisteredClient {
            client_id: "client_abc".into(),
            redirect_uri: "http://127.0.0.1:8765/callback".into(),
        };
        let json = serde_json::to_value(&client).unwrap();
        assert_eq!(json["client_id"], "client_abc");
        assert_eq!(json["redirect_uri"], "http://127.0.0.1:8765/callback");

        let back: RegisteredClient = serde_json::from_value(json).unwrap();
        assert_eq!(back.redirect_uri, client.redirect_uri);
    }

    #[test]
    fn restoring_a_registered_client_restores_both_halves() {
        // Reusing a client id against a different redirect URI is rejected by
        // the authorization server, so the pair must survive together.
        let mut f = flow();
        f.client_id = None;
        f.redirect_uri = None;

        let f = f.with_registered_client(RegisteredClient {
            client_id: "saved_id".into(),
            redirect_uri: "http://127.0.0.1:9999/cb".into(),
        });

        assert_eq!(f.client_id(), Some("saved_id"));
        assert_eq!(f.redirect_uri(), Some("http://127.0.0.1:9999/cb"));

        let (url, _) = f.authorize_url().unwrap();
        assert!(url.contains("client_id=saved_id"));
        assert!(url.contains("redirect_uri=http%3A%2F%2F127.0.0.1%3A9999%2Fcb"));
    }

    #[test]
    fn authcode_error_converts_into_the_crate_error() {
        let e: Error = AuthCodeError::NoClientId.into();
        assert!(matches!(e, Error::Auth(_)));
    }

    // ---------------------------------------------------------------------
    // Cross-language contract
    //
    // Every test above round-trips a grant through this crate's own serde
    // impls, which passes even if a field name is wrong — as long as it is
    // consistently wrong. These load `testdata/contract.json`, the same bytes
    // every language SDK checks, so a grant written here is provably readable
    // elsewhere. See `testdata/README.md`.
    //
    // `error_kinds` is not checked here: `AuthCodeError` is a `thiserror` enum
    // with no string form, and giving it one would mean new public API. Python
    // and TypeScript enumerate theirs and cover that row.
    // ---------------------------------------------------------------------

    fn contract() -> serde_json::Value {
        serde_json::from_str(include_str!(concat!(
            env!("CARGO_MANIFEST_DIR"),
            "/../testdata/contract.json"
        )))
        .expect("testdata/contract.json is not valid JSON")
    }

    #[test]
    fn contract_fixture_grant_loads_field_for_field() {
        // Read explicitly rather than by round-trip: a misnamed field would
        // fail to deserialize or land as None, and a round-trip alone would
        // not say which.
        let grant: Grant = serde_json::from_value(contract()["grant"].clone()).unwrap();

        assert_eq!(grant.access_token, "at_contract_fixture");
        assert_eq!(grant.refresh_token.as_deref(), Some("rt_contract_fixture"));
        assert_eq!(grant.expires_at, Some(1_700_000_000));
        assert_eq!(grant.client_id, "client_contract_fixture");
        assert_eq!(
            grant.token_endpoint,
            "https://gateway.example.com/oauth/token"
        );
        assert_eq!(grant.scope.as_deref(), Some("mcp tools"));
        assert_eq!(
            grant.resource.as_deref(),
            Some("https://gateway.example.com/connect")
        );
    }

    #[test]
    fn contract_fixture_grant_serializes_identically() {
        let expected = contract()["grant"].clone();
        let grant: Grant = serde_json::from_value(expected.clone()).unwrap();
        assert_eq!(serde_json::to_value(&grant).unwrap(), expected);
    }

    #[test]
    fn contract_fixture_minimal_grant_omits_absent_optionals() {
        let expected = contract()["grant_minimal"].clone();
        let grant: Grant = serde_json::from_value(expected.clone()).unwrap();
        // Not `"refresh_token": null` — another SDK reading this must see
        // absence.
        assert_eq!(serde_json::to_value(&grant).unwrap(), expected);
    }

    #[test]
    fn contract_fixture_registered_client_round_trips_as_one_unit() {
        let expected = contract()["registered_client"].clone();
        let client: RegisteredClient = serde_json::from_value(expected.clone()).unwrap();
        assert_eq!(serde_json::to_value(&client).unwrap(), expected);
    }

    #[test]
    fn contract_fixture_pins_the_default_scope() {
        assert_eq!(DEFAULT_SCOPE, contract()["default_scope"].as_str().unwrap());
    }
}
