/**
 * RFC 8693 **delegation** — an agent acting *for* a user.
 *
 * The two grants this SDK already speaks each answer one question.
 * {@link ./oauth} (`client_credentials`) says *which machine* is calling;
 * {@link ./authcode} says *which person* consented. Neither says both, and an
 * agent working on a user's behalf needs to: the resource server has to know
 * whose data it is (`sub`) and who is actually holding the connection (`act`).
 * The RFC 8693 exchange produces exactly that token, from two the caller
 * already has.
 *
 * # Delegation, not impersonation
 *
 * RFC 8693 distinguishes the two. In **delegation** the issued token names the
 * user as `sub` and the agent in an `act` claim, so the resource server can
 * see — and audit, and rate-limit, and revoke — the agent separately from the
 * user. In **impersonation** the agent simply *becomes* the user, and the
 * resource server cannot tell the difference. DataGrout's authorization server
 * issues delegation tokens and requires an `actor_token`; this module
 * therefore **requires an actor by default** and refuses to build a request
 * without one. Impersonation is an explicit opt-in via
 * {@link DelegationRequest.impersonation}, for RFC 8693 servers that support
 * it.
 *
 * # Wire contract
 *
 * `POST {tokenEndpoint}`, form-encoded, in this order:
 *
 * | field | value |
 * |---|---|
 * | `grant_type` | {@link GRANT_TYPE} |
 * | `subject_token`, `subject_token_type` | the user's token and its {@link TokenType} URN |
 * | `actor_token`, `actor_token_type` | the agent's token and URN — omitted only under `impersonation()` |
 * | `client_id`, `client_secret?` | client authentication, in the body by default (see {@link ClientAuth}) |
 * | `audience?`, `resource?`, `scope?`, `requested_token_type?` | as set |
 *
 * `resource` is RFC 8707 and, when set, is always sent — the same invariant the
 * authorization-code module keeps, so a delegated token cannot be replayed
 * against a different resource.
 *
 * **The client must be the actor.** The `client_id` authenticating the request
 * and the principal behind `actor_token` are expected to be the same agent.
 * This SDK does not verify that — it cannot, without decoding the actor token —
 * and the server enforces it (`unauthorized_client` when they differ).
 *
 * The response is `{access_token, issued_token_type, token_type, expires_in?,
 * scope?}`; errors are RFC 6749 bodies `{error, error_description?}`, with the
 * codes listed in {@link SERVER_ERROR_CODES}.
 *
 * ```ts
 * import {
 *   Client,
 *   DelegatedProvider,
 *   DelegationRequest,
 *   OAuthTokenProvider,
 *   TokenSource,
 *   TOKEN_TYPES,
 * } from "@datagrout/conduit";
 *
 * // The agent's own credential — the actor.
 * const agent = new OAuthTokenProvider({
 *   clientId: "agent_client_id",
 *   clientSecret: "agent_client_secret",
 *   tokenEndpoint: "https://gateway.datagrout.ai/oauth/token",
 * });
 *
 * // The user's token — the subject. Here one handed to the agent for this run;
 * // a long-lived app would use `TokenSource.authorizationCode(provider)`.
 * const user = TokenSource.staticToken(userToken, TOKEN_TYPES.access_token);
 *
 * const request = new DelegationRequest(
 *   "https://gateway.datagrout.ai/oauth/token",
 *   "agent_client_id",
 * )
 *   .clientSecret("agent_client_secret")
 *   .resource("https://gateway.datagrout.ai/connect");
 *
 * const provider = new DelegatedProvider(
 *   request,
 *   user,
 *   TokenSource.clientCredentials(agent),
 * );
 *
 * const client = new Client({
 *   url: "https://gateway.datagrout.ai/connect",
 *   auth: { delegation: provider },
 * });
 * ```
 *
 * # Naming
 *
 * Elsewhere in this SDK "token exchange" already means redeeming a
 * `client_credentials` grant — `AuthCodeError`'s `token_exchange` kind, and the
 * onramp's `token_exchange` stage. This module says *delegation* and *exchange*
 * — {@link DelegationRequest.exchange}, {@link DelegatedToken} — and never
 * reuses that label, so a log line cannot be read two ways.
 */

