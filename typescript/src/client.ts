/**
 * DataGrout Conduit client implementation
 */

import * as path from "path";
import { Transport } from "./transports/base";
import { MCPTransport } from "./transports/mcp";
import { JSONRPCTransport } from "./transports/jsonrpc";
import { WsTransport, Subscription } from "./transports/ws";
export type { Subscription, SubscriptionEvent } from "./transports/ws";
import { ConduitIdentity } from "./identity";
import {
  generateKeypair,
  registerIdentity,
  saveIdentity,
  DEFAULT_IDENTITY_DIR,
  DG_SUBSTRATE_ENDPOINT,
} from "./registration";
import { NotInitializedError, InvalidConfigError } from "./errors";
import {
  PrismNamespace,
  LogicNamespace,
  WardenNamespace,
  DeliverablesNamespace,
  EphemeralsNamespace,
  FlowNamespace,
} from "./namespaces";
import type {
  ClientOptions,
  DiscoverResult,
  DiscoverOptions,
  PerformOptions,
  GuideRequestOptions,
  GuideState,
  PlanOptions,
  MCPTool,
  MCPResource,
  MCPPrompt,
} from "./types";

/**
 * Stateful guided workflow session returned by `Client.guide()`.
 *
 * Call `session.choose(optionId)` to advance through workflow steps,
 * and `session.complete()` to retrieve the final result once `status === "completed"`.
 */
export class GuidedSession {
  private client: Client;
  private state: GuideState;

  constructor(client: Client, state: GuideState) {
    this.client = client;
    this.state = state;
  }

  /** Unique session identifier used to resume the workflow. */
  get sessionId(): string {
    return this.state.sessionId;
  }

  /** Current workflow status (e.g. `"ready"`, `"completed"`). */
  get status(): string {
    return this.state.status;
  }

  /** Available options for the current step. */
  get options() {
    return this.state.options || [];
  }

  /** Final result, populated once `status === "completed"`. */
  get result() {
    return this.state.result;
  }

  /** Returns the raw `GuideState` snapshot for this step. */
  getState(): GuideState {
    return this.state;
  }

  /**
   * Advance the guided session by selecting an option.
   *
   * @param optionId - The `id` of the option to choose (from `session.options`).
   * @returns A new `GuidedSession` reflecting the next workflow step.
   */
  async choose(optionId: string): Promise<GuidedSession> {
    return await this.client.guide({
      sessionId: this.sessionId,
      choice: optionId,
    });
  }

  /**
   * Retrieve the completed workflow result.
   *
   * Throws if the session has not yet reached `status === "completed"`.
   * Use `choose()` to advance through remaining steps first.
   */
  async complete(): Promise<any> {
    if (this.status === "completed") {
      return this.result;
    }

    throw new Error(
      `Workflow not complete (status: ${this.status}). ` +
        `Call choose() with one of the available options.`,
    );
  }
}

/** Returns `true` when `url` points at a DataGrout-managed endpoint. */
export function isDgUrl(url: string): boolean {
  return (
    url.includes("datagrout.ai") ||
    url.includes("datagrout.dev") ||
    !!process.env["CONDUIT_IS_DG"]
  );
}

/**
 * DataGrout Conduit client — a drop-in replacement for MCP clients with
 * first-class support for DataGrout semantic extensions.
 *
 * @example
 * ```ts
 * const client = new Client('https://gateway.datagrout.ai/servers/<uuid>/mcp');
 * await client.connect();
 * const tools = await client.listTools();
 * await client.disconnect();
 * ```
 */
export class Client {
  private url: string;
  private auth?: ClientOptions["auth"];
  private useIntelligentInterface: boolean;
  private transport: Transport;
  private readonly isDg: boolean;
  private dgWarned = false;
  private initialized = false;
  private maxRetries: number;

