/**
 * Tests for the OAuth 2.1 token provider.
 */

import { describe, it, expect, beforeEach, vi } from 'vitest';
import { OAuthTokenProvider, deriveTokenEndpoint } from '../src/oauth';

// ─── Token endpoint derivation ────────────────────────────────────────────────

describe('deriveTokenEndpoint', () => {
  it('strips /mcp suffix', () => {
    expect(deriveTokenEndpoint('https://app.datagrout.ai/servers/abc/mcp')).toBe(
      'https://app.datagrout.ai/servers/abc/oauth/token'
    );
  });

  it('strips /mcp and any path after it', () => {
    expect(deriveTokenEndpoint('https://app.datagrout.ai/servers/abc/mcp/something')).toBe(
      'https://app.datagrout.ai/servers/abc/oauth/token'
    );
  });

  it('handles URL without /mcp', () => {
    expect(deriveTokenEndpoint('https://app.datagrout.ai/servers/abc')).toBe(
      'https://app.datagrout.ai/servers/abc/oauth/token'
    );
  });

  it('handles trailing slash URL without /mcp', () => {
    expect(deriveTokenEndpoint('https://app.datagrout.ai/servers/abc/')).toBe(
      'https://app.datagrout.ai/servers/abc/oauth/token'
    );
  });
});

// ─── OAuthTokenProvider ───────────────────────────────────────────────────────

const TOKEN_RESPONSE = {
  access_token: 'eyJtest.token.here',
  token_type: 'Bearer',
  expires_in: 3600,
  scope: 'mcp',
};

function mockFetch(body: object, status = 200) {
  return vi.fn().mockResolvedValue({
    ok: status >= 200 && status < 300,
    status,
    json: () => Promise.resolve(body),
    text: () => Promise.resolve(JSON.stringify(body)),
  });
}

describe('OAuthTokenProvider', () => {
  let provider: OAuthTokenProvider;

  beforeEach(() => {
    provider = new OAuthTokenProvider({
      clientId: 'test_id',
      clientSecret: 'test_secret',
      tokenEndpoint: 'https://app.datagrout.ai/servers/abc/oauth/token',
      scope: 'mcp',
    });
  });

  it('fetches a token on first call', async () => {
    const fetchMock = mockFetch(TOKEN_RESPONSE);
    globalThis.fetch = fetchMock as any;

    const token = await provider.getToken();

    expect(token).toBe('eyJtest.token.here');
    expect(fetchMock).toHaveBeenCalledOnce();

    const [url, options] = fetchMock.mock.calls[0] as [string, RequestInit];
    expect(url).toBe('https://app.datagrout.ai/servers/abc/oauth/token');
    expect(options.method).toBe('POST');
    expect(options.body?.toString()).toContain('grant_type=client_credentials');
    expect(options.body?.toString()).toContain('client_id=test_id');
    expect(options.body?.toString()).toContain('scope=mcp');
  });

  it('returns cached token on second call', async () => {
    const fetchMock = mockFetch(TOKEN_RESPONSE);
    globalThis.fetch = fetchMock as any;

    await provider.getToken();
    const token = await provider.getToken();

    expect(token).toBe('eyJtest.token.here');
    // Fetch should only have been called once.
    expect(fetchMock).toHaveBeenCalledOnce();
  });

  it('fetches a new token after invalidate', async () => {
    const fetchMock = mockFetch(TOKEN_RESPONSE);
    globalThis.fetch = fetchMock as any;

    await provider.getToken();
    provider.invalidate();
    await provider.getToken();

    expect(fetchMock).toHaveBeenCalledTimes(2);
  });

  it('throws on non-2xx response', async () => {
    const fetchMock = mockFetch({ error: 'invalid_client' }, 401);
    globalThis.fetch = fetchMock as any;

    await expect(provider.getToken()).rejects.toThrow(/401/);
  });

  it('de-duplicates concurrent fetches', async () => {
    let resolveFirst!: (v: Response) => void;
    const firstFetchPromise = new Promise<Response>((res) => {
      resolveFirst = res;
    });

    const fetchMock = vi
      .fn()
      .mockReturnValueOnce(firstFetchPromise)
      .mockResolvedValue({
        ok: true,
        status: 200,
        json: () => Promise.resolve(TOKEN_RESPONSE),
      });

    globalThis.fetch = fetchMock as any;

    // Start two concurrent getToken calls.
    const p1 = provider.getToken();
    const p2 = provider.getToken();

    // Resolve the first fetch.
    resolveFirst({
      ok: true,
      status: 200,
      json: () => Promise.resolve(TOKEN_RESPONSE),
    } as Response);

    const [t1, t2] = await Promise.all([p1, p2]);

    expect(t1).toBe('eyJtest.token.here');
    expect(t2).toBe('eyJtest.token.here');
    // Fetch should only have been called once despite two concurrent callers.
    expect(fetchMock).toHaveBeenCalledOnce();
  });
});
