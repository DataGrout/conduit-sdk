//! WebSocket transport for `datagrout-jsonrpc.v1`.
//!
//! This is the recommended transport for any client that wants bidirectional
//! push (server-initiated notifications) without a polling loop:
//!
//!  * Tool calls and metadata methods (`tools.call`, `tools.list`, `tools.get`)
//!    multiplexed over a single mTLS connection.
//!  * `subscribe` / `unsubscribe` to dotted-namespace topics
//!    (`agents.<agent_id>.events`, `tools.<tool>.results`, `tasks.<task_id>.*`,
//!    `flows.<flow_id>.*`, `governor.<server_uuid>`).
//!  * Server pushes `{"method":"notification", params: { subscription, event,
//!    data }}` JSON-RPC notifications; subscribers receive them via a
//!    Tokio broadcast channel.
//!
//! ## Wire protocol
//!
//! - Subprotocol: `datagrout-jsonrpc.v1`
//! - Frame body: JSON-RPC 2.0 (text frames only; binary frames are rejected)
//! - Connect URL: `wss://<gateway>/servers/<uuid>/ws`
//! - mTLS: client cert presented at TLS handshake (same identity as HTTP)
//!
//! ## Reconnection
//!
//! Reconnect is **caller-driven** for v1 — when [`WsTransport::send_request`]
//! sees a closed connection it returns [`Error::NotInitialized`] and the
//! caller should call [`connect`](TransportTrait::connect) again. Active
//! subscriptions do **not** survive reconnects (the server clears them on
//! disconnect); callers must re-issue `subscribe` after reconnecting. A
//! supervised auto-reconnecting wrapper is on the roadmap.

use crate::error::{Error, Result};
use crate::identity::ConduitIdentity;
use crate::protocol::{JsonRpcRequest, JsonRpcResponse};
use crate::transport::{AuthConfig, TransportTrait};

use async_trait::async_trait;
use base64::{engine::general_purpose, Engine as _};
use futures_util::{sink::SinkExt, stream::StreamExt};
use serde_json::Value;
use std::collections::HashMap;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Arc;
use std::time::Duration;
use tokio::sync::{broadcast, mpsc, oneshot, Mutex};
use tokio::task::JoinHandle;
use tokio_tungstenite::tungstenite::{
    client::IntoClientRequest,
    handshake::client::Request as WsRequest,
    http::header::{HeaderName, HeaderValue, AUTHORIZATION, SEC_WEBSOCKET_PROTOCOL},
    Message,
};
use tokio_tungstenite::Connector;

/// Subprotocol identifier negotiated during the WS handshake.
pub const SUBPROTOCOL: &str = "datagrout-jsonrpc.v1";

/// Default channel capacity for a single subscription's broadcast queue.
const SUBSCRIPTION_BUFFER: usize = 256;

/// Default capacity for the outbound frame queue.
const OUTBOUND_BUFFER: usize = 64;

// ─── Public types ───────────────────────────────────────────────────────────

/// A live subscription handle. Drop to leave the local broadcast channel
/// (the server-side subscription is unaffected; call
/// [`WsTransport::unsubscribe`] to actually stop server-side fan-out).
#[derive(Debug)]
pub struct Subscription {
    /// The server-issued subscription id (unique within this connection).
    pub id: String,
    /// The dotted topic this subscription was opened for.
    pub topic: String,
    /// Receiver fed by the connection task whenever the server pushes a
    /// notification matching this subscription.
    pub events: broadcast::Receiver<NotificationEvent>,
}

/// A single server-pushed notification.
#[derive(Debug, Clone)]
pub struct NotificationEvent {
    /// The subscription id this event belongs to.
    pub subscription: String,
    /// Server-named event slug (e.g. `"agent.thought"`).
    pub event: String,
    /// Free-form payload from the server.
    pub data: Value,
}

// ─── Internal control protocol ──────────────────────────────────────────────

