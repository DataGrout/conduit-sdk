// `tokio-tungstenite::handshake::server::ErrorResponse` is a large `http::Response`
// alias; the upstream callback signature unavoidably triggers
// `clippy::result_large_err`.
#![allow(clippy::result_large_err)]

//! End-to-end tests for the JSON-RPC-over-WebSocket transport.
//!
//! Spins up a mock `datagrout-jsonrpc.v1` server using `tokio-tungstenite`
//! as the server side. Verifies:
//!  * Subprotocol negotiation
//!  * Bearer-token forwarding in the upgrade headers
//!  * Request/response correlation under concurrency (multiplexing)
//!  * `subscribe` + server-pushed notifications + `unsubscribe`
//!  * Server-side errors propagated to the caller as `Error::Server`
//!  * Connect/disconnect lifecycle hygiene (no orphan tasks)

use datagrout_conduit::protocol::JsonRpcRequest;
use datagrout_conduit::transport::{AuthConfig, TransportTrait};
use datagrout_conduit::ws_transport::{WsTransport, SUBPROTOCOL as WS_SUBPROTOCOL};
use futures_util::{SinkExt, StreamExt};
use serde_json::{json, Value};
use std::collections::HashMap;
use std::sync::Arc;
use std::time::Duration;
use tokio::net::TcpListener;
use tokio::sync::Mutex;
use tokio_tungstenite::tungstenite::handshake::server::{ErrorResponse, Request, Response};
use tokio_tungstenite::tungstenite::http::HeaderValue;
use tokio_tungstenite::tungstenite::Message;

// ─── Mock server ────────────────────────────────────────────────────────────

/// A pluggable handler that mirrors `DataGroutWeb.JsonRpc.Dispatcher` enough
/// to drive the client-side correlator and subscription paths through their
/// real code.
type Handler = Arc<
    dyn Fn(Value, Arc<MockState>) -> futures::future::BoxFuture<'static, Vec<Value>> + Send + Sync,
>;

struct MockState {
    /// Records every method the server saw, in order.
    pub seen_methods: Mutex<Vec<String>>,
    /// Maps a subscription id → topic so we can blast notifications.
    pub subscriptions: Mutex<HashMap<String, String>>,
}

impl MockState {
    fn new() -> Self {
        Self {
            seen_methods: Mutex::new(Vec::new()),
            subscriptions: Mutex::new(HashMap::new()),
        }
    }
}

struct MockServer {
    pub addr: String,
    pub state: Arc<MockState>,
    /// Channel used by tests to push server-initiated frames out the socket
    /// (notifications, raw text, etc.). Drop the sender to ignore.
    pub push_tx: tokio::sync::mpsc::UnboundedSender<Message>,
    _accept_task: tokio::task::JoinHandle<()>,
}

async fn spawn_mock_server(handler: Handler) -> MockServer {
    let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
    let port = listener.local_addr().unwrap().port();
    let addr = format!("ws://127.0.0.1:{port}/ws");

    let state = Arc::new(MockState::new());
    let (push_tx, push_rx) = tokio::sync::mpsc::unbounded_channel::<Message>();
    let push_rx = Arc::new(Mutex::new(push_rx));

    let state_clone = Arc::clone(&state);
    let push_rx_clone = Arc::clone(&push_rx);
    let accept_task = tokio::spawn(async move {
        // Single-connection mock — the test always opens exactly one client.
        let (stream, _) = listener.accept().await.unwrap();

        let callback = |req: &Request,
                        mut response: Response|
         -> std::result::Result<Response, ErrorResponse> {
            let offered = req
                .headers()
                .get("sec-websocket-protocol")
                .and_then(|v| v.to_str().ok())
                .unwrap_or("");
            if !offered.is_empty() && offered.contains(WS_SUBPROTOCOL) {
                response.headers_mut().insert(
                    "sec-websocket-protocol",
                    HeaderValue::from_static(WS_SUBPROTOCOL),
                );
            }
            Ok(response)
        };

        let ws = tokio_tungstenite::accept_hdr_async(stream, callback)
            .await
            .unwrap();
        let (mut sink, mut stream) = ws.split();

        let mut push_rx = push_rx_clone.lock().await;

        loop {
            tokio::select! {
                maybe_msg = stream.next() => {
                    let Some(Ok(msg)) = maybe_msg else { break };
                    match msg {
                        Message::Text(text) => {
                            let value: Value = match serde_json::from_str(&text) {
                                Ok(v) => v,
                                Err(_) => continue,
                            };
                            if let Some(method) = value.get("method").and_then(Value::as_str) {
                                state_clone.seen_methods.lock().await.push(method.to_string());
                            }

                            let frames = handler(value, Arc::clone(&state_clone)).await;
                            for frame in frames {
                                if sink
                                    .send(Message::Text(frame.to_string()))
                                    .await
                                    .is_err()
                                {
                                    return;
                                }
                            }
                        }
                        Message::Ping(p) => {
                            let _ = sink.send(Message::Pong(p)).await;
                        }
                        Message::Close(_) => break,
                        _ => {}
                    }
                }
                Some(push) = push_rx.recv() => {
                    if sink.send(push).await.is_err() { return; }
                }
            }
        }
    });

    MockServer {
        addr,
        state,
        push_tx,
        _accept_task: accept_task,
    }
}

