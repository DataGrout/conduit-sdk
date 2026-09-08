/**
 * Tests for the OAuth 2.1 authorization-code + PKCE flow.
 *
 * Ports the Rust reference suite: the same invariants, checked the same way, so
 * a behaviour that drifts in one language fails in the other.
 */

import { describe, it, expect, vi } from "vitest";
import {
  AuthCodeError,
  AuthCodeFlow,
  AuthCodeProvider,
  DEFAULT_SCOPE,
  authCodeProviderFrom,
  challengeS256,
  generateVerifier,
  isGrantExpired,
  isGrantRefreshable,
  refreshGrant,
  supportsS256,
  urlencode,
  originOf,
  type AuthServerMetadata,
  type Grant,
} from "../src/authcode";

const METADATA: AuthServerMetadata = {
  issuer: "https://gateway.datagrout.ai",
  authorization_endpoint: "https://gateway.datagrout.ai/oauth/authorize",
  token_endpoint: "https://gateway.datagrout.ai/oauth/token",
  registration_endpoint: "https://gateway.datagrout.ai/register",
  code_challenge_methods_supported: ["S256"],
  grant_types_supported: ["authorization_code", "refresh_token"],
};

const RESOURCE = "https://gateway.datagrout.ai/connect";

/**
 * A flow standing where `discover` would leave it, without network access.
 *
 * `discover` is the only constructor, so this drives it with a fetch that
 * serves the metadata and then restores the registered-client state.
 */
async function flow(
  overrides: Partial<AuthServerMetadata> = {},
): Promise<AuthCodeFlow> {
  const metadata = { ...METADATA, ...overrides };
  const fetchImpl = vi.fn(async (url: any) => {
    const href = String(url);
    if (href.includes("oauth-protected-resource")) {
      return new Response("not found", { status: 404 });
    }
    return new Response(JSON.stringify(metadata), {
      status: 200,
      headers: { "content-type": "application/json" },
    });
  }) as any;

  const f = await AuthCodeFlow.discover(RESOURCE, fetchImpl);
  return f.withClientId("client_abc", "http://127.0.0.1:8765/callback");
}

function grant(expiresAt?: number, refresh?: string): Grant {
  return {
    access_token: "at",
    refresh_token: refresh,
    expires_at: expiresAt,
    client_id: "client_abc",
    token_endpoint: "https://gateway.datagrout.ai/oauth/token",
  };
}

const nowSecs = () => Math.floor(Date.now() / 1000);

// ─── PKCE ─────────────────────────────────────────────────────────────────────

describe("PKCE", () => {
  it("produces a verifier meeting RFC 7636 length and alphabet", () => {
    const v = generateVerifier();
    expect(v.length).toBe(43); // 32 bytes of base64url
    expect(v.length).toBeGreaterThanOrEqual(43);
    expect(v.length).toBeLessThanOrEqual(128);
    expect(/^[A-Za-z0-9\-._~]+$/.test(v)).toBe(true);
  });

  it("produces unique verifiers", () => {
    expect(generateVerifier()).not.toBe(generateVerifier());
  });

  it("matches the RFC 7636 appendix B test vector", () => {
    expect(challengeS256("dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk")).toBe(
      "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM",
    );
  });

  it("emits an unpadded url-safe challenge", () => {
    const c = challengeS256("anything");
    expect(c).not.toContain("=");
    expect(c).not.toContain("+");
    expect(c).not.toContain("/");
  });
});

// ─── authorize URL ────────────────────────────────────────────────────────────

