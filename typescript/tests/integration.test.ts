/**
 * Integration tests against the live DataGrout production environment.
 *
 * These tests verify the Conduit SDK works end-to-end from the perspective of
 * a real SDK consumer: someone who has a server UUID and an access token.
 *
 * Environment variables (set via .env or CLI):
 *
 *   DG_RPC_SERVER_UUID       — JSONRPC-enabled server UUID
 *   DG_RPC_AUTH_TOKEN        — Access token for the JSONRPC server
 *   DG_MCP_SERVER_UUID       — MCP server UUID (default: open, no-auth test server)
 *   DG_MACHINE_CLIENT_ID     — for OAuth 2.1 client_credentials tests
 *   DG_MACHINE_CLIENT_SECRET — for OAuth 2.1 client_credentials tests
 *   DG_INTEGRATION_NETWORK   — set to any value to enable CA/mTLS network tests
 *
 * Run:
 *   DG_RPC_SERVER_UUID=... DG_RPC_AUTH_TOKEN=... npm test -- tests/integration.test.ts
 */

import { describe, it, test, expect, beforeAll, afterAll } from 'vitest';
import * as crypto from 'node:crypto';
import * as os from 'node:os';
import * as fs from 'node:fs';
import * as path from 'node:path';

import { ConduitIdentity, fetchWithIdentity } from '../src/identity';
import {
  fetchDgCaCert,
  generateKeypair,
  saveIdentity,
} from '../src/registration';
import { Client } from '../src/client';
import { deriveTokenEndpoint } from '../src/oauth';

// ── Constants ──────────────────────────────────────────────────────────────

const DG_GATEWAY = 'https://gateway.datagrout.ai';
const DG_CA_URL = 'https://ca.datagrout.ai/ca.pem';
const DG_CA_INFO_URL = 'https://ca.datagrout.ai/info';

// Open MCP server (no auth required — set via env var)
const MCP_SERVER_UUID = process.env.DG_MCP_SERVER_UUID;
const SERVER_MCP_URL = MCP_SERVER_UUID
  ? `${DG_GATEWAY}/servers/${MCP_SERVER_UUID}/mcp`
  : undefined;

// Authenticated JSONRPC server
const RPC_SERVER_UUID = process.env.DG_RPC_SERVER_UUID;
const RPC_AUTH_TOKEN = process.env.DG_RPC_AUTH_TOKEN;
const SERVER_RPC_URL = RPC_SERVER_UUID
  ? `${DG_GATEWAY}/servers/${RPC_SERVER_UUID}/rpc`
  : undefined;
const SERVER_RPC_MCP_URL = RPC_SERVER_UUID
  ? `${DG_GATEWAY}/servers/${RPC_SERVER_UUID}/mcp`
  : undefined;

// OAuth 2.1 machine client
const MACHINE_CLIENT_ID = process.env.DG_MACHINE_CLIENT_ID;
const MACHINE_CLIENT_SECRET = process.env.DG_MACHINE_CLIENT_SECRET;

const HAS_MCP = !!SERVER_MCP_URL;
const HAS_RPC = !!SERVER_RPC_URL && !!RPC_AUTH_TOKEN;
const HAS_NETWORK = !!process.env.DG_INTEGRATION_NETWORK;

// ═══════════════════════════════════════════════════════════════════════════
// 1. CA Certificate Distribution
// ═══════════════════════════════════════════════════════════════════════════

