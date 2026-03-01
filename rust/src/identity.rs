//! Identity and mTLS support for Conduit connections.
//!
//! A [`ConduitIdentity`] holds the client certificate and private key used for
//! mutual TLS.  When one is present, the transport layer presents it during
//! every TLS handshake — the server can verify who the caller is without any
//! application-layer token.
//!
//! # Auto-discovery order
//!
//! [`ConduitIdentity::try_default`] walks the following chain and returns the
//! first identity it finds:
//!
//! 1. `CONDUIT_MTLS_CERT` + `CONDUIT_MTLS_KEY` (+ optional `CONDUIT_MTLS_CA`)
//!    environment variables (PEM strings).
//! 2. `CONDUIT_IDENTITY_DIR` environment variable — a directory containing
//!    `identity.pem` and `identity_key.pem`.  Useful for running multiple
//!    agents on the same machine with distinct identities.
//! 3. `~/.conduit/identity.pem` + `~/.conduit/identity_key.pem`
//!    (+ optional `~/.conduit/ca.pem`).
//! 4. `.conduit/identity.pem` relative to the current working directory.
//!
//! If none of the above locations exist the function returns `None` and the
//! transport falls back to bearer token / API key auth as before — nothing
//! breaks.
//!
//! # Rotation awareness
//!
//! [`ConduitIdentity`] can optionally carry the certificate's expiry timestamp.
//! Call [`ConduitIdentity::needs_rotation`] to check whether the cert is within
//! `threshold_days` of expiry.  Actual re-registration with the DataGrout CA
//! is handled separately (see `ArbiterHub` registration flow, planned).

use crate::error::{Error, Result};
use std::path::{Path, PathBuf};
use std::time::{Duration, SystemTime};

/// A Conduit client identity — the cert + key pair used for mTLS.
///
/// Construct via [`from_pem`](Self::from_pem), [`from_paths`](Self::from_paths),
/// [`from_env`](Self::from_env), or [`try_default`](Self::try_default).
#[derive(Clone)]
pub struct ConduitIdentity {
    /// PEM-encoded X.509 client certificate.
    cert_pem: Vec<u8>,
    /// PEM-encoded private key (PKCS#8 or PKCS#1).
    key_pem: Vec<u8>,
    /// PEM-encoded CA certificate(s) for verifying the *server* cert.
    /// When `None` the system trust store is used.
    ca_pem: Option<Vec<u8>>,
    /// Certificate expiry, if known.  Set via [`with_expiry`](Self::with_expiry).
    expires_at: Option<SystemTime>,
}

impl std::fmt::Debug for ConduitIdentity {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("ConduitIdentity")
            .field("cert_pem", &"<redacted>")
            .field("key_pem", &"<redacted>")
            .field("has_ca", &self.ca_pem.is_some())
            .field("expires_at", &self.expires_at)
            .finish()
    }
}

impl ConduitIdentity {
    // ─── Constructors ────────────────────────────────────────────────────────

    /// Build an identity from PEM bytes already in memory.
    ///
    /// `cert_pem` and `key_pem` are separate PEM blobs; they do not need to be
    /// concatenated before calling this function.
    pub fn from_pem(
        cert_pem: impl Into<Vec<u8>>,
        key_pem: impl Into<Vec<u8>>,
        ca_pem: Option<impl Into<Vec<u8>>>,
    ) -> Result<Self> {
        let cert_pem = cert_pem.into();
        let key_pem = key_pem.into();

        // Basic sanity checks — fail early rather than getting a cryptic TLS error later.
        if !pem_contains(&cert_pem, "CERTIFICATE") {
            return Err(Error::invalid_config(
                "cert_pem does not appear to contain a PEM certificate",
            ));
        }
        if !pem_has_private_key(&key_pem) {
            return Err(Error::invalid_config(
                "key_pem does not appear to contain a PEM private key",
            ));
        }

        Ok(Self {
            cert_pem,
            key_pem,
            ca_pem: ca_pem.map(Into::into),
            expires_at: None,
        })
    }