describe("authorizeUrl", () => {
  it("carries every required parameter", async () => {
    const { url, pending } = (await flow()).authorizeUrl();

    expect(
      url.startsWith("https://gateway.datagrout.ai/oauth/authorize?"),
    ).toBe(true);
    expect(url).toContain("response_type=code");
    expect(url).toContain("client_id=client_abc");
    expect(url).toContain("code_challenge_method=S256");
    expect(url).toContain(`state=${urlencode(pending.state)}`);
    expect(url).toContain(
      `code_challenge=${challengeS256(pending.codeVerifier)}`,
    );
    // The challenge travels; the verifier never does.
    expect(url).not.toContain(pending.codeVerifier);
  });

  it("percent-encodes the redirect and resource", async () => {
    const { url } = (await flow()).authorizeUrl();
    expect(url).toContain(
      "redirect_uri=http%3A%2F%2F127.0.0.1%3A8765%2Fcallback",
    );
    expect(url).toContain(
      "resource=https%3A%2F%2Fgateway.datagrout.ai%2Fconnect",
    );
  });

  it("binds the token to the resource (RFC 8707)", async () => {
    const { url } = (await flow()).authorizeUrl();
    expect(url).toContain("resource=");
  });

  it("requires a client id", async () => {
    const f = await flow();
    // A flow that never registered has no id to authorize with.
    const bare = Object.create(Object.getPrototypeOf(f));
    Object.assign(bare, f, {
      clientIdValue: undefined,
      redirectUriValue: undefined,
    });
    expect(() => bare.authorizeUrl()).toThrowError(
      expect.objectContaining({ kind: "no_client_id" }),
    );
  });

  it("appends when the endpoint already has a query", async () => {
    const f = await flow({
      authorization_endpoint: "https://example.com/authorize?foo=1",
    });
    const { url } = f.authorizeUrl();
    expect(url).toContain("/authorize?foo=1&response_type=code");
  });

  it("requests the default scope", async () => {
    const { url } = (await flow()).authorizeUrl();
    expect(url).toContain(`scope=${urlencode(DEFAULT_SCOPE)}`);
  });
});

// ─── state / CSRF ─────────────────────────────────────────────────────────────

describe("exchange", () => {
  it("refuses a mismatched state", async () => {
    const f = await flow();
    const { pending } = f.authorizeUrl();
    await expect(
      f.exchange(pending, "the_code", "not_the_state"),
    ).rejects.toThrowError(expect.objectContaining({ kind: "state_mismatch" }));
  });

  it("refuses an empty state", async () => {
    const f = await flow();
    const { pending } = f.authorizeUrl();
    await expect(f.exchange(pending, "code", "")).rejects.toThrowError(
      expect.objectContaining({ kind: "state_mismatch" }),
    );
  });

  it("sends the verifier and resource, and returns a persistable grant", async () => {
    const metadata = METADATA;
    let body = "";
    const fetchImpl = vi.fn(async (url: any, init?: any) => {
      const href = String(url);
      if (href.includes("oauth-protected-resource")) {
        return new Response("nope", { status: 404 });
      }
      if (href.includes(".well-known")) {
        return new Response(JSON.stringify(metadata), { status: 200 });
      }
      body = String(init?.body ?? "");
      return new Response(
        JSON.stringify({
          access_token: "new_at",
          refresh_token: "new_rt",
          expires_in: 3600,
          scope: "mcp tools",
        }),
        { status: 200 },
      );
    }) as any;

    const f = (await AuthCodeFlow.discover(RESOURCE, fetchImpl)).withClientId(
      "client_abc",
      "http://127.0.0.1:8765/callback",
    );
    const { pending } = f.authorizeUrl();
    const g = await f.exchange(pending, "the_code", pending.state);

    expect(body).toContain("grant_type=authorization_code");
    expect(body).toContain(`code_verifier=${pending.codeVerifier}`);
    expect(body).toContain(
      "resource=https%3A%2F%2Fgateway.datagrout.ai%2Fconnect",
    );
    expect(g.access_token).toBe("new_at");
    expect(g.refresh_token).toBe("new_rt");
    expect(g.client_id).toBe("client_abc");
    expect(g.resource).toBe(RESOURCE);
    expect(g.expires_at).toBeGreaterThan(nowSecs());
  });

  it("reports a rejected exchange with its status and body", async () => {
    const fetchImpl = vi.fn(async (url: any) => {
      const href = String(url);
      if (href.includes("oauth-protected-resource")) {
        return new Response("nope", { status: 404 });
      }
      if (href.includes(".well-known")) {
        return new Response(JSON.stringify(METADATA), { status: 200 });
      }
      return new Response('{"error":"invalid_grant"}', { status: 400 });
    }) as any;

    const f = (await AuthCodeFlow.discover(RESOURCE, fetchImpl)).withClientId(
      "c",
      "http://127.0.0.1:1/cb",
    );
    const { pending } = f.authorizeUrl();

    await expect(
      f.exchange(pending, "code", pending.state),
    ).rejects.toThrowError(
      expect.objectContaining({ kind: "token_exchange", status: 400 }),
    );
  });
});

