//! Integration tests for the identity registration flow.
//!
//! These tests use `mockito` to simulate the DataGrout registration endpoint,
//! so no network access is required.

use datagrout_conduit::registration::{
    register_identity, save_identity_to_dir, RegistrationOptions,
};

// ─── Shared PEM fixtures ──────────────────────────────────────────────────────

const CERT_PEM: &str = "-----BEGIN CERTIFICATE-----\n\
MIIBhzCCAS2gAwIBAgIUao9uFkLfJy0xVomv71SndxLDMRMwCgYIKoZIzj0EAwIw\n\
GTEXMBUGA1UEAwwOdGVzdC1zdWJzdHJhdGUwHhcNMjYwMjIwMDYzOTUyWhcNMjcw\n\
MjIwMDYzOTUyWjAZMRcwFQYDVQQDDA50ZXN0LXN1YnN0cmF0ZTBZMBMGByqGSM49\n\
AgEGCCqGSM49AwEHA0IABEo5cT6LMNdl/qtjX1gBIc4dUwvDeA9/v1rkXs3aCNUK\n\
8ksSP/PFPUE7zWObRa509E+yR3WWlzivMQ0CfRAUzPWjUzBRMB0GA1UdDgQWBBSg\n\
cWDOHV/nYefQda12rUivSe7p5DAfBgNVHSMEGDAWgBSgcWDOHV/nYefQda12rUiv\n\
Se7p5DAPBgNVHRMBAf8EBTADAQH/MAoGCCqGSM49BAMCA0gAMEUCIQCy1+wH/u9V\n\
KLM8HDV9PmIcDChtBCStPnCBvUuouOrzlwIgRiWcLdukpeuSUkMSOwtJ3VLOmjvg\n\
7plz+qwVSU/KYf8=\n\
-----END CERTIFICATE-----\n";

const KEY_PEM: &str = "-----BEGIN PRIVATE KEY-----\n\
MIGHAgEAMBMGByqGSM49AgEGCCqGSM49AwEHBG0wawIBAQQghG7yzhh14w6XNvfo\n\
SGDxcMtNsPEpdzYwW+UrgE+zC8mhRANCAARKOXE+izDXZf6rY19YASHOHVMLw3gP\n\
f79a5F7N2gjVCvJLEj/zxT1BO81jm0WudPRPskd1lpc4rzENAn0QFMz1\n\
-----END PRIVATE KEY-----\n";

// A DG-signed certificate that the server would return after registration
const DG_SIGNED_CERT_PEM: &str = "-----BEGIN CERTIFICATE-----\n\
MIIBpTCCAQ6gAwIBAgIUZ2F0ZXdheS1jbGllbnQtMDAxMCAXDTI1MDEwMTAwMDAw\n\
MFoYDzIwMzUwMTAxMDAwMDAwWjAWMRQwEgYDVQQDDAtleGFtcGxlLmNvbTCBnzAN\n\
BgkqhkiG9w0BAQEFAAOBjQAwgYkCgYEA2a2rwplBQLzm3sXbgkPHtOhVyFw5lA1B\n\
GLHE/4z5PSs5zStQSyEOqJaqNbDEL0PYBCGtDM6x9BfLHNbmMTcb7TJ9uHnElk0i\n\
ZDR+dqtplz1P1oCEthOzLy0dADEhqp+ePOkfmhWP2F+3QzIWPRUPNEjECAwEAAaNT\n\
MFEwHQYDVR0OBBYEFHoHCVGvTCCMRgTyFnyKuWDHnVFqMB8GA1UdIwQYMBaAFHoH\n\
CVGvTCCMRgTyFnyKuWDHnVFqMA8GA1UdEwEB/wQFMAMBAf8=\n\
-----END CERTIFICATE-----\n";

fn make_identity() -> datagrout_conduit::ConduitIdentity {
    datagrout_conduit::ConduitIdentity::from_pem(CERT_PEM, KEY_PEM, None::<Vec<u8>>)
        .expect("fixture PEM should be valid")
}

// ─── generate_keypair ─────────────────────────────────────────────────────────

#[cfg(feature = "registration")]
#[test]
fn generate_keypair_produces_valid_identity() {
    use datagrout_conduit::registration::generate_keypair;

    let identity = generate_keypair("test-substrate")
        .expect("should generate without error");

    let cert = String::from_utf8_lossy(identity.cert_pem_bytes());
    assert!(cert.contains("BEGIN CERTIFICATE"), "cert_pem should be a cert");

    let key = String::from_utf8_lossy(identity.key_pem_bytes());
    assert!(key.contains("BEGIN"), "key_pem should be a key");
}

#[cfg(feature = "registration")]
#[test]
fn generate_keypair_rotation_flag_not_set_for_new_cert() {
    use datagrout_conduit::registration::generate_keypair;

    let identity = generate_keypair("test-node")
        .expect("should generate");

    // A freshly-generated keypair has no server-assigned expiry yet
    // (expiry is set after the server returns a signed cert), so
    // needs_rotation should be false.
    assert!(!identity.needs_rotation(30), "fresh keypair should not need rotation");
}