/// Messages the transport task accepts from `send_request` /
/// `subscribe` / `unsubscribe`.
enum Control {
    /// Send an arbitrary JSON-RPC request and route the matching response
    /// back through the oneshot.
    Send {
        request: JsonRpcRequest,
        responder: oneshot::Sender<Result<JsonRpcResponse>>,
    },
    /// Send a `subscribe` request, register the broadcast channel under the
    /// returned `subscription` id, and hand the subscription back.
    Subscribe {
        topic: String,
        responder: oneshot::Sender<Result<Subscription>>,
    },
    /// Send an `unsubscribe` request and drop the local broadcast channel
    /// for that id.
    Unsubscribe {
        subscription_id: String,
        responder: oneshot::Sender<Result<()>>,
    },
    /// Stop the connection task cleanly (sent on `disconnect`).
    Shutdown,
}

/// Shared state holding the pending request map and active subscriptions.
/// The connection task owns the mutexes; callers never touch this directly.
struct ConnectionState {
    pending: HashMap<String, oneshot::Sender<Result<JsonRpcResponse>>>,
    pending_subscribe: HashMap<String, (String, oneshot::Sender<Result<Subscription>>)>,
    subscriptions: HashMap<String, broadcast::Sender<NotificationEvent>>,
}

impl ConnectionState {
    fn new() -> Self {
        Self {
            pending: HashMap::new(),
            pending_subscribe: HashMap::new(),
            subscriptions: HashMap::new(),
        }
    }
}

// ─── Transport ──────────────────────────────────────────────────────────────

/// JSON-RPC 2.0 over WebSocket transport.
///
/// Multiplexes any number of in-flight requests on one socket and routes
/// server-pushed notifications back to subscribers via Tokio broadcast
/// channels. See module docs for protocol details.
#[derive(Debug)]
pub struct WsTransport {
    url: String,
    auth: AuthConfig,
    identity: Option<ConduitIdentity>,
    connected: Arc<AtomicBool>,
    next_id: Arc<std::sync::atomic::AtomicU64>,
    control_tx: Mutex<Option<mpsc::Sender<Control>>>,
    task_handle: Mutex<Option<JoinHandle<()>>>,
}

impl WsTransport {
    /// Create a new WebSocket transport without mTLS.
    pub fn new(url: String, auth: AuthConfig) -> Result<Self> {
        Self::with_identity(url, auth, None)
    }

    /// Create a new WebSocket transport, optionally presenting a client
    /// certificate at the TLS handshake.
    pub fn with_identity(
        url: String,
        auth: AuthConfig,
        identity: Option<&ConduitIdentity>,
    ) -> Result<Self> {
        // Validate URL scheme up front so misconfigured callers get a clear
        // error instead of a TLS-layer panic later.
        let parsed = url::Url::parse(&url).map_err(|e| Error::invalid_url(e.to_string()))?;
        match parsed.scheme() {
            "ws" | "wss" => {}
            other => {
                return Err(Error::invalid_url(format!(
                    "WS transport requires ws:// or wss://, got {other}"
                )))
            }
        }

        Ok(Self {
            url,
            auth,
            identity: identity.cloned(),
            connected: Arc::new(AtomicBool::new(false)),
            next_id: Arc::new(std::sync::atomic::AtomicU64::new(1)),
            control_tx: Mutex::new(None),
            task_handle: Mutex::new(None),
        })
    }

    /// Subscribe to a dotted-namespace topic.
    ///
    /// The returned [`Subscription`] holds a `broadcast::Receiver` that fires
    /// every time the server pushes an event matching this subscription.
    /// The transport keeps the underlying broadcast sender alive for as long
    /// as the subscription is registered.
    pub async fn subscribe(&self, topic: impl Into<String>) -> Result<Subscription> {
        let topic = topic.into();
        let tx = self.require_control().await?;
        let (responder, rx) = oneshot::channel();
        tx.send(Control::Subscribe { topic, responder })
            .await
            .map_err(|_| Error::Network("WS connection task is gone".into()))?;
        rx.await
            .map_err(|_| Error::Network("WS connection task dropped responder".into()))?
    }

