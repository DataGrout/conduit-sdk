//! Tests for transport hardening: SSE parsing, session-id tracking, 202 Accepted

use datagrout_conduit::parse_sse_body;
use datagrout_conduit::transport::{AuthConfig, McpTransport, TransportTrait};
use serde_json::json;

// ─── SSE parsing ────────────────────────────────────────────────────────────

#[test]
fn test_parse_sse_single_event() {
    let body = "event: message\ndata: {\"jsonrpc\":\"2.0\",\"id\":\"1\",\"result\":{\"ok\":true}}\n\n";
    let resp = parse_sse_body(body).unwrap();
    assert_eq!(resp.id, "1");
    assert_eq!(resp.result.unwrap(), json!({"ok": true}));
    assert!(resp.error.is_none());
}

#[test]
fn test_parse_sse_multiple_events_returns_last() {
    let body = "\
event: message\n\
data: {\"jsonrpc\":\"2.0\",\"id\":\"1\",\"result\":{\"step\":1}}\n\
\n\
event: message\n\
data: {\"jsonrpc\":\"2.0\",\"id\":\"1\",\"result\":{\"step\":2}}\n\
\n";
    let resp = parse_sse_body(body).unwrap();
    assert_eq!(resp.result.unwrap(), json!({"step": 2}));
}

#[test]
fn test_parse_sse_data_no_space_after_colon() {
    let body = "data:{\"jsonrpc\":\"2.0\",\"id\":\"42\",\"result\":null}\n\n";
    let resp = parse_sse_body(body).unwrap();
    assert_eq!(resp.id, "42");
}

#[test]
fn test_parse_sse_ignores_non_data_lines() {
    let body = "event: message\nid: 7\nretry: 3000\ndata: {\"jsonrpc\":\"2.0\",\"id\":\"1\",\"result\":\"ok\"}\n\n";
    let resp = parse_sse_body(body).unwrap();
    assert_eq!(resp.result.unwrap(), json!("ok"));
}

#[test]
fn test_parse_sse_empty_body_errors() {
    let result = parse_sse_body("");
    assert!(result.is_err());
    let err = result.unwrap_err().to_string();
    assert!(err.contains("No JSON-RPC message"));
}

#[test]
fn test_parse_sse_non_json_data_lines_skipped() {
    let body = "data: not-json\n\ndata: {\"jsonrpc\":\"2.0\",\"id\":\"1\",\"result\":42}\n\n";
    let resp = parse_sse_body(body).unwrap();
    assert_eq!(resp.result.unwrap(), json!(42));
}

// ─── 202 Accepted handling ──────────────────────────────────────────────────

#[tokio::test]
async fn test_202_accepted_returns_null_result() {
    let mut server = mockito::Server::new_async().await;
    let mock = server
        .mock("POST", "/mcp")
        .with_status(202)
        .create_async()
        .await;

    let mut transport =
        McpTransport::new(format!("{}/mcp", server.url()), AuthConfig::None).unwrap();
    transport.connect().await.unwrap();

    let request = datagrout_conduit::protocol::JsonRpcRequest::notification(
        "notifications/initialized",
        None,
    );
    let resp = transport.send_request(request).await.unwrap();

    assert!(resp.error.is_none());
    assert_eq!(resp.result, Some(serde_json::Value::Null));
    mock.assert_async().await;
}

// ─── Session ID tracking ────────────────────────────────────────────────────

#[tokio::test]
async fn test_session_id_captured_and_sent() {
    let mut server = mockito::Server::new_async().await;

    let first_response = json!({
        "jsonrpc": "2.0",
        "id": "1",
        "result": {"protocolVersion": "2025-03-26", "capabilities": {}, "serverInfo": {"name": "test", "version": "1"}}
    });

    let first = server
        .mock("POST", "/mcp")
        .with_status(200)
        .with_header("content-type", "application/json")
        .with_header("mcp-session-id", "sess_abc123")
        .with_body(first_response.to_string())
        .create_async()
        .await;

    let second_response = json!({
        "jsonrpc": "2.0",
        "id": "2",
        "result": {"tools": [], "nextCursor": null}
    });

    let second = server
        .mock("POST", "/mcp")
        .match_header("Mcp-Session-Id", "sess_abc123")
        .with_status(200)
        .with_header("content-type", "application/json")
        .with_body(second_response.to_string())
        .create_async()
        .await;

    let mut transport =
        McpTransport::new(format!("{}/mcp", server.url()), AuthConfig::None).unwrap();
    transport.connect().await.unwrap();

    let req1 = datagrout_conduit::protocol::JsonRpcRequest::new(
        "1".into(),
        "initialize",
        Some(json!({})),
    );
    let _ = transport.send_request(req1).await.unwrap();
    first.assert_async().await;

    let req2 = datagrout_conduit::protocol::JsonRpcRequest::new(
        "2".into(),
        "tools/list",
        Some(json!({})),
    );
    let _ = transport.send_request(req2).await.unwrap();
    second.assert_async().await;
}

// ─── SSE content-type dispatching via mock server ───────────────────────────

#[tokio::test]
async fn test_sse_content_type_parsed() {
    let mut server = mockito::Server::new_async().await;

    let sse_body = "event: message\ndata: {\"jsonrpc\":\"2.0\",\"id\":\"1\",\"result\":{\"sse\":true}}\n\n";

    let mock = server
        .mock("POST", "/mcp")
        .with_status(200)
        .with_header("content-type", "text/event-stream")
        .with_body(sse_body)
        .create_async()
        .await;

    let mut transport =
        McpTransport::new(format!("{}/mcp", server.url()), AuthConfig::None).unwrap();
    transport.connect().await.unwrap();

    let request = datagrout_conduit::protocol::JsonRpcRequest::new(
        "1".into(),
        "test",
        None,
    );
    let resp = transport.send_request(request).await.unwrap();

    assert_eq!(resp.result.unwrap(), json!({"sse": true}));
    mock.assert_async().await;
}

// ─── Accept header verification ────────────────────────────────────────────

#[tokio::test]
async fn test_accept_header_sent() {
    let mut server = mockito::Server::new_async().await;

    let response = json!({"jsonrpc": "2.0", "id": "1", "result": null});

    let mock = server
        .mock("POST", "/mcp")
        .match_header("accept", "application/json, text/event-stream")
        .with_status(200)
        .with_header("content-type", "application/json")
        .with_body(response.to_string())
        .create_async()
        .await;

    let mut transport =
        McpTransport::new(format!("{}/mcp", server.url()), AuthConfig::None).unwrap();
    transport.connect().await.unwrap();

    let request = datagrout_conduit::protocol::JsonRpcRequest::new(
        "1".into(),
        "test",
        None,
    );
    let _ = transport.send_request(request).await.unwrap();
    mock.assert_async().await;
}
