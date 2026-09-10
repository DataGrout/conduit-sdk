//! RFC 8693 **token exchange** — delegation, so an agent acts *for* a user.
//!
//! The two grants this crate already speaks each answer one question.
//! [`crate::oauth`] (`client_credentials`) says *which machine* is calling;
//! [`crate::authcode`] says *which person* consented. Neither says both, and an
//! agent working on a user's behalf needs to: the resource server has to know
//! whose data it is (`sub`) and who is actually holding the connection
//! (`act`). RFC 8693 token exchange produces exactly that token, from two the
//! caller already has.
//!
//! # Delegation, not impersonation
//!
//! RFC 8693 distinguishes the two. In **delegation** the issued token names the
//! user as `sub` and the agent in an `act` claim, so the resource server can
//! see — and audit, and rate-limit, and revoke — the agent separately from the
//! user. In **impersonation** the agent simply *becomes* the user, and the
//! resource server cannot tell the difference. DataGrout's authorization
//! server issues delegation tokens and requires an `actor_token`; this module
//! therefore **requires an actor by default** and refuses to build a request
//! without one. Impersonation is an explicit opt-in via
//! [`DelegationRequest::impersonation`], for RFC 8693 servers that support it.
//!
//! # Wire contract
//!
//! `POST {token_endpoint}`, form-encoded:
//!
//! | field | value |
//! |---|---|
//! | `grant_type` | `urn:ietf:params:oauth:grant-type:token-exchange` |
//! | `subject_token`, `subject_token_type` | the user's token and its [`TokenType`] URN |
//! | `actor_token`, `actor_token_type` | the agent's token and URN — omitted only under `impersonation()` |
//! | `client_id`, `client_secret?` | client authentication, in the body by default (see [`ClientAuth`]) |
//! | `audience?`, `resource?`, `scope?`, `requested_token_type?` | as set |
//!
//! `resource` is RFC 8707 and, when set, is always sent — the same invariant
//! the authorization-code module keeps, so a delegated token cannot be
//! replayed against a different resource.
//!
//! **The client must be the actor.** The `client_id` authenticating the request
//! and the principal behind `actor_token` are expected to be the same agent.
//! This SDK does not verify that — it cannot, without decoding the actor
//! token — and the server enforces it (`unauthorized_client` when they differ).
//!
//! The response is `{access_token, issued_token_type, token_type, expires_in?,
//! scope?}`; errors are RFC 6749 bodies `{error, error_description?}`, with the
//! codes listed in [`codes`].
//!
//! # Usage
//!
//! ```rust,no_run
//! use datagrout_conduit::delegation::{DelegatedProvider, DelegationRequest, TokenSource, TokenType};
//! use datagrout_conduit::{ClientBuilder, OAuthTokenProvider};
//!
//! # #[tokio::main]
//! # async fn main() -> Result<(), Box<dyn std::error::Error>> {
//! // The agent's own credential — the actor.
//! let agent = OAuthTokenProvider::new(
//!     "agent_client_id",
//!     "agent_client_secret",
//!     "https://gateway.datagrout.ai/oauth/token",
//!     None,
//! );
//!
//! // The user's token — the subject. Here a token handed to the agent; a
//! // long-lived app would use `TokenSource::authorization_code(provider)`.
//! # let user_token = String::new();
//! let user = TokenSource::static_token(user_token, TokenType::AccessToken);
//!
//! let request = DelegationRequest::new(
//!     "https://gateway.datagrout.ai/oauth/token",
//!     "agent_client_id",
//! )
//! .client_secret("agent_client_secret")
//! .resource("https://gateway.datagrout.ai/connect");
//!
//! let provider = DelegatedProvider::new(request, user, Some(TokenSource::client_credentials(agent)));
//!
//! let client = ClientBuilder::new()
//!     .url("https://gateway.datagrout.ai/connect")
//!     .auth_delegation(provider)
//!     .build()?;
//! client.connect().await?;
//! # Ok(()) }
//! ```
//!
//! # Naming
//!
//! Elsewhere in this crate "token exchange" already means redeeming a
//! `client_credentials` grant (`Error::Onramp { stage: "token_exchange" }`,
//! `AuthCodeError::TokenExchange`). This module says *delegation* and
//! *exchange* — `DelegationRequest::exchange`, `DelegatedToken` — and never
//! reuses that label, so a log line cannot be read two ways.

use std::future::Future;
use std::pin::Pin;
use std::sync::Arc;
use std::time::{SystemTime, UNIX_EPOCH};

use base64::{engine::general_purpose, Engine as _};
use serde::{Deserialize, Serialize};
use tokio::sync::RwLock;

use crate::error::{Error, Result};
use crate::oauth::OAuthTokenProvider;

/// The RFC 8693 grant type.
pub const GRANT_TYPE: &str = "urn:ietf:params:oauth:grant-type:token-exchange";

/// Re-exchange this many seconds before the delegated token actually expires.
///
/// The same buffer [`crate::oauth`] and [`crate::authcode`] use, so all three
/// providers behave alike under a clock skew.
const REFRESH_SKEW_SECS: u64 = 60;

/// RFC 6749 error codes a token-exchange endpoint returns, as
/// [`DelegationError::Server::error`].
///
/// Listed so callers and ports compare against a name rather than a string
/// they typed. `invalid_target` is the one specific to RFC 8693: the
/// `audience` or `resource` is not one this server issues tokens for.
pub mod codes {
    /// Malformed request, or a required parameter missing.
    pub const INVALID_REQUEST: &str = "invalid_request";
    /// Client authentication failed.
    pub const INVALID_CLIENT: &str = "invalid_client";
    /// The subject or actor token is invalid, expired, or revoked.
    pub const INVALID_GRANT: &str = "invalid_grant";
    /// This client may not use this grant — including a client that is not the actor.
    pub const UNAUTHORIZED_CLIENT: &str = "unauthorized_client";
    /// The requested `audience` or `resource` is not served here (RFC 8693 §2.2.2).
    pub const INVALID_TARGET: &str = "invalid_target";
    /// A requested scope is unknown or exceeds what the subject token allows.
    pub const INVALID_SCOPE: &str = "invalid_scope";
    /// The server does not support token exchange.
    pub const UNSUPPORTED_GRANT_TYPE: &str = "unsupported_grant_type";

    /// Every code, for the contract test.
    pub const ALL: [&str; 7] = [
        INVALID_REQUEST,
        INVALID_CLIENT,
        INVALID_GRANT,
        UNAUTHORIZED_CLIENT,
        INVALID_TARGET,
        INVALID_SCOPE,
        UNSUPPORTED_GRANT_TYPE,
    ];
}

// ---------------------------------------------------------------------------
// Token types
// ---------------------------------------------------------------------------

/// An RFC 8693 §3 token type identifier.
///
/// Serializes as its URN, so the wire shape is the same string in every
/// language; a URN this crate does not name round-trips through
/// [`Other`](Self::Other) rather than failing.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(into = "String", from = "String")]
pub enum TokenType {
    /// `urn:ietf:params:oauth:token-type:access_token` — the default for both
    /// subject and actor, and what DataGrout issues.
    AccessToken,
    /// `urn:ietf:params:oauth:token-type:jwt` — a JWT presented as a JWT
    /// rather than as an opaque access token.
    Jwt,
    /// `urn:ietf:params:oauth:token-type:id_token`.
    IdToken,
    /// `urn:ietf:params:oauth:token-type:refresh_token`.
    RefreshToken,
    /// `urn:ietf:params:oauth:token-type:saml2`.
    Saml2,
    /// A URN this crate does not name.
    Other(String),
}

