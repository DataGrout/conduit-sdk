/**
 * Tests for DataGrout Conduit client
 */

import { describe, it, expect, vi, beforeEach } from 'vitest';
import { Client } from '../src/client';
import { extractMeta } from '../src/types';
import { RateLimitError, unwrapContent } from '../src/transports/jsonrpc';

// ─── Real DG _datagrout receipt fixture (matches gateway output) ─────────────

const RECEIPT_META = {
  _datagrout: {
    receipt: {
      receipt_id: 'rcp_123',
      timestamp: '2026-02-13T00:00:00Z',
      estimated_credits: 5.0,
      actual_credits: 4.5,
      net_credits: 4.5,
      savings: 0.5,
      savings_bonus: 0.0,
      breakdown: { base: 4.5 },
      byok: { enabled: false, discount_applied: 0.0, discount_rate: 0.0 },
      balance_before: 1000.0,
      balance_after: 995.5,
    },
    credit_estimate: {
      estimated_total: 5.0,
      actual_total: 4.5,
      net_total: 4.5,
      breakdown: { base: 4.5 },
    },
  },
};

/** Helper: create a mock transport and mark the client as initialized. */
function injectMockTransport(client: Client, overrides: Record<string, any> = {}) {
  const mockTransport = {
    connect: vi.fn().mockResolvedValue(undefined),
    disconnect: vi.fn().mockResolvedValue(undefined),
    listTools: vi.fn().mockResolvedValue([]),
    callTool: vi.fn().mockResolvedValue({}),
    listResources: vi.fn().mockResolvedValue([]),
    readResource: vi.fn().mockResolvedValue({}),
    listPrompts: vi.fn().mockResolvedValue([]),
    getPrompt: vi.fn().mockResolvedValue({}),
    ...overrides,
  };
  // @ts-ignore
  client.transport = mockTransport;
  // @ts-ignore
  client.initialized = true;
  return mockTransport;
}

// ─── Client initialisation ────────────────────────────────────────────────────

