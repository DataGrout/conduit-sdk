//! Sign in as a **user** with OAuth 2.1 authorization code + PKCE.
//!
//! This is the reference implementation of the flow: the other conduit SDKs
//! port these semantics, so keep this example and their equivalents in step.
//!
//! ```bash
//! cargo run --example browser_signin --features authcode-loopback
//! ```
//!
//! Contrast with `bootstrap.rs`, which authenticates a *machine* holding a
//! secret. This authenticates a *person*, which is what a desktop or CLI app
//! needs — and the only way to use `/connect`, where the server binding is
//! chosen at consent time and lives in the token rather than the URL.

use std::time::Duration;

use datagrout_conduit::authcode::{loopback, AuthCodeFlow, Grant, RegisteredClient};
use datagrout_conduit::ClientBuilder;

const GATEWAY: &str = "https://gateway.datagrout.ai/connect";
const APP_NAME: &str = "Conduit Example";

#[tokio::main]
async fn main() -> Result<(), Box<dyn std::error::Error>> {
    // A real app loads a saved grant here and skips straight to `use_grant`.
    // Storage is the application's choice — an OS keychain, a config file, a
    // vault. The SDK owns the grant's shape and its refresh, not its location.
    let grant = match load_saved_grant() {
        Some(grant) => {
            println!("Reusing the saved grant.");
            grant
        }
        None => sign_in().await?,
    };

    use_grant(grant).await
}

/// The full browser-consent flow.
async fn sign_in() -> Result<Grant, Box<dyn std::error::Error>> {
    // A previously registered client, if we have one. Registering afresh on
    // every sign-in leaves a new client record behind each time.
    let saved = load_saved_client();

    // 1. Bind the redirect listener FIRST, because registration has to name
    //    the real port.
    //
    //    When reusing a saved client we must come back on the SAME port: the
    //    authorization server matches the redirect URI exactly, with no
    //    loopback-port exemption. If that port is now occupied, the recovery
    //    is a fresh registration, not a retry.
    let (listener, saved) = match &saved {
        Some(client) => match loopback::Listener::bind_for(&client.redirect_uri).await {
            Ok(listener) => (listener, saved.clone()),
            Err(_) => {
                println!("Saved redirect port is unavailable; registering a new client.");
                (loopback::Listener::bind().await?, None)
            }
        },
        None => (loopback::Listener::bind().await?, None),
    };

    // 2. Discover the authorization server protecting the gateway.
    let mut flow = AuthCodeFlow::discover(GATEWAY).await?;
    println!(
        "Authorization server: {}",
        flow.metadata().authorization_endpoint
    );

    // 3. Reuse the saved client, or register as a public client (no secret —
    //    PKCE stands in for one).
    let flow = match saved {
        Some(client) => {
            println!("Reusing client_id: {}", client.client_id);
            flow.with_registered_client(client)
        }
        None => {
            let client = flow.register(APP_NAME, listener.redirect_uri()).await?;
            println!("Registered client_id: {}", client.client_id);
            // Persist the id and its redirect URI TOGETHER — an id saved
            // without its URI cannot be reused.
            save_client(&client);
            flow
        }
    };

    // 4. Build the consent URL. The verifier and CSRF state stay in `pending`
    //    and never travel.
    let (url, pending) = flow.authorize_url()?;

    println!("\nOpen this URL to sign in:\n\n  {url}\n");
    // A GUI app would launch a browser here instead of printing.

    // 5. Wait for the browser to come back.
    let redirect = listener.wait(Duration::from_secs(300)).await?;

    // 6. Redeem the code. `exchange` checks the returned state against the
    //    pending request before sending anything — a mismatch is refused, not
    //    attempted.
    let grant = flow
        .exchange(pending, &redirect.code, &redirect.state)
        .await?;

    println!("Signed in. Grant expires at: {:?}", grant.expires_at);
    save_grant(&grant);

    Ok(grant)
}

/// Use a grant to talk to the gateway.
async fn use_grant(grant: Grant) -> Result<(), Box<dyn std::error::Error>> {
    let client = ClientBuilder::new()
        .url(GATEWAY)
        .auth_authorization_code(grant)
        .build()?;

    client.connect().await?;

    let results = client
        .discover()
        .query("summarise numeric data")
        .limit(5)
        .execute()
        .await?;

    println!("\nTools matching that goal:");
    for tool in results.tools.iter().take(5) {
        println!("  {}", tool.name);
    }

    Ok(())
}

// ---------------------------------------------------------------------------
// Persistence — deliberately trivial, and deliberately the application's job.
// ---------------------------------------------------------------------------

fn grant_path() -> std::path::PathBuf {
    std::env::temp_dir().join("conduit-example-grant.json")
}

fn client_path() -> std::path::PathBuf {
    std::env::temp_dir().join("conduit-example-client.json")
}

fn load_saved_client() -> Option<RegisteredClient> {
    let raw = std::fs::read_to_string(client_path()).ok()?;
    serde_json::from_str(&raw).ok()
}

fn save_client(client: &RegisteredClient) {
    if let Ok(json) = serde_json::to_string_pretty(client) {
        let _ = std::fs::write(client_path(), json);
    }
}

fn load_saved_grant() -> Option<Grant> {
    let raw = std::fs::read_to_string(grant_path()).ok()?;
    serde_json::from_str(&raw).ok()
}

fn save_grant(grant: &Grant) {
    // A real app writes to a keychain. Note the refresh token is a
    // long-lived credential: a plain file in a temp directory is fine for an
    // example and wrong for anything else.
    if let Ok(json) = serde_json::to_string_pretty(grant) {
        let _ = std::fs::write(grant_path(), json);
        println!("Grant saved to {}", grant_path().display());
    }
}