    /// Cancel a server-side subscription. The local broadcast receiver may
    /// still drain queued events before going silent.
    pub async fn unsubscribe(&self, subscription_id: impl Into<String>) -> Result<()> {
        let subscription_id = subscription_id.into();
        let tx = self.require_control().await?;
        let (responder, rx) = oneshot::channel();
        tx.send(Control::Unsubscribe {
            subscription_id,
            responder,
        })
        .await
        .map_err(|_| Error::Network("WS connection task is gone".into()))?;
        rx.await
            .map_err(|_| Error::Network("WS connection task dropped responder".into()))?
    }

    async fn require_control(&self) -> Result<mpsc::Sender<Control>> {
        let guard = self.control_tx.lock().await;
        guard.as_ref().cloned().ok_or(Error::NotInitialized)
    }

    fn next_request_id(&self) -> String {
        format!("ws-{}", self.next_id.fetch_add(1, Ordering::Relaxed))
    }
}

#[async_trait]
impl TransportTrait for WsTransport {
    async fn connect(&mut self) -> Result<()> {
        if self.connected.load(Ordering::Acquire) {
            return Ok(());
        }

        let request = build_handshake_request(&self.url, &self.auth)?;
        let connector = build_connector(self.identity.as_ref())?;

        let (ws_stream, response) =
            tokio_tungstenite::connect_async_tls_with_config(request, None, false, Some(connector))
                .await
                .map_err(|e| Error::Network(format!("WS connect failed: {e}")))?;

        // Verify the server agreed to our subprotocol. Some servers may
        // omit it on success — we treat absence as acceptable, but a
        // mismatch is fatal.
        if let Some(value) = response.headers().get(SEC_WEBSOCKET_PROTOCOL) {
            let advertised = value.to_str().unwrap_or("");
            if !advertised.is_empty() && advertised != SUBPROTOCOL {
                return Err(Error::Protocol(format!(
                    "server selected subprotocol {advertised:?}, expected {SUBPROTOCOL:?}"
                )));
            }
        }

        let (control_tx, control_rx) = mpsc::channel(OUTBOUND_BUFFER);
        let connected = Arc::clone(&self.connected);
        connected.store(true, Ordering::Release);

        let task = tokio::spawn(run_connection(ws_stream, control_rx, connected));

        {
            let mut tx_slot = self.control_tx.lock().await;
            *tx_slot = Some(control_tx);
        }
        {
            let mut handle_slot = self.task_handle.lock().await;
            *handle_slot = Some(task);
        }

        Ok(())
    }

    async fn disconnect(&mut self) -> Result<()> {
        let tx = {
            let mut guard = self.control_tx.lock().await;
            guard.take()
        };
        if let Some(tx) = tx {
            // Best-effort shutdown; ignore send errors when the task is
            // already gone.
            let _ = tx.send(Control::Shutdown).await;
        }
        self.connected.store(false, Ordering::Release);

        if let Some(handle) = self.task_handle.lock().await.take() {
            // Give the task a moment to exit cleanly, then drop the handle
            // so the abort propagates if it hung.
            let _ = tokio::time::timeout(Duration::from_secs(2), handle).await;
        }
        Ok(())
    }

