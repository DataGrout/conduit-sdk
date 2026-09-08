/**
 * OAuth 2.1 **authorization code + PKCE** — browser-consent sign-in.
 *
 * The `client_credentials` grant in {@link ./oauth} authenticates a *machine*:
 * it needs a client secret issued out of band. This module authenticates a
 * *person*: the app opens a browser, the user consents at the gateway, and the
 * app receives a grant bound to that user's account. It is what a desktop or
 * CLI application needs, and the only way to use
 * `https://gateway.datagrout.ai/connect`, where the server binding is chosen at
 * consent time and lives in the token rather than the URL.
 *
 * # Flow
 *
 * 1. {@link AuthCodeFlow.discover} — protected-resource metadata, then the
 *    authorization server's metadata.
 * 2. {@link AuthCodeFlow.register} — RFC 7591 dynamic client registration, as a
 *    **public client** (no secret; PKCE takes its place).
 * 3. {@link AuthCodeFlow.authorizeUrl} — build the consent URL and hold the
 *    PKCE verifier and CSRF state in a {@link PendingAuthorization}.
 * 4. The caller opens that URL and captures the redirect. `authcode/loopback`
 *    can do the capturing.
 * 5. {@link AuthCodeFlow.exchange} — trade the code for a {@link Grant}.
 *
 * ```ts
 * import { AuthCodeFlow } from "@datagrout/conduit/authcode";
 *
 * const flow = await AuthCodeFlow.discover("https://gateway.datagrout.ai/connect");
 * const client = await flow.register("My App", "http://127.0.0.1:8765/callback");
 *
 * const { url, pending } = flow.authorizeUrl();
 * console.log(`Open: ${url}`);
 *
 * const grant = await flow.exchange(pending, code, state);
 * ```
 *
 * # Persisting the grant
 *
 * This module owns the {@link Grant} shape and its refresh logic; it
 * deliberately does **not** choose where a grant is stored. That is the
 * application's decision — an OS keychain, a config file, a vault — and baking
 * a filesystem opinion into an SDK makes it wrong for half its callers.
 *
 * {@link Grant.expires_at} is Unix **seconds** rather than a monotonic clock
 * value, precisely so a grant survives serialization: it is written by one
 * process and read by another, possibly in a different language.
 */

import { createHash, randomBytes, timingSafeEqual } from "node:crypto";

import { ConduitError } from "./errors";

/**
 * Scopes requested when the caller does not specify.
 *
 * Matches the authorization server's own registration default rather than
 * inventing a finer-grained vocabulary: DataGrout splits the scope string on
 * whitespace and stores what it is given, so a made-up scope is accepted
 * silently and then means nothing.
 */
export const DEFAULT_SCOPE = "mcp tools";

/** Refresh this many seconds before the token actually expires. */
const REFRESH_SKEW_SECS = 60;

// ─── Errors ──────────────────────────────────────────────────────────────────

/**
 * The distinguishable failures of the authorization-code flow.
 *
 * The taxonomy is part of the cross-language contract: every conduit SDK
 * distinguishes these same cases, so callers can branch identically.
 */
export type AuthCodeErrorKind =
  /** Metadata discovery failed or returned something unusable. */
  | "discovery"
  /** The authorization server does not advertise dynamic client registration. */
  | "no_registration_endpoint"
  /** Dynamic client registration was rejected. */
  | "registration_rejected"
  /** `authorizeUrl` was called before a client id was known. */
  | "no_client_id"
  /** The server does not support PKCE with S256. */
  | "pkce_unsupported"
  /** The `state` returned by the redirect did not match the one sent. */
  | "state_mismatch"
  /** The token endpoint rejected the exchange or refresh. */
  | "token_exchange"
  /** The grant has no refresh token, so it cannot be renewed. */
  | "not_refreshable"
  /** The authorization server returned an error at the redirect. */
  | "denied"
  /** Transport failure talking to the authorization server. */
  | "http";

/** An error from the authorization-code flow, tagged with its {@link AuthCodeErrorKind}. */
export class AuthCodeError extends ConduitError {
  readonly kind: AuthCodeErrorKind;
  /** HTTP status, for `registration_rejected` and `token_exchange`. */
  readonly status?: number;
  /** Response body, for `registration_rejected` and `token_exchange`. */
  readonly body?: string;

