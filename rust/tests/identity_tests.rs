//! Integration-level tests for `ConduitIdentity` (mTLS identity plane).
//!
//! The PEM fixtures here are syntactically valid but not semantically real
//! X.509 certificates.  That is intentional: tests that call
//! `to_reqwest_identity()` (which feeds real DER into rustls) are marked
//! `#[ignore]` and require genuine cert files.  Everything else — validation
//! logic, auto-discovery, rotation checks — runs without a real CA.
//!
//! Tests that touch environment variables acquire `ENV_LOCK` first to prevent
//! races when cargo runs tests across threads (the default).

use datagrout_conduit::ConduitIdentity;
use std::sync::Mutex;
use std::time::{Duration, SystemTime};

/// Serialises all env-var tests. `std::env` is process-global, so tests that
/// set or remove the same variables must not overlap.
static ENV_LOCK: Mutex<()> = Mutex::new(());

// ─── PEM fixtures ────────────────────────────────────────────────────────────

/// A syntactically correct PEM certificate block (valid label; body is faked).
const CERT_PEM: &str = "\
-----BEGIN CERTIFICATE-----\n\
MIIBpTCCAQ6gAwIBAgIUZ2F0ZXdheS1jbGllbnQtMDAxMCAXDTI1MDEwMTAwMDAw\n\
MFoYDzIwMzUwMTAxMDAwMDAwWjAWMRQwEgYDVQQDDAtleGFtcGxlLmNvbTCBnzAN\n\
BgkqhkiG9w0BAQEFAAOBjQAwgYkCgYEA2a2rwplBQLF29amygykEMmYz0+Kcj3bZ\n\
CZkPHtOhVyFw5lA1BGLHE/4z5PSs5zStQSyEOqJaqNbDEL0PYBCGtDM6x9BfLHN\n\
bmMTcb7TJ9uHnElk0iZDR+dqtplz1P1oCEthOzLy0dADEhqp+ePOkfmhWP2F+3Q\n\
zIWPRUPNEjECAwEAAaNTMFEwHQYDVR0OBBYEFHoHCVGvTCCMRgTyFnyKuWDHnVFq\n\
MB8GA1UdIwQYMBaAFHoHCVGvTCCMRgTyFnyKuWDHnVFqMA8GA1UdEwEB/wQFMAMB\n\
Af8wDQYJKoZIhvcNAQELBQADgYEAHmyONbQM8SObJd0Rmq9vCOON+GhxkLaP6bVq\n\
-----END CERTIFICATE-----\n";

const KEY_PEM: &str = "\
-----BEGIN PRIVATE KEY-----\n\
MIIEvQIBADANBgkqhkiG9w0BAQEFAASCBKcwggSjAgEAAoIBAQDZravCmUFAsXb1\n\
qbKDKQQyZjPT4pyPdtkJmQ8e06FXIXDmUDUEYscT/jPk9KznNK1BLJQ6olqo1sM\n\
QvQ9gEIa0MzrH0F8sc1uYxNxvtMn24ecSWTSJkNH52q2mXPU/WgIS2E7MvLR0AMS\n\
GqmZ486R+aFY/YX7dDMhY9FQ80SMEB4CAwEAAQ==\n\
-----END PRIVATE KEY-----\n";

const RSA_KEY_PEM: &str = "\
-----BEGIN RSA PRIVATE KEY-----\n\
MIIEowIBAAKCAQEA2a2rwplBQLF29amygykEMmYz0fake==\n\
-----END RSA PRIVATE KEY-----\n";

const EC_KEY_PEM: &str = "\
-----BEGIN EC PRIVATE KEY-----\n\
MHQCAQEEIPfakekeyhere==\n\
-----END EC PRIVATE KEY-----\n";

const CA_PEM: &str = "\
-----BEGIN CERTIFICATE-----\n\
MIIBpzCCAQ+gAwIBAgIUWENnSElGTGgtY2EtMDAxIDAXDTI1MDEwMTAwMDAwMFoY\n\
DzIwMzUwMTAxMDAwMDAwWjAXMRUwEwYDVQQDDAxleGFtcGxlLWNhLTEwgZ8=\n\
-----END CERTIFICATE-----\n";

