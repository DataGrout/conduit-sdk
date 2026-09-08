/**
 * The cross-language contract, checked against the shared fixture.
 *
 * Every other test in this suite round-trips a grant through this SDK's own
 * serializer, which passes even if a field name is wrong — as long as it is
 * consistently wrong. These load `testdata/contract.json`, the same bytes every
 * language checks, so a grant written here is provably readable elsewhere.
 *
 * See `testdata/README.md`.
 */

import { describe, it, expect } from "vitest";
import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { dirname, join } from "node:path";

import {
  DEFAULT_SCOPE,
  type AuthCodeErrorKind,
  type Grant,
  type RegisteredClient,
} from "../src/index";

const here = dirname(fileURLToPath(import.meta.url));
const contract = JSON.parse(
  readFileSync(join(here, "..", "..", "testdata", "contract.json"), "utf8"),
) as {
  default_scope: string;
  error_kinds: string[];
  grant: Record<string, unknown>;
  grant_minimal: Record<string, unknown>;
  registered_client: Record<string, unknown>;
};

describe("cross-language contract", () => {
  it("loads a grant written elsewhere, field for field", () => {
    // Read explicitly rather than by round-trip: a misnamed field would be
    // undefined, and a round-trip alone would not notice.
    const grant = contract.grant as unknown as Grant;

    expect(grant.access_token).toBe("at_contract_fixture");
    expect(grant.refresh_token).toBe("rt_contract_fixture");
    expect(grant.expires_at).toBe(1700000000);
    expect(grant.client_id).toBe("client_contract_fixture");
    expect(grant.token_endpoint).toBe(
      "https://gateway.example.com/oauth/token",
    );
    expect(grant.scope).toBe("mcp tools");
    expect(grant.resource).toBe("https://gateway.example.com/connect");
  });

  it("writes a grant byte-identical to the contract", () => {
    // The object literal is typed, so a renamed interface field fails to
    // compile here before it ever fails the assertion.
    const grant: Grant = {
      access_token: "at_contract_fixture",
      refresh_token: "rt_contract_fixture",
      expires_at: 1700000000,
      client_id: "client_contract_fixture",
      token_endpoint: "https://gateway.example.com/oauth/token",
      scope: "mcp tools",
      resource: "https://gateway.example.com/connect",
    };

    expect(JSON.parse(JSON.stringify(grant))).toEqual(contract.grant);
  });

  it("omits absent optionals rather than nulling them", () => {
    const minimal: Grant = {
      access_token: "at_minimal_fixture",
      client_id: "client_minimal_fixture",
      token_endpoint: "https://gateway.example.com/oauth/token",
    };

    expect(JSON.parse(JSON.stringify(minimal))).toEqual(contract.grant_minimal);
  });

  it("round-trips a registered client as one unit", () => {
    const client: RegisteredClient = {
      client_id: "client_contract_fixture",
      redirect_uri: "http://127.0.0.1:8765/callback",
    };

    expect(JSON.parse(JSON.stringify(client))).toEqual(
      contract.registered_client,
    );
  });

  it("uses the contract's default scope", () => {
    expect(DEFAULT_SCOPE).toBe(contract.default_scope);
  });

  it("defines exactly the contract's error taxonomy", () => {
    // An exhaustive Record: adding a kind to the union without adding it here
    // fails to compile, and a key that is not in the union fails too. The
    // assertion then ties both to the shared fixture.
    const kinds: Record<AuthCodeErrorKind, true> = {
      discovery: true,
      no_registration_endpoint: true,
      registration_rejected: true,
      no_client_id: true,
      pkce_unsupported: true,
      state_mismatch: true,
      token_exchange: true,
      not_refreshable: true,
      denied: true,
      http: true,
    };

    expect(Object.keys(kinds).sort()).toEqual([...contract.error_kinds].sort());
  });
});
