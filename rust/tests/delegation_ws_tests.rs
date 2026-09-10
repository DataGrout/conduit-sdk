// `tokio-tungstenite::handshake::server::ErrorResponse` is a large `http::Response`
// alias; the upstream callback signature unavoidably triggers
// `clippy::result_large_err`.
#![allow(clippy::result_large_err)]
#![cfg(feature = "delegation")]

//! The delegated bearer reaches the WebSocket upgrade.
//!
//! Drives the real `WsTransport::connect` against a WebSocket server whose
//! handshake callback captures the `Authorization` header, with the token
//! endpoint on a mock HTTP server. Invariant 11 in the changelog: the WS
//! handshake carries the resolved OAuth bearer — for this grant too.

use datagrout_conduit::delegation::{DelegatedProvider, DelegationRequest, TokenSource, TokenType};
use datagrout_conduit::transport::{AuthConfig, TransportTrait};
use datagrout_conduit::ws_transport::{WsTransport, SUBPROTOCOL as WS_SUBPROTOCOL};
use futures_util::StreamExt;
use std::sync::Arc;
use tokio::net::TcpListener;
use tokio::sync::Mutex;
use tokio_tungstenite::tungstenite::handshake::server::{ErrorResponse, Request, Response};
use tokio_tungstenite::tungstenite::http::HeaderValue;

/// A single-connection WebSocket server that records the upgrade's
/// `Authorization` header and then sits on the socket.
async fn spawn_capturing_ws_server() -> (String, Arc<Mutex<Option<String>>>) {
    let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
    let port = listener.local_addr().unwrap().port();
    let captured: Arc<Mutex<Option<String>>> = Arc::new(Mutex::new(None));

    let sink = Arc::clone(&captured);
    tokio::spawn(async move {
        let (stream, _) = listener.accept().await.unwrap();
        let seen: Arc<std::sync::Mutex<Option<String>>> = Arc::new(std::sync::Mutex::new(None));
        let seen_in_callback = Arc::clone(&seen);

        let callback = move |req: &Request,
                             mut response: Response|
              -> std::result::Result<Response, ErrorResponse> {
            *seen_in_callback.lock().unwrap() = req
                .headers()
                .get("authorization")
                .and_then(|v| v.to_str().ok())
                .map(str::to_string);
            response.headers_mut().insert(
                "sec-websocket-protocol",
                HeaderValue::from_static(WS_SUBPROTOCOL),
            );
            Ok(response)
        };

        let ws = tokio_tungstenite::accept_hdr_async(stream, callback)
            .await
            .unwrap();
        // Copy out before awaiting: a std guard must not live across `.await`.
        let header = seen.lock().unwrap().clone();
        *sink.lock().await = header;

        // Keep the connection open until the client goes away.
        let (_, mut stream) = ws.split();
        while let Some(Ok(_)) = stream.next().await {}
    });

    (format!("ws://127.0.0.1:{port}/ws"), captured)
}

#[tokio::test]
async fn the_ws_upgrade_carries_the_exchanged_bearer() {
    let mut token_server = mockito::Server::new_async().await;
    let exchange = token_server
        .mock("POST", "/oauth/token")
        .match_body(mockito::Matcher::AllOf(vec![
            mockito::Matcher::UrlEncoded(
                "grant_type".into(),
                "urn:ietf:params:oauth:grant-type:token-exchange".into(),
            ),
            mockito::Matcher::UrlEncoded("subject_token".into(), "user_at".into()),
            mockito::Matcher::UrlEncoded("actor_token".into(), "agent_at".into()),
        ]))
        .with_status(200)
        .with_header("content-type", "application/json")
        .with_body(
            r#"{"access_token":"delegated_ws_bearer","issued_token_type":"urn:ietf:params:oauth:token-type:access_token","token_type":"Bearer","expires_in":900}"#,
        )
        .expect(1)
        .create_async()
        .await;

    let provider = DelegatedProvider::new(
        DelegationRequest::new(
            format!("{}/oauth/token", token_server.url()),
            "agent_client",
        )
        .client_secret("agent_secret"),
        TokenSource::static_token("user_at", TokenType::AccessToken),
        Some(TokenSource::static_token(
            "agent_at",
            TokenType::AccessToken,
        )),
    );

    let (addr, captured) = spawn_capturing_ws_server().await;

    let mut transport = WsTransport::new(addr, AuthConfig::Delegation(provider)).unwrap();
    transport.connect().await.unwrap();
    assert!(transport.is_connected());

    // The exchange happened before the handshake, and its result rode the
    // upgrade — not a placeholder, not nothing.
    exchange.assert_async().await;
    let header = captured.lock().await.clone();
    assert_eq!(header.as_deref(), Some("Bearer delegated_ws_bearer"));

    transport.disconnect().await.unwrap();
}

#[tokio::test]
async fn a_failed_exchange_refuses_the_ws_connection() {
    // The token rides the upgrade and there is no second chance, so a refusal
    // at the token endpoint must stop the connect rather than proceed
    // unauthenticated.
    let mut token_server = mockito::Server::new_async().await;
    let _refused = token_server
        .mock("POST", "/oauth/token")
        .with_status(400)
        .with_body(r#"{"error":"invalid_grant","error_description":"subject token expired"}"#)
        .create_async()
        .await;

    let provider = DelegatedProvider::new(
        DelegationRequest::new(
            format!("{}/oauth/token", token_server.url()),
            "agent_client",
        ),
        TokenSource::static_token("user_at", TokenType::AccessToken),
        Some(TokenSource::static_token(
            "agent_at",
            TokenType::AccessToken,
        )),
    );

    let (addr, captured) = spawn_capturing_ws_server().await;
    let mut transport = WsTransport::new(addr, AuthConfig::Delegation(provider)).unwrap();

    let err = transport.connect().await.unwrap_err();
    assert!(matches!(err, datagrout_conduit::Error::Auth(_)), "{err:?}");
    assert!(err.to_string().contains("invalid_grant"), "{err}");
    assert!(!transport.is_connected());
    // No handshake was attempted at all.
    assert!(captured.lock().await.is_none());
}