// ─── Grant ────────────────────────────────────────────────────────────────────

describe("Grant", () => {
  it("treats a grant with no stated expiry as live", () => {
    expect(isGrantExpired(grant())).toBe(false);
  });

  it("expires early by the refresh skew", () => {
    // Expires in 30s, skew is 60s → already due.
    expect(isGrantExpired(grant(nowSecs() + 30, "rt"))).toBe(true);
    expect(isGrantExpired(grant(nowSecs() + 600, "rt"))).toBe(false);
  });

  it("refuses to refresh without a refresh token", async () => {
    await expect(refreshGrant(grant(0))).rejects.toThrowError(
      expect.objectContaining({ kind: "not_refreshable" }),
    );
  });

  it("keeps the old refresh token when the server does not rotate", async () => {
    const fetchImpl = vi.fn(
      async () =>
        new Response(JSON.stringify({ access_token: "at2", expires_in: 60 }), {
          status: 200,
        }),
    ) as any;

    const refreshed = await refreshGrant(grant(0, "original_rt"), fetchImpl);
    expect(refreshed.access_token).toBe("at2");
    // Silently dropping it would make the grant unrefreshable from here on.
    expect(refreshed.refresh_token).toBe("original_rt");
  });

  it("round-trips through JSON with the cross-language field names", () => {
    const g = grant(1_800_000_000, "rt");
    const json = JSON.parse(JSON.stringify(g));

    expect(json.access_token).toBe("at");
    expect(json.refresh_token).toBe("rt");
    expect(json.expires_at).toBe(1_800_000_000);
    expect(json.client_id).toBe("client_abc");
    expect(typeof json.token_endpoint).toBe("string");
  });

  it("omits absent optionals when serialized", () => {
    const json = JSON.parse(JSON.stringify(grant()));
    expect("refresh_token" in json).toBe(false);
    expect("expires_at" in json).toBe(false);
  });

  it("reads a minimal payload", () => {
    const g = JSON.parse(
      '{"access_token":"at","client_id":"c","token_endpoint":"https://e/t"}',
    ) as Grant;
    expect(isGrantRefreshable(g)).toBe(false);
    expect(isGrantExpired(g)).toBe(false);
  });
});

// ─── provider ─────────────────────────────────────────────────────────────────