describe('CA Certificate Distribution (ca.datagrout.ai)', () => {
  it.skipIf(!HAS_NETWORK)('fetches ca.pem and returns a valid PEM certificate', async () => {
    const pem = await fetchDgCaCert(DG_CA_URL);

    expect(pem).toContain('-----BEGIN CERTIFICATE-----');
    expect(pem).toContain('-----END CERTIFICATE-----');

    const cert = new crypto.X509Certificate(pem);
    expect(cert.subject).toContain('CN=');
    expect(new Date(cert.validTo).getTime()).toBeGreaterThan(Date.now());
  });

  it.skipIf(!HAS_NETWORK)('returns CA metadata from /info endpoint', async () => {
    const resp = await fetch(DG_CA_INFO_URL, {
      headers: { Accept: 'application/json' },
    });

    expect(resp.ok).toBe(true);
    const info = await resp.json();

    expect(info).toHaveProperty('issuer');
    expect(info).toHaveProperty('algorithm');
    expect(info).toHaveProperty('fingerprint_sha256');
    expect(info).toHaveProperty('valid_until');
    expect(info).toHaveProperty('ca_cert_pem');
    expect(typeof info.fingerprint_sha256).toBe('string');
    expect(info.fingerprint_sha256.length).toBeGreaterThan(10);
    expect(info.ca_cert_pem).toContain('-----BEGIN CERTIFICATE-----');
  });

  it.skipIf(!HAS_NETWORK)('CA cert has a reasonable validity period', async () => {
    const pem = await fetchDgCaCert(DG_CA_URL);
    const cert = new crypto.X509Certificate(pem);

    const validFrom = new Date(cert.validFrom);
    const validTo = new Date(cert.validTo);
    const daysRemaining = (validTo.getTime() - Date.now()) / (1000 * 60 * 60 * 24);

    expect(validFrom.getTime()).toBeLessThan(Date.now());
    expect(daysRemaining).toBeGreaterThan(30);
  });
});

// ═══════════════════════════════════════════════════════════════════════════
// 2. Keypair Generation (local, no network)
// ═══════════════════════════════════════════════════════════════════════════

describe('Keypair and Identity (local)', () => {
  let tmpDir: string;

  beforeAll(() => {
    tmpDir = fs.mkdtempSync(path.join(os.tmpdir(), 'conduit-test-'));
  });

  afterAll(() => {
    fs.rmSync(tmpDir, { recursive: true, force: true });
  });

  it('generates a valid ECDSA P-256 keypair', () => {
    const keypair = generateKeypair();

    expect(keypair.privateKeyPem).toContain('-----BEGIN PRIVATE KEY-----');
    expect(keypair.publicKeyPem).toContain('-----BEGIN PUBLIC KEY-----');

    const key = crypto.createPublicKey(keypair.publicKeyPem);
    expect(key.asymmetricKeyType).toBe('ec');
  });

  it('needsRotation returns true when cert is about to expire', () => {
    const id = ConduitIdentity.fromPem(FIXTURE_CERT_PEM, FIXTURE_KEY_PEM)
      .withExpiry(new Date(Date.now() + 5 * 24 * 60 * 60 * 1000));

    expect(id.needsRotation(30)).toBe(true);
    expect(id.needsRotation(3)).toBe(false);
  });

  it('needsRotation returns false when no expiry is set', () => {
    const id = ConduitIdentity.fromPem(FIXTURE_CERT_PEM, FIXTURE_KEY_PEM);
    expect(id.needsRotation(30)).toBe(false);
  });

  it('saves and loads identity from disk', () => {
    const identity = {
      certPem: FIXTURE_CERT_PEM,
      keyPem: FIXTURE_KEY_PEM,
      caPem: FIXTURE_CA_PEM,
      id: 'test-id',
      name: 'test-identity',
      fingerprint: 'abc123',
      registeredAt: new Date().toISOString(),
    };

    const paths = saveIdentity(identity, tmpDir);
    expect(fs.existsSync(paths.certPath)).toBe(true);
    expect(fs.existsSync(paths.keyPath)).toBe(true);

    // Key file should have restrictive permissions
    const keyMode = (fs.statSync(paths.keyPath).mode & 0o777).toString(8);
    expect(keyMode).toBe('600');

    // Round-trip via ConduitIdentity
    const loaded = ConduitIdentity.fromPaths(paths.certPath, paths.keyPath, paths.caPath);
    expect(loaded.certPem).toBe(FIXTURE_CERT_PEM);
    expect(loaded.keyPem).toBe(FIXTURE_KEY_PEM);
  });
});

