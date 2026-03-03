//! Error types for Conduit SDK

/// Result type alias for Conduit operations
pub type Result<T> = std::result::Result<T, Error>;

/// Rate limit cap — either a fixed calls-per-hour number or truly unlimited.
///
/// Authenticated DataGrout users always receive `Unlimited`. Anonymous visitors
/// (using inspectors without a DG account) receive `PerHour(n)`.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum RateLimit {
    /// No cap — authenticated DataGrout users.
    Unlimited,
    /// Maximum calls allowed per hour — anonymous visitors.
    PerHour(u32),
}

impl std::fmt::Display for RateLimit {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            RateLimit::Unlimited => write!(f, "unlimited"),
            RateLimit::PerHour(n) => write!(f, "{}/hour", n),
        }
    }
}

/// Conduit SDK error variants.
///
/// All builder `.execute()` calls and `Client` methods return `Result<T, Error>`.
/// Match on specific variants for fine-grained error handling:
///
/// ```rust
/// # use datagrout_conduit::error::Error;
/// # fn handle(e: Error) {
/// match e {
///     Error::NotInitialized => { /* call connect() first */ }
///     Error::RateLimit { retry_after, .. } => { /* back off */ }
///     Error::Auth(_) => { /* check credentials */ }
///     Error::Server { code, message, .. } => { /* server-side error */ }
///     _ => {}
/// }
/// # }
/// ```
#[derive(Debug, thiserror::Error)]
pub enum Error {
    /// HTTP transport error (connection refused, TLS failure, etc.)
    #[error("HTTP error: {0}")]
    Http(#[from] reqwest::Error),

    /// JSON serialization/deserialization error
    #[error("JSON error: {0}")]
    Json(#[from] serde_json::Error),

    /// Server-side JSON-RPC error (method not found, invalid params, etc.)
    ///
    /// Maps to the `error` field in a JSON-RPC response.  The `code` follows
    /// the JSON-RPC 2.0 spec; see [`codes`] for the standard values.
    #[error("Server error {code}: {message}")]
    Server {
        /// JSON-RPC error code
        code: i32,
        /// Human-readable error message from the server
        message: String,
        /// Additional structured error data, if provided by the server
        data: Option<serde_json::Value>,
    },

    /// Rate limit exceeded (HTTP 429).
    ///
    /// Authenticated DataGrout users are never rate-limited (`limit` =
    /// [`RateLimit::Unlimited`]). Anonymous visitors hitting the inspector
    /// receive this error once the per-hour cap is reached.
    ///
    /// `retry_after` is populated when the server provides a `Retry-After`
    /// response header (number of seconds to wait before retrying).
    #[error("Rate limit exceeded ({used} / {limit} calls this hour)")]
    RateLimit {
        /// Seconds to wait before retrying, if the server advertised one.
        retry_after: Option<u64>,
        /// Calls made in the current window
        used: u32,
        /// Total allowed calls in the window
        limit: RateLimit,
    },

    /// Network-level error (TCP connection failure, DNS, etc.)
    #[error("Network error: {0}")]
    Network(String),

    /// Protocol-level error (unexpected SSE format, malformed response, etc.)
    #[error("Protocol error: {0}")]
    Protocol(String),

    /// Authentication error — bad token, expired credentials, etc.
    #[error("Authentication error: {0}")]
    Auth(String),

    /// Initialization error — unexpected failure during the MCP handshake.
    #[error("Initialization error: {0}")]
    Init(String),

    /// Request timed out after the given number of milliseconds.
    #[error("Operation timed out after {0}ms")]
    Timeout(u64),

    /// Invalid URL
    #[error("Invalid URL: {0}")]
    InvalidUrl(String),

    /// Invalid configuration — missing required field, incompatible options, etc.
    #[error("Invalid configuration: {0}")]
    InvalidConfig(String),

    /// Session not initialized — call [`Client::connect`](crate::client::Client::connect) first.
    #[error("Session not initialized. Call connect() first.")]
    NotInitialized,

    /// Tool not found
    #[error("Tool not found: {0}")]
    ToolNotFound(String),

    /// Resource not found
    #[error("Resource not found: {0}")]
    ResourceNotFound(String),

    /// Invalid arguments
    #[error("Invalid arguments: {0}")]
    InvalidArguments(String),

    /// Generic I/O error
    #[error("I/O error: {0}")]
    Io(#[from] std::io::Error),

    /// Catch-all for unexpected errors not covered by the above variants.
    #[error("{0}")]
    Other(String),
}

impl Error {
    /// Create a new server-side JSON-RPC error.
    pub fn server(code: i32, message: impl Into<String>, data: Option<serde_json::Value>) -> Self {
        Self::Server {
            code,
            message: message.into(),
            data,
        }
    }

    /// Create a rate-limit error for anonymous visitors.
    ///
    /// `retry_after` is the number of seconds the caller should wait before
    /// retrying, as advertised by the server's `Retry-After` header (or `None`
    /// when the header was absent).
    pub fn rate_limit(used: u32, per_hour_limit: u32, retry_after: Option<u64>) -> Self {
        Self::RateLimit {
            retry_after,
            used,
            limit: RateLimit::PerHour(per_hour_limit),
        }
    }

    /// Create a network error.
    pub fn network(message: impl Into<String>) -> Self {
        Self::Network(message.into())
    }

    /// Create an authentication error.
    pub fn auth(message: impl Into<String>) -> Self {
        Self::Auth(message.into())
    }

    /// Create an initialization error.
    pub fn init(message: impl Into<String>) -> Self {
        Self::Init(message.into())
    }

    /// Create an invalid URL error.
    pub fn invalid_url(message: impl Into<String>) -> Self {
        Self::InvalidUrl(message.into())
    }

    /// Create an invalid configuration error.
    pub fn invalid_config(message: impl Into<String>) -> Self {
        Self::InvalidConfig(message.into())
    }

    /// Returns `true` when the error is likely transient and safe to retry.
    pub fn is_retriable(&self) -> bool {
        matches!(
            self,
            Error::Http(_) | Error::Timeout(_) | Error::Network(_) | Error::Protocol(_)
        )
    }

    /// Returns `true` when the client has not yet been initialized via `connect()`.
    pub fn is_not_initialized(&self) -> bool {
        match self {
            Error::NotInitialized => true,
            Error::Server { code, message, .. } => {
                *code == -32002
                    || message.contains("not initialized")
                    || message.contains("Server not initialized")
            }
            _ => false,
        }
    }

    /// Returns `true` when the server has rate-limited this caller (HTTP 429).
    pub fn is_rate_limited(&self) -> bool {
        matches!(self, Error::RateLimit { .. })
    }
}

/// MCP error codes (from JSON-RPC 2.0 spec)
pub mod codes {
    /// Parse error
    pub const PARSE_ERROR: i32 = -32700;
    /// Invalid request
    pub const INVALID_REQUEST: i32 = -32600;
    /// Method not found
    pub const METHOD_NOT_FOUND: i32 = -32601;
    /// Invalid params
    pub const INVALID_PARAMS: i32 = -32602;
    /// Internal error
    pub const INTERNAL_ERROR: i32 = -32603;
    /// Server not initialized (custom MCP code)
    pub const NOT_INITIALIZED: i32 = -32002;
}
