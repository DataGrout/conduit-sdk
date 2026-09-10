/**
 * Tests for RFC 8693 delegation — an agent acting *for* a user.
 *
 * Ports the Rust reference suite (`rust/src/delegation.rs`): the same
 * invariants, checked the same way, so a behaviour that drifts in one language
 * fails in the other. The wire-level cases inject a `fetchImpl` rather than
 * standing up a server, as the authorization-code tests do; the WebSocket case
 * drives the real `connect()` against a capturing `WebSocket` stub, because the
 * bearer has to be resolved before the handshake and a mocked transport would
 * skip exactly that wiring.
 */

import { describe, it, expect, vi, afterEach } from "vitest";
import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { dirname, join } from "node:path";
import { inspect } from "node:util";

import {
  DelegatedProvider,
  DelegationError,
  DelegationRequest,
  GRANT_TYPE,
  SERVER_ERROR_CODES,
  TOKEN_TYPES,
  TokenSource,
  isDelegatedTokenExpired,
  tokenTypeName,
  type DelegatedToken,
  type DelegationErrorKind,
  type ServerErrorCode,
} from "../src/delegation";
import { OAuthTokenProvider } from "../src/oauth";
import { AuthCodeProvider, type FetchLike, type Grant } from "../src/authcode";
import { WsTransport } from "../src/transports/ws";
import { JSONRPCTransport } from "../src/transports/jsonrpc";

const ENDPOINT = "https://as.example.com/oauth/token";

const SUCCESS_BODY = JSON.stringify({
  access_token: "delegated_at",
  issued_token_type: TOKEN_TYPES.access_token,
  token_type: "Bearer",
  expires_in: 900,
  scope: "mcp tools",
});

const nowSecs = () => Math.floor(Date.now() / 1000);

/** A request with both tokens set, as the Rust suite's `request()` helper. */
function request(endpoint = ENDPOINT): DelegationRequest {
  return new DelegationRequest(endpoint, "agent_client")
    .clientSecret("agent_secret")
    .subjectToken("user_at", TOKEN_TYPES.access_token)
    .actorToken("agent_at", TOKEN_TYPES.access_token);
}

/** A fetch that answers every call with the same status and body. */
function serving(body: string, status = 200) {
  return vi.fn(
    async (_url: string | URL | Request, _init?: RequestInit) =>
      new Response(body, { status }),
  );
}

const asFetch = (spy: unknown) => spy as unknown as FetchLike;

/** The form fields of the most recent POST, in the order they were sent. */
function sentForm(spy: { mock: { calls: any[][] } }, call = 0): string[][] {
  const init = spy.mock.calls[call][1] as { body: string };
  return [...new URLSearchParams(init.body).entries()].map(([k, v]) => [k, v]);
}

const realWebSocket = globalThis.WebSocket;
const realFetch = globalThis.fetch;

afterEach(() => {
  (globalThis as any).WebSocket = realWebSocket;
  globalThis.fetch = realFetch;
});

// ─── Token types ─────────────────────────────────────────────────────────────

describe("token types", () => {
  it("round-trips through their URNs", () => {
    for (const [name, urn] of Object.entries(TOKEN_TYPES)) {
      expect(urn.startsWith("urn:ietf:params:oauth:token-type:")).toBe(true);
      expect(tokenTypeName(urn)).toBe(name);
    }
  });

  it("carries a URN it does not name as the open other case", () => {
    // A token type *is* its URN, so an unknown one survives verbatim.
    expect(tokenTypeName("urn:example:custom")).toBe("other");
    const req = new DelegationRequest(ENDPOINT, "c")
      .subjectToken("t", "urn:example:custom")
      .impersonation();
    expect(req.formParams()).toContainEqual([
      "subject_token_type",
      "urn:example:custom",
    ]);
  });

  it("pins the grant type", () => {
    expect(GRANT_TYPE).toBe("urn:ietf:params:oauth:grant-type:token-exchange");
  });
});

// ─── Form body ───────────────────────────────────────────────────────────────