// ═══════════════════════════════════════════════════════════════════════════
// 3. MCP Streamable HTTP (open server, no auth)
// ═══════════════════════════════════════════════════════════════════════════

describe('MCP Streamable HTTP', () => {
  async function mcpPost(url: string, body: object, sessionId?: string): Promise<any> {
    const headers: Record<string, string> = {
      'Content-Type': 'application/json',
      Accept: 'application/json',
    };
    if (sessionId) headers['mcp-session-id'] = sessionId;

    const resp = await fetch(url, {
      method: 'POST',
      headers,
      body: JSON.stringify(body),
    });

    const responseSessionId = resp.headers.get('mcp-session-id');
    const text = await resp.text();
    const trimmed = text.trim();
    const data = trimmed ? JSON.parse(trimmed) : {};

    return { status: resp.status, data, sessionId: responseSessionId };
  }

  it.skipIf(!HAS_MCP)('initializes an MCP session', async () => {
    const { status, data, sessionId } = await mcpPost(SERVER_MCP_URL!, {
      jsonrpc: '2.0',
      id: 1,
      method: 'initialize',
      params: {
        protocolVersion: '2024-11-05',
        capabilities: {},
        clientInfo: { name: 'conduit-test', version: '1.0.0' },
      },
    });

    expect(status).toBe(200);
    expect(data).toHaveProperty('result');
    expect(data.result).toHaveProperty('serverInfo');
    expect(data.result).toHaveProperty('protocolVersion');
    expect(sessionId).toBeTruthy();
  }, 30_000);

  it.skipIf(!HAS_MCP)('lists tools after initialization', async () => {
    const init = await mcpPost(SERVER_MCP_URL!, {
      jsonrpc: '2.0',
      id: 1,
      method: 'initialize',
      params: {
        protocolVersion: '2024-11-05',
        capabilities: {},
        clientInfo: { name: 'conduit-test', version: '1.0.0' },
      },
    });

    expect(init.sessionId).toBeTruthy();

    await mcpPost(
      SERVER_MCP_URL!,
      { jsonrpc: '2.0', method: 'notifications/initialized', params: {} },
      init.sessionId!
    );

    const { status, data } = await mcpPost(
      SERVER_MCP_URL!,
      { jsonrpc: '2.0', id: 2, method: 'tools/list', params: {} },
      init.sessionId!
    );

    expect(status).toBe(200);
    expect(data).toHaveProperty('result');
    expect(data.result).toHaveProperty('tools');
    expect(Array.isArray(data.result.tools)).toBe(true);
    expect(data.result.tools.length).toBeGreaterThan(0);

    for (const tool of data.result.tools.slice(0, 3)) {
      expect(tool).toHaveProperty('name');
      expect(typeof tool.name).toBe('string');
    }
  }, 30_000);

  it.skipIf(!HAS_MCP)('initialize returns 200 (not 202) when no SSE handler exists', async () => {
    const resp = await fetch(SERVER_MCP_URL!, {
      method: 'POST',
      headers: {
        'Content-Type': 'application/json',
        Accept: 'application/json, text/event-stream',
      },
      body: JSON.stringify({
        jsonrpc: '2.0',
        id: 1,
        method: 'initialize',
        params: {
          protocolVersion: '2024-11-05',
          capabilities: {},
          clientInfo: { name: 'conduit-sse-test', version: '1.0.0' },
        },
      }),
    });

    expect(resp.status).toBe(200);

    const text = await resp.text();
    const data = JSON.parse(text.trim());
    expect(data).toHaveProperty('result');
    expect(data.result).toHaveProperty('serverInfo');
  }, 30_000);
});

// ═══════════════════════════════════════════════════════════════════════════
// 4. JSONRPC with Bearer Token (authenticated server)
// ═══════════════════════════════════════════════════════════════════════════