    /// Build an identity by reading files from disk.
    ///
    /// `ca_path` is optional; pass `None` to use the system trust store.
    pub fn from_paths(
        cert_path: impl AsRef<Path>,
        key_path: impl AsRef<Path>,
        ca_path: Option<impl AsRef<Path>>,
    ) -> Result<Self> {
        let cert_pem = std::fs::read(cert_path.as_ref()).map_err(|e| {
            Error::invalid_config(format!(
                "cannot read cert at {}: {e}",
                cert_path.as_ref().display()
            ))
        })?;

        let key_pem = std::fs::read(key_path.as_ref()).map_err(|e| {
            Error::invalid_config(format!(
                "cannot read key at {}: {e}",
                key_path.as_ref().display()
            ))
        })?;

        let ca_pem = ca_path
            .map(|p| {
                std::fs::read(p.as_ref()).map_err(|e| {
                    Error::invalid_config(format!(
                        "cannot read CA at {}: {e}",
                        p.as_ref().display()
                    ))
                })
            })
            .transpose()?;

        Self::from_pem(cert_pem, key_pem, ca_pem)
    }

    /// Build an identity from environment variables.
    ///
    /// Variables:
    /// - `CONDUIT_MTLS_CERT` — PEM string for the client certificate
    /// - `CONDUIT_MTLS_KEY`  — PEM string for the private key
    /// - `CONDUIT_MTLS_CA`   — PEM string for the CA (optional)
    ///
    /// Returns `None` if `CONDUIT_MTLS_CERT` is not set.
    pub fn from_env() -> Result<Option<Self>> {
        let cert = match std::env::var("CONDUIT_MTLS_CERT") {
            Ok(v) if !v.is_empty() => v,
            _ => return Ok(None),
        };

        let key = std::env::var("CONDUIT_MTLS_KEY").map_err(|_| {
            Error::invalid_config(
                "CONDUIT_MTLS_CERT is set but CONDUIT_MTLS_KEY is missing",
            )
        })?;

        let ca = std::env::var("CONDUIT_MTLS_CA").ok().filter(|s| !s.is_empty());

        Self::from_pem(cert.into_bytes(), key.into_bytes(), ca.map(String::into_bytes)).map(Some)
    }

    /// Try to locate an identity using the auto-discovery chain described in
    /// the module docs.  Returns `None` if nothing is found (not an error).
    pub fn try_default() -> Option<Self> {
        Self::try_discover(None)
    }

    /// Like [`try_default`](Self::try_default) but checks `override_dir` first.
    ///
    /// Discovery order:
    /// 1. `override_dir` (if `Some`)
    /// 2. `CONDUIT_MTLS_CERT` + `CONDUIT_MTLS_KEY` env vars
    /// 3. `CONDUIT_IDENTITY_DIR` env var
    /// 4. `~/.conduit/`
    /// 5. `.conduit/` relative to cwd
    pub fn try_discover(override_dir: Option<&Path>) -> Option<Self> {
        // 0. Explicit override directory
        if let Some(dir) = override_dir {
            if let Some(id) = Self::try_load_from_dir(dir) {
                tracing::debug!("conduit: loaded mTLS identity from {}", dir.display());
                return Some(id);
            }
        }

        // 1. Environment variables (individual cert/key PEMs)
        if let Ok(Some(id)) = Self::from_env() {
            tracing::debug!("conduit: loaded mTLS identity from environment variables");
            return Some(id);
        }

        // 2. CONDUIT_IDENTITY_DIR env var
        if let Ok(dir_str) = std::env::var("CONDUIT_IDENTITY_DIR") {
            let dir = PathBuf::from(&dir_str);
            if let Some(id) = Self::try_load_from_dir(&dir) {
                tracing::debug!(
                    "conduit: loaded mTLS identity from CONDUIT_IDENTITY_DIR={}",
                    dir.display()
                );
                return Some(id);
            }
        }

        // 3. ~/.conduit/
        if let Some(home_dir) = dirs_next() {
            let dir = home_dir.join(".conduit");
            if let Some(id) = Self::try_load_from_dir(&dir) {
                tracing::debug!(
                    "conduit: loaded mTLS identity from {}",
                    dir.display()
                );
                return Some(id);
            }
        }

        // 4. .conduit/ relative to cwd
        if let Ok(cwd) = std::env::current_dir() {
            let dir = cwd.join(".conduit");
            if let Some(id) = Self::try_load_from_dir(&dir) {
                tracing::debug!(
                    "conduit: loaded mTLS identity from {}",
                    dir.display()
                );
                return Some(id);
            }
        }

        tracing::debug!("conduit: no mTLS identity found, using token auth");
        None
    }

