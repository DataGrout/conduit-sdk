/**
 * Tests for the WebSocket transport (datagrout-jsonrpc.v1).
 *
 * Uses a lightweight in-process mock WebSocket to exercise the full
 * message-routing logic without a real network connection.
 */

import { describe, it, expect, vi, beforeEach } from 'vitest';
import { WsTransport, Subscription, SubscriptionEvent, SUBPROTOCOL, PING_INTERVAL_MS } from '../src/transports/ws';
import { Client } from '../src/client';

// ── Mock WebSocket factory ────────────────────────────────────────────────────

type WsHandler = (data: string) => void;

interface MockWsInstance {
  onopen: (() => void) | null;
  onmessage: ((ev: { data: string }) => void) | null;
  onerror: ((ev: { message?: string }) => void) | null;
  onclose: (() => void) | null;
  send: ReturnType<typeof vi.fn>;
  close: ReturnType<typeof vi.fn>;
  /** Helper: trigger a server frame as if it arrived from the network. */
  receive(data: unknown): void;
}

function createMockWs(): MockWsInstance {
  const ws: MockWsInstance = {
    onopen: null,
    onmessage: null,
    onerror: null,
    onclose: null,
    send: vi.fn(),
    close: vi.fn(),
    receive(data: unknown) {
      ws.onmessage?.({ data: JSON.stringify(data) });
    },
  };
  return ws;
}

/** Build a WsTransport that wraps the given mock WS instance. */
function buildTransportWithMock(ws: MockWsInstance): WsTransport {
  const transport = new WsTransport('wss://example.com/ws');

  // Patch _ws directly so we skip the real connect().
  (transport as any)._ws = ws;
  // Wire the message handler.
  ws.onmessage = (ev: { data: string }) => (transport as any)._handleMessage(ev.data);

  return transport;
}

// ── Constructor validation ────────────────────────────────────────────────────

describe('WsTransport constructor', () => {
  it('rejects non-ws URLs', () => {
    expect(() => new WsTransport('https://example.com/ws')).toThrow('ws://');
  });

  it('accepts ws:// URLs', () => {
    expect(() => new WsTransport('ws://localhost:4000/ws')).not.toThrow();
  });

  it('accepts wss:// URLs', () => {
    expect(() => new WsTransport('wss://gw.example.com/ws')).not.toThrow();
  });

  it('starts disconnected', () => {
    const t = new WsTransport('wss://example.com/ws');
    expect((t as any)._ws).toBeNull();
  });
});

// ── Pending-request routing ───────────────────────────────────────────────────

describe('WsTransport request/response routing', () => {
  it('routes a JSON-RPC response to the matching pending request', async () => {
    const ws = createMockWs();
    const t = buildTransportWithMock(ws);

    // Plant a pending request.
    const resultPromise = new Promise((resolve, reject) => {
      (t as any)._pending.set('ws-1', { resolve, reject });
    });

    ws.receive({ jsonrpc: '2.0', id: 'ws-1', result: { ok: true } });

    expect(await resultPromise).toEqual({ ok: true });
    expect((t as any)._pending.size).toBe(0);
  });

  it('propagates a JSON-RPC error to the pending request', async () => {
    const ws = createMockWs();
    const t = buildTransportWithMock(ws);

    const errPromise = new Promise((_resolve, reject) => {
      (t as any)._pending.set('ws-1', { resolve: () => {}, reject });
    });

    ws.receive({ jsonrpc: '2.0', id: 'ws-1', error: { code: -32600, message: 'bad input' } });

    await expect(errPromise).rejects.toThrow('bad input');
  });

  it('silently drops responses for unknown ids', () => {
    const ws = createMockWs();
    const t = buildTransportWithMock(ws);

    // No pending entry for "ghost" — should not throw.
    expect(() =>
      ws.receive({ jsonrpc: '2.0', id: 'ghost', result: {} })
    ).not.toThrow();
  });

  it('silently drops malformed JSON', () => {
    const ws = createMockWs();
    const t = buildTransportWithMock(ws);

    expect(() => (t as any)._handleMessage('not json')).not.toThrow();
    expect(() => (t as any)._handleMessage('')).not.toThrow();
  });
});

// ── Subscribe response routing ────────────────────────────────────────────────

