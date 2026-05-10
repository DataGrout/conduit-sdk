/**
 * Tests for the autonomous agent onramp flow.
 */

import { describe, it, expect, vi, beforeEach, afterEach } from 'vitest';
import {
  registerOnly,
  registerAndExchange,
  _doRegister,
  _exchangeToken,
  type OnrampOptions,
  type OnrampCredentials,
} from '../src/onramp';

// ─── Fixtures ──────────────────────────────────────────────────────────────────

const INIT_RESPONSE = { session_token: 'sess_abc123' };

const COMPLETE_RESPONSE = {
  client_id: 'agt_abc123',
  client_secret: 'sk_xyz789',
  token_url: 'https://app.datagrout.ai/servers/abc/oauth/token',
  mcp_url: 'https://app.datagrout.ai/servers/abc/mcp',
  rpc_url: 'https://app.datagrout.ai/servers/abc/rpc',
  scopes: ['mcp:read', 'tools:call'],
  expires_in: 2592000,
};

const TOKEN_RESPONSE = { access_token: 'tok_live123' };

const DEFAULT_OPTS: OnrampOptions = {
  gateway: 'https://app.datagrout.ai',
  agentName: 'test-agent',
  agentType: 'claude-sonnet-4-6',
  intendedUse: 'Testing.',
};

function mockFetch(responses: Array<{ body: object; ok?: boolean; status?: number }>) {
  let call = 0;
  return vi.fn().mockImplementation(() => {
    const r = responses[call++];
    const ok = r.ok ?? (r.status ? r.status < 400 : true);
    const status = r.status ?? (ok ? 200 : 400);
    return Promise.resolve({
      ok,
      status,
      json: () => Promise.resolve(r.body),
      text: () => Promise.resolve(JSON.stringify(r.body)),
    });
  });
}

// ─── OnrampOptions structure ──────────────────────────────────────────────────

describe('OnrampOptions', () => {
  it('holds all fields', () => {
    const opts: OnrampOptions = {
      gateway: 'https://app.datagrout.ai',
      agentName: 'my-agent',
      agentType: 'gpt-4o',
      intendedUse: 'extraction',
      accessCode: 'code123',
    };
    expect(opts.agentName).toBe('my-agent');
    expect(opts.agentType).toBe('gpt-4o');
    expect(opts.accessCode).toBe('code123');
  });

  it('allows optional fields to be absent', () => {
    const opts: OnrampOptions = {
      gateway: 'https://app.datagrout.ai',
      agentName: 'bare',
    };
    expect(opts.agentType).toBeUndefined();
    expect(opts.intendedUse).toBeUndefined();
    expect(opts.accessCode).toBeUndefined();
  });
});

// ─── OnrampCredentials structure ──────────────────────────────────────────────

describe('OnrampCredentials', () => {
  it('can be constructed with all fields', () => {
    const creds: OnrampCredentials = {
      clientId: 'agt_abc',
      clientSecret: 'sk_xyz',
      tokenUrl: 'https://example.com/token',
      scopes: ['mcp:read'],
      expiresIn: 2592000,
      mcpUrl: 'https://example.com/mcp',
      rpcUrl: 'https://example.com/rpc',
    };
    expect(creds.clientId).toBe('agt_abc');
    expect(creds.mcpUrl).toBe('https://example.com/mcp');
    expect(creds.expiresIn).toBe(2592000);
  });

  it('can have absent mcpUrl and rpcUrl', () => {
    const creds: OnrampCredentials = {
      clientId: 'x', clientSecret: 'y',
      tokenUrl: 'https://example.com/token',
      scopes: [], expiresIn: 0,
    };
    expect(creds.mcpUrl).toBeUndefined();
    expect(creds.rpcUrl).toBeUndefined();
  });
});

// ─── _doRegister ──────────────────────────────────────────────────────────────

