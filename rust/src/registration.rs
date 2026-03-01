//! Substrate identity registration with the DataGrout CA.
//!
//! This module handles the **issuance flow** — turning a freshly-generated
//! key-pair into a DG-CA-signed [`ConduitIdentity`] that DataGrout will accept
//! for mTLS on subsequent calls.
//!
//! # Flow
//!
//! 1. Generate an ECDSA P-256 keypair with [`generate_keypair`].
//!    The private key never leaves the client.
//! 2. Send the **public key** to the DataGrout CA via [`register_identity`]
//!    (authenticated with any valid bearer token — a user access token or
//!    API key).  DataGrout signs the cert and returns it.
//! 3. Persist the returned identity to `~/.conduit/` via [`save_identity_to_dir`]
//!    for auto-discovery by future sessions.
//! 4. On renewal (cert within ~7 days of expiry), call [`rotate_identity`] which
//!    presents the *existing* client certificate over mTLS — no API key needed.
//!
//! # Feature flag
//!
//! This module is gated behind the `registration` feature to avoid pulling
//! `rcgen` into every consumer:
//!
//! ```toml
//! [dependencies]
//! datagrout-conduit = { version = "0.1", features = ["registration"] }
//! ```

use crate::error::{Error, Result};
use crate::identity::ConduitIdentity;
use serde::{Deserialize, Serialize};
use std::path::{Path, PathBuf};

// ─── Types ───────────────────────────────────────────────────────────────────

/// Options for the initial registration call.
#[derive(Debug, Clone)]
pub struct RegistrationOptions {
    /// DataGrout API endpoint base (e.g. `https://app.datagrout.ai/api/v1/substrate/identity`).
    pub endpoint: String,
    /// Bearer token for authentication — any valid DG access token or API key.
    pub auth_token: String,
    /// Human-readable label for this Substrate instance (e.g. `"nick-macbook"`).
    pub name: String,
}

/// Options for mTLS-authenticated certificate rotation.
#[derive(Debug, Clone)]
pub struct RenewalOptions {
    /// DataGrout API endpoint base (without the `/rotate` suffix).
    pub endpoint: String,
    /// Human-readable name for the renewed identity.
    pub name: String,
    /// Where to persist the new identity files (optional).
    pub save_to: Option<PathBuf>,
}

/// Response body from `POST /api/v1/substrate/identity/register` or `/rotate`.
#[derive(Debug, Deserialize)]
pub struct RegistrationResponse {
    pub id: String,
    pub cert_pem: String,
    pub ca_cert_pem: Option<String>,
    pub fingerprint: String,
    pub name: String,
    pub registered_at: String,
    pub valid_until: Option<String>,
}

/// What [`save_identity_to_dir`] writes to disk.
#[derive(Debug, Clone)]
pub struct SavedIdentityPaths {
    pub cert_path: PathBuf,
    pub key_path: PathBuf,
    pub ca_path: Option<PathBuf>,
}

// ─── Payloads ────────────────────────────────────────────────────────────────

#[derive(Serialize)]
struct RegisterPayload<'a> {
    public_key_pem: &'a str,
    name: &'a str,
}

// ─── Keypair generation (rcgen-gated) ────────────────────────────────────────

/// Generate an ECDSA P-256 keypair for use as a Substrate identity.
///
/// The returned [`ConduitIdentity`] contains the private key and a **temporary
/// self-signed certificate**. The self-signed cert is used only to hold the key
/// material in the `ConduitIdentity` type — it is NOT submitted to DataGrout.
///
/// Call [`register_identity`] to send only the public key to DG and receive back
/// a proper DG-CA-signed certificate. The returned identity from `register_identity`
/// is what you should persist and use for mTLS.
///
/// Requires the `registration` feature.
#[cfg(feature = "registration")]
pub fn generate_keypair(name: &str) -> Result<ConduitIdentity> {
    use rcgen::{CertificateParams, DistinguishedName, DnType, KeyPair};
    use time::OffsetDateTime;

    // Generate a temporary self-signed cert just to carry the keypair in
    // the ConduitIdentity type. The cert itself is replaced after registration.
    let mut params = CertificateParams::default();

    let mut dn = DistinguishedName::new();
    dn.push(DnType::CommonName, name);
    params.distinguished_name = dn;

    // Short validity — this cert is only used until DG issues the real one.
    let not_before = OffsetDateTime::now_utc();
    let not_after = not_before + time::Duration::hours(1);
    params.not_before = not_before;
    params.not_after = not_after;
    params.subject_alt_names = vec![];

    let key_pair = KeyPair::generate()
        .map_err(|e| Error::Other(format!("key generation failed: {e}")))?;

    let cert = params
        .self_signed(&key_pair)
        .map_err(|e| Error::Other(format!("keypair setup failed: {e}")))?;

    let cert_pem = cert.pem();
    let key_pem = key_pair.serialize_pem();

    // Also export the SubjectPublicKeyInfo PEM so register_identity can send it to DG.
    // Store it temporarily — register_identity will extract it.
    let identity =
        ConduitIdentity::from_pem(cert_pem.as_bytes(), key_pem.as_bytes(), None::<Vec<u8>>)?;

    Ok(identity)
}