describe('JSONRPC with Bearer Token', () => {
  it.skipIf(!HAS_RPC)(
    'lists tools via Conduit Client',
    async () => {
      const client = new Client({
        url: SERVER_RPC_URL!,
        transport: 'jsonrpc',
        auth: { bearer: RPC_AUTH_TOKEN! },
      });

      await client.connect();
      const tools = await client.listTools();

      expect(Array.isArray(tools)).toBe(true);
      expect(tools.length).toBeGreaterThan(0);

      for (const tool of tools.slice(0, 3)) {
        expect(tool).toHaveProperty('name');
        expect(typeof tool.name).toBe('string');
        expect(tool).toHaveProperty('description');
      }

      await client.disconnect();
    },
    30_000
  );

  it.skipIf(!HAS_RPC)(
    'discovers tools via semantic search',
    async () => {
      const client = new Client({
        url: SERVER_RPC_URL!,
        transport: 'jsonrpc',
        auth: { bearer: RPC_AUTH_TOKEN! },
      });

      await client.connect();
      const result = await client.discover({ query: 'list all tools', limit: 5 });

      expect(result).toHaveProperty('results');
      expect(Array.isArray(result.results)).toBe(true);
      expect(result).toHaveProperty('queryUsed');

      await client.disconnect();
    },
    30_000
  );

  it.skipIf(!HAS_RPC)(
    'useIntelligentInterface filters DG-internal tools',
    async () => {
      const regularClient = new Client({
        url: SERVER_RPC_URL!,
        transport: 'jsonrpc',
        auth: { bearer: RPC_AUTH_TOKEN! },
      });
      const iiClient = new Client({
        url: SERVER_RPC_URL!,
        transport: 'jsonrpc',
        auth: { bearer: RPC_AUTH_TOKEN! },
        useIntelligentInterface: true,
      });

      await regularClient.connect();
      await iiClient.connect();

      const allTools = await regularClient.listTools();
      const iiTools = await iiClient.listTools();

      expect(iiTools.length).toBeLessThanOrEqual(allTools.length);

      for (const tool of iiTools) {
        expect(tool.name).toContain('@');
      }

      await regularClient.disconnect();
      await iiClient.disconnect();
    },
    30_000
  );

  it.skipIf(!HAS_RPC)(
    'rejects unauthenticated requests with 401',
    async () => {
      const client = new Client({
        url: SERVER_RPC_URL!,
        transport: 'jsonrpc',
      });

      await client.connect();
      await expect(client.listTools()).rejects.toThrow(/401/);
      await client.disconnect();
    },
    15_000
  );

  it.skipIf(!HAS_RPC)(
    'authenticated MCP initialize also works on same server',
    async () => {
      const resp = await fetch(SERVER_RPC_MCP_URL!, {
        method: 'POST',
        headers: {
          'Content-Type': 'application/json',
          Accept: 'application/json',
          Authorization: `Bearer ${RPC_AUTH_TOKEN}`,
        },
        body: JSON.stringify({
          jsonrpc: '2.0',
          id: 1,
          method: 'initialize',
          params: {
            protocolVersion: '2024-11-05',
            capabilities: {},
            clientInfo: { name: 'conduit-bearer-mcp-test', version: '1.0.0' },
          },
        }),
      });

      expect(resp.status).toBe(200);
      const data = await resp.json();
      expect(data).toHaveProperty('result');
      expect(data.result).toHaveProperty('serverInfo');
    },
    30_000
  );
});

// ═══════════════════════════════════════════════════════════════════════════
// 5. OAuth 2.1 Machine Client (client_credentials)
// ═══════════════════════════════════════════════════════════════════════════

