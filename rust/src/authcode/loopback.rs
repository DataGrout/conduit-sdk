//! Capture the OAuth redirect on `127.0.0.1`.
//!
//! A native app has no web server to redirect to, so it runs one for a few
//! seconds: bind a loopback port, send the user to the consent page, and read
//! the `code` off the single request the browser makes coming back.
//!
//! This lives behind its own feature. In Rust it needs no extra dependency —
//! tokio is already here — but the split is kept because in other conduit SDKs
//! a local HTTP server *is* a dependency, and the surface should look the same
//! in every language. It also lets headless callers take
//! [`AuthCodeFlow`](super::AuthCodeFlow) without compiling a listener they will
//! never bind.
//!
//! ```rust,no_run
//! use datagrout_conduit::authcode::{loopback, AuthCodeFlow};
//!
//! # #[tokio::main]
//! # async fn main() -> Result<(), Box<dyn std::error::Error>> {
//! let listener = loopback::Listener::bind().await?;
//!
//! let mut flow = AuthCodeFlow::discover("https://gateway.datagrout.ai/connect").await?;
//! flow.register("My App", listener.redirect_uri()).await?;
//!
//! let (url, pending) = flow.authorize_url()?;
//! // open `url` in a browser however suits the application
//!
//! let redirect = listener.wait(std::time::Duration::from_secs(300)).await?;
//! let grant = flow.exchange(pending, &redirect.code, &redirect.state).await?;
//! # Ok(()) }
//! ```

use std::time::Duration;

use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::net::TcpListener;

use super::AuthCodeError;

/// What the authorization server sent back to the redirect URI.
#[derive(Debug, Clone)]
pub struct Redirect {
    /// The authorization code.
    pub code: String,
    /// The `state` parameter, to be checked against the pending request.
    pub state: String,
}

/// A one-shot loopback listener for the OAuth redirect.
#[derive(Debug)]
pub struct Listener {
    listener: TcpListener,
    port: u16,
    path: String,
}

impl Listener {
    /// Bind an OS-assigned port on `127.0.0.1`.
    ///
    /// Letting the OS choose avoids fighting whatever else owns a fixed port —
    /// and because registration happens after binding, the real port is already
    /// known by the time the redirect URI is registered.
    pub async fn bind() -> std::result::Result<Self, AuthCodeError> {
        Self::bind_on(0, "/callback").await
    }

    /// Bind a specific port and path.
    ///
    /// Use when the client was registered out of band against a fixed redirect
    /// URI and the authorization server will accept no other.
    pub async fn bind_on(port: u16, path: &str) -> std::result::Result<Self, AuthCodeError> {
        let listener = TcpListener::bind(("127.0.0.1", port))
            .await
            .map_err(|e| AuthCodeError::Http(format!("cannot bind loopback port: {e}")))?;
        let port = listener
            .local_addr()
            .map_err(|e| AuthCodeError::Http(e.to_string()))?
            .port();

        Ok(Self {
            listener,
            port,
            path: if path.starts_with('/') {
                path.to_string()
            } else {
                format!("/{path}")
            },
        })
    }

    /// Re-bind the exact port and path of a previously registered redirect URI.
    ///
    /// Needed whenever a saved
    /// [`RegisteredClient`](super::RegisteredClient) is reused: the
    /// authorization server matches the redirect URI exactly, so the listener
    /// has to come back on the same port it registered.
    ///
    /// Returns an error if that port is occupied. The right recovery is to
    /// [`bind`](Self::bind) a fresh port and register a new client — not to
    /// retry, and not to authorize against a URI the server will reject.
    pub async fn bind_for(redirect_uri: &str) -> std::result::Result<Self, AuthCodeError> {
        let parsed = url::Url::parse(redirect_uri)
            .map_err(|e| AuthCodeError::Http(format!("bad redirect_uri {redirect_uri}: {e}")))?;

        let port = parsed.port().ok_or_else(|| {
            AuthCodeError::Http(format!("redirect_uri {redirect_uri} names no port"))
        })?;

        Self::bind_on(port, parsed.path()).await
    }

    /// The port actually bound.
    pub fn port(&self) -> u16 {
        self.port
    }

    /// The redirect URI to register and to send in the authorize request.
    ///
    /// Uses `127.0.0.1` rather than `localhost`: RFC 8252 recommends the
    /// literal address, and it sidesteps hosts where `localhost` resolves to
    /// IPv6 first while the listener is bound to IPv4.
    pub fn redirect_uri(&self) -> String {
        format!("http://127.0.0.1:{}{}", self.port, self.path)
    }