  constructor(
    kind: AuthCodeErrorKind,
    message: string,
    extra?: { status?: number; body?: string },
  ) {
    super(message);
    this.kind = kind;
    this.status = extra?.status;
    this.body = extra?.body;
  }
}

// ─── Metadata ────────────────────────────────────────────────────────────────

/** RFC 8414 authorization server metadata (the fields this flow uses). */
export interface AuthServerMetadata {
  issuer?: string;
  authorization_endpoint: string;
  token_endpoint: string;
  /** RFC 7591 dynamic client registration endpoint, when offered. */
  registration_endpoint?: string;
  /** PKCE methods, e.g. `["S256"]`. */
  code_challenge_methods_supported?: string[];
  grant_types_supported?: string[];
  scopes_supported?: string[];
}

/**
 * Whether S256 is usable.
 *
 * An empty or absent list means the server did not advertise. RFC 8414 makes
 * the field optional and DataGrout omits it on some paths, so absence is
 * treated as "assume S256" rather than as a refusal — a server that truly
 * cannot do S256 will reject the authorize request anyway.
 */
export function supportsS256(metadata: AuthServerMetadata): boolean {
  const methods = metadata.code_challenge_methods_supported;
  if (!methods || methods.length === 0) return true;
  return methods.some((m) => m.toUpperCase() === "S256");
}

interface ProtectedResourceMetadata {
  authorization_servers?: string[];
}

// ─── Grant ───────────────────────────────────────────────────────────────────

/**
 * A dynamically-registered client: the id **and** the redirect URI it is bound
 * to.
 *
 * These travel together because an authorization server matches the redirect
 * URI **exactly** against the value registered — there is no loopback-port
 * exemption to rely on. Persisting the id alone means a later re-authorization
 * on a freshly-chosen port is rejected as `invalid_redirect_uri`, and the
 * failure only shows up once the first grant can no longer be refreshed.
 */
export interface RegisteredClient {
  client_id: string;
  redirect_uri: string;
}

/**
 * A user's authorization, ready to persist.
 *
 * The serialized shape is part of the cross-language contract: a grant written
 * by one conduit SDK must be readable by another. Field names are therefore
 * snake_case and fixed, and `expires_at` is Unix seconds.
 */
export interface Grant {
  access_token: string;
  refresh_token?: string;
  /** Absolute expiry, Unix seconds. Absent means the server did not say. */
  expires_at?: number;
  /** The client id this grant belongs to — needed to refresh it. */
  client_id: string;
  /** Token endpoint that issued it — needed to refresh it. */
  token_endpoint: string;
  scope?: string;
  /** The resource this grant is bound to (RFC 8707). */
  resource?: string;
}

interface TokenResponse {
  access_token: string;
  refresh_token?: string;
  expires_in?: number;
  scope?: string;
}

/** Anything with `fetch`'s shape, so tests can substitute a fake. */
export type FetchLike = typeof globalThis.fetch;

/**
 * True when the access token is expired, or within the refresh skew of it.
 *
 * A grant with no stated expiry is treated as live: the server chose not to
 * say, and guessing an expiry would throw away working tokens.
 */
export function isGrantExpired(grant: Grant): boolean {
  if (grant.expires_at === undefined) return false;
  return nowSecs() + REFRESH_SKEW_SECS >= grant.expires_at;
}

/** Whether this grant can renew itself without user interaction. */
export function isGrantRefreshable(grant: Grant): boolean {
  return grant.refresh_token !== undefined && grant.refresh_token !== "";
}

/**
 * Exchange the refresh token for a fresh grant.
 *
 * Returns a new grant; the old one should be discarded. DataGrout rotates
 * refresh tokens, so keeping the previous grant around and using it again can
 * invalidate the whole family.
 */