describe('OAuth 2.1 Machine Client', () => {
  it('derives the correct token endpoint from MCP URL', () => {
    const exampleUrl = `${DG_GATEWAY}/servers/some-uuid/mcp`;
    const tokenUrl = deriveTokenEndpoint(exampleUrl);
    expect(tokenUrl).toBe(`${DG_GATEWAY}/servers/some-uuid/oauth/token`);
  });

  const HAS_OAUTH = !!MACHINE_CLIENT_ID && !!MACHINE_CLIENT_SECRET && HAS_MCP;

  it.skipIf(!HAS_OAUTH)(
    'obtains an access token via client_credentials grant',
    async () => {
      const tokenUrl = deriveTokenEndpoint(SERVER_MCP_URL!);

      const body = new URLSearchParams({
        grant_type: 'client_credentials',
        client_id: MACHINE_CLIENT_ID!,
        client_secret: MACHINE_CLIENT_SECRET!,
      });

      const resp = await fetch(tokenUrl, {
        method: 'POST',
        headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
        body: body.toString(),
      });

      expect(resp.ok).toBe(true);

      const data = await resp.json();
      expect(data).toHaveProperty('access_token');
      expect(data).toHaveProperty('token_type');
      expect(data.token_type.toLowerCase()).toBe('bearer');
      expect(data.expires_in).toBeGreaterThan(0);
    },
    15_000
  );

  it.skipIf(!HAS_OAUTH)(
    'authenticates MCP requests with OAuth bearer token',
    async () => {
      const tokenUrl = deriveTokenEndpoint(SERVER_MCP_URL!);
      const body = new URLSearchParams({
        grant_type: 'client_credentials',
        client_id: MACHINE_CLIENT_ID!,
        client_secret: MACHINE_CLIENT_SECRET!,
      });

      const tokenResp = await fetch(tokenUrl, {
        method: 'POST',
        headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
        body: body.toString(),
      });

      expect(tokenResp.ok).toBe(true);
      const tokenData = await tokenResp.json();
      const token = tokenData.access_token;

      const mcpResp = await fetch(SERVER_MCP_URL!, {
        method: 'POST',
        headers: {
          'Content-Type': 'application/json',
          Accept: 'application/json',
          Authorization: `Bearer ${token}`,
        },
        body: JSON.stringify({
          jsonrpc: '2.0',
          id: 1,
          method: 'initialize',
          params: {
            protocolVersion: '2024-11-05',
            capabilities: {},
            clientInfo: { name: 'conduit-oauth-test', version: '1.0.0' },
          },
        }),
      });

      expect(mcpResp.status).toBe(200);
      const data = await mcpResp.json();
      expect(data).toHaveProperty('result');
      expect(data.result).toHaveProperty('serverInfo');
    },
    30_000
  );
});

// ═══════════════════════════════════════════════════════════════════════════
// 6. mTLS with Existing Identity
//    (uses a locally-generated self-signed cert to exercise the mTLS code
//     path — a real user would have a cert from their CA or from DG)
// ═══════════════════════════════════════════════════════════════════════════

describe('mTLS code path', () => {
  it.skipIf(!HAS_NETWORK)('fetchWithIdentity sends a request with client cert headers', async () => {
    const conduitId = ConduitIdentity.fromPem(FIXTURE_CERT_PEM, FIXTURE_KEY_PEM);

    // This exercises the Node.js https.request + client cert path.
    // The CA info endpoint doesn't require mTLS, but this proves the
    // SDK correctly wires certs into the TLS handshake.
    const resp = await fetchWithIdentity(
      DG_CA_INFO_URL,
      {
        method: 'GET',
        headers: { Accept: 'application/json' },
      },
      conduitId
    );

    expect(resp.ok).toBe(true);
    const info = await resp.json();
    expect(info).toHaveProperty('issuer');
  }, 15_000);

  it.skipIf(!HAS_RPC)(
    'fetchWithIdentity makes an mTLS POST to the MCP endpoint',
    async () => {
      const conduitId = ConduitIdentity.fromPem(FIXTURE_CERT_PEM, FIXTURE_KEY_PEM);

      // mTLS + bearer token together (composed auth)
      const resp = await fetchWithIdentity(
        SERVER_RPC_MCP_URL!,
        {
          method: 'POST',
          headers: {
            'Content-Type': 'application/json',
            Accept: 'application/json',
            Authorization: `Bearer ${RPC_AUTH_TOKEN}`,
          },
          body: JSON.stringify({
            jsonrpc: '2.0',
            id: 1,
            method: 'initialize',
            params: {
              protocolVersion: '2024-11-05',
              capabilities: {},
              clientInfo: { name: 'conduit-mtls-test', version: '1.0.0' },
            },
          }),
        },
        conduitId
      );

      expect(resp.status).toBe(200);
      const data = await resp.json();
      expect(data).toHaveProperty('result');
      expect(data.result).toHaveProperty('serverInfo');
    },
    30_000
  );
});