impl TokenType {
    const ACCESS_TOKEN: &'static str = "urn:ietf:params:oauth:token-type:access_token";
    const JWT: &'static str = "urn:ietf:params:oauth:token-type:jwt";
    const ID_TOKEN: &'static str = "urn:ietf:params:oauth:token-type:id_token";
    const REFRESH_TOKEN: &'static str = "urn:ietf:params:oauth:token-type:refresh_token";
    const SAML2: &'static str = "urn:ietf:params:oauth:token-type:saml2";

    /// The URN sent on the wire.
    pub fn as_urn(&self) -> &str {
        match self {
            Self::AccessToken => Self::ACCESS_TOKEN,
            Self::Jwt => Self::JWT,
            Self::IdToken => Self::ID_TOKEN,
            Self::RefreshToken => Self::REFRESH_TOKEN,
            Self::Saml2 => Self::SAML2,
            Self::Other(urn) => urn,
        }
    }

    /// Parse a URN. Unknown values become [`Other`](Self::Other).
    pub fn from_urn(urn: &str) -> Self {
        match urn {
            Self::ACCESS_TOKEN => Self::AccessToken,
            Self::JWT => Self::Jwt,
            Self::ID_TOKEN => Self::IdToken,
            Self::REFRESH_TOKEN => Self::RefreshToken,
            Self::SAML2 => Self::Saml2,
            other => Self::Other(other.to_string()),
        }
    }
}

impl std::fmt::Display for TokenType {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str(self.as_urn())
    }
}

impl From<TokenType> for String {
    fn from(t: TokenType) -> Self {
        t.as_urn().to_string()
    }
}

impl From<String> for TokenType {
    fn from(s: String) -> Self {
        Self::from_urn(&s)
    }
}

// ---------------------------------------------------------------------------
// Errors
// ---------------------------------------------------------------------------

/// Errors from a token exchange.
///
/// The taxonomy is part of the cross-language contract: every conduit SDK
/// distinguishes these same cases under the same [`kind`](Self::kind) names.
#[derive(Debug, thiserror::Error)]
pub enum DelegationError {
    /// No subject token was set — there is nobody to act for.
    #[error("no subject_token — call DelegationRequest::subject_token first")]
    MissingSubject,

    /// No actor token was set and the request is not an impersonation.
    ///
    /// Delegation is the default because it is what DataGrout requires and
    /// what leaves an audit trail. If the server really is meant to issue a
    /// token with no `act` claim, say so with
    /// [`DelegationRequest::impersonation`].
    #[error(
        "no actor_token — delegation requires one; call impersonation() to opt out explicitly"
    )]
    MissingActor,

    /// Transport failure talking to the token endpoint.
    #[error("HTTP error: {0}")]
    Http(String),

    /// The token endpoint refused, with an RFC 6749 error body.
    #[error("token exchange refused (HTTP {status}): {error}{}", .error_description.as_deref().map(|d| format!(" — {d}")).unwrap_or_default())]
    Server {
        /// HTTP status code.
        status: u16,
        /// RFC 6749 error code; see [`codes`].
        error: String,
        /// Human-readable description, when the server gave one.
        error_description: Option<String>,
    },

    /// The endpoint answered with something that is not a token-exchange
    /// response — a success body missing required fields, or a failure whose
    /// body is not an RFC 6749 error.
    #[error("invalid token exchange response: {0}")]
    InvalidResponse(String),
}

impl DelegationError {
    /// The cross-language name for this failure.
    ///
    /// Every conduit SDK distinguishes the same cases under the same names.
    /// Rust callers branching on the failure should match the variant; this
    /// exists for the contract, and for logs that another SDK's user may read.
    ///
    /// The `match` is exhaustive on purpose: a new variant will not compile
    /// until it is named here.
    ///
    /// ```
    /// use datagrout_conduit::delegation::DelegationError;
    ///
    /// assert_eq!(DelegationError::MissingActor.kind(), "missing_actor");
    /// ```
    pub fn kind(&self) -> &'static str {
        match self {
            Self::MissingSubject => "missing_subject",
            Self::MissingActor => "missing_actor",
            Self::Http(_) => "http",
            Self::Server { .. } => "server",
            Self::InvalidResponse(_) => "invalid_response",
        }
    }
}

impl From<DelegationError> for Error {
    fn from(e: DelegationError) -> Self {
        Error::Auth(e.to_string())
    }
}

// ---------------------------------------------------------------------------
// Request
// ---------------------------------------------------------------------------

/// How the client authenticates to the token endpoint.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub enum ClientAuth {
    /// `client_id` and `client_secret` as form fields (RFC 6749 §2.3.1
    /// `client_secret_post`). The default, and what DataGrout expects.
    #[default]
    Body,
    /// `Authorization: Basic base64(client_id:client_secret)`
    /// (`client_secret_basic`). `client_id` is still sent in the body, as RFC
    /// 6749 permits and some servers require.
    Basic,
}

/// A token-exchange request, built up and then [`exchange`](Self::exchange)d.
///
/// Cloneable so a [`DelegatedProvider`] can hold one as a template and fill in
/// fresh subject and actor tokens on each re-exchange.
#[derive(Debug, Clone)]
pub struct DelegationRequest {
    token_endpoint: String,
    client_id: String,
    client_secret: Option<String>,
    client_auth: ClientAuth,
    subject: Option<(String, TokenType)>,
    actor: Option<(String, TokenType)>,
    audience: Option<String>,
    resource: Option<String>,
    scope: Option<String>,
    requested_token_type: Option<TokenType>,
    impersonation: bool,
}

impl DelegationRequest {
    /// Start a request against `token_endpoint`, authenticating as `client_id`.
    ///
    /// The client should be the actor — see the module docs.
    pub fn new(token_endpoint: impl Into<String>, client_id: impl Into<String>) -> Self {
        Self {
            token_endpoint: token_endpoint.into(),
            client_id: client_id.into(),
            client_secret: None,
            client_auth: ClientAuth::default(),
            subject: None,
            actor: None,
            audience: None,
            resource: None,
            scope: None,
            requested_token_type: None,
            impersonation: false,
        }
    }

    /// The client secret, for confidential clients.
    pub fn client_secret(mut self, secret: impl Into<String>) -> Self {
        self.client_secret = Some(secret.into());
        self
    }

    /// Where the client secret travels. Defaults to [`ClientAuth::Body`].
    pub fn client_auth(mut self, auth: ClientAuth) -> Self {
        self.client_auth = auth;
        self
    }

    /// The token being exchanged: the **user's**, whose identity the issued
    /// token will carry as `sub`.
    pub fn subject_token(mut self, token: impl Into<String>, token_type: TokenType) -> Self {
        self.subject = Some((token.into(), token_type));
        self
    }

    /// The **agent's** own token, which the issued token will name in `act`.
    pub fn actor_token(mut self, token: impl Into<String>, token_type: TokenType) -> Self {
        self.actor = Some((token.into(), token_type));
        self
    }

