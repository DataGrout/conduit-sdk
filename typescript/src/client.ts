/**
 * DataGrout Conduit client implementation
 */

import { Transport } from './transports/base';
import { MCPTransport } from './transports/mcp';
import { JSONRPCTransport } from './transports/jsonrpc';
import { ConduitIdentity } from './identity';
import type {
  ClientOptions,
  DiscoverResult,
  DiscoverOptions,
  PerformOptions,
  GuideRequestOptions,
  GuideState,
  FlowOptions,
  PrismFocusOptions,
  MCPTool,
  MCPResource,
  MCPPrompt,
} from './types';

/**
 * Stateful guided workflow session
 */
export class GuidedSession {
  private client: Client;
  private state: GuideState;

  constructor(client: Client, state: GuideState) {
    this.client = client;
    this.state = state;
  }

  get sessionId(): string {
    return this.state.sessionId;
  }

  get status(): string {
    return this.state.status;
  }

  get options() {
    return this.state.options || [];
  }

  get result() {
    return this.state.result;
  }

  getState(): GuideState {
    return this.state;
  }

  async choose(optionId: string): Promise<GuidedSession> {
    return await this.client.guide({
      sessionId: this.sessionId,
      choice: optionId,
    });
  }

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
  return url.includes('datagrout.ai') || url.includes('datagrout.dev');
}

/**
 * DataGrout Conduit client - drop-in replacement for MCP clients
 */
export class Client {
  private url: string;
  private auth?: ClientOptions['auth'];
  private useIntelligentInterface: boolean;
  private transport: Transport;
  private readonly isDg: boolean;
  private dgWarned = false;

  constructor(options: ClientOptions | string) {
    // Allow simple string URL or full options object
    if (typeof options === 'string') {
      options = { url: options };
    }

    this.url = options.url;
    this.auth = options.auth;
    this.useIntelligentInterface = options.useIntelligentInterface ?? false;
    this.isDg = isDgUrl(this.url);

    // Resolve identity: explicit > identityAuto flag > DG URL auto-discover.
    // For DG URLs, silently try auto-discovery unless disable_mtls is set.
    let identity =
      options.identity ??
      (options.identityAuto ? ConduitIdentity.tryDefault() ?? undefined : undefined);
    if (identity === undefined && this.isDg && !options.disableMtls) {
      identity = ConduitIdentity.tryDefault() ?? undefined;
    }

    // Initialize transport
    const transportType = options.transport || 'jsonrpc';
    if (transportType === 'mcp') {
      this.transport = new MCPTransport(this.url, this.auth);
    } else {
      this.transport = new JSONRPCTransport(this.url, this.auth, options.timeout, identity);
    }
  }

  async connect(): Promise<void> {
    await this.transport.connect();
  }

  async disconnect(): Promise<void> {
    await this.transport.disconnect();
  }

  // ===== Standard MCP API (Drop-in Compatible) =====

  async listTools(options?: any): Promise<MCPTool[]> {
    const tools = await this.transport.listTools(options);
    if (this.useIntelligentInterface) {
      // Third-party integration tools use the integration@version/tool@version
      // naming scheme. DG's own tools (arbiter_*, governor_*) do not contain "@".
      return tools.filter(t => !t.name.includes('@'));
    }
    return tools;
  }

  async callTool(name: string, args: Record<string, any>, options?: any): Promise<any> {
    return await this.performWithTracking(name, args, options);
  }

  async listResources(options?: any): Promise<MCPResource[]> {
    return await this.transport.listResources(options);
  }

  async readResource(uri: string, options?: any): Promise<any> {
    return await this.transport.readResource(uri, options);
  }

  async listPrompts(options?: any): Promise<MCPPrompt[]> {
    return await this.transport.listPrompts(options);
  }

