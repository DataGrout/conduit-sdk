/**
 * WebSocket transport for `datagrout-jsonrpc.v1`.
 *
 * Recommended for any client that needs bidirectional push (server-initiated
 * notifications) without a polling loop. A single `wss://` connection is
 * multiplexed for all in-flight requests; concurrent calls are correlated by
 * JSON-RPC `id` with no head-of-line blocking.
 *
 * @example
 * ```ts
 * const client = new Client({
 *   url: 'wss://gateway.datagrout.ai/servers/<uuid>/ws',
 *   transport: 'websocket',
 *   auth: { bearer: 'your-token' },
 * });
 * await client.connect();
 *
 * // Push subscription
 * const sub = await client.subscribe('agents.my-agent-id.events');
 * for await (const event of sub) {
 *   console.log(event.event, event.data);
 * }
 * await client.unsubscribe(sub.id);
 * ```
 *
 * @module
 */

import type { MCPTool, MCPResource, MCPPrompt, AuthConfig } from "../types";
import type { ConduitIdentity } from "../identity";
import { Transport } from "./base";

export const SUBPROTOCOL = "datagrout-jsonrpc.v1";

/** Maximum events buffered per subscription before the oldest is dropped. */
const SUBSCRIPTION_BUFFER = 256;

// ── Public types ──────────────────────────────────────────────────────────────

/** A single server-pushed notification. */
export interface SubscriptionEvent {
  /** The subscription id this event belongs to. */
  subscription: string;
  /** Server-named event slug (e.g. `"agent.thought"`). */
  event: string;
  /** Free-form payload from the server. */
  data: unknown;
}

/**
 * Handle for an active server-push subscription.
 *
 * Consume events with {@link Subscription.recv} or an async-for loop:
 * ```ts
 * for await (const event of sub) {
 *   handle(event);
 * }
 * ```
 */
export class Subscription {
  readonly id: string;
  readonly topic: string;

  private _queue: SubscriptionEvent[] = [];
  private _waiters: Array<(ev: SubscriptionEvent) => void> = [];
  private _rejecters: Array<(err: Error) => void> = [];
  private _closed = false;

  constructor(id: string, topic: string) {
    this.id = id;
    this.topic = topic;
  }

  /**
   * Wait for the next event from this subscription.
   *
   * @throws When the subscription has been closed.
   */
  recv(): Promise<SubscriptionEvent> {
    if (this._queue.length > 0) {
      return Promise.resolve(this._queue.shift()!);
    }
    if (this._closed) {
      return Promise.reject(new Error("Subscription closed"));
    }
    return new Promise<SubscriptionEvent>((resolve, reject) => {
      this._waiters.push(resolve);
      this._rejecters.push(reject);
    });
  }

  async *[Symbol.asyncIterator](): AsyncGenerator<SubscriptionEvent> {
    while (this._queue.length > 0 || !this._closed) {
      try {
        yield await this.recv();
      } catch {
        return;
      }
    }
  }

  // ── Internal ───────────────────────────────────────────────────────────────

  _enqueue(event: SubscriptionEvent): void {
    if (this._waiters.length > 0) {
      const resolve = this._waiters.shift()!;
      this._rejecters.shift();
      resolve(event);
    } else if (this._queue.length < SUBSCRIPTION_BUFFER) {
      this._queue.push(event);
    }
    // else: drop on overflow
  }

  _close(): void {
    this._closed = true;
    const err = new Error("Subscription closed");
    for (const reject of this._rejecters) {
      reject(err);
    }
    this._waiters.length = 0;
    this._rejecters.length = 0;
  }
}

// ── Internal pending-request types ───────────────────────────────────────────

interface PendingRequest {
  resolve: (value: unknown) => void;
  reject: (err: Error) => void;
}

interface PendingSubscribe {
  topic: string;
  resolve: (sub: Subscription) => void;
  reject: (err: Error) => void;
}

// ── WsTransport ───────────────────────────────────────────────────────────────

/**
 * JSON-RPC 2.0 over WebSocket transport (`datagrout-jsonrpc.v1`).
 *
 * Multiplexes any number of in-flight requests on one socket and routes
 * server-pushed notifications back to {@link Subscription} queues.
 */
export class WsTransport extends Transport {
  private readonly _url: string;
  private readonly _auth?: AuthConfig;

  private _ws: WebSocket | null = null;
  private _nextId = 0;