  constructor(options: ClientOptions | string) {
    // Allow simple string URL or full options object
    if (typeof options === "string") {
      options = { url: options };
    }

    this.url = options.url;
    this.auth = options.auth;
    this.isDg = isDgUrl(this.url);
    this.useIntelligentInterface = options.useIntelligentInterface ?? this.isDg;
    this.maxRetries = options.maxRetries ?? 3;

    // Resolve identity: explicit > identityAuto flag.
    // Auto-discovery is opt-in only — pass identityAuto: true to enable it.
    const identity =
      options.identity ??
      (options.identityAuto
        ? (ConduitIdentity.tryDiscover(options.identityDir) ?? undefined)
        : undefined);

    const transportType = options.transport || "mcp";
    if (transportType === "mcp") {
      this.transport = new MCPTransport(this.url, this.auth, identity);
    } else if (transportType === "websocket") {
      // Rewrite https:// → wss:// (or http:// → ws://) if the caller passed
      // an HTTP URL so they don't have to think about it.
      let wsUrl = this.url;
      if (wsUrl.startsWith("https://")) wsUrl = "wss://" + wsUrl.slice(8);
      else if (wsUrl.startsWith("http://")) wsUrl = "ws://" + wsUrl.slice(7);
      this.transport = new WsTransport(
        wsUrl,
        this.auth,
        options.timeout,
        identity,
      );
    } else {
      // When the user passes an MCP URL (ending in /mcp), transparently rewrite
      // the path to the DG JSONRPC endpoint (/rpc).
      const rpcUrl = this.url.endsWith("/mcp")
        ? this.url.slice(0, -4) + "/rpc"
        : this.url;
      this.transport = new JSONRPCTransport(
        rpcUrl,
        this.auth,
        options.timeout,
        identity,
      );
    }
  }

  // ===== Bootstrap / seamless mTLS =====

  /**
   * Create a `Client` with an mTLS identity bootstrapped automatically.
   *
   * Checks the auto-discovery chain first. If an existing identity is found
   * and not within 7 days of expiry, it is reused. Otherwise a new keypair
   * is generated, registered with DataGrout, and saved locally.
   *
   * After the first successful bootstrap the token is no longer needed —
   * mTLS handles authentication on every subsequent run.
   *
   * @param options.url              - DataGrout server URL.
   * @param options.authToken        - Bearer token for the initial registration call.
   * @param options.name             - Human-readable identity name (default: `"conduit-client"`).
   * @param options.identityDir      - Custom identity storage directory.
   * @param options.substrateEndpoint - Override the DG Substrate endpoint.
   */
  static async bootstrapIdentity(options: {
    url: string;
    authToken: string;
    name?: string;
    identityDir?: string;
    substrateEndpoint?: string;
  }): Promise<Client> {
    const dir = options.identityDir || DEFAULT_IDENTITY_DIR;
    const name = options.name || "conduit-client";
    const endpoint = options.substrateEndpoint || DG_SUBSTRATE_ENDPOINT;

    // Fast path: existing identity that doesn't need rotation.
    const existing = ConduitIdentity.tryDiscover(dir);
    if (existing && !existing.needsRotation(7)) {
      const client = new Client({ url: options.url, identity: existing });
      await client.connect();
      return client;
    }

    // Slow path: generate, register, persist.
    const keypair = generateKeypair();
    const registered = await registerIdentity(keypair, {
      endpoint,
      authToken: options.authToken,
      name,
    });

    saveIdentity(registered, dir);

    const identity = ConduitIdentity.fromPaths(
      path.join(dir, "identity.pem"),
      path.join(dir, "identity_key.pem"),
      path.join(dir, "ca.pem"),
    );
    const client = new Client({ url: options.url, identity });
    await client.connect();
    return client;
  }