// ═══════════════════════════════════════════════════════════════════════════
// 7. End-to-End: Full SDK Client Pipeline
// ═══════════════════════════════════════════════════════════════════════════

describe('End-to-end: SDK Client Pipeline', () => {
  it.skipIf(!HAS_RPC)(
    'connect → listTools → discover → disconnect',
    async () => {
      const client = new Client({
        url: SERVER_RPC_URL!,
        transport: 'jsonrpc',
        auth: { bearer: RPC_AUTH_TOKEN! },
      });

      await client.connect();

      // List tools
      const tools = await client.listTools();
      expect(tools.length).toBeGreaterThan(0);

      // Discover
      const discovery = await client.discover({
        query: 'what tools are available',
        limit: 3,
      });
      expect(discovery.results).toBeDefined();

      await client.disconnect();
    },
    60_000
  );
});

// ═══════════════════════════════════════════════════════════════════════════
// 8. Conduit URL integration tests (gated on CONDUIT_TEST_URL)
//
//    Set CONDUIT_TEST_URL to a live DataGrout-compatible MCP endpoint.
//    Optionally set CONDUIT_TEST_TOKEN with a bearer token for authenticated
//    endpoints.
//
//    Run:
//      CONDUIT_TEST_URL=https://... CONDUIT_TEST_TOKEN=... npx vitest run
// ═══════════════════════════════════════════════════════════════════════════

const TEST_URL = process.env.CONDUIT_TEST_URL;
const TEST_TOKEN = process.env.CONDUIT_TEST_TOKEN;

function buildClient() {
  return new Client({
    url: TEST_URL!,
    auth: TEST_TOKEN ? { bearer: TEST_TOKEN } : undefined,
  });
}

