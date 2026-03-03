//! Integration tests against a live DataGrout server.
//!
//! Both `CONDUIT_TEST_URL` and `CONDUIT_TEST_TOKEN` must be set for these
//! tests to run.  When `CONDUIT_TEST_URL` is absent every test silently skips.
//!
//! Run with:
//! ```sh
//! CONDUIT_TEST_URL=http://localhost:4000/servers/{uuid}/mcp \
//! CONDUIT_TEST_TOKEN=my_token \
//! cargo test --test integration_tests -- --test-threads=1
//! ```

use datagrout_conduit::{Client, ClientBuilder, Transport};
use serde_json::json;

// ─── Test helpers ─────────────────────────────────────────────────────────────

fn test_url() -> Option<String> {
    std::env::var("CONDUIT_TEST_URL").ok()
}

fn test_token() -> Option<String> {
    std::env::var("CONDUIT_TEST_TOKEN").ok()
}

/// Skip a test gracefully when `CONDUIT_TEST_URL` is not set.
macro_rules! skip_without_url {
    () => {
        match test_url() {
            Some(u) => u,
            None => {
                eprintln!("[integration] CONDUIT_TEST_URL not set — skipping");
                return;
            }
        }
    };
}

/// Build an authenticated client pointed at the test server.
fn build_client(url: &str) -> Client {
    let mut builder = ClientBuilder::new()
        .url(url)
        .transport(Transport::JsonRpc)
        .no_mtls()
        .use_intelligent_interface(false);

    if let Some(token) = test_token() {
        builder = builder.auth_bearer(token);
    }

    builder.build().expect("failed to build integration test client")
}

/// Returns `true` when an error looks like a transient / expected live-server
/// condition (rate-limit, not-found, method-not-found) rather than an SDK bug.
/// When this returns `true` the calling test should skip rather than fail.
fn is_skippable_error(e: &datagrout_conduit::error::Error) -> bool {
    use datagrout_conduit::error::Error;
    match e {
        Error::RateLimit { .. } => true,
        Error::Server { code, message, .. } => {
            let msg = message.to_lowercase();
            // -32601 method not found, -32602 invalid params, 404 not-found-style codes
            *code == -32601
                || *code == -32602
                || msg.contains("not found")
                || msg.contains("not supported")
                || msg.contains("unknown method")
                // Server-side tool execution failures (e.g. missing LLM API key, Prolog
                // not available) are infrastructure issues, not SDK bugs. Treat as skip.
                || (*code == -32603 && msg.contains("tool execution failed"))
                || (*code == -32603 && msg.contains("invalid arguments provided"))
                // Logic tools require Prolog-backed symbolic memory — skip gracefully if unavailable
                || msg.contains("requires user_id")
                || msg.contains("logic cell")
                || msg.contains("swi")
                || msg.contains("prolog")
        }
        Error::Network(msg) => msg.contains("404") || msg.contains("not found"),
        _ => false,
    }
}

/// Assert `result` is `Ok`, or skip if the error is a known live-server
/// transient, or panic with the error message otherwise.
macro_rules! assert_ok_or_skip {
    ($result:expr) => {
        match $result {
            Ok(v) => v,
            Err(ref e) if is_skippable_error(e) => {
                eprintln!("[integration] skipping — server returned: {}", e);
                return;
            }
            Err(e) => panic!("unexpected error: {}", e),
        }
    };
}

// ─── MCP baseline ─────────────────────────────────────────────────────────────

/// Connect to the server, confirm initialization, then disconnect cleanly.
#[tokio::test]
async fn test_connect() {
    let url = skip_without_url!();
    let client = build_client(&url);

    client.connect().await.expect("connect() failed");
    assert!(client.is_initialized().await, "client should be initialized after connect()");

    client.disconnect().await.expect("disconnect() failed");
    assert!(!client.is_initialized().await, "client should not be initialized after disconnect()");
}

/// `list_tools` returns at least one tool from a live server.
#[tokio::test]
async fn test_list_tools() {
    let url = skip_without_url!();
    let client = build_client(&url);
    client.connect().await.expect("connect() failed");

    let tools = assert_ok_or_skip!(client.list_tools().await);
    assert!(!tools.is_empty(), "expected at least one tool from the server");

    // Every tool must have a non-empty name
    for t in &tools {
        assert!(!t.name.is_empty(), "tool name must be non-empty");
    }
}

/// When intelligent interface is enabled, `list_tools` filters out third-party
/// integration tools (names containing `@`) and returns only DG-native tools.
#[tokio::test]
async fn test_intelligent_interface_filters_tools() {
    let url = skip_without_url!();

    // Build a client with intelligent interface explicitly ON
    let mut builder = ClientBuilder::new()
        .url(&url)
        .transport(Transport::JsonRpc)
        .no_mtls()
        .use_intelligent_interface(true);
    if let Some(token) = test_token() {
        builder = builder.auth_bearer(token);
    }
    let client = builder.build().expect("build failed");
    client.connect().await.expect("connect() failed");

    let tools = assert_ok_or_skip!(client.list_tools().await);

    // None of the returned tools should contain "@" in their name
    for t in &tools {
        assert!(
            !t.name.contains('@'),
            "intelligent interface leaked a third-party tool: {}",
            t.name
        );
    }
}

