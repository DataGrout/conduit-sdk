/**
 * JSONRPC transport implementation
 */

import { Transport } from './base';
import type { AuthConfig, MCPTool, MCPResource, MCPPrompt } from '../types';

export class JSONRPCTransport extends Transport {
  private url: string;
  private auth?: AuthConfig;
  private timeout: number;
  private requestId = 0;

  constructor(url: string, auth?: AuthConfig, timeout = 30000) {
    super();
    this.url = url;
    this.auth = auth;
    this.timeout = timeout;
  }

  async connect(): Promise<void> {
    // Connection is established per-request in fetch-based transport
  }

  async disconnect(): Promise<void> {
    // No persistent connection to close
  }

  private async call(method: string, params?: any): Promise<any> {
    const headers: Record<string, string> = {
      'Content-Type': 'application/json',
    };

    // Handle bearer token auth
    if (this.auth?.bearer) {
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

    try {
      const response = await fetch(this.url, {
        method: 'POST',
        headers,
        body: JSON.stringify(request),
        signal: controller.signal,
      });

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