describe("form body", () => {
  it("carries exactly the expected fields in wire order", () => {
    const form = request()
      .audience("https://gateway.example.com")
      .resource("https://gateway.example.com/connect")
      .scope("mcp tools")
      .requestedTokenType(TOKEN_TYPES.access_token)
      .formParams();

    expect(form).toEqual([
      ["grant_type", GRANT_TYPE],
      ["subject_token", "user_at"],
      ["subject_token_type", TOKEN_TYPES.access_token],
      ["actor_token", "agent_at"],
      ["actor_token_type", TOKEN_TYPES.access_token],
      ["client_id", "agent_client"],
      ["client_secret", "agent_secret"],
      ["audience", "https://gateway.example.com"],
      ["resource", "https://gateway.example.com/connect"],
      ["scope", "mcp tools"],
      ["requested_token_type", TOKEN_TYPES.access_token],
    ]);
  });

  it("omits optionals that were not set", () => {
    const keys = request()
      .formParams()
      .map(([k]) => k);
    for (const absent of [
      "audience",
      "resource",
      "scope",
      "requested_token_type",
    ]) {
      expect(keys).not.toContain(absent);
    }
  });

  it("sends resource whenever it is set", () => {
    // RFC 8707 — the same invariant the authorization-code module keeps.
    const form = request()
      .resource("https://gateway.example.com/connect")
      .formParams();
    expect(form).toContainEqual([
      "resource",
      "https://gateway.example.com/connect",
    ]);
  });

  it("keeps the secret out of the body under basic auth", () => {
    const form = request().clientAuth("basic").formParams();
    expect(form.map(([k]) => k)).not.toContain("client_secret");
    // client_id still travels in the body.
    expect(form).toContainEqual(["client_id", "agent_client"]);
  });

  it("accepts a JWT subject", () => {
    const form = new DelegationRequest(ENDPOINT, "c")
      .subjectToken("eyJ", TOKEN_TYPES.jwt)
      .actorToken("agent_at")
      .formParams();
    expect(form).toContainEqual(["subject_token_type", TOKEN_TYPES.jwt]);
  });

  it("is unaffected by cloning the template", () => {
    const template = request().resource("https://gateway.example.com/connect");
    const clone = template.clone().subjectToken("other_user");
    expect(clone.formParams()).toContainEqual(["subject_token", "other_user"]);
    expect(template.formParams()).toContainEqual(["subject_token", "user_at"]);
  });
});

// ─── Refusals before any HTTP ────────────────────────────────────────────────

describe("refusals before any request is sent", () => {
  it("refuses a missing actor without touching the network", async () => {
    const never = serving(SUCCESS_BODY);
    const exchange = new DelegationRequest(ENDPOINT, "c")
      .subjectToken("user_at")
      .exchange(asFetch(never));

    await expect(exchange).rejects.toMatchObject({ kind: "missing_actor" });
    expect(never).not.toHaveBeenCalled();
  });

  it("refuses a missing subject without touching the network", async () => {
    const never = serving(SUCCESS_BODY);
    const exchange = new DelegationRequest(ENDPOINT, "c")
      .actorToken("agent_at")
      .exchange(asFetch(never));

    await expect(exchange).rejects.toMatchObject({ kind: "missing_subject" });
    expect(never).not.toHaveBeenCalled();
  });

  it("makes impersonation the only way to omit the actor", () => {
    const form = new DelegationRequest(ENDPOINT, "c")
      .subjectToken("user_at")
      .impersonation()
      .formParams();
    expect(
      form.map(([k]) => k).filter((k) => k.startsWith("actor_token")),
    ).toEqual([]);
  });

  it("throws a DelegationError, catchable as one", () => {
    let caught: unknown;
    try {
      new DelegationRequest(ENDPOINT, "c").formParams();
    } catch (err) {
      caught = err;
    }
    expect(caught).toBeInstanceOf(DelegationError);
    expect((caught as DelegationError).kind).toBe("missing_subject");
  });
});

// ─── The wire ────────────────────────────────────────────────────────────────