  /**
   * Like `bootstrapIdentity` but uses OAuth 2.1 `client_credentials` to obtain
   * the bearer token automatically — no pre-obtained token needed.
   *
   * @param options.url              - DataGrout server URL.
   * @param options.clientId         - OAuth client ID.
   * @param options.clientSecret     - OAuth client secret.
   * @param options.name             - Human-readable identity name (default: `"conduit-client"`).
   * @param options.identityDir      - Custom identity storage directory.
   * @param options.substrateEndpoint - Override the DG Substrate endpoint.
   */
  static async bootstrapIdentityOAuth(options: {
    url: string;
    clientId: string;
    clientSecret: string;
    name?: string;
    identityDir?: string;
    substrateEndpoint?: string;
  }): Promise<Client> {
    const { OAuthTokenProvider, deriveTokenEndpoint } = await import("./oauth");
    const tokenEndpoint = deriveTokenEndpoint(options.url);
    const provider = new OAuthTokenProvider({
      clientId: options.clientId,
      clientSecret: options.clientSecret,
      tokenEndpoint,
    });
    const token = await provider.getToken();
    return Client.bootstrapIdentity({
      url: options.url,
      authToken: token,
      name: options.name,
      identityDir: options.identityDir,
      substrateEndpoint: options.substrateEndpoint,
    });
  }

  /**
   * Register autonomously with DG and bootstrap an mTLS identity.
   *
   * The all-in-one flow: onramp (no prior credentials required) →
   * OAuth token exchange → mTLS identity registration and persistence.
   *
   * On subsequent runs the saved mTLS identity is auto-discovered and
   * no credentials are needed.
   *
   * @param options.opts         - Onramp registration options.
   * @param options.url          - MCP server URL. Required if the onramp
   *                               response does not include `mcpUrl`.
   * @param options.identityDir  - Custom identity storage directory.
   *
   * @example
   * ```ts
   * import { Client } from './client';
   * import type { OnrampOptions } from './onramp';
   *
   * const client = await Client.bootstrapOnramp({
   *   opts: {
   *     gateway: 'https://app.datagrout.ai',
   *     agentName: 'my-research-agent',
   *     agentType: 'claude-sonnet-4-6',
   *   },
   * });
   * await client.connect();
   * ```
   */
  static async bootstrapOnramp(options: {
    opts: import("./onramp").OnrampOptions;
    url?: string;
    identityDir?: string;
  }): Promise<Client> {
    const { _doRegister, _exchangeToken } = await import("./onramp");
    const dir = options.identityDir || DEFAULT_IDENTITY_DIR;

    // Fast path: existing valid identity.
    const existing = ConduitIdentity.tryDiscover(dir);
    if (existing && !existing.needsRotation(7)) {
      if (!options.url) {
        throw new Error(
          "'url' must be provided when an existing identity is reused",
        );
      }
      return new Client({
        url: options.url,
        identity: existing,
        identityDir: dir,
      });
    }

    // Slow path: full onramp flow.
    const creds = await _doRegister(options.opts);
    const token = await _exchangeToken(creds);

    const url = creds.mcpUrl ?? options.url;
    if (!url) {
      throw new Error(
        "'url' must be provided when mcpUrl is absent from the onramp response",
      );
    }

    return Client.bootstrapIdentity({
      url,
      authToken: token,
      name: options.opts.agentName,
      identityDir: options.identityDir,
    });
  }

  // ===== Lifecycle =====

  /**
   * Establish the underlying transport connection.
   *
   * Must be called before any other method. For the MCP transport this
   * performs the JSON-RPC `initialize` handshake; for JSONRPC it is a no-op
   * (connections are per-request).
   */
  async connect(): Promise<void> {
    await this.transport.connect();
    this.initialized = true;
  }

  /**
   * Close the underlying transport connection and mark the client as
   * uninitialized. After calling this, `connect()` must be called again
   * before issuing further requests.
   */
  async disconnect(): Promise<void> {
    await this.transport.disconnect();
    this.initialized = false;
  }

  private ensureInitialized(): void {
    if (!this.initialized) {
      throw new NotInitializedError();
    }
  }