describe("AuthCodeProvider", () => {
  it("returns a live token without refreshing", async () => {
    const fetchImpl = vi.fn() as any;
    const p = new AuthCodeProvider(grant(nowSecs() + 3600, "rt"), fetchImpl);
    expect(await p.getToken()).toBe("at");
    expect(fetchImpl).not.toHaveBeenCalled();
    expect(p.isDirty()).toBe(false);
  });

  it("refreshes an expired token and marks itself dirty", async () => {
    const fetchImpl = vi.fn(
      async () =>
        new Response(
          JSON.stringify({
            access_token: "fresh",
            refresh_token: "rt2",
            expires_in: 3600,
          }),
          { status: 200 },
        ),
    ) as any;

    const p = new AuthCodeProvider(grant(nowSecs() - 10, "rt"), fetchImpl);
    expect(await p.getToken()).toBe("fresh");
    expect(p.isDirty()).toBe(true);

    // A rotated refresh token must reach the application, or the stored grant
    // goes stale and eventually invalidates the family.
    const taken = p.takeIfDirty();
    expect(taken?.refresh_token).toBe("rt2");
    expect(p.takeIfDirty()).toBeNull();
  });

  it("de-duplicates concurrent refreshes", async () => {
    const fetchImpl = vi.fn(
      async () =>
        new Response(
          JSON.stringify({ access_token: "fresh", expires_in: 3600 }),
          {
            status: 200,
          },
        ),
    ) as any;

    const p = new AuthCodeProvider(grant(nowSecs() - 10, "rt"), fetchImpl);
    const [a, b] = await Promise.all([p.getToken(), p.getToken()]);
    expect(a).toBe("fresh");
    expect(b).toBe("fresh");
    expect(fetchImpl).toHaveBeenCalledTimes(1);
  });

  it("invalidate forces the next fetch to refresh", async () => {
    const p = new AuthCodeProvider(grant(nowSecs() + 3600), vi.fn() as any);
    p.invalidate();
    // No refresh token, so the forced refresh surfaces rather than silently
    // returning the stale token.
    await expect(p.getToken()).rejects.toThrowError(
      expect.objectContaining({ kind: "not_refreshable" }),
    );
  });

  it("takeIfDirty is empty until something changes", () => {
    const p = new AuthCodeProvider(grant(nowSecs() + 3600, "rt"));
    expect(p.takeIfDirty()).toBeNull();
  });
});

describe("authCodeProviderFrom", () => {
  it("wraps a bare grant and passes a provider through untouched", () => {
    expect(authCodeProviderFrom(undefined)).toBeUndefined();
    expect(authCodeProviderFrom(grant())).toBeInstanceOf(AuthCodeProvider);

    const mine = new AuthCodeProvider(grant());
    // Identity matters: the caller polls their own provider for a rotated grant.
    expect(authCodeProviderFrom(mine)).toBe(mine);
  });
});

// ─── metadata / discovery ─────────────────────────────────────────────────────

