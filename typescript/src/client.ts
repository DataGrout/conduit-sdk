/**
 * DataGrout Conduit client implementation
 */

import * as path from 'path';
import { Transport } from './transports/base';
import { MCPTransport } from './transports/mcp';
import { JSONRPCTransport } from './transports/jsonrpc';
import { ConduitIdentity } from './identity';
import {
  generateKeypair,
  registerIdentity,
  saveIdentity,
  DEFAULT_IDENTITY_DIR,
  DG_SUBSTRATE_ENDPOINT,
} from './registration';
import { NotInitializedError, InvalidConfigError } from './errors';
import type {
  ClientOptions,
  DiscoverResult,
  DiscoverOptions,
  PerformOptions,
  GuideRequestOptions,
  GuideState,
  FlowOptions,
  PrismFocusOptions,
  PlanOptions,
  RefractOptions,
  ChartOptions,
  RememberOptions,
  QueryCellOptions,
  ForgetOptions,
  ConstrainOptions,
  ReflectOptions,
  MCPTool,
  MCPResource,
  MCPPrompt,
} from './types';

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
    if (this.status === 'completed') {
      return this.result;
    }

    throw new Error(
      `Workflow not complete (status: ${this.status}). ` +
        `Call choose() with one of the available options.`
    );
  }
}