import { ConduitError } from "./errors";
import type { AuthCodeProvider, FetchLike } from "./authcode";
import type { OAuthTokenProvider } from "./oauth";

/** The RFC 8693 grant type. */
export const GRANT_TYPE = "urn:ietf:params:oauth:grant-type:token-exchange";

/**
 * `util.inspect`'s hook, resolved once so it can key a class method.
 *
 * Both this module's inspect overrides exist to keep tokens and the client
 * secret out of a debug dump: without one, `util.inspect` walks the instance's
 * own fields and prints them.
 */
const INSPECT_CUSTOM = Symbol.for("nodejs.util.inspect.custom");

/**
 * Re-exchange this many seconds before the delegated token actually expires.
 *
 * The same buffer {@link ./oauth} and {@link ./authcode} use, so all three
 * providers behave alike under a clock skew.
 */
const REFRESH_SKEW_SECS = 60;

/**
 * RFC 6749 error codes an RFC 8693 endpoint returns, as
 * {@link DelegationError.error} on a `server` failure.
 *
 * Listed so callers and ports compare against a name rather than a string they
 * typed. `invalid_target` is the one specific to RFC 8693: the `audience` or
 * `resource` is not one this server issues tokens for.
 */
export const SERVER_ERROR_CODES = Object.freeze([
  /** Malformed request, or a required parameter missing. */
  "invalid_request",
  /** Client authentication failed. */
  "invalid_client",
  /** The subject or actor token is invalid, expired, or revoked. */
  "invalid_grant",
  /** This client may not use this grant — including a client that is not the actor. */
  "unauthorized_client",
  /** The requested `audience` or `resource` is not served here (RFC 8693 §2.2.2). */
  "invalid_target",
  /** A requested scope is unknown or exceeds what the subject token allows. */
  "invalid_scope",
  /** The server does not support the exchange. */
  "unsupported_grant_type",
] as const);

/** One of {@link SERVER_ERROR_CODES}. */
export type ServerErrorCode = (typeof SERVER_ERROR_CODES)[number];

// ─── Token types ─────────────────────────────────────────────────────────────

/**
 * The RFC 8693 §3 token-type URNs this SDK names.
 *
 * Keyed by the RFC's own short names — which are also the keys
 * `testdata/contract.json` uses — rather than camelCase, so the fixture and the
 * table are read side by side.
 */
export const TOKEN_TYPES = Object.freeze({
  /** The default for both subject and actor, and what DataGrout issues. */
  access_token: "urn:ietf:params:oauth:token-type:access_token",
  /** A JWT presented as a JWT rather than as an opaque access token. */
  jwt: "urn:ietf:params:oauth:token-type:jwt",
  id_token: "urn:ietf:params:oauth:token-type:id_token",
  refresh_token: "urn:ietf:params:oauth:token-type:refresh_token",
  saml2: "urn:ietf:params:oauth:token-type:saml2",
} as const);

/** A URN this SDK names. */
export type NamedTokenTypeUrn = (typeof TOKEN_TYPES)[keyof typeof TOKEN_TYPES];

/**
 * An RFC 8693 §3 token type identifier, **as its URN**.
 *
 * A token type *is* its URN here, so the wire shape is the same string in every
 * language and serialization is the identity: nothing has to be mapped on the
 * way out or in. The five named URNs autocomplete via {@link TOKEN_TYPES}; any
 * other URN is carried verbatim, which is the open `other` case Rust models as
 * `TokenType::Other` — {@link tokenTypeName} reports it as `"other"`.
 */
export type TokenType = NamedTokenTypeUrn | (string & {});

/** The short name of a token type, or `"other"` for a URN this SDK does not name. */
export type TokenTypeName = keyof typeof TOKEN_TYPES | "other";

/**
 * The short name for a token-type URN.
 *
 * For logs, tests and cross-language comparison — the value itself stays the
 * URN, so this is never needed to build a request.
 */