    async fn send_request(&self, request: JsonRpcRequest) -> Result<JsonRpcResponse> {
        if !self.is_connected() {
            return Err(Error::NotInitialized);
        }

        let tx = self.require_control().await?;

        // Normalise: empty-string ids are treated as notifications.
        // Requests without an id get one minted before queueing so the
        // connection task can correlate the response.
        let mut req = request;
        req.jsonrpc = "2.0".to_string();
        if req.id.as_deref().map(str::is_empty).unwrap_or(false) {
            req.id = None;
        }
        let is_notification = req.id.is_none();
        if !is_notification {
            // Already has an id from the caller — leave it alone so the
            // outer client can pick its own correlation scheme.
        } else if req.method != "notifications/initialized"
            && !req.method.starts_with("notifications/")
        {
            // Not actually a notification per JSON-RPC 2.0 (callers using
            // bare method names without an id). Mint an id so we can wait
            // on a response.
            req.id = Some(self.next_request_id());
        }

        let (responder, rx) = oneshot::channel();
        tx.send(Control::Send {
            request: req,
            responder,
        })
        .await
        .map_err(|_| Error::Network("WS connection task is gone".into()))?;

        rx.await
            .map_err(|_| Error::Network("WS connection task dropped responder".into()))?
    }

    fn is_connected(&self) -> bool {
        self.connected.load(Ordering::Acquire)
    }
}

// ─── Connection task ────────────────────────────────────────────────────────

type WsStream<S> = tokio_tungstenite::WebSocketStream<tokio_tungstenite::MaybeTlsStream<S>>;

async fn run_connection(
    ws_stream: WsStream<tokio::net::TcpStream>,
    mut control_rx: mpsc::Receiver<Control>,
    connected: Arc<AtomicBool>,
) {
    let (mut sink, mut stream) = ws_stream.split();
    let mut state = ConnectionState::new();

    loop {
        tokio::select! {
            biased;

            // Outbound: requests, subscriptions, shutdown.
            maybe_ctrl = control_rx.recv() => {
                let Some(ctrl) = maybe_ctrl else { break };
                match ctrl {
                    Control::Shutdown => {
                        let _ = sink.send(Message::Close(None)).await;
                        break;
                    }
                    Control::Send { request, responder } => {
                        let frame = match serde_json::to_string(&request) {
                            Ok(f) => f,
                            Err(e) => {
                                let _ = responder.send(Err(Error::Json(e)));
                                continue;
                            }
                        };

                        if let Err(e) = sink.send(Message::Text(frame)).await {
                            let _ = responder.send(Err(Error::Network(format!(
                                "WS write failed: {e}"
                            ))));
                            break;
                        }

                        match request.id {
                            Some(id) => {
                                state.pending.insert(id, responder);
                            }
                            None => {
                                // Notification frame — no response expected.
                                let _ = responder.send(Ok(JsonRpcResponse {
                                    jsonrpc: "2.0".to_string(),
                                    id: String::new(),
                                    result: Some(Value::Null),
                                    error: None,
                                }));
                            }
                        }
                    }
                    Control::Subscribe { topic, responder } => {
                        let id = format!("sub-{}", uuid::Uuid::new_v4());
                        let request = JsonRpcRequest::new(
                            id.clone(),
                            "subscribe",
                            Some(serde_json::json!({ "topic": topic })),
                        );
                        let frame = match serde_json::to_string(&request) {
                            Ok(f) => f,
                            Err(e) => {
                                let _ = responder.send(Err(Error::Json(e)));
                                continue;
                            }
                        };
                        if let Err(e) = sink.send(Message::Text(frame)).await {
                            let _ = responder.send(Err(Error::Network(format!(
                                "WS write failed: {e}"
                            ))));
                            break;
                        }
                        state
                            .pending_subscribe
                            .insert(id, (topic, responder));
                    }
                    Control::Unsubscribe { subscription_id, responder } => {
                        let id = format!("uns-{}", uuid::Uuid::new_v4());
                        let request = JsonRpcRequest::new(
                            id.clone(),
                            "unsubscribe",
                            Some(serde_json::json!({ "subscription": subscription_id })),
                        );
                        let frame = match serde_json::to_string(&request) {
                            Ok(f) => f,
                            Err(e) => {
                                let _ = responder.send(Err(Error::Json(e)));
                                continue;
                            }
                        };
                        if let Err(e) = sink.send(Message::Text(frame)).await {
                            let _ = responder.send(Err(Error::Network(format!(
                                "WS write failed: {e}"
                            ))));
                            break;
                        }

                        // Drop the local broadcast sender immediately so any
                        // in-flight events stop being routed. The server will
                        // ack via the unsubscribe response which we ignore here.
                        state.subscriptions.remove(&subscription_id);
                        // Wire the responder up to the next response with this id
                        // by reusing pending; we synthesise a unit result.
                        let (proxy_tx, proxy_rx) = oneshot::channel();
                        state.pending.insert(id, proxy_tx);
                        tokio::spawn(async move {
                            let _ = match proxy_rx.await {
                                Ok(Ok(_)) => responder.send(Ok(())),
                                Ok(Err(e)) => responder.send(Err(e)),
                                Err(_) => responder.send(Err(Error::Network(
                                    "WS task dropped unsubscribe responder".into(),
                                ))),
                            };
                        });
                    }
                }
            }

            // Inbound: responses + notifications + control frames.
            msg = stream.next() => {
                let Some(msg) = msg else { break };
                match msg {
                    Ok(Message::Text(text)) => {
                        handle_inbound(&text, &mut state);
                    }
                    Ok(Message::Binary(_)) => {
                        // Protocol violation: server sent a binary frame.
                        // Fail any pending subscribes/sends with an explicit
                        // error and bail.
                        fail_all(&mut state, "server sent binary frame");
                        break;
                    }
                    Ok(Message::Ping(payload)) => {
                        let _ = sink.send(Message::Pong(payload)).await;
                    }
                    Ok(Message::Pong(_)) => {}
                    Ok(Message::Close(_)) => {
                        break;
                    }
                    Ok(Message::Frame(_)) => {
                        // Raw frames aren't expected in client mode.
                    }
                    Err(e) => {
                        fail_all(&mut state, &format!("WS read error: {e}"));
                        break;
                    }
                }
            }
        }
    }

    connected.store(false, Ordering::Release);
    fail_all(&mut state, "WS connection closed");
}