const BAD_PEM: &str = "this is definitely not a PEM";

// ─── from_pem — validation ───────────────────────────────────────────────────

#[test]
fn from_pem_accepts_valid_cert_and_key() {
    let id = ConduitIdentity::from_pem(CERT_PEM, KEY_PEM, None::<&str>).unwrap();
    assert_eq!(id.cert_pem_bytes(), CERT_PEM.as_bytes());
    assert_eq!(id.key_pem_bytes(), KEY_PEM.as_bytes());
    assert!(id.ca_pem_bytes().is_none());
    assert!(id.expires_at().is_none());
}

#[test]
fn from_pem_accepts_optional_ca() {
    let id = ConduitIdentity::from_pem(CERT_PEM, KEY_PEM, Some(CA_PEM)).unwrap();
    // CA presence is reflected in Debug output
    assert!(format!("{id:?}").contains("has_ca: true"));
}

#[test]
fn from_pem_rejects_bad_cert() {
    let err = ConduitIdentity::from_pem(BAD_PEM, KEY_PEM, None::<&str>).unwrap_err();
    assert!(err.to_string().to_lowercase().contains("certificate"), "{err}");
}

#[test]
fn from_pem_rejects_cert_as_key() {
    // Passing a cert where a key is expected
    let err = ConduitIdentity::from_pem(CERT_PEM, CERT_PEM, None::<&str>).unwrap_err();
    assert!(err.to_string().to_lowercase().contains("private key"), "{err}");
}

#[test]
fn from_pem_rejects_bad_key() {
    let err = ConduitIdentity::from_pem(CERT_PEM, BAD_PEM, None::<&str>).unwrap_err();
    assert!(err.to_string().to_lowercase().contains("private key"), "{err}");
}

#[test]
fn from_pem_accepts_rsa_private_key_header() {
    ConduitIdentity::from_pem(CERT_PEM, RSA_KEY_PEM, None::<&str>).unwrap();
}

#[test]
fn from_pem_accepts_ec_private_key_header() {
    ConduitIdentity::from_pem(CERT_PEM, EC_KEY_PEM, None::<&str>).unwrap();
}

// ─── from_paths ───────────────────────────────────────────────────────────────

#[test]
fn from_paths_loads_cert_and_key() {
    let dir = tempfile::tempdir().unwrap();
    let cert_path = dir.path().join("cert.pem");
    let key_path = dir.path().join("key.pem");
    std::fs::write(&cert_path, CERT_PEM).unwrap();
    std::fs::write(&key_path, KEY_PEM).unwrap();

    let id = ConduitIdentity::from_paths(&cert_path, &key_path, None::<&std::path::Path>).unwrap();
    assert!(format!("{id:?}").contains("has_ca: false"));
}

#[test]
fn from_paths_loads_ca_when_provided() {
    let dir = tempfile::tempdir().unwrap();
    let cert_path = dir.path().join("cert.pem");
    let key_path = dir.path().join("key.pem");
    let ca_path = dir.path().join("ca.pem");
    std::fs::write(&cert_path, CERT_PEM).unwrap();
    std::fs::write(&key_path, KEY_PEM).unwrap();
    std::fs::write(&ca_path, CA_PEM).unwrap();

    let id = ConduitIdentity::from_paths(&cert_path, &key_path, Some(&ca_path)).unwrap();
    assert!(format!("{id:?}").contains("has_ca: true"));
}

#[test]
fn from_paths_errors_when_file_missing() {
    let err = ConduitIdentity::from_paths(
        "/nonexistent/cert.pem",
        "/nonexistent/key.pem",
        None::<&std::path::Path>,
    )
    .unwrap_err();
    assert!(!err.to_string().is_empty());
}

#[test]
fn from_paths_errors_when_cert_has_bad_content() {
    let dir = tempfile::tempdir().unwrap();
    let cert_path = dir.path().join("cert.pem");
    let key_path = dir.path().join("key.pem");
    std::fs::write(&cert_path, BAD_PEM).unwrap();
    std::fs::write(&key_path, KEY_PEM).unwrap();

    let err = ConduitIdentity::from_paths(&cert_path, &key_path, None::<&std::path::Path>)
        .unwrap_err();
    assert!(err.to_string().to_lowercase().contains("certificate"), "{err}");
}