export async function refreshGrant(
  grant: Grant,
  fetchImpl: FetchLike = globalThis.fetch,
): Promise<Grant> {
  if (!isGrantRefreshable(grant)) {
    throw new AuthCodeError(
      "not_refreshable",
      "grant has expired and carries no refresh_token — re-authorize",
    );
  }

  const form: Record<string, string> = {
    grant_type: "refresh_token",
    refresh_token: grant.refresh_token as string,
    client_id: grant.client_id,
  };
  if (grant.resource) form.resource = grant.resource;

  const token = await postForm(fetchImpl, grant.token_endpoint, form);

  return {
    access_token: token.access_token,
    // A server that does not rotate returns no new refresh token; keep the
    // existing one rather than silently making the grant unrefreshable.
    refresh_token: token.refresh_token ?? grant.refresh_token,
    expires_at:
      token.expires_in === undefined ? undefined : nowSecs() + token.expires_in,
    client_id: grant.client_id,
    token_endpoint: grant.token_endpoint,
    scope: token.scope ?? grant.scope,
    resource: grant.resource,
  };
}

// ─── Pending authorization ───────────────────────────────────────────────────

/**
 * The secrets held between building the consent URL and redeeming the code.
 *
 * {@link AuthCodeFlow.exchange} consumes it, so a verifier is not replayed
 * against a second code.
 */
export interface PendingAuthorization {
  readonly codeVerifier: string;
  readonly state: string;
  readonly redirectUri: string;
}

// ─── The flow ────────────────────────────────────────────────────────────────

/** Drives discovery, registration, consent, and exchange. */
export class AuthCodeFlow {
  private readonly fetchImpl: FetchLike;
  private readonly metadataDoc: AuthServerMetadata;
  /** The protected resource this grant will be bound to (RFC 8707). */
  private readonly resource: string;
  private clientIdValue?: string;
  private redirectUriValue?: string;
  private scope: string = DEFAULT_SCOPE;

  private constructor(
    fetchImpl: FetchLike,
    metadata: AuthServerMetadata,
    resource: string,
  ) {
    this.fetchImpl = fetchImpl;
    this.metadataDoc = metadata;
    this.resource = resource;
  }

  /**
   * Discover the authorization server protecting `resourceUrl`.
   *
   * `resourceUrl` is the MCP endpoint being connected to — for DataGrout,
   * `https://gateway.datagrout.ai/connect` or a `.../servers/{uuid}/mcp` URL.
   *
   * Tries RFC 9728 protected-resource metadata first, then RFC 8414
   * authorization-server metadata on whatever that names. Falls back to the
   * resource's own origin, which is where DataGrout serves it.
   */
  static async discover(
    resourceUrl: string,
    fetchImpl: FetchLike = globalThis.fetch,
  ): Promise<AuthCodeFlow> {
    const resource = resourceUrl.replace(/\/+$/, "");

    const prm = await fetchResourceMetadata(fetchImpl, resource);
    let issuer: string | undefined;
    if (prm?.authorization_servers && prm.authorization_servers.length > 0) {
      issuer = prm.authorization_servers[0];
    } else {
      // No PRM, or it named no servers: DataGrout serves AS metadata at the
      // origin, so try there before giving up.
      issuer = originOf(resource);
    }
    if (!issuer) {
      throw new AuthCodeError("discovery", `not a URL: ${resource}`);
    }

    const metadata = await fetchAsMetadata(fetchImpl, issuer);
    if (!supportsS256(metadata)) {
      throw new AuthCodeError(
        "pkce_unsupported",
        "authorization server does not support PKCE S256; refusing to downgrade",
      );
    }

    return new AuthCodeFlow(fetchImpl, metadata, resource);
  }

  /** Use a client id registered out of band, skipping dynamic registration. */
  withClientId(clientId: string, redirectUri: string): this {
    this.clientIdValue = clientId;
    this.redirectUriValue = redirectUri;
    return this;
  }

  /**
   * Reuse a client registered on a previous run.
   *
   * Prefer this over {@link withClientId}: it carries the redirect URI with the
   * id, which is not optional bookkeeping — an authorization server matches the
   * redirect URI **exactly** against what was registered, so a client id reused
   * with a different URI is rejected.
   */
  withRegisteredClient(client: RegisteredClient): this {
    return this.withClientId(client.client_id, client.redirect_uri);
  }

  /** Request scopes other than {@link DEFAULT_SCOPE}. */
  withScope(scope: string): this {
    this.scope = scope;
    return this;
  }

