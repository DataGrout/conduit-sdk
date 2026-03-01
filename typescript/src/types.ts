/**
 * Type definitions for DataGrout Conduit
 */

// ─── Rate limiting ───────────────────────────────────────────────────────────

/**
 * Rate limit cap returned in `X-RateLimit-Limit` response headers.
 *
 * - `"unlimited"` — authenticated DataGrout users; the gateway never blocks them.
 * - `{ perHour: number }` — unauthenticated callers hitting a per-hour cap.
 */
export type RateLimit = 'unlimited' | { perHour: number };

/**
 * Parsed rate limit state from a gateway response.
 *
 * Surfaced via `RateLimitError.status` when the client receives HTTP 429.
 */
export interface RateLimitStatus {
  /** Calls made in the current 1-hour window. */
  used: number;
  /** Total allowed calls (or `"unlimited"`). */
  limit: RateLimit;
  /** `true` when the caller has been throttled. */
  isLimited: boolean;
  /** Remaining calls this window, or `null` when unlimited. */
  remaining: number | null;
}

/** BYOK discount details embedded in a receipt. */
export interface Byok {
  enabled: boolean;
  discountApplied: number;
  discountRate: number;
}

/**
 * Cost receipt attached to every DG tool-call result under `result._meta.datagrout.receipt`.
 *
 * Use `extractMeta(result)` to pull this out cleanly.
 */
export interface Receipt {
  /** DG-internal receipt identifier (`rcp_…`). */
  receiptId: string;
  /** DB transaction ID (set only when a user account was charged). */
  transactionId?: string;
  timestamp: string;
  estimatedCredits: number;
  actualCredits: number;
  netCredits: number;
  savings: number;
  savingsBonus: number;
  /** Account balance before the charge. */
  balanceBefore?: number;
  /** Account balance after the charge. */
  balanceAfter?: number;
  /** Per-component credit breakdown. */
  breakdown: Record<string, any>;
  byok: Byok;
}

/** Pre-execution credit estimate under `result._meta.datagrout.credit_estimate`. */
export interface CreditEstimate {
  estimatedTotal: number;
  actualTotal: number;
  netTotal: number;
  breakdown: Record<string, any>;
}

/**
 * The DataGrout billing block attached to every tool-call result in `_meta.datagrout`.
 *
 * @example
 * ```ts
 * const result = await client.callTool('salesforce@v1/get_lead@v1', { id: '123' });
 * const meta = extractMeta(result);
 * if (meta) console.log(`Charged ${meta.receipt.netCredits} credits`);
 * ```
 */
export interface ToolMeta {
  receipt: Receipt;
  creditEstimate?: CreditEstimate;
}

/**
 * Extract the DataGrout metadata block from a tool-call result.
 *
 * Checks `_meta.datagrout` first (current format — MCP spec extension point),
 * then falls back to top-level `_datagrout`, then bare `_meta`, for
 * backward compatibility with older gateway responses.
 *
 * Returns `null` when no recognized key is found (e.g. upstream servers not
 * routed through the DG gateway).
 */
export function extractMeta(result: Record<string, any>): ToolMeta | null {
  const raw = result?._meta?.datagrout ?? result?._datagrout ?? result?._meta;
  if (!raw?.receipt) return null;

  const r = raw.receipt;
  const receipt: Receipt = {
    receiptId: r.receipt_id ?? '',
    transactionId: r.transaction_id,
    timestamp: r.timestamp ?? '',
    estimatedCredits: r.estimated_credits ?? 0,
    actualCredits: r.actual_credits ?? 0,
    netCredits: r.net_credits ?? 0,
    savings: r.savings ?? 0,
    savingsBonus: r.savings_bonus ?? 0,
    balanceBefore: r.balance_before,
    balanceAfter: r.balance_after,
    breakdown: r.breakdown ?? {},
    byok: {
      enabled: r.byok?.enabled ?? false,
      discountApplied: r.byok?.discount_applied ?? 0,
      discountRate: r.byok?.discount_rate ?? 0,
    },
  };

  const e = raw.credit_estimate;
  const creditEstimate: CreditEstimate | undefined = e
    ? {
        estimatedTotal: e.estimated_total ?? 0,
        actualTotal: e.actual_total ?? 0,
        netTotal: e.net_total ?? 0,
        breakdown: e.breakdown ?? {},
      }
    : undefined;

  return { receipt, creditEstimate };
}

