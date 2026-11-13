/**
 * The WS transport against a real `wss://` server that demands a client
 * certificate — no stubs between the transport and the socket.
 *
 * The stub-based tests in `ws_mtls.test.ts` assert on the options object the
 * transport builds. They passed while the transport was broken, because on
 * Node 22+ it constructed Node's global WebSocket, which ignores that object:
 * no upgrade headers, no client certificate. Only a real handshake catches
 * that, so this one performs it, with the shared fixtures in `testdata/mtls`.
 */

import * as https from "node:https";
import { readFileSync } from "node:fs";
import { join } from "node:path";
import { TLSSocket } from "node:tls";
import type { AddressInfo } from "node:net";
import { describe, it, expect, afterEach } from "vitest";
import WebSocket, { WebSocketServer } from "ws";
import { WsTransport, resolveWebSocketImpl } from "../src/transports/ws";
import { ConduitIdentity, fetchWithIdentity } from "../src/identity";

const FIXTURES = join(__dirname, "..", "..", "testdata", "mtls");
const fixture = (name: string) => readFileSync(join(FIXTURES, name), "utf8");

interface Seen {
  peerCN?: string;
  authorization?: string;
}

let server: https.Server | undefined;

afterEach(async () => {
  await new Promise<void>((resolve) =>
    server ? server.close(() => resolve()) : resolve(),
  );
  server = undefined;
});

/** A loopback wss:// server that refuses any client without a CA-signed cert. */
async function startServer(): Promise<{ url: string; seen: Seen[] }> {
  const seen: Seen[] = [];
  server = https.createServer({
    cert: fixture("server.pem"),
    key: fixture("server-key.pem"),
    ca: fixture("ca.pem"),
    requestCert: true,
    rejectUnauthorized: true,
  });
  const wss = new WebSocketServer({ server });
  wss.on("connection", (socket, req) => {
    const peer = (req.socket as TLSSocket).getPeerCertificate();
    seen.push({
      peerCN: peer?.subject?.CN as string | undefined,
      authorization: req.headers["authorization"],
    });
    socket.on("error", () => {});
  });
  await new Promise<void>((resolve) => server!.listen(0, "127.0.0.1", resolve));
  const { port } = server!.address() as AddressInfo;
  return { url: `wss://localhost:${port}/ws`, seen };
}

describe("WS mTLS over a real loopback handshake", () => {
  it("presents the client certificate and the upgrade headers", async () => {
    const { url, seen } = await startServer();
    const identity = ConduitIdentity.fromPem(
      fixture("client.pem"),
      fixture("client-key.pem"),
      fixture("ca.pem"),
    );
    const t = new WsTransport(url, { bearer: "loopback" }, undefined, identity);

    await t.connect();
    await t.disconnect();

    expect(seen).toEqual([
      { peerCN: "conduit-sdk test client", authorization: "Bearer loopback" },
    ]);
  });

  it("cannot connect without an identity when the server demands one", async () => {
    const { url, seen } = await startServer();
    const t = new WsTransport(url, { bearer: "loopback" });

    // No identity means no client certificate and no fixture CA, so the
    // handshake fails either way; what matters is that it never completes.
    await expect(t.connect()).rejects.toThrow();
    expect(seen).toEqual([]);
  });

  it("uses the ws package under Node, not the global WebSocket", async () => {
    expect(await resolveWebSocketImpl()).toBe(WebSocket);
  });
});

describe("HTTP mTLS over a real loopback handshake", () => {
  it("fetchWithIdentity presents the certificate and trusts the identity's CA", async () => {
    server = https.createServer(
      {
        cert: fixture("server.pem"),
        key: fixture("server-key.pem"),
        ca: fixture("ca.pem"),
        requestCert: true,
        rejectUnauthorized: true,
      },
      (req, res) => {
        const peer = (req.socket as TLSSocket).getPeerCertificate();
        res.end(String(peer?.subject?.CN));
      },
    );
    await new Promise<void>((resolve) =>
      server!.listen(0, "127.0.0.1", resolve),
    );
    const { port } = server!.address() as AddressInfo;
    const identity = ConduitIdentity.fromPem(
      fixture("client.pem"),
      fixture("client-key.pem"),
      fixture("ca.pem"),
    );

    const res = await fetchWithIdentity(
      `https://localhost:${port}/`,
      {},
      identity,
    );

    expect(await res.text()).toBe("conduit-sdk test client");
  });
});