  /** The discovered metadata. */
  get metadata(): AuthServerMetadata {
    return this.metadataDoc;
  }

  /** The client id, once registered or supplied. */
  get clientId(): string | undefined {
    return this.clientIdValue;
  }

  /** The redirect URI this flow is bound to. */
  get redirectUri(): string | undefined {
    return this.redirectUriValue;
  }

  /**
   * Register this application via RFC 7591 dynamic client registration.
   *
   * Registers a **public client** — `token_endpoint_auth_method: "none"`, no
   * secret issued. A desktop or CLI application cannot keep a secret, and PKCE
   * is what stands in for one.
   *
   * Returns the id **and** the redirect URI it is bound to. Persist the pair
   * and restore it with {@link withRegisteredClient} — re-registering on every
   * launch creates a new client record each time, and reusing an id against a
   * different redirect URI is rejected.
   */
  async register(
    clientName: string,
    redirectUri: string,
  ): Promise<RegisteredClient> {
    const endpoint = this.metadataDoc.registration_endpoint;
    if (!endpoint) {
      throw new AuthCodeError(
        "no_registration_endpoint",
        "authorization server has no registration endpoint — register a client manually and use withClientId()",
      );
    }

    let response: Response;
    try {
      response = await this.fetchImpl(endpoint, {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({
          client_name: clientName,
          redirect_uris: [redirectUri],
          grant_types: ["authorization_code", "refresh_token"],
          response_types: ["code"],
          token_endpoint_auth_method: "none",
          application_type: "native",
        }),
      });
    } catch (err) {
      throw new AuthCodeError("http", `HTTP error: ${err}`);
    }

    if (!response.ok) {
      const body = await response.text().catch(() => "");
      throw new AuthCodeError(
        "registration_rejected",
        `client registration rejected (HTTP ${response.status}): ${body}`,
        { status: response.status, body },
      );
    }

    let clientId: string;
    try {
      const parsed = (await response.json()) as { client_id: string };
      clientId = parsed.client_id;
    } catch (err) {
      throw new AuthCodeError("http", `bad registration response: ${err}`);
    }

    this.clientIdValue = clientId;
    this.redirectUriValue = redirectUri;
    return { client_id: clientId, redirect_uri: redirectUri };
  }

  /**
   * Build the consent URL, plus the {@link PendingAuthorization} needed to
   * redeem the resulting code.
   *
   * The caller opens the URL however suits it — a browser, a printed
   * instruction, a QR code. This SDK does not launch browsers.
   */
  authorizeUrl(): { url: string; pending: PendingAuthorization } {
    const clientId = this.clientIdValue;
    const redirectUri = this.redirectUriValue;
    if (!clientId || !redirectUri) {
      throw new AuthCodeError(
        "no_client_id",
        "no client_id — call register() or withClientId() first",
      );
    }

    const codeVerifier = generateVerifier();
    const state = generateState();

    const query = (
      [
        ["response_type", "code"],
        ["client_id", clientId],
        ["redirect_uri", redirectUri],
        ["scope", this.scope],
        ["state", state],
        ["code_challenge", challengeS256(codeVerifier)],
        ["code_challenge_method", "S256"],
        // RFC 8707: bind the token to this resource so it cannot be replayed
        // against a different one.
        ["resource", this.resource],
      ] as const
    )
      .map(([k, v]) => `${k}=${urlencode(v)}`)
      .join("&");

    const separator = this.metadataDoc.authorization_endpoint.includes("?")
      ? "&"
      : "?";
    const url = `${this.metadataDoc.authorization_endpoint}${separator}${query}`;

    return { url, pending: { codeVerifier, state, redirectUri } };
  }