  async getPrompt(name: string, args?: Record<string, any>, options?: any): Promise<any> {
    return await this.transport.getPrompt(name, args, options);
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

  async discover(options: DiscoverOptions): Promise<DiscoverResult> {
    this.warnIfNotDg('discover');
    const params: Record<string, any> = {
      limit: options.limit ?? 10,
      minScore: options.minScore ?? 0.0,
    };

    if (options.query) params.query = options.query;
    if (options.goal) params.goal = options.goal;
    if (options.integrations) params.integrations = options.integrations;
    if (options.servers) params.servers = options.servers;

    const result = await this.transport.callTool('data-grout/discovery.discover', params);

    return {
      queryUsed: result.query_used || result.queryUsed,
      results: (result.results || []).map((r: any) => ({
        toolName: r.tool_name || r.toolName,
        integration: r.integration,
        serverId: r.server_id || r.serverId,
        score: r.score,
        distance: r.distance,
        description: r.description,
        sideEffects: r.side_effects || r.sideEffects,
        inputSchema: r.input_schema || r.inputSchema,
        outputSchema: r.output_schema || r.outputSchema,
      })),
      total: result.total,
      limit: result.limit,
    };
  }

  async perform(options: PerformOptions): Promise<any> {
    this.warnIfNotDg('perform');
    return await this.performWithTracking(
      options.tool,
      options.args,
      options.demux ? { demux: options.demux, demuxMode: options.demuxMode } : undefined
    );
  }

  async performBatch(calls: Array<{ tool: string; args: Record<string, any> }>): Promise<any[]> {
    this.warnIfNotDg('performBatch');
    return await this.transport.callTool('data-grout/discovery.perform', calls);
  }

  async guide(options: GuideRequestOptions): Promise<GuidedSession> {
    this.warnIfNotDg('guide');
    const params: Record<string, any> = {};

    if (options.goal) params.goal = options.goal;
    if (options.policy) params.policy = options.policy;
    if (options.sessionId) params.session_id = options.sessionId;
    if (options.choice) params.choice = options.choice;

    const result = await this.transport.callTool('data-grout/discovery.guide', params);

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

  async flowInto(options: FlowOptions): Promise<any> {
    this.warnIfNotDg('flowInto');
    const params: Record<string, any> = {
      plan: options.plan,
      validate_ctc: options.validateCtc ?? true,
      save_as_skill: options.saveAsSkill ?? false,
    };

    if (options.inputData) {
      params.input_data = options.inputData;
    }

    return await this.transport.callTool('data-grout/flow.into', params);
  }

  async prismFocus(options: PrismFocusOptions): Promise<any> {
    this.warnIfNotDg('prismFocus');
    const params = {
      data: options.data,
      source_type: options.sourceType,
      target_type: options.targetType,
    };

    return await this.transport.callTool('data-grout/prism.focus', params);
  }

  // ===== Logic Cell Extensions =====

  /**
   * Store facts in the agent's persistent logic cell.
   *
   * Converts natural language to symbolic Prolog facts and stores them
   * durably across sessions.
   *
   * @param statement - Natural language statement to remember
   * @param options.tag - Tag/namespace for grouping facts
   * @param options.facts - Optional pre-structured fact list
   */
  async remember(
    statement: string,
    options?: { tag?: string; facts?: Record<string, any>[] }
  ): Promise<{ handles: string[]; facts: any[]; count: number; message: string }> {
    const params: Record<string, any> = {
      tag: options?.tag ?? 'default',
    };

    if (options?.facts) {
      params.facts = options.facts;
    } else {
      params.statement = statement;
    }

    return await this.transport.callTool('data-grout/logic.remember', params);
  }

  /**
   * Query the agent's logic cell with natural language.
   *
   * Translates question to Prolog patterns and retrieves matching facts.
   * Zero-token retrieval after the NL→pattern translation step.
   *
   * @param question - Natural language question
   * @param options.limit - Maximum results (default: 50)
   * @param options.patterns - Optional pre-built pattern list
   */
  async queryCell(
    question: string,
    options?: { limit?: number; patterns?: Record<string, any>[] }
  ): Promise<{ results: any[]; total: number; description: string; message: string }> {
    const params: Record<string, any> = {
      limit: options?.limit ?? 50,
    };

    if (options?.patterns) {
      params.patterns = options.patterns;
    } else {
      params.question = question;
    }

    return await this.transport.callTool('data-grout/logic.query', params);
  }

  /**
   * Retract facts from the agent's logic cell.
   *
   * @param options.handles - Specific fact handles to retract
   * @param options.pattern - NL pattern — retract all facts mentioning this text
   */
  async forget(
    options: { handles?: string[]; pattern?: string }
  ): Promise<{ retracted: number; handles: string[]; message: string }> {
    const params: Record<string, any> = {};

    if (options.handles) params.handles = options.handles;
    if (options.pattern) params.pattern = options.pattern;

    return await this.transport.callTool('data-grout/logic.forget', params);
  }

  /**
   * Reflect on the agent's logic cell — full snapshot or per-entity view.
   *
   * @param options.entity - Optional entity name to scope reflection
   * @param options.summaryOnly - If true, return only counts
   */
  async reflect(
    options?: { entity?: string; summaryOnly?: boolean }
  ): Promise<{ total: number; summary?: any; entity?: string; facts?: any[]; message: string }> {
    const params: Record<string, any> = {
      summary_only: options?.summaryOnly ?? false,
    };

    if (options?.entity) params.entity = options.entity;

    return await this.transport.callTool('data-grout/logic.reflect', params);
  }

  /**
   * Store a logical rule or policy in the agent's logic cell.
   *
   * @param rule - Natural language rule (e.g. 'VIP customers have ARR > $500K')
   * @param options.tag - Tag/namespace for this constraint
   */
  async constrain(
    rule: string,
    options?: { tag?: string }
  ): Promise<{ handle: string; name: string; rule: string; message: string }> {
    const params: Record<string, any> = {
      rule,
      tag: options?.tag ?? 'constraint',
    };

    return await this.transport.callTool('data-grout/logic.constrain', params);
  }

  async estimateCost(tool: string, args: Record<string, any>): Promise<any> {
    const estimateArgs = { ...args, estimate_only: true };
    return await this.transport.callTool(tool, estimateArgs);
  }

  // ===== Internal Helpers =====

  private async performWithTracking(
    tool: string,
    args: Record<string, any>,
    options?: any
  ): Promise<any> {
    const params = { tool, args, ...options };
    // Receipt is embedded in result["_meta"]["datagrout"]["receipt"] — callers can use
    // extractMeta(result) to access it without any client-side state.
    return await this.transport.callTool('data-grout/discovery.perform', params);
  }

}