describe('Client', () => {
  it('should initialize with URL string', () => {
    const client = new Client('https://gateway.datagrout.ai/servers/test/mcp');
    expect(client).toBeDefined();
  });

  it('should initialize with options object using useIntelligentInterface', () => {
    const client = new Client({
      url: 'https://gateway.datagrout.ai/servers/test/mcp',
      useIntelligentInterface: true,
    });
    expect(client).toBeDefined();
  });

  it('default useIntelligentInterface is true for DG URLs', () => {
    const client = new Client('https://gateway.datagrout.ai/servers/test/mcp');
    // @ts-ignore - accessing private property for testing
    expect(client.useIntelligentInterface).toBe(true);
  });

  it('default useIntelligentInterface is false for non-DG URLs', () => {
    const client = new Client('https://my-mcp-server.example.com/mcp');
    // @ts-ignore - accessing private property for testing
    expect(client.useIntelligentInterface).toBe(false);
  });

  it('should detect DG URL correctly', () => {
    const dgClient = new Client('https://gateway.datagrout.ai/servers/test/mcp');
    // @ts-ignore
    expect(dgClient.isDg).toBe(true);

    const otherClient = new Client('https://my-mcp-server.example.com/mcp');
    // @ts-ignore
    expect(otherClient.isDg).toBe(false);
  });

  // ─── ensureInitialized ────────────────────────────────────────────────────────

  it('should throw before connect() is called', async () => {
    const client = new Client('https://gateway.datagrout.ai/servers/test/mcp');
    // @ts-ignore
    client.transport = {
      connect: vi.fn().mockResolvedValue(undefined),
      disconnect: vi.fn().mockResolvedValue(undefined),
      listTools: vi.fn().mockResolvedValue([]),
      callTool: vi.fn().mockResolvedValue({}),
      listResources: vi.fn().mockResolvedValue([]),
      readResource: vi.fn().mockResolvedValue({}),
      listPrompts: vi.fn().mockResolvedValue([]),
      getPrompt: vi.fn().mockResolvedValue({}),
    };

    await expect(client.listTools()).rejects.toThrow('Client not initialized');
    await expect(client.callTool('t', {})).rejects.toThrow('Client not initialized');
    await expect(client.listResources()).rejects.toThrow('Client not initialized');
    await expect(client.readResource('u')).rejects.toThrow('Client not initialized');
    await expect(client.listPrompts()).rejects.toThrow('Client not initialized');
    await expect(client.getPrompt('p')).rejects.toThrow('Client not initialized');
  });

  it('should not throw after connect() is called', async () => {
    const client = new Client('https://gateway.datagrout.ai/servers/test/mcp');
    injectMockTransport(client);

    await expect(client.listTools()).resolves.not.toThrow();
  });

  it('should throw again after disconnect()', async () => {
    const client = new Client('https://gateway.datagrout.ai/servers/test/mcp');
    const mock = injectMockTransport(client);

    await client.disconnect();
    await expect(client.listTools()).rejects.toThrow('Client not initialized');
  });

  // ─── sendWithRetry ────────────────────────────────────────────────────────────

  it('should retry on not-initialized error (-32002)', async () => {
    const client = new Client('https://gateway.datagrout.ai/servers/test/mcp');

    let callCount = 0;
    const mockTransport = {
      connect: vi.fn().mockResolvedValue(undefined),
      disconnect: vi.fn().mockResolvedValue(undefined),
      listTools: vi.fn().mockImplementation(async () => {
        callCount++;
        if (callCount === 1) {
          const err: any = new Error('not initialized');
          err.code = -32002;
          throw err;
        }
        return [{ name: 'tool_a' }];
      }),
      callTool: vi.fn().mockResolvedValue({}),
      listResources: vi.fn().mockResolvedValue([]),
      readResource: vi.fn().mockResolvedValue({}),
      listPrompts: vi.fn().mockResolvedValue([]),
      getPrompt: vi.fn().mockResolvedValue({}),
    };
    // @ts-ignore
    client.transport = mockTransport;
    // @ts-ignore
    client.initialized = true;

    const tools = await client.listTools();
    expect(tools).toEqual([{ name: 'tool_a' }]);
    expect(mockTransport.connect).toHaveBeenCalledTimes(1);
    expect(callCount).toBe(2);
  });

  it('should retry on "not initialized" message string', async () => {
    const client = new Client('https://gateway.datagrout.ai/servers/test/mcp');

    let callCount = 0;
    const mockTransport = {
      connect: vi.fn().mockResolvedValue(undefined),
      disconnect: vi.fn().mockResolvedValue(undefined),
      callTool: vi.fn().mockImplementation(async () => {
        callCount++;
        if (callCount === 1) {
          throw new Error('Server session not initialized');
        }
        return { success: true };
      }),
      listTools: vi.fn().mockResolvedValue([]),
      listResources: vi.fn().mockResolvedValue([]),
      readResource: vi.fn().mockResolvedValue({}),
      listPrompts: vi.fn().mockResolvedValue([]),
      getPrompt: vi.fn().mockResolvedValue({}),
    };
    // @ts-ignore
    client.transport = mockTransport;
    // @ts-ignore
    client.initialized = true;

    const result = await client.callTool('test', {});
    expect(result).toEqual({ success: true });
    expect(callCount).toBe(2);
  });

  it('should not retry on unrelated errors', async () => {
    const client = new Client('https://gateway.datagrout.ai/servers/test/mcp');
    const mockTransport = {
      connect: vi.fn().mockResolvedValue(undefined),
      disconnect: vi.fn().mockResolvedValue(undefined),
      callTool: vi.fn().mockRejectedValue(new Error('Network error')),
      listTools: vi.fn().mockResolvedValue([]),
      listResources: vi.fn().mockResolvedValue([]),
      readResource: vi.fn().mockResolvedValue({}),
      listPrompts: vi.fn().mockResolvedValue([]),
      getPrompt: vi.fn().mockResolvedValue({}),
    };
    // @ts-ignore
    client.transport = mockTransport;
    // @ts-ignore
    client.initialized = true;

    await expect(client.callTool('test', {})).rejects.toThrow('Network error');
    expect(mockTransport.connect).not.toHaveBeenCalled();
  });

  // ─── bootstrapIdentity ────────────────────────────────────────────────────────

  it('should bootstrap with existing valid identity', async () => {
    const { ConduitIdentity } = await import('../src/identity');

    const mockIdentity = {
      certPem: '-----BEGIN CERTIFICATE-----\ntest\n-----END CERTIFICATE-----',
      keyPem: '-----BEGIN PRIVATE KEY-----\ntest\n-----END PRIVATE KEY-----',
      needsRotation: vi.fn().mockReturnValue(false),
    };

    vi.spyOn(ConduitIdentity, 'tryDiscover').mockReturnValue(mockIdentity as any);

    const mockTransport = {
      connect: vi.fn().mockResolvedValue(undefined),
      disconnect: vi.fn().mockResolvedValue(undefined),
      listTools: vi.fn().mockResolvedValue([]),
      callTool: vi.fn().mockResolvedValue({}),
      listResources: vi.fn().mockResolvedValue([]),
      readResource: vi.fn().mockResolvedValue({}),
      listPrompts: vi.fn().mockResolvedValue([]),
      getPrompt: vi.fn().mockResolvedValue({}),
    };

    const { MCPTransport } = await import('../src/transports/mcp');
    vi.spyOn(MCPTransport.prototype, 'connect').mockResolvedValue(undefined);

    const client = await Client.bootstrapIdentity({
      url: 'https://gateway.datagrout.ai/servers/test/mcp',
      authToken: 'test-token',
    });

    expect(client).toBeDefined();
    expect(mockIdentity.needsRotation).toHaveBeenCalledWith(7);

    vi.restoreAllMocks();
  });

  // ─── listTools — intelligent interface filter ────────────────────────────────

  it('should return all tools when useIntelligentInterface=false', async () => {
    const client = new Client({
      url: 'https://gateway.datagrout.ai/servers/test/mcp',
      useIntelligentInterface: false,
    });
    injectMockTransport(client, {
      listTools: vi.fn().mockResolvedValue([
        { name: 'salesforce@v1/get_lead@v1', description: 'Integration tool' },
        { name: 'arbiter_check_policy', description: 'DG tool' },
      ]),
    });

    const tools = await client.listTools();
    const names = tools.map((t) => t.name);
    expect(names).toContain('salesforce@v1/get_lead@v1');
    expect(names).toContain('arbiter_check_policy');
  });

  it('should filter out integration tools when useIntelligentInterface=true', async () => {
    const client = new Client({
      url: 'https://gateway.datagrout.ai/servers/test/mcp',
      useIntelligentInterface: true,
    });
    injectMockTransport(client, {
      listTools: vi.fn().mockResolvedValue([
        { name: 'salesforce@v1/get_lead@v1', description: 'Integration tool' },
        { name: 'arbiter_check_policy', description: 'DG tool' },
        { name: 'governor_enable', description: 'DG tool' },
        { name: 'hubspot@v1/create_contact@v1', description: 'Integration tool' },
      ]),
    });

    const tools = await client.listTools();
    const names = tools.map((t) => t.name);
    expect(names).not.toContain('salesforce@v1/get_lead@v1');
    expect(names).not.toContain('hubspot@v1/create_contact@v1');
    expect(names).toContain('arbiter_check_policy');
    expect(names).toContain('governor_enable');
  });

  // ─── callTool uses transport directly ────────────────────────────────────────

  it('should route callTool directly through the transport', async () => {
    const client = new Client('https://gateway.datagrout.ai/servers/test/mcp');
    const mock = injectMockTransport(client, {
      callTool: vi.fn().mockResolvedValue({ success: true }),
    });

    await client.callTool('test-tool', { arg: 'value' });

    expect(mock.callTool).toHaveBeenCalledWith('test-tool', { arg: 'value' });
  });

  // ─── perform() still routes through discovery.perform ──────────────────────

  it('should route perform() through discovery.perform', async () => {
    const client = new Client('https://gateway.datagrout.ai/servers/test/mcp');
    const mock = injectMockTransport(client, {
      callTool: vi.fn().mockResolvedValue({ success: true }),
    });

    await client.perform({ tool: 'test-tool', args: { arg: 'value' } });

    expect(mock.callTool).toHaveBeenCalledWith(
      'data-grout/discovery.perform',
      expect.objectContaining({ tool: 'test-tool', args: { arg: 'value' } })
    );
  });

  // ─── Receipt via extractMeta ──────────────────────────────────────────────

  it('should parse receipt from _datagrout block using extractMeta', async () => {
    const client = new Client('https://gateway.datagrout.ai/servers/test/mcp');
    injectMockTransport(client, {
      callTool: vi.fn().mockResolvedValue({ result: 'success', ...RECEIPT_META }),
    });

    const result = await client.perform({ tool: 'test-tool', args: {} });
    const meta = extractMeta(result);

    expect(meta).toBeDefined();
    expect(meta!.receipt.receiptId).toBe('rcp_123');
    expect(meta!.receipt.actualCredits).toBe(4.5);
    expect(meta!.receipt.netCredits).toBe(4.5);
    expect(meta!.receipt.balanceBefore).toBe(1000.0);
    expect(meta!.receipt.balanceAfter).toBe(995.5);
  });

  it('should parse credit estimate from _datagrout block using extractMeta', async () => {
    const client = new Client('https://gateway.datagrout.ai/servers/test/mcp');
    injectMockTransport(client, {
      callTool: vi.fn().mockResolvedValue({ result: 'success', ...RECEIPT_META }),
    });

    const result = await client.perform({ tool: 'test-tool', args: {} });
    const meta = extractMeta(result);

    expect(meta?.creditEstimate).toBeDefined();
    expect(meta!.creditEstimate!.estimatedTotal).toBe(5.0);
    expect(meta!.creditEstimate!.netTotal).toBe(4.5);
  });

  it('extractMeta returns null when no _datagrout/_meta in result', () => {
    const consoleSpy = vi.spyOn(console, 'warn').mockImplementation(() => {});
    expect(extractMeta({ result: 'ok' })).toBeNull();
    expect(extractMeta({})).toBeNull();
    expect(extractMeta(null as any)).toBeNull();
    consoleSpy.mockRestore();
  });

  // ─── extractMeta: rich _meta.datagrout format ────────────────────────────────

  it('extractMeta parses rich _meta.datagrout format', () => {
    const result = {
      _meta: {
        datagrout: {
          receipt: {
            receipt_id: 'rcp_rich',
            timestamp: '2026-03-19T00:00:00Z',
            estimated_credits: 10,
            actual_credits: 8,
            net_credits: 8,
            savings: 2,
            savings_bonus: 0.5,
            balance_before: 500,
            balance_after: 492,
            breakdown: { base: 6, premium: 2 },
            byok: { enabled: true, discount_applied: 1, discount_rate: 0.1 },
          },
          credit_estimate: {
            estimated_total: 10,
            actual_total: 8,
            net_total: 8,
            breakdown: { base: 6, premium: 2 },
          },
        },
      },
    };

    const meta = extractMeta(result);
    expect(meta).not.toBeNull();
    expect(meta!.receipt.receiptId).toBe('rcp_rich');
    expect(meta!.receipt.actualCredits).toBe(8);
    expect(meta!.receipt.savings).toBe(2);
    expect(meta!.receipt.savingsBonus).toBe(0.5);
    expect(meta!.receipt.byok.enabled).toBe(true);
    expect(meta!.receipt.byok.discountRate).toBe(0.1);
    expect(meta!.creditEstimate).toBeDefined();
    expect(meta!.creditEstimate!.estimatedTotal).toBe(10);
  });

  // ─── extractMeta: compact _dg format ─────────────────────────────────────────

  it('extractMeta synthesizes from compact _dg format', () => {
    const result = {
      _dg: {
        credits: {
          estimated: 5,
          charged: 4,
          remaining: 96,
          premium: 1.5,
          llm: 2.5,
        },
      },
    };

    const meta = extractMeta(result);
    expect(meta).not.toBeNull();
    expect(meta!.receipt.receiptId).toBe('');
    expect(meta!.receipt.estimatedCredits).toBe(5);
    expect(meta!.receipt.actualCredits).toBe(4);
    expect(meta!.receipt.netCredits).toBe(4);
    expect(meta!.receipt.balanceAfter).toBe(96);
    expect(meta!.receipt.breakdown).toEqual({ premium: 1.5, llm: 2.5 });
    expect(meta!.receipt.byok.enabled).toBe(false);
    expect(meta!.creditEstimate).toBeUndefined();
  });

  it('extractMeta handles _dg with minimal credits', () => {
    const result = {
      _dg: { credits: { charged: 2 } },
    };

    const meta = extractMeta(result);
    expect(meta).not.toBeNull();
    expect(meta!.receipt.estimatedCredits).toBe(0);
    expect(meta!.receipt.actualCredits).toBe(2);
    expect(meta!.receipt.breakdown).toEqual({});
  });

  it('extractMeta handles _dg with empty credits object', () => {
    const result = { _dg: {} };

    const meta = extractMeta(result);
    expect(meta).not.toBeNull();
    expect(meta!.receipt.estimatedCredits).toBe(0);
    expect(meta!.receipt.actualCredits).toBe(0);
  });

  // ─── extractMeta: console.warn on missing metadata ──────────────────────────

  it('extractMeta warns when no metadata found', () => {
    const consoleSpy = vi.spyOn(console, 'warn').mockImplementation(() => {});

    extractMeta({ result: 'no-meta' });

    expect(consoleSpy).toHaveBeenCalledTimes(1);
    expect(consoleSpy.mock.calls[0][0]).toMatch(/No DataGrout metadata found/);
    expect(consoleSpy.mock.calls[0][0]).toMatch(/Include DG Inline/);

    consoleSpy.mockRestore();
  });

  // ─── extractMeta: priority order ─────────────────────────────────────────────

  it('extractMeta prefers _meta.datagrout over _datagrout', () => {
    const result = {
      _meta: {
        datagrout: {
          receipt: {
            receipt_id: 'rcp_rich',
            timestamp: 'T1',
            estimated_credits: 10,
            actual_credits: 10,
            net_credits: 10,
            savings: 0,
            savings_bonus: 0,
            breakdown: {},
            byok: {},
          },
        },
      },
      _datagrout: {
        receipt: {
          receipt_id: 'rcp_legacy',
          timestamp: 'T2',
          estimated_credits: 5,
          actual_credits: 5,
          net_credits: 5,
          savings: 0,
          savings_bonus: 0,
          breakdown: {},
          byok: {},
        },
      },
    };

    const meta = extractMeta(result);
    expect(meta!.receipt.receiptId).toBe('rcp_rich');
  });

  it('extractMeta prefers _datagrout over _dg', () => {
    const result = {
      _datagrout: {
        receipt: {
          receipt_id: 'rcp_legacy',
          timestamp: 'T1',
          estimated_credits: 5,
          actual_credits: 5,
          net_credits: 5,
          savings: 0,
          savings_bonus: 0,
          breakdown: {},
          byok: {},
        },
      },
      _dg: { credits: { charged: 1 } },
    };

    const meta = extractMeta(result);
    expect(meta!.receipt.receiptId).toBe('rcp_legacy');
    expect(meta!.receipt.actualCredits).toBe(5);
  });

  it('extractMeta falls through to _dg when rich and legacy are absent', () => {
    const result = {
      _dg: { credits: { charged: 3, remaining: 97 } },
    };

    const meta = extractMeta(result);
    expect(meta!.receipt.actualCredits).toBe(3);
    expect(meta!.receipt.balanceAfter).toBe(97);
  });

  // ─── Discover ────────────────────────────────────────────────────────────────

  it('should handle discover results', async () => {
    const client = new Client('https://gateway.datagrout.ai/servers/test/mcp');
    injectMockTransport(client, {
      callTool: vi.fn().mockResolvedValue({
        query_used: 'test query',
        results: [
          {
            tool_name: 'salesforce@1/get_lead@1',
            integration: 'salesforce',
            score: 0.95,
          },
        ],
        total: 1,
        limit: 10,
      }),
    });

    const result = await client.discover({ query: 'test query' });

    expect(result.queryUsed).toBe('test query');
    expect(result.results).toHaveLength(1);
    expect(result.results[0].toolName).toBe('salesforce@1/get_lead@1');
  });

  // ─── Guide session ───────────────────────────────────────────────────────────

  it('should create guided session', async () => {
    const client = new Client('https://gateway.datagrout.ai/servers/test/mcp');
    injectMockTransport(client, {
      callTool: vi.fn().mockResolvedValue({
        session_id: 'guide_abc',
        step: '1',
        message: 'Choose a path',
        status: 'ready',
        options: [{ id: '1.1', label: 'Option 1', cost: 2.5, viable: true }],
        path_taken: [],
        total_cost: 0.0,
      }),
    });

    const session = await client.guide({ goal: 'test goal' });

    expect(session.sessionId).toBe('guide_abc');
    expect(session.status).toBe('ready');
    expect(session.options).toHaveLength(1);
  });

  // ─── prism.focus wire protocol (namespaced) ──────────────────────────────────

  it('prism.focus sends source_type and target_type (not lens)', async () => {
    const client = new Client('https://gateway.datagrout.ai/servers/test/mcp');
    const mock = injectMockTransport(client, {
      callTool: vi.fn().mockResolvedValue({ result: 'focused' }),
    });

    await client.prism.focus({
      data: { value: 42 },
      sourceType: 'raw_json',
      targetType: 'crm_lead',
      sourceAnnotations: { hint: 'is_numeric' },
      targetAnnotations: { required: true },
      context: 'sales pipeline',
    });

    expect(mock.callTool).toHaveBeenCalledWith(
      'data-grout/prism.focus',
      expect.objectContaining({
        data: { value: 42 },
        source_type: 'raw_json',
        target_type: 'crm_lead',
        source_annotations: { hint: 'is_numeric' },
        target_annotations: { required: true },
        context: 'sales pipeline',
      })
    );
    const calledParams = mock.callTool.mock.calls[0][1];
    expect(calledParams).not.toHaveProperty('lens');
  });

  it('prism.focus omits optional snake_case keys when not provided', async () => {
    const client = new Client('https://gateway.datagrout.ai/servers/test/mcp');
    const mock = injectMockTransport(client, {
      callTool: vi.fn().mockResolvedValue({}),
    });

    await client.prism.focus({ data: 'hello', sourceType: 'text', targetType: 'summary' });

    const calledParams = mock.callTool.mock.calls[0][1];
    expect(calledParams).not.toHaveProperty('source_annotations');
    expect(calledParams).not.toHaveProperty('target_annotations');
    expect(calledParams).not.toHaveProperty('context');
  });

  // ─── plan() ──────────────────────────────────────────────────────────────────

  it('plan sends data-grout/discovery.plan with snake_case params', async () => {
    const client = new Client('https://gateway.datagrout.ai/servers/test/mcp');
    const mock = injectMockTransport(client, {
      callTool: vi.fn().mockResolvedValue({ steps: [] }),
    });

    await client.plan({
      goal: 'find leads',
      query: 'CRM search',
      server: 'salesforce',
      k: 5,
      returnCallHandles: true,
      exposeVirtualSkills: false,
      modelOverrides: { model: 'gpt-4o' },
    });

    expect(mock.callTool).toHaveBeenCalledWith(
      'data-grout/discovery.plan',
      expect.objectContaining({
        goal: 'find leads',
        query: 'CRM search',
        server: 'salesforce',
        k: 5,
        return_call_handles: true,
        expose_virtual_skills: false,
        model_overrides: { model: 'gpt-4o' },
      })
    );
  });

  it('plan omits undefined optional params', async () => {
    const client = new Client('https://gateway.datagrout.ai/servers/test/mcp');
    const mock = injectMockTransport(client, {
      callTool: vi.fn().mockResolvedValue({}),
    });

    await client.plan({ goal: 'test' });

    const calledParams = mock.callTool.mock.calls[0][1];
    expect(calledParams).not.toHaveProperty('query');
    expect(calledParams).not.toHaveProperty('k');
    expect(calledParams).not.toHaveProperty('return_call_handles');
  });

  // ─── prism.refract() (namespaced) ─────────────────────────────────────────────

  it('prism.refract sends data-grout/prism.refract with correct params', async () => {
    const client = new Client('https://gateway.datagrout.ai/servers/test/mcp');
    const mock = injectMockTransport(client, {
      callTool: vi.fn().mockResolvedValue({ output: 'refracted' }),
    });

    await client.prism.refract({ goal: 'summarise', payload: { data: [1, 2, 3] }, verbose: true, chart: false });

    expect(mock.callTool).toHaveBeenCalledWith(
      'data-grout/prism.refract',
      expect.objectContaining({
        goal: 'summarise',
        payload: { data: [1, 2, 3] },
        verbose: true,
        chart: false,
      })
    );
  });

  // ─── prism.chart() (namespaced) ─────────────────────────────────────────────

  it('prism.chart sends data-grout/prism.chart with snake_case params', async () => {
    const client = new Client('https://gateway.datagrout.ai/servers/test/mcp');
    const mock = injectMockTransport(client, {
      callTool: vi.fn().mockResolvedValue({ url: 'chart.png' }),
    });

    await client.prism.chart({
      goal: 'visualise revenue',
      payload: { rows: [] },
      chartType: 'bar',
      xLabel: 'Month',
      yLabel: 'Revenue',
      width: 800,
      height: 400,
    });

    expect(mock.callTool).toHaveBeenCalledWith(
      'data-grout/prism.chart',
      expect.objectContaining({
        goal: 'visualise revenue',
        payload: { rows: [] },
        chart_type: 'bar',
        x_label: 'Month',
        y_label: 'Revenue',
        width: 800,
        height: 400,
      })
    );
    const calledParams = mock.callTool.mock.calls[0][1];
    expect(calledParams).not.toHaveProperty('chartType');
    expect(calledParams).not.toHaveProperty('xLabel');
    expect(calledParams).not.toHaveProperty('yLabel');
  });

  // ─── Logic cell (namespaced) ──────────────────────────────────────────────────

  it('logic.remember sends data-grout/logic.remember', async () => {
    const client = new Client('https://gateway.datagrout.ai/servers/test/mcp');
    const mock = injectMockTransport(client, {
      callTool: vi.fn().mockResolvedValue({ handles: [], facts: [], count: 0, message: 'ok' }),
    });

    await client.logic.remember('Alice is a VIP customer');

    expect(mock.callTool).toHaveBeenCalledWith(
      'data-grout/logic.remember',
      expect.objectContaining({ statement: 'Alice is a VIP customer' })
    );
  });

  it('logic.query sends data-grout/logic.query', async () => {
    const client = new Client('https://gateway.datagrout.ai/servers/test/mcp');
    const mock = injectMockTransport(client, {
      callTool: vi.fn().mockResolvedValue({ results: [], total: 0, description: '', message: 'ok' }),
    });

    await client.logic.query('Who are the VIP customers?');

    expect(mock.callTool).toHaveBeenCalledWith(
      'data-grout/logic.query',
      expect.objectContaining({ question: 'Who are the VIP customers?' })
    );
  });

  it('logic.forget sends data-grout/logic.forget', async () => {
    const client = new Client('https://gateway.datagrout.ai/servers/test/mcp');
    const mock = injectMockTransport(client, {
      callTool: vi.fn().mockResolvedValue({ retracted: 1, handles: ['h1'], message: 'ok' }),
    });

    await client.logic.forget({ handles: ['h1'] });

    expect(mock.callTool).toHaveBeenCalledWith(
      'data-grout/logic.forget',
      expect.objectContaining({ handles: ['h1'] })
    );
  });

  it('logic.reflect sends data-grout/logic.reflect', async () => {
    const client = new Client('https://gateway.datagrout.ai/servers/test/mcp');
    const mock = injectMockTransport(client, {
      callTool: vi.fn().mockResolvedValue({ total: 0, message: 'ok' }),
    });

    await client.logic.reflect({ summaryOnly: true });

    expect(mock.callTool).toHaveBeenCalledWith(
      'data-grout/logic.reflect',
      expect.objectContaining({ summary_only: true })
    );
  });

  it('logic.constrain sends data-grout/logic.constrain', async () => {
    const client = new Client('https://gateway.datagrout.ai/servers/test/mcp');
    const mock = injectMockTransport(client, {
      callTool: vi.fn().mockResolvedValue({ handle: 'c1', name: 'rule', rule: 'rule', message: 'ok' }),
    });

    await client.logic.constrain('VIP customers have ARR > $500K');

    expect(mock.callTool).toHaveBeenCalledWith(
      'data-grout/logic.constrain',
      expect.objectContaining({ rule: 'VIP customers have ARR > $500K' })
    );
  });

  it('flow.route sends data-grout/flow.route', async () => {
    const client = new Client('https://gateway.datagrout.ai/servers/test/mcp');
    const mock = injectMockTransport(client, {
      callTool: vi.fn().mockResolvedValue({ matched: 'branch_1' }),
    });

    await client.flow.route({
      branches: [{ when: 'amount > 1000', then: 'approval_flow' }],
      payload: { amount: 1500 },
    });

    expect(mock.callTool).toHaveBeenCalledWith(
      'data-grout/flow.route',
      expect.objectContaining({
        branches: [{ when: 'amount > 1000', then: 'approval_flow' }],
        payload: { amount: 1500 },
      })
    );
  });

  // ─── dg() generic hook ───────────────────────────────────────────────────────

  it('dg() sends data-grout/<toolShortName> with provided params', async () => {
    const client = new Client('https://gateway.datagrout.ai/servers/test/mcp');
    const mock = injectMockTransport(client, {
      callTool: vi.fn().mockResolvedValue({ rendered: true }),
    });

    await client.dg('prism.render', { payload: { val: 1 }, goal: 'summary' });

    expect(mock.callTool).toHaveBeenCalledWith(
      'data-grout/prism.render',
      { payload: { val: 1 }, goal: 'summary' }
    );
  });

  it('dg() defaults to empty params object', async () => {
    const client = new Client('https://gateway.datagrout.ai/servers/test/mcp');
    const mock = injectMockTransport(client, {
      callTool: vi.fn().mockResolvedValue({}),
    });

    await client.dg('some.tool');

    expect(mock.callTool).toHaveBeenCalledWith('data-grout/some.tool', {});
  });

  // ─── Non-DG URL warning ──────────────────────────────────────────────────────

  it('should warn once when calling DG-specific method on non-DG URL', async () => {
    const consoleSpy = vi.spyOn(console, 'warn').mockImplementation(() => {});

    const client = new Client('https://my-custom-mcp.example.com/mcp');
    injectMockTransport(client, {
      callTool: vi.fn().mockResolvedValue({
        query_used: 'q', results: [], total: 0, limit: 5
      }),
    });

    await client.discover({ query: 'test' });
    await client.discover({ query: 'test again' });

    expect(consoleSpy).toHaveBeenCalledTimes(1);
    expect(consoleSpy.mock.calls[0][0]).toMatch(/DataGrout-specific/i);

    consoleSpy.mockRestore();
  });

  it('should NOT warn when calling DG-specific method on DG URL', async () => {
    const consoleSpy = vi.spyOn(console, 'warn').mockImplementation(() => {});

    const client = new Client('https://gateway.datagrout.ai/servers/test/mcp');
    injectMockTransport(client, {
      callTool: vi.fn().mockResolvedValue({
        query_used: 'q', results: [], total: 0, limit: 5
      }),
    });

    await client.discover({ query: 'test' });

    const dgWarnings = consoleSpy.mock.calls.filter(c =>
      typeof c[0] === 'string' && c[0].includes('DataGrout-specific')
    );
    expect(dgWarnings).toHaveLength(0);

    consoleSpy.mockRestore();
  });

  // ─── Rate limiting ────────────────────────────────────────────────────────────

  it('should throw RateLimitError when transport returns 429', async () => {
    const rateLimitResponse = new Response('', {
      status: 429,
      headers: {
        'X-RateLimit-Used': '50',
        'X-RateLimit-Limit': '50',
      },
    });

    vi.stubGlobal('fetch', vi.fn().mockResolvedValue(rateLimitResponse));

    const client = new Client({
      url: 'https://gateway.datagrout.ai/servers/test/mcp',
      transport: 'jsonrpc',
    });
    // @ts-ignore — JSONRPC transport auto-connects on call, but we need initialized=true
    client.initialized = true;

    let caughtError: unknown;
    try {
      await client.callTool('some-tool', {});
    } catch (err) {
      caughtError = err;
    }

    expect(caughtError).toBeInstanceOf(RateLimitError);
    const rlErr = caughtError as RateLimitError;
    expect(rlErr.status.used).toBe(50);
    expect(rlErr.status.isLimited).toBe(true);
    expect(rlErr.status.remaining).toBe(0);
    expect(rlErr.message).toMatch(/rate limit/i);

    vi.unstubAllGlobals();
  });

  it('should surface unlimited rate limit for authenticated users', () => {
    const status = {
      used: 0,
      limit: 'unlimited' as const,
      isLimited: false,
      remaining: null,
    };
    const err = new RateLimitError(status);
    expect(err.status.limit).toBe('unlimited');
    expect(err.message).toContain('unlimited');
  });

  // ─── discover sends min_score (snake_case) ─────────────────────────────────

  it('discover sends min_score as snake_case to match server wire protocol', async () => {
    const client = new Client('https://gateway.datagrout.ai/servers/test/mcp');
    const mock = injectMockTransport(client, {
      callTool: vi.fn().mockResolvedValue({
        goal_used: 'q', results: [], total: 0, limit: 5,
      }),
    });

    await client.discover({ query: 'test', minScore: 0.5 });

    const calledParams = mock.callTool.mock.calls[0][1];
    expect(calledParams).toHaveProperty('min_score', 0.5);
    expect(calledParams).not.toHaveProperty('minScore');
  });

  // ─── maxRetries ─────────────────────────────────────────────────────────────

  it('defaults maxRetries to 3', () => {
    const client = new Client('https://gateway.datagrout.ai/servers/test/mcp');
    // @ts-ignore
    expect(client.maxRetries).toBe(3);
  });

  it('respects custom maxRetries option', () => {
    const client = new Client({ url: 'https://example.com/mcp', maxRetries: 5 });
    // @ts-ignore
    expect(client.maxRetries).toBe(5);
  });

  it('should exhaust maxRetries before giving up', async () => {
    const client = new Client({ url: 'https://gateway.datagrout.ai/servers/test/mcp', maxRetries: 2 });

    let callCount = 0;
    const mockTransport = {
      connect: vi.fn().mockResolvedValue(undefined),
      disconnect: vi.fn().mockResolvedValue(undefined),
      callTool: vi.fn().mockImplementation(async () => {
        callCount++;
        const err: any = new Error('not initialized');
        err.code = -32002;
        throw err;
      }),
      listTools: vi.fn().mockResolvedValue([]),
      listResources: vi.fn().mockResolvedValue([]),
      readResource: vi.fn().mockResolvedValue({}),
      listPrompts: vi.fn().mockResolvedValue([]),
      getPrompt: vi.fn().mockResolvedValue({}),
    };
    // @ts-ignore
    client.transport = mockTransport;
    // @ts-ignore
    client.initialized = true;

    await expect(client.callTool('test', {})).rejects.toThrow('not initialized');
    expect(callCount).toBe(3); // initial + 2 retries
    expect(mockTransport.connect).toHaveBeenCalledTimes(2);
  });

  // ─── plan requires goal or query ──────────────────────────────────────────

  it('plan throws InvalidConfigError when neither goal nor query given', async () => {
    const client = new Client('https://gateway.datagrout.ai/servers/test/mcp');
    injectMockTransport(client);

    await expect(client.plan({})).rejects.toThrow(/goal.*query/i);
  });
});