    /// Logical name of the service the token is for (RFC 8693 `audience`).
    pub fn audience(mut self, audience: impl Into<String>) -> Self {
        self.audience = Some(audience.into());
        self
    }

    /// URI of the resource the token is for (RFC 8707 `resource`). Always sent
    /// when set, so the token cannot be replayed elsewhere.
    pub fn resource(mut self, resource: impl Into<String>) -> Self {
        self.resource = Some(resource.into());
        self
    }

    /// Scopes to request, space-separated.
    pub fn scope(mut self, scope: impl Into<String>) -> Self {
        self.scope = Some(scope.into());
        self
    }

    /// The kind of token wanted back. Servers default to an access token.
    pub fn requested_token_type(mut self, token_type: TokenType) -> Self {
        self.requested_token_type = Some(token_type);
        self
    }

    /// Opt out of delegation: send no `actor_token`, so the issued token has
    /// no `act` claim and the agent is indistinguishable from the user.
    ///
    /// DataGrout does not issue these. This exists for other RFC 8693 servers,
    /// and it is a builder call rather than a default precisely so that
    /// forgetting to set an actor is an error instead of a silent downgrade.
    pub fn impersonation(mut self) -> Self {
        self.impersonation = true;
        self
    }

    /// The token endpoint this request posts to.
    pub fn token_endpoint(&self) -> &str {
        &self.token_endpoint
    }

    /// The client id this request authenticates as.
    pub fn client_id(&self) -> &str {
        &self.client_id
    }

    /// Whether [`impersonation`](Self::impersonation) was called.
    pub fn is_impersonation(&self) -> bool {
        self.impersonation
    }

    /// The form body this request will post, in wire order.
    ///
    /// Fails before any network activity when the request is incomplete:
    /// [`DelegationError::MissingSubject`], or
    /// [`DelegationError::MissingActor`] unless
    /// [`impersonation`](Self::impersonation) was called. Public so a caller
    /// — or another SDK's test suite — can check the body against the
    /// contract fixture without a server.
    pub fn form_params(&self) -> std::result::Result<Vec<(String, String)>, DelegationError> {
        let (subject, subject_type) = self
            .subject
            .as_ref()
            .ok_or(DelegationError::MissingSubject)?;

        let mut form: Vec<(String, String)> = vec![
            ("grant_type".into(), GRANT_TYPE.into()),
            ("subject_token".into(), subject.clone()),
            ("subject_token_type".into(), subject_type.as_urn().into()),
        ];

        match (&self.actor, self.impersonation) {
            (Some((actor, actor_type)), _) => {
                form.push(("actor_token".into(), actor.clone()));
                form.push(("actor_token_type".into(), actor_type.as_urn().into()));
            }
            (None, true) => {}
            (None, false) => return Err(DelegationError::MissingActor),
        }

        form.push(("client_id".into(), self.client_id.clone()));
        if let (Some(secret), ClientAuth::Body) = (&self.client_secret, self.client_auth) {
            form.push(("client_secret".into(), secret.clone()));
        }

        for (key, value) in [
            ("audience", &self.audience),
            ("resource", &self.resource),
            ("scope", &self.scope),
        ] {
            if let Some(value) = value {
                form.push((key.into(), value.clone()));
            }
        }
        if let Some(requested) = &self.requested_token_type {
            form.push(("requested_token_type".into(), requested.as_urn().into()));
        }

        Ok(form)
    }

    /// Perform the exchange.
    pub async fn exchange(
        &self,
        http: &reqwest::Client,
    ) -> std::result::Result<DelegatedToken, DelegationError> {
        let form = self.form_params()?;

        let mut request = http.post(&self.token_endpoint).form(&form);
        if let (Some(secret), ClientAuth::Basic) = (&self.client_secret, self.client_auth) {
            let credentials =
                general_purpose::STANDARD.encode(format!("{}:{}", self.client_id, secret));
            request = request.header(
                reqwest::header::AUTHORIZATION,
                format!("Basic {credentials}"),
            );
        }

        let resp = request
            .send()
            .await
            .map_err(|e| DelegationError::Http(e.to_string()))?;

        let status = resp.status();
        let body = resp
            .text()
            .await
            .map_err(|e| DelegationError::Http(e.to_string()))?;

        if !status.is_success() {
            return Err(parse_error_body(status.as_u16(), &body));
        }

        let token: TokenResponse = serde_json::from_str(&body)
            .map_err(|e| DelegationError::InvalidResponse(format!("HTTP {status}: {e}")))?;

        tracing::debug!(
            "conduit: exchanged for a delegated token (client_id={} issued={} expires_in={:?})",
            self.client_id,
            token.issued_token_type,
            token.expires_in
        );

        Ok(DelegatedToken {
            access_token: token.access_token,
            issued_token_type: token.issued_token_type,
            token_type: token.token_type,
            expires_at: token.expires_in.map(|s| now_secs() + s),
            scope: token.scope,
        })
    }
}

/// A non-2xx body is an RFC 6749 error when it carries `error`; anything else
/// — a proxy's HTML, an empty body — is reported as an invalid response with
/// the status, since it did not come from the token endpoint's contract.
fn parse_error_body(status: u16, body: &str) -> DelegationError {
    #[derive(Deserialize)]
    struct ErrorBody {
        error: String,
        #[serde(default)]
        error_description: Option<String>,
    }

    match serde_json::from_str::<ErrorBody>(body) {
        Ok(err) => DelegationError::Server {
            status,
            error: err.error,
            error_description: err.error_description,
        },
        Err(_) => DelegationError::InvalidResponse(format!(
            "HTTP {status} with a non-OAuth body: {}",
            body.chars().take(200).collect::<String>()
        )),
    }
}

/// RFC 8693 §2.2.1 success response. `issued_token_type` and `token_type`
/// are required by the RFC; a server omitting either is out of contract and
/// surfaces as [`DelegationError::InvalidResponse`].
#[derive(Debug, Deserialize)]
struct TokenResponse {
    access_token: String,
    issued_token_type: TokenType,
    token_type: String,
    #[serde(default)]
    expires_in: Option<u64>,
    #[serde(default)]
    scope: Option<String>,
}

// ---------------------------------------------------------------------------
// Token
// ---------------------------------------------------------------------------

/// A token issued by an exchange.
///
/// The serialized shape is part of the cross-language contract, and is what
/// `testdata/contract.json` pins: `access_token`, `issued_token_type` (a URN
/// string), `token_type`, `expires_at?`, `scope?`. As with
/// [`crate::authcode::Grant`], `expires_at` is **Unix seconds** — computed
/// from the server's relative `expires_in` at receipt — never a monotonic
/// instant, so the token means the same thing once written down.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct DelegatedToken {
    /// The bearer token to present.
    pub access_token: String,
    /// What kind of token was issued.
    pub issued_token_type: TokenType,
    /// How to present it — `Bearer`, in practice.
    pub token_type: String,
    /// Absolute expiry, Unix seconds. `None` means the server did not say.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub expires_at: Option<u64>,
    /// Granted scopes, when the server reported them.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub scope: Option<String>,
}