fn handle_inbound(text: &str, state: &mut ConnectionState) {
    let value: Value = match serde_json::from_str(text) {
        Ok(v) => v,
        Err(e) => {
            tracing::warn!("ws: dropping malformed JSON frame: {e}");
            return;
        }
    };

    // Notifications: id field is absent.
    if value.get("id").is_none() {
        if let Some(method) = value.get("method").and_then(Value::as_str) {
            if method == "notification" {
                route_notification(value.get("params"), state);
            }
            // Other server-initiated methods (e.g. session.ready) are
            // intentionally ignored — they're informational only.
        }
        return;
    }

    let response: JsonRpcResponse = match serde_json::from_value(value.clone()) {
        Ok(r) => r,
        Err(e) => {
            tracing::warn!("ws: dropping malformed JSON-RPC response: {e}");
            return;
        }
    };

    let id = response.id.clone();

    // Subscribe responses wear a different shape: their result includes
    // {subscription, topic}. We must register the broadcast channel before
    // delivering the subscription handle to the caller, otherwise any
    // immediately-following notification could race ahead of registration.
    if let Some((topic, responder)) = state.pending_subscribe.remove(&id) {
        if let Some(err) = response.error {
            let _ = responder.send(Err(Error::server(err.code, err.message, err.data)));
            return;
        }
        let result = response.result.unwrap_or(Value::Null);
        let sub_id = result
            .get("subscription")
            .and_then(Value::as_str)
            .map(str::to_owned)
            .unwrap_or_else(|| id.clone());
        let (tx, rx) = broadcast::channel(SUBSCRIPTION_BUFFER);
        state.subscriptions.insert(sub_id.clone(), tx);
        let subscription = Subscription {
            id: sub_id,
            topic,
            events: rx,
        };
        let _ = responder.send(Ok(subscription));
        return;
    }

    if let Some(responder) = state.pending.remove(&id) {
        if let Some(err) = response.error {
            let _ = responder.send(Err(Error::server(err.code, err.message, err.data)));
        } else {
            let _ = responder.send(Ok(response));
        }
    } else {
        tracing::debug!("ws: response for unknown id {id} (likely already timed out)");
    }
}

