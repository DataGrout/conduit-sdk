/**
 * JSONRPC transport implementation
 */

import { Transport } from './base';
import { ConduitIdentity, fetchWithIdentity } from '../identity';
import { OAuthTokenProvider } from '../oauth';
import type { AuthConfig, MCPTool, MCPResource, MCPPrompt, RateLimit, RateLimitStatus } from '../types';

/**
 * Thrown when the DataGrout gateway returns HTTP 429.
 *
 * Authenticated users are never rate-limited. Unauthenticated callers
 * hitting the hourly cap will receive this error.
 */
export class RateLimitError extends Error {
  readonly status: RateLimitStatus;

  constructor(status: RateLimitStatus) {
    const limitStr =
      status.limit === 'unlimited'
        ? 'unlimited'
        : `${(status.limit as { perHour: number }).perHour}/hour`;
    super(`Rate limit exceeded (${status.used} / ${limitStr} calls this hour)`);
    this.name = 'RateLimitError';
    this.status = status;
  }
}

function parseRateLimitError(response: Response): RateLimitError {
  const used = parseInt(response.headers.get('X-RateLimit-Used') ?? '0', 10) || 0;
  const limitStr = response.headers.get('X-RateLimit-Limit') ?? '50';
  const limit: RateLimit =
    limitStr.toLowerCase() === 'unlimited'
      ? 'unlimited'
      : { perHour: parseInt(limitStr, 10) || 50 };
  const isLimited = limit === 'unlimited' ? false : used >= (limit as { perHour: number }).perHour;
  const remaining =
    limit === 'unlimited' ? null : Math.max(0, (limit as { perHour: number }).perHour - used);

  return new RateLimitError({ used, limit, isLimited, remaining });
}

export class JSONRPCTransport extends Transport {
  private url: string;
  private auth?: AuthConfig;
  private identity?: ConduitIdentity;
  private timeout: number;
  private requestId = 0;
  /** Resolved token provider, present only when `auth.clientCredentials` is set. */
  private oauthProvider?: OAuthTokenProvider;

  constructor(url: string, auth?: AuthConfig, timeout = 30000, identity?: ConduitIdentity) {
    super();
    this.url = url;
    this.auth = auth;
    this.identity = identity;
    this.timeout = timeout;

    if (identity?.needsRotation(30)) {
      console.warn('[conduit] mTLS certificate expires within 30 days — consider rotating');
    }

    if (auth?.clientCredentials) {
      const cc = auth.clientCredentials;
      const tokenEndpoint =
        cc.tokenEndpoint ?? (() => {
          const { deriveTokenEndpoint } = require('../oauth') as typeof import('../oauth');
          return deriveTokenEndpoint(url);
        })();
      this.oauthProvider = new OAuthTokenProvider({
        clientId: cc.clientId,
        clientSecret: cc.clientSecret,
        tokenEndpoint,
        scope: cc.scope,
      });
    }
  }

  async connect(): Promise<void> {
    // Connection is established per-request in fetch-based transport
  }

  async disconnect(): Promise<void> {
    // No persistent connection to close
  }

  private async call(method: string, params?: any): Promise<any> {
    return this._callWithRetry(method, params, false);
  }

  private async _callWithRetry(method: string, params: any, isRetry: boolean): Promise<any> {
    const headers: Record<string, string> = {
      'Content-Type': 'application/json',
    };

    // Handle auth — OAuth token fetched asynchronously.
    if (this.oauthProvider) {
      const token = await this.oauthProvider.getToken();
      headers['Authorization'] = `Bearer ${token}`;
    } else if (this.auth?.bearer) {
      headers['Authorization'] = `Bearer ${this.auth.bearer}`;
    } else if (this.auth?.basic) {
      const credentials = btoa(`${this.auth.basic.username}:${this.auth.basic.password}`);
      headers['Authorization'] = `Basic ${credentials}`;
    } else if (this.auth?.custom) {
      Object.assign(headers, this.auth.custom);
    }

    const request = {
      jsonrpc: '2.0',
      id: ++this.requestId,
      method,
      params: params || {},
    };

    const controller = new AbortController();
    const timeoutId = setTimeout(() => controller.abort(), this.timeout);

    const fetchInit: RequestInit = {
      method: 'POST',
      headers,
      body: JSON.stringify(request),
      signal: controller.signal,
    };

    try {
      const response = this.identity
        ? await fetchWithIdentity(this.url, fetchInit, this.identity)
        : await fetch(this.url, fetchInit);

      if (response.status === 429) {
        throw parseRateLimitError(response);
      }

      // On 401, invalidate the cached OAuth token and retry once.
      if (response.status === 401 && this.oauthProvider && !isRetry) {
        this.oauthProvider.invalidate();
        return this._callWithRetry(method, params, true);
      }

      if (!response.ok) {
        throw new Error(`HTTP ${response.status}: ${response.statusText}`);
      }

      const data = await response.json();

      if (data.error) {
        throw new Error(`JSONRPC Error: ${JSON.stringify(data.error)}`);
      }

      return data.result;
    } finally {
      clearTimeout(timeoutId);
    }
  }

  async listTools(options?: any): Promise<MCPTool[]> {
    const result = await this.call('tools/list', options);
    return result?.tools || [];
  }

  async callTool(name: string, args: Record<string, any>, options?: any): Promise<any> {
    const params = { name, arguments: args, ...options };
    return await this.call('tools/call', params);
  }

  async listResources(options?: any): Promise<MCPResource[]> {
    const result = await this.call('resources/list', options);
    return result?.resources || [];
  }

  async readResource(uri: string, options?: any): Promise<any> {
    const params = { uri, ...options };
    return await this.call('resources/read', params);
  }

  async listPrompts(options?: any): Promise<MCPPrompt[]> {
    const result = await this.call('prompts/list', options);
    return result?.prompts || [];
  }

  async getPrompt(name: string, args?: Record<string, any>, options?: any): Promise<any> {
    const params = { name, arguments: args || {}, ...options };
    return await this.call('prompts/get', params);
  }
}