impl DelegatedToken {
    /// True when the token is expired, or within the refresh skew of it.
    ///
    /// A token with no stated expiry is treated as live: the server chose not
    /// to say, and guessing would throw away working tokens.
    pub fn is_expired(&self) -> bool {
        match self.expires_at {
            None => false,
            Some(at) => now_secs() + REFRESH_SKEW_SECS >= at,
        }
    }
}

// ---------------------------------------------------------------------------
// Token sources
// ---------------------------------------------------------------------------

type DynamicSource =
    Arc<dyn Fn() -> Pin<Box<dyn Future<Output = Result<String>> + Send>> + Send + Sync>;

#[derive(Clone)]
enum SourceKind {
    Static(String),
    ClientCredentials(OAuthTokenProvider),
    #[cfg(feature = "authcode")]
    AuthorizationCode(crate::authcode::AuthCodeProvider),
    Dynamic(DynamicSource),
}

/// Where a [`DelegatedProvider`] gets a subject or actor token from, and what
/// [`TokenType`] to declare it as.
///
/// A source is consulted on every exchange, so a provider-backed source hands
/// over a *fresh* token each time — the whole point of wrapping a provider
/// rather than copying its current token out.
#[derive(Clone)]
pub struct TokenSource {
    kind: SourceKind,
    token_type: TokenType,
}

impl std::fmt::Debug for TokenSource {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        // Never print tokens.
        let kind = match &self.kind {
            SourceKind::Static(_) => "static",
            SourceKind::ClientCredentials(_) => "client_credentials",
            #[cfg(feature = "authcode")]
            SourceKind::AuthorizationCode(_) => "authorization_code",
            SourceKind::Dynamic(_) => "dynamic",
        };
        f.debug_struct("TokenSource")
            .field("kind", &kind)
            .field("token_type", &self.token_type)
            .finish()
    }
}

impl TokenSource {
    /// A fixed token, e.g. one handed to the agent for this run.
    pub fn static_token(token: impl Into<String>, token_type: TokenType) -> Self {
        Self {
            kind: SourceKind::Static(token.into()),
            token_type,
        }
    }

    /// The agent's own `client_credentials` provider — the usual **actor**.
    /// Declared as [`TokenType::AccessToken`]; override with
    /// [`with_token_type`](Self::with_token_type) if the server wants `jwt`.
    pub fn client_credentials(provider: OAuthTokenProvider) -> Self {
        Self {
            kind: SourceKind::ClientCredentials(provider),
            token_type: TokenType::AccessToken,
        }
    }

    /// A user's authorization-code provider — the usual **subject** in an app
    /// that signed the user in itself. Refreshes its grant as needed, so the
    /// exchange always sees a live subject token.
    #[cfg(feature = "authcode")]
    pub fn authorization_code(provider: crate::authcode::AuthCodeProvider) -> Self {
        Self {
            kind: SourceKind::AuthorizationCode(provider),
            token_type: TokenType::AccessToken,
        }
    }

    /// Any async function that yields a token — a vault lookup, a header from
    /// an inbound request, another SDK's provider.
    pub fn dynamic<F, Fut>(f: F, token_type: TokenType) -> Self
    where
        F: Fn() -> Fut + Send + Sync + 'static,
        Fut: Future<Output = Result<String>> + Send + 'static,
    {
        Self {
            kind: SourceKind::Dynamic(Arc::new(move || Box::pin(f()))),
            token_type,
        }
    }

    /// Declare a different [`TokenType`] for this source.
    pub fn with_token_type(mut self, token_type: TokenType) -> Self {
        self.token_type = token_type;
        self
    }

    /// The declared token type.
    pub fn token_type(&self) -> &TokenType {
        &self.token_type
    }

    async fn resolve(&self, http: &reqwest::Client) -> Result<String> {
        match &self.kind {
            SourceKind::Static(token) => Ok(token.clone()),
            SourceKind::ClientCredentials(p) => p.get_token(http).await,
            #[cfg(feature = "authcode")]
            SourceKind::AuthorizationCode(p) => p.get_token(http).await,
            SourceKind::Dynamic(f) => f().await,
        }
    }
}

// ---------------------------------------------------------------------------
// Provider
// ---------------------------------------------------------------------------

/// Keeps a delegated token fresh, re-exchanging when it nears expiry.
///
/// The third token provider in this crate, shaped like the other two —
/// [`OAuthTokenProvider`](crate::oauth::OAuthTokenProvider) and
/// [`AuthCodeProvider`](crate::authcode::AuthCodeProvider) — so every
/// transport reaches it through the same path: `get_token` on the way out,
/// `invalidate` on a 401. Each exchange pulls a fresh subject and actor token
/// from its [`TokenSource`]s, so an expiring upstream credential is handled by
/// the provider that owns it.
///
/// Cheaply cloneable (one `Arc`); clones share one cache and one exchange.
#[derive(Clone)]
pub struct DelegatedProvider {
    inner: Arc<Inner>,
}

/// Everything behind the `Arc`, so the provider is pointer-sized inside
/// [`AuthConfig`](crate::transport::AuthConfig) like the other two.
struct Inner {
    request: DelegationRequest,
    subject: TokenSource,
    actor: Option<TokenSource>,
    cached: RwLock<Option<DelegatedToken>>,
    /// Serializes exchanges so concurrent callers make one request rather
    /// than a stampede. Separate from `cached`: this one is held across the
    /// network call, that one never is.
    exchanging: tokio::sync::Mutex<()>,
}

impl std::fmt::Debug for DelegatedProvider {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        // Never print tokens — the request template carries the client secret.
        f.debug_struct("DelegatedProvider")
            .field("token_endpoint", &self.inner.request.token_endpoint)
            .field("client_id", &self.inner.request.client_id)
            .field("subject", &self.inner.subject)
            .field("actor", &self.inner.actor)
            .finish_non_exhaustive()
    }
}

impl DelegatedProvider {
    /// Wrap a request template with the sources of its two tokens.
    ///
    /// Any `subject_token` or `actor_token` already on `request` is ignored;
    /// the sources supply them. Pass `actor: None` only with a request that
    /// called [`impersonation`](DelegationRequest::impersonation) — otherwise
    /// every `get_token` fails with `missing_actor`, which is the intended
    /// loud failure rather than a silent downgrade.
    pub fn new(
        request: DelegationRequest,
        subject: TokenSource,
        actor: Option<TokenSource>,
    ) -> Self {
        Self {
            inner: Arc::new(Inner {
                request,
                subject,
                actor,
                cached: RwLock::new(None),
                exchanging: tokio::sync::Mutex::new(()),
            }),
        }
    }

    /// The current delegated bearer, exchanging first if there is none or it
    /// is at or near expiry.
    pub async fn get_token(&self, http: &reqwest::Client) -> Result<String> {
        if let Some(token) = self.live_token().await {
            return Ok(token);
        }

        // One exchange at a time. Waiters re-check on entry, so a leader that
        // succeeded spares them the request entirely.
        let _exchanging = self.inner.exchanging.lock().await;
        if let Some(token) = self.live_token().await {
            return Ok(token);
        }

        let token = self.exchange(http).await?;
        let bearer = token.access_token.clone();
        *self.inner.cached.write().await = Some(token);
        Ok(bearer)
    }