export function tokenTypeName(tokenType: TokenType): TokenTypeName {
  for (const [name, urn] of Object.entries(TOKEN_TYPES)) {
    if (urn === tokenType) return name as keyof typeof TOKEN_TYPES;
  }
  return "other";
}

// ─── Errors ──────────────────────────────────────────────────────────────────

/**
 * The distinguishable failures of a delegation exchange.
 *
 * The taxonomy is part of the cross-language contract: every conduit SDK
 * distinguishes these same cases under the same names, so callers can branch
 * identically.
 */
export type DelegationErrorKind =
  /** No subject token was set — there is nobody to act for. */
  | "missing_subject"
  /** No actor token was set and the request is not an impersonation. */
  | "missing_actor"
  /** Transport failure talking to the token endpoint. */
  | "http"
  /** The token endpoint refused, with an RFC 6749 error body. */
  | "server"
  /**
   * The endpoint answered with something that is not an RFC 8693 response — a
   * success body missing required fields, or a failure whose body is not an
   * RFC 6749 error.
   */
  | "invalid_response";

/** An error from a delegation exchange, tagged with its {@link DelegationErrorKind}. */
export class DelegationError extends ConduitError {
  readonly kind: DelegationErrorKind;
  /** HTTP status, for `server`. */
  readonly status?: number;
  /** RFC 6749 error code, for `server`; see {@link SERVER_ERROR_CODES}. */
  readonly error?: ServerErrorCode | (string & {});
  /** Human-readable description, when the server gave one. */
  readonly errorDescription?: string;

  constructor(
    kind: DelegationErrorKind,
    message: string,
    extra?: {
      status?: number;
      error?: ServerErrorCode | (string & {});
      errorDescription?: string;
    },
  ) {
    super(message);
    this.kind = kind;
    this.status = extra?.status;
    this.error = extra?.error;
    this.errorDescription = extra?.errorDescription;
  }
}

// ─── Request ─────────────────────────────────────────────────────────────────

/**
 * How the client authenticates to the token endpoint.
 *
 * - `"body"` — `client_id` and `client_secret` as form fields (RFC 6749 §2.3.1
 *   `client_secret_post`). The default, and what DataGrout expects.
 * - `"basic"` — `Authorization: Basic base64(client_id:client_secret)`
 *   (`client_secret_basic`). `client_id` is still sent in the body, as RFC 6749
 *   permits and some servers require.
 */
export type ClientAuth = "body" | "basic";

/**
 * A delegation request, built up and then {@link DelegationRequest.exchange}d.
 *
 * The builder methods mutate and return `this`, as {@link AuthCodeFlow}'s do.
 * {@link DelegationRequest.clone} exists because a {@link DelegatedProvider}
 * holds one as a template and fills in fresh subject and actor tokens on each
 * re-exchange.
 */
export class DelegationRequest {
  private readonly endpoint: string;
  private readonly client: string;
  private secret?: string;
  private auth: ClientAuth = "body";
  private subject?: { token: string; tokenType: TokenType };
  private actor?: { token: string; tokenType: TokenType };
  private audienceValue?: string;
  private resourceValue?: string;
  private scopeValue?: string;
  private requestedTokenTypeValue?: TokenType;
  private impersonating = false;

  /**
   * Start a request against `tokenEndpoint`, authenticating as `clientId`.
   *
   * The client should be the actor — see the module docs.
   */
  constructor(tokenEndpoint: string, clientId: string) {
    this.endpoint = tokenEndpoint;
    this.client = clientId;
  }

  /** The client secret, for confidential clients. */
  clientSecret(secret: string): this {
    this.secret = secret;
    return this;
  }

  /** Where the client secret travels. Defaults to `"body"`. */
  clientAuth(auth: ClientAuth): this {
    this.auth = auth;
    return this;
  }

  /**
   * The token being exchanged: the **user's**, whose identity the issued token
   * will carry as `sub`.
   */
  subjectToken(
    token: string,
    tokenType: TokenType = TOKEN_TYPES.access_token,
  ): this {
    this.subject = { token, tokenType };
    return this;
  }