  private readonly _pending = new Map<string, PendingRequest>();
  private readonly _pendingSubscribe = new Map<string, PendingSubscribe>();
  private readonly _subscriptions = new Map<string, Subscription>();

  constructor(
    url: string,
    auth?: AuthConfig,
    _timeout?: number,
    _identity?: ConduitIdentity,
  ) {
    super();

    const scheme = new URL(url).protocol.replace(":", "");
    if (scheme !== "ws" && scheme !== "wss") {
      throw new Error(
        `WS transport requires a ws:// or wss:// URL, got ${scheme}://`,
      );
    }

    this._url = url;
    this._auth = auth;
  }

  // ── Lifecycle ─────────────────────────────────────────────────────────────

  async connect(): Promise<void> {
    if (this._ws !== null) return;

    const WsImpl = await resolveWebSocketImpl();
    const headers = buildUpgradeHeaders(this._auth);

    // The `ws` package accepts `{ headers }` as the third argument to the
    // constructor; browsers ignore unknown options.
    const ws: WebSocket = new (WsImpl as any)(this._url, [SUBPROTOCOL], {
      headers,
    });

    await new Promise<void>((resolve, reject) => {
      ws.onopen = () => resolve();
      ws.onerror = (ev: Event) =>
        reject(
          new Error(`WS connect failed: ${(ev as any).message ?? "unknown"}`),
        );
    });

    ws.onmessage = (ev: MessageEvent) => this._handleMessage(ev.data);
    ws.onerror = (_ev: Event) => this._failAll("WS connection error");
    ws.onclose = () => {
      this._failAll("WS connection closed");
      this._ws = null;
    };

    this._ws = ws;
  }

  async disconnect(): Promise<void> {
    const ws = this._ws;
    this._ws = null;

    this._failAll("WS connection closed");

    if (ws !== null) {
      try {
        ws.close();
      } catch {
        // ignore
      }
    }
  }

  // ── Subscriptions ─────────────────────────────────────────────────────────

  /**
   * Open a server-side push subscription for `topic`.
   *
   * @param topic - Dotted namespace topic, e.g.
   *   `"agents.my-agent-id.events"` or `"tasks.task-123.*"`.
   * @returns A {@link Subscription} handle whose async-for loop delivers events.
   */
  async subscribe(topic: string): Promise<Subscription> {
    this._requireConnected();
    const id = this._mintId();

    return new Promise<Subscription>((resolve, reject) => {
      this._pendingSubscribe.set(id, { topic, resolve, reject });
      this._send({
        jsonrpc: "2.0",
        id,
        method: "subscribe",
        params: { topic },
      });
    });
  }

  /**
   * Cancel a server-side subscription.
   *
   * The local {@link Subscription} queue is closed immediately.
   *
   * @param subscriptionId - The `id` field from the {@link Subscription}
   *   returned by {@link subscribe}.
   */
  async unsubscribe(subscriptionId: string): Promise<void> {
    this._requireConnected();

    const sub = this._subscriptions.get(subscriptionId);
    if (sub !== undefined) {
      this._subscriptions.delete(subscriptionId);
      sub._close();
    }

    const id = this._mintId();
    const ackPromise = new Promise<unknown>((resolve, reject) => {
      this._pending.set(id, { resolve, reject });
    });
    this._send({
      jsonrpc: "2.0",
      id,
      method: "unsubscribe",
      params: { subscription: subscriptionId },
    });

    await Promise.race([
      ackPromise,
      new Promise<void>((resolve) => setTimeout(resolve, 5000)),
    ]);
    this._pending.delete(id);
  }

  // ── Transport base implementation ─────────────────────────────────────────

  async listTools(options?: any): Promise<MCPTool[]> {
    return (await this._request("tools/list", options)) as MCPTool[];
  }

  async callTool(
    name: string,
    args: Record<string, any>,
    _options?: any,
  ): Promise<any> {
    return this._request("tools/call", { name, arguments: args });
  }

  async listResources(_options?: any): Promise<MCPResource[]> {
    return (await this._request("resources/list")) as MCPResource[];
  }

  async readResource(uri: string, _options?: any): Promise<any> {
    return this._request("resources/read", { uri });
  }

  async listPrompts(_options?: any): Promise<MCPPrompt[]> {
    return (await this._request("prompts/list")) as MCPPrompt[];
  }

  async getPrompt(
    name: string,
    args?: Record<string, any>,
    _options?: any,
  ): Promise<any> {
    return this._request("prompts/get", { name, arguments: args });
  }

  // ── Internal ──────────────────────────────────────────────────────────────