    // ─── Builder-style setters ────────────────────────────────────────────────

    /// Attach a known expiry time so [`needs_rotation`](Self::needs_rotation)
    /// can give accurate results.
    pub fn with_expiry(mut self, expires_at: SystemTime) -> Self {
        self.expires_at = Some(expires_at);
        self
    }

    // ─── Introspection ────────────────────────────────────────────────────────

    /// Returns `true` if the certificate expires within `threshold_days`.
    ///
    /// Returns `false` if no expiry is set — call [`with_expiry`](Self::with_expiry)
    /// or use the DataGrout registration flow to populate this field.
    pub fn needs_rotation(&self, threshold_days: u64) -> bool {
        match self.expires_at {
            None => false,
            Some(exp) => {
                let threshold = Duration::from_secs(threshold_days * 86_400);
                SystemTime::now()
                    .checked_add(threshold)
                    .map(|deadline| deadline > exp)
                    .unwrap_or(false)
            }
        }
    }

    /// Return the expiry timestamp, if known.
    pub fn expires_at(&self) -> Option<SystemTime> {
        self.expires_at
    }

    // ─── Public accessors ─────────────────────────────────────────────────────

    /// Returns the PEM-encoded client certificate bytes.
    pub fn cert_pem_bytes(&self) -> &[u8] {
        &self.cert_pem
    }

    /// Returns the PEM-encoded private key bytes.
    pub fn key_pem_bytes(&self) -> &[u8] {
        &self.key_pem
    }

    /// Returns the PEM-encoded CA certificate bytes, if any.
    pub fn ca_pem_bytes(&self) -> Option<&[u8]> {
        self.ca_pem.as_deref()
    }

    // ─── Test helpers ─────────────────────────────────────────────────────────

    /// Exposes `try_load_from_dir` for integration tests.
    #[doc(hidden)]
    pub fn _try_load_from_dir_pub(dir: &Path) -> Option<Self> {
        Self::try_load_from_dir(dir)
    }

    // ─── reqwest integration ──────────────────────────────────────────────────

    /// Convert this identity into a `reqwest::Identity`.
    ///
    /// reqwest (with `rustls-tls`) expects the key and cert concatenated in a
    /// single PEM blob.  The order is key first, cert second.
    pub(crate) fn to_reqwest_identity(&self) -> Result<reqwest::Identity> {
        // Combine: key PEM first, then cert PEM (rustls requirement).
        let mut combined = self.key_pem.clone();
        if !combined.ends_with(b"\n") {
            combined.push(b'\n');
        }
        combined.extend_from_slice(&self.cert_pem);

        reqwest::Identity::from_pem(&combined)
            .map_err(|e| Error::invalid_config(format!("failed to build mTLS identity: {e}")))
    }

    /// If a custom CA is set, return it as a `reqwest::Certificate`.
    pub(crate) fn to_reqwest_ca(&self) -> Result<Option<reqwest::Certificate>> {
        match &self.ca_pem {
            None => Ok(None),
            Some(pem) => {
                let cert = reqwest::Certificate::from_pem(pem).map_err(|e| {
                    Error::invalid_config(format!("failed to parse CA certificate: {e}"))
                })?;
                Ok(Some(cert))
            }
        }
    }

    // ─── Helpers ─────────────────────────────────────────────────────────────

    fn try_load_from_dir(dir: &Path) -> Option<Self> {
        let cert = dir.join("identity.pem");
        let key = dir.join("identity_key.pem");

        if !cert.exists() || !key.exists() {
            return None;
        }

        let ca = dir.join("ca.pem");
        let ca_opt: Option<PathBuf> = if ca.exists() { Some(ca) } else { None };

        match Self::from_paths(&cert, &key, ca_opt) {
            Ok(id) => Some(id),
            Err(e) => {
                tracing::warn!("conduit: identity at {} is invalid: {e}", dir.display());
                None
            }
        }
    }
}