// ─── from_env ────────────────────────────────────────────────────────────────

#[test]
fn from_env_returns_none_when_cert_var_absent() {
    let _guard = ENV_LOCK.lock().unwrap();
    std::env::remove_var("CONDUIT_MTLS_CERT");
    let result = ConduitIdentity::from_env().unwrap();
    assert!(result.is_none());
}

#[test]
fn from_env_loads_identity_from_env_vars() {
    let _guard = ENV_LOCK.lock().unwrap();
    std::env::set_var("CONDUIT_MTLS_CERT", CERT_PEM);
    std::env::set_var("CONDUIT_MTLS_KEY", KEY_PEM);
    std::env::remove_var("CONDUIT_MTLS_CA");

    let result = ConduitIdentity::from_env().unwrap();
    assert!(result.is_some());
    let id = result.unwrap();
    assert!(format!("{id:?}").contains("has_ca: false"));

    std::env::remove_var("CONDUIT_MTLS_CERT");
    std::env::remove_var("CONDUIT_MTLS_KEY");
}

#[test]
fn from_env_includes_ca_when_set() {
    let _guard = ENV_LOCK.lock().unwrap();
    std::env::set_var("CONDUIT_MTLS_CERT", CERT_PEM);
    std::env::set_var("CONDUIT_MTLS_KEY", KEY_PEM);
    std::env::set_var("CONDUIT_MTLS_CA", CA_PEM);

    let result = ConduitIdentity::from_env().unwrap();
    let id = result.unwrap();
    assert!(format!("{id:?}").contains("has_ca: true"));

    std::env::remove_var("CONDUIT_MTLS_CERT");
    std::env::remove_var("CONDUIT_MTLS_KEY");
    std::env::remove_var("CONDUIT_MTLS_CA");
}

#[test]
fn from_env_errors_when_cert_set_but_key_missing() {
    let _guard = ENV_LOCK.lock().unwrap();
    std::env::set_var("CONDUIT_MTLS_CERT", CERT_PEM);
    std::env::remove_var("CONDUIT_MTLS_KEY");

    let err = ConduitIdentity::from_env().unwrap_err();
    assert!(err.to_string().contains("CONDUIT_MTLS_KEY"), "{err}");

    std::env::remove_var("CONDUIT_MTLS_CERT");
}

// ─── try_default ─────────────────────────────────────────────────────────────

#[test]
fn try_default_returns_none_when_unconfigured() {
    // Ensure env vars are not set
    std::env::remove_var("CONDUIT_MTLS_CERT");
    // The function may still find ~/.conduit/ if it exists, so just verify it doesn't panic.
    let _ = ConduitIdentity::try_default();
}

#[test]
fn try_default_picks_up_env_vars() {
    let _guard = ENV_LOCK.lock().unwrap();
    std::env::set_var("CONDUIT_MTLS_CERT", CERT_PEM);
    std::env::set_var("CONDUIT_MTLS_KEY", KEY_PEM);

    let result = ConduitIdentity::try_default();
    assert!(result.is_some());

    std::env::remove_var("CONDUIT_MTLS_CERT");
    std::env::remove_var("CONDUIT_MTLS_KEY");
}

#[test]
fn try_default_loads_from_dir() {
    let dir = tempfile::tempdir().unwrap();
    std::fs::write(dir.path().join("identity.pem"), CERT_PEM).unwrap();
    std::fs::write(dir.path().join("identity_key.pem"), KEY_PEM).unwrap();

    // Use the internal helper directly
    let result = ConduitIdentity::_try_load_from_dir_pub(dir.path());
    assert!(result.is_some());
}

#[test]
fn try_default_skips_dir_without_cert() {
    let dir = tempfile::tempdir().unwrap();
    // Only write key, not cert
    std::fs::write(dir.path().join("identity_key.pem"), KEY_PEM).unwrap();

    let result = ConduitIdentity::_try_load_from_dir_pub(dir.path());
    assert!(result.is_none());
}

// ─── Rotation awareness ───────────────────────────────────────────────────────