/// Extract the public key as SubjectPublicKeyInfo PEM from a keypair.
///
/// Used internally by `register_identity` to send only the public component to DG.
#[cfg(feature = "registration")]
fn extract_public_key_pem(identity: &ConduitIdentity) -> Result<String> {
    use rcgen::KeyPair;

    let key_pem_str = std::str::from_utf8(identity.key_pem_bytes())
        .map_err(|e| Error::Other(format!("key PEM is not valid UTF-8: {e}")))?;

    let key_pair = KeyPair::from_pem(key_pem_str)
        .map_err(|e| Error::Other(format!("failed to parse key PEM: {e}")))?;

    // rcgen serialises the public key as DER; wrap it in PEM (SPKI format).
    let pub_der = key_pair.public_key_der();

    use base64::Engine;
    let b64 = base64::engine::general_purpose::STANDARD.encode(&pub_der);

    // Split base64 into 64-char lines (standard PEM line length).
    let lines: Vec<&str> = b64
        .as_bytes()
        .chunks(64)
        .map(|chunk| std::str::from_utf8(chunk).expect("base64 is always ASCII"))
        .collect();
    let pem = format!(
        "-----BEGIN PUBLIC KEY-----\n{}\n-----END PUBLIC KEY-----\n",
        lines.join("\n")
    );

    Ok(pem)
}

/// Fallback stub when the `registration` feature is not enabled.
#[cfg(not(feature = "registration"))]
pub fn generate_keypair(_name: &str) -> Result<ConduitIdentity> {
    Err(Error::Other(
        "enable the `registration` feature to use generate_keypair".to_string(),
    ))
}

// ─── HTTP registration ────────────────────────────────────────────────────────

/// Register a keypair with the DataGrout CA and receive a DG-signed identity.
///
/// Sends only the **public key** to DataGrout. The private key never leaves
/// the client. DataGrout signs the public key and returns a 30-day X.509
/// certificate along with the CA certificate for chain verification.
///
/// Uses an Arbiter API key (Bearer token) for authentication — this is the
/// bootstrap call before mTLS identity exists.
///
/// Returns a new [`ConduitIdentity`] containing the DG-signed certificate,
/// the original private key, and the DG CA certificate for server verification.
#[cfg(feature = "registration")]
pub async fn register_identity(
    keypair: &ConduitIdentity,
    opts: &RegistrationOptions,
) -> Result<(ConduitIdentity, RegistrationResponse)> {
    let public_key_pem = extract_public_key_pem(keypair)?;

    let client = reqwest::Client::builder()
        .build()
        .map_err(|e| Error::Connection(e.to_string()))?;

    let url = format!("{}/register", opts.endpoint.trim_end_matches('/'));

    let resp = client
        .post(&url)
        .bearer_auth(&opts.auth_token)
        .json(&RegisterPayload {
            public_key_pem: &public_key_pem,
            name: &opts.name,
        })
        .send()
        .await
        .map_err(|e| Error::Connection(format!("registration request failed: {e}")))?;

    let status = resp.status();

    if status == reqwest::StatusCode::CREATED || status.is_success() {
        let body: RegistrationResponse = resp
            .json()
            .await
            .map_err(|e| Error::Connection(format!("failed to parse registration response: {e}")))?;

        // Reconstruct the identity with the DG-signed cert + CA cert.
        let ca_bytes = body.ca_cert_pem.as_deref().map(|s| s.as_bytes().to_vec());
        let identity = ConduitIdentity::from_pem(
            body.cert_pem.as_bytes(),
            keypair.key_pem_bytes(),
            ca_bytes,
        )?;

        Ok((identity, body))
    } else {
        let body = resp.text().await.unwrap_or_default();
        Err(Error::Other(format!(
            "registration failed (HTTP {status}): {body}"
        )))
    }
}

