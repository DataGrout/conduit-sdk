/**
 * OAuth 2.1 `client_credentials` token provider for Conduit.
 *
 * Fetches short-lived JWTs from the DataGrout machine-client token endpoint
 * and caches them, refreshing proactively before they expire.
 *
 * @example
 * ```ts
 * // Most users should use the high-level `auth.clientCredentials` option on
 * // ClientOptions instead of instantiating this class directly.
 * import { Client } from 'datagrout-conduit';
 *
 * const client = new Client({
 *   url: 'https://app.datagrout.ai/servers/{uuid}/mcp',
 *   auth: {
 *     clientCredentials: { clientId: 'abc', clientSecret: 'xyz' },
 *   },
 * });
 * ```
 */

interface TokenResponse {
  access_token: string;
  token_type: string;
  expires_in?: number;
  scope?: string;
}

interface CachedToken {
  accessToken: string;
  expiresAt: number; // ms epoch
}

/**
 * Derive the token endpoint URL from a DataGrout MCP URL.
 *
 * @example
 * ```ts
 * deriveTokenEndpoint('https://app.datagrout.ai/servers/abc/mcp');
 * // → 'https://app.datagrout.ai/servers/abc/oauth/token'
 * ```
 */
export function deriveTokenEndpoint(mcpUrl: string): string {
  const mcpIdx = mcpUrl.indexOf('/mcp');
  const base = mcpIdx !== -1 ? mcpUrl.slice(0, mcpIdx) : mcpUrl.replace(/\/$/, '');
  return `${base}/oauth/token`;
}

/** @internal */
export class OAuthTokenProvider {
  private readonly clientId: string;
  private readonly clientSecret: string;
  private readonly tokenEndpoint: string;
  private readonly scope?: string;

  private cached: CachedToken | null = null;
  private fetchPromise: Promise<CachedToken> | null = null;

  constructor(opts: {
    clientId: string;
    clientSecret: string;
    tokenEndpoint: string;
    scope?: string;
  }) {
    this.clientId = opts.clientId;
    this.clientSecret = opts.clientSecret;
    this.tokenEndpoint = opts.tokenEndpoint;
    this.scope = opts.scope;
  }

  /**
   * Return the current bearer token, fetching a fresh one if necessary.
   * Concurrent callers share a single in-flight fetch.
   */
  async getToken(): Promise<string> {
    const now = Date.now();

    // Fast path — cached and not within the 60-second refresh buffer.
    if (this.cached && this.cached.expiresAt - now > 60_000) {
      return this.cached.accessToken;
    }

    // De-duplicate concurrent fetches.
    if (!this.fetchPromise) {
      this.fetchPromise = this.fetchToken().finally(() => {
        this.fetchPromise = null;
      });
    }

    const cached = await this.fetchPromise;
    return cached.accessToken;
  }

  /** Invalidate the cached token (e.g. after receiving a 401). */
  invalidate(): void {
    this.cached = null;
  }

  // ─── Private ───────────────────────────────────────────────────────────────

  private async fetchToken(): Promise<CachedToken> {
    const body = new URLSearchParams({
      grant_type: 'client_credentials',
      client_id: this.clientId,
      client_secret: this.clientSecret,
    });

    if (this.scope) {
      body.set('scope', this.scope);
    }

    let response: Response;
    try {
      response = await fetch(this.tokenEndpoint, {
        method: 'POST',
        headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
        body: body.toString(),
      });
    } catch (err) {
      throw new Error(`OAuth token request failed: ${err}`);
    }

    if (!response.ok) {
      const text = await response.text().catch(() => '');
      throw new Error(`OAuth token endpoint returned ${response.status}: ${text}`);
    }

    const data = (await response.json()) as TokenResponse;
    const expiresIn = data.expires_in ?? 3600;

    const cached: CachedToken = {
      accessToken: data.access_token,
      expiresAt: Date.now() + expiresIn * 1000,
    };

    this.cached = cached;
    return cached;
  }
}