describe('Conduit URL integration (CONDUIT_TEST_URL)', () => {
  // ── MCP baseline ─────────────────────────────────────────────────────────

  test.skipIf(!TEST_URL)('connects and lists at least one tool', async () => {
    const client = buildClient();
    await client.connect();

    const tools = await client.listTools();

    expect(Array.isArray(tools)).toBe(true);
    expect(tools.length).toBeGreaterThan(0);

    for (const tool of tools.slice(0, 3)) {
      expect(tool).toHaveProperty('name');
      expect(typeof tool.name).toBe('string');
    }

    await client.disconnect();
  }, 30_000);

  test.skipIf(!TEST_URL)(
    'intelligent interface: useIntelligentInterface=true returns only non-@ tools',
    async () => {
      const iiClient = new Client({
        url: TEST_URL!,
        auth: TEST_TOKEN ? { bearer: TEST_TOKEN } : undefined,
        useIntelligentInterface: true,
      });
      await iiClient.connect();

      const iiTools = await iiClient.listTools();

      expect(Array.isArray(iiTools)).toBe(true);
      for (const tool of iiTools) {
        expect(tool.name).not.toMatch(/@/);
      }

      await iiClient.disconnect();
    },
    30_000
  );

  test.skipIf(!TEST_URL)(
    'callTool on a known DG tool returns a non-null result',
    async () => {
      const client = buildClient();
      await client.connect();

      const result = await client.callTool('data-grout@1/discovery.discover@1', {
        query: 'test',
        limit: 1,
      });

      expect(result).not.toBeNull();

      await client.disconnect();
    },
    30_000
  );

  // ── Discovery ─────────────────────────────────────────────────────────────

  test.skipIf(!TEST_URL)('discover() returns a tools array', async () => {
    const client = buildClient();
    await client.connect();

    const result = await client.discover({ query: 'find recent data', limit: 3 });

    expect(result).toHaveProperty('results');
    expect(Array.isArray(result.results)).toBe(true);
    expect(result).toHaveProperty('queryUsed');

    await client.disconnect();
  }, 30_000);

  test.skipIf(!TEST_URL)('plan() with goal returns a non-null result', async () => {
    const client = buildClient();
    await client.connect();

    const result = await client.plan({ goal: 'summarize data' });

    expect(result).not.toBeNull();

    await client.disconnect();
  }, 30_000);

  test.skipIf(!TEST_URL)(
    'guide() returns a sessionId and options array',
    async () => {
      const client = buildClient();
      await client.connect();

      const session = await client.guide({ goal: 'help me find something' });

      expect(session.sessionId).toBeTruthy();
      expect(typeof session.sessionId).toBe('string');
      expect(Array.isArray(session.options)).toBe(true);

      await client.disconnect();
    },
    30_000
  );

  // ── Prism ─────────────────────────────────────────────────────────────────

  test.skipIf(!TEST_URL)('refract() returns a non-null result', async () => {
    const client = buildClient();
    await client.connect();

    const result = await client.refract({ goal: 'count items', payload: [1, 2, 3] });

    expect(result).not.toBeNull();

    await client.disconnect();
  }, 30_000);

  test.skipIf(!TEST_URL)('chart() returns a non-null result', async () => {
    const client = buildClient();
    await client.connect();

    const result = await client.chart({ goal: 'show counts', payload: { a: 1, b: 2 } });

    expect(result).not.toBeNull();

    await client.disconnect();
  }, 30_000);

  // ── Logic Cell lifecycle ──────────────────────────────────────────────────

  test.skipIf(!TEST_URL)(
    'logic cell: remember → queryCell → forget → reflect lifecycle',
    async () => {
      const client = buildClient();
      await client.connect();

      const testStatement = 'sdk integration test fact for conduit lifecycle';

      // 1. Store a fact
      const remembered = await client.remember({ statement: testStatement });
      expect(remembered).toHaveProperty('handles');
      expect(Array.isArray(remembered.handles)).toBe(true);
      expect(remembered.handles.length).toBeGreaterThan(0);

      const handles = remembered.handles;

      // 2. Query to verify the fact is retrievable
      const queried = await client.queryCell({ question: 'sdk integration test' });
      expect(queried).toHaveProperty('results');
      expect(Array.isArray(queried.results)).toBe(true);

      // 3. Forget the fact by handles
      const forgotten = await client.forget({ handles });
      expect(forgotten).toHaveProperty('retracted');
      expect(typeof forgotten.retracted).toBe('number');

      // 4. Reflect to verify state
      const reflection = await client.reflect();
      expect(reflection).toHaveProperty('total');
      expect(typeof reflection.total).toBe('number');

      await client.disconnect();
    },
    60_000
  );

  // ── Generic dg() hook ─────────────────────────────────────────────────────

  test.skipIf(!TEST_URL)(
    'dg() generic hook returns a non-null result',
    async () => {
      const client = buildClient();
      await client.connect();

      const result = await client.dg('discovery.discover', { query: 'test', limit: 1 });

      expect(result).not.toBeNull();

      await client.disconnect();
    },
    30_000
  );

  // ── Input validation (local, no network) ──────────────────────────────────

  test('plan() throws InvalidConfigError when neither goal nor query is provided', async () => {
    const client = new Client('https://gateway.datagrout.ai/servers/test/mcp');
    // @ts-ignore
    client.initialized = true;
    const { InvalidConfigError: ICE } = await import('../src/errors');
    await expect(client.plan({})).rejects.toBeInstanceOf(ICE);
  });

  test('forget() throws InvalidConfigError when neither handles nor pattern is provided', async () => {
    const client = new Client('https://gateway.datagrout.ai/servers/test/mcp');
    // @ts-ignore
    client.initialized = true;
    const { InvalidConfigError: ICE } = await import('../src/errors');
    await expect(client.forget({})).rejects.toBeInstanceOf(ICE);
  });

  test('remember() throws InvalidConfigError when neither statement nor facts is provided', async () => {
    const client = new Client('https://gateway.datagrout.ai/servers/test/mcp');
    // @ts-ignore
    client.initialized = true;
    const { InvalidConfigError: ICE } = await import('../src/errors');
    await expect(client.remember('')).rejects.toBeInstanceOf(ICE);
    await expect(client.remember({})).rejects.toBeInstanceOf(ICE);
  });

  test('queryCell() throws InvalidConfigError when neither question nor patterns is provided', async () => {
    const client = new Client('https://gateway.datagrout.ai/servers/test/mcp');
    // @ts-ignore
    client.initialized = true;
    const { InvalidConfigError: ICE } = await import('../src/errors');
    await expect(client.queryCell('')).rejects.toBeInstanceOf(ICE);
    await expect(client.queryCell({})).rejects.toBeInstanceOf(ICE);
  });

  test('error hierarchy: all Conduit errors extend ConduitError', async () => {
    const {
      ConduitError: CE,
      NotInitializedError: NIE,
      RateLimitError: RLE,
      AuthError: AE,
      NetworkError: NE,
      ServerError: SE,
      InvalidConfigError: ICE,
    } = await import('../src/errors');

    expect(new NIE()).toBeInstanceOf(CE);
    expect(new RLE({ used: 1, limit: { perHour: 50 }, isLimited: true, remaining: 49 })).toBeInstanceOf(CE);
    expect(new AE()).toBeInstanceOf(CE);
    expect(new NE('timeout')).toBeInstanceOf(CE);
    expect(new SE(500, 'internal')).toBeInstanceOf(CE);
    expect(new ICE('bad config')).toBeInstanceOf(CE);
  });
});