    /// Force the next [`get_token`](Self::get_token) to exchange again. Call
    /// on a 401.
    ///
    /// Only the delegated token is dropped. The subject and actor sources are
    /// left alone: a provider-backed source tracks its own expiry, and a 401
    /// from the resource server says nothing about them.
    pub async fn invalidate(&self) {
        *self.inner.cached.write().await = None;
    }

    /// A snapshot of the cached token, if any — for inspection or logging.
    pub async fn token(&self) -> Option<DelegatedToken> {
        self.inner.cached.read().await.clone()
    }

    /// The request template, without tokens.
    pub fn request(&self) -> &DelegationRequest {
        &self.inner.request
    }

    async fn live_token(&self) -> Option<String> {
        let guard = self.inner.cached.read().await;
        guard
            .as_ref()
            .filter(|t| !t.is_expired())
            .map(|t| t.access_token.clone())
    }

    async fn exchange(&self, http: &reqwest::Client) -> Result<DelegatedToken> {
        let Inner {
            request,
            subject,
            actor,
            ..
        } = &*self.inner;

        // Refuse before resolving anything: a missing actor is a configuration
        // mistake, and fetching a subject token first would only hide it.
        if actor.is_none() && !request.impersonation {
            return Err(DelegationError::MissingActor.into());
        }

        let subject_token = subject.resolve(http).await?;
        let mut request = request
            .clone()
            .subject_token(subject_token, subject.token_type.clone());

        if let Some(actor) = actor {
            let token = actor.resolve(http).await?;
            request = request.actor_token(token, actor.token_type.clone());
        }

        Ok(request.exchange(http).await?)
    }
}

fn now_secs() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_secs())
        .unwrap_or(0)
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

#[cfg(test)]
mod tests {
    use super::*;
    use mockito::Matcher;

    fn request(endpoint: &str) -> DelegationRequest {
        DelegationRequest::new(endpoint, "agent_client")
            .client_secret("agent_secret")
            .subject_token("user_at", TokenType::AccessToken)
            .actor_token("agent_at", TokenType::AccessToken)
    }