fn route_notification(params: Option<&Value>, state: &mut ConnectionState) {
    let Some(params) = params else { return };
    let subscription = params
        .get("subscription")
        .and_then(Value::as_str)
        .map(str::to_owned);
    let event = params
        .get("event")
        .and_then(Value::as_str)
        .unwrap_or("")
        .to_string();
    let data = params.get("data").cloned().unwrap_or(Value::Null);

    let Some(sub_id) = subscription else {
        tracing::debug!("ws: dropping notification with no subscription id");
        return;
    };

    if let Some(tx) = state.subscriptions.get(&sub_id) {
        // A `send` returns Err only when there are no live receivers; that's
        // fine, we just drop the event.
        let _ = tx.send(NotificationEvent {
            subscription: sub_id,
            event,
            data,
        });
    }
}

fn fail_all(state: &mut ConnectionState, msg: &str) {
    for (_id, responder) in state.pending.drain() {
        let _ = responder.send(Err(Error::Network(msg.to_string())));
    }
    for (_id, (_topic, responder)) in state.pending_subscribe.drain() {
        let _ = responder.send(Err(Error::Network(msg.to_string())));
    }
    state.subscriptions.clear();
}

// ─── Handshake helpers ──────────────────────────────────────────────────────

fn build_handshake_request(url: &str, auth: &AuthConfig) -> Result<WsRequest> {
    let mut request = url
        .into_client_request()
        .map_err(|e| Error::invalid_url(format!("invalid WS URL: {e}")))?;

    let headers = request.headers_mut();

    headers.insert(
        SEC_WEBSOCKET_PROTOCOL,
        HeaderValue::from_static(SUBPROTOCOL),
    );

    match auth {
        AuthConfig::None | AuthConfig::ClientCredentials(_) => {
            // ClientCredentials is async; tokens can be carried in the
            // initial subscribe frame instead. mTLS is the recommended
            // auth path for WS.
        }
        AuthConfig::Bearer(token) => {
            if let Ok(value) = HeaderValue::from_str(&format!("Bearer {token}")) {
                headers.insert(AUTHORIZATION, value);
            }
        }
        AuthConfig::ApiKey(key) => {
            if let Ok(value) = HeaderValue::from_str(key) {
                let name = HeaderName::from_static("x-api-key");
                headers.insert(name, value);
            }
        }
        AuthConfig::Basic { username, password } => {
            let credentials = general_purpose::STANDARD.encode(format!("{username}:{password}"));
            if let Ok(value) = HeaderValue::from_str(&format!("Basic {credentials}")) {
                headers.insert(AUTHORIZATION, value);
            }
        }
    }

    Ok(request)
}