  /** The **agent's** own token, which the issued token will name in `act`. */
  actorToken(
    token: string,
    tokenType: TokenType = TOKEN_TYPES.access_token,
  ): this {
    this.actor = { token, tokenType };
    return this;
  }

  /** Logical name of the service the token is for (RFC 8693 `audience`). */
  audience(audience: string): this {
    this.audienceValue = audience;
    return this;
  }

  /**
   * URI of the resource the token is for (RFC 8707 `resource`). Always sent
   * when set, so the token cannot be replayed elsewhere.
   */
  resource(resource: string): this {
    this.resourceValue = resource;
    return this;
  }

  /** Scopes to request, space-separated. */
  scope(scope: string): this {
    this.scopeValue = scope;
    return this;
  }

  /** The kind of token wanted back. Servers default to an access token. */
  requestedTokenType(tokenType: TokenType): this {
    this.requestedTokenTypeValue = tokenType;
    return this;
  }

  /**
   * Opt out of delegation: send no `actor_token`, so the issued token has no
   * `act` claim and the agent is indistinguishable from the user.
   *
   * DataGrout does not issue these. This exists for other RFC 8693 servers, and
   * it is a builder call rather than a default precisely so that forgetting to
   * set an actor is an error instead of a silent downgrade.
   */
  impersonation(): this {
    this.impersonating = true;
    return this;
  }

  /** The token endpoint this request posts to. */
  get tokenEndpoint(): string {
    return this.endpoint;
  }

  /** The client id this request authenticates as. */
  get clientId(): string {
    return this.client;
  }

  /** Whether {@link impersonation} was called. */
  get isImpersonation(): boolean {
    return this.impersonating;
  }

  /** An independent copy, so a template can be filled in per exchange. */
  clone(): DelegationRequest {
    const copy = new DelegationRequest(this.endpoint, this.client);
    copy.secret = this.secret;
    copy.auth = this.auth;
    copy.subject = this.subject && { ...this.subject };
    copy.actor = this.actor && { ...this.actor };
    copy.audienceValue = this.audienceValue;
    copy.resourceValue = this.resourceValue;
    copy.scopeValue = this.scopeValue;
    copy.requestedTokenTypeValue = this.requestedTokenTypeValue;
    copy.impersonating = this.impersonating;
    return copy;
  }

  /**
   * The form body this request will post, in wire order.
   *
   * Throws before any network activity when the request is incomplete:
   * `missing_subject`, or `missing_actor` unless {@link impersonation} was
   * called. Public so a caller — or another SDK's test suite — can check the
   * body against the contract fixture without a server.
   */
  formParams(): Array<[string, string]> {
    if (this.subject === undefined) {
      throw new DelegationError(
        "missing_subject",
        "no subject_token — call subjectToken() first",
      );
    }

    const form: Array<[string, string]> = [
      ["grant_type", GRANT_TYPE],
      ["subject_token", this.subject.token],
      ["subject_token_type", this.subject.tokenType],
    ];

    if (this.actor !== undefined) {
      form.push(["actor_token", this.actor.token]);
      form.push(["actor_token_type", this.actor.tokenType]);
    } else if (!this.impersonating) {
      throw new DelegationError(
        "missing_actor",
        "no actor_token — delegation requires one; call impersonation() to opt out explicitly",
      );
    }

    form.push(["client_id", this.client]);
    if (this.secret !== undefined && this.auth === "body") {
      form.push(["client_secret", this.secret]);
    }

    for (const [key, value] of [
      ["audience", this.audienceValue],
      ["resource", this.resourceValue],
      ["scope", this.scopeValue],
      ["requested_token_type", this.requestedTokenTypeValue],
    ] as const) {
      if (value !== undefined) form.push([key, value]);
    }

    return form;
  }