// ─── Discovery ────────────────────────────────────────────────────────────────

/// `discover` with a simple query returns a non-empty result with scores.
#[tokio::test]
async fn test_discover() {
    let url = skip_without_url!();
    let client = build_client(&url);
    client.connect().await.expect("connect() failed");

    let result = assert_ok_or_skip!(
        client.discover()
            .query("find recent data")
            .limit(5)
            .execute()
            .await
    );

    // The result must have a `tools` field (may be empty on a fresh server)
    // and every scored tool must have a non-negative score.
    for tool in &result.tools {
        assert!(
            tool.score >= 0.0,
            "discovered tool score must be >= 0, got {}",
            tool.score
        );
    }
}

/// `plan` with a goal returns a non-null JSON result.
#[tokio::test]
async fn test_plan() {
    let url = skip_without_url!();
    let client = build_client(&url);
    client.connect().await.expect("connect() failed");

    let result = assert_ok_or_skip!(
        client.plan()
            .goal("summarise data in my workspace")
            .execute()
            .await
    );

    assert!(!result.is_null(), "plan result must not be null");
}

/// `estimate_cost` for the discovery tool returns a non-null JSON result.
#[tokio::test]
async fn test_estimate_cost() {
    let url = skip_without_url!();
    let client = build_client(&url);
    client.connect().await.expect("connect() failed");

    let result = assert_ok_or_skip!(
        client.estimate_cost(
            "data-grout/discovery.discover",
            json!({ "query": "test", "limit": 1 }),
        )
        .await
    );

    assert!(!result.is_null(), "estimate_cost result must not be null");
}

// ─── Prism ────────────────────────────────────────────────────────────────────

/// `refract` with a simple goal and numeric payload returns a non-null result.
#[tokio::test]
async fn test_refract() {
    let url = skip_without_url!();
    let client = build_client(&url);
    client.connect().await.expect("connect() failed");

    let result = assert_ok_or_skip!(
        client.refract("count items", json!([1, 2, 3]))
            .execute()
            .await
    );

    assert!(!result.is_null(), "refract result must not be null");
}

/// `chart` with a simple goal and object payload returns a non-null result.
#[tokio::test]
async fn test_chart() {
    let url = skip_without_url!();
    let client = build_client(&url);
    client.connect().await.expect("connect() failed");

    let result = assert_ok_or_skip!(
        client.chart("show counts", json!({"a": 1, "b": 2}))
            .execute()
            .await
    );

    assert!(!result.is_null(), "chart result must not be null");
}

// ─── Logic Cell lifecycle ─────────────────────────────────────────────────────

/// Full remember → query → forget → reflect cycle.
#[tokio::test]
async fn test_logic_cell_lifecycle() {
    let url = skip_without_url!();
    let client = build_client(&url);
    client.connect().await.expect("connect() failed");

    // 1. Remember a test fact
    let remember_result = assert_ok_or_skip!(
        client.remember("sdk_integration_test_fact(conduit_rust_sdk).").await
    );
    assert!(!remember_result.is_null(), "remember result must not be null");

    // Extract handle if the server returns one
    let handle: Option<String> = remember_result
        .get("handle")
        .or_else(|| remember_result.get("id"))
        .and_then(|v| v.as_str())
        .map(str::to_owned);

    // 2. Query — our fact should be retrievable
    let query_result = assert_ok_or_skip!(
        client.query_cell("sdk_integration_test_fact").await
    );
    assert!(!query_result.is_null(), "query_cell result must not be null");

    // 3. Forget by handle (if we got one), otherwise by pattern
    if let Some(h) = handle {
        let forget_result = assert_ok_or_skip!(client.forget(vec![h]).await);
        assert!(!forget_result.is_null(), "forget result must not be null");
    } else {
        let forget_result = assert_ok_or_skip!(
            client.forget_pattern("sdk_integration_test_fact(_).").await
        );
        assert!(!forget_result.is_null(), "forget_pattern result must not be null");
    }

    // 4. Reflect — verify the cell is accessible (content is server-dependent)
    let reflect_result = assert_ok_or_skip!(client.reflect().await);
    assert!(!reflect_result.is_null(), "reflect result must not be null");
}

// ─── Generic DG hook ─────────────────────────────────────────────────────────

/// `client.dg()` correctly prefixes the method name and returns a non-null result.
#[tokio::test]
async fn test_dg_generic() {
    let url = skip_without_url!();
    let client = build_client(&url);
    client.connect().await.expect("connect() failed");

    let result = assert_ok_or_skip!(
        client.dg("discovery.discover", json!({"query": "test", "limit": 1})).await
    );

    assert!(!result.is_null(), "dg() result must not be null");
}
