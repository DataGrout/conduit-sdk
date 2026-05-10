//! Integration tests for the full onramp → mTLS bootstrap flow.
//!
//! These tests run against a live DataGrout server. They are skipped
//! automatically when `DG_GATEWAY_URL` is not set, so they are safe to include
//! in CI as long as the env var is not exported in the base pipeline.
//!
//! # Running
//!
//! Credential tests only (1 onramp registration per test):
//! ```sh
//! DG_GATEWAY_URL=https://app-staging.datagrout.ai \
//!   cargo test --test onramp_integration --features bootstrap -- --nocapture --test-threads=1
//! ```
//!
//! Full bootstrap + connection tests (requires a known MCP URL):
//! ```sh
//! DG_GATEWAY_URL=https://app-staging.datagrout.ai \
//! DG_TEST_MCP_URL=https://app-staging.datagrout.ai/servers/{uuid}/mcp \
//!   cargo test --test onramp_integration --features bootstrap -- --nocapture --test-threads=1
//! ```
//!
//! Human (existing credentials) path:
//! ```sh
//! DG_TEST_CLIENT_ID=your_client_id \
//! DG_TEST_CLIENT_SECRET=your_client_secret \
//! DG_TEST_MCP_URL=https://app.datagrout.ai/servers/{uuid}/mcp \
//!   cargo test --test onramp_integration --features bootstrap -- --nocapture --test-threads=1
//! ```

#[cfg(feature = "bootstrap")]
mod bootstrap_tests {
    use datagrout_conduit::{
        onramp::{register_and_exchange, register_only, OnrampOptions},
        try_load_credentials, try_read_server_url, ClientBuilder,
    };
    use std::path::Path;

    // ─── Helpers ─────────────────────────────────────────────────────────────

    fn gateway() -> Option<String> {
        std::env::var("DG_GATEWAY_URL").ok()
    }

    fn test_mcp_url() -> Option<String> {
        std::env::var("DG_TEST_MCP_URL").ok()
    }

    fn agent_name(label: &str) -> String {
        let id = uuid::Uuid::new_v4().to_string();
        format!("conduit-test-{}-{}", label, &id[..8])
    }

    fn base_opts(label: &str, gateway: &str) -> OnrampOptions {
        OnrampOptions {
            gateway: gateway.to_string(),
            agent_name: agent_name(label),
            agent_type: Some("conduit-integration-test".into()),
            intended_use: Some("Automated integration test — safe to ignore.".into()),
            access_code: None,
        }
    }

    macro_rules! require_gateway {
        () => {
            match gateway() {
                Some(g) => g,
                None => {
                    eprintln!("[onramp_integration] DG_GATEWAY_URL not set — skipping");
                    return;
                }
            }
        };
    }

    macro_rules! require_mcp_url {
        () => {
            match test_mcp_url() {
                Some(u) => u,
                None => {
                    eprintln!(
                        "[onramp_integration] DG_TEST_MCP_URL not set — skipping connection test"
                    );
                    return;
                }
            }
        };
    }

    fn identity_files_present(dir: &Path) -> bool {
        dir.join("identity.pem").exists() && dir.join("identity_key.pem").exists()
    }

    fn read_cert_fingerprint(dir: &Path) -> Option<String> {
        // Read the raw cert bytes — we use its content as a proxy for identity
        // equality across two builder invocations.
        std::fs::read_to_string(dir.join("identity.pem")).ok()
    }

    // ─── Credential tests (1 onramp registration each) ───────────────────────

    /// Two-step handshake only: verify credential shape.
    #[tokio::test]
    async fn onramp_register_only_returns_valid_credentials() {
        let gw = require_gateway!();

        let creds = register_only(&base_opts("handshake", &gw))
            .await
            .expect("onramp handshake should succeed");

        assert!(!creds.client_id.is_empty(), "client_id must be non-empty");
        assert!(
            !creds.client_secret.is_empty(),
            "client_secret must be non-empty"
        );
        assert!(
            creds.token_url.starts_with("http"),
            "token_url must be a URL, got: {}",
            creds.token_url
        );
        assert!(!creds.scopes.is_empty(), "scopes must be non-empty");
        assert!(creds.expires_in > 0, "expires_in must be positive");

        eprintln!(
            "[onramp] credentials OK — client_id={}, mcp_url={:?}",
            creds.client_id, creds.mcp_url
        );
    }

