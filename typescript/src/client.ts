/**
 * DataGrout Conduit client implementation
 */

import { Transport } from './transports/base';
import { MCPTransport } from './transports/mcp';
import { JSONRPCTransport } from './transports/jsonrpc';
import type {
  ClientOptions,
  Receipt,
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

/**
 * DataGrout Conduit client - drop-in replacement for MCP clients
 */
export class Client {
  private url: string;
  private auth?: ClientOptions['auth'];
  private hide3rdPartyTools: boolean;
  private transport: Transport;
  private lastReceipt?: Receipt;

  constructor(options: ClientOptions | string) {
    // Allow simple string URL or full options object
    if (typeof options === 'string') {
      options = { url: options };
    }

    this.url = options.url;
    this.auth = options.auth;
    this.hide3rdPartyTools = options.hide3rdPartyTools ?? true;

    // Initialize transport
    const transportType = options.transport || 'jsonrpc';
    if (transportType === 'mcp') {
      this.transport = new MCPTransport(this.url, this.auth);
    } else {
      this.transport = new JSONRPCTransport(this.url, this.auth, options.timeout);
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
    if (this.hide3rdPartyTools) {
      return this.getDatagroutTools();
    }
    return await this.transport.listTools(options);
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

  // ===== DataGrout Extensions =====

  async discover(options: DiscoverOptions): Promise<DiscoverResult> {
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
    return await this.performWithTracking(
      options.tool,
      options.args,
      options.demux ? { demux: options.demux, demuxMode: options.demuxMode } : undefined
    );
  }

  async performBatch(calls: Array<{ tool: string; args: Record<string, any> }>): Promise<any[]> {
    const result = await this.transport.callTool('data-grout/discovery.perform', calls);

    // Extract receipts if present
    if (Array.isArray(result)) {
      for (const item of result) {
        if (item && typeof item === 'object' && '_receipt' in item) {
          this.lastReceipt = this.normalizeReceipt(item._receipt);
        }
      }
    }

    return result;
  }

  async guide(options: GuideRequestOptions): Promise<GuidedSession> {
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
    const params: Record<string, any> = {
      plan: options.plan,
      validate_ctc: options.validateCtc ?? true,
      save_as_skill: options.saveAsSkill ?? false,
    };

    if (options.inputData) {
      params.input_data = options.inputData;
    }

    const result = await this.transport.callTool('data-grout/flow.into', params);

    // Extract receipt
    if (result && typeof result === 'object' && '_receipt' in result) {
      this.lastReceipt = this.normalizeReceipt(result._receipt);
    }

    return result;
  }

  async prismFocus(options: PrismFocusOptions): Promise<any> {
    const params = {
      data: options.data,
      source_type: options.sourceType,
      target_type: options.targetType,
    };

    return await this.transport.callTool('data-grout/prism.focus', params);
  }

  // ===== Receipt & Credit Management =====

  getLastReceipt(): Receipt | undefined {
    return this.lastReceipt;
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

    const result = await this.transport.callTool('data-grout/discovery.perform', params);

    // Extract receipt
    if (result && typeof result === 'object') {
      if ('_receipt' in result) {
        this.lastReceipt = this.normalizeReceipt(result._receipt);
        const { _receipt, ...cleanResult } = result;
        return cleanResult;
      }
      if ('structured_content' in result && result.structured_content?._receipt) {
        this.lastReceipt = this.normalizeReceipt(result.structured_content._receipt);
        return result.structured_content.result ?? result;
      }
    }

    return result;
  }

  private normalizeReceipt(receipt: any): Receipt {
    return {
      receiptId: receipt.receipt_id || receipt.receiptId,
      estimatedCredits: receipt.estimated_credits || receipt.estimatedCredits,
      actualCredits: receipt.actual_credits || receipt.actualCredits,
      netCredits: receipt.net_credits || receipt.netCredits,
      savings: receipt.savings,
      savingsBonus: receipt.savings_bonus || receipt.savingsBonus,
      breakdown: receipt.breakdown,
      byok: receipt.byok,
    };
  }

  private getDatagroutTools(): MCPTool[] {
    return [
      {
        name: 'data-grout/discovery.discover',
        description: 'Semantic tool discovery with natural language queries',
        inputSchema: {
          type: 'object',
          properties: {
            query: { type: 'string' },
            goal: { type: 'string' },
            limit: { type: 'integer', default: 10 },
          },
        },
      },
      {
        name: 'data-grout/discovery.perform',
        description: 'Direct tool execution with credit tracking',
        inputSchema: {
          type: 'object',
          properties: {
            tool: { type: 'string' },
            args: { type: 'object' },
            demux: { type: 'boolean', default: false },
          },
          required: ['tool', 'args'],
        },
      },
      {
        name: 'data-grout/discovery.guide',
        description: 'Guided workflow navigation (MUD-style)',
        inputSchema: {
          type: 'object',
          properties: {
            goal: { type: 'string' },
            policy: { type: 'object' },
            session_id: { type: 'string' },
            choice: { type: 'string' },
          },
        },
      },
      {
        name: 'data-grout/flow.into',
        description: 'Multi-step workflow orchestration with CTCs',
        inputSchema: {
          type: 'object',
          properties: {
            plan: { type: 'array' },
            validate_ctc: { type: 'boolean', default: true },
            save_as_skill: { type: 'boolean', default: false },
          },
          required: ['plan'],
        },
      },
      {
        name: 'data-grout/prism.focus',
        description: 'Semantic type transformation',
        inputSchema: {
          type: 'object',
          properties: {
            data: { type: 'object' },
            source_type: { type: 'string' },
            target_type: { type: 'string' },
          },
          required: ['data', 'source_type', 'target_type'],
        },
      },
    ];
  }
}
