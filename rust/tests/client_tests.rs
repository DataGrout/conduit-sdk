//! Integration tests for Conduit client

use datagrout_conduit::{Client, ClientBuilder, Transport};
use serde_json::json;

#[tokio::test]
async fn test_client_builder() {
    let result = ClientBuilder::new()
        .url("https://gateway.datagrout.ai/servers/test/mcp")
        .transport(Transport::JsonRpc)
        .auth_bearer("test-token")
        .max_retries(3)
        .build();

    assert!(result.is_ok());
}

#[tokio::test]
async fn test_client_builder_requires_url() {
    let result = ClientBuilder::new()
        .transport(Transport::JsonRpc)
        .build();

    assert!(result.is_err());
    assert!(result.unwrap_err().to_string().contains("URL is required"));
}

// Mock server tests would go here
// For now, these are placeholder tests that demonstrate the API
#[tokio::test]
#[ignore] // Requires actual server
async fn test_connect() {
    let client = ClientBuilder::new()
        .url("https://gateway.datagrout.ai/servers/test/mcp")
        .auth_bearer("test-token")
        .build()
        .unwrap();

    let result = client.connect().await;
    // Would succeed with real server
    assert!(result.is_err()); // Fails without server
}

#[tokio::test]
#[ignore] // Requires actual server
async fn test_list_tools() {
    let client = ClientBuilder::new()
        .url("https://gateway.datagrout.ai/servers/test/mcp")
        .auth_bearer("test-token")
        .build()
        .unwrap();

    client.connect().await.unwrap();
    let tools = client.list_tools().await;

    assert!(tools.is_ok());
}

#[tokio::test]
#[ignore] // Requires actual server
async fn test_call_tool() {
    let client = ClientBuilder::new()
        .url("https://gateway.datagrout.ai/servers/test/mcp")
        .auth_bearer("test-token")
        .build()
        .unwrap();

    client.connect().await.unwrap();

    let result = client
        .call_tool("test_tool", json!({"arg": "value"}))
        .await;

    assert!(result.is_ok());
}

#[tokio::test]
#[ignore] // Requires actual server
async fn test_discover() {
    let client = ClientBuilder::new()
        .url("https://gateway.datagrout.ai/servers/test/mcp")
        .auth_bearer("test-token")
        .build()
        .unwrap();

    client.connect().await.unwrap();

    let result = client
        .discover()
        .query("get lead by email")
        .integration("salesforce")
        .limit(10)
        .execute()
        .await;

    assert!(result.is_ok());
}

#[tokio::test]
#[ignore] // Requires actual server
async fn test_guide() {
    let client = ClientBuilder::new()
        .url("https://gateway.datagrout.ai/servers/test/mcp")
        .auth_bearer("test-token")
        .build()
        .unwrap();

    client.connect().await.unwrap();

    let session = client
        .guide()
        .goal("create invoice from lead")
        .execute()
        .await;

    assert!(session.is_ok());

    if let Ok(session) = session {
        assert!(!session.session_id().is_empty());
        assert!(!session.status().is_empty());
    }
}

#[test]
fn test_error_types() {
    use datagrout_conduit::error::{codes, Error};

    let err = Error::mcp(codes::NOT_INITIALIZED, "Not initialized", None);
    assert!(err.is_not_initialized());

    let err = Error::connection("Connection failed");
    assert!(err.is_retriable());

    let err = Error::invalid_config("Bad config");
    assert!(!err.is_retriable());
}

#[test]
fn test_rate_limited_error() {
    use datagrout_conduit::error::{Error, RateLimit};

    // Anonymous visitor hitting the cap
    let err = Error::rate_limited(50, 50);
    assert!(err.is_rate_limited());
    assert!(!err.is_retriable());
    assert!(!err.is_not_initialized());
    assert!(err.to_string().contains("50"));

    // Unlimited variant (authenticated DG users never hit this in practice,
    // but the type should be expressible)
    let err = Error::RateLimited {
        used: 0,
        limit: RateLimit::Unlimited,
    };
    assert!(err.is_rate_limited());
    assert!(err.to_string().contains("unlimited"));
}

#[test]
fn test_rate_limit_enum() {
    use datagrout_conduit::error::RateLimit;

    assert_eq!(RateLimit::Unlimited.to_string(), "unlimited");
    assert_eq!(RateLimit::PerHour(50).to_string(), "50/hour");
    assert_eq!(RateLimit::PerHour(1000).to_string(), "1000/hour");
}