    fn success_body() -> &'static str {
        r#"{
            "access_token": "delegated_at",
            "issued_token_type": "urn:ietf:params:oauth:token-type:access_token",
            "token_type": "Bearer",
            "expires_in": 900,
            "scope": "mcp tools"
        }"#
    }

    // ─── token types ─────────────────────────────────────────────────────

    #[test]
    fn token_types_round_trip_through_their_urns() {
        for t in [
            TokenType::AccessToken,
            TokenType::Jwt,
            TokenType::IdToken,
            TokenType::RefreshToken,
            TokenType::Saml2,
        ] {
            assert!(t.as_urn().starts_with("urn:ietf:params:oauth:token-type:"));
            assert_eq!(TokenType::from_urn(t.as_urn()), t);
        }
        assert_eq!(
            TokenType::from_urn("urn:example:custom"),
            TokenType::Other("urn:example:custom".into())
        );
    }

    #[test]
    fn token_type_serializes_as_a_bare_urn_string() {
        let json = serde_json::to_value(TokenType::Jwt).unwrap();
        assert_eq!(json, "urn:ietf:params:oauth:token-type:jwt");
        let back: TokenType = serde_json::from_value(json).unwrap();
        assert_eq!(back, TokenType::Jwt);
    }

    // ─── form body ───────────────────────────────────────────────────────

    #[test]
    fn form_carries_exactly_the_expected_fields_in_wire_order() {
        let form = request("https://as.example.com/oauth/token")
            .audience("https://gateway.example.com")
            .resource("https://gateway.example.com/connect")
            .scope("mcp tools")
            .requested_token_type(TokenType::AccessToken)
            .form_params()
            .unwrap();

        let expected: Vec<(String, String)> = [
            ("grant_type", GRANT_TYPE),
            ("subject_token", "user_at"),
            (
                "subject_token_type",
                "urn:ietf:params:oauth:token-type:access_token",
            ),
            ("actor_token", "agent_at"),
            (
                "actor_token_type",
                "urn:ietf:params:oauth:token-type:access_token",
            ),
            ("client_id", "agent_client"),
            ("client_secret", "agent_secret"),
            ("audience", "https://gateway.example.com"),
            ("resource", "https://gateway.example.com/connect"),
            ("scope", "mcp tools"),
            (
                "requested_token_type",
                "urn:ietf:params:oauth:token-type:access_token",
            ),
        ]
        .iter()
        .map(|(k, v)| (k.to_string(), v.to_string()))
        .collect();

        assert_eq!(form, expected);
    }

    #[test]
    fn form_omits_optionals_that_were_not_set() {
        let form = request("https://as.example.com/oauth/token")
            .form_params()
            .unwrap();
        let keys: Vec<&str> = form.iter().map(|(k, _)| k.as_str()).collect();
        for absent in ["audience", "resource", "scope", "requested_token_type"] {
            assert!(!keys.contains(&absent), "{absent} should not be sent");
        }
    }

    #[test]
    fn form_sends_resource_whenever_it_is_set() {
        // RFC 8707 — the same invariant the authorization-code module keeps.
        let form = request("https://as.example.com/oauth/token")
            .resource("https://gateway.example.com/connect")
            .form_params()
            .unwrap();
        assert!(form.contains(&(
            "resource".to_string(),
            "https://gateway.example.com/connect".to_string()
        )));
    }

    #[test]
    fn form_keeps_the_secret_out_of_the_body_under_basic_auth() {
        let form = request("https://as.example.com/oauth/token")
            .client_auth(ClientAuth::Basic)
            .form_params()
            .unwrap();
        assert!(form.iter().all(|(k, _)| k != "client_secret"));
        // client_id still travels in the body.
        assert!(form.contains(&("client_id".to_string(), "agent_client".to_string())));
    }

    #[test]
    fn form_accepts_a_jwt_subject() {
        let form = DelegationRequest::new("https://as.example.com/oauth/token", "c")
            .subject_token("eyJ", TokenType::Jwt)
            .actor_token("agent_at", TokenType::AccessToken)
            .form_params()
            .unwrap();
        assert!(form.contains(&(
            "subject_token_type".to_string(),
            "urn:ietf:params:oauth:token-type:jwt".to_string()
        )));
    }

    // ─── refusals before any HTTP ────────────────────────────────────────

    #[tokio::test]
    async fn a_missing_actor_is_refused_before_any_request_is_sent() {
        let mut server = mockito::Server::new_async().await;
        let never = server
            .mock("POST", "/oauth/token")
            .expect(0)
            .create_async()
            .await;

        let err = DelegationRequest::new(format!("{}/oauth/token", server.url()), "c")
            .subject_token("user_at", TokenType::AccessToken)
            .exchange(&reqwest::Client::new())
            .await
            .unwrap_err();

        assert!(matches!(err, DelegationError::MissingActor), "{err:?}");
        assert_eq!(err.kind(), "missing_actor");
        never.assert_async().await;
    }

    #[tokio::test]
    async fn a_missing_subject_is_refused_before_any_request_is_sent() {
        let mut server = mockito::Server::new_async().await;
        let never = server
            .mock("POST", "/oauth/token")
            .expect(0)
            .create_async()
            .await;

        let err = DelegationRequest::new(format!("{}/oauth/token", server.url()), "c")
            .actor_token("agent_at", TokenType::AccessToken)
            .exchange(&reqwest::Client::new())
            .await
            .unwrap_err();

        assert!(matches!(err, DelegationError::MissingSubject));
        assert_eq!(err.kind(), "missing_subject");
        never.assert_async().await;
    }

    #[test]
    fn impersonation_is_the_only_way_to_omit_the_actor() {
        let form = DelegationRequest::new("https://as.example.com/oauth/token", "c")
            .subject_token("user_at", TokenType::AccessToken)
            .impersonation()
            .form_params()
            .unwrap();
        assert!(form.iter().all(|(k, _)| !k.starts_with("actor_token")));
    }

    // ─── the wire ────────────────────────────────────────────────────────

    #[tokio::test]
    async fn exchange_posts_a_form_encoded_body_with_the_actor_fields() {
        let mut server = mockito::Server::new_async().await;
        let token = server
            .mock("POST", "/oauth/token")
            .match_header("content-type", "application/x-www-form-urlencoded")
            .match_body(Matcher::AllOf(vec![
                Matcher::UrlEncoded("grant_type".into(), GRANT_TYPE.into()),
                Matcher::UrlEncoded("subject_token".into(), "user_at".into()),
                Matcher::UrlEncoded(
                    "subject_token_type".into(),
                    "urn:ietf:params:oauth:token-type:access_token".into(),
                ),
                Matcher::UrlEncoded("actor_token".into(), "agent_at".into()),
                Matcher::UrlEncoded(
                    "actor_token_type".into(),
                    "urn:ietf:params:oauth:token-type:access_token".into(),
                ),
                Matcher::UrlEncoded("client_id".into(), "agent_client".into()),
                Matcher::UrlEncoded("client_secret".into(), "agent_secret".into()),
                Matcher::UrlEncoded(
                    "resource".into(),
                    "https://gateway.example.com/connect".into(),
                ),
            ]))
            .with_status(200)
            .with_header("content-type", "application/json")
            .with_body(success_body())
            .expect(1)
            .create_async()
            .await;

        let issued = request(&format!("{}/oauth/token", server.url()))
            .resource("https://gateway.example.com/connect")
            .exchange(&reqwest::Client::new())
            .await
            .unwrap();

        assert_eq!(issued.access_token, "delegated_at");
        token.assert_async().await;
    }

    #[tokio::test]
    async fn exchange_sends_basic_client_auth_when_asked() {
        let mut server = mockito::Server::new_async().await;
        let expected = general_purpose::STANDARD.encode("agent_client:agent_secret");
        let token = server
            .mock("POST", "/oauth/token")
            .match_header("authorization", format!("Basic {expected}").as_str())
            .with_status(200)
            .with_body(success_body())
            .expect(1)
            .create_async()
            .await;

        request(&format!("{}/oauth/token", server.url()))
            .client_auth(ClientAuth::Basic)
            .exchange(&reqwest::Client::new())
            .await
            .unwrap();
        token.assert_async().await;
    }

    #[tokio::test]
    async fn a_success_response_becomes_a_token_with_an_absolute_expiry() {
        let mut server = mockito::Server::new_async().await;
        let _token = server
            .mock("POST", "/oauth/token")
            .with_status(200)
            .with_body(success_body())
            .create_async()
            .await;

        let before = now_secs();
        let issued = request(&format!("{}/oauth/token", server.url()))
            .exchange(&reqwest::Client::new())
            .await
            .unwrap();
        let after = now_secs();

        assert_eq!(issued.access_token, "delegated_at");
        assert_eq!(issued.issued_token_type, TokenType::AccessToken);
        assert_eq!(issued.token_type, "Bearer");
        assert_eq!(issued.scope.as_deref(), Some("mcp tools"));

        // expires_at = now + expires_in, in seconds, allowing for the clock
        // ticking during the request.
        let at = issued.expires_at.expect("expires_in was given");
        assert!(at >= before + 900 && at <= after + 900, "expires_at={at}");
        assert!(!issued.is_expired());
    }

    #[tokio::test]
    async fn an_rfc6749_error_body_is_a_server_error_with_code_and_status() {
        let mut server = mockito::Server::new_async().await;
        let _token = server
            .mock("POST", "/oauth/token")
            .with_status(400)
            .with_header("content-type", "application/json")
            .with_body(r#"{"error":"invalid_target","error_description":"unknown resource"}"#)
            .create_async()
            .await;

        let err = request(&format!("{}/oauth/token", server.url()))
            .exchange(&reqwest::Client::new())
            .await
            .unwrap_err();

        assert_eq!(err.kind(), "server");
        match err {
            DelegationError::Server {
                status,
                error,
                error_description,
            } => {
                assert_eq!(status, 400);
                assert_eq!(error, codes::INVALID_TARGET);
                assert_eq!(error_description.as_deref(), Some("unknown resource"));
            }
            other => panic!("expected Server, got {other:?}"),
        }
    }

    #[tokio::test]
    async fn a_failure_without_an_oauth_body_is_an_invalid_response() {
        let mut server = mockito::Server::new_async().await;
        let _token = server
            .mock("POST", "/oauth/token")
            .with_status(502)
            .with_body("<html>bad gateway</html>")
            .create_async()
            .await;

        let err = request(&format!("{}/oauth/token", server.url()))
            .exchange(&reqwest::Client::new())
            .await
            .unwrap_err();

        assert_eq!(err.kind(), "invalid_response");
        assert!(err.to_string().contains("502"), "{err}");
    }

    #[tokio::test]
    async fn a_success_missing_issued_token_type_is_an_invalid_response() {
        // RFC 8693 §2.2.1 makes the field REQUIRED; a server that drops it is
        // out of contract, and guessing would hide that.
        let mut server = mockito::Server::new_async().await;
        let _token = server
            .mock("POST", "/oauth/token")
            .with_status(200)
            .with_body(r#"{"access_token":"x","token_type":"Bearer"}"#)
            .create_async()
            .await;

        let err = request(&format!("{}/oauth/token", server.url()))
            .exchange(&reqwest::Client::new())
            .await
            .unwrap_err();
        assert!(
            matches!(err, DelegationError::InvalidResponse(_)),
            "{err:?}"
        );
    }

    #[tokio::test]
    async fn an_unreachable_endpoint_is_an_http_error() {
        // Port 1 refuses connections.
        let err = request("http://127.0.0.1:1/oauth/token")
            .exchange(&reqwest::Client::new())
            .await
            .unwrap_err();
        assert_eq!(err.kind(), "http");
    }

    // ─── token ───────────────────────────────────────────────────────────

    fn token(expires_at: Option<u64>) -> DelegatedToken {
        DelegatedToken {
            access_token: "delegated_at".into(),
            issued_token_type: TokenType::AccessToken,
            token_type: "Bearer".into(),
            expires_at,
            scope: None,
        }
    }

    #[test]
    fn a_token_with_no_stated_expiry_is_not_expired() {
        assert!(!token(None).is_expired());
    }

    #[test]
    fn a_token_expires_early_by_the_refresh_skew() {
        assert!(token(Some(now_secs() + 30)).is_expired());
        assert!(!token(Some(now_secs() + 600)).is_expired());
    }

    #[test]
    fn token_omits_absent_optionals_when_serialized() {
        let json = serde_json::to_value(token(None)).unwrap();
        assert!(json.get("expires_at").is_none());
        assert!(json.get("scope").is_none());
        assert_eq!(
            json["issued_token_type"],
            "urn:ietf:params:oauth:token-type:access_token"
        );
    }

    // ─── provider ────────────────────────────────────────────────────────

    fn provider(endpoint: &str) -> DelegatedProvider {
        DelegatedProvider::new(
            DelegationRequest::new(endpoint, "agent_client").client_secret("agent_secret"),
            TokenSource::static_token("user_at", TokenType::AccessToken),
            Some(TokenSource::static_token(
                "agent_at",
                TokenType::AccessToken,
            )),
        )
    }

    #[tokio::test]
    async fn provider_exchanges_once_and_serves_from_cache_until_expiry() {
        let mut server = mockito::Server::new_async().await;
        let token = server
            .mock("POST", "/oauth/token")
            .with_status(200)
            .with_body(success_body())
            .expect(1)
            .create_async()
            .await;

        let p = provider(&format!("{}/oauth/token", server.url()));
        let http = reqwest::Client::new();

        assert_eq!(p.get_token(&http).await.unwrap(), "delegated_at");
        assert_eq!(p.get_token(&http).await.unwrap(), "delegated_at");
        assert_eq!(p.get_token(&http).await.unwrap(), "delegated_at");

        token.assert_async().await;
        assert!(p.token().await.is_some());
    }

    #[tokio::test]
    async fn provider_re_exchanges_after_invalidate() {
        let mut server = mockito::Server::new_async().await;
        let token = server
            .mock("POST", "/oauth/token")
            .with_status(200)
            .with_body(success_body())
            .expect(2)
            .create_async()
            .await;

        let p = provider(&format!("{}/oauth/token", server.url()));
        let http = reqwest::Client::new();

        p.get_token(&http).await.unwrap();
        p.invalidate().await;
        assert!(p.token().await.is_none());
        p.get_token(&http).await.unwrap();

        token.assert_async().await;
    }

    #[tokio::test]
    async fn provider_re_exchanges_a_token_that_is_inside_the_skew() {
        let mut server = mockito::Server::new_async().await;
        // Expires in 30s: already inside the 60s buffer, so the second call
        // must exchange again rather than serve it.
        let token = server
            .mock("POST", "/oauth/token")
            .with_status(200)
            .with_body(
                r#"{"access_token":"short","issued_token_type":"urn:ietf:params:oauth:token-type:access_token","token_type":"Bearer","expires_in":30}"#,
            )
            .expect(2)
            .create_async()
            .await;

        let p = provider(&format!("{}/oauth/token", server.url()));
        let http = reqwest::Client::new();
        p.get_token(&http).await.unwrap();
        p.get_token(&http).await.unwrap();
        token.assert_async().await;
    }

    #[tokio::test]
    async fn provider_pulls_fresh_upstream_tokens_on_every_exchange() {
        let mut server = mockito::Server::new_async().await;
        let first = server
            .mock("POST", "/oauth/token")
            .match_body(Matcher::UrlEncoded("subject_token".into(), "user_1".into()))
            .with_status(200)
            .with_body(success_body())
            .expect(1)
            .create_async()
            .await;
        let second = server
            .mock("POST", "/oauth/token")
            .match_body(Matcher::UrlEncoded("subject_token".into(), "user_2".into()))
            .with_status(200)
            .with_body(success_body())
            .expect(1)
            .create_async()
            .await;

        let counter = Arc::new(std::sync::atomic::AtomicUsize::new(0));
        let subject = {
            let counter = counter.clone();
            TokenSource::dynamic(
                move || {
                    let n = counter.fetch_add(1, std::sync::atomic::Ordering::SeqCst) + 1;
                    async move { Ok(format!("user_{n}")) }
                },
                TokenType::AccessToken,
            )
        };

        let p = DelegatedProvider::new(
            DelegationRequest::new(format!("{}/oauth/token", server.url()), "agent_client"),
            subject,
            Some(TokenSource::static_token(
                "agent_at",
                TokenType::AccessToken,
            )),
        );
        let http = reqwest::Client::new();

        p.get_token(&http).await.unwrap();
        p.invalidate().await;
        p.get_token(&http).await.unwrap();

        first.assert_async().await;
        second.assert_async().await;
    }

    #[tokio::test]
    async fn provider_uses_a_client_credentials_actor() {
        let mut server = mockito::Server::new_async().await;
        // The agent's own grant first, then the exchange carrying it.
        let cc = server
            .mock("POST", "/agent/token")
            .with_status(200)
            .with_body(r#"{"access_token":"agent_live","token_type":"Bearer","expires_in":3600}"#)
            .expect(1)
            .create_async()
            .await;
        let exchange = server
            .mock("POST", "/oauth/token")
            .match_body(Matcher::UrlEncoded(
                "actor_token".into(),
                "agent_live".into(),
            ))
            .with_status(200)
            .with_body(success_body())
            .expect(1)
            .create_async()
            .await;

        let actor = OAuthTokenProvider::new(
            "agent_client",
            "agent_secret",
            format!("{}/agent/token", server.url()),
            None,
        );
        let p = DelegatedProvider::new(
            DelegationRequest::new(format!("{}/oauth/token", server.url()), "agent_client")
                .client_secret("agent_secret"),
            TokenSource::static_token("user_at", TokenType::AccessToken),
            Some(TokenSource::client_credentials(actor)),
        );

        assert_eq!(
            p.get_token(&reqwest::Client::new()).await.unwrap(),
            "delegated_at"
        );
        cc.assert_async().await;
        exchange.assert_async().await;
    }

    #[tokio::test]
    async fn provider_without_an_actor_fails_loudly_unless_impersonating() {
        let mut server = mockito::Server::new_async().await;
        let never = server
            .mock("POST", "/oauth/token")
            .expect(0)
            .create_async()
            .await;

        let p = DelegatedProvider::new(
            DelegationRequest::new(format!("{}/oauth/token", server.url()), "c"),
            TokenSource::static_token("user_at", TokenType::AccessToken),
            None,
        );
        let err = p.get_token(&reqwest::Client::new()).await.unwrap_err();
        assert!(matches!(err, Error::Auth(_)));
        assert!(err.to_string().contains("actor_token"), "{err}");
        never.assert_async().await;
    }

    #[tokio::test]
    async fn provider_single_flights_concurrent_callers() {
        use tokio::io::{AsyncReadExt, AsyncWriteExt};

        // A slow endpoint, so the other callers are reliably queued behind the
        // leader rather than racing it.
        let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
        let addr = listener.local_addr().unwrap();
        let hits = Arc::new(std::sync::atomic::AtomicUsize::new(0));
        let counted = hits.clone();
        tokio::spawn(async move {
            while let Ok((mut socket, _)) = listener.accept().await {
                counted.fetch_add(1, std::sync::atomic::Ordering::SeqCst);
                tokio::spawn(async move {
                    let mut buf = [0u8; 4096];
                    let _ = socket.read(&mut buf).await;
                    tokio::time::sleep(std::time::Duration::from_millis(300)).await;
                    let body = success_body();
                    let _ = socket
                        .write_all(
                            format!(
                                "HTTP/1.1 200 OK\r\ncontent-type: application/json\r\n\
                                 content-length: {}\r\nconnection: close\r\n\r\n{}",
                                body.len(),
                                body
                            )
                            .as_bytes(),
                        )
                        .await;
                });
            }
        });

        let p = provider(&format!("http://{addr}/oauth/token"));
        let http = reqwest::Client::new();
        let waiters: Vec<_> = (0..5)
            .map(|_| {
                let p = p.clone();
                let h = http.clone();
                tokio::spawn(async move { p.get_token(&h).await })
            })
            .collect();
        for w in waiters {
            assert_eq!(w.await.unwrap().unwrap(), "delegated_at");
        }
        assert_eq!(hits.load(std::sync::atomic::Ordering::SeqCst), 1);
    }

    #[test]
    fn provider_debug_never_prints_tokens_or_secrets() {
        let p = provider("https://as.example.com/oauth/token");
        let rendered = format!("{p:?}");
        assert!(!rendered.contains("agent_secret"));
        assert!(!rendered.contains("user_at"));
        assert!(!rendered.contains("agent_at"));
        assert!(rendered.contains("agent_client"));
    }

    #[test]
    fn delegation_error_converts_into_the_crate_error() {
        let e: Error = DelegationError::MissingActor.into();
        assert!(matches!(e, Error::Auth(_)));
    }

    // ---------------------------------------------------------------------
    // Cross-language contract
    //
    // `testdata/contract.json` holds the delegation fixture every language
    // SDK checks: the grant type, the token-type URNs, the exact form body a
    // fixture request must produce, the issued-token shape, the error kinds
    // and the server error codes. See `testdata/README.md`.
    // ---------------------------------------------------------------------

    fn contract() -> serde_json::Value {
        let all: serde_json::Value = serde_json::from_str(include_str!(concat!(
            env!("CARGO_MANIFEST_DIR"),
            "/../testdata/contract.json"
        )))
        .expect("testdata/contract.json is not valid JSON");
        all["delegation"].clone()
    }

    #[test]
    fn contract_fixture_pins_the_grant_type() {
        assert_eq!(GRANT_TYPE, contract()["grant_type"].as_str().unwrap());
    }

    #[test]
    fn contract_fixture_pins_the_token_type_urns() {
        let urns = &contract()["token_types"];
        let pairs = [
            ("access_token", TokenType::AccessToken),
            ("jwt", TokenType::Jwt),
            ("id_token", TokenType::IdToken),
            ("refresh_token", TokenType::RefreshToken),
            ("saml2", TokenType::Saml2),
        ];
        assert_eq!(urns.as_object().unwrap().len(), pairs.len());
        for (name, t) in pairs {
            assert_eq!(urns[name].as_str().unwrap(), t.as_urn(), "{name}");
        }
    }

    #[test]
    fn contract_fixture_request_produces_exactly_the_fixture_form() {
        // The request fixture is what a port builds; `request_form` is the
        // body it must post, field for field and in order.
        let c = contract();
        let r = &c["request"];

        let mut request = DelegationRequest::new(
            r["token_endpoint"].as_str().unwrap(),
            r["client_id"].as_str().unwrap(),
        )
        .client_secret(r["client_secret"].as_str().unwrap())
        .subject_token(
            r["subject_token"].as_str().unwrap(),
            TokenType::from_urn(r["subject_token_type"].as_str().unwrap()),
        )
        .actor_token(
            r["actor_token"].as_str().unwrap(),
            TokenType::from_urn(r["actor_token_type"].as_str().unwrap()),
        )
        .audience(r["audience"].as_str().unwrap())
        .resource(r["resource"].as_str().unwrap())
        .scope(r["scope"].as_str().unwrap());
        request = request.requested_token_type(TokenType::from_urn(
            r["requested_token_type"].as_str().unwrap(),
        ));

        let expected: Vec<(String, String)> = c["request_form"]
            .as_array()
            .unwrap()
            .iter()
            .map(|pair| {
                (
                    pair[0].as_str().unwrap().to_string(),
                    pair[1].as_str().unwrap().to_string(),
                )
            })
            .collect();

        assert_eq!(request.form_params().unwrap(), expected);
    }

    #[test]
    fn contract_fixture_token_loads_field_for_field() {
        let t: DelegatedToken = serde_json::from_value(contract()["token"].clone()).unwrap();
        assert_eq!(t.access_token, "delegated_contract_fixture");
        assert_eq!(t.issued_token_type, TokenType::AccessToken);
        assert_eq!(t.token_type, "Bearer");
        assert_eq!(t.expires_at, Some(1_700_000_000));
        assert_eq!(t.scope.as_deref(), Some("mcp tools"));
    }

    #[test]
    fn contract_fixture_token_serializes_identically() {
        let expected = contract()["token"].clone();
        let t: DelegatedToken = serde_json::from_value(expected.clone()).unwrap();
        assert_eq!(serde_json::to_value(&t).unwrap(), expected);
    }

    #[test]
    fn contract_fixture_minimal_token_omits_absent_optionals() {
        let expected = contract()["token_minimal"].clone();
        let t: DelegatedToken = serde_json::from_value(expected.clone()).unwrap();
        assert!(t.expires_at.is_none());
        assert!(!t.is_expired());
        // Not `"scope": null` — another SDK reading this must see absence.
        assert_eq!(serde_json::to_value(&t).unwrap(), expected);
    }

    #[test]
    fn contract_fixture_wire_response_parses_to_the_fixture_token() {
        // The server's relative `expires_in` becomes an absolute `expires_at`.
        // Everything else copies across unchanged.
        let c = contract();
        let wire: TokenResponse = serde_json::from_value(c["wire_response"].clone()).unwrap();
        let expected: DelegatedToken = serde_json::from_value(c["token"].clone()).unwrap();
        assert_eq!(wire.access_token, expected.access_token);
        assert_eq!(wire.issued_token_type, expected.issued_token_type);
        assert_eq!(wire.token_type, expected.token_type);
        assert_eq!(wire.scope, expected.scope);
        assert_eq!(wire.expires_in, Some(900));
    }

    #[test]
    fn contract_fixture_pins_the_error_taxonomy() {
        let mut kinds: Vec<&'static str> = vec![
            DelegationError::MissingSubject.kind(),
            DelegationError::MissingActor.kind(),
            DelegationError::Http(String::new()).kind(),
            DelegationError::Server {
                status: 400,
                error: String::new(),
                error_description: None,
            }
            .kind(),
            DelegationError::InvalidResponse(String::new()).kind(),
        ];
        kinds.sort_unstable();

        let mut expected: Vec<String> = contract()["error_kinds"]
            .as_array()
            .unwrap()
            .iter()
            .map(|k| k.as_str().unwrap().to_string())
            .collect();
        expected.sort();

        assert_eq!(kinds, expected);
    }

    #[test]
    fn contract_fixture_pins_the_server_error_codes() {
        let mut ours: Vec<&str> = codes::ALL.to_vec();
        ours.sort_unstable();
        let mut expected: Vec<String> = contract()["server_error_codes"]
            .as_array()
            .unwrap()
            .iter()
            .map(|k| k.as_str().unwrap().to_string())
            .collect();
        expected.sort();
        assert_eq!(ours, expected);
    }
}