  /** Perform the exchange. */
  async exchange(
    fetchImpl: FetchLike = globalThis.fetch,
  ): Promise<DelegatedToken> {
    // Before anything is sent, so an incomplete request cannot reach the wire.
    const form = this.formParams();

    const headers: Record<string, string> = {
      "Content-Type": "application/x-www-form-urlencoded",
    };
    if (this.secret !== undefined && this.auth === "basic") {
      const credentials = Buffer.from(
        `${this.client}:${this.secret}`,
        "utf8",
      ).toString("base64");
      headers["Authorization"] = `Basic ${credentials}`;
    }

    let response: Response;
    try {
      response = await fetchImpl(this.endpoint, {
        method: "POST",
        headers,
        // `URLSearchParams` keeps the order it is given, which is the wire
        // order the contract fixture pins.
        body: new URLSearchParams(form).toString(),
      });
    } catch (err) {
      throw new DelegationError("http", `HTTP error: ${err}`);
    }

    const body = await response.text().catch(() => "");

    if (!response.ok) {
      throw errorFromBody(response.status, body);
    }

    let parsed: unknown;
    try {
      parsed = JSON.parse(body);
    } catch (err) {
      throw new DelegationError(
        "invalid_response",
        `HTTP ${response.status}: ${err}`,
      );
    }

    return tokenFromWire(parsed, response.status);
  }
}

/**
 * A non-2xx body is an RFC 6749 error when it carries a string `error`;
 * anything else — a proxy's HTML, an empty body — is reported as an invalid
 * response with the status, since it did not come from the token endpoint's
 * contract.
 */
function errorFromBody(status: number, body: string): DelegationError {
  let parsed: unknown;
  try {
    parsed = JSON.parse(body);
  } catch {
    parsed = undefined;
  }

  const oauth = parsed as
    | { error?: unknown; error_description?: unknown }
    | undefined;

  if (oauth && typeof oauth.error === "string") {
    const description =
      typeof oauth.error_description === "string"
        ? oauth.error_description
        : undefined;
    return new DelegationError(
      "server",
      `delegation exchange refused (HTTP ${status}): ${oauth.error}` +
        (description ? ` — ${description}` : ""),
      { status, error: oauth.error, errorDescription: description },
    );
  }

  return new DelegationError(
    "invalid_response",
    `HTTP ${status} with a non-OAuth body: ${body.slice(0, 200)}`,
  );
}

/**
 * RFC 8693 §2.2.1 success response → {@link DelegatedToken}.
 *
 * `access_token`, `issued_token_type` and `token_type` are REQUIRED by the RFC;
 * a server that drops one is out of contract, and guessing would hide that. The
 * server's relative `expires_in` becomes an absolute `expires_at` here, at
 * receipt.
 */
function tokenFromWire(parsed: unknown, status: number): DelegatedToken {
  const wire = parsed as Record<string, unknown> | null;

  const missing = ["access_token", "issued_token_type", "token_type"].filter(
    (field) => typeof wire?.[field] !== "string",
  );
  if (missing.length > 0) {
    throw new DelegationError(
      "invalid_response",
      `HTTP ${status}: delegation response is missing required field(s): ${missing.join(", ")}`,
    );
  }

  const expiresIn = wire!["expires_in"];
  const scope = wire!["scope"];

  return {
    access_token: wire!["access_token"] as string,
    issued_token_type: wire!["issued_token_type"] as string,
    token_type: wire!["token_type"] as string,
    ...(typeof expiresIn === "number"
      ? { expires_at: nowSecs() + expiresIn }
      : {}),
    ...(typeof scope === "string" ? { scope } : {}),
  };
}

// ─── Token ───────────────────────────────────────────────────────────────────

/**
 * A token issued by an exchange.
 *
 * The serialized shape is part of the cross-language contract, and is what
 * `testdata/contract.json` pins: `access_token`, `issued_token_type` (a URN
 * string), `token_type`, `expires_at?`, `scope?`. Field names are therefore
 * snake_case and fixed, so `JSON.stringify` on one of these is the wire form —
 * exactly as for `Grant`. As there, `expires_at` is **Unix seconds** —
 * computed from the server's relative `expires_in` at receipt — never
 * milliseconds and never a monotonic clock reading, so the token means the same
 * thing once written down.
 */