    /// Wait for the browser's redirect, up to `timeout`.
    ///
    /// Serves a small page either way so the user sees an outcome rather than a
    /// browser error, then returns. Requests to other paths are answered 404
    /// and ignored — browsers routinely ask for `/favicon.ico`, and treating
    /// that as the redirect would abort the flow.
    pub async fn wait(&self, timeout: Duration) -> std::result::Result<Redirect, AuthCodeError> {
        tokio::time::timeout(timeout, self.accept_loop())
            .await
            .map_err(|_| {
                AuthCodeError::Http(format!(
                    "timed out after {}s waiting for the authorization redirect",
                    timeout.as_secs()
                ))
            })?
    }

    async fn accept_loop(&self) -> std::result::Result<Redirect, AuthCodeError> {
        loop {
            let (mut stream, _) = self
                .listener
                .accept()
                .await
                .map_err(|e| AuthCodeError::Http(e.to_string()))?;

            let mut buf = vec![0u8; 8192];
            let n = match stream.read(&mut buf).await {
                Ok(0) | Err(_) => continue,
                Ok(n) => n,
            };

            let request = String::from_utf8_lossy(&buf[..n]);
            let Some(target) = request_target(&request) else {
                continue;
            };

            let (path, query) = match target.split_once('?') {
                Some((p, q)) => (p, q),
                None => (target, ""),
            };

            if path != self.path {
                respond(&mut stream, 404, "Not found").await;
                continue;
            }

            let params = parse_query(query);

            if let Some(error) = params.get("error") {
                respond(
                    &mut stream,
                    200,
                    "Authorization was denied. You can close this window.",
                )
                .await;
                return Err(AuthCodeError::Denied {
                    error: error.clone(),
                    description: params.get("error_description").cloned(),
                });
            }

            match (params.get("code"), params.get("state")) {
                (Some(code), Some(state)) => {
                    respond(
                        &mut stream,
                        200,
                        "Signed in. You can close this window and return to the app.",
                    )
                    .await;
                    return Ok(Redirect {
                        code: code.clone(),
                        state: state.clone(),
                    });
                }
                _ => {
                    respond(&mut stream, 400, "Missing code or state.").await;
                    return Err(AuthCodeError::Discovery(
                        "redirect carried neither an error nor a code/state pair".into(),
                    ));
                }
            }
        }
    }
}

fn request_target(request: &str) -> Option<&str> {
    request.lines().next()?.split_whitespace().nth(1)
}

fn parse_query(query: &str) -> std::collections::BTreeMap<String, String> {
    query
        .split('&')
        .filter(|p| !p.is_empty())
        .filter_map(|pair| {
            let (k, v) = pair.split_once('=')?;
            Some((percent_decode(k), percent_decode(v)))
        })
        .collect()
}

/// Decode `%XX` escapes and `+` as space.
///
/// Authorization codes and state values are opaque and routinely contain
/// characters that must survive a round trip through the query string.
fn percent_decode(s: &str) -> String {
    let bytes = s.as_bytes();
    let mut out = Vec::with_capacity(bytes.len());
    let mut i = 0;
    while i < bytes.len() {
        match bytes[i] {
            b'+' => {
                out.push(b' ');
                i += 1;
            }
            b'%' if i + 2 < bytes.len() => {
                match u8::from_str_radix(
                    std::str::from_utf8(&bytes[i + 1..i + 3]).unwrap_or(""),
                    16,
                ) {
                    Ok(byte) => {
                        out.push(byte);
                        i += 3;
                    }
                    Err(_) => {
                        out.push(bytes[i]);
                        i += 1;
                    }
                }
            }
            b => {
                out.push(b);
                i += 1;
            }
        }
    }
    String::from_utf8_lossy(&out).to_string()
}

async fn respond(stream: &mut tokio::net::TcpStream, status: u16, message: &str) {
    let body = format!(
        "<!DOCTYPE html><html><head><meta charset=\"utf-8\"><title>DataGrout</title>\
         <style>body{{font:15px/1.5 system-ui,sans-serif;margin:16vh auto;max-width:26rem;\
         text-align:center;color-scheme:light dark}}</style></head>\
         <body><p>{message}</p></body></html>"
    );
    let head = format!(
        "HTTP/1.1 {status} OK\r\ncontent-type: text/html; charset=utf-8\r\n\
         content-length: {}\r\nconnection: close\r\n\r\n",
        body.len()
    );
    let _ = stream.write_all(head.as_bytes()).await;
    let _ = stream.write_all(body.as_bytes()).await;
    let _ = stream.flush().await;
}

#[cfg(test)]
mod tests {
    use super::*;

    #[tokio::test]
    async fn binds_a_loopback_port_and_reports_it() {
        let l = Listener::bind().await.unwrap();
        assert!(l.port() > 0);
        assert_eq!(
            l.redirect_uri(),
            format!("http://127.0.0.1:{}/callback", l.port())
        );
    }

    #[tokio::test]
    async fn redirect_uri_uses_the_literal_address_not_localhost() {
        // RFC 8252, and it avoids IPv6-vs-IPv4 resolution surprises.
        let l = Listener::bind().await.unwrap();
        assert!(l.redirect_uri().contains("127.0.0.1"));
        assert!(!l.redirect_uri().contains("localhost"));
    }