  /**
   * Wrap a transport call with automatic retry on "not initialized" errors
   * (JSON-RPC code -32002). Re-initializes the connection and retries up to
   * `maxRetries` times with 500ms backoff between attempts.
   */
  private async sendWithRetry<T>(fn: () => Promise<T>): Promise<T> {
    let retries = this.maxRetries;

    // eslint-disable-next-line no-constant-condition
    while (true) {
      try {
        return await fn();
      } catch (error: any) {
        const isNotInit =
          error?.code === -32002 || error?.message?.includes("not initialized");
        if (isNotInit && retries > 0) {
          retries--;
          await this.connect();
          await new Promise((r) => setTimeout(r, 500));
          continue;
        }
        throw error;
      }
    }
  }

  // ===== Namespace Accessors =====

  private callDgTool = async (
    tool: string,
    params: Record<string, any>,
  ): Promise<any> => {
    this.ensureInitialized();
    return this.sendWithRetry(() =>
      this.transport.callTool(`data-grout/${tool}`, params),
    );
  };

  /** Data transformation, charting, rendering, and type bridging. */
  get prism(): PrismNamespace {
    return new PrismNamespace(this.callDgTool, (m) => this.warnIfNotDg(m));
  }

  /** Persistent agent memory backed by a Prolog logic cell. */
  get logic(): LogicNamespace {
    return new LogicNamespace(this.callDgTool, (m) => this.warnIfNotDg(m));
  }

  /** Safety gates, intent verification, and multi-model consensus. */
  get warden(): WardenNamespace {
    return new WardenNamespace(this.callDgTool, (m) => this.warnIfNotDg(m));
  }

  /** Work product registration, listing, and retrieval. */
  get deliverables(): DeliverablesNamespace {
    return new DeliverablesNamespace(this.callDgTool, (m) =>
      this.warnIfNotDg(m),
    );
  }

  /** Cache listing and inspection. */
  get ephemerals(): EphemeralsNamespace {
    return new EphemeralsNamespace(this.callDgTool, (m) => this.warnIfNotDg(m));
  }

  /** Multi-step orchestration, routing, approvals, and execution history. */
  get flow(): FlowNamespace {
    return new FlowNamespace(this.callDgTool, (m) => this.warnIfNotDg(m));
  }

  // ===== Standard MCP API (Drop-in Compatible) =====

  /**
   * List all tools exposed by the connected MCP server.
   *
   * Calls the MCP `tools/list` method with automatic cursor-based pagination.
   * When `useIntelligentInterface` is enabled (default for DataGrout URLs),
   * integration tools (names containing `@`) are filtered out, leaving only
   * the DataGrout semantic discovery interface.
   *
   * JSON-RPC method: `tools/list`
   */
  async listTools(options?: any): Promise<MCPTool[]> {
    this.ensureInitialized();
    return this.sendWithRetry(async () => {
      let allTools: MCPTool[] = [];
      let cursor: string | undefined;

      do {
        const response = await this.transport.listTools({ ...options, cursor });
        const tools = Array.isArray(response)
          ? response
          : (response as any).tools || [];
        allTools.push(...tools);
        cursor = Array.isArray(response)
          ? undefined
          : (response as any).nextCursor;
      } while (cursor);

      if (this.useIntelligentInterface) {
        return allTools.filter((t) => !t.name.includes("@"));
      }
      return allTools;
    });
  }

  /**
   * Invoke a named tool on the connected MCP server.
   *
   * JSON-RPC method: `tools/call`
   *
   * @param name - Fully-qualified tool name (e.g. `salesforce@v1/get_lead@v1`).
   * @param args - Tool input arguments.
   */
  async callTool(
    name: string,
    args: Record<string, any>,
    _options?: any,
  ): Promise<any> {
    this.ensureInitialized();
    return this.sendWithRetry(() => this.transport.callTool(name, args));
  }

  /**
   * List resources exposed by the connected MCP server.
   *
   * JSON-RPC method: `resources/list`
   */
  async listResources(options?: any): Promise<MCPResource[]> {
    this.ensureInitialized();
    return this.sendWithRetry(() => this.transport.listResources(options));
  }

