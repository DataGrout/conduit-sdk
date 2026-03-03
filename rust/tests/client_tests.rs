//! Integration tests for Conduit client

use datagrout_conduit::{Client, ClientBuilder, Transport};
use serde_json::json;

// ─── Mockito helpers ──────────────────────────────────────────────────────────

/// Build a mock client pointing at `server_url`.  Uses `Transport::JsonRpc` so
/// that every call is a plain HTTP POST — easy to intercept with mockito.
fn mock_client(server_url: &str) -> Client {
    ClientBuilder::new()
        .url(server_url)
        .transport(Transport::JsonRpc)
        .no_mtls()
        .build()
        .expect("mock client build failed")
}

/// Canonical JSON-RPC initialize response body.
const INIT_BODY: &str = r#"{"jsonrpc":"2.0","id":"1","result":{"protocolVersion":"2025-03-26","serverInfo":{"name":"test-server","version":"1.0"},"capabilities":{}}}"#;

/// A generic success result body with a given `id`.
fn ok_body(id: &str) -> String {
    format!(r#"{{"jsonrpc":"2.0","id":"{}","result":{{"ok":true}}}}"#, id)
}

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

    let err = Error::server(codes::NOT_INITIALIZED, "Not initialized", None);
    assert!(err.is_not_initialized());

    let err = Error::network("Connection failed");
    assert!(err.is_retriable());

    let err = Error::invalid_config("Bad config");
    assert!(!err.is_retriable());
}