  /**
   * Redeem an authorization code for a {@link Grant}.
   *
   * `returnedState` is the `state` parameter from the redirect. It is checked
   * against the pending request before anything is sent: a mismatch means the
   * response belongs to a different authorization request, and the exchange is
   * refused rather than attempted.
   */
  async exchange(
    pending: PendingAuthorization,
    code: string,
    returnedState: string,
  ): Promise<Grant> {
    if (!constantTimeEqual(pending.state, returnedState)) {
      throw new AuthCodeError(
        "state_mismatch",
        "state mismatch — the authorization response does not match this request",
      );
    }

    const clientId = this.clientIdValue;
    if (!clientId) {
      throw new AuthCodeError(
        "no_client_id",
        "no client_id — call register() or withClientId() first",
      );
    }

    const token = await postForm(
      this.fetchImpl,
      this.metadataDoc.token_endpoint,
      {
        grant_type: "authorization_code",
        code,
        redirect_uri: pending.redirectUri,
        client_id: clientId,
        code_verifier: pending.codeVerifier,
        resource: this.resource,
      },
    );

    return {
      access_token: token.access_token,
      refresh_token: token.refresh_token,
      expires_at:
        token.expires_in === undefined
          ? undefined
          : nowSecs() + token.expires_in,
      client_id: clientId,
      token_endpoint: this.metadataDoc.token_endpoint,
      scope: token.scope,
      resource: this.resource,
    };
  }
}

// ─── Provider ────────────────────────────────────────────────────────────────

/**
 * Holds a {@link Grant} and keeps its access token fresh.
 *
 * Mirrors {@link ./oauth.OAuthTokenProvider} so both grant types reach the
 * transports through the same path — `getToken` on the way out, `invalidate`
 * on a 401.
 */
export class AuthCodeProvider {
  private grantValue: Grant;
  private dirty = false;
  private refreshPromise: Promise<Grant> | null = null;
  private readonly fetchImpl: FetchLike;

  constructor(grant: Grant, fetchImpl: FetchLike = globalThis.fetch) {
    this.grantValue = grant;
    this.fetchImpl = fetchImpl;
  }

  /** The current access token, refreshing first if it is at or near expiry. */
  async getToken(): Promise<string> {
    if (!isGrantExpired(this.grantValue)) {
      return this.grantValue.access_token;
    }

    // De-duplicate concurrent refreshes, as the client_credentials provider does.
    if (!this.refreshPromise) {
      this.refreshPromise = refreshGrant(this.grantValue, this.fetchImpl)
        .then((refreshed) => {
          this.grantValue = refreshed;
          this.dirty = true;
          return refreshed;
        })
        .finally(() => {
          this.refreshPromise = null;
        });
    }

    const refreshed = await this.refreshPromise;
    return refreshed.access_token;
  }

  /** A snapshot of the current grant, for persisting. */
  grant(): Grant {
    return { ...this.grantValue };
  }

  /** Whether the grant changed since the last {@link takeIfDirty}. */
  isDirty(): boolean {
    return this.dirty;
  }

  /**
   * Return the grant if it has changed since the last call, clearing the flag.
   *
   * The intended use is a persistence loop: call periodically and write
   * whatever comes back, so a rotated refresh token is never lost.
   */
  takeIfDirty(): Grant | null {
    if (!this.dirty) return null;
    this.dirty = false;
    return this.grant();
  }

  /** Force the next {@link getToken} to refresh. Call on a 401. */
  invalidate(): void {
    // Expire in the past rather than clearing the token: the refresh token is
    // what matters, and dropping the grant would make recovery impossible.
    this.grantValue = { ...this.grantValue, expires_at: 0 };
  }
}

/**
 * Coerce whatever `auth.authorizationCode` holds into a provider.
 *
 * A caller who passes a bare {@link Grant} gets one made for them; a caller who
 * passes their own {@link AuthCodeProvider} keeps it, so a rotated refresh
 * token stays visible to them through `takeIfDirty()`.
 */
export function authCodeProviderFrom(
  value: Grant | AuthCodeProvider | undefined,
  fetchImpl: FetchLike = globalThis.fetch,
): AuthCodeProvider | undefined {
  if (value === undefined) return undefined;
  if (value instanceof AuthCodeProvider) return value;
  return new AuthCodeProvider(value, fetchImpl);
}

// ─── PKCE and helpers ────────────────────────────────────────────────────────

/** Generate an RFC 7636 code verifier: 43 characters of base64url. */
export function generateVerifier(): string {
  return randomBytes(32).toString("base64url");
}

/** The S256 challenge for a verifier: `base64url(sha256(verifier))`. */
export function challengeS256(verifier: string): string {
  return createHash("sha256").update(verifier, "utf8").digest("base64url");
}

function generateState(): string {
  return randomBytes(16).toString("base64url");
}