export interface DelegatedToken {
  /** The bearer token to present. */
  access_token: string;
  /** What kind of token was issued, as its {@link TokenType} URN. */
  issued_token_type: TokenType;
  /** How to present it — `Bearer`, in practice. */
  token_type: string;
  /** Absolute expiry, Unix **seconds**. Absent means the server did not say. */
  expires_at?: number;
  /** Granted scopes, when the server reported them. */
  scope?: string;
}

/**
 * True when the token is expired, or within the refresh skew of it.
 *
 * A token with no stated expiry is treated as live: the server chose not to say,
 * and guessing would throw away working tokens.
 */
export function isDelegatedTokenExpired(token: DelegatedToken): boolean {
  if (token.expires_at === undefined) return false;
  return nowSecs() + REFRESH_SKEW_SECS >= token.expires_at;
}

// ─── Token sources ───────────────────────────────────────────────────────────

/** What a {@link TokenSource} draws its token from — for logs, never the token. */
export type TokenSourceKind =
  | "static"
  | "client_credentials"
  | "authorization_code"
  | "dynamic";

/**
 * Where a {@link DelegatedProvider} gets a subject or actor token from, and what
 * {@link TokenType} to declare it as.
 *
 * A source is consulted on **every** exchange, so a provider-backed source hands
 * over a *fresh* token each time — the whole point of wrapping a provider rather
 * than copying its current token out.
 */
export class TokenSource {
  private readonly resolver: () => Promise<string>;
  private readonly sourceKind: TokenSourceKind;
  private readonly declaredType: TokenType;

  private constructor(
    kind: TokenSourceKind,
    tokenType: TokenType,
    resolver: () => Promise<string>,
  ) {
    this.sourceKind = kind;
    this.declaredType = tokenType;
    this.resolver = resolver;
  }

  /** A fixed token, e.g. one handed to the agent for this run. */
  static staticToken(
    token: string,
    tokenType: TokenType = TOKEN_TYPES.access_token,
  ): TokenSource {
    return new TokenSource("static", tokenType, async () => token);
  }

  /** The agent's own `client_credentials` provider — the usual **actor**. */
  static clientCredentials(
    provider: OAuthTokenProvider,
    tokenType: TokenType = TOKEN_TYPES.access_token,
  ): TokenSource {
    return new TokenSource("client_credentials", tokenType, () =>
      provider.getToken(),
    );
  }

  /**
   * A user's authorization-code provider — the usual **subject** in an app that
   * signed the user in itself. Refreshes its grant as needed, so the exchange
   * always sees a live subject token.
   */
  static authorizationCode(
    provider: AuthCodeProvider,
    tokenType: TokenType = TOKEN_TYPES.access_token,
  ): TokenSource {
    return new TokenSource("authorization_code", tokenType, () =>
      provider.getToken(),
    );
  }

  /**
   * Any function that yields a token — a vault lookup, a header from an inbound
   * request, another SDK's provider. Called on every exchange.
   */
  static dynamic(
    fn: () => string | Promise<string>,
    tokenType: TokenType = TOKEN_TYPES.access_token,
  ): TokenSource {
    return new TokenSource("dynamic", tokenType, async () => fn());
  }

  /** Declare a different {@link TokenType} for this source. */
  withTokenType(tokenType: TokenType): TokenSource {
    return new TokenSource(this.sourceKind, tokenType, this.resolver);
  }

  /** The declared token type. */
  get tokenType(): TokenType {
    return this.declaredType;
  }

  /** Where the token comes from. */
  get kind(): TokenSourceKind {
    return this.sourceKind;
  }

  /** Draw a token. */
  resolve(): Promise<string> {
    return this.resolver();
  }

  /** Never print tokens — only where they come from. */
  toJSON(): { kind: TokenSourceKind; tokenType: TokenType } {
    return { kind: this.sourceKind, tokenType: this.declaredType };
  }

  [INSPECT_CUSTOM](): string {
    return `TokenSource { kind: '${this.sourceKind}', tokenType: '${this.declaredType}' }`;
  }
}

// ─── Provider ────────────────────────────────────────────────────────────────

