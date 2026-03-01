/**
 * Substrate identity registration with the DataGrout CA.
 *
 * Flow:
 * 1. Generate an ECDSA P-256 keypair locally — private key never leaves the client.
 * 2. Send only the public key to DataGrout via {@link registerIdentity}.
 *    DG signs and returns the certificate + CA cert.
 * 3. Persist to `~/.conduit/` via {@link saveIdentity}.
 * 4. On renewal, call {@link rotateIdentity} — authenticated by mTLS, no API key needed.
 *
 * CA cert refresh
 * ---------------
 * {@link fetchDgCaCert} fetches the current DataGrout CA certificate from
 * `https://ca.datagrout.ai/ca.pem`. When the DG CA rotates, clients that call
 * {@link refreshCaCert} at startup automatically pick up the change without a
 * rebuild or re-registration.
 */

import * as fs from 'fs';
import * as os from 'os';
import * as path from 'path';
import * as crypto from 'crypto';

/** Canonical URL for the DataGrout CA certificate. */
export const DG_CA_URL = 'https://ca.datagrout.ai/ca.pem';

/** Default local identity directory. */
export const DEFAULT_IDENTITY_DIR = path.join(os.homedir(), '.conduit');

// ─── CA cert fetching ──────────────────────────────────────────────────────────

/**
 * Fetch the current DataGrout CA certificate from `ca.datagrout.ai`.
 *
 * Uses the system trust store for HTTPS (Cloudflare TLS) — no circularity
 * with the DG CA, which only signs client certificates.
 *
 * @param url Override the CA cert URL (default: {@link DG_CA_URL}).
 * @returns PEM-encoded CA certificate string.
 */
export async function fetchDgCaCert(url: string = DG_CA_URL): Promise<string> {
  const resp = await fetch(url, {
    headers: { Accept: 'application/x-pem-file, text/plain, */*' },
  });

  if (!resp.ok) {
    throw new Error(`CA cert fetch failed (HTTP ${resp.status}) from ${url}`);
  }

  const pem = await resp.text();

  if (!pem.includes('-----BEGIN CERTIFICATE-----')) {
    throw new Error(`Response from ${url} does not look like a PEM certificate`);
  }

  return pem;
}

/**
 * Refresh the locally-cached DG CA certificate.
 *
 * Fetches the current CA cert from `ca.datagrout.ai` and writes it to
 * `{identityDir}/ca.pem`. Call at application startup to pick up CA rotations
 * without requiring a new registration or SDK rebuild.
 *
 * @param identityDir Directory to write `ca.pem` into (default: `~/.conduit/`).
 * @param url Override the CA cert URL.
 * @returns Path to the written `ca.pem` file.
 */
export async function refreshCaCert(
  identityDir: string = DEFAULT_IDENTITY_DIR,
  url: string = DG_CA_URL
): Promise<string> {
  const pem = await fetchDgCaCert(url);
  fs.mkdirSync(identityDir, { recursive: true });
  const caPath = path.join(identityDir, 'ca.pem');
  fs.writeFileSync(caPath, pem, 'utf8');
  return caPath;
}

// ─── Types ────────────────────────────────────────────────────────────────────

/**
 * An ECDSA P-256 keypair generated locally.
 *
 * Pass to {@link registerIdentity} to exchange for a DG-signed certificate.
 * The private key never leaves the client process.
 */
export interface Keypair {
  /** PEM-encoded PKCS#8 private key (never transmitted). */
  privateKeyPem: string;
  /** PEM-encoded SPKI public key (sent to DG during registration). */
  publicKeyPem: string;
}

export interface RegistrationOptions {
  /** DataGrout substrate identity API base URL. */
  endpoint: string;
  /** Any valid DG access token for bootstrap Bearer auth. */
  authToken: string;
  /** Human-readable label for this Substrate instance. */
  name: string;
  /** CA cert URL override (default: {@link DG_CA_URL}). */
  caUrl?: string;
}

export interface RenewalOptions {
  /** DataGrout substrate identity API base URL. */
  endpoint: string;
  /** Human-readable label for the renewed identity. */
  name: string;
  /** CA cert URL override. */
  caUrl?: string;
}

export interface RegisteredIdentity {
  /** PEM-encoded DG-signed certificate. */
  certPem: string;
  /** PEM-encoded private key (never sent to DG). */
  keyPem: string;
  /** PEM-encoded DG CA certificate. */
  caPem?: string;
  /** Server-assigned identity ID. */
  id: string;
  /** Human-readable label assigned during registration. */
  name: string;
  /** SHA-256 fingerprint of the certificate. */
  fingerprint: string;
  /** ISO-8601 timestamp when the identity was registered. */
  registeredAt: string;
  /** ISO-8601 expiry date. */
  validUntil?: string;
}

// ─── Keypair generation ───────────────────────────────────────────────────────

/**
 * Generate an ECDSA P-256 keypair for Substrate identity registration.
 *
 * Returns a {@link Keypair} holding the private key (local only) and the
 * public key to send to DataGrout.  Pass the result to {@link registerIdentity}
 * to receive a DG-CA-signed certificate.
 *
 * Node.js only (`crypto.generateKeyPairSync`).
 */
export function generateKeypair(): Keypair {
  const { privateKey, publicKey } = crypto.generateKeyPairSync('ec', {
    namedCurve: 'P-256',
  });
  return {
    privateKeyPem: privateKey.export({ type: 'pkcs8', format: 'pem' }) as string,
    publicKeyPem: publicKey.export({ type: 'spki', format: 'pem' }) as string,
  };
}

// ─── Registration ─────────────────────────────────────────────────────────────