  /**
   * Read the content of a named resource.
   *
   * JSON-RPC method: `resources/read`
   *
   * @param uri - Resource URI as returned by `listResources()`.
   */
  async readResource(uri: string, options?: any): Promise<any> {
    this.ensureInitialized();
    return this.sendWithRetry(() => this.transport.readResource(uri, options));
  }

  /**
   * List prompt templates exposed by the connected MCP server.
   *
   * JSON-RPC method: `prompts/list`
   */
  async listPrompts(options?: any): Promise<MCPPrompt[]> {
    this.ensureInitialized();
    return this.sendWithRetry(() => this.transport.listPrompts(options));
  }

  /**
   * Retrieve a prompt template, optionally instantiated with arguments.
   *
   * JSON-RPC method: `prompts/get`
   *
   * @param name - Prompt name as returned by `listPrompts()`.
   * @param args - Template argument values.
   */
  async getPrompt(
    name: string,
    args?: Record<string, any>,
    options?: any,
  ): Promise<any> {
    this.ensureInitialized();
    return this.sendWithRetry(() =>
      this.transport.getPrompt(name, args, options),
    );
  }

  // ===== WebSocket push subscriptions =====

  /**
   * Subscribe to a server-push topic (WebSocket transport only).
   *
   * Requires `transport: 'websocket'` when constructing the client.
   *
   * @param topic - Dotted namespace topic, e.g.
   *   `"agents.my-agent-id.events"` or `"tasks.task-123.*"`.
   * @returns A {@link Subscription} handle. Consume events with
   *   {@link Subscription.recv} or an `for await` loop.
   *
   * @example
   * ```ts
   * const sub = await client.subscribe('agents.my-agent-id.events');
   * for await (const event of sub) {
   *   console.log(event.event, event.data);
   * }
   * await client.unsubscribe(sub.id);
   * ```
   */
  async subscribe(topic: string): Promise<Subscription> {
    this.ensureInitialized();
    if (!(this.transport instanceof WsTransport)) {
      throw new Error(
        "subscribe() requires transport: 'websocket'. " +
          "Reinitialise the client with transport: 'websocket'.",
      );
    }
    return (this.transport as WsTransport).subscribe(topic);
  }

  /**
   * Cancel a server-side push subscription.
   *
   * @param subscriptionId - The `id` from the {@link Subscription} returned
   *   by {@link subscribe}.
   */
  async unsubscribe(subscriptionId: string): Promise<void> {
    this.ensureInitialized();
    if (!(this.transport instanceof WsTransport)) {
      throw new Error(
        "unsubscribe() requires transport: 'websocket'. " +
          "Reinitialise the client with transport: 'websocket'.",
      );
    }
    return (this.transport as WsTransport).unsubscribe(subscriptionId);
  }

  // ===== DG-awareness helpers =====

  private warnIfNotDg(method: string): void {
    if (!this.isDg && !this.dgWarned) {
      this.dgWarned = true;
      console.warn(
        `[conduit] \`${method}\` is a DataGrout-specific extension. ` +
          `The connected server may not support it. ` +
          `Standard MCP methods (listTools, callTool, …) work on any server.`,
      );
    }
  }

  // ===== DataGrout Extensions =====