describe("exchange", () => {
  it("posts a form-encoded body with the actor fields", async () => {
    const fetchImpl = serving(SUCCESS_BODY);
    const issued = await request()
      .resource("https://gateway.example.com/connect")
      .exchange(asFetch(fetchImpl));

    expect(issued.access_token).toBe("delegated_at");
    expect(fetchImpl).toHaveBeenCalledTimes(1);

    const [url, init] = fetchImpl.mock.calls[0] as [string, any];
    expect(url).toBe(ENDPOINT);
    expect(init.method).toBe("POST");
    expect(init.headers["Content-Type"]).toBe(
      "application/x-www-form-urlencoded",
    );
    expect(sentForm(fetchImpl)).toEqual([
      ["grant_type", GRANT_TYPE],
      ["subject_token", "user_at"],
      ["subject_token_type", TOKEN_TYPES.access_token],
      ["actor_token", "agent_at"],
      ["actor_token_type", TOKEN_TYPES.access_token],
      ["client_id", "agent_client"],
      ["client_secret", "agent_secret"],
      ["resource", "https://gateway.example.com/connect"],
    ]);
  });

  it("sends basic client auth when asked", async () => {
    const fetchImpl = serving(SUCCESS_BODY);
    await request().clientAuth("basic").exchange(asFetch(fetchImpl));

    const expected = Buffer.from("agent_client:agent_secret").toString(
      "base64",
    );
    const init = fetchImpl.mock.calls[0][1] as any;
    expect(init.headers["Authorization"]).toBe(`Basic ${expected}`);
  });

  it("sends no Authorization header under body client auth", async () => {
    const fetchImpl = serving(SUCCESS_BODY);
    await request().exchange(asFetch(fetchImpl));
    const init = fetchImpl.mock.calls[0][1] as any;
    expect(init.headers["Authorization"]).toBeUndefined();
  });

  it("turns a success response into a token with an absolute expiry", async () => {
    const before = nowSecs();
    const issued = await request().exchange(asFetch(serving(SUCCESS_BODY)));
    const after = nowSecs();

    expect(issued.access_token).toBe("delegated_at");
    expect(issued.issued_token_type).toBe(TOKEN_TYPES.access_token);
    expect(issued.token_type).toBe("Bearer");
    expect(issued.scope).toBe("mcp tools");

    // expires_at = now + expires_in, in seconds, allowing for the clock
    // ticking during the request.
    expect(issued.expires_at).toBeGreaterThanOrEqual(before + 900);
    expect(issued.expires_at).toBeLessThanOrEqual(after + 900);
    expect(isDelegatedTokenExpired(issued)).toBe(false);
  });

  it("reads an RFC 6749 error body as a server error with code and status", async () => {
    const fetchImpl = serving(
      JSON.stringify({
        error: "invalid_target",
        error_description: "unknown resource",
      }),
      400,
    );

    await expect(request().exchange(asFetch(fetchImpl))).rejects.toMatchObject({
      kind: "server",
      status: 400,
      error: "invalid_target",
      errorDescription: "unknown resource",
    });
  });

  it("reads a failure without an OAuth body as an invalid response", async () => {
    const fetchImpl = serving("<html>bad gateway</html>", 502);
    const failure = request().exchange(asFetch(fetchImpl));

    await expect(failure).rejects.toMatchObject({ kind: "invalid_response" });
    await expect(failure).rejects.toThrow("502");
  });

  it("reads a 2xx missing issued_token_type as an invalid response", async () => {
    // RFC 8693 §2.2.1 makes the field REQUIRED; a server that drops it is out
    // of contract, and guessing would hide that.
    const fetchImpl = serving(
      JSON.stringify({ access_token: "x", token_type: "Bearer" }),
    );
    await expect(request().exchange(asFetch(fetchImpl))).rejects.toMatchObject({
      kind: "invalid_response",
    });
  });

  it("reads a 2xx missing token_type as an invalid response", async () => {
    const fetchImpl = serving(
      JSON.stringify({
        access_token: "x",
        issued_token_type: TOKEN_TYPES.access_token,
      }),
    );
    await expect(request().exchange(asFetch(fetchImpl))).rejects.toMatchObject({
      kind: "invalid_response",
    });
  });

  it("reads a 2xx that is not JSON as an invalid response", async () => {
    const fetchImpl = serving("not json at all");
    await expect(request().exchange(asFetch(fetchImpl))).rejects.toMatchObject({
      kind: "invalid_response",
    });
  });

  it("reports a transport failure as an http error", async () => {
    const fetchImpl = vi.fn(async () => {
      throw new Error("ECONNREFUSED");
    });
    await expect(request().exchange(asFetch(fetchImpl))).rejects.toMatchObject({
      kind: "http",
    });
  });

  it("omits the expiry when the server states none", async () => {
    const fetchImpl = serving(
      JSON.stringify({
        access_token: "x",
        issued_token_type: TOKEN_TYPES.access_token,
        token_type: "Bearer",
      }),
    );
    const issued = await request().exchange(asFetch(fetchImpl));
    expect(issued.expires_at).toBeUndefined();
    expect(isDelegatedTokenExpired(issued)).toBe(false);
  });
});

