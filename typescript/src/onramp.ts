/**
 * Autonomous agent self-registration (onramp) for DataGrout.
 *
 * The onramp flow lets a machine intelligence register itself with DG
 * without a human in the loop, using only plain HTTP JSON — no MCP client
 * required. This matters because many agent harnesses gate or restrict MCP
 * connections but allow arbitrary HTTP requests.
 *
 * Flow
 * ----
 * 1. POST to `/onramp` with agent identity metadata (no auth).
 * 2. DG returns a short-lived `session_token` (5 minutes).
 * 3. POST to `/onramp/complete` with `Authorization: Bearer <session_token>`.
 * 4. DG issues provisional `client_id` + `client_secret` (restricted scopes).
 *
 * @example
 * ```ts
 * import { Client } from './client';
 * import { OnrampOptions } from './onramp';
 *
 * // One-shot: autonomous registration + mTLS bootstrap.
 * const client = await Client.bootstrapOnramp({
 *   opts: {
 *     gateway: 'https://app.datagrout.ai',
 *     agentName: 'my-research-agent',
 *     agentType: 'claude-sonnet-4-6',
 *     intendedUse: 'Summarise documents and extract entities.',
 *   },
 * });
 * await client.connect();
 * ```
 */

/** Options for the autonomous agent onramp flow. */
export interface OnrampOptions {
  /** DataGrout gateway base URL (e.g. `"https://app.datagrout.ai"`). */
  gateway: string;
  /** Human-readable name for this agent instance. */
  agentName: string;
  /** Model or framework identifier (e.g. `"claude-sonnet-4-6"`, `"gpt-4o"`). */
  agentType?: string;
  /** Plain-language description of what the agent intends to do. */
  intendedUse?: string;
  /** Optional access code from the server owner — reserved for scope elevation. */
  accessCode?: string;
}

/**
 * Provisional credentials returned by the DG onramp complete endpoint.
 *
 * Store `clientId` and `clientSecret` securely — the secret is shown exactly
 * once and cannot be recovered after this point.
 *
 * `mcpUrl` and `rpcUrl` are provisioned as part of the identity registration
 * step and may be absent from the initial onramp response. Use
 * `Client.bootstrapOnramp` for the all-in-one flow that handles this
 * transparently.
 */
export interface OnrampCredentials {
  /** OAuth client ID. */
  clientId: string;
  /** OAuth client secret. Store this securely — shown once. */
  clientSecret: string;
  /** Token endpoint for the `client_credentials` grant. */
  tokenUrl: string;
  /** Granted OAuth scopes. */
  scopes: string[];
  /** Provisional credential TTL in seconds. */
  expiresIn: number;
  /** JSON-RPC endpoint. Absent until identity is registered. */
  rpcUrl?: string;
  /** MCP endpoint. Absent until identity is registered. */
  mcpUrl?: string;
}

// ---------------------------------------------------------------------------
// Internal helpers (also used by Client.bootstrapOnramp)
// ---------------------------------------------------------------------------

/** @internal */
export async function _doRegister(
  opts: OnrampOptions,
): Promise<OnrampCredentials> {
  const base = opts.gateway.replace(/\/$/, "");

  const body: Record<string, string> = { agent_name: opts.agentName };
  if (opts.agentType) body["agent_type"] = opts.agentType;
  if (opts.intendedUse) body["intended_use"] = opts.intendedUse;
  if (opts.accessCode) body["access_code"] = opts.accessCode;

  const initResp = await fetch(`${base}/onramp`, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify(body),
  });

  if (!initResp.ok) {
    const text = await initResp.text();
    throw new Error(`onramp init rejected (HTTP ${initResp.status}): ${text}`);
  }

  const initData = (await initResp.json()) as { session_token: string };
  const sessionToken = initData.session_token;

  const completeResp = await fetch(`${base}/onramp/complete`, {
    method: "POST",
    headers: { Authorization: `Bearer ${sessionToken}` },
  });

  if (!completeResp.ok) {
    const text = await completeResp.text();
    throw new Error(
      `onramp complete rejected (HTTP ${completeResp.status}): ${text}`,
    );
  }

  const data = (await completeResp.json()) as Record<string, any>;
  return {
    clientId: data["client_id"] as string,
    clientSecret: data["client_secret"] as string,
    tokenUrl: data["token_url"] as string,
    scopes: (data["scopes"] as string[]) ?? [],
    expiresIn: (data["expires_in"] as number) ?? 0,
    rpcUrl: data["rpc_url"] as string | undefined,
    mcpUrl: data["mcp_url"] as string | undefined,
  };
}

/** @internal */
export async function _exchangeToken(
  creds: OnrampCredentials,
): Promise<string> {
  const body = new URLSearchParams({
    grant_type: "client_credentials",
    client_id: creds.clientId,
    client_secret: creds.clientSecret,
  });

  const resp = await fetch(creds.tokenUrl, {
    method: "POST",
    body,
  });

  if (!resp.ok) {
    const text = await resp.text();
    throw new Error(`token exchange failed (HTTP ${resp.status}): ${text}`);
  }

  const data = (await resp.json()) as { access_token: string };
  return data.access_token;
}

// ---------------------------------------------------------------------------
// Public API
// ---------------------------------------------------------------------------

/**
 * Perform the onramp handshake and return provisional OAuth credentials.
 *
 * This is the low-level entry point. Most callers should use
 * `Client.bootstrapOnramp` instead, which chains onramp → token exchange →
 * mTLS identity bootstrap in a single call.
 *
 * @param opts Onramp registration options.
 * @returns `OnrampCredentials` containing `clientId` and `clientSecret`.
 */
export async function registerOnly(
  opts: OnrampOptions,
): Promise<OnrampCredentials> {
  return _doRegister(opts);
}

/**
 * Perform the full onramp handshake and OAuth token exchange.
 *
 * Returns the provisional credentials alongside a short-lived access token
 * ready for use with `Client.bootstrapIdentity`.
 *
 * @param opts Onramp registration options.
 * @returns Tuple of `[OnrampCredentials, accessToken]`.
 */
export async function registerAndExchange(
  opts: OnrampOptions,
): Promise<[OnrampCredentials, string]> {
  const creds = await _doRegister(opts);
  const token = await _exchangeToken(creds);
  return [creds, token];
}