    #[tokio::test]
    async fn bind_for_reuses_the_exact_port_and_path_of_a_saved_uri() {
        // A saved client id is bound to its redirect URI exactly, so a later
        // run has to come back on the same port.
        let first = Listener::bind_on(0, "/cb").await.unwrap();
        let uri = first.redirect_uri();
        let port = first.port();
        drop(first);

        let again = Listener::bind_for(&uri).await.unwrap();
        assert_eq!(again.port(), port);
        assert_eq!(again.redirect_uri(), uri);
    }

    #[tokio::test]
    async fn bind_for_fails_loudly_when_the_port_is_taken() {
        let held = Listener::bind().await.unwrap();
        let err = Listener::bind_for(&held.redirect_uri()).await.unwrap_err();
        // Better a clear failure the caller can answer by re-registering than
        // authorizing against a URI the server will reject.
        assert!(err.to_string().contains("cannot bind loopback port"));
    }

    #[tokio::test]
    async fn bind_for_rejects_a_uri_with_no_port() {
        let err = Listener::bind_for("https://example.com/callback")
            .await
            .unwrap_err();
        assert!(err.to_string().contains("names no port"));
    }

    #[tokio::test]
    async fn normalises_a_path_without_a_leading_slash() {
        let l = Listener::bind_on(0, "cb").await.unwrap();
        assert!(l.redirect_uri().ends_with("/cb"));
    }

    #[tokio::test]
    async fn captures_code_and_state_from_the_redirect() {
        let listener = Listener::bind().await.unwrap();
        let uri = listener.redirect_uri();

        let waiter = tokio::spawn(async move { listener.wait(Duration::from_secs(5)).await });

        // Give the accept loop a moment, then act as the browser.
        tokio::time::sleep(Duration::from_millis(50)).await;
        reqwest::get(format!("{uri}?code=the_code&state=the_state"))
            .await
            .unwrap();

        let redirect = waiter.await.unwrap().unwrap();
        assert_eq!(redirect.code, "the_code");
        assert_eq!(redirect.state, "the_state");
    }

    #[tokio::test]
    async fn ignores_favicon_and_keeps_waiting() {
        let listener = Listener::bind().await.unwrap();
        let uri = listener.redirect_uri();
        let base = format!("http://127.0.0.1:{}", listener.port());

        let waiter = tokio::spawn(async move { listener.wait(Duration::from_secs(5)).await });

        tokio::time::sleep(Duration::from_millis(50)).await;
        // A browser asks for this unprompted; treating it as the redirect
        // would abort the flow.
        let _ = reqwest::get(format!("{base}/favicon.ico")).await;
        reqwest::get(format!("{uri}?code=c2&state=s2"))
            .await
            .unwrap();

        let redirect = waiter.await.unwrap().unwrap();
        assert_eq!(redirect.code, "c2");
    }

    #[tokio::test]
    async fn surfaces_a_denial_as_a_typed_error() {
        let listener = Listener::bind().await.unwrap();
        let uri = listener.redirect_uri();

        let waiter = tokio::spawn(async move { listener.wait(Duration::from_secs(5)).await });

        tokio::time::sleep(Duration::from_millis(50)).await;
        reqwest::get(format!(
            "{uri}?error=access_denied&error_description=User%20said%20no"
        ))
        .await
        .unwrap();

        let err = waiter.await.unwrap().unwrap_err();
        match err {
            AuthCodeError::Denied { error, description } => {
                assert_eq!(error, "access_denied");
                assert_eq!(description.as_deref(), Some("User said no"));
            }
            other => panic!("expected Denied, got {other:?}"),
        }
    }

    #[tokio::test]
    async fn times_out_when_no_redirect_arrives() {
        let listener = Listener::bind().await.unwrap();
        let err = listener.wait(Duration::from_millis(80)).await.unwrap_err();
        assert!(err.to_string().contains("timed out"));
    }

    #[test]
    fn parses_the_request_target() {
        assert_eq!(
            request_target("GET /callback?code=1 HTTP/1.1\r\nHost: x\r\n\r\n"),
            Some("/callback?code=1")
        );
        assert_eq!(request_target(""), None);
    }

    #[test]
    fn decodes_percent_escapes_and_plus() {
        assert_eq!(percent_decode("a%20b"), "a b");
        assert_eq!(percent_decode("a+b"), "a b");
        assert_eq!(percent_decode("plain"), "plain");
        assert_eq!(percent_decode("100%"), "100%");
    }

    #[test]
    fn parses_query_pairs() {
        let q = parse_query("code=abc&state=x%20y");
        assert_eq!(q.get("code").unwrap(), "abc");
        assert_eq!(q.get("state").unwrap(), "x y");
        assert!(parse_query("").is_empty());
    }
}