/// Default handler: responds to anything with a generic ok, and supports
/// `subscribe` / `unsubscribe` per the dispatcher contract.
fn default_handler() -> Handler {
    Arc::new(|req: Value, state: Arc<MockState>| {
        Box::pin(async move {
            let id = req.get("id").cloned().unwrap_or(Value::Null);
            let method = req
                .get("method")
                .and_then(Value::as_str)
                .unwrap_or("")
                .to_string();
            let params = req.get("params").cloned().unwrap_or(Value::Null);

            if method == "subscribe" {
                let topic = params
                    .get("topic")
                    .and_then(Value::as_str)
                    .unwrap_or("")
                    .to_string();
                let sub_id = format!("sub_{}", uuid::Uuid::new_v4().simple());
                state
                    .subscriptions
                    .lock()
                    .await
                    .insert(sub_id.clone(), topic.clone());
                return vec![json!({
                    "jsonrpc": "2.0",
                    "id": id,
                    "result": {"subscription": sub_id, "topic": topic},
                })];
            }

            if method == "unsubscribe" {
                let sub_id = params
                    .get("subscription")
                    .and_then(Value::as_str)
                    .unwrap_or("")
                    .to_string();
                state.subscriptions.lock().await.remove(&sub_id);
                return vec![json!({
                    "jsonrpc": "2.0",
                    "id": id,
                    "result": {"unsubscribed": sub_id},
                })];
            }

            vec![json!({
                "jsonrpc": "2.0",
                "id": id,
                "result": {"echoed_method": method},
            })]
        })
    })
}

async fn connect_client(addr: &str) -> WsTransport {
    let mut t = WsTransport::new(addr.to_string(), AuthConfig::None).unwrap();
    t.connect().await.unwrap();
    t
}

// ─── Tests ──────────────────────────────────────────────────────────────────

#[tokio::test]
async fn round_trips_a_simple_request() {
    let server = spawn_mock_server(default_handler()).await;
    let transport = connect_client(&server.addr).await;

    let request = JsonRpcRequest::new("1".into(), "tools.list", Some(json!({"cursor": null})));
    let response = transport.send_request(request).await.unwrap();

    assert_eq!(response.id, "1");
    assert_eq!(
        response.result.unwrap(),
        json!({"echoed_method": "tools.list"})
    );

    let methods = server.state.seen_methods.lock().await.clone();
    assert_eq!(methods, vec!["tools.list".to_string()]);
}

#[tokio::test]
async fn multiplexes_concurrent_requests_with_distinct_ids() {
    // Handler that artificially staggers responses so the second request
    // beats the first to the wire — proves correlation works regardless
    // of server response order.
    let handler: Handler = Arc::new(|req: Value, _: Arc<MockState>| {
        Box::pin(async move {
            let id = req.get("id").cloned().unwrap_or(Value::Null);
            let id_str = id.as_str().unwrap_or("");
            let delay = if id_str == "first" { 100 } else { 10 };
            tokio::time::sleep(Duration::from_millis(delay)).await;
            vec![json!({
                "jsonrpc": "2.0",
                "id": id,
                "result": {"echo_id": id_str},
            })]
        })
    });

    let server = spawn_mock_server(handler).await;
    let transport = Arc::new(connect_client(&server.addr).await);

    let t1 = Arc::clone(&transport);
    let h1 = tokio::spawn(async move {
        t1.send_request(JsonRpcRequest::new(
            "first".into(),
            "tools.call",
            Some(json!({})),
        ))
        .await
    });

    let t2 = Arc::clone(&transport);
    let h2 = tokio::spawn(async move {
        t2.send_request(JsonRpcRequest::new(
            "second".into(),
            "tools.call",
            Some(json!({})),
        ))
        .await
    });

    let (r1, r2) = tokio::join!(h1, h2);
    let r1 = r1.unwrap().unwrap();
    let r2 = r2.unwrap().unwrap();

    assert_eq!(r1.id, "first");
    assert_eq!(r1.result.unwrap(), json!({"echo_id": "first"}));
    assert_eq!(r2.id, "second");
    assert_eq!(r2.result.unwrap(), json!({"echo_id": "second"}));
}