fn build_connector(identity: Option<&ConduitIdentity>) -> Result<Connector> {
    use rustls::pki_types::{CertificateDer, PrivateKeyDer};
    use rustls::{ClientConfig, RootCertStore};

    // Build the trust store: webpki roots by default, plus any caller-provided
    // CA. This matches the reqwest-based transports.
    let mut roots = RootCertStore::empty();
    roots.extend(webpki_roots::TLS_SERVER_ROOTS.iter().cloned());

    if let Some(id) = identity {
        if let Some(ca_pem) = id.ca_pem_bytes() {
            for cert in rustls_pemfile::certs(&mut std::io::Cursor::new(ca_pem)) {
                let cert = cert.map_err(|e| {
                    Error::invalid_config(format!("failed to parse custom CA: {e}"))
                })?;
                roots.add(cert).map_err(|e| {
                    Error::invalid_config(format!("failed to trust custom CA: {e}"))
                })?;
            }
        }
    }

    let config_builder = ClientConfig::builder().with_root_certificates(roots);

    let client_config = if let Some(id) = identity {
        let cert_chain: Vec<CertificateDer<'static>> =
            rustls_pemfile::certs(&mut std::io::Cursor::new(id.cert_pem_bytes()))
                .collect::<std::result::Result<Vec<_>, _>>()
                .map_err(|e| Error::invalid_config(format!("failed to parse client cert: {e}")))?;

        let key: PrivateKeyDer<'static> =
            rustls_pemfile::private_key(&mut std::io::Cursor::new(id.key_pem_bytes()))
                .map_err(|e| Error::invalid_config(format!("failed to parse client key: {e}")))?
                .ok_or_else(|| Error::invalid_config("no PEM private key found in identity key"))?;

        config_builder
            .with_client_auth_cert(cert_chain, key)
            .map_err(|e| {
                Error::invalid_config(format!("failed to build mTLS client config: {e}"))
            })?
    } else {
        config_builder.with_no_client_auth()
    };

    Ok(Connector::Rustls(Arc::new(client_config)))
}