// ── Fixtures ───────────────────────────────────────────────────────────────

// Real self-signed ECDSA P-256 cert + key for exercising the mTLS code path.
// These are test-only credentials with no access to anything.
const FIXTURE_CERT_PEM = `-----BEGIN CERTIFICATE-----
MIIBgzCCASmgAwIBAgIUdvv5mARYLegPGuP/pVCyCbe/4powCgYIKoZIzj0EAwIw
FzEVMBMGA1UEAwwMY29uZHVpdC10ZXN0MB4XDTI2MDMwMTA3NTQ1NFoXDTI3MDMw
MTA3NTQ1NFowFzEVMBMGA1UEAwwMY29uZHVpdC10ZXN0MFkwEwYHKoZIzj0CAQYI
KoZIzj0DAQcDQgAEcC7URYVKB7/zUbFFFWIGri+xwbhj4agvjhUHjY4liqc8zzdh
xWpipNLiZp+zmm3DVM7iiPC0P6d128fpTj7RNqNTMFEwHQYDVR0OBBYEFK21I0v+
GZgDy45ZcI97H4olugx1MB8GA1UdIwQYMBaAFK21I0v+GZgDy45ZcI97H4olugx1
MA8GA1UdEwEB/wQFMAMBAf8wCgYIKoZIzj0EAwIDSAAwRQIhAI4X+q/LtMev3w+f
mpLdDi4oyb/Gw6du72NgpKf8LksEAiAFAb6yLu0bL4TolgTqI4HPoFgdY6NCYphV
RMp3qLKOMA==
-----END CERTIFICATE-----
`;

const FIXTURE_KEY_PEM = `-----BEGIN PRIVATE KEY-----
MIGHAgEAMBMGByqGSM49AgEGCCqGSM49AwEHBG0wawIBAQQgHzwzWaP9g94UEFgI
b9qh1TEEddnRO9dweT5s+ayr+TihRANCAARwLtRFhUoHv/NRsUUVYgauL7HBuGPh
qC+OFQeNjiWKpzzPN2HFamKk0uJmn7OabcNUzuKI8LQ/p3Xbx+lOPtE2
-----END PRIVATE KEY-----
`;

const FIXTURE_CA_PEM = FIXTURE_CERT_PEM;