    /// Handshake + token exchange: verify we get a usable Bearer token back.
    #[tokio::test]
    async fn onramp_register_and_exchange_returns_token() {
        let gw = require_gateway!();

        let (creds, token) = register_and_exchange(&base_opts("exchange", &gw))
            .await
            .expect("onramp + token exchange should succeed");

        assert!(!token.is_empty(), "access token must be non-empty");

        eprintln!(
            "[onramp] token exchange OK — token_len={}, mcp_url={:?}",
            token.len(),
            creds.mcp_url
        );
    }

    /// Server now includes mcp_url in the onramp/complete response.
    #[tokio::test]
    async fn onramp_complete_response_includes_mcp_url() {
        let gw = require_gateway!();

        let creds = register_only(&base_opts("mcp-url", &gw))
            .await
            .expect("onramp handshake should succeed");

        assert!(
            creds.mcp_url.is_some(),
            "mcp_url must be present in the complete response; got None — \
             check that the server includes mcp_url in the /onramp/complete JSON body"
        );

        let mcp_url = creds.mcp_url.unwrap();
        assert!(
            mcp_url.contains("/mcp"),
            "mcp_url should end in /mcp, got: {mcp_url}"
        );

        eprintln!("[onramp] mcp_url OK — {mcp_url}");
    }

    // ─── Bootstrap + connection tests (require DG_TEST_MCP_URL) ─────────────

    /// Full autonomous flow: bootstrap_onramp produces a client that can connect
    /// and list tools.
    #[tokio::test]
    async fn bootstrap_onramp_client_connects_and_lists_tools() {
        let gw = require_gateway!();
        let mcp_url = require_mcp_url!();
        let tmp = tempfile::tempdir().expect("tempdir");

        let client = ClientBuilder::new()
            .url(&mcp_url)
            .identity_dir(tmp.path())
            .bootstrap_onramp(base_opts("full", &gw))
            .await
            .expect("bootstrap_onramp should succeed")
            .build()
            .expect("build should succeed");

        client.connect().await.expect("connect should succeed");

        let tools = client
            .list_tools()
            .await
            .expect("list_tools should succeed");

        assert!(
            !tools.is_empty(),
            "tool list should be non-empty after connect"
        );

        eprintln!(
            "[onramp] full bootstrap OK — {} tools available",
            tools.len()
        );
    }

    /// Verify the mTLS identity files land on disk after bootstrap_onramp.
    #[tokio::test]
    async fn bootstrap_onramp_persists_identity_to_dir() {
        let gw = require_gateway!();
        let mcp_url = require_mcp_url!();
        let tmp = tempfile::tempdir().expect("tempdir");

        ClientBuilder::new()
            .url(&mcp_url)
            .identity_dir(tmp.path())
            .bootstrap_onramp(base_opts("persist", &gw))
            .await
            .expect("bootstrap_onramp should succeed")
            .build()
            .expect("build should succeed");

        assert!(
            identity_files_present(tmp.path()),
            "identity.pem and identity_key.pem must exist in identity_dir after bootstrap"
        );

        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            let key_mode = std::fs::metadata(tmp.path().join("identity_key.pem"))
                .unwrap()
                .permissions()
                .mode();
            assert_eq!(
                key_mode & 0o777,
                0o600,
                "identity_key.pem must be mode 0600"
            );
        }