  private _mintId(): string {
    return `ws-${++this._nextId}`;
  }

  private _requireConnected(): void {
    if (this._ws === null) {
      throw new Error("WS transport not connected. Call connect() first.");
    }
  }

  private _send(payload: Record<string, unknown>): void {
    this._ws!.send(JSON.stringify(payload));
  }

  private async _request(method: string, params?: unknown): Promise<unknown> {
    this._requireConnected();
    const id = this._mintId();

    return new Promise<unknown>((resolve, reject) => {
      this._pending.set(id, { resolve, reject });
      this._send({
        jsonrpc: "2.0",
        id,
        method,
        ...(params !== undefined ? { params } : {}),
      });
    });
  }

  private _handleMessage(data: string): void {
    let msg: Record<string, unknown>;
    try {
      msg = JSON.parse(data);
    } catch {
      return; // malformed frame — silently ignore
    }

    // Notifications have no `id` field.
    if (!("id" in msg)) {
      if (msg["method"] === "notification") {
        this._routeNotification(
          msg["params"] as Record<string, unknown> | undefined,
        );
      }
      return;
    }

    const msgId = String(msg["id"]);

    // Subscribe response — register the channel before handing off the handle.
    const pendingSub = this._pendingSubscribe.get(msgId);
    if (pendingSub !== undefined) {
      this._pendingSubscribe.delete(msgId);
      const err = msg["error"] as Record<string, unknown> | undefined;
      if (err !== undefined) {
        pendingSub.reject(
          new Error(String(err["message"] ?? "Subscribe failed")),
        );
        return;
      }
      const result = (msg["result"] ?? {}) as Record<string, unknown>;
      const subId = String(result["subscription"] ?? msgId);
      const sub = new Subscription(subId, pendingSub.topic);
      this._subscriptions.set(subId, sub);
      pendingSub.resolve(sub);
      return;
    }

    // Regular response.
    const pending = this._pending.get(msgId);
    if (pending !== undefined) {
      this._pending.delete(msgId);
      const err = msg["error"] as Record<string, unknown> | undefined;
      if (err !== undefined) {
        pending.reject(new Error(String(err["message"] ?? "RPC error")));
      } else {
        pending.resolve(msg["result"]);
      }
    }
  }

  private _routeNotification(params?: Record<string, unknown>): void {
    if (params === undefined) return;
    const subId = params["subscription"];
    if (typeof subId !== "string") return;
    const sub = this._subscriptions.get(subId);
    if (sub === undefined) return;

    sub._enqueue({
      subscription: subId,
      event: String(params["event"] ?? ""),
      data: params["data"],
    });
  }

  private _failAll(reason: string): void {
    const err = new Error(reason);
    for (const { reject } of this._pending.values()) {
      reject(err);
    }
    this._pending.clear();

    for (const { reject } of this._pendingSubscribe.values()) {
      reject(err);
    }
    this._pendingSubscribe.clear();

    for (const sub of this._subscriptions.values()) {
      sub._close();
    }
    this._subscriptions.clear();
  }
}

// ── Helpers ───────────────────────────────────────────────────────────────────

/** Build upgrade request headers from the auth config. */
function buildUpgradeHeaders(auth?: AuthConfig): Record<string, string> {
  const headers: Record<string, string> = {};
  if (auth === undefined) return headers;

  if ("bearer" in auth && auth.bearer !== undefined) {
    headers["Authorization"] = `Bearer ${auth.bearer}`;
  } else if ("apiKey" in auth && auth.apiKey !== undefined) {
    headers["X-API-Key"] = auth.apiKey;
  } else if ("basic" in auth && auth.basic !== undefined) {
    const encoded = Buffer.from(
      `${auth.basic.username}:${auth.basic.password}`,
    ).toString("base64");
    headers["Authorization"] = `Basic ${encoded}`;
  }

  return headers;
}

/**
 * Resolve the WebSocket implementation to use.
 *
 * Prefers the global `WebSocket` (available in Node ≥ 22, all browsers).
 * Falls back to the `ws` npm package for Node 18–21.
 */
async function resolveWebSocketImpl(): Promise<typeof WebSocket> {
  if (typeof globalThis.WebSocket !== "undefined") {
    return globalThis.WebSocket;
  }
  try {
    const { default: WS } = await import("ws");
    return WS as unknown as typeof WebSocket;
  } catch {
    throw new Error(
      "No WebSocket implementation found. Install the 'ws' package: npm install ws",
    );
  }
}