function nowSecs(): number {
  return Math.floor(Date.now() / 1000);
}

/** Length-independent comparison, so a state check cannot be timed. */
function constantTimeEqual(a: string, b: string): boolean {
  const ab = Buffer.from(a, "utf8");
  const bb = Buffer.from(b, "utf8");
  if (ab.length !== bb.length) return false;
  if (ab.length === 0) return true;
  return timingSafeEqual(ab, bb);
}

/**
 * Percent-encode a query parameter value.
 *
 * Unreserved set per RFC 3986. Everything else is escaped — including `/` and
 * `:`, which appear in redirect URIs and resource URLs and must not be taken
 * as structure by the authorization server. `encodeURIComponent` leaves
 * `!'()*` alone, so this is written out rather than delegated.
 */
export function urlencode(value: string): string {
  let out = "";
  for (const byte of Buffer.from(value, "utf8")) {
    const ch = String.fromCharCode(byte);
    if (/[A-Za-z0-9\-._~]/.test(ch)) {
      out += ch;
    } else {
      out += `%${byte.toString(16).toUpperCase().padStart(2, "0")}`;
    }
  }
  return out;
}

/** Scheme, host and port of a URL, with no path. */
export function originOf(url: string): string | undefined {
  try {
    const parsed = new URL(url);
    if (!parsed.hostname) return undefined;
    return parsed.port
      ? `${parsed.protocol}//${parsed.hostname}:${parsed.port}`
      : `${parsed.protocol}//${parsed.hostname}`;
  } catch {
    return undefined;
  }
}

async function fetchResourceMetadata(
  fetchImpl: FetchLike,
  resource: string,
): Promise<ProtectedResourceMetadata | undefined> {
  // Path-appended form first (what MCP servers with a path segment use), then
  // the origin-level one.
  const origin = originOf(resource);
  const candidates = [
    `${resource}/.well-known/oauth-protected-resource`,
    origin ? `${origin}/.well-known/oauth-protected-resource` : undefined,
  ].filter((u): u is string => u !== undefined);

  for (const url of candidates) {
    try {
      const resp = await fetchImpl(url);
      if (resp.ok) {
        return (await resp.json()) as ProtectedResourceMetadata;
      }
    } catch {
      // Try the next candidate.
    }
  }
  return undefined;
}

async function fetchAsMetadata(
  fetchImpl: FetchLike,
  issuer: string,
): Promise<AuthServerMetadata> {
  const base = issuer.replace(/\/+$/, "");
  const candidates = [
    `${base}/.well-known/oauth-authorization-server`,
    `${base}/.well-known/openid-configuration`,
  ];

  let last = "";
  for (const url of candidates) {
    try {
      const resp = await fetchImpl(url);
      if (resp.ok) {
        try {
          return (await resp.json()) as AuthServerMetadata;
        } catch (err) {
          throw new AuthCodeError(
            "discovery",
            `OAuth discovery failed: bad metadata at ${url}: ${err}`,
          );
        }
      }
      last = `${url} → HTTP ${resp.status}`;
    } catch (err) {
      if (err instanceof AuthCodeError) throw err;
      last = `${url} → ${err}`;
    }
  }

  throw new AuthCodeError(
    "discovery",
    `OAuth discovery failed: no authorization server metadata found (last attempt: ${last})`,
  );
}

async function postForm(
  fetchImpl: FetchLike,
  endpoint: string,
  form: Record<string, string>,
): Promise<TokenResponse> {
  let response: Response;
  try {
    response = await fetchImpl(endpoint, {
      method: "POST",
      headers: { "Content-Type": "application/x-www-form-urlencoded" },
      body: new URLSearchParams(form).toString(),
    });
  } catch (err) {
    throw new AuthCodeError("http", `HTTP error: ${err}`);
  }

  if (!response.ok) {
    const body = await response.text().catch(() => "");
    throw new AuthCodeError(
      "token_exchange",
      `token exchange failed (HTTP ${response.status}): ${body}`,
      { status: response.status, body },
    );
  }

  try {
    return (await response.json()) as TokenResponse;
  } catch (err) {
    throw new AuthCodeError("http", `bad token response: ${err}`);
  }
}
