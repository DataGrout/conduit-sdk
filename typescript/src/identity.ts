/**
 * Identity and mTLS support for Conduit connections.
 *
 * A {@link ConduitIdentity} holds the client certificate and private key used
 * for mutual TLS.  When present, every connection presents the certificate
 * during the TLS handshake — the server can verify the caller's identity
 * without a separate application-layer token exchange.
 *
 * ## Auto-discovery
 *
 * {@link ConduitIdentity.tryDefault} walks this chain and returns the first
 * identity it finds:
 *
 * 1. `CONDUIT_MTLS_CERT` + `CONDUIT_MTLS_KEY` (+ optional `CONDUIT_MTLS_CA`)
 *    environment variables (inline PEM strings).
 * 2. `CONDUIT_IDENTITY_DIR` environment variable — a directory containing
 *    `identity.pem` and `identity_key.pem`.  Useful for running multiple
 *    agents on the same machine with distinct identities.
 * 3. `~/.conduit/identity.pem` + `~/.conduit/identity_key.pem`
 * 4. `.conduit/identity.pem` relative to the current working directory.
 *
 * If nothing is found, `tryDefault` returns `null` — the client falls back to
 * bearer token / API key auth silently.
 *
 * ## Rotation awareness
 *
 * Attach a known expiry with `withExpiry(date)` and call
 * `needsRotation(thresholdDays)` to check whether the cert is within
 * `thresholdDays` of expiry.  Actual re-registration with the DataGrout CA is
 * handled separately.
 *
 * ## Runtime note
 *
 * mTLS in HTTP is a Node.js capability — browser `fetch` implementations do
 * not support client certificates.  In browser environments the identity is
 * stored but not applied; a warning is emitted instead.
 */

/** Raw mTLS material. */
export interface MtlsConfig {
  /** PEM-encoded X.509 client certificate. */
  certPem: string;
  /** PEM-encoded private key (PKCS#8 or PKCS#1). */
  keyPem: string;
  /**
   * PEM-encoded CA certificate(s) for verifying the *server* cert.
   * When absent the system trust store is used.
   */
  caPem?: string;
  /** Certificate expiry, if known.  Set via {@link ConduitIdentity.withExpiry}. */
  expiresAt?: Date;
}

/**
 * A Conduit client identity — the cert + key pair used for mTLS.
 *
 * Construct via {@link fromPem}, {@link fromPaths}, {@link fromEnv}, or
 * {@link tryDefault}.
 */
export class ConduitIdentity {
  private readonly _config: MtlsConfig;

  private constructor(config: MtlsConfig) {
    this._config = config;
  }

  // ─── Constructors ───────────────────────────────────────────────────────────

  /**
   * Build an identity from PEM strings already in memory.
   *
   * @throws {Error} if the PEM strings do not look like a certificate or key.
   */
  static fromPem(certPem: string, keyPem: string, caPem?: string): ConduitIdentity {
    if (!certPem.includes('-----BEGIN CERTIFICATE-----')) {
      throw new Error(
        'certPem does not appear to contain a PEM certificate ' +
          '(missing "-----BEGIN CERTIFICATE-----")'
      );
    }
    if (!ConduitIdentity._hasPemPrivateKey(keyPem)) {
      throw new Error(
        'keyPem does not appear to contain a PEM private key ' +
          '(expected PRIVATE KEY, RSA PRIVATE KEY, or EC PRIVATE KEY header)'
      );
    }
    return new ConduitIdentity({ certPem, keyPem, caPem });
  }

  /**
   * Build an identity by reading PEM files from disk (Node.js only).
   *
   * @throws {Error} in browser environments or if the files cannot be read.
   */
  static fromPaths(certPath: string, keyPath: string, caPath?: string): ConduitIdentity {
    if (typeof process === 'undefined' || !process.versions?.node) {
      throw new Error('ConduitIdentity.fromPaths() is only available in Node.js environments');
    }
    // eslint-disable-next-line @typescript-eslint/no-require-imports
    const fs = require('node:fs') as typeof import('fs');
    const certPem = fs.readFileSync(certPath, 'utf8');
    const keyPem = fs.readFileSync(keyPath, 'utf8');
    const caPem = caPath ? fs.readFileSync(caPath, 'utf8') : undefined;
    return ConduitIdentity.fromPem(certPem, keyPem, caPem);
  }