export interface ToolInfo {
  toolName: string;
  integration: string;
  serverId?: string;
  score?: number;
  distance?: number;
  description?: string;
  sideEffects?: string;
  inputSchema?: Record<string, any>;
  outputSchema?: Record<string, any>;
}

export interface DiscoverResult {
  queryUsed: string;
  results: ToolInfo[];
  total: number;
  limit: number;
}

export interface PerformResult {
  success: boolean;
  result: any;
  tool: string;
  metadata?: Record<string, any>;
  receipt?: Receipt;
}

export interface GuideOptions {
  id: string;
  label: string;
  cost: number;
  viable: boolean;
  metadata?: Record<string, any>;
}

export interface GuideState {
  sessionId: string;
  step: string;
  message: string;
  status: string;
  options?: GuideOptions[];
  pathTaken?: string[];
  totalCost?: number;
  result?: any;
  progress?: string;
}

export interface AuthConfig {
  bearer?: string;
  basic?: {
    username: string;
    password: string;
  };
  /**
   * OAuth 2.1 `client_credentials` grant.
   *
   * When set, the SDK automatically fetches and caches a short-lived JWT from
   * the DataGrout token endpoint.  No token management needed in application code.
   *
   * The `tokenEndpoint` is derived from the client URL automatically if omitted.
   */
  clientCredentials?: {
    clientId: string;
    clientSecret: string;
    /** Optional explicit token endpoint URL. Derived from the client URL if omitted. */
    tokenEndpoint?: string;
    /** Optional space-separated scope string (e.g. `"mcp tools"`). */
    scope?: string;
  };
  custom?: Record<string, string>;
}

export interface ClientOptions {
  url: string;
  auth?: AuthConfig;
  /**
   * mTLS client identity.  When set, every connection presents this
   * certificate during the TLS handshake (Node.js only).
   *
   * Can be set explicitly or discovered automatically via
   * `ConduitIdentity.tryDefault()`.
   */
  identity?: import('./identity').ConduitIdentity;
  /**
   * When `true`, auto-discover an mTLS identity from env vars or
   * `~/.conduit/` before falling back to token auth.  Equivalent to
   * calling `ConduitIdentity.tryDefault()` and passing the result as
   * `identity`.
   */
  identityAuto?: boolean;
  /**
   * Custom directory for identity storage and discovery.  Overrides the
   * default `~/.conduit/` directory.  Useful for running multiple agents
   * on the same machine — each gets its own identity directory.
   */
  identityDir?: string;
  /**
   * Enable the intelligent interface (DataGrout `discover` / `perform` only).
   *
   * When `true`, `listTools()` returns only the DataGrout semantic discovery
   * and execution tools instead of the raw tool list from the MCP server.
   * This mirrors the `use_intelligent_interface` setting on the server.
   *
   * @default false
   */
  useIntelligentInterface?: boolean;
  /**
   * Disable automatic mTLS even for DataGrout URLs.
   *
   * By default, DG URLs (`*.datagrout.ai`) silently attempt to discover an
   * mTLS identity from env vars or `~/.conduit/`.  Set to `true` to opt out
   * and use token-only auth.
   *
   * @default false
   */
  disableMtls?: boolean;
  transport?: 'mcp' | 'jsonrpc';
  timeout?: number;
}

export interface DiscoverOptions {
  query?: string;
  goal?: string;
  limit?: number;
  minScore?: number;
  integrations?: string[];
  servers?: string[];
}

export interface PerformOptions {
  tool: string;
  args: Record<string, any>;
  demux?: boolean;
  demuxMode?: 'strict' | 'fuzzy';
}

export interface GuideRequestOptions {
  goal?: string;
  policy?: Record<string, any>;
  sessionId?: string;
  choice?: string;
}

export interface FlowOptions {
  plan: Array<Record<string, any>>;
  validateCtc?: boolean;
  saveAsSkill?: boolean;
  inputData?: Record<string, any>;
}

export interface PrismFocusOptions {
  data: Record<string, any>;
  sourceType: string;
  targetType: string;
}

export interface MCPTool {
  name: string;
  description?: string;
  inputSchema?: Record<string, any>;
}

export interface MCPResource {
  uri: string;
  name?: string;
  description?: string;
  mimeType?: string;
}

export interface MCPPrompt {
  name: string;
  description?: string;
  arguments?: Array<{
    name: string;
    description?: string;
    required?: boolean;
  }>;
}