/**
 * Register a Substrate keypair with the DataGrout CA.
 *
 * Sends only the public key to DG and receives a DG-CA-signed certificate.
 * The private key in *keypair* is reused — it never leaves the client.
 *
 * @param keypair Generated by {@link generateKeypair}.
 * @param opts Registration options (endpoint, API key, name).
 */
export async function registerIdentity(
  keypair: Keypair,
  opts: RegistrationOptions
): Promise<RegisteredIdentity> {
  const { privateKeyPem, publicKeyPem } = keypair;

  const url = opts.endpoint.replace(/\/$/, '') + '/register';

  const resp = await fetch(url, {
    method: 'POST',
    headers: {
      Authorization: `Bearer ${opts.authToken}`,
      'Content-Type': 'application/json',
    },
    body: JSON.stringify({ public_key_pem: publicKeyPem, name: opts.name }),
  });

  if (!resp.ok) {
    const body = await resp.text();
    throw new Error(`Registration failed (HTTP ${resp.status}): ${body}`);
  }

  const body = await resp.json();
  let caPem: string | undefined = body.ca_cert_pem;

  if (!caPem) {
    try {
      caPem = await fetchDgCaCert(opts.caUrl ?? DG_CA_URL);
    } catch {
      caPem = undefined;
    }
  }

  return {
    certPem: body.cert_pem,
    keyPem: privateKeyPem,
    caPem,
    id: body.id,
    name: body.name,
    fingerprint: body.fingerprint,
    registeredAt: body.registered_at ?? '',
    validUntil: body.valid_until,
  };
}

// ─── Rotation ─────────────────────────────────────────────────────────────────

export interface RotationOptions {
  /** DataGrout substrate identity API base URL. */
  endpoint: string;
  /** Human-readable label for the renewed identity. */
  name: string;
  /** CA cert URL override. */
  caUrl?: string;
  /** Current identity PEM strings, used to build the mTLS client cert. */
  currentCertPem: string;
  currentKeyPem: string;
}

/**
 * Rotate the Substrate identity by presenting the current cert over mTLS.
 *
 * Generates a new ECDSA P-256 keypair and sends the public key to the `/rotate`
 * endpoint, authenticated with the *existing* client certificate over mTLS.
 * The server returns a new DG-CA-signed certificate.
 *
 * Note: This uses Node.js `https` for mTLS — not compatible with browser environments.
 */
export async function rotateIdentity(opts: RotationOptions): Promise<RegisteredIdentity> {
  const { privateKey, publicKey } = crypto.generateKeyPairSync('ec', { namedCurve: 'P-256' });

  const publicKeyPem = publicKey.export({ type: 'spki', format: 'pem' }) as string;
  const privateKeyPem = privateKey.export({ type: 'pkcs8', format: 'pem' }) as string;

  const url = opts.endpoint.replace(/\/$/, '') + '/rotate';

  // Use Node's https module for mTLS client cert authentication.
  const https = await import('https');
  const urlModule = await import('url');
  const parsed = new urlModule.URL(url);

  const responseBody = await new Promise<string>((resolve, reject) => {
    const reqOptions = {
      hostname: parsed.hostname,
      port: parsed.port || 443,
      path: parsed.pathname,
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      cert: opts.currentCertPem,
      key: opts.currentKeyPem,
    };

    const body = JSON.stringify({ public_key_pem: publicKeyPem, name: opts.name });

    const req = https.request(reqOptions, (res) => {
      let data = '';
      res.on('data', (chunk: string) => { data += chunk; });
      res.on('end', () => {
        if (res.statusCode && res.statusCode >= 200 && res.statusCode < 300) {
          resolve(data);
        } else {
          reject(new Error(`Rotation failed (HTTP ${res.statusCode}): ${data}`));
        }
      });
    });

    req.on('error', reject);
    req.write(body);
    req.end();
  });

  const respBody = JSON.parse(responseBody);
  let caPem: string | undefined = respBody.ca_cert_pem;

  if (!caPem) {
    try {
      caPem = await fetchDgCaCert(opts.caUrl ?? DG_CA_URL);
    } catch {
      caPem = undefined;
    }
  }

  return {
    certPem: respBody.cert_pem,
    keyPem: privateKeyPem,
    caPem,
    id: respBody.id,
    name: respBody.name,
    fingerprint: respBody.fingerprint,
    registeredAt: respBody.registered_at ?? '',
    validUntil: respBody.valid_until,
  };
}

// ─── Persistence ──────────────────────────────────────────────────────────────

export interface SavedPaths {
  certPath: string;
  keyPath: string;
  caPath?: string;
}

/**
 * Save a registered identity to a directory for auto-discovery by future sessions.
 *
 * Writes:
 * - `{dir}/identity.pem`     — DG-signed certificate
 * - `{dir}/identity_key.pem` — private key (mode 0600)
 * - `{dir}/ca.pem`           — DG CA certificate (if present)
 */
export function saveIdentity(
  identity: RegisteredIdentity,
  directory: string = DEFAULT_IDENTITY_DIR
): SavedPaths {
  fs.mkdirSync(directory, { recursive: true });

  const certPath = path.join(directory, 'identity.pem');
  const keyPath = path.join(directory, 'identity_key.pem');

  fs.writeFileSync(certPath, identity.certPem, 'utf8');
  fs.writeFileSync(keyPath, identity.keyPem, { encoding: 'utf8', mode: 0o600 });

  const result: SavedPaths = { certPath, keyPath };

  if (identity.caPem) {
    const caPath = path.join(directory, 'ca.pem');
    fs.writeFileSync(caPath, identity.caPem, 'utf8');
    result.caPath = caPath;
  }

  return result;
}
