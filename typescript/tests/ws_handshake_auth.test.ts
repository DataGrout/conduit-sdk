/**
 * The WebSocket upgrade must carry the resolved OAuth bearer.
 *
 * Fetching a token is asynchronous while building request headers is not, so
 * before this was fixed a provider-backed token could never reach the upgrade:
 * an OAuth client authenticated over WS only if it also happened to present an
 * mTLS identity. These tests drive the real `connect()` against a capturing
 * WebSocket stub, because the bug lived precisely in the wiring that a mocked
 * transport skips.
 */

import { describe, it, expect, vi, afterEach } from "vitest";
import { WsTransport } from "../src/transports/ws";
import type { Grant } from "../src/authcode";

/** Headers seen by the most recent WebSocket construction. */
let captured: Record<string, string> | undefined;

const realWebSocket = globalThis.WebSocket;
const realFetch = globalThis.fetch;

/** Install a WebSocket stub that records its options and opens immediately. */
function captureUpgrade(): void {
  captured = undefined;
  class CapturingWebSocket {
    onopen: (() => void) | null = null;
    onmessage: ((ev: unknown) => void) | null = null;
    onerror: ((ev: unknown) => void) | null = null;
    onclose: (() => void) | null = null;

    constructor(
      _url: string,
      _protocols?: string[],
      options?: { headers?: Record<string, string> },
    ) {
      captured = options?.headers;
      // Open on the next tick so `connect()`'s promise has a handler attached.
      setTimeout(() => this.onopen?.(), 0);
    }

    send(): void {}
    close(): void {}
    ping(): void {}
  }
  (globalThis as any).WebSocket = CapturingWebSocket;
}

afterEach(() => {
  (globalThis as any).WebSocket = realWebSocket;
  globalThis.fetch = realFetch;
});

function liveGrant(): Grant {
  return {
    access_token: "user_access_token",
    refresh_token: "rt",
    // Far future, so the provider serves it without refreshing.
    expires_at: Math.floor(Date.now() / 1000) + 3600,
    client_id: "client_abc",
    token_endpoint: "https://gateway.datagrout.ai/oauth/token",
  };
}

describe("WS upgrade authentication", () => {
  it("carries an authorization-code bearer", async () => {
    captureUpgrade();
    const t = new WsTransport("wss://gateway.datagrout.ai/ws", {
      authorizationCode: liveGrant(),
    });

    await t.connect();
    await t.disconnect();

    expect(captured?.["Authorization"]).toBe("Bearer user_access_token");
  });

  it("carries a client_credentials bearer", async () => {
    // The grant that shipped first and never authenticated over WS.
    captureUpgrade();
    globalThis.fetch = vi.fn(
      async () =>
        new Response(
          JSON.stringify({
            access_token: "machine_token",
            token_type: "Bearer",
            expires_in: 3600,
          }),
          { status: 200 },
        ),
    ) as any;

    const t = new WsTransport("wss://gateway.datagrout.ai/ws", {
      clientCredentials: {
        clientId: "id",
        clientSecret: "secret",
        tokenEndpoint: "https://gateway.datagrout.ai/oauth/token",
      },
    });

    await t.connect();
    await t.disconnect();

    expect(captured?.["Authorization"]).toBe("Bearer machine_token");
  });

  it("derives the token endpoint from the ws:// URL as an http:// one", async () => {
    captureUpgrade();
    const fetchSpy = vi.fn(
      async () =>
        new Response(
          JSON.stringify({ access_token: "derived", expires_in: 3600 }),
          {
            status: 200,
          },
        ),
    ) as any;
    globalThis.fetch = fetchSpy;

    const t = new WsTransport("wss://app.datagrout.ai/servers/abc/mcp", {
      clientCredentials: { clientId: "id", clientSecret: "secret" },
    });

    await t.connect();
    await t.disconnect();

    // A ws:// token endpoint would be nonsense; the scheme has to map across.
    expect(String(fetchSpy.mock.calls[0][0])).toBe(
      "https://app.datagrout.ai/servers/abc/oauth/token",
    );
  });

  it("still carries a statically supplied bearer", async () => {
    captureUpgrade();
    const t = new WsTransport("wss://gateway.datagrout.ai/ws", {
      bearer: "static",
    });

    await t.connect();
    await t.disconnect();

    expect(captured?.["Authorization"]).toBe("Bearer static");
  });

  it("sends no Authorization header when there is no auth", async () => {
    captureUpgrade();
    const t = new WsTransport("wss://gateway.datagrout.ai/ws");

    await t.connect();
    await t.disconnect();

    expect(captured?.["Authorization"]).toBeUndefined();
  });
});