  /**
   * Build an identity from environment variables.
   *
   * Reads:
   * - `CONDUIT_MTLS_CERT` — PEM string for the client certificate
   * - `CONDUIT_MTLS_KEY`  — PEM string for the private key
   * - `CONDUIT_MTLS_CA`   — PEM string for the CA (optional)
   *
   * @returns `null` if `CONDUIT_MTLS_CERT` is not set.
   * @throws {Error} if `CONDUIT_MTLS_CERT` is set but `CONDUIT_MTLS_KEY` is missing.
   */
  static fromEnv(): ConduitIdentity | null {
    const certPem = process.env.CONDUIT_MTLS_CERT;
    if (!certPem) return null;

    const keyPem = process.env.CONDUIT_MTLS_KEY;
    if (!keyPem) {
      throw new Error('CONDUIT_MTLS_CERT is set but CONDUIT_MTLS_KEY is missing');
    }

    const caPem = process.env.CONDUIT_MTLS_CA || undefined;
    return ConduitIdentity.fromPem(certPem, keyPem, caPem);
  }

  /**
   * Try to locate an identity using the auto-discovery chain described in the
   * module docs.  Returns `null` if nothing is found.
   */
  static tryDefault(): ConduitIdentity | null {
    return ConduitIdentity.tryDiscover();
  }

  /**
   * Like {@link tryDefault} but checks `overrideDir` first.
   *
   * Discovery order:
   * 1. `overrideDir` (if provided)
   * 2. `CONDUIT_MTLS_CERT` + `CONDUIT_MTLS_KEY` env vars
   * 3. `CONDUIT_IDENTITY_DIR` env var
   * 4. `~/.conduit/`
   * 5. `.conduit/` relative to cwd
   */
  static tryDiscover(overrideDir?: string): ConduitIdentity | null {
    // 0. Explicit override directory
    if (overrideDir) {
      const id = ConduitIdentity._tryLoadFromDir(overrideDir);
      if (id) return id;
    }

    // 1. Environment variables (inline PEM strings)
    try {
      const id = ConduitIdentity.fromEnv();
      if (id) return id;
    } catch {
      // CONDUIT_MTLS_KEY missing — let caller deal with this via fromEnv() directly
    }

    // Node.js only from here
    if (typeof process === 'undefined' || !process.versions?.node) {
      return null;
    }

    // 2. CONDUIT_IDENTITY_DIR env var
    const envDir = process.env.CONDUIT_IDENTITY_DIR;
    if (envDir) {
      const id = ConduitIdentity._tryLoadFromDir(envDir);
      if (id) return id;
    }

    // 3. ~/.conduit/
    const home = process.env.HOME ?? process.env.USERPROFILE ?? '';
    if (home) {
      const id = ConduitIdentity._tryLoadFromDir(`${home}/.conduit`);
      if (id) return id;
    }

    // 4. .conduit/ relative to cwd
    {
      const id = ConduitIdentity._tryLoadFromDir('.conduit');
      if (id) return id;
    }

    return null;
  }

  // ─── Builder-style setters ──────────────────────────────────────────────────

  /** Attach a known certificate expiry for rotation checks. */
  withExpiry(expiresAt: Date): ConduitIdentity {
    return new ConduitIdentity({ ...this._config, expiresAt });
  }

  // ─── Introspection ──────────────────────────────────────────────────────────

  /**
   * Returns `true` if the certificate expires within `thresholdDays`.
   *
   * Always returns `false` when no expiry is set.
   */
  needsRotation(thresholdDays: number): boolean {
    if (!this._config.expiresAt) return false;
    const thresholdMs = thresholdDays * 86_400_000;
    return Date.now() + thresholdMs > this._config.expiresAt.getTime();
  }