/** Returns `true` when `url` points at a DataGrout-managed endpoint. */
export function isDgUrl(url: string): boolean {
  return (
    url.includes('datagrout.ai') ||
    url.includes('datagrout.dev') ||
    !!process.env['CONDUIT_IS_DG']
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
  private auth?: ClientOptions['auth'];
  private useIntelligentInterface: boolean;
  private transport: Transport;
  private readonly isDg: boolean;
  private dgWarned = false;
  private initialized = false;
  private maxRetries: number;

  constructor(options: ClientOptions | string) {
    // Allow simple string URL or full options object
    if (typeof options === 'string') {
      options = { url: options };
    }

    this.url = options.url;
    this.auth = options.auth;
    this.isDg = isDgUrl(this.url);
    this.useIntelligentInterface = options.useIntelligentInterface ?? this.isDg;
    this.maxRetries = options.maxRetries ?? 3;

    // Resolve identity: explicit > identityAuto flag > DG URL auto-discover.
    // For DG URLs, silently try auto-discovery unless disable_mtls is set.
    let identity =
      options.identity ??
      (options.identityAuto
        ? ConduitIdentity.tryDiscover(options.identityDir) ?? undefined
        : undefined);
    if (identity === undefined && this.isDg && !options.disableMtls) {
      identity = ConduitIdentity.tryDiscover(options.identityDir) ?? undefined;
    }

    const transportType = options.transport || 'mcp';
    if (transportType === 'mcp') {
      this.transport = new MCPTransport(this.url, this.auth, identity);
    } else {
      // When the user passes an MCP URL (ending in /mcp), transparently rewrite
      // the path to the DG JSONRPC endpoint (/rpc).
      const rpcUrl = this.url.endsWith('/mcp')
        ? this.url.slice(0, -4) + '/rpc'
        : this.url;
      this.transport = new JSONRPCTransport(rpcUrl, this.auth, options.timeout, identity);
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
    const name = options.name || 'conduit-client';
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
      path.join(dir, 'identity.pem'),
      path.join(dir, 'identity_key.pem'),
      path.join(dir, 'ca.pem')
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
    const { OAuthTokenProvider, deriveTokenEndpoint } = await import('./oauth');
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
          error?.code === -32002 ||
          error?.message?.includes('not initialized');
        if (isNotInit && retries > 0) {
          retries--;
          await this.connect();
          await new Promise(r => setTimeout(r, 500));
          continue;
        }
        throw error;
      }
    }
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
        const tools = Array.isArray(response) ? response : ((response as any).tools || []);
        allTools.push(...tools);
        cursor = Array.isArray(response) ? undefined : (response as any).nextCursor;
      } while (cursor);

      if (this.useIntelligentInterface) {
        return allTools.filter(t => !t.name.includes('@'));
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
  async callTool(name: string, args: Record<string, any>, _options?: any): Promise<any> {
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
  async getPrompt(name: string, args?: Record<string, any>, options?: any): Promise<any> {
    this.ensureInitialized();
    return this.sendWithRetry(() => this.transport.getPrompt(name, args, options));
  }

  // ===== DG-awareness helpers =====

  private warnIfNotDg(method: string): void {
    if (!this.isDg && !this.dgWarned) {
      this.dgWarned = true;
      console.warn(
        `[conduit] \`${method}\` is a DataGrout-specific extension. ` +
        `The connected server may not support it. ` +
        `Standard MCP methods (listTools, callTool, …) work on any server.`
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
    this.warnIfNotDg('discover');
    const params: Record<string, any> = {
      limit: options.limit ?? 10,
      min_score: options.minScore ?? 0.0,
    };

    if (options.query) params.query = options.query;
    if (options.goal) params.goal = options.goal;
    if (options.integrations) params.integrations = options.integrations;
    if (options.servers) params.servers = options.servers;

    const result = await this.sendWithRetry(() =>
      this.transport.callTool('data-grout/discovery.discover', params)
    );

    const tools = result.results || result.tools || [];
    return {
      queryUsed: result.goal_used || result.query_used || result.queryUsed || '',
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
      limit: result.limit ?? (options.limit ?? 10),
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
    this.warnIfNotDg('perform');
    return await this.performWithTracking(
      options.tool,
      options.args,
      options.demux ? { demux: options.demux, demuxMode: options.demuxMode } : undefined
    );
  }

  /**
   * Execute multiple tool calls in a single gateway request.
   *
   * JSON-RPC method: `tools/call` → `data-grout/discovery.perform`
   *
   * @param calls - Array of `{ tool, args }` call descriptors.
   */
  async performBatch(calls: Array<{ tool: string; args: Record<string, any> }>): Promise<any[]> {
    this.ensureInitialized();
    this.warnIfNotDg('performBatch');
    return this.sendWithRetry(() =>
      this.transport.callTool('data-grout/discovery.perform', calls)
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
    this.warnIfNotDg('guide');
    const params: Record<string, any> = {};

    if (options.goal) params.goal = options.goal;
    if (options.policy) params.policy = options.policy;
    if (options.sessionId) params.session_id = options.sessionId;
    if (options.choice) params.choice = options.choice;

    const result = await this.sendWithRetry(() =>
      this.transport.callTool('data-grout/discovery.guide', params)
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
   * Execute a pre-planned sequence of tool calls (a "flow") through the
   * DataGrout gateway.
   *
   * JSON-RPC method: `tools/call` → `data-grout/flow.into`
   *
   * @param options.plan          - Ordered list of tool call descriptors.
   * @param options.validateCtc   - Validate each call against its CTC schema (default: `true`).
   * @param options.saveAsSkill   - Persist the flow as a reusable skill (default: `false`).
   * @param options.inputData     - Runtime input data for the flow.
   */
  async flowInto(options: FlowOptions): Promise<any> {
    this.ensureInitialized();
    this.warnIfNotDg('flowInto');
    const params: Record<string, any> = {
      plan: options.plan,
      validate_ctc: options.validateCtc ?? true,
      save_as_skill: options.saveAsSkill ?? false,
    };

    if (options.inputData) {
      params.input_data = options.inputData;
    }

    return this.sendWithRetry(() =>
      this.transport.callTool('data-grout/flow.into', params)
    );
  }

  /**
   * Transform data from one annotated type to another using the DataGrout
   * Prism semantic mapping engine.
   *
   * JSON-RPC method: `tools/call` → `data-grout/prism.focus`
   *
   * @param options.data               - Source payload to transform.
   * @param options.sourceType         - Semantic type of the source data.
   * @param options.targetType         - Desired semantic type for the output.
   * @param options.sourceAnnotations  - Additional schema hints for the source.
   * @param options.targetAnnotations  - Additional schema hints for the target.
   * @param options.context            - Free-text context to guide the mapping.
   */
  async prismFocus(options: PrismFocusOptions): Promise<any> {
    this.ensureInitialized();
    this.warnIfNotDg('prismFocus');
    const params: Record<string, any> = {
      data: options.data,
      source_type: options.sourceType,
      target_type: options.targetType,
      ...(options.sourceAnnotations && { source_annotations: options.sourceAnnotations }),
      ...(options.targetAnnotations && { target_annotations: options.targetAnnotations }),
      ...(options.context && { context: options.context }),
    };

    return this.sendWithRetry(() =>
      this.transport.callTool('data-grout/prism.focus', params)
    );
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
    this.warnIfNotDg('plan');

    if (!options.goal && !options.query) {
      throw new InvalidConfigError('plan() requires either goal or query');
    }

    const params: Record<string, any> = {};

    if (options.goal) params.goal = options.goal;
    if (options.query) params.query = options.query;
    if (options.server) params.server = options.server;
    if (options.k !== undefined) params.k = options.k;
    if (options.policy) params.policy = options.policy;
    if (options.have) params.have = options.have;
    if (options.returnCallHandles !== undefined) params.return_call_handles = options.returnCallHandles;
    if (options.exposeVirtualSkills !== undefined) params.expose_virtual_skills = options.exposeVirtualSkills;
    if (options.modelOverrides) params.model_overrides = options.modelOverrides;

    return this.sendWithRetry(() =>
      this.transport.callTool('data-grout/discovery.plan', params)
    );
  }

  /**
   * Analyse and summarise a payload using the DataGrout Prism refraction engine.
   *
   * JSON-RPC method: `tools/call` → `data-grout/prism.refract`
   *
   * @param options.goal    - Description of what to extract or summarise.
   * @param options.payload - Input data to analyse (any JSON-serializable value).
   * @param options.verbose - Include detailed processing trace in the response.
   * @param options.chart   - Also generate a chart representation.
   */
  async refract(options: RefractOptions): Promise<any> {
    this.ensureInitialized();
    this.warnIfNotDg('refract');
    const params: Record<string, any> = {
      goal: options.goal,
      payload: options.payload,
    };

    if (options.verbose !== undefined) params.verbose = options.verbose;
    if (options.chart !== undefined) params.chart = options.chart;

    return this.sendWithRetry(() =>
      this.transport.callTool('data-grout/prism.refract', params)
    );
  }

  /**
   * Generate a chart from a data payload using the DataGrout Prism engine.
   *
   * JSON-RPC method: `tools/call` → `data-grout/prism.chart`
   *
   * @param options.goal      - What the chart should visualise.
   * @param options.payload   - Input data (any JSON-serializable value).
   * @param options.format    - Output format (e.g. `"png"`, `"svg"`).
   * @param options.chartType - Chart type (e.g. `"bar"`, `"line"`, `"pie"`).
   * @param options.title     - Chart title.
   * @param options.xLabel    - X-axis label.
   * @param options.yLabel    - Y-axis label.
   * @param options.width     - Chart width in pixels.
   * @param options.height    - Chart height in pixels.
   */
  async chart(options: ChartOptions): Promise<any> {
    this.ensureInitialized();
    this.warnIfNotDg('chart');
    const params: Record<string, any> = {
      goal: options.goal,
      payload: options.payload,
    };

    if (options.format) params.format = options.format;
    if (options.chartType) params.chart_type = options.chartType;
    if (options.title) params.title = options.title;
    if (options.xLabel) params.x_label = options.xLabel;
    if (options.yLabel) params.y_label = options.yLabel;
    if (options.width !== undefined) params.width = options.width;
    if (options.height !== undefined) params.height = options.height;

    return this.sendWithRetry(() =>
      this.transport.callTool('data-grout/prism.chart', params)
    );
  }

  /**
   * Generate a document toward a natural-language goal.
   * Supported formats: markdown, html, pdf, json.
   */
  async render(options: { goal: string; payload?: any; format?: string; sections?: any[]; [k: string]: any }): Promise<any> {
    this.ensureInitialized();
    this.warnIfNotDg('render');
    const { goal, format = 'markdown', payload, sections, ...rest } = options;
    const params: Record<string, any> = { goal, format, ...rest };
    if (payload !== undefined) params.payload = payload;
    if (sections !== undefined) params.sections = sections;
    return this.sendWithRetry(() => this.transport.callTool('data-grout/prism.render', params));
  }

  /**
   * Convert content to another format (no LLM). Supports csv, xlsx, pdf, json, html, markdown, etc.
   */
  async export(options: { content: any; format: string; style?: Record<string, any>; metadata?: Record<string, any>; [k: string]: any }): Promise<any> {
    this.ensureInitialized();
    this.warnIfNotDg('export');
    const { content, format, ...rest } = options;
    const params: Record<string, any> = { content, format, ...rest };
    return this.sendWithRetry(() => this.transport.callTool('data-grout/prism.export', params));
  }

  /**
   * Pause workflow for human approval. Use for destructive or policy-gated actions.
   */
  async requestApproval(options: { action: string; details?: Record<string, any>; reason?: string; context?: Record<string, any>; [k: string]: any }): Promise<any> {
    this.ensureInitialized();
    this.warnIfNotDg('requestApproval');
    const { action, details, reason, context, ...rest } = options;
    const params: Record<string, any> = { action, ...rest };
    if (details !== undefined) params.details = details;
    if (reason !== undefined) params.reason = reason;
    if (context !== undefined) params.context = context;
    return this.sendWithRetry(() => this.transport.callTool('data-grout/flow.request-approval', params));
  }

  /**
   * Request user clarification for missing fields. Pauses until user provides values.
   */
  async requestFeedback(options: { missing_fields: string[]; reason: string; current_data?: Record<string, any>; suggestions?: Record<string, any>; context?: Record<string, any>; [k: string]: any }): Promise<any> {
    this.ensureInitialized();
    this.warnIfNotDg('requestFeedback');
    const { missing_fields, reason, ...rest } = options;
    const params: Record<string, any> = { missing_fields, reason, ...rest };
    return this.sendWithRetry(() => this.transport.callTool('data-grout/flow.request-feedback', params));
  }

  /**
   * List recent tool executions for the current server.
   */
  async executionHistory(options: { limit?: number; offset?: number; status?: string; refractions_only?: boolean; [k: string]: any } = {}): Promise<any> {
    this.ensureInitialized();
    this.warnIfNotDg('executionHistory');
    const params: Record<string, any> = { limit: options.limit ?? 50, offset: options.offset ?? 0, refractions_only: options.refractions_only ?? false, ...options };
    if (options.status !== undefined) params.status = options.status;
    return this.sendWithRetry(() => this.transport.callTool('data-grout/inspect.execution-history', params));
  }

  /**
   * Get details and transcript for a specific execution.
   */
  async executionDetails(executionId: string): Promise<any> {
    this.ensureInitialized();
    this.warnIfNotDg('executionDetails');
    return this.sendWithRetry(() => this.transport.callTool('data-grout/inspect.execution-details', { execution_id: executionId }));
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
  async dg(toolShortName: string, params: Record<string, any> = {}): Promise<any> {
    this.ensureInitialized();
    const method = `data-grout/${toolShortName}`;
    return this.sendWithRetry(() => this.transport.callTool(method, params));
  }

  // ===== Logic Cell Extensions =====

  /**
   * Store facts in the agent's persistent logic cell.
   *
   * Converts natural language to symbolic facts and stores them
   * durably across sessions. Accepts either a natural language `statement`
   * (positional or via options) or a pre-structured `facts` array.
   *
   * Throws `InvalidConfigError` if neither `statement` nor `facts` is provided.
   *
   * JSON-RPC method: `tools/call` → `data-grout/logic.remember`
   *
   * @param statement - Natural language statement to remember.
   * @param options.tag   - Tag/namespace for grouping facts (default: `"default"`).
   * @param options.facts - Optional pre-structured fact list (skips NL conversion).
   */
  async remember(statement: string, options?: RememberOptions): Promise<{ handles: string[]; facts: any[]; count: number; message: string }>;
  /**
   * Store facts in the agent's persistent logic cell using an options object.
   *
   * Throws `InvalidConfigError` if neither `statement` nor `facts` is provided.
   *
   * JSON-RPC method: `tools/call` → `data-grout/logic.remember`
   */
  async remember(options: RememberOptions): Promise<{ handles: string[]; facts: any[]; count: number; message: string }>;
  async remember(
    statementOrOptions: string | RememberOptions,
    optionsArg?: RememberOptions
  ): Promise<{ handles: string[]; facts: any[]; count: number; message: string }> {
    this.ensureInitialized();

    let statement: string | undefined;
    let opts: RememberOptions | undefined;

    if (typeof statementOrOptions === 'string') {
      statement = statementOrOptions;
      opts = optionsArg;
    } else {
      opts = statementOrOptions;
      statement = opts.statement;
    }

    if (!statement && !opts?.facts?.length) {
      throw new InvalidConfigError('remember() requires either a statement or facts');
    }

    const params: Record<string, any> = {
      tag: opts?.tag ?? 'default',
    };

    if (opts?.facts) {
      params.facts = opts.facts;
    } else {
      params.statement = statement;
    }

    return this.sendWithRetry(() =>
      this.transport.callTool('data-grout/logic.remember', params)
    );
  }

  /**
   * Query the agent's logic cell with a natural language question.
   *
   * Translates the question to query patterns and retrieves matching facts.
   * Accepts either a natural language `question` (positional or via options)
   * or a pre-built `patterns` array.
   *
   * Throws `InvalidConfigError` if neither `question` nor `patterns` is provided.
   *
   * JSON-RPC method: `tools/call` → `data-grout/logic.query`
   *
   * @param question       - Natural language question.
   * @param options.limit  - Maximum results to return (default: 50).
   * @param options.patterns - Optional pre-built pattern list (skips NL translation).
   */
  async queryCell(question: string, options?: QueryCellOptions): Promise<{ results: any[]; total: number; description: string; message: string }>;
  /**
   * Query the agent's logic cell using an options object.
   *
   * Throws `InvalidConfigError` if neither `question` nor `patterns` is provided.
   *
   * JSON-RPC method: `tools/call` → `data-grout/logic.query`
   */
  async queryCell(options: QueryCellOptions): Promise<{ results: any[]; total: number; description: string; message: string }>;
  async queryCell(
    questionOrOptions: string | QueryCellOptions,
    optionsArg?: QueryCellOptions
  ): Promise<{ results: any[]; total: number; description: string; message: string }> {
    this.ensureInitialized();

    let question: string | undefined;
    let opts: QueryCellOptions | undefined;

    if (typeof questionOrOptions === 'string') {
      question = questionOrOptions;
      opts = optionsArg;
    } else {
      opts = questionOrOptions;
      question = opts.question;
    }

    if (!question && !opts?.patterns?.length) {
      throw new InvalidConfigError('queryCell() requires either a question or patterns');
    }

    const params: Record<string, any> = {
      limit: opts?.limit ?? 50,
    };

    if (opts?.patterns) {
      params.patterns = opts.patterns;
    } else {
      params.question = question;
    }

    return this.sendWithRetry(() =>
      this.transport.callTool('data-grout/logic.query', params)
    );
  }

  /**
   * Retract facts from the agent's logic cell.
   *
   * Throws `InvalidConfigError` if neither `handles` nor `pattern` is provided.
   *
   * JSON-RPC method: `tools/call` → `data-grout/logic.forget`
   *
   * @param options.handles - Specific fact handles to retract.
   * @param options.pattern - Natural language pattern — retract all matching facts.
   */
  async forget(
    options: ForgetOptions
  ): Promise<{ retracted: number; handles: string[]; message: string }> {
    this.ensureInitialized();

    if (!options.handles?.length && !options.pattern) {
      throw new InvalidConfigError('forget() requires either handles or pattern');
    }

    const params: Record<string, any> = {};

    if (options.handles) params.handles = options.handles;
    if (options.pattern) params.pattern = options.pattern;

    return this.sendWithRetry(() =>
      this.transport.callTool('data-grout/logic.forget', params)
    );
  }

  /**
   * Reflect on the agent's logic cell — returns a full snapshot or a
   * per-entity view of all stored facts.
   *
   * JSON-RPC method: `tools/call` → `data-grout/logic.reflect`
   *
   * @param options.entity      - Optional entity name to scope reflection.
   * @param options.summaryOnly - When `true`, return only counts (default: `false`).
   */
  async reflect(
    options?: ReflectOptions
  ): Promise<{ total: number; summary?: any; entity?: string; facts?: any[]; message: string }> {
    this.ensureInitialized();
    const params: Record<string, any> = {
      summary_only: options?.summaryOnly ?? false,
    };

    if (options?.entity) params.entity = options.entity;

    return this.sendWithRetry(() =>
      this.transport.callTool('data-grout/logic.reflect', params)
    );
  }

  /**
   * Store a logical rule or policy in the agent's logic cell.
   *
   * Rules are permanent constraints evaluated during `queryCell()` calls.
   *
   * JSON-RPC method: `tools/call` → `data-grout/logic.constrain`
   *
   * @param rule         - Natural language rule (e.g. `"VIP customers have ARR > $500K"`).
   * @param options.tag  - Tag/namespace for this constraint (default: `"constraint"`).
   */
  async constrain(
    rule: string,
    options?: ConstrainOptions
  ): Promise<{ handle: string; name: string; rule: string; message: string }> {
    this.ensureInitialized();
    const params: Record<string, any> = {
      rule,
      tag: options?.tag ?? 'constraint',
    };

    return this.sendWithRetry(() =>
      this.transport.callTool('data-grout/logic.constrain', params)
    );
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
      this.transport.callTool(tool, estimateArgs)
    );
  }

  // ===== Internal Helpers =====

  private async performWithTracking(
    tool: string,
    args: Record<string, any>,
    options?: any
  ): Promise<any> {
    const params = { tool, args, ...options };
    return this.sendWithRetry(() =>
      this.transport.callTool('data-grout/discovery.perform', params)
    );
  }

}
