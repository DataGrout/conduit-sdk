//! Transport layer for MCP communication

use crate::error::{Error, Result};
use crate::protocol::{JsonRpcRequest, JsonRpcResponse};
use async_trait::async_trait;
use base64::{Engine as _, engine::general_purpose};
use reqwest::{header, Client as HttpClient};
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
    /// No authentication
    None,
    /// Bearer token
    Bearer(String),
    /// API key
    ApiKey(String),
    /// Basic auth
    Basic {
        /// Username
        username: String,
        /// Password
        password: String,
    },
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

/// MCP transport (SSE-based)
pub struct McpTransport {
    url: String,
    auth: AuthConfig,
    client: HttpClient,
    connected: Arc<RwLock<bool>>,
}

impl McpTransport {
    /// Create new MCP transport
    pub fn new(url: String, auth: AuthConfig) -> Result<Self> {
        let client = HttpClient::builder()
            .timeout(std::time::Duration::from_secs(60))
            .build()?;

        Ok(Self {
            url,
            auth,
            client,
            connected: Arc::new(RwLock::new(false)),
        })
    }

    fn build_headers(&self) -> header::HeaderMap {
        let mut headers = header::HeaderMap::new();
        headers.insert(
            header::CONTENT_TYPE,
            header::HeaderValue::from_static("application/json"),
        );

        match &self.auth {
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
                let credentials = general_purpose::STANDARD.encode(format!("{}:{}", username, password));
                if let Ok(value) = header::HeaderValue::from_str(&format!("Basic {}", credentials))
                {
                    headers.insert(header::AUTHORIZATION, value);
                }
            }
            AuthConfig::None => {}
        }

        headers
    }
}

#[async_trait]
impl TransportTrait for McpTransport {
    async fn connect(&mut self) -> Result<()> {
        // For MCP, connection is established on first request
        // Here we just verify the URL is valid
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

        let headers = self.build_headers();
        let response = self
            .client
            .post(&self.url)
            .headers(headers)
            .json(&request)
            .send()
            .await?;

        if !response.status().is_success() {
            return Err(Error::connection(format!(
                "HTTP {} error",
                response.status()
            )));
        }

        let json_response: JsonRpcResponse = response.json().await?;

        // Check for JSON-RPC error
        if let Some(error) = json_response.error {
            return Err(Error::mcp(error.code, error.message, error.data));
        }

        Ok(json_response)
    }

    fn is_connected(&self) -> bool {
        // Use try_read to avoid blocking
        if let Ok(connected) = self.connected.try_read() {
            *connected
        } else {
            false
        }
    }
}

/// JSON-RPC transport (HTTP POST-based)
pub struct JsonRpcTransport {
    url: String,
    auth: AuthConfig,
    client: HttpClient,
    connected: Arc<RwLock<bool>>,
}

impl JsonRpcTransport {
    /// Create new JSON-RPC transport
    pub fn new(url: String, auth: AuthConfig) -> Result<Self> {
        let client = HttpClient::builder()
            .timeout(std::time::Duration::from_secs(60))
            .build()?;

        Ok(Self {
            url,
            auth,
            client,
            connected: Arc::new(RwLock::new(false)),
        })
    }

    fn build_headers(&self) -> header::HeaderMap {
        let mut headers = header::HeaderMap::new();
        headers.insert(
            header::CONTENT_TYPE,
            header::HeaderValue::from_static("application/json"),
        );

        match &self.auth {
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
                let credentials = general_purpose::STANDARD.encode(format!("{}:{}", username, password));
                if let Ok(value) = header::HeaderValue::from_str(&format!("Basic {}", credentials))
                {
                    headers.insert(header::AUTHORIZATION, value);
                }
            }
            AuthConfig::None => {}
        }

        headers
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

        let headers = self.build_headers();
        let response = self
            .client
            .post(&self.url)
            .headers(headers)
            .json(&request)
            .send()
            .await?;

        if !response.status().is_success() {
            return Err(Error::connection(format!(
                "HTTP {} error",
                response.status()
            )));
        }

        let json_response: JsonRpcResponse = response.json().await?;

        // Check for JSON-RPC error
        if let Some(error) = json_response.error {
            return Err(Error::mcp(error.code, error.message, error.data));
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
