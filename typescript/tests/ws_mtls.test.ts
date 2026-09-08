/**
 * The WebSocket handshake must present the mTLS identity.
 *
 * The HTTP transports route an identity through `fetchWithIdentity`; the WS
 * transport accepted the same identity and dropped it, so a `wss://` connection
 * presented no client certificate. These tests drive the real `connect()`
 * against a capturing WebSocket stub and assert on the options the `ws`
 * client is constructed with, because the bug lived in exactly that wiring.
 */

import { describe, it, expect, vi, afterEach } from "vitest";
import { WsTransport, buildTlsOptions } from "../src/transports/ws";
import { ConduitIdentity } from "../src/identity";

// Syntactically valid PEM blocks — the TLS stack is never reached here.
const CERT_PEM = `-----BEGIN CERTIFICATE-----
MIIBpTCCAQ6gAwIBAgIUZ2F0ZXdheS1jbGllbnQtMDAxMCAXDTI1MDEwMTAwMDAw
-----END CERTIFICATE-----
`;

const KEY_PEM = `-----BEGIN PRIVATE KEY-----
MIIEvQIBADANBgkqhkiG9w0BAQEFAASCBKcwggSjAgEAAoIBAQDZravCmUFAsXb1
-----END PRIVATE KEY-----
`;

const CA_PEM = `-----BEGIN CERTIFICATE-----
MIIBpzCCAQ+gAwIBAgIUWENnSElGTGgtY2EtMDAxIDAXDTI1MDEwMTAwMDAwMFoY
-----END CERTIFICATE-----
`;

/** Options seen by the most recent WebSocket construction. */
let captured: Record<string, unknown> | undefined;

const realWebSocket = globalThis.WebSocket;

/** Install a WebSocket stub that records its options and opens immediately. */
function captureOptions(): void {
  captured = undefined;
  class CapturingWebSocket {
    onopen: (() => void) | null = null;
    onmessage: ((ev: unknown) => void) | null = null;
    onerror: ((ev: unknown) => void) | null = null;
    onclose: (() => void) | null = null;

    constructor(
      _url: string,
      _protocols?: string[],
      options?: Record<string, unknown>,
    ) {
      captured = options;
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
  vi.restoreAllMocks();
});

describe("WS handshake mTLS", () => {
  it("presents cert and key when an identity is configured", async () => {
    captureOptions();
    const identity = ConduitIdentity.fromPem(CERT_PEM, KEY_PEM);
    const t = new WsTransport(
      "wss://gateway.datagrout.ai/ws",
      { bearer: "static" },
      undefined,
      identity,
    );

    await t.connect();
    await t.disconnect();

    expect(captured?.cert).toBe(CERT_PEM);
    expect(captured?.key).toBe(KEY_PEM);
    expect(captured?.ca).toBeUndefined();
    // The identity must not displace the upgrade headers.
    expect((captured?.headers as Record<string, string>)["Authorization"]).toBe(
      "Bearer static",
    );
  });

  it("also trusts the identity's CA when one is present", async () => {
    captureOptions();
    const identity = ConduitIdentity.fromPem(CERT_PEM, KEY_PEM, CA_PEM);
    const t = new WsTransport(
      "wss://gateway.datagrout.ai/ws",
      undefined,
      undefined,
      identity,
    );

    await t.connect();
    await t.disconnect();

    expect(captured?.cert).toBe(CERT_PEM);
    expect(captured?.key).toBe(KEY_PEM);
    expect(captured?.ca).toBe(CA_PEM);
  });

  it("passes no TLS options without an identity", async () => {
    captureOptions();
    const t = new WsTransport("wss://gateway.datagrout.ai/ws", {
      bearer: "static",
    });

    await t.connect();
    await t.disconnect();

    expect(captured).toBeDefined();
    expect(captured).not.toHaveProperty("cert");
    expect(captured).not.toHaveProperty("key");
    expect(captured).not.toHaveProperty("ca");
  });

  it("does not present a certificate on a plain ws:// connection", async () => {
    captureOptions();
    const identity = ConduitIdentity.fromPem(CERT_PEM, KEY_PEM, CA_PEM);
    const t = new WsTransport(
      "ws://localhost:4000/ws",
      undefined,
      undefined,
      identity,
    );

    await t.connect();
    await t.disconnect();

    expect(captured).not.toHaveProperty("cert");
    expect(captured).not.toHaveProperty("key");
    expect(captured).not.toHaveProperty("ca");
  });
});

describe("buildTlsOptions", () => {
  it("warns and returns nothing outside Node", () => {
    const warn = vi.spyOn(console, "warn").mockImplementation(() => {});
    const identity = ConduitIdentity.fromPem(CERT_PEM, KEY_PEM);

    // Simulate a runtime with no Node `process.versions`, as identity.ts does.
    const realProcess = globalThis.process;
    (globalThis as any).process = undefined;
    try {
      expect(
        buildTlsOptions("wss://gateway.datagrout.ai/ws", identity),
      ).toEqual({});
    } finally {
      (globalThis as any).process = realProcess;
    }

    expect(warn).toHaveBeenCalledOnce();
    expect(String(warn.mock.calls[0][0])).toMatch(/without mTLS/);
  });
});
