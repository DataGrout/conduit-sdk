/**
 * Tests for the loopback redirect listener.
 *
 * Ports the Rust reference suite. These bind real sockets on 127.0.0.1 and
 * drive them with real requests, because the failures worth catching here are
 * exactly the ones a mocked server cannot have: a port that will not re-bind, a
 * favicon request mistaken for the redirect, a response that never flushes.
 */

import { describe, it, expect } from "vitest";
import { LoopbackListener } from "../src/loopback";

describe("LoopbackListener", () => {
  it("binds a loopback port and reports it", async () => {
    const l = await LoopbackListener.bind();
    expect(l.port).toBeGreaterThan(0);
    expect(l.redirectUri).toBe(`http://127.0.0.1:${l.port}/callback`);
    l.close();
  });

  it("uses the literal address rather than localhost", async () => {
    // RFC 8252, and it avoids IPv6-vs-IPv4 resolution surprises.
    const l = await LoopbackListener.bind();
    expect(l.redirectUri).toContain("127.0.0.1");
    expect(l.redirectUri).not.toContain("localhost");
    l.close();
  });

  it("re-binds the exact port and path of a saved URI", async () => {
    // A saved client id is bound to its redirect URI exactly, so a later run
    // has to come back on the same port.
    const first = await LoopbackListener.bindOn(0, "/cb");
    const uri = first.redirectUri;
    const port = first.port;
    first.close();
    // Give the OS a moment to release the port.
    await new Promise((r) => setTimeout(r, 50));

    const again = await LoopbackListener.bindFor(uri);
    expect(again.port).toBe(port);
    expect(again.redirectUri).toBe(uri);
    again.close();
  });

  it("fails loudly when the port is taken", async () => {
    const held = await LoopbackListener.bind();
    // Better a clear failure the caller can answer by re-registering than
    // authorizing against a URI the server will reject.
    await expect(
      LoopbackListener.bindFor(held.redirectUri),
    ).rejects.toThrowError(/cannot bind loopback port/);
    held.close();
  });

  it("rejects a redirect URI with no port", async () => {
    await expect(
      LoopbackListener.bindFor("https://example.com/callback"),
    ).rejects.toThrowError(/names no port/);
  });

  it("normalises a path without a leading slash", async () => {
    const l = await LoopbackListener.bindOn(0, "cb");
    expect(l.redirectUri.endsWith("/cb")).toBe(true);
    l.close();
  });

  it("captures code and state from the redirect", async () => {
    const l = await LoopbackListener.bind();
    const waiting = l.wait(5000);

    const res = await fetch(`${l.redirectUri}?code=the_code&state=the_state`);
    expect(res.status).toBe(200);
    // The user sees an outcome rather than a browser error.
    expect(await res.text()).toContain("Signed in");

    await expect(waiting).resolves.toEqual({
      code: "the_code",
      state: "the_state",
    });
  });

  it("ignores a favicon request and keeps waiting", async () => {
    const l = await LoopbackListener.bind();
    const waiting = l.wait(5000);

    // A browser asks for this unprompted; treating it as the redirect would
    // abort the flow.
    const favicon = await fetch(`http://127.0.0.1:${l.port}/favicon.ico`);
    expect(favicon.status).toBe(404);

    await fetch(`${l.redirectUri}?code=c2&state=s2`);
    await expect(waiting).resolves.toMatchObject({ code: "c2" });
  });

  it("surfaces a denial as a typed error", async () => {
    const l = await LoopbackListener.bind();
    // Attach the assertions before triggering the redirect: the rejection can
    // land during the fetch, and a promise that rejects with no handler yet is
    // an unhandled rejection even though we go on to assert on it.
    const waiting = l.wait(5000);
    const assertions = Promise.all([
      expect(waiting).rejects.toThrowError(
        expect.objectContaining({ kind: "denied" }),
      ),
      expect(waiting).rejects.toThrowError(/access_denied — User said no/),
    ]);

    await fetch(
      `${l.redirectUri}?error=access_denied&error_description=User%20said%20no`,
    );
    await assertions;
  });

  it("rejects a redirect carrying neither an error nor a code", async () => {
    const l = await LoopbackListener.bind();
    const waiting = l.wait(5000);
    const assertion = expect(waiting).rejects.toThrowError(
      /neither an error nor a code/,
    );

    const res = await fetch(l.redirectUri);
    expect(res.status).toBe(400);
    await assertion;
  });

  it("times out when no redirect arrives", async () => {
    const l = await LoopbackListener.bind();
    await expect(l.wait(80)).rejects.toThrowError(/timed out/);
  });

  it("decodes percent escapes in the code and state", async () => {
    // Codes and state values are opaque and routinely contain characters that
    // must survive a round trip through the query string.
    const l = await LoopbackListener.bind();
    const waiting = l.wait(5000);

    await fetch(`${l.redirectUri}?code=a%2Fb&state=x%20y`);
    await expect(waiting).resolves.toEqual({ code: "a/b", state: "x y" });
  });
});