// ─── Token ───────────────────────────────────────────────────────────────────

describe("delegated token", () => {
  const token = (expiresAt?: number): DelegatedToken => ({
    access_token: "delegated_at",
    issued_token_type: TOKEN_TYPES.access_token,
    token_type: "Bearer",
    ...(expiresAt === undefined ? {} : { expires_at: expiresAt }),
  });

  it("treats a token with no stated expiry as live", () => {
    expect(isDelegatedTokenExpired(token())).toBe(false);
  });

  it("expires early by the refresh skew", () => {
    expect(isDelegatedTokenExpired(token(nowSecs() + 30))).toBe(true);
    expect(isDelegatedTokenExpired(token(nowSecs() + 600))).toBe(false);
  });

  it("omits absent optionals when serialized", () => {
    const json = JSON.parse(JSON.stringify(token()));
    expect("expires_at" in json).toBe(false);
    expect("scope" in json).toBe(false);
    expect(json.issued_token_type).toBe(TOKEN_TYPES.access_token);
  });
});

// ─── Provider ────────────────────────────────────────────────────────────────

describe("delegated provider", () => {
  const provider = (fetchImpl: unknown, endpoint = ENDPOINT) =>
    new DelegatedProvider(
      new DelegationRequest(endpoint, "agent_client").clientSecret(
        "agent_secret",
      ),
      TokenSource.staticToken("user_at", TOKEN_TYPES.access_token),
      TokenSource.staticToken("agent_at", TOKEN_TYPES.access_token),
      asFetch(fetchImpl),
    );

  it("exchanges once and serves from cache until expiry", async () => {
    const fetchImpl = serving(SUCCESS_BODY);
    const p = provider(fetchImpl);

    expect(await p.getToken()).toBe("delegated_at");
    expect(await p.getToken()).toBe("delegated_at");
    expect(await p.getToken()).toBe("delegated_at");

    expect(fetchImpl).toHaveBeenCalledTimes(1);
    expect(p.token()?.access_token).toBe("delegated_at");
  });

  it("re-exchanges after invalidate", async () => {
    const fetchImpl = serving(SUCCESS_BODY);
    const p = provider(fetchImpl);

    await p.getToken();
    p.invalidate();
    expect(p.token()).toBeUndefined();
    await p.getToken();

    expect(fetchImpl).toHaveBeenCalledTimes(2);
  });

  it("re-exchanges a token that is inside the skew", async () => {
    // Expires in 30s: already inside the 60s buffer, so the second call must
    // exchange again rather than serve it.
    const fetchImpl = serving(
      JSON.stringify({
        access_token: "short",
        issued_token_type: TOKEN_TYPES.access_token,
        token_type: "Bearer",
        expires_in: 30,
      }),
    );
    const p = provider(fetchImpl);

    await p.getToken();
    await p.getToken();
    expect(fetchImpl).toHaveBeenCalledTimes(2);
  });

  it("pulls fresh upstream tokens on every exchange", async () => {
    const fetchImpl = serving(SUCCESS_BODY);
    let n = 0;
    const p = new DelegatedProvider(
      new DelegationRequest(ENDPOINT, "agent_client"),
      TokenSource.dynamic(() => `user_${++n}`),
      TokenSource.staticToken("agent_at"),
      asFetch(fetchImpl),
    );

    await p.getToken();
    p.invalidate();
    await p.getToken();

    expect(sentForm(fetchImpl, 0)).toContainEqual(["subject_token", "user_1"]);
    expect(sentForm(fetchImpl, 1)).toContainEqual(["subject_token", "user_2"]);
  });

  it("uses a client_credentials actor", async () => {
    // The agent's own grant first, then the exchange carrying it. The
    // client-credentials provider talks through the global fetch, so both legs
    // are served from one stub.
    const calls: string[] = [];
    globalThis.fetch = vi.fn(async (url: any) => {
      calls.push(String(url));
      if (String(url).endsWith("/agent/token")) {
        return new Response(
          JSON.stringify({
            access_token: "agent_live",
            token_type: "Bearer",
            expires_in: 3600,
          }),
          { status: 200 },
        );
      }
      return new Response(SUCCESS_BODY, { status: 200 });
    }) as any;

    const actor = new OAuthTokenProvider({
      clientId: "agent_client",
      clientSecret: "agent_secret",
      tokenEndpoint: "https://as.example.com/agent/token",
    });
    const p = new DelegatedProvider(
      new DelegationRequest(ENDPOINT, "agent_client").clientSecret(
        "agent_secret",
      ),
      TokenSource.staticToken("user_at"),
      TokenSource.clientCredentials(actor),
    );

    expect(await p.getToken()).toBe("delegated_at");
    expect(calls).toEqual(["https://as.example.com/agent/token", ENDPOINT]);
    const exchangeCall = (globalThis.fetch as any).mock.calls[1][1];
    expect([
      ...new URLSearchParams(exchangeCall.body).entries(),
    ]).toContainEqual(["actor_token", "agent_live"]);
  });

  it("uses an authorization-code subject", async () => {
    const fetchImpl = serving(SUCCESS_BODY);
    const grant: Grant = {
      access_token: "user_live",
      expires_at: nowSecs() + 3600,
      client_id: "client_abc",
      token_endpoint: "https://as.example.com/oauth/token",
    };
    const p = new DelegatedProvider(
      new DelegationRequest(ENDPOINT, "agent_client"),
      TokenSource.authorizationCode(new AuthCodeProvider(grant)),
      TokenSource.staticToken("agent_at"),
      asFetch(fetchImpl),
    );

    await p.getToken();
    expect(sentForm(fetchImpl)).toContainEqual(["subject_token", "user_live"]);
  });

  it("declares a different token type when asked", async () => {
    const fetchImpl = serving(SUCCESS_BODY);
    const p = new DelegatedProvider(
      new DelegationRequest(ENDPOINT, "agent_client"),
      TokenSource.staticToken("eyJ").withTokenType(TOKEN_TYPES.jwt),
      TokenSource.staticToken("agent_at"),
      asFetch(fetchImpl),
    );

    await p.getToken();
    expect(sentForm(fetchImpl)).toContainEqual([
      "subject_token_type",
      TOKEN_TYPES.jwt,
    ]);
  });

  it("fails loudly without an actor unless impersonating", async () => {
    const never = serving(SUCCESS_BODY);
    const p = new DelegatedProvider(
      new DelegationRequest(ENDPOINT, "c"),
      TokenSource.staticToken("user_at"),
      undefined,
      asFetch(never),
    );

    const call = p.getToken();
    await expect(call).rejects.toMatchObject({ kind: "missing_actor" });
    await expect(call).rejects.toThrow("actor_token");
    expect(never).not.toHaveBeenCalled();
  });

  it("exchanges without an actor once impersonation is explicit", async () => {
    const fetchImpl = serving(SUCCESS_BODY);
    const p = new DelegatedProvider(
      new DelegationRequest(ENDPOINT, "c").impersonation(),
      TokenSource.staticToken("user_at"),
      undefined,
      asFetch(fetchImpl),
    );

    expect(await p.getToken()).toBe("delegated_at");
    expect(sentForm(fetchImpl).map(([k]) => k)).not.toContain("actor_token");
  });

  it("single-flights concurrent callers", async () => {
    // A slow endpoint, so the other callers are reliably queued behind the
    // leader rather than racing it.
    const fetchImpl = vi.fn(async () => {
      await new Promise((resolve) => setTimeout(resolve, 50));
      return new Response(SUCCESS_BODY, { status: 200 });
    });
    const p = provider(fetchImpl);

    const tokens = await Promise.all(
      Array.from({ length: 5 }, () => p.getToken()),
    );

    expect(tokens).toEqual(Array(5).fill("delegated_at"));
    expect(fetchImpl).toHaveBeenCalledTimes(1);
  });

  it("lets a failed exchange be retried rather than latching", async () => {
    const fetchImpl = vi
      .fn()
      .mockResolvedValueOnce(new Response("nope", { status: 500 }))
      .mockResolvedValueOnce(new Response(SUCCESS_BODY, { status: 200 }));
    const p = provider(fetchImpl);

    await expect(p.getToken()).rejects.toBeInstanceOf(DelegationError);
    expect(await p.getToken()).toBe("delegated_at");
  });

  it("never prints tokens or the client secret", () => {
    const p = provider(serving(SUCCESS_BODY));
    for (const rendered of [
      inspect(p),
      JSON.stringify(p),
      inspect(p, { depth: 5 }),
    ]) {
      expect(rendered).not.toContain("agent_secret");
      expect(rendered).not.toContain("user_at");
      expect(rendered).not.toContain("agent_at");
    }
    expect(inspect(p)).toContain("agent_client");
  });

  it("never prints the token a source holds", () => {
    const source = TokenSource.staticToken("very_secret_token");
    expect(inspect(source)).not.toContain("very_secret_token");
    expect(JSON.stringify(source)).not.toContain("very_secret_token");
    expect(inspect(source)).toContain("static");
  });

  it("exposes the request template without tokens", () => {
    const p = provider(serving(SUCCESS_BODY));
    expect(p.request.tokenEndpoint).toBe(ENDPOINT);
    expect(p.request.clientId).toBe("agent_client");
    expect(p.request.isImpersonation).toBe(false);
  });
});