describe('WsTransport subscribe/unsubscribe', () => {
  it('resolves subscribe with a Subscription on success', async () => {
    const ws = createMockWs();
    const t = buildTransportWithMock(ws);

    const subPromise = new Promise<Subscription>((resolve, reject) => {
      (t as any)._pendingSubscribe.set('req-1', {
        topic: 'agents.x.events',
        resolve,
        reject,
      });
    });

    ws.receive({
      jsonrpc: '2.0',
      id: 'req-1',
      result: { subscription: 'sub_abc', topic: 'agents.x.events' },
    });

    const sub = await subPromise;
    expect(sub).toBeInstanceOf(Subscription);
    expect(sub.id).toBe('sub_abc');
    expect(sub.topic).toBe('agents.x.events');
    expect((t as any)._subscriptions.has('sub_abc')).toBe(true);
  });

  it('rejects subscribe on error response', async () => {
    const ws = createMockWs();
    const t = buildTransportWithMock(ws);

    const errPromise = new Promise<Subscription>((_resolve, reject) => {
      (t as any)._pendingSubscribe.set('req-1', {
        topic: 'bad.topic',
        resolve: () => {},
        reject,
      });
    });

    ws.receive({
      jsonrpc: '2.0',
      id: 'req-1',
      error: { code: -32000, message: 'unknown topic' },
    });

    await expect(errPromise).rejects.toThrow('unknown topic');
  });

  it('closes local subscription immediately on unsubscribe', async () => {
    const ws = createMockWs();
    const t = buildTransportWithMock(ws);

    const sub = new Subscription('sub_1', 'tasks.x.*');
    (t as any)._subscriptions.set('sub_1', sub);

    // Resolve the pending unsubscribe ack immediately.
    ws.send.mockImplementationOnce(() => {
      const id = [...(t as any)._pending.keys()].pop();
      if (id) {
        const { resolve } = (t as any)._pending.get(id);
        (t as any)._pending.delete(id);
        resolve({});
      }
    });

    await t.unsubscribe('sub_1');

    expect((t as any)._subscriptions.has('sub_1')).toBe(false);
    // Subscription queue should be closed.
    await expect(sub.recv()).rejects.toThrow('closed');
  });
});

// ── Notification routing ──────────────────────────────────────────────────────

describe('WsTransport notification routing', () => {
  it('routes a notification to the matching subscription', () => {
    const ws = createMockWs();
    const t = buildTransportWithMock(ws);

    const sub = new Subscription('sub_abc', 'agents.x.events');
    (t as any)._subscriptions.set('sub_abc', sub);

    ws.receive({
      jsonrpc: '2.0',
      method: 'notification',
      params: { subscription: 'sub_abc', event: 'thought', data: { text: 'hi' } },
    });

    const ev = (sub as any)._queue[0] as SubscriptionEvent;
    expect(ev).toBeDefined();
    expect(ev.event).toBe('thought');
    expect(ev.data).toEqual({ text: 'hi' });
  });

  it('silently drops notifications for unknown subscription ids', () => {
    const ws = createMockWs();
    const t = buildTransportWithMock(ws);

    expect(() =>
      ws.receive({
        jsonrpc: '2.0',
        method: 'notification',
        params: { subscription: 'ghost', event: 'x', data: null },
      })
    ).not.toThrow();
  });

  it('ignores unknown server-initiated methods', () => {
    const ws = createMockWs();
    const t = buildTransportWithMock(ws);

    expect(() =>
      ws.receive({ jsonrpc: '2.0', method: 'session.ready', params: { session_id: 'abc' } })
    ).not.toThrow();
    expect((t as any)._subscriptions.size).toBe(0);
  });
});

// ── Fail-all on disconnect ────────────────────────────────────────────────────

describe('WsTransport _failAll', () => {
  it('rejects all pending requests and closes subscriptions', () => {
    const ws = createMockWs();
    const t = buildTransportWithMock(ws);

    let rejected1 = false;
    let rejected2 = false;

    (t as any)._pending.set('ws-1', {
      resolve: () => {},
      reject: () => {
        rejected1 = true;
      },
    });
    (t as any)._pendingSubscribe.set('req-1', {
      topic: 'x',
      resolve: () => {},
      reject: () => {
        rejected2 = true;
      },
    });
    const sub = new Subscription('sub_1', 'x');
    (t as any)._subscriptions.set('sub_1', sub);

    (t as any)._failAll('boom');

    expect(rejected1).toBe(true);
    expect(rejected2).toBe(true);
    expect((t as any)._pending.size).toBe(0);
    expect((t as any)._subscriptions.size).toBe(0);
  });
});

// ── Subscription class ────────────────────────────────────────────────────────

describe('Subscription', () => {
  it('delivers buffered events via recv()', async () => {
    const sub = new Subscription('sub_1', 'topic.x');
    const ev: SubscriptionEvent = { subscription: 'sub_1', event: 'ping', data: 1 };
    sub._enqueue(ev);
    expect(await sub.recv()).toEqual(ev);
  });

  it('throws on recv() when closed', async () => {
    const sub = new Subscription('sub_1', 'topic.x');
    sub._close();
    await expect(sub.recv()).rejects.toThrow('closed');
  });

  it('async-iterates buffered events and stops on close', async () => {
    const sub = new Subscription('sub_1', 'topic.x');
    for (let i = 0; i < 3; i++) {
      sub._enqueue({ subscription: 'sub_1', event: `ev${i}`, data: i });
    }
    sub._close();

    const collected: SubscriptionEvent[] = [];
    for await (const ev of sub) {
      collected.push(ev);
    }
    expect(collected).toHaveLength(3);
    expect(collected.map((e) => e.event)).toEqual(['ev0', 'ev1', 'ev2']);
  });

  it('delivers events to waiters directly (no buffering)', async () => {
    const sub = new Subscription('sub_1', 'topic.x');
    const promise = sub.recv();
    const ev: SubscriptionEvent = { subscription: 'sub_1', event: 'direct', data: 42 };
    sub._enqueue(ev);
    expect(await promise).toEqual(ev);
    // Queue should be empty — the event went straight to the waiter.
    expect((sub as any)._queue).toHaveLength(0);
  });
});