/**
 * Keeps a delegated token fresh, re-exchanging when it nears expiry.
 *
 * The third token provider in this SDK, shaped like the other two —
 * {@link OAuthTokenProvider} and {@link AuthCodeProvider} — so every transport
 * reaches it through the same path: `getToken` on the way out, `invalidate` on a
 * 401. Each exchange pulls a fresh subject and actor token from its
 * {@link TokenSource}s, so an expiring upstream credential is handled by the
 * provider that owns it.
 */
export class DelegatedProvider {
  private readonly template: DelegationRequest;
  private readonly subject: TokenSource;
  private readonly actor?: TokenSource;
  private readonly fetchImpl: FetchLike;

  private cached: DelegatedToken | null = null;
  /**
   * The in-flight exchange, so concurrent callers make one request rather than
   * a stampede. Mirrors `AuthCodeProvider`'s refresh de-duplication.
   */
  private exchangePromise: Promise<DelegatedToken> | null = null;

  /**
   * Wrap a request template with the sources of its two tokens.
   *
   * Any `subjectToken` or `actorToken` already on `request` is ignored; the
   * sources supply them. Omit `actor` only with a request that called
   * {@link DelegationRequest.impersonation} — otherwise every `getToken` fails
   * with `missing_actor`, which is the intended loud failure rather than a
   * silent downgrade.
   */
  constructor(
    request: DelegationRequest,
    subject: TokenSource,
    actor?: TokenSource,
    fetchImpl: FetchLike = globalThis.fetch,
  ) {
    this.template = request;
    this.subject = subject;
    this.actor = actor;
    this.fetchImpl = fetchImpl;
  }

  /**
   * The current delegated bearer, exchanging first if there is none or it is at
   * or near expiry.
   */
  async getToken(): Promise<string> {
    const live = this.liveToken();
    if (live !== undefined) return live;

    if (!this.exchangePromise) {
      this.exchangePromise = this.exchange()
        .then((token) => {
          this.cached = token;
          return token;
        })
        .finally(() => {
          this.exchangePromise = null;
        });
    }

    const token = await this.exchangePromise;
    return token.access_token;
  }

  /**
   * Force the next {@link getToken} to exchange again. Call on a 401.
   *
   * Only the delegated token is dropped. The subject and actor sources are left
   * alone: a provider-backed source tracks its own expiry, and a 401 from the
   * resource server says nothing about them.
   */
  invalidate(): void {
    this.cached = null;
  }

  /** A snapshot of the cached token, if any — for inspection or logging. */
  token(): DelegatedToken | undefined {
    return this.cached === null ? undefined : { ...this.cached };
  }

  /** The request template, without tokens. */
  get request(): DelegationRequest {
    return this.template;
  }

  /** Never print tokens, and never the client secret the template carries. */
  toJSON(): Record<string, unknown> {
    return {
      tokenEndpoint: this.template.tokenEndpoint,
      clientId: this.template.clientId,
      subject: this.subject.toJSON(),
      ...(this.actor ? { actor: this.actor.toJSON() } : {}),
      hasToken: this.cached !== null,
    };
  }

  [INSPECT_CUSTOM](): string {
    return `DelegatedProvider ${JSON.stringify(this.toJSON())}`;
  }

  // ─── Private ───────────────────────────────────────────────────────────────

  private liveToken(): string | undefined {
    if (this.cached === null) return undefined;
    if (isDelegatedTokenExpired(this.cached)) return undefined;
    return this.cached.access_token;
  }

  private async exchange(): Promise<DelegatedToken> {
    // Refuse before resolving anything: a missing actor is a configuration
    // mistake, and fetching a subject token first would only hide it.
    if (this.actor === undefined && !this.template.isImpersonation) {
      throw new DelegationError(
        "missing_actor",
        "no actor_token — delegation requires one; call impersonation() to opt out explicitly",
      );
    }

    const request = this.template
      .clone()
      .subjectToken(await this.subject.resolve(), this.subject.tokenType);

    if (this.actor !== undefined) {
      request.actorToken(await this.actor.resolve(), this.actor.tokenType);
    }

    return request.exchange(this.fetchImpl);
  }
}

function nowSecs(): number {
  return Math.floor(Date.now() / 1000);
}
