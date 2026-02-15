/**
 * Tests for DataGrout Conduit client
 */

import { describe, it, expect, vi, beforeEach } from 'vitest';
import { Client } from '../src/client';

describe('Client', () => {
  it('should initialize with URL string', () => {
    const client = new Client('https://gateway.datagrout.ai/servers/test/mcp');
    expect(client).toBeDefined();
  });

  it('should initialize with options object', () => {
    const client = new Client({
      url: 'https://gateway.datagrout.ai/servers/test/mcp',
      hide3rdPartyTools: true,
    });
    expect(client).toBeDefined();
  });

  it('should return filtered tools when hide3rdPartyTools=true', async () => {
    const client = new Client({
      url: 'https://gateway.datagrout.ai/servers/test/mcp',
      hide3rdPartyTools: true,
    });

    const tools = await client.listTools();

    expect(tools.length).toBeGreaterThan(0);
    const toolNames = tools.map((t) => t.name);
    expect(toolNames).toContain('data-grout/discovery.discover');
    expect(toolNames).toContain('data-grout/discovery.perform');
  });

  it('should track receipts from operations', async () => {
    const mockTransport = {
      connect: vi.fn().mockResolvedValue(undefined),
      disconnect: vi.fn().mockResolvedValue(undefined),
      listTools: vi.fn().mockResolvedValue([]),
      callTool: vi.fn().mockResolvedValue({
        result: 'success',
        _receipt: {
          receipt_id: 'rcp_123',
          estimated_credits: 5.0,
          actual_credits: 4.5,
          net_credits: 4.5,
          savings: 0.5,
        },
      }),
      listResources: vi.fn().mockResolvedValue([]),
      readResource: vi.fn().mockResolvedValue({}),
      listPrompts: vi.fn().mockResolvedValue([]),
      getPrompt: vi.fn().mockResolvedValue({}),
    };

    const client = new Client('https://gateway.datagrout.ai/servers/test/mcp');
    // @ts-ignore - accessing private property for testing
    client.transport = mockTransport;

    await client.perform({ tool: 'test-tool', args: {} });

    const receipt = client.getLastReceipt();
    expect(receipt).toBeDefined();
    expect(receipt?.receiptId).toBe('rcp_123');
    expect(receipt?.actualCredits).toBe(4.5);
  });

  it('should normalize snake_case to camelCase for receipts', async () => {
    const mockTransport = {
      connect: vi.fn().mockResolvedValue(undefined),
      disconnect: vi.fn().mockResolvedValue(undefined),
      listTools: vi.fn().mockResolvedValue([]),
      callTool: vi.fn().mockResolvedValue({
        result: 'success',
        _receipt: {
          receipt_id: 'rcp_456',
          estimated_credits: 10.0,
          actual_credits: 9.0,
          net_credits: 9.0,
          savings_bonus: 0.5,
        },
      }),
      listResources: vi.fn().mockResolvedValue([]),
      readResource: vi.fn().mockResolvedValue({}),
      listPrompts: vi.fn().mockResolvedValue([]),
      getPrompt: vi.fn().mockResolvedValue({}),
    };

    const client = new Client('https://gateway.datagrout.ai/servers/test/mcp');
    // @ts-ignore - accessing private property for testing
    client.transport = mockTransport;

    await client.perform({ tool: 'test-tool', args: {} });

    const receipt = client.getLastReceipt();
    expect(receipt?.receiptId).toBe('rcp_456');
    expect(receipt?.savingsBonus).toBe(0.5);
  });

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
    // @ts-ignore - accessing private property for testing
    client.transport = mockTransport;

    const result = await client.discover({ query: 'test query' });

    expect(result.queryUsed).toBe('test query');
    expect(result.results).toHaveLength(1);
    expect(result.results[0].toolName).toBe('salesforce@1/get_lead@1');
  });

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
    // @ts-ignore - accessing private property for testing
    client.transport = mockTransport;

    const session = await client.guide({ goal: 'test goal' });

    expect(session.sessionId).toBe('guide_abc');
    expect(session.status).toBe('ready');
    expect(session.options).toHaveLength(1);
  });
});