  /**
   * Semantically discover tools relevant to a goal or query.
   *
   * Uses DataGrout's vector-search index to find the best-matching tools
   * across all registered integrations. Returns ranked results with scores,
   * descriptions, and schemas.
   *
   * JSON-RPC method: `tools/call` → `data-grout/discovery.discover`
   *
   * @param options.query        - Natural language search query.
   * @param options.goal         - High-level goal description (alternative to `query`).
   * @param options.limit        - Maximum results to return (default: 10).
   * @param options.minScore     - Minimum relevance score (default: 0.0).
   * @param options.integrations - Filter by specific integration names.
   * @param options.servers      - Filter by specific server IDs.
   */
  async discover(options: DiscoverOptions): Promise<DiscoverResult> {
    this.ensureInitialized();
    this.warnIfNotDg("discover");
    const params: Record<string, any> = {
      limit: options.limit ?? 10,
      min_score: options.minScore ?? 0.0,
    };

    if (options.query) params.query = options.query;
    if (options.goal) params.goal = options.goal;
    if (options.integrations) params.integrations = options.integrations;
    if (options.servers) params.servers = options.servers;

    const result = await this.sendWithRetry(() =>
      this.transport.callTool("data-grout/discovery.discover", params),
    );

    const tools = result.results || result.tools || [];
    return {
      queryUsed:
        result.goal_used || result.query_used || result.queryUsed || "",
      results: tools.map((r: any) => ({
        toolName: r.tool_name || r.toolName,
        integration: r.integration,
        serverId: r.server_id || r.serverId || r.server,
        score: r.score,
        distance: r.distance,
        description: r.description,
        sideEffects: r.side_effects || r.sideEffects,
        inputSchema: r.input_contract || r.input_schema || r.inputSchema,
        outputSchema: r.output_contract || r.output_schema || r.outputSchema,
      })),
      total: result.total ?? tools.length,
      limit: result.limit ?? options.limit ?? 10,
    };
  }

  /**
   * Execute a single tool call routed through DataGrout's gateway.
   *
   * The gateway handles credential injection, usage tracking, and receipts.
   * Use `performBatch()` to execute multiple calls in one request.
   *
   * JSON-RPC method: `tools/call` → `data-grout/discovery.perform`
   *
   * @param options.tool     - Fully-qualified tool name.
   * @param options.args     - Tool input arguments.
   * @param options.demux    - When `true`, use semantic demultiplexing.
   * @param options.demuxMode - Demux strictness (`"strict"` | `"fuzzy"`).
   */
  async perform(options: PerformOptions): Promise<any> {
    this.ensureInitialized();
    this.warnIfNotDg("perform");
    return await this.performWithTracking(
      options.tool,
      options.args,
      options.demux
        ? { demux: options.demux, demuxMode: options.demuxMode }
        : undefined,
    );
  }

  /**
   * Execute multiple tool calls in a single gateway request.
   *
   * JSON-RPC method: `tools/call` → `data-grout/discovery.perform`
   *
   * @param calls - Array of `{ tool, args }` call descriptors.
   */
  async performBatch(
    calls: Array<{ tool: string; args: Record<string, any> }>,
  ): Promise<any[]> {
    this.ensureInitialized();
    this.warnIfNotDg("performBatch");
    return this.sendWithRetry(() =>
      this.transport.callTool("data-grout/discovery.perform", calls),
    );
  }

  /**
   * Start or advance a guided workflow session.
   *
   * The first call (with only `goal`) starts a new session and returns the
   * initial options. Subsequent calls provide `sessionId` and `choice` to
   * advance through steps. Returns a `GuidedSession` that exposes helpers
   * for navigating the workflow.
   *
   * JSON-RPC method: `tools/call` → `data-grout/discovery.guide`
   *
   * @param options.goal      - High-level goal to accomplish (first call only).
   * @param options.policy    - Optional policy constraints for tool selection.
   * @param options.sessionId - Resume an existing session (subsequent calls).
   * @param options.choice    - Option ID selected at the current step.
   */
  async guide(options: GuideRequestOptions): Promise<GuidedSession> {
    this.ensureInitialized();
    this.warnIfNotDg("guide");
    const params: Record<string, any> = {};

    if (options.goal) params.goal = options.goal;
    if (options.policy) params.policy = options.policy;
    if (options.sessionId) params.session_id = options.sessionId;
    if (options.choice) params.choice = options.choice;

    const result = await this.sendWithRetry(() =>
      this.transport.callTool("data-grout/discovery.guide", params),
    );

    const state: GuideState = {
      sessionId: result.session_id || result.sessionId,
      step: result.step,
      message: result.message,
      status: result.status,
      options: result.options?.map((o: any) => ({
        id: o.id,
        label: o.label,
        cost: o.cost,
        viable: o.viable,
        metadata: o.metadata,
      })),
      pathTaken: result.path_taken || result.pathTaken,
      totalCost: result.total_cost || result.totalCost,
      result: result.result,
      progress: result.progress,
    };

    return new GuidedSession(this, state);
  }

