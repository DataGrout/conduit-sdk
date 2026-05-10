//! Autonomous agent self-registration (onramp) example
//!
//! Demonstrates two paths for getting a fully-bootstrapped DG client with
//! zero prior credentials:
//!
//! **Path A — one-liner** (`ClientBuilder::bootstrap_onramp`):
//! Chains onramp → token exchange → mTLS identity registration in a single
//! builder call. This is what most agents should use.
//!
//! **Path B — manual** (`register_only` / `register_and_exchange`):
//! Lower-level access for agents that want to persist or inspect credentials
//! before building a client (e.g. storing `client_secret` in a vault).
//!
//! # Running
//!
//! ```sh
//! cargo run --example bootstrap --features bootstrap
//! ```
//!
//! The first run registers a new agent and saves the mTLS identity to
//! `~/.conduit/`. Subsequent runs auto-discover the saved identity — no
//! credentials are needed at all. Set the `CONDUIT_IDENTITY_DIR` env var
//! to use a custom directory.

use datagrout_conduit::{onramp::OnrampOptions, ClientBuilder};

/// Agent identity — edit these to describe your agent.
const GATEWAY: &str = "https://app.datagrout.ai";
const AGENT_NAME: &str = "example-bootstrap-agent";
const AGENT_TYPE: &str = "rust-example";

#[cfg(feature = "bootstrap")]
#[tokio::main]
async fn main() -> Result<(), Box<dyn std::error::Error>> {
    tracing_subscriber::fmt::init();

    println!("=== DataGrout Conduit — Bootstrap Example ===\n");

    // ── Path A: one-liner ─────────────────────────────────────────────────────
    //
    // `bootstrap_onramp` handles everything:
    //
    // 1. Checks `~/.conduit/` for a saved identity → reuses it if valid.
    // 2. If no identity, performs the two-step onramp handshake.
    // 3. Exchanges the provisional credentials for an access token.
    // 4. Registers a fresh mTLS keypair with the DG CA.
    // 5. Persists the signed cert to `~/.conduit/` for future runs.
    // 6. Returns a `ClientBuilder` ready to `.build()`.
    //
    // On the second run and beyond, only step 1 executes.

    let opts = OnrampOptions {
        gateway: GATEWAY.into(),
        agent_name: AGENT_NAME.into(),
        agent_type: Some(AGENT_TYPE.into()),
        intended_use: Some("Demonstrate the conduit-sdk bootstrap example.".into()),
        access_code: None,
    };

    println!("Path A — one-liner bootstrap:");
    let builder = ClientBuilder::new().bootstrap_onramp(opts.clone()).await?;

    let client = builder.build()?;
    client.connect().await?;
    println!("  Connected via bootstrap_onramp ✓");

    // Show server info if available.
    if let Some(info) = client.server_info().await {
        println!("  Server: {} v{}", info.name, info.version);
    }

    client.disconnect().await?;

    // ── Path B: manual — inspect credentials before building ─────────────────
    //
    // Use this when you need to store the `client_secret` in a vault or
    // inspect the granted scopes before proceeding.

    println!("\nPath B — manual onramp + identity bootstrap:");

    // Step 1: two-step handshake → provisional OAuth credentials.
    let (creds, token) = datagrout_conduit::onramp::register_and_exchange(&opts).await?;

    println!("  Registered:  client_id={}", creds.client_id);
    println!("  Scopes:      {:?}", creds.scopes);
    println!("  MCP URL:     {:?}", creds.mcp_url);
    println!("  Token TTL:   {} days", creds.expires_in / 86_400);
    println!(
        "  Secret:      {}… (store this securely — shown once)",
        &creds.client_secret[..6.min(creds.client_secret.len())]
    );

    // Step 2: use the access token to bootstrap mTLS identity.
    // The identity is registered with the DG CA and saved to ~/.conduit/.
    // Subsequent runs auto-discover it — no token or secret needed.
    let url = creds
        .mcp_url
        .as_deref()
        .unwrap_or("https://app.datagrout.ai/servers/example/mcp");

    let client = ClientBuilder::new()
        .url(url)
        .bootstrap_identity(&token, &opts.agent_name)
        .await?
        .build()?;

    client.connect().await?;
    println!("  Connected via manual bootstrap ✓");
    client.disconnect().await?;

    println!("\nDone. Identity saved to ~/.conduit/ — subsequent runs need no credentials.");
    Ok(())
}

#[cfg(not(feature = "bootstrap"))]
fn main() {
    eprintln!("This example requires the `bootstrap` feature flag.");
    eprintln!("Run: cargo run --example bootstrap --features bootstrap");
    std::process::exit(1);
}