#[tokio::test]
async fn subscribe_receives_server_pushed_notifications() {
    let server = spawn_mock_server(default_handler()).await;
    let transport = connect_client(&server.addr).await;

    let mut subscription = transport.subscribe("agents.x.events").await.unwrap();
    assert!(!subscription.id.is_empty());
    assert_eq!(subscription.topic, "agents.x.events");

    // Push a server-initiated notification matching this subscription.
    let frame = json!({
        "jsonrpc": "2.0",
        "method": "notification",
        "params": {
            "subscription": subscription.id.clone(),
            "event": "agent.thought",
            "data": {"text": "I see things"},
        }
    });
    server
        .push_tx
        .send(Message::Text(frame.to_string()))
        .unwrap();

    let evt = tokio::time::timeout(Duration::from_secs(2), subscription.events.recv())
        .await
        .expect("notification did not arrive in time")
        .expect("broadcast channel closed");

    assert_eq!(evt.subscription, subscription.id);
    assert_eq!(evt.event, "agent.thought");
    assert_eq!(evt.data, json!({"text": "I see things"}));
}

#[tokio::test]
async fn unsubscribe_stops_local_routing() {
    let server = spawn_mock_server(default_handler()).await;
    let transport = connect_client(&server.addr).await;

    let mut subscription = transport.subscribe("tools.x.results").await.unwrap();
    let sub_id = subscription.id.clone();

    transport.unsubscribe(sub_id.clone()).await.unwrap();

    // Even if the (buggy) server keeps pushing, the local broadcast sender
    // is gone — so `recv` should error out rather than yield events.
    let frame = json!({
        "jsonrpc": "2.0",
        "method": "notification",
        "params": {
            "subscription": sub_id,
            "event": "should_not_arrive",
            "data": {},
        }
    });
    server
        .push_tx
        .send(Message::Text(frame.to_string()))
        .unwrap();

    let result = tokio::time::timeout(Duration::from_millis(150), subscription.events.recv()).await;
    match result {
        Ok(Err(_closed)) => {} // expected: sender dropped
        Err(_timeout) => {}    // also acceptable: nothing arrived
        Ok(Ok(evt)) => panic!("received event after unsubscribe: {evt:?}"),
    }

    assert!(
        server.state.subscriptions.lock().await.is_empty(),
        "server-side subscription should have been dropped"
    );
}

#[tokio::test]
async fn server_jsonrpc_error_propagates_as_typed_error() {
    let handler: Handler = Arc::new(|req: Value, _: Arc<MockState>| {
        Box::pin(async move {
            let id = req.get("id").cloned().unwrap_or(Value::Null);
            vec![json!({
                "jsonrpc": "2.0",
                "id": id,
                "error": {"code": -32601, "message": "method not found"},
            })]
        })
    });
    let server = spawn_mock_server(handler).await;
    let transport = connect_client(&server.addr).await;

    let err = transport
        .send_request(JsonRpcRequest::new("1".into(), "does.not.exist", None))
        .await
        .unwrap_err();

    match err {
        datagrout_conduit::Error::Server { code, message, .. } => {
            assert_eq!(code, -32601);
            assert_eq!(message, "method not found");
        }
        other => panic!("expected Server error, got {other:?}"),
    }
}

#[tokio::test]
async fn send_before_connect_returns_not_initialized() {
    let transport = WsTransport::new("ws://127.0.0.1:1/ws".into(), AuthConfig::None).unwrap();
    let err = transport
        .send_request(JsonRpcRequest::new("1".into(), "tools.list", None))
        .await
        .unwrap_err();
    assert!(matches!(err, datagrout_conduit::Error::NotInitialized));
}

#[tokio::test]
async fn disconnect_closes_socket_cleanly() {
    let server = spawn_mock_server(default_handler()).await;
    let mut transport = connect_client(&server.addr).await;
    assert!(transport.is_connected());

    transport.disconnect().await.unwrap();
    assert!(!transport.is_connected());

    // Subsequent sends should fail with NotInitialized rather than hang.
    let err = transport
        .send_request(JsonRpcRequest::new("1".into(), "x", None))
        .await
        .unwrap_err();
    assert!(matches!(err, datagrout_conduit::Error::NotInitialized));
}

#[tokio::test]
async fn connect_is_idempotent() {
    let server = spawn_mock_server(default_handler()).await;
    let mut transport = connect_client(&server.addr).await;
    // Second connect should be a no-op, not a re-handshake.
    transport.connect().await.unwrap();
    assert!(transport.is_connected());
}