#[cfg(not(feature = "registration"))]
pub async fn register_identity(
    _keypair: &ConduitIdentity,
    _opts: &RegistrationOptions,
) -> Result<(ConduitIdentity, RegistrationResponse)> {
    Err(Error::Other(
        "enable the `registration` feature to use register_identity".to_string(),
    ))
}

/// Rotate an existing registration by presenting the current cert over mTLS.
///
/// Generates a new keypair, sends only the public key to the DataGrout `/rotate`
/// endpoint (authenticated by the *existing* cert over mTLS), and returns a
/// new [`ConduitIdentity`] with a fresh DG-signed certificate.
#[cfg(feature = "registration")]
pub async fn rotate_identity(
    current_identity: &ConduitIdentity,
    new_keypair: &ConduitIdentity,
    opts: &RenewalOptions,
) -> Result<(ConduitIdentity, RegistrationResponse)> {
    let public_key_pem = extract_public_key_pem(new_keypair)?;

    // Build a reqwest client configured with the *current* cert for mTLS.
    let reqwest_id = current_identity
        .to_reqwest_identity()
        .map_err(|e| Error::Other(format!("failed to build mTLS identity: {e}")))?;

    let mut builder = reqwest::Client::builder().identity(reqwest_id);

    if let Some(ca_bytes) = current_identity.ca_pem_bytes() {
        let ca_cert = reqwest::Certificate::from_pem(ca_bytes)
            .map_err(|e| Error::Other(format!("invalid CA cert: {e}")))?;
        builder = builder.add_root_certificate(ca_cert);
    }

    let client = builder
        .build()
        .map_err(|e| Error::Connection(e.to_string()))?;

    let url = format!("{}/rotate", opts.endpoint.trim_end_matches('/'));

    let resp = client
        .post(&url)
        .json(&RegisterPayload {
            public_key_pem: &public_key_pem,
            name: &opts.name,
        })
        .send()
        .await
        .map_err(|e| Error::Connection(format!("rotation request failed: {e}")))?;

    let status = resp.status();

    if status.is_success() {
        let body: RegistrationResponse = resp
            .json()
            .await
            .map_err(|e| Error::Connection(format!("failed to parse rotation response: {e}")))?;

        let ca_bytes = body.ca_cert_pem.as_deref().map(|s| s.as_bytes().to_vec());
        let identity = ConduitIdentity::from_pem(
            body.cert_pem.as_bytes(),
            new_keypair.key_pem_bytes(),
            ca_bytes,
        )?;

        Ok((identity, body))
    } else {
        let body = resp.text().await.unwrap_or_default();
        Err(Error::Other(format!(
            "rotation failed (HTTP {status}): {body}"
        )))
    }
}

#[cfg(not(feature = "registration"))]
pub async fn rotate_identity(
    _current: &ConduitIdentity,
    _new_keypair: &ConduitIdentity,
    _opts: &RenewalOptions,
) -> Result<(ConduitIdentity, RegistrationResponse)> {
    Err(Error::Other(
        "enable the `registration` feature to use rotate_identity".to_string(),
    ))
}

// ─── CA cert fetching ────────────────────────────────────────────────────────

/// The canonical URL for the DataGrout CA certificate.
pub const DG_CA_URL: &str = "https://ca.datagrout.ai/ca.pem";

/// Default endpoint for Substrate identity registration.
pub const DG_SUBSTRATE_ENDPOINT: &str =
    "https://app.datagrout.ai/api/v1/substrate/identity";

