//! Error types for Conduit SDK

/// Result type alias for Conduit operations
pub type Result<T> = std::result::Result<T, Error>;

/// Conduit error types
#[derive(Debug, thiserror::Error)]
pub enum Error {
    /// HTTP transport error
    #[error("HTTP error: {0}")]
    Http(#[from] reqwest::Error),

    /// JSON serialization/deserialization error
    #[error("JSON error: {0}")]
    Json(#[from] serde_json::Error),

    /// MCP protocol error (from server)
    #[error("MCP error {code}: {message}")]
    Mcp {
        /// JSON-RPC error code
        code: i32,
        /// Error message
        message: String,
        /// Additional error data
        data: Option<serde_json::Value>,
    },

    /// Connection error
    #[error("Connection error: {0}")]
    Connection(String),

    /// Authentication error
    #[error("Authentication error: {0}")]
    Auth(String),

    /// Initialization error
    #[error("Initialization error: {0}")]
    Init(String),

    /// Timeout error
    #[error("Operation timed out after {0}ms")]
    Timeout(u64),

    /// Invalid URL
    #[error("Invalid URL: {0}")]
    InvalidUrl(String),

    /// Invalid configuration
    #[error("Invalid configuration: {0}")]
    InvalidConfig(String),

    /// Session not initialized
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

    /// SSE stream error
    #[error("SSE stream error: {0}")]
    Sse(String),

    /// Other error
    #[error("{0}")]
    Other(String),
}

impl Error {
    /// Create a new MCP error
    pub fn mcp(code: i32, message: impl Into<String>, data: Option<serde_json::Value>) -> Self {
        Self::Mcp {
            code,
            message: message.into(),
            data,
        }
    }

    /// Create a connection error
    pub fn connection(message: impl Into<String>) -> Self {
        Self::Connection(message.into())
    }

    /// Create an authentication error
    pub fn auth(message: impl Into<String>) -> Self {
        Self::Auth(message.into())
    }

    /// Create an initialization error
    pub fn init(message: impl Into<String>) -> Self {
        Self::Init(message.into())
    }

    /// Create an invalid URL error
    pub fn invalid_url(message: impl Into<String>) -> Self {
        Self::InvalidUrl(message.into())
    }

    /// Create an invalid configuration error
    pub fn invalid_config(message: impl Into<String>) -> Self {
        Self::InvalidConfig(message.into())
    }

    /// Check if error is retriable
    pub fn is_retriable(&self) -> bool {
        matches!(
            self,
            Error::Http(_) | Error::Timeout(_) | Error::Connection(_) | Error::Sse(_)
        )
    }

    /// Check if error indicates not initialized
    pub fn is_not_initialized(&self) -> bool {
        match self {
            Error::NotInitialized => true,
            Error::Mcp { code, message, .. } => {
                *code == -32002
                    || message.contains("not initialized")
                    || message.contains("Server not initialized")
            }
            _ => false,
        }
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