describe('_doRegister', () => {
  let originalFetch: typeof global.fetch;

  beforeEach(() => { originalFetch = global.fetch; });
  afterEach(() => { global.fetch = originalFetch; });

  it('sends init then complete', async () => {
    global.fetch = mockFetch([
      { body: INIT_RESPONSE },
      { body: COMPLETE_RESPONSE },
    ]);

    const creds = await _doRegister(DEFAULT_OPTS);

    expect((global.fetch as ReturnType<typeof vi.fn>)).toHaveBeenCalledTimes(2);

    const [initCall, completeCall] = (global.fetch as ReturnType<typeof vi.fn>).mock.calls;
    expect(initCall[0]).toContain('/onramp');
    expect(completeCall[0]).toContain('/onramp/complete');

    expect(creds.clientId).toBe('agt_abc123');
    expect(creds.clientSecret).toBe('sk_xyz789');
    expect(creds.mcpUrl).toBe('https://app.datagrout.ai/servers/abc/mcp');
    expect(creds.scopes).toEqual(['mcp:read', 'tools:call']);
  });

  it('sends session token in complete Authorization header', async () => {
    global.fetch = mockFetch([
      { body: INIT_RESPONSE },
      { body: COMPLETE_RESPONSE },
    ]);
    await _doRegister(DEFAULT_OPTS);
    const completeCall = (global.fetch as ReturnType<typeof vi.fn>).mock.calls[1];
    expect(completeCall[1]?.headers?.Authorization).toBe('Bearer sess_abc123');
  });

  it('includes optional fields in init body when set', async () => {
    global.fetch = mockFetch([
      { body: INIT_RESPONSE },
      { body: COMPLETE_RESPONSE },
    ]);
    await _doRegister(DEFAULT_OPTS);
    const initBody = JSON.parse((global.fetch as ReturnType<typeof vi.fn>).mock.calls[0][1].body);
    expect(initBody.agent_name).toBe('test-agent');
    expect(initBody.agent_type).toBe('claude-sonnet-4-6');
    expect(initBody.intended_use).toBe('Testing.');
  });

  it('omits undefined optional fields from init body', async () => {
    global.fetch = mockFetch([
      { body: INIT_RESPONSE },
      { body: COMPLETE_RESPONSE },
    ]);
    const opts: OnrampOptions = { gateway: 'https://app.datagrout.ai', agentName: 'bare' };
    await _doRegister(opts);
    const initBody = JSON.parse((global.fetch as ReturnType<typeof vi.fn>).mock.calls[0][1].body);
    expect(initBody.agent_type).toBeUndefined();
    expect(initBody.intended_use).toBeUndefined();
    expect(initBody.access_code).toBeUndefined();
  });

  it('strips trailing slash from gateway', async () => {
    global.fetch = mockFetch([
      { body: INIT_RESPONSE },
      { body: COMPLETE_RESPONSE },
    ]);
    const opts: OnrampOptions = { gateway: 'https://app.datagrout.ai/', agentName: 'a' };
    await _doRegister(opts);
    const url = (global.fetch as ReturnType<typeof vi.fn>).mock.calls[0][0];
    expect(url).toBe('https://app.datagrout.ai/onramp');
  });

  it('throws when init is rejected', async () => {
    global.fetch = mockFetch([{ body: { error: 'rate_limited' }, ok: false, status: 429 }]);
    await expect(_doRegister(DEFAULT_OPTS)).rejects.toThrow('429');
  });

  it('throws when complete is rejected', async () => {
    global.fetch = mockFetch([
      { body: INIT_RESPONSE },
      { body: { error: 'expired' }, ok: false, status: 410 },
    ]);
    await expect(_doRegister(DEFAULT_OPTS)).rejects.toThrow('410');
  });

  it('handles absent mcp_url and rpc_url gracefully', async () => {
    const partialResp = { ...COMPLETE_RESPONSE };
    delete (partialResp as any).mcp_url;
    delete (partialResp as any).rpc_url;
    global.fetch = mockFetch([{ body: INIT_RESPONSE }, { body: partialResp }]);
    const creds = await _doRegister(DEFAULT_OPTS);
    expect(creds.mcpUrl).toBeUndefined();
    expect(creds.rpcUrl).toBeUndefined();
  });
});

// ─── _exchangeToken ───────────────────────────────────────────────────────────

describe('_exchangeToken', () => {
  let originalFetch: typeof global.fetch;

  beforeEach(() => { originalFetch = global.fetch; });
  afterEach(() => { global.fetch = originalFetch; });

  const creds: OnrampCredentials = {
    clientId: 'agt_abc',
    clientSecret: 'sk_xyz',
    tokenUrl: 'https://app.datagrout.ai/servers/abc/oauth/token',
    scopes: [], expiresIn: 0,
  };

  it('posts client_credentials form and returns access_token', async () => {
    global.fetch = mockFetch([{ body: TOKEN_RESPONSE }]);
    const token = await _exchangeToken(creds);
    expect(token).toBe('tok_live123');
  });

  it('throws on non-2xx response', async () => {
    global.fetch = mockFetch([{ body: {}, ok: false, status: 401 }]);
    await expect(_exchangeToken(creds)).rejects.toThrow('401');
  });
});

// ─── Public API ───────────────────────────────────────────────────────────────

describe('registerOnly', () => {
  let originalFetch: typeof global.fetch;
  beforeEach(() => { originalFetch = global.fetch; });
  afterEach(() => { global.fetch = originalFetch; });

  it('returns OnrampCredentials', async () => {
    global.fetch = mockFetch([{ body: INIT_RESPONSE }, { body: COMPLETE_RESPONSE }]);
    const creds = await registerOnly(DEFAULT_OPTS);
    expect(creds.clientId).toBe('agt_abc123');
    expect(creds.clientSecret).toBe('sk_xyz789');
  });
});

describe('registerAndExchange', () => {
  let originalFetch: typeof global.fetch;
  beforeEach(() => { originalFetch = global.fetch; });
  afterEach(() => { global.fetch = originalFetch; });

  it('returns [credentials, token]', async () => {
    global.fetch = mockFetch([
      { body: INIT_RESPONSE },
      { body: COMPLETE_RESPONSE },
      { body: TOKEN_RESPONSE },
    ]);
    const [creds, token] = await registerAndExchange(DEFAULT_OPTS);
    expect(creds.clientId).toBe('agt_abc123');
    expect(token).toBe('tok_live123');
  });
});