describe("metadata", () => {
  it("assumes S256 when the server does not advertise", () => {
    expect(
      supportsS256({ ...METADATA, code_challenge_methods_supported: [] }),
    ).toBe(true);
    expect(
      supportsS256({
        authorization_endpoint: "a",
        token_endpoint: "t",
      }),
    ).toBe(true);
  });

  it("refuses a server advertising only plain", () => {
    expect(
      supportsS256({
        ...METADATA,
        code_challenge_methods_supported: ["plain"],
      }),
    ).toBe(false);
  });

  it("refuses to downgrade during discovery", async () => {
    const fetchImpl = vi.fn(async (url: any) => {
      if (String(url).includes("oauth-protected-resource")) {
        return new Response("nope", { status: 404 });
      }
      return new Response(
        JSON.stringify({
          ...METADATA,
          code_challenge_methods_supported: ["plain"],
        }),
        { status: 200 },
      );
    }) as any;

    await expect(
      AuthCodeFlow.discover(RESOURCE, fetchImpl),
    ).rejects.toThrowError(
      expect.objectContaining({ kind: "pkce_unsupported" }),
    );
  });

  it("follows protected-resource metadata to the authorization server", async () => {
    const seen: string[] = [];
    const fetchImpl = vi.fn(async (url: any) => {
      const href = String(url);
      seen.push(href);
      if (href.includes("oauth-protected-resource")) {
        return new Response(
          JSON.stringify({ authorization_servers: ["https://as.example.com"] }),
          { status: 200 },
        );
      }
      return new Response(JSON.stringify(METADATA), { status: 200 });
    }) as any;

    await AuthCodeFlow.discover(RESOURCE, fetchImpl);
    expect(
      seen.some((u) => u.startsWith("https://as.example.com/.well-known/")),
    ).toBe(true);
  });

  it("reports discovery failure when no metadata is found", async () => {
    const fetchImpl = vi.fn(
      async () => new Response("nope", { status: 404 }),
    ) as any;
    await expect(
      AuthCodeFlow.discover(RESOURCE, fetchImpl),
    ).rejects.toThrowError(expect.objectContaining({ kind: "discovery" }));
  });

  it("registers as a public client and returns the id paired with its URI", async () => {
    let registrationBody: any;
    const fetchImpl = vi.fn(async (url: any, init?: any) => {
      const href = String(url);
      if (href.includes("oauth-protected-resource")) {
        return new Response("nope", { status: 404 });
      }
      if (href.includes(".well-known")) {
        return new Response(JSON.stringify(METADATA), { status: 200 });
      }
      registrationBody = JSON.parse(String(init?.body ?? "{}"));
      return new Response(JSON.stringify({ client_id: "issued_id" }), {
        status: 201,
      });
    }) as any;

    const f = await AuthCodeFlow.discover(RESOURCE, fetchImpl);
    const client = await f.register("My App", "http://127.0.0.1:9/cb");

    // A desktop app cannot keep a secret; PKCE stands in for one.
    expect(registrationBody.token_endpoint_auth_method).toBe("none");
    expect(registrationBody.redirect_uris).toEqual(["http://127.0.0.1:9/cb"]);
    expect(registrationBody.grant_types).toContain("refresh_token");
    expect(client).toEqual({
      client_id: "issued_id",
      redirect_uri: "http://127.0.0.1:9/cb",
    });
  });

  it("reports a missing registration endpoint distinctly", async () => {
    const f = await flow({ registration_endpoint: undefined });
    await expect(
      f.register("App", "http://127.0.0.1:9/cb"),
    ).rejects.toThrowError(
      expect.objectContaining({ kind: "no_registration_endpoint" }),
    );
  });

  it("restores both halves of a saved registration", async () => {
    // Reusing an id against a different redirect URI is rejected by the server,
    // so the pair must survive together.
    const f = (await flow()).withRegisteredClient({
      client_id: "saved_id",
      redirect_uri: "http://127.0.0.1:9999/cb",
    });

    expect(f.clientId).toBe("saved_id");
    expect(f.redirectUri).toBe("http://127.0.0.1:9999/cb");

    const { url } = f.authorizeUrl();
    expect(url).toContain("client_id=saved_id");
    expect(url).toContain("redirect_uri=http%3A%2F%2F127.0.0.1%3A9999%2Fcb");
  });
});

// ─── helpers ──────────────────────────────────────────────────────────────────

describe("helpers", () => {
  it("escapes structure characters when encoding", () => {
    expect(urlencode("a b")).toBe("a%20b");
    expect(urlencode("http://x/y")).toBe("http%3A%2F%2Fx%2Fy");
    expect(urlencode("safe-._~")).toBe("safe-._~");
  });

  it("strips paths and keeps ports when taking an origin", () => {
    expect(originOf("https://gateway.datagrout.ai/connect")).toBe(
      "https://gateway.datagrout.ai",
    );
    expect(originOf("http://localhost:4000/servers/abc/mcp")).toBe(
      "http://localhost:4000",
    );
    expect(originOf("not a url")).toBeUndefined();
  });

  it("uses the authorization server’s own default scope", () => {
    // Inventing finer-grained scopes is worse than useless: the server splits
    // on whitespace and stores what it is handed.
    expect(DEFAULT_SCOPE).toBe("mcp tools");
  });

  it("tags every error with a kind from the shared taxonomy", () => {
    const e = new AuthCodeError(
      "denied",
      "authorization denied: access_denied",
    );
    expect(e).toBeInstanceOf(Error);
    expect(e.kind).toBe("denied");
    expect(e.name).toBe("AuthCodeError");
  });
});
