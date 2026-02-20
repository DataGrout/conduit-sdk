/**
 * Tests for DataGrout Conduit client
 */

import { describe, it, expect, vi, beforeEach } from 'vitest';
import { Client } from '../src/client';
import { extractMeta } from '../src/types';
import { RateLimitError } from '../src/transports/jsonrpc';

// ─── Real DG _meta receipt fixture (matches gateway output) ──────────────────

const RECEIPT_META = {
  _meta: {
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

  it('default useIntelligentInterface is false (matches Rust spec)', () => {
    const client = new Client('https://gateway.datagrout.ai/servers/test/mcp');
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

  // ─── listTools — intelligent interface filter ────────────────────────────────

  it('should return all tools when useIntelligentInterface=false', async () => {
    const mockTransport = {
      connect: vi.fn().mockResolvedValue(undefined),
      disconnect: vi.fn().mockResolvedValue(undefined),
      listTools: vi.fn().mockResolvedValue([
        { name: 'salesforce@v1/get_lead@v1', description: 'Integration tool' },
        { name: 'arbiter_check_policy', description: 'DG tool' },
      ]),
      callTool: vi.fn().mockResolvedValue({}),
      listResources: vi.fn().mockResolvedValue([]),
      readResource: vi.fn().mockResolvedValue({}),
      listPrompts: vi.fn().mockResolvedValue([]),
      getPrompt: vi.fn().mockResolvedValue({}),
    };

    const client = new Client({
      url: 'https://gateway.datagrout.ai/servers/test/mcp',
      useIntelligentInterface: false,
    });
    // @ts-ignore
    client.transport = mockTransport;

    const tools = await client.listTools();
    const names = tools.map((t) => t.name);
    expect(names).toContain('salesforce@v1/get_lead@v1');
    expect(names).toContain('arbiter_check_policy');
  });

  it('should filter out integration tools when useIntelligentInterface=true', async () => {
    const mockTransport = {
      connect: vi.fn().mockResolvedValue(undefined),
      disconnect: vi.fn().mockResolvedValue(undefined),
      listTools: vi.fn().mockResolvedValue([
        { name: 'salesforce@v1/get_lead@v1', description: 'Integration tool' },
        { name: 'arbiter_check_policy', description: 'DG tool' },
        { name: 'governor_enable', description: 'DG tool' },
        { name: 'hubspot@v1/create_contact@v1', description: 'Integration tool' },
      ]),
      callTool: vi.fn().mockResolvedValue({}),
      listResources: vi.fn().mockResolvedValue([]),
      readResource: vi.fn().mockResolvedValue({}),
      listPrompts: vi.fn().mockResolvedValue([]),
      getPrompt: vi.fn().mockResolvedValue({}),
    };

    const client = new Client({
      url: 'https://gateway.datagrout.ai/servers/test/mcp',
      useIntelligentInterface: true,
    });
    // @ts-ignore
    client.transport = mockTransport;

    const tools = await client.listTools();
    const names = tools.map((t) => t.name);
    expect(names).not.toContain('salesforce@v1/get_lead@v1');
    expect(names).not.toContain('hubspot@v1/create_contact@v1');
    expect(names).toContain('arbiter_check_policy');
    expect(names).toContain('governor_enable');
  });

  // ─── call_tool routes through perform ────────────────────────────────────────

  it('should route call_tool through discovery.perform', async () => {
    const mockTransport = {
      connect: vi.fn().mockResolvedValue(undefined),
      disconnect: vi.fn().mockResolvedValue(undefined),
      listTools: vi.fn().mockResolvedValue([]),
      callTool: vi.fn().mockResolvedValue({ success: true }),
      listResources: vi.fn().mockResolvedValue([]),
      readResource: vi.fn().mockResolvedValue({}),
      listPrompts: vi.fn().mockResolvedValue([]),
      getPrompt: vi.fn().mockResolvedValue({}),
    };

    const client = new Client('https://gateway.datagrout.ai/servers/test/mcp');
    // @ts-ignore
    client.transport = mockTransport;

    await client.callTool('test-tool', { arg: 'value' });

    expect(mockTransport.callTool).toHaveBeenCalledWith(
      'data-grout/discovery.perform',
      expect.objectContaining({ tool: 'test-tool', args: { arg: 'value' } })
    );
  });

  // ─── Receipt via extractMeta ──────────────────────────────────────────────

  it('should parse receipt from _meta block using extractMeta', async () => {
    const mockTransport = {
      connect: vi.fn().mockResolvedValue(undefined),
      disconnect: vi.fn().mockResolvedValue(undefined),
      listTools: vi.fn().mockResolvedValue([]),
      callTool: vi.fn().mockResolvedValue({ result: 'success', ...RECEIPT_META }),
      listResources: vi.fn().mockResolvedValue([]),
      readResource: vi.fn().mockResolvedValue({}),
      listPrompts: vi.fn().mockResolvedValue([]),
      getPrompt: vi.fn().mockResolvedValue({}),
    };

    const client = new Client('https://gateway.datagrout.ai/servers/test/mcp');
    // @ts-ignore
    client.transport = mockTransport;

    const result = await client.perform({ tool: 'test-tool', args: {} });
    const meta = extractMeta(result);

    expect(meta).toBeDefined();
    expect(meta!.receipt.receiptId).toBe('rcp_123');
    expect(meta!.receipt.actualCredits).toBe(4.5);
    expect(meta!.receipt.netCredits).toBe(4.5);
    expect(meta!.receipt.balanceBefore).toBe(1000.0);
    expect(meta!.receipt.balanceAfter).toBe(995.5);
  });

  it('should parse credit estimate from _meta block using extractMeta', async () => {
    const mockTransport = {
      connect: vi.fn().mockResolvedValue(undefined),
      disconnect: vi.fn().mockResolvedValue(undefined),
      listTools: vi.fn().mockResolvedValue([]),
      callTool: vi.fn().mockResolvedValue({ result: 'success', ...RECEIPT_META }),
      listResources: vi.fn().mockResolvedValue([]),
      readResource: vi.fn().mockResolvedValue({}),
      listPrompts: vi.fn().mockResolvedValue([]),
      getPrompt: vi.fn().mockResolvedValue({}),
    };

    const client = new Client('https://gateway.datagrout.ai/servers/test/mcp');
    // @ts-ignore
    client.transport = mockTransport;

    const result = await client.perform({ tool: 'test-tool', args: {} });
    const meta = extractMeta(result);

    expect(meta?.creditEstimate).toBeDefined();
    expect(meta!.creditEstimate!.estimatedTotal).toBe(5.0);
    expect(meta!.creditEstimate!.netTotal).toBe(4.5);
  });

  it('extractMeta returns null when no _meta in result', () => {
    expect(extractMeta({ result: 'ok' })).toBeNull();
    expect(extractMeta({})).toBeNull();
    expect(extractMeta(null as any)).toBeNull();
  });

  // ─── Discover ────────────────────────────────────────────────────────────────

  it('should handle discover results', async () => {
    const mockTransport = {
      connect: vi.fn().mockResolvedValue(undefined),
      disconnect: vi.fn().mockResolvedValue(undefined),
      listTools: vi.fn().mockResolvedValue([]),
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
      listResources: vi.fn().mockResolvedValue([]),
      readResource: vi.fn().mockResolvedValue({}),
      listPrompts: vi.fn().mockResolvedValue([]),
      getPrompt: vi.fn().mockResolvedValue({}),
    };

    const client = new Client('https://gateway.datagrout.ai/servers/test/mcp');
    // @ts-ignore
    client.transport = mockTransport;

    const result = await client.discover({ query: 'test query' });

    expect(result.queryUsed).toBe('test query');
    expect(result.results).toHaveLength(1);
    expect(result.results[0].toolName).toBe('salesforce@1/get_lead@1');
  });

  // ─── Guide session ───────────────────────────────────────────────────────────

  it('should create guided session', async () => {
    const mockTransport = {
      connect: vi.fn().mockResolvedValue(undefined),
      disconnect: vi.fn().mockResolvedValue(undefined),
      listTools: vi.fn().mockResolvedValue([]),
      callTool: vi.fn().mockResolvedValue({
        session_id: 'guide_abc',
        step: '1',
        message: 'Choose a path',
        status: 'ready',
        options: [{ id: '1.1', label: 'Option 1', cost: 2.5, viable: true }],
        path_taken: [],
        total_cost: 0.0,
      }),
      listResources: vi.fn().mockResolvedValue([]),
      readResource: vi.fn().mockResolvedValue({}),
      listPrompts: vi.fn().mockResolvedValue([]),
      getPrompt: vi.fn().mockResolvedValue({}),
    };

    const client = new Client('https://gateway.datagrout.ai/servers/test/mcp');
    // @ts-ignore
    client.transport = mockTransport;

    const session = await client.guide({ goal: 'test goal' });

    expect(session.sessionId).toBe('guide_abc');
    expect(session.status).toBe('ready');
    expect(session.options).toHaveLength(1);
  });

  // ─── Non-DG URL warning ──────────────────────────────────────────────────────

  it('should warn once when calling DG-specific method on non-DG URL', async () => {
    const consoleSpy = vi.spyOn(console, 'warn').mockImplementation(() => {});

    const mockTransport = {
      connect: vi.fn().mockResolvedValue(undefined),
      disconnect: vi.fn().mockResolvedValue(undefined),
      listTools: vi.fn().mockResolvedValue([]),
      callTool: vi.fn().mockResolvedValue({
        query_used: 'q', results: [], total: 0, limit: 5
      }),
      listResources: vi.fn().mockResolvedValue([]),
      readResource: vi.fn().mockResolvedValue({}),
      listPrompts: vi.fn().mockResolvedValue([]),
      getPrompt: vi.fn().mockResolvedValue({}),
    };

    const client = new Client('https://my-custom-mcp.example.com/mcp');
    // @ts-ignore
    client.transport = mockTransport;

    await client.discover({ query: 'test' });
    await client.discover({ query: 'test again' }); // second call — should NOT warn again

    expect(consoleSpy).toHaveBeenCalledTimes(1);
    expect(consoleSpy.mock.calls[0][0]).toMatch(/DataGrout-specific/i);

    consoleSpy.mockRestore();
  });

  it('should NOT warn when calling DG-specific method on DG URL', async () => {
    const consoleSpy = vi.spyOn(console, 'warn').mockImplementation(() => {});

    const mockTransport = {
      connect: vi.fn().mockResolvedValue(undefined),
      disconnect: vi.fn().mockResolvedValue(undefined),
      listTools: vi.fn().mockResolvedValue([]),
      callTool: vi.fn().mockResolvedValue({
        query_used: 'q', results: [], total: 0, limit: 5
      }),
      listResources: vi.fn().mockResolvedValue([]),
      readResource: vi.fn().mockResolvedValue({}),
      listPrompts: vi.fn().mockResolvedValue([]),
      getPrompt: vi.fn().mockResolvedValue({}),
    };

    const client = new Client('https://gateway.datagrout.ai/servers/test/mcp');
    // @ts-ignore
    client.transport = mockTransport;

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

    const client = new Client('https://gateway.datagrout.ai/servers/test/mcp');

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
});