// ─── Internal PEM helpers (no extra deps needed) ─────────────────────────────

fn pem_contains(pem: &[u8], label: &str) -> bool {
    if let Ok(s) = std::str::from_utf8(pem) {
        s.contains(&format!("-----BEGIN {label}-----"))
    } else {
        false
    }
}

fn pem_has_private_key(pem: &[u8]) -> bool {
    if let Ok(s) = std::str::from_utf8(pem) {
        s.contains("-----BEGIN PRIVATE KEY-----")
            || s.contains("-----BEGIN RSA PRIVATE KEY-----")
            || s.contains("-----BEGIN EC PRIVATE KEY-----")
            || s.contains("-----BEGIN ENCRYPTED PRIVATE KEY-----")
    } else {
        false
    }
}

/// Portable home-directory lookup.  Tries `$HOME` first, then falls back to
/// the standard dirs approach if the `dirs` crate were available.  We avoid
/// adding the `dirs` crate dep by just reading `$HOME`/`$USERPROFILE`.
fn dirs_next() -> Option<PathBuf> {
    std::env::var("HOME")
        .or_else(|_| std::env::var("USERPROFILE"))
        .ok()
        .map(PathBuf::from)
}

// ─── Tests ───────────────────────────────────────────────────────────────────

#[cfg(test)]
mod tests {
    use super::*;

    const SAMPLE_CERT: &str = "-----BEGIN CERTIFICATE-----\nMIIBIjANBgkqhkiG9w0BAQEFAAOCAQ8AMIIBCgKCAQEA\n-----END CERTIFICATE-----\n";
    const SAMPLE_KEY: &str = "-----BEGIN PRIVATE KEY-----\nMIIEvAIBADANBgkqhkiG9w0BAQEFAASCBKYwggSiAgEA\n-----END PRIVATE KEY-----\n";
    const BAD_PEM: &str = "this is not a pem";

    #[test]
    fn from_pem_validates_cert() {
        let err = ConduitIdentity::from_pem(BAD_PEM, SAMPLE_KEY, None::<Vec<u8>>).unwrap_err();
        assert!(err.to_string().contains("certificate"), "{err}");
    }

    #[test]
    fn from_pem_validates_key() {
        let err = ConduitIdentity::from_pem(SAMPLE_CERT, BAD_PEM, None::<Vec<u8>>).unwrap_err();
        assert!(err.to_string().contains("private key"), "{err}");
    }

    #[test]
    fn from_pem_accepts_valid_pems() {
        // Won't build a real reqwest::Identity from fake PEMs, but construction succeeds.
        let id =
            ConduitIdentity::from_pem(SAMPLE_CERT, SAMPLE_KEY, None::<Vec<u8>>).unwrap();
        assert!(!id.needs_rotation(30));
    }

    #[test]
    fn needs_rotation_false_when_no_expiry() {
        let id =
            ConduitIdentity::from_pem(SAMPLE_CERT, SAMPLE_KEY, None::<Vec<u8>>).unwrap();
        assert!(!id.needs_rotation(90));
    }

    #[test]
    fn needs_rotation_true_when_expiry_in_past() {
        let id = ConduitIdentity::from_pem(SAMPLE_CERT, SAMPLE_KEY, None::<Vec<u8>>)
            .unwrap()
            .with_expiry(SystemTime::UNIX_EPOCH); // already expired
        assert!(id.needs_rotation(0));
    }

    #[test]
    fn needs_rotation_false_when_expiry_far_future() {
        let far_future = SystemTime::now() + Duration::from_secs(365 * 86_400 * 10);
        let id = ConduitIdentity::from_pem(SAMPLE_CERT, SAMPLE_KEY, None::<Vec<u8>>)
            .unwrap()
            .with_expiry(far_future);
        assert!(!id.needs_rotation(30));
    }

    #[test]
    fn from_env_returns_none_when_vars_absent() {
        // Don't set env vars — just ensure it returns None cleanly.
        std::env::remove_var("CONDUIT_MTLS_CERT");
        assert!(ConduitIdentity::from_env().unwrap().is_none());
    }
}