// ── Upgrade headers ───────────────────────────────────────────────────────────

describe('buildUpgradeHeaders', () => {
  // Access the private helper via the WS transport's internal build path.

  it('bearer auth header', () => {
    // We can exercise this indirectly by checking _send includes auth.
    // Just verify the transport constructs without error.
    const t = new WsTransport('wss://example.com/ws', { bearer: 'tok123' });
    expect(t).toBeDefined();
  });

  it('api key header', () => {
    const t = new WsTransport('wss://example.com/ws', { apiKey: 'k123' });
    expect(t).toBeDefined();
  });
});

// ── Client integration ────────────────────────────────────────────────────────

describe('Client WebSocket integration', () => {
  it('accepts transport: websocket and creates WsTransport', () => {
    const client = new Client({
      url: 'wss://gateway.datagrout.ai/servers/test/ws',
      transport: 'websocket',
    });
    expect((client as any).transport).toBeInstanceOf(WsTransport);
  });

  it('rewrites https:// to wss://', () => {
    const client = new Client({
      url: 'https://gateway.datagrout.ai/servers/test/ws',
      transport: 'websocket',
    });
    const t = (client as any).transport as WsTransport;
    expect((t as any)._url).toMatch(/^wss:\/\//);
  });

  it('rewrites http:// to ws://', () => {
    const client = new Client({
      url: 'http://localhost:4000/ws',
      transport: 'websocket',
    });
    const t = (client as any).transport as WsTransport;
    expect((t as any)._url).toMatch(/^ws:\/\//);
  });

  it('subscribe() throws when transport is not WS', async () => {
    const client = new Client('https://gateway.datagrout.ai/servers/test/mcp');
    (client as any).initialized = true;
    await expect(client.subscribe('agents.x.events')).rejects.toThrow("transport: 'websocket'");
  });

  it('unsubscribe() throws when transport is not WS', async () => {
    const client = new Client('https://gateway.datagrout.ai/servers/test/mcp');
    (client as any).initialized = true;
    await expect(client.unsubscribe('sub_123')).rejects.toThrow("transport: 'websocket'");
  });
});

// ── Ping keepalive ────────────────────────────────────────────────────────────

describe('WsTransport ping keepalive', () => {
  it('exports PING_INTERVAL_MS = 25 000', () => {
    expect(PING_INTERVAL_MS).toBe(25_000);
  });

  it('does not start a ping timer before connect()', () => {
    const t = new WsTransport('wss://example.com/ws');
    expect((t as any)._pingTimer).toBeNull();
    expect(t.pingsSent).toBe(0);
  });

  it('starts and stops the ping timer across the connect/disconnect lifecycle', async () => {
    const t = new WsTransport('wss://example.com/ws');
    t.setPingInterval(20); // 20ms so the test does not stall

    const ws = createMockWs();
    // Mock the `ws.ping()` method that the Node `ws` package would expose.
    const ping = vi.fn();
    (ws as any).ping = ping;

    (t as any)._ws = ws;
    (t as any)._startPingTimer();

    expect((t as any)._pingTimer).not.toBeNull();

    // Wait long enough for at least one tick.
    await new Promise(resolve => setTimeout(resolve, 80));
    expect(ping.mock.calls.length).toBeGreaterThanOrEqual(1);
    expect(t.pingsSent).toBeGreaterThanOrEqual(1);

    await t.disconnect();
    expect((t as any)._pingTimer).toBeNull();

    const callsBefore = ping.mock.calls.length;
    await new Promise(resolve => setTimeout(resolve, 60));
    expect(ping.mock.calls.length).toBe(callsBefore);
  });

  it('silently skips ping when the underlying WebSocket lacks a ping method (browser)', async () => {
    const t = new WsTransport('wss://example.com/ws');
    t.setPingInterval(20);

    const ws = createMockWs(); // no `ping` property
    (t as any)._ws = ws;
    (t as any)._startPingTimer();

    await new Promise(resolve => setTimeout(resolve, 80));
    // No throw, no pings counted, timer still active until disconnect.
    expect(t.pingsSent).toBe(0);

    await t.disconnect();
  });
});