  /**
   * Generate an execution plan for a goal using DataGrout's planning engine.
   *
   * Returns an ordered list of tool calls that, when executed, accomplish the
   * stated goal. Throws `InvalidConfigError` if neither `goal` nor `query` is
   * provided.
   *
   * JSON-RPC method: `tools/call` → `data-grout/discovery.plan`
   *
   * @param options.goal                - High-level goal description.
   * @param options.query               - Search query to anchor the plan (alternative to `goal`).
   * @param options.server              - Restrict planning to a specific server.
   * @param options.k                   - Maximum number of plan steps.
   * @param options.policy              - Policy constraints for tool selection.
   * @param options.have                - Pre-existing data/context available to the planner.
   * @param options.returnCallHandles   - Include call handles in the response.
   * @param options.exposeVirtualSkills - Include virtual skills in the plan.
   * @param options.modelOverrides      - Override LLM model settings.
   */
  async plan(options: PlanOptions): Promise<any> {
    this.ensureInitialized();
    this.warnIfNotDg("plan");

    if (!options.goal && !options.query) {
      throw new InvalidConfigError("plan() requires either goal or query");
    }

    const params: Record<string, any> = {};

    if (options.goal) params.goal = options.goal;
    if (options.query) params.query = options.query;
    if (options.server) params.server = options.server;
    if (options.k !== undefined) params.k = options.k;
    if (options.policy) params.policy = options.policy;
    if (options.have) params.have = options.have;
    if (options.returnCallHandles !== undefined)
      params.return_call_handles = options.returnCallHandles;
    if (options.exposeVirtualSkills !== undefined)
      params.expose_virtual_skills = options.exposeVirtualSkills;
    if (options.modelOverrides) params.model_overrides = options.modelOverrides;

    return this.sendWithRetry(() =>
      this.transport.callTool("data-grout/discovery.plan", params),
    );
  }

  /**
   * Call any DataGrout first-party tool by its short name.
   *
   * Prepends `data-grout/` to the tool name automatically, so
   * `client.dg('prism.render', { ... })` calls `data-grout/prism.render`.
   *
   * JSON-RPC method: `tools/call` → `data-grout/<toolShortName>`
   *
   * @param toolShortName - Tool name without the `data-grout/` prefix.
   * @param params        - Tool input arguments.
   */
  async dg(
    toolShortName: string,
    params: Record<string, any> = {},
  ): Promise<any> {
    this.ensureInitialized();
    const method = `data-grout/${toolShortName}`;
    return this.sendWithRetry(() => this.transport.callTool(method, params));
  }

  /**
   * Estimate the credit cost of a tool call without executing it.
   *
   * Passes `estimate_only: true` to the tool, which returns a cost breakdown
   * without performing any side effects or charging credits.
   *
   * @param tool - Fully-qualified tool name.
   * @param args - Tool input arguments.
   */
  async estimateCost(tool: string, args: Record<string, any>): Promise<any> {
    this.ensureInitialized();
    const estimateArgs = { ...args, estimate_only: true };
    return this.sendWithRetry(() =>
      this.transport.callTool(tool, estimateArgs),
    );
  }

  // ===== Internal Helpers =====

  private async performWithTracking(
    tool: string,
    args: Record<string, any>,
    options?: any,
  ): Promise<any> {
    const params = { tool, args, ...options };
    return this.sendWithRetry(() =>
      this.transport.callTool("data-grout/discovery.perform", params),
    );
  }
}