// ─── Transports ──────────────────────────────────────────────────────────────

/** Headers seen by the most recent WebSocket construction. */
let capturedUpgrade: Record<string, string> | undefined;

/** Install a WebSocket stub that records its options and opens immediately. */
function captureUpgrade(): void {
  capturedUpgrade = undefined;
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
      capturedUpgrade = options?.headers;
      setTimeout(() => this.onopen?.(), 0);
    }

    send(): void {}
    close(): void {}
    ping(): void {}
  }
  (globalThis as any).WebSocket = CapturingWebSocket;
}

describe("transport wiring", () => {
  const delegated = (fetchImpl: unknown) =>
    new DelegatedProvider(
      new DelegationRequest(ENDPOINT, "agent_client").clientSecret(
        "agent_secret",
      ),
      TokenSource.staticToken("user_at"),
      TokenSource.staticToken("agent_at"),
      asFetch(fetchImpl),
    );

  it("carries the exchanged bearer on the WebSocket upgrade", async () => {
    captureUpgrade();
    const exchange = serving(SUCCESS_BODY);
    const t = new WsTransport("wss://gateway.datagrout.ai/ws", {
      delegation: delegated(exchange),
    });

    await t.connect();
    await t.disconnect();

    // Resolved before the handshake, or it could never reach the upgrade.
    expect(capturedUpgrade?.["Authorization"]).toBe("Bearer delegated_at");
    expect(exchange).toHaveBeenCalledTimes(1);
  });

  it("carries the exchanged bearer on an HTTP call", async () => {
    const exchange = serving(SUCCESS_BODY);
    globalThis.fetch = vi.fn(
      async () =>
        new Response(JSON.stringify({ jsonrpc: "2.0", id: 1, result: {} }), {
          status: 200,
        }),
    ) as any;

    const t = new JSONRPCTransport("https://gateway.datagrout.ai/rpc", {
      delegation: delegated(exchange),
    });
    await t.listTools();

    const init = (globalThis.fetch as any).mock.calls[0][1];
    expect(init.headers["Authorization"]).toBe("Bearer delegated_at");
  });

  it("re-exchanges once on a 401 and retries", async () => {
    let issued = 0;
    const exchange = vi.fn(
      async () =>
        new Response(
          SUCCESS_BODY.replace("delegated_at", `delegated_${++issued}`),
          {
            status: 200,
          },
        ),
    );
    const bearers: string[] = [];
    globalThis.fetch = vi.fn(async (_url: any, init: any) => {
      bearers.push(init.headers["Authorization"]);
      return bearers.length === 1
        ? new Response("", { status: 401 })
        : new Response(JSON.stringify({ jsonrpc: "2.0", id: 1, result: {} }), {
            status: 200,
          });
    }) as any;

    const t = new JSONRPCTransport("https://gateway.datagrout.ai/rpc", {
      delegation: delegated(exchange),
    });
    await t.listTools();

    expect(bearers).toEqual(["Bearer delegated_1", "Bearer delegated_2"]);
    expect(exchange).toHaveBeenCalledTimes(2);
  });
});