// ─── Tests ──────────────────────────────────────────────────────────────────

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn rejects_non_ws_url() {
        let err = WsTransport::new("https://example.com/ws".into(), AuthConfig::None).unwrap_err();
        assert!(format!("{err}").contains("ws://"), "{err}");
    }

    #[test]
    fn accepts_ws_and_wss() {
        WsTransport::new("ws://localhost:4000/ws".into(), AuthConfig::None).unwrap();
        WsTransport::new("wss://gw.example.com/ws".into(), AuthConfig::None).unwrap();
    }

    #[test]
    fn handshake_includes_subprotocol() {
        let req = build_handshake_request("wss://example.com/ws", &AuthConfig::None).unwrap();
        let value = req
            .headers()
            .get(SEC_WEBSOCKET_PROTOCOL)
            .and_then(|v| v.to_str().ok())
            .unwrap_or("");
        assert_eq!(value, SUBPROTOCOL);
    }

    #[test]
    fn handshake_carries_bearer_token() {
        let req =
            build_handshake_request("wss://example.com/ws", &AuthConfig::Bearer("abc123".into()))
                .unwrap();
        let value = req
            .headers()
            .get(AUTHORIZATION)
            .and_then(|v| v.to_str().ok())
            .unwrap_or("");
        assert_eq!(value, "Bearer abc123");
    }

    #[test]
    fn handshake_carries_basic_auth() {
        let req = build_handshake_request(
            "wss://example.com/ws",
            &AuthConfig::Basic {
                username: "alice".into(),
                password: "s3cret".into(),
            },
        )
        .unwrap();
        let value = req
            .headers()
            .get(AUTHORIZATION)
            .and_then(|v| v.to_str().ok())
            .unwrap_or("");
        assert!(value.starts_with("Basic "));
    }

    #[test]
    fn connector_builds_without_identity() {
        let connector = build_connector(None).unwrap();
        assert!(matches!(connector, Connector::Rustls(_)));
    }

    #[test]
    fn route_notification_drops_unknown_sub() {
        let mut state = ConnectionState::new();
        route_notification(
            Some(&json!({"subscription": "ghost", "event": "x", "data": null})),
            &mut state,
        );
        assert!(state.subscriptions.is_empty());
    }

    #[test]
    fn handle_inbound_routes_response_to_pending() {
        let mut state = ConnectionState::new();
        let (tx, rx) = oneshot::channel();
        state.pending.insert("42".into(), tx);

        handle_inbound(
            r#"{"jsonrpc":"2.0","id":"42","result":{"ok":true}}"#,
            &mut state,
        );

        let result = rx.blocking_recv().unwrap().unwrap();
        assert_eq!(result.result.unwrap(), json!({"ok": true}));
        assert!(state.pending.is_empty());
    }

    #[test]
    fn handle_inbound_drops_response_for_unknown_id() {
        let mut state = ConnectionState::new();
        handle_inbound(r#"{"jsonrpc":"2.0","id":"ghost","result":{}}"#, &mut state);
        // No panic, no pending entry created.
        assert!(state.pending.is_empty());
    }

    #[test]
    fn handle_inbound_routes_subscribe_response() {
        let mut state = ConnectionState::new();
        let (tx, rx) = oneshot::channel();
        state
            .pending_subscribe
            .insert("req-1".into(), ("agents.x.events".into(), tx));

        handle_inbound(
            r#"{"jsonrpc":"2.0","id":"req-1","result":{"subscription":"sub_abc","topic":"agents.x.events"}}"#,
            &mut state,
        );

        let sub = rx.blocking_recv().unwrap().unwrap();
        assert_eq!(sub.id, "sub_abc");
        assert_eq!(sub.topic, "agents.x.events");
        assert!(state.subscriptions.contains_key("sub_abc"));
    }

    #[test]
    fn handle_inbound_propagates_subscribe_error() {
        let mut state = ConnectionState::new();
        let (tx, rx) = oneshot::channel();
        state
            .pending_subscribe
            .insert("req-1".into(), ("bad.topic".into(), tx));

        handle_inbound(
            r#"{"jsonrpc":"2.0","id":"req-1","error":{"code":-32600,"message":"unknown topic"}}"#,
            &mut state,
        );

        let err = rx.blocking_recv().unwrap().unwrap_err();
        assert!(matches!(err, Error::Server { code: -32600, .. }));
    }

    #[test]
    fn handle_inbound_routes_notification_to_subscriber() {
        let mut state = ConnectionState::new();
        let (tx, _rx) = broadcast::channel(8);
        let mut events = tx.subscribe();
        state.subscriptions.insert("sub_abc".into(), tx);

        handle_inbound(
            r#"{"jsonrpc":"2.0","method":"notification","params":{"subscription":"sub_abc","event":"thought","data":{"text":"hi"}}}"#,
            &mut state,
        );

        let evt = events.try_recv().unwrap();
        assert_eq!(evt.subscription, "sub_abc");
        assert_eq!(evt.event, "thought");
        assert_eq!(evt.data, json!({"text": "hi"}));
    }

    #[test]
    fn handle_inbound_ignores_unknown_server_methods() {
        let mut state = ConnectionState::new();
        // session.ready and similar informational notifications are dropped
        // silently — the SDK exposes them via subscribe(), not the request loop.
        handle_inbound(
            r#"{"jsonrpc":"2.0","method":"session.ready","params":{"session_id":"abc"}}"#,
            &mut state,
        );
        assert!(state.subscriptions.is_empty());
    }

    #[test]
    fn handle_inbound_ignores_malformed_frames() {
        let mut state = ConnectionState::new();
        handle_inbound("not valid json", &mut state);
        handle_inbound(r#"{"id":"1","not":"jsonrpc"}"#, &mut state);
        // No state changes, no panics.
        assert!(state.pending.is_empty());
    }

    #[test]
    fn fail_all_drains_pending() {
        let mut state = ConnectionState::new();
        let (tx1, rx1) = oneshot::channel();
        let (tx2, rx2) = oneshot::channel();
        state.pending.insert("a".into(), tx1);
        state
            .pending_subscribe
            .insert("b".into(), ("topic.x".into(), tx2));

        fail_all(&mut state, "boom");

        let err1 = rx1.blocking_recv().unwrap().unwrap_err();
        let err2 = rx2.blocking_recv().unwrap().unwrap_err();
        assert!(matches!(err1, Error::Network(_)));
        assert!(matches!(err2, Error::Network(_)));
        assert!(state.pending.is_empty());
        assert!(state.pending_subscribe.is_empty());
    }
}