  get certPem(): string {
    return this._config.certPem;
  }

  get keyPem(): string {
    return this._config.keyPem;
  }

  get caPem(): string | undefined {
    return this._config.caPem;
  }

  get expiresAt(): Date | undefined {
    return this._config.expiresAt;
  }

  // ─── Internal helpers ───────────────────────────────────────────────────────

  private static _hasPemPrivateKey(pem: string): boolean {
    return (
      pem.includes('-----BEGIN PRIVATE KEY-----') ||
      pem.includes('-----BEGIN RSA PRIVATE KEY-----') ||
      pem.includes('-----BEGIN EC PRIVATE KEY-----') ||
      pem.includes('-----BEGIN ENCRYPTED PRIVATE KEY-----')
    );
  }

  private static _tryLoadFromDir(dir: string): ConduitIdentity | null {
    try {
      // eslint-disable-next-line @typescript-eslint/no-require-imports
      const fs = require('node:fs') as typeof import('fs');
      const certPath = `${dir}/identity.pem`;
      const keyPath = `${dir}/identity_key.pem`;
      if (!fs.existsSync(certPath) || !fs.existsSync(keyPath)) return null;
      const caPath = `${dir}/ca.pem`;
      return ConduitIdentity.fromPaths(certPath, keyPath, fs.existsSync(caPath) ? caPath : undefined);
    } catch {
      return null;
    }
  }
}

// ─── Node.js mTLS fetch helper ──────────────────────────────────────────────

/**
 * Perform an HTTP/HTTPS request using Node.js built-in `https` with a client
 * certificate for mTLS.  Returns a `Response`-compatible object usable
 * everywhere the standard `fetch` response is expected.
 *
 * This bypasses the global `fetch` (which doesn't support client certs) and
 * uses Node.js's `https.request` directly.
 */
export async function fetchWithIdentity(
  url: string,
  init: RequestInit,
  identity: ConduitIdentity
): Promise<Response> {
  if (typeof process === 'undefined' || !process.versions?.node) {
    console.warn(
      '[conduit] mTLS identity is set but this environment does not support client ' +
        'certificates in fetch().  The request will proceed without mTLS.'
    );
    return fetch(url, init);
  }

  // eslint-disable-next-line @typescript-eslint/no-require-imports
  const https = require('node:https') as typeof import('https');
  const parsedUrl = new URL(url);

  const options: import('https').RequestOptions = {
    hostname: parsedUrl.hostname,
    port: parsedUrl.port || 443,
    path: parsedUrl.pathname + parsedUrl.search,
    method: (init.method ?? 'GET').toUpperCase(),
    headers: flattenHeaders(init.headers),
    cert: identity.certPem,
    key: identity.keyPem,
    ...(identity.caPem ? { ca: identity.caPem } : {}),
  };

  return new Promise<Response>((resolve, reject) => {
    const req = https.request(options, (res) => {
      const chunks: Buffer[] = [];
      res.on('data', (chunk: Buffer) => chunks.push(chunk));
      res.on('end', () => {
        const body = Buffer.concat(chunks);
        const responseHeaders = new Headers();
        for (const [key, value] of Object.entries(res.headers)) {
          if (value !== undefined) {
            const v = Array.isArray(value) ? value.join(', ') : String(value);
            responseHeaders.set(key, v);
          }
        }
        resolve(
          new Response(body, {
            status: res.statusCode ?? 200,
            statusText: res.statusMessage ?? '',
            headers: responseHeaders,
          })
        );
      });
      res.on('error', reject);
    });

    req.on('error', reject);

    if (init.body) {
      req.write(init.body as string | Buffer);
    }
    req.end();
  });
}

function flattenHeaders(
  headers: HeadersInit | undefined
): Record<string, string> {
  if (!headers) return {};
  if (headers instanceof Headers) {
    const obj: Record<string, string> = {};
    headers.forEach((v, k) => { obj[k] = v; });
    return obj;
  }
  if (Array.isArray(headers)) {
    return Object.fromEntries(headers);
  }
  return headers as Record<string, string>;
}