// ─────────────────────────────────────────────────────────────────────────────
// Cross-language contract
//
// `testdata/contract.json` holds the delegation fixture every language SDK
// checks: the grant type, the token-type URNs, the exact form body a fixture
// request must produce, the issued-token shape, the error kinds and the server
// error codes. See `testdata/README.md`.
// ─────────────────────────────────────────────────────────────────────────────

const here = dirname(fileURLToPath(import.meta.url));
const contract = (
  JSON.parse(
    readFileSync(join(here, "..", "..", "testdata", "contract.json"), "utf8"),
  ) as {
    delegation: {
      grant_type: string;
      token_types: Record<string, string>;
      request: Record<string, string>;
      request_form: Array<[string, string]>;
      token: Record<string, unknown>;
      token_minimal: Record<string, unknown>;
      wire_response: Record<string, unknown>;
      error_kinds: string[];
      server_error_codes: string[];
    };
  }
).delegation;

describe("cross-language contract", () => {
  it("pins the grant type", () => {
    expect(GRANT_TYPE).toBe(contract.grant_type);
  });

  it("pins the token-type URNs", () => {
    expect(TOKEN_TYPES).toEqual(contract.token_types);
  });

  it("produces exactly the fixture form from the fixture request", () => {
    // The request fixture is what a port builds; `request_form` is the body it
    // must post, field for field and in order.
    const r = contract.request;
    const built = new DelegationRequest(r.token_endpoint, r.client_id)
      .clientSecret(r.client_secret)
      .subjectToken(r.subject_token, r.subject_token_type)
      .actorToken(r.actor_token, r.actor_token_type)
      .audience(r.audience)
      .resource(r.resource)
      .scope(r.scope)
      .requestedTokenType(r.requested_token_type);

    expect(built.formParams()).toEqual(contract.request_form);
  });

  it("emits that form on the wire, in the fixture's order", async () => {
    const r = contract.request;
    const fetchImpl = serving(SUCCESS_BODY);
    await new DelegationRequest(r.token_endpoint, r.client_id)
      .clientSecret(r.client_secret)
      .subjectToken(r.subject_token, r.subject_token_type)
      .actorToken(r.actor_token, r.actor_token_type)
      .audience(r.audience)
      .resource(r.resource)
      .scope(r.scope)
      .requestedTokenType(r.requested_token_type)
      .exchange(asFetch(fetchImpl));

    expect(sentForm(fetchImpl)).toEqual(contract.request_form);
  });

  it("loads a token written elsewhere, field for field", () => {
    // Read explicitly rather than by round-trip: a misnamed field would be
    // undefined, and a round-trip alone would not notice.
    const token = contract.token as unknown as DelegatedToken;
    expect(token.access_token).toBe("delegated_contract_fixture");
    expect(token.issued_token_type).toBe(TOKEN_TYPES.access_token);
    expect(token.token_type).toBe("Bearer");
    expect(token.expires_at).toBe(1700000000);
    expect(token.scope).toBe("mcp tools");
  });

  it("writes a token byte-identical to the contract", () => {
    // The object literal is typed, so a renamed interface field fails to
    // compile here before it ever fails the assertion.
    const token: DelegatedToken = {
      access_token: "delegated_contract_fixture",
      issued_token_type: TOKEN_TYPES.access_token,
      token_type: "Bearer",
      expires_at: 1700000000,
      scope: "mcp tools",
    };
    expect(JSON.parse(JSON.stringify(token))).toEqual(contract.token);
  });

  it("omits absent optionals rather than nulling them", () => {
    const minimal: DelegatedToken = {
      access_token: "delegated_minimal_fixture",
      issued_token_type: TOKEN_TYPES.access_token,
      token_type: "Bearer",
    };
    // Not `"scope": null` — another SDK reading this must see absence.
    expect(JSON.parse(JSON.stringify(minimal))).toEqual(contract.token_minimal);
    expect(isDelegatedTokenExpired(minimal)).toBe(false);
  });

  it("parses the fixture wire response into the fixture token", async () => {
    // The server's relative `expires_in` becomes an absolute `expires_at`;
    // everything else copies across unchanged.
    const before = nowSecs();
    const issued = await request().exchange(
      asFetch(serving(JSON.stringify(contract.wire_response))),
    );
    const expected = contract.token as unknown as DelegatedToken;

    expect(issued.access_token).toBe(expected.access_token);
    expect(issued.issued_token_type).toBe(expected.issued_token_type);
    expect(issued.token_type).toBe(expected.token_type);
    expect(issued.scope).toBe(expected.scope);
    expect(issued.expires_at).toBeGreaterThanOrEqual(
      before + (contract.wire_response.expires_in as number),
    );
  });

  it("defines exactly the contract's error taxonomy", () => {
    // An exhaustive Record: adding a kind to the union without adding it here
    // fails to compile, and a key that is not in the union fails too.
    const kinds: Record<DelegationErrorKind, true> = {
      missing_subject: true,
      missing_actor: true,
      http: true,
      server: true,
      invalid_response: true,
    };
    expect(Object.keys(kinds).sort()).toEqual([...contract.error_kinds].sort());
  });

  it("reaches the package entry point under a delegation-scoped name", async () => {
    // "token exchange" already means the client-credentials grant here, so the
    // grant type and error codes are namespaced on the way out rather than
    // exported as bare `GRANT_TYPE`.
    const pkg = await import("../src/index");
    expect(pkg.DELEGATION_GRANT_TYPE).toBe(contract.grant_type);
    expect([...pkg.DELEGATION_SERVER_ERROR_CODES]).toEqual([
      ...SERVER_ERROR_CODES,
    ]);
    expect(pkg.TOKEN_TYPES).toEqual(contract.token_types);
    expect(pkg.DelegationRequest).toBe(DelegationRequest);
    expect(pkg.DelegatedProvider).toBe(DelegatedProvider);
    expect(pkg.TokenSource).toBe(TokenSource);
    expect(pkg.DelegationError).toBe(DelegationError);
    expect(pkg.isDelegatedTokenExpired).toBe(isDelegatedTokenExpired);
    expect(pkg.tokenTypeName).toBe(tokenTypeName);
  });

  it("defines exactly the contract's server error codes", () => {
    expect([...SERVER_ERROR_CODES].sort()).toEqual(
      [...contract.server_error_codes].sort(),
    );
    // The union is the list, so a typo'd code does not type-check.
    const target: ServerErrorCode = "invalid_target";
    expect(SERVER_ERROR_CODES).toContain(target);
  });
});