#[test]
fn test_rate_limited_error() {
    use datagrout_conduit::error::{Error, RateLimit};

    // Anonymous visitor hitting the cap
    let err = Error::rate_limit(50, 50, None);
    assert!(err.is_rate_limited());
    assert!(!err.is_retriable());
    assert!(!err.is_not_initialized());
    assert!(err.to_string().contains("50"));

    // With retry_after hint
    let err = Error::rate_limit(10, 50, Some(30));
    assert!(err.is_rate_limited());
    match &err {
        Error::RateLimit { retry_after, .. } => assert_eq!(*retry_after, Some(30)),
        _ => panic!("expected RateLimit"),
    }

    // Unlimited variant (authenticated DG users never hit this in practice,
    // but the type should be expressible)
    let err = Error::RateLimit {
        retry_after: None,
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

// ─── plan() tests ─────────────────────────────────────────────────────────────

#[tokio::test]
async fn test_plan_requires_goal_or_query() {
    // `plan()` without goal or query should return InvalidConfig before hitting
    // the network, so no mock server is needed.
    let client = ClientBuilder::new()
        .url("https://gateway.datagrout.ai/servers/test/mcp")
        .transport(Transport::JsonRpc)
        .no_mtls()
        .build()
        .unwrap();

    // Force initialized state would need a real server; instead verify the
    // validation fires while the client is not initialized — the early return
    // path hits the `ensure_initialized` guard first, but we can still exercise
    // the validation by building and checking the builder compiles.
    let builder = client.plan();
    // Calling execute on an uninitialized client returns NotInitialized, which
    // is the expected error at this stage.  The goal/query validation fires
    // after initialization; we test that separately via mockito below.
    let err = builder.execute().await.unwrap_err();
    assert!(
        err.to_string().contains("not initialized") || err.to_string().contains("Session"),
        "unexpected error: {err}"
    );
}

#[tokio::test]
async fn test_plan_validation_goal_or_query_required() {
    let mut server = mockito::Server::new_async().await;

    // Catch-all mock: handles initialize + the initialized notification.
    let _m_init = server
        .mock("POST", "/")
        .with_status(200)
        .with_header("content-type", "application/json")
        .with_body(INIT_BODY)
        .expect_at_least(1)
        .create_async()
        .await;

    let client = mock_client(&server.url());
    client.connect().await.unwrap();

    // Neither goal nor query set → InvalidConfig
    let err = client.plan().execute().await.unwrap_err();
    assert!(
        err.to_string().contains("goal") || err.to_string().contains("query"),
        "expected goal/query validation error, got: {err}"
    );
}

#[tokio::test]
async fn test_plan_sends_correct_method_name() {
    let mut server = mockito::Server::new_async().await;

    // Specific mock for plan calls (registered second → highest priority).
    let m_plan = server
        .mock("POST", "/")
        .match_body(mockito::Matcher::Regex(
            r#"discovery\.plan"#.to_string(),
        ))
        .with_status(200)
        .with_header("content-type", "application/json")
        .with_body(ok_body("3"))
        .create_async()
        .await;

    // Catch-all for initialize + notification (registered first → lower priority).
    let _m_init = server
        .mock("POST", "/")
        .with_status(200)
        .with_header("content-type", "application/json")
        .with_body(INIT_BODY)
        .create_async()
        .await;

    let client = mock_client(&server.url());
    client.connect().await.unwrap();

    let result = client.plan().goal("get all leads").execute().await;
    assert!(result.is_ok(), "plan() failed: {:?}", result.unwrap_err());
    m_plan.assert_async().await;
}

#[tokio::test]
async fn test_plan_builder_params() {
    let mut server = mockito::Server::new_async().await;

    // Verify that k, server, return_call_handles appear in the request body.
    let m_plan = server
        .mock("POST", "/")
        .match_body(mockito::Matcher::AllOf(vec![
            mockito::Matcher::Regex(r#"discovery\.plan"#.to_string()),
            mockito::Matcher::Regex(r#""k"\s*:\s*5"#.to_string()),
            mockito::Matcher::Regex(r#""return_call_handles"\s*:\s*true"#.to_string()),
        ]))
        .with_status(200)
        .with_header("content-type", "application/json")
        .with_body(ok_body("3"))
        .create_async()
        .await;

    let _m_init = server
        .mock("POST", "/")
        .with_status(200)
        .with_header("content-type", "application/json")
        .with_body(INIT_BODY)
        .create_async()
        .await;

    let client = mock_client(&server.url());
    client.connect().await.unwrap();

    let result = client
        .plan()
        .goal("migrate data")
        .k(5)
        .return_call_handles(true)
        .execute()
        .await;

    assert!(result.is_ok(), "plan() with params failed: {:?}", result.unwrap_err());
    m_plan.assert_async().await;
}

// ─── refract() tests ──────────────────────────────────────────────────────────

#[tokio::test]
async fn test_refract_sends_correct_method_name() {
    let mut server = mockito::Server::new_async().await;

    let m_refract = server
        .mock("POST", "/")
        .match_body(mockito::Matcher::Regex(r#"prism\.refract"#.to_string()))
        .with_status(200)
        .with_header("content-type", "application/json")
        .with_body(ok_body("3"))
        .create_async()
        .await;

    let _m_init = server
        .mock("POST", "/")
        .with_status(200)
        .with_header("content-type", "application/json")
        .with_body(INIT_BODY)
        .create_async()
        .await;

    let client = mock_client(&server.url());
    client.connect().await.unwrap();

    let result = client
        .refract("normalise addresses", json!({"city": "NYC"}))
        .execute()
        .await;

    assert!(result.is_ok(), "refract() failed: {:?}", result.unwrap_err());
    m_refract.assert_async().await;
}

#[tokio::test]
async fn test_refract_builder_params() {
    let mut server = mockito::Server::new_async().await;

    let m_refract = server
        .mock("POST", "/")
        .match_body(mockito::Matcher::AllOf(vec![
            mockito::Matcher::Regex(r#"prism\.refract"#.to_string()),
            mockito::Matcher::Regex(r#""verbose"\s*:\s*true"#.to_string()),
            mockito::Matcher::Regex(r#""chart"\s*:\s*true"#.to_string()),
        ]))
        .with_status(200)
        .with_header("content-type", "application/json")
        .with_body(ok_body("3"))
        .create_async()
        .await;

    let _m_init = server
        .mock("POST", "/")
        .with_status(200)
        .with_header("content-type", "application/json")
        .with_body(INIT_BODY)
        .create_async()
        .await;

    let client = mock_client(&server.url());
    client.connect().await.unwrap();

    let result = client
        .refract("categorise products", json!({"items": []}))
        .verbose(true)
        .chart(true)
        .execute()
        .await;

    assert!(result.is_ok(), "refract() with params failed: {:?}", result.unwrap_err());
    m_refract.assert_async().await;
}

// ─── chart() tests ────────────────────────────────────────────────────────────

#[tokio::test]
async fn test_chart_sends_correct_method_name() {
    let mut server = mockito::Server::new_async().await;

    let m_chart = server
        .mock("POST", "/")
        .match_body(mockito::Matcher::Regex(r#"prism\.chart"#.to_string()))
        .with_status(200)
        .with_header("content-type", "application/json")
        .with_body(ok_body("3"))
        .create_async()
        .await;

    let _m_init = server
        .mock("POST", "/")
        .with_status(200)
        .with_header("content-type", "application/json")
        .with_body(INIT_BODY)
        .create_async()
        .await;

    let client = mock_client(&server.url());
    client.connect().await.unwrap();

    let result = client
        .chart("sales by region", json!({"rows": []}))
        .execute()
        .await;

    assert!(result.is_ok(), "chart() failed: {:?}", result.unwrap_err());
    m_chart.assert_async().await;
}

#[tokio::test]
async fn test_chart_builder_params() {
    let mut server = mockito::Server::new_async().await;

    let m_chart = server
        .mock("POST", "/")
        .match_body(mockito::Matcher::AllOf(vec![
            mockito::Matcher::Regex(r#"prism\.chart"#.to_string()),
            mockito::Matcher::Regex(r#""chart_type"\s*:\s*"bar""#.to_string()),
            mockito::Matcher::Regex(r#""width"\s*:\s*800"#.to_string()),
        ]))
        .with_status(200)
        .with_header("content-type", "application/json")
        .with_body(ok_body("3"))
        .create_async()
        .await;

    let _m_init = server
        .mock("POST", "/")
        .with_status(200)
        .with_header("content-type", "application/json")
        .with_body(INIT_BODY)
        .create_async()
        .await;

    let client = mock_client(&server.url());
    client.connect().await.unwrap();

    let result = client
        .chart("revenue over time", json!({"series": []}))
        .chart_type("bar")
        .title("Revenue")
        .x_label("Month")
        .y_label("USD")
        .width(800)
        .height(400)
        .format("svg")
        .execute()
        .await;

    assert!(result.is_ok(), "chart() with params failed: {:?}", result.unwrap_err());
    m_chart.assert_async().await;
}

// ─── Logic cell tests ─────────────────────────────────────────────────────────

#[tokio::test]
async fn test_remember_sends_correct_method_name() {
    let mut server = mockito::Server::new_async().await;

    let m = server
        .mock("POST", "/")
        .match_body(mockito::Matcher::Regex(r#"logic\.remember"#.to_string()))
        .with_status(200)
        .with_header("content-type", "application/json")
        .with_body(ok_body("3"))
        .create_async()
        .await;

    let _m_init = server
        .mock("POST", "/")
        .with_status(200)
        .with_header("content-type", "application/json")
        .with_body(INIT_BODY)
        .create_async()
        .await;

    let client = mock_client(&server.url());
    client.connect().await.unwrap();

    let result = client.remember("user(alice).").await;
    assert!(result.is_ok(), "remember() failed: {:?}", result.unwrap_err());
    m.assert_async().await;
}

#[tokio::test]
async fn test_query_cell_sends_correct_method_name() {
    let mut server = mockito::Server::new_async().await;

    let m = server
        .mock("POST", "/")
        .match_body(mockito::Matcher::Regex(r#"logic\.query"#.to_string()))
        .with_status(200)
        .with_header("content-type", "application/json")
        .with_body(ok_body("3"))
        .create_async()
        .await;

    let _m_init = server
        .mock("POST", "/")
        .with_status(200)
        .with_header("content-type", "application/json")
        .with_body(INIT_BODY)
        .create_async()
        .await;

    let client = mock_client(&server.url());
    client.connect().await.unwrap();

    let result = client.query_cell("who are the users?").await;
    assert!(result.is_ok(), "query_cell() failed: {:?}", result.unwrap_err());
    m.assert_async().await;
}

#[tokio::test]
async fn test_forget_sends_correct_method_name() {
    let mut server = mockito::Server::new_async().await;

    let m = server
        .mock("POST", "/")
        .match_body(mockito::Matcher::Regex(r#"logic\.forget"#.to_string()))
        .with_status(200)
        .with_header("content-type", "application/json")
        .with_body(ok_body("3"))
        .create_async()
        .await;

    let _m_init = server
        .mock("POST", "/")
        .with_status(200)
        .with_header("content-type", "application/json")
        .with_body(INIT_BODY)
        .create_async()
        .await;

    let client = mock_client(&server.url());
    client.connect().await.unwrap();

    let result = client.forget(vec!["fact_abc".to_string()]).await;
    assert!(result.is_ok(), "forget() failed: {:?}", result.unwrap_err());
    m.assert_async().await;
}

#[tokio::test]
async fn test_constrain_sends_correct_method_name() {
    let mut server = mockito::Server::new_async().await;

    let m = server
        .mock("POST", "/")
        .match_body(mockito::Matcher::Regex(r#"logic\.constrain"#.to_string()))
        .with_status(200)
        .with_header("content-type", "application/json")
        .with_body(ok_body("3"))
        .create_async()
        .await;

    let _m_init = server
        .mock("POST", "/")
        .with_status(200)
        .with_header("content-type", "application/json")
        .with_body(INIT_BODY)
        .create_async()
        .await;

    let client = mock_client(&server.url());
    client.connect().await.unwrap();

    let result = client.constrain("cost(X) :- X > 100.").await;
    assert!(result.is_ok(), "constrain() failed: {:?}", result.unwrap_err());
    m.assert_async().await;
}

#[tokio::test]
async fn test_reflect_sends_correct_method_name() {
    let mut server = mockito::Server::new_async().await;

    let m = server
        .mock("POST", "/")
        .match_body(mockito::Matcher::Regex(r#"logic\.reflect"#.to_string()))
        .with_status(200)
        .with_header("content-type", "application/json")
        .with_body(ok_body("3"))
        .create_async()
        .await;

    let _m_init = server
        .mock("POST", "/")
        .with_status(200)
        .with_header("content-type", "application/json")
        .with_body(INIT_BODY)
        .create_async()
        .await;

    let client = mock_client(&server.url());
    client.connect().await.unwrap();

    let result = client.reflect().await;
    assert!(result.is_ok(), "reflect() failed: {:?}", result.unwrap_err());
    m.assert_async().await;
}

// ─── dg() generic hook tests ──────────────────────────────────────────────────

#[tokio::test]
async fn test_dg_prefixes_method_name() {
    let mut server = mockito::Server::new_async().await;

    // Must match the full prefixed method name.
    let m = server
        .mock("POST", "/")
        .match_body(mockito::Matcher::Regex(
            r#"data-grout/prism\.render"#.to_string(),
        ))
        .with_status(200)
        .with_header("content-type", "application/json")
        .with_body(ok_body("3"))
        .create_async()
        .await;

    let _m_init = server
        .mock("POST", "/")
        .with_status(200)
        .with_header("content-type", "application/json")
        .with_body(INIT_BODY)
        .create_async()
        .await;

    let client = mock_client(&server.url());
    client.connect().await.unwrap();

    let result = client.dg("prism.render", json!({})).await;
    assert!(result.is_ok(), "dg() failed: {:?}", result.unwrap_err());
    m.assert_async().await;
}

#[tokio::test]
async fn test_dg_arbitrary_tool_name() {
    let mut server = mockito::Server::new_async().await;

    let m = server
        .mock("POST", "/")
        .match_body(mockito::Matcher::Regex(
            r#"data-grout/logic\.query"#.to_string(),
        ))
        .with_status(200)
        .with_header("content-type", "application/json")
        .with_body(ok_body("3"))
        .create_async()
        .await;

    let _m_init = server
        .mock("POST", "/")
        .with_status(200)
        .with_header("content-type", "application/json")
        .with_body(INIT_BODY)
        .create_async()
        .await;

    let client = mock_client(&server.url());
    client.connect().await.unwrap();

    let result = client
        .dg("logic.query", json!({"question": "who are the admins?"}))
        .await;
    assert!(result.is_ok(), "dg(logic.query) failed: {:?}", result.unwrap_err());
    m.assert_async().await;
}