// ─── unwrapContent (MCP 2025 structuredContent priority) ─────────────────────

describe('unwrapContent', () => {
  it('returns structuredContent directly when present', () => {
    const sc = { docs: [{ ref: 'doc_abc', title: 'My Doc' }] };
    const result = unwrapContent({
      structuredContent: sc,
      content: [{ type: 'text', text: '{"docs":[{"ref":"doc_xyz"}]}' }],
      isError: false,
    });
    expect(result).toBe(sc);
  });

  it('returns structuredContent even when it is an empty object', () => {
    const result = unwrapContent({ structuredContent: {} });
    expect(result).toEqual({});
  });

  it('falls back to parsing content[0].text as JSON when no structuredContent', () => {
    const payload = { answer: 42, rows: [1, 2, 3] };
    const result = unwrapContent({
      content: [{ type: 'text', text: JSON.stringify(payload) }],
      isError: false,
    });
    expect(result).toEqual(payload);
  });

  it('returns { text } when content[0].text is not valid JSON', () => {
    const result = unwrapContent({
      content: [{ type: 'text', text: 'plain string result' }],
    });
    expect(result).toEqual({ text: 'plain string result' });
  });

  it('returns content[0] as-is when it has no text field', () => {
    const item = { type: 'image', url: 'https://example.com/img.png' };
    const result = unwrapContent({ content: [item] });
    expect(result).toBe(item);
  });

  it('returns the raw result when neither structuredContent nor content is present', () => {
    const raw = { custom: 'payload' };
    const result = unwrapContent(raw);
    expect(result).toBe(raw);
  });

  it('returns null/undefined as-is', () => {
    expect(unwrapContent(null)).toBeNull();
    expect(unwrapContent(undefined)).toBeUndefined();
  });
});