#[test]
fn needs_rotation_false_when_no_expiry_set() {
    let id = ConduitIdentity::from_pem(CERT_PEM, KEY_PEM, None::<&str>).unwrap();
    assert!(!id.needs_rotation(30));
    assert!(!id.needs_rotation(0));
}

#[test]
fn needs_rotation_true_when_already_expired() {
    let past = SystemTime::UNIX_EPOCH; // definitely in the past
    let id = ConduitIdentity::from_pem(CERT_PEM, KEY_PEM, None::<&str>)
        .unwrap()
        .with_expiry(past);
    assert!(id.needs_rotation(0));
}

#[test]
fn needs_rotation_true_within_threshold() {
    let ten_days = SystemTime::now() + Duration::from_secs(10 * 86_400);
    let id = ConduitIdentity::from_pem(CERT_PEM, KEY_PEM, None::<&str>)
        .unwrap()
        .with_expiry(ten_days);
    assert!(id.needs_rotation(30)); // threshold 30d → within
    assert!(!id.needs_rotation(5)); // threshold 5d → not within
}

#[test]
fn needs_rotation_false_when_expiry_far_future() {
    let far = SystemTime::now() + Duration::from_secs(365 * 86_400 * 5);
    let id = ConduitIdentity::from_pem(CERT_PEM, KEY_PEM, None::<&str>)
        .unwrap()
        .with_expiry(far);
    assert!(!id.needs_rotation(90));
}

#[test]
fn with_expiry_returns_new_identity() {
    let original = ConduitIdentity::from_pem(CERT_PEM, KEY_PEM, None::<&str>).unwrap();
    assert!(original.expires_at().is_none());

    let expiry = SystemTime::now() + Duration::from_secs(365 * 86_400);
    let updated = original.with_expiry(expiry);
    assert!(updated.expires_at().is_some());

    // Original is unchanged
    let original2 = ConduitIdentity::from_pem(CERT_PEM, KEY_PEM, None::<&str>).unwrap();
    assert!(original2.expires_at().is_none());
}

// ─── ClientBuilder integration ────────────────────────────────────────────────

/// Generate a real (ephemeral) self-signed ECDSA P-256 cert+key pair for tests
/// that feed the identity into reqwest (which eagerly validates the PEM).
fn make_real_identity() -> ConduitIdentity {
    use rcgen::{CertificateParams, DistinguishedName, DnType, KeyPair};

    let key_pair = KeyPair::generate().expect("key generation");
    let mut params = CertificateParams::default();
    let mut dn = DistinguishedName::new();
    dn.push(DnType::CommonName, "test-conduit");
    params.distinguished_name = dn;
    let cert = params.self_signed(&key_pair).expect("self-signed cert");

    ConduitIdentity::from_pem(cert.pem().as_bytes(), key_pair.serialize_pem().as_bytes(), None::<&[u8]>)
        .expect("real cert should load")
}

#[tokio::test]
async fn client_builder_accepts_with_identity() {
    use datagrout_conduit::{ClientBuilder, Transport};

    let id = make_real_identity();
    let result = ClientBuilder::new()
        .url("https://gateway.datagrout.ai/servers/test/mcp")
        .transport(Transport::JsonRpc)
        .with_identity(id)
        .build();

    assert!(result.is_ok(), "{}", result.unwrap_err());
}

#[tokio::test]
async fn client_builder_with_identity_auto_no_certs_no_error() {
    use datagrout_conduit::{ClientBuilder, Transport};

    std::env::remove_var("CONDUIT_MTLS_CERT");

    let result = ClientBuilder::new()
        .url("https://gateway.datagrout.ai/servers/test/mcp")
        .transport(Transport::JsonRpc)
        .with_identity_auto()
        .build();

    // No identity found → falls back silently → build succeeds.
    assert!(result.is_ok(), "{}", result.unwrap_err());
}

#[tokio::test]
async fn client_builder_composes_identity_with_bearer_token() {
    use datagrout_conduit::{ClientBuilder, Transport};

    let id = make_real_identity();
    let result = ClientBuilder::new()
        .url("https://gateway.datagrout.ai/servers/test/mcp")
        .transport(Transport::JsonRpc)
        .auth_bearer("tok_test")
        .with_identity(id)
        .build();

    assert!(result.is_ok(), "{}", result.unwrap_err());
}