// ─── register_identity (mocked DG CA flow) ────────────────────────────────────
//
// The new flow: client sends public_key_pem → DG CA signs it → server returns
// a DG-signed cert_pem (plus optional ca_cert_pem and fingerprint).
// These tests require the `registration` feature (which pulls in rcgen).

#[cfg(feature = "registration")]
#[tokio::test]
async fn register_identity_sends_public_key_and_token() {
    let mut server = mockito::Server::new_async().await;

    let mock = server
        .mock("POST", "/register")
        .match_header("authorization", "Bearer test-access-token")
        .match_body(mockito::Matcher::Regex(
            r#"public_key_pem"#.to_string(),
        ))
        .with_status(201)
        .with_header("content-type", "application/json")
        .with_body(format!(
            r#"{{
                "id": "sub_abc123",
                "fingerprint": "aa:bb:cc:dd",
                "name": "test-substrate",
                "cert_pem": "{}",
                "ca_cert_pem": null,
                "registered_at": "2026-02-13T00:00:00Z",
                "valid_until": "2027-02-13T00:00:00Z"
            }}"#,
            DG_SIGNED_CERT_PEM.replace('\n', "\\n")
        ))
        .create_async()
        .await;

    let identity = make_identity();
    let resp = register_identity(
        &identity,
        &RegistrationOptions {
            endpoint: server.url(),
            auth_token: "test-access-token".to_string(),
            name: "test-substrate".to_string(),
        },
    )
    .await
    .expect("registration should succeed");

    let (_identity, reg) = resp;
    assert_eq!(reg.id, "sub_abc123");
    assert_eq!(reg.fingerprint, "aa:bb:cc:dd");
    assert!(reg.cert_pem.contains("BEGIN CERTIFICATE"), "should return a DG-signed cert");
    mock.assert_async().await;
}

#[cfg(feature = "registration")]
#[tokio::test]
async fn register_identity_returns_error_on_4xx() {
    let mut server = mockito::Server::new_async().await;

    server
        .mock("POST", "/register")
        .with_status(422)
        .with_header("content-type", "application/json")
        .with_body(r#"{"error":"invalid public key"}"#)
        .create_async()
        .await;

    let identity = make_identity();
    let err = register_identity(
        &identity,
        &RegistrationOptions {
            endpoint: server.url(),
            auth_token: "key".to_string(),
            name: "bad".to_string(),
        },
    )
    .await
    .expect_err("should fail on 422");

    assert!(err.to_string().contains("422"), "error should mention status: {err}");
}

#[cfg(feature = "registration")]
#[tokio::test]
async fn register_identity_returns_error_on_server_error() {
    let mut server = mockito::Server::new_async().await;

    server
        .mock("POST", "/register")
        .with_status(500)
        .with_body("internal error")
        .create_async()
        .await;

    let identity = make_identity();
    let err = register_identity(
        &identity,
        &RegistrationOptions {
            endpoint: server.url(),
            auth_token: "key".to_string(),
            name: "node".to_string(),
        },
    )
    .await
    .expect_err("should fail on 500");

    assert!(err.to_string().contains("500"), "{err}");
}

// ─── save_identity_to_dir ─────────────────────────────────────────────────────

#[test]
fn save_identity_to_dir_writes_cert_and_key() {
    let dir = tempfile::tempdir().expect("temp dir");
    let identity = make_identity();

    let paths = save_identity_to_dir(&identity, dir.path())
        .expect("should save without error");

    assert!(paths.cert_path.exists(), "cert file should exist");
    assert!(paths.key_path.exists(), "key file should exist");

    let cert_contents = std::fs::read_to_string(&paths.cert_path).unwrap();
    assert!(cert_contents.contains("BEGIN CERTIFICATE"));
}

#[test]
fn save_identity_to_dir_creates_dir_if_missing() {
    let base = tempfile::tempdir().expect("temp dir");
    let nested = base.path().join("deep").join("nested");

    let identity = make_identity();
    save_identity_to_dir(&identity, &nested).expect("should create dirs and save");

    assert!(nested.join("identity.pem").exists());
}

#[test]
fn save_identity_to_dir_sets_restrictive_key_permissions() {
    #[cfg(unix)]
    {
        use std::os::unix::fs::MetadataExt;

        let dir = tempfile::tempdir().expect("temp dir");
        let identity = make_identity();
        let paths = save_identity_to_dir(&identity, dir.path()).unwrap();

        let mode = std::fs::metadata(&paths.key_path).unwrap().mode() & 0o777;
        assert_eq!(mode, 0o600, "key file should be 0600, got {:o}", mode);
    }
}

// ─── default_identity_dir ─────────────────────────────────────────────────────

#[test]
fn default_identity_dir_returns_home_conduit() {
    use datagrout_conduit::registration::default_identity_dir;

    if std::env::var("HOME").is_err() {
        return;
    }

    let dir = default_identity_dir().expect("should return a path");
    assert!(dir.ends_with(".conduit"), "should end with .conduit: {dir:?}");
}
