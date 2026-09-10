//! Act **for a user** as an agent, with an RFC 8693 delegated token.
//!
//! This is the reference implementation of the flow: the other conduit SDKs
//! port these semantics, so keep this example and their equivalents in step.
//!
//! ```bash
//! CONDUIT_USER_TOKEN=... CONDUIT_AGENT_CLIENT_ID=... CONDUIT_AGENT_CLIENT_SECRET=... \
//!   cargo run --example delegated_agent --features delegation
//! ```
//!
//! Contrast with `bootstrap.rs` (a *machine* holding a secret) and
//! `browser_signin.rs` (a *person* consenting in a browser). This is the third
//! shape: a machine working on a person's behalf. The token it ends up holding
//! names the user as `sub` and this agent in `act`, so the gateway can see —
//! and audit, and limit, and revoke — the two separately.

use datagrout_conduit::delegation::{DelegatedProvider, DelegationRequest, TokenSource, TokenType};
use datagrout_conduit::{ClientBuilder, OAuthTokenProvider};

const GATEWAY: &str = "https://gateway.datagrout.ai/connect";
const TOKEN_ENDPOINT: &str = "https://gateway.datagrout.ai/oauth/token";

#[tokio::main]
async fn main() -> Result<(), Box<dyn std::error::Error>> {
    // The three inputs. None of them is a real credential; supply your own.
    //
    // The user's token is the SUBJECT. How the agent came by it is the
    // application's business — handed over on an inbound request, read from a
    // vault, or obtained by signing the user in with `browser_signin.rs` (in
    // which case `TokenSource::authorization_code(provider)` keeps it fresh).
    let user_token = env("CONDUIT_USER_TOKEN")?;

    // The agent's own client credentials. These play two roles at once: they
    // AUTHENTICATE the exchange request, and the token they mint is the ACTOR.
    // The server checks that the two are the same principal; the SDK does not.
    let agent_client_id = env("CONDUIT_AGENT_CLIENT_ID")?;
    let agent_client_secret = env("CONDUIT_AGENT_CLIENT_SECRET")?;

    // 1. The agent's own `client_credentials` provider — the actor's source.
    //    It refreshes itself, so every exchange carries a live actor token.
    let agent =
        OAuthTokenProvider::new(&agent_client_id, &agent_client_secret, TOKEN_ENDPOINT, None);

    // 2. The exchange, as a template. Subject and actor tokens are filled in
    //    by the provider on every exchange; everything else is fixed here.
    //
    //    `resource` is RFC 8707 and always sent when set, so the delegated
    //    token cannot be replayed against another server.
    //
    //    There is no `.impersonation()` call: delegation is the default, and
    //    a request with no actor is refused rather than quietly downgraded.
    let request = DelegationRequest::new(TOKEN_ENDPOINT, &agent_client_id)
        .client_secret(&agent_client_secret)
        .resource(GATEWAY)
        .scope("mcp tools");

    let provider = DelegatedProvider::new(
        request,
        TokenSource::static_token(user_token, TokenType::AccessToken),
        Some(TokenSource::client_credentials(agent)),
    );

    // 3. A client that sends the delegated bearer on every request — and on
    //    the WebSocket upgrade, had we chosen `Transport::Ws`. It re-exchanges
    //    before expiry and once more on a 401.
    let client = ClientBuilder::new()
        .url(GATEWAY)
        .auth_delegation(provider.clone())
        .build()?;

    client.connect().await?;

    if let Some(token) = provider.token().await {
        println!(
            "Holding a delegated {} (issued as {}), expires at {:?}",
            token.token_type, token.issued_token_type, token.expires_at
        );
    }

    let results = client
        .discover()
        .query("summarise numeric data")
        .limit(5)
        .execute()
        .await?;

    println!("\nTools this user can reach through this agent:");
    for tool in results.tools.iter().take(5) {
        println!("  {}", tool.name);
    }

    Ok(())
}

fn env(name: &str) -> Result<String, Box<dyn std::error::Error>> {
    std::env::var(name).map_err(|_| format!("set {name} to run this example").into())
}