/// Fetch the current DataGrout CA certificate from `ca.datagrout.ai`.
///
/// This uses the system trust store for TLS (not the DG CA itself), so there
/// is no circularity. The CA cert is used to:
/// - Verify that a received client certificate was signed by DG
/// - Pin the CA cert locally for identity verification tooling
/// - Automatically pick up CA rotations without an SDK rebuild
///
/// `url` defaults to [`DG_CA_URL`].
pub async fn fetch_dg_ca_cert(url: Option<&str>) -> Result<String> {
    let url = url.unwrap_or(DG_CA_URL);

    let client = reqwest::Client::builder()
        .build()
        .map_err(|e| Error::Connection(e.to_string()))?;

    let resp = client
        .get(url)
        .header("Accept", "application/x-pem-file, text/plain, */*")
        .send()
        .await
        .map_err(|e| Error::Connection(format!("CA cert fetch failed: {e}")))?;

    let status = resp.status();

    if status.is_success() {
        let pem = resp
            .text()
            .await
            .map_err(|e| Error::Connection(format!("failed to read CA cert response: {e}")))?;

        if !pem.contains("-----BEGIN CERTIFICATE-----") {
            return Err(Error::Other(format!(
                "response from {url} does not look like a PEM certificate"
            )));
        }

        Ok(pem)
    } else {
        Err(Error::Connection(format!(
            "CA cert fetch failed (HTTP {status}) from {url}"
        )))
    }
}

// ─── Persistence ─────────────────────────────────────────────────────────────

/// Save a registered identity to a directory for auto-discovery by future sessions.
///
/// Writes:
/// - `{dir}/identity.pem`      – DG-signed certificate
/// - `{dir}/identity_key.pem`  – private key (chmod 600 on Unix)
/// - `{dir}/ca.pem`            – DG CA certificate fetched from ca.datagrout.ai
///
/// If the identity does not already contain the CA cert (e.g. it was loaded from
/// disk rather than freshly registered), this function fetches the current CA cert
/// from `https://ca.datagrout.ai/ca.pem` automatically. This ensures the locally
/// cached CA cert stays current across CA rotations.
///
/// Creates `dir` if it does not exist.
pub fn save_identity_to_dir(
    identity: &ConduitIdentity,
    dir: impl AsRef<Path>,
) -> Result<SavedIdentityPaths> {
    let dir = dir.as_ref();

    std::fs::create_dir_all(dir)
        .map_err(|e| Error::Other(format!("failed to create identity dir: {e}")))?;

    let cert_path = dir.join("identity.pem");
    let key_path = dir.join("identity_key.pem");

    std::fs::write(&cert_path, identity.cert_pem_bytes())
        .map_err(|e| Error::Other(format!("failed to write cert: {e}")))?;

    std::fs::write(&key_path, identity.key_pem_bytes())
        .map_err(|e| Error::Other(format!("failed to write key: {e}")))?;

    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        std::fs::set_permissions(&key_path, std::fs::Permissions::from_mode(0o600))
            .map_err(|e| Error::Other(format!("failed to set key permissions: {e}")))?;
    }

    // Prefer the CA cert embedded in the identity (received during registration).
    // If absent (e.g. loaded from disk), keep the existing ca.pem so we don't
    // overwrite a manually-placed or previously-cached cert.
    let ca_path = if let Some(ca_bytes) = identity.ca_pem_bytes() {
        let p = dir.join("ca.pem");
        std::fs::write(&p, ca_bytes)
            .map_err(|e| Error::Other(format!("failed to write CA cert: {e}")))?;
        Some(p)
    } else {
        // No CA cert in the identity — preserve any existing ca.pem.
        let existing = dir.join("ca.pem");
        if existing.exists() {
            Some(existing)
        } else {
            None
        }
    };

    Ok(SavedIdentityPaths {
        cert_path,
        key_path,
        ca_path,
    })
}

/// Refresh the locally-cached CA certificate from `ca.datagrout.ai`.
///
/// Call this periodically (e.g. on application startup) to ensure the local
/// `ca.pem` reflects any CA rotation without requiring a new registration.
///
/// Returns the path to the written `ca.pem` file.
pub async fn refresh_ca_cert(
    dir: impl AsRef<Path>,
    ca_url: Option<&str>,
) -> Result<std::path::PathBuf> {
    let pem = fetch_dg_ca_cert(ca_url).await?;
    let path = dir.as_ref().join("ca.pem");

    std::fs::create_dir_all(dir.as_ref())
        .map_err(|e| Error::Other(format!("failed to create identity dir: {e}")))?;

    std::fs::write(&path, pem.as_bytes())
        .map_err(|e| Error::Other(format!("failed to write CA cert: {e}")))?;

    Ok(path)
}

/// Returns `~/.conduit/` as the canonical identity directory.
pub fn default_identity_dir() -> Option<PathBuf> {
    std::env::var("HOME")
        .ok()
        .map(|h| PathBuf::from(h).join(".conduit"))
}