        eprintln!(
            "[onramp] identity persisted OK — dir={}",
            tmp.path().display()
        );
    }

    /// bootstrap_onramp persists the server URL alongside the identity files.
    ///
    /// This is the prerequisite for zero-config restarts — if no `server_url` is
    /// saved, subsequent builds can't reconstruct the URL.
    #[tokio::test]
    async fn bootstrap_onramp_persists_server_url_to_dir() {
        let gw = require_gateway!();
        let mcp_url = require_mcp_url!();
        let tmp = tempfile::tempdir().expect("tempdir");

        ClientBuilder::new()
            .url(&mcp_url)
            .identity_dir(tmp.path())
            .bootstrap_onramp(base_opts("url-persist", &gw))
            .await
            .expect("bootstrap_onramp should succeed")
            .build()
            .expect("build should succeed");

        let saved_url = try_read_server_url(Some(tmp.path()));
        assert!(
            saved_url.is_some(),
            "server_url file must exist in identity_dir after bootstrap"
        );

        let saved = saved_url.unwrap();
        assert!(
            saved.contains("/mcp"),
            "saved URL should be the MCP endpoint, got: {saved}"
        );

        eprintln!("[onramp] server_url persisted OK — {saved}");
    }

    /// Second run via with_identity_auto — no URL or credentials needed.
    ///
    /// This is the core zero-config restart test. After a first bootstrap_onramp
    /// run, a brand-new ClientBuilder with only identity_dir set should be able
    /// to build and connect without any URL or credentials — both are recovered
    /// from disk.
    #[tokio::test]
    async fn second_run_with_identity_auto_requires_no_url_or_credentials() {
        let gw = require_gateway!();
        let mcp_url = require_mcp_url!();
        let tmp = tempfile::tempdir().expect("tempdir");

        // First run: full bootstrap.
        ClientBuilder::new()
            .url(&mcp_url)
            .identity_dir(tmp.path())
            .bootstrap_onramp(base_opts("zero-cfg", &gw))
            .await
            .expect("first bootstrap_onramp should succeed")
            .build()
            .expect("first build should succeed");

        assert!(
            identity_files_present(tmp.path()),
            "identity files must exist before second run"
        );
        assert!(
            try_read_server_url(Some(tmp.path())).is_some(),
            "server_url must be saved before second run"
        );

        // Second run: zero-config — no URL, no credentials, no explicit identity
        // loading.  The builder recovers everything from identity_dir.
        let client2 = ClientBuilder::new()
            .identity_dir(tmp.path())
            .with_identity_auto() // recovers both cert and URL
            .build()
            .expect("second build without URL or credentials should succeed");

        client2
            .connect()
            .await
            .expect("second client connect should succeed");

        eprintln!("[onramp] zero-config restart OK — URL and identity auto-discovered");
    }

    /// build() fallback: URL recovered from disk without with_identity_auto.
    ///
    /// Even without calling with_identity_auto(), build() itself attempts URL
    /// recovery as a last resort. This covers callers who manually load an
    /// identity via with_identity() but forget to provide a URL.
    #[tokio::test]
    async fn build_recovers_url_from_disk_without_with_identity_auto() {
        let gw = require_gateway!();
        let mcp_url = require_mcp_url!();
        let tmp = tempfile::tempdir().expect("tempdir");

        // First run: full bootstrap saves identity + URL to tmp.
        ClientBuilder::new()
            .url(&mcp_url)
            .identity_dir(tmp.path())
            .bootstrap_onramp(base_opts("build-recover", &gw))
            .await
            .expect("first bootstrap_onramp should succeed")
            .build()
            .expect("first build should succeed");

        // Second run: no URL, no with_identity_auto — build() recovers the URL.
        let client2 = ClientBuilder::new()
            .identity_dir(tmp.path())
            // Deliberately NOT calling with_identity_auto — build() should
            // still find the URL from the server_url file.
            .build()
            .expect("build() should recover URL from identity_dir without with_identity_auto");

        client2
            .connect()
            .await
            .expect("second client connect should succeed");

        eprintln!("[onramp] build() URL recovery OK");
    }

    /// bootstrap_onramp short-circuits on an existing valid identity.
    ///
    /// Calling bootstrap_onramp twice to the same identity_dir must NOT create
    /// a second machine account — the existing cert is reused and no network
    /// calls to the onramp endpoints are made.
    #[tokio::test]
    async fn bootstrap_onramp_second_call_reuses_existing_identity() {
        let gw = require_gateway!();
        let mcp_url = require_mcp_url!();
        let tmp = tempfile::tempdir().expect("tempdir");

        // First run: genuine onramp + registration.
        ClientBuilder::new()
            .url(&mcp_url)
            .identity_dir(tmp.path())
            .bootstrap_onramp(base_opts("short-circuit-a", &gw))
            .await
            .expect("first bootstrap_onramp should succeed")
            .build()
            .expect("first build should succeed");

        let cert_after_first = read_cert_fingerprint(tmp.path())
            .expect("identity.pem must exist after first bootstrap");

        // Second run: different agent_name to prove it's NOT registering a new
        // identity (if it were, the cert content would change).
        ClientBuilder::new()
            .url(&mcp_url)
            .identity_dir(tmp.path())
            .bootstrap_onramp(base_opts("short-circuit-b", &gw))
            .await
            .expect("second bootstrap_onramp should succeed")
            .build()
            .expect("second build should succeed");

        let cert_after_second = read_cert_fingerprint(tmp.path())
            .expect("identity.pem must still exist after second bootstrap");

        assert_eq!(
            cert_after_first, cert_after_second,
            "cert must be unchanged after second bootstrap_onramp — \
             short-circuit should have skipped registration entirely"
        );

        eprintln!("[onramp] short-circuit OK — cert unchanged after second bootstrap_onramp");
    }

    /// Short-circuit preserves the URL from the saved server_url file.
    ///
    /// When bootstrap_onramp takes the fast path (existing identity), the
    /// builder must still have a URL set so that build() succeeds without the
    /// caller providing one.
    #[tokio::test]
    async fn bootstrap_onramp_short_circuit_restores_url() {
        let gw = require_gateway!();
        let mcp_url = require_mcp_url!();
        let tmp = tempfile::tempdir().expect("tempdir");

        // First run: genuine bootstrap.
        ClientBuilder::new()
            .url(&mcp_url)
            .identity_dir(tmp.path())
            .bootstrap_onramp(base_opts("sc-url-a", &gw))
            .await
            .expect("first bootstrap_onramp should succeed")
            .build()
            .expect("first build should succeed");

        // Second run: no explicit URL — the short-circuit path must recover it.
        let client2 = ClientBuilder::new()
            .identity_dir(tmp.path())
            .bootstrap_onramp(base_opts("sc-url-b", &gw))
            .await
            .expect("second bootstrap_onramp (short-circuit) should succeed")
            .build()
            .expect("build without explicit URL should succeed after short-circuit");

        client2
            .connect()
            .await
            .expect("connect should succeed after short-circuit");

        eprintln!("[onramp] short-circuit URL recovery OK");
    }

    // ─── Cert-loss recovery ──────────────────────────────────────────────────

    /// After bootstrap_onramp, deleting the cert files and calling
    /// bootstrap_onramp again must re-register a cert for the **same** machine
    /// account (same client_id from credentials.json) rather than creating a
    /// new account via onramp.
    #[tokio::test]
    async fn bootstrap_onramp_recovers_from_lost_cert_using_saved_credentials() {
        let gw = require_gateway!();
        let mcp_url = require_mcp_url!();
        let tmp = tempfile::tempdir().expect("tempdir");

        // First run: genuine onramp + registration, saves credentials + cert.
        ClientBuilder::new()
            .url(&mcp_url)
            .identity_dir(tmp.path())
            .bootstrap_onramp(base_opts("cert-loss-a", &gw))
            .await
            .expect("first bootstrap_onramp should succeed")
            .build()
            .expect("first build should succeed");

        let saved = try_load_credentials(Some(tmp.path()))
            .expect("credentials.json must exist after first bootstrap");
        let original_client_id = saved.client_id.clone();

        // Simulate cert loss — delete the identity files.
        std::fs::remove_file(tmp.path().join("identity.pem")).expect("remove identity.pem");
        std::fs::remove_file(tmp.path().join("identity_key.pem")).expect("remove identity_key.pem");

        assert!(
            !tmp.path().join("identity.pem").exists(),
            "cert must be gone before second run"
        );

        // Second run: no cert, but saved credentials exist.
        // Should NOT create a new account — reuses the saved client_id.
        ClientBuilder::new()
            .url(&mcp_url)
            .identity_dir(tmp.path())
            .bootstrap_onramp(base_opts("cert-loss-b", &gw))
            .await
            .expect("second bootstrap_onramp (cert recovery) should succeed")
            .build()
            .expect("second build should succeed");

        assert!(
            tmp.path().join("identity.pem").exists(),
            "identity.pem must be re-created after recovery"
        );

        // The client_id in credentials.json must not have changed — same account.
        let after = try_load_credentials(Some(tmp.path()))
            .expect("credentials.json must still exist after recovery");
        assert_eq!(
            after.client_id, original_client_id,
            "client_id must be unchanged after cert recovery — \
             re-used saved credentials, did not create a new account"
        );

        eprintln!(
            "[onramp] cert-loss recovery OK — client_id={} preserved",
            original_client_id
        );
    }

    /// Recovered client can connect after cert-loss recovery.
    #[tokio::test]
    async fn bootstrap_onramp_cert_recovery_produces_connectable_client() {
        let gw = require_gateway!();
        let mcp_url = require_mcp_url!();
        let tmp = tempfile::tempdir().expect("tempdir");

        ClientBuilder::new()
            .url(&mcp_url)
            .identity_dir(tmp.path())
            .bootstrap_onramp(base_opts("cert-conn-a", &gw))
            .await
            .expect("first bootstrap should succeed")
            .build()
            .expect("first build should succeed");

        // Simulate cert loss.
        std::fs::remove_file(tmp.path().join("identity.pem")).unwrap();
        std::fs::remove_file(tmp.path().join("identity_key.pem")).unwrap();

        let client = ClientBuilder::new()
            .identity_dir(tmp.path())
            .bootstrap_onramp(base_opts("cert-conn-b", &gw))
            .await
            .expect("recovery bootstrap should succeed")
            .build()
            .expect("build should succeed");

        client
            .connect()
            .await
            .expect("connect after cert recovery should succeed");

        let tools = client
            .list_tools()
            .await
            .expect("list_tools should succeed");
        assert!(!tools.is_empty());

        eprintln!("[onramp] cert-loss connectable OK — {} tools", tools.len());
    }

    /// bootstrap_onramp saves credentials.json alongside the identity.
    #[tokio::test]
    async fn bootstrap_onramp_persists_credentials_to_dir() {
        let gw = require_gateway!();
        let mcp_url = require_mcp_url!();
        let tmp = tempfile::tempdir().expect("tempdir");

        ClientBuilder::new()
            .url(&mcp_url)
            .identity_dir(tmp.path())
            .bootstrap_onramp(base_opts("creds-persist", &gw))
            .await
            .expect("bootstrap_onramp should succeed")
            .build()
            .expect("build should succeed");

        let creds = try_load_credentials(Some(tmp.path()))
            .expect("credentials.json must exist after bootstrap");

        assert!(
            creds.client_id.starts_with("agt_"),
            "client_id must have agt_ prefix"
        );
        assert!(
            !creds.client_secret.is_empty(),
            "client_secret must be non-empty"
        );
        assert!(
            creds.token_url.starts_with("http"),
            "token_url must be a URL, got: {}",
            creds.token_url
        );

        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            let mode = std::fs::metadata(tmp.path().join("credentials.json"))
                .unwrap()
                .permissions()
                .mode();
            assert_eq!(mode & 0o777, 0o600, "credentials.json must be mode 0600");
        }

        eprintln!(
            "[onramp] credentials persisted OK — client_id={}",
            creds.client_id
        );
    }

    // ─── rotation_days configuration ─────────────────────────────────────────

    /// rotation_days(365) treats every fresh cert as "expiring soon" (since DG
    /// issues 30-day certs, which fall within the 365-day window).  Verify the
    /// rotation path fires and the cert changes on the second call.
    #[tokio::test]
    async fn rotation_days_large_forces_rotation_path() {
        let gw = require_gateway!();
        let mcp_url = require_mcp_url!();
        let tmp = tempfile::tempdir().expect("tempdir");

        // First run: genuine bootstrap — get a fresh cert + credentials.json.
        ClientBuilder::new()
            .url(&mcp_url)
            .identity_dir(tmp.path())
            .bootstrap_onramp(base_opts("rotdays-a", &gw))
            .await
            .expect("first bootstrap should succeed")
            .build()
            .expect("first build should succeed");

        let cert_before = read_cert_fingerprint(tmp.path()).unwrap();

        // Second run: rotation_days(365) treats any cert expiring within a year
        // as "needs rotation".  A fresh 30-day DG cert satisfies that, so
        // bootstrap_identity_with_endpoint's mTLS rotation path fires.
        ClientBuilder::new()
            .url(&mcp_url)
            .identity_dir(tmp.path())
            .rotation_days(365)
            .bootstrap_onramp(base_opts("rotdays-b", &gw))
            .await
            .expect("second bootstrap with rotation_days(365) should succeed")
            .build()
            .expect("build should succeed");

        let cert_after = read_cert_fingerprint(tmp.path()).unwrap();

        // The cert should be replaced because the rotation threshold exceeded
        // the cert's remaining validity.
        assert_ne!(
            cert_before, cert_after,
            "cert should be rotated when rotation_days exceeds remaining validity"
        );

        eprintln!("[onramp] rotation_days(365) OK — cert was rotated");
    }

    // ─── Human (existing credentials) path ──────────────────────────────────

    fn human_creds() -> Option<(String, String, String)> {
        let client_id = std::env::var("DG_TEST_CLIENT_ID").ok()?;
        let client_secret = std::env::var("DG_TEST_CLIENT_SECRET").ok()?;
        let mcp_url = std::env::var("DG_TEST_MCP_URL").ok()?;
        Some((client_id, client_secret, mcp_url))
    }

    /// Human path: existing client_id + client_secret → bootstrap_identity_oauth → mTLS client.
    #[tokio::test]
    async fn bootstrap_identity_oauth_human_path() {
        let (client_id, client_secret, mcp_url) = match human_creds() {
            Some(c) => c,
            None => {
                eprintln!(
                    "[onramp_integration] DG_TEST_CLIENT_ID/SECRET/MCP_URL not set — skipping"
                );
                return;
            }
        };

        let tmp = tempfile::tempdir().expect("tempdir");

        let client = ClientBuilder::new()
            .url(&mcp_url)
            .identity_dir(tmp.path())
            .bootstrap_identity_oauth(client_id, client_secret, "conduit-human-test")
            .await
            .expect("bootstrap_identity_oauth should succeed")
            .build()
            .expect("build should succeed");

        client.connect().await.expect("connect should succeed");

        let tools = client
            .list_tools()
            .await
            .expect("list_tools should succeed");

        assert!(!tools.is_empty(), "tool list should be non-empty");

        // Verify URL was saved alongside the identity.
        assert!(
            try_read_server_url(Some(tmp.path())).is_some(),
            "server_url must be saved after bootstrap_identity_oauth"
        );

        eprintln!(
            "[onramp] human path OK — {} tools, identity_dir={}",
            tools.len(),
            tmp.path().display()
        );
    }
}

#[cfg(not(feature = "bootstrap"))]
#[test]
fn onramp_integration_requires_bootstrap_feature() {
    eprintln!("Re-run with --features bootstrap to enable onramp integration tests");
}
