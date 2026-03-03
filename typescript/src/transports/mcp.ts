/**
 * MCP transport implementation using official SDK
 */

import { Transport } from './base';
import type { AuthConfig, MCPTool, MCPResource, MCPPrompt } from '../types';
import type { ConduitIdentity } from '../identity';
import { OAuthTokenProvider, deriveTokenEndpoint } from '../oauth';
import { Client } from '@modelcontextprotocol/sdk/client/index.js';
import { SSEClientTransport } from '@modelcontextprotocol/sdk/client/sse.js';
import { StdioClientTransport } from '@modelcontextprotocol/sdk/client/stdio.js';

export class MCPTransport extends Transport {
  private url: string;
  private auth?: AuthConfig;
  private identity?: ConduitIdentity;
  private client?: Client;
  private clientTransport?: SSEClientTransport | StdioClientTransport;
  private oauthProvider?: OAuthTokenProvider;

  constructor(url: string, auth?: AuthConfig, identity?: ConduitIdentity) {
    super();
    this.url = url;
    this.auth = auth;
    this.identity = identity;

    if (auth?.clientCredentials) {
      const cc = auth.clientCredentials;
      const tokenEndpoint = cc.tokenEndpoint ?? deriveTokenEndpoint(url);
      this.oauthProvider = new OAuthTokenProvider({
        clientId: cc.clientId,
        clientSecret: cc.clientSecret,
        tokenEndpoint,
        scope: cc.scope,
      });
    }
  }

  private async buildHeaders(): Promise<Record<string, string>> {
    const headers: Record<string, string> = {};

    if (this.oauthProvider) {
      const token = await this.oauthProvider.getToken();
      headers['Authorization'] = `Bearer ${token}`;
    } else if (this.auth?.bearer) {
      headers['Authorization'] = `Bearer ${this.auth.bearer}`;
    } else if (this.auth?.basic) {
      const encoded = Buffer.from(
        `${this.auth.basic.username}:${this.auth.basic.password}`
      ).toString('base64');
      headers['Authorization'] = `Basic ${encoded}`;
    } else if (this.auth?.custom) {
      Object.assign(headers, this.auth.custom);
    }

    return headers;
  }

  async connect(): Promise<void> {
    if (this.url.startsWith('stdio://')) {
      const command = this.url.replace('stdio://', '');
      const parts = command.split(' ');

      this.clientTransport = new StdioClientTransport({
        command: parts[0],
        args: parts.slice(1),
      });
    } else if (this.url.startsWith('http://') || this.url.startsWith('https://')) {
      const headers = await this.buildHeaders();

      const transportOpts: Record<string, any> = {};

      if (Object.keys(headers).length > 0) {
        transportOpts.requestInit = { headers };
      }

      if (this.identity) {
        const id = this.identity;
        transportOpts.fetcher = (url: string | URL | Request, init?: RequestInit) => {
          const { fetchWithIdentity } = require('../identity') as typeof import('../identity');
          return fetchWithIdentity(
            typeof url === 'string' ? url : url instanceof URL ? url.toString() : url.url,
            init ?? {},
            id
          );
        };
      }

      this.clientTransport = new SSEClientTransport(
        new URL(this.url),
        transportOpts
      );
    } else {
      throw new Error(`Unsupported MCP URL scheme: ${this.url}`);
    }

    this.client = new Client(
      { name: 'datagrout-conduit', version: '0.1.0' },
      { capabilities: {} }
    );

    await this.client.connect(this.clientTransport);
  }

  async disconnect(): Promise<void> {
    if (this.client) {
      await this.client.close();
    }
  }

  async listTools(options?: any): Promise<MCPTool[]> {
    if (!this.client) {
      throw new Error('Not connected. Call connect() first.');
    }

    const result = await this.client.listTools(options);
    return result.tools.map((tool: any) => ({
      name: tool.name,
      description: tool.description,
      inputSchema: tool.inputSchema,
      annotations: tool.annotations,
    }));
  }

  async callTool(name: string, args: Record<string, any>, options?: any): Promise<any> {
    if (!this.client) {
      throw new Error('Not connected. Call connect() first.');
    }

    const result = await this.client.callTool({ name, arguments: args });

    // MCP tool responses wrap the actual result in a content envelope:
    // { "content": [{ "type": "text", "text": "<json>" }], "isError": false }
    // Unwrap so callers receive the actual tool output map.
    const content = result?.content;
    if (Array.isArray(content) && content.length > 0) {
      const first = content[0];
      if (first && typeof first.text === 'string') {
        try {
          return JSON.parse(first.text);
        } catch {
          return { text: first.text };
        }
      }
    }
    return result;
  }

  async listResources(options?: any): Promise<MCPResource[]> {
    if (!this.client) {
      throw new Error('Not connected. Call connect() first.');
    }

    const result = await this.client.listResources();
    return result.resources.map((resource: any) => ({
      uri: resource.uri,
      name: resource.name,
      description: resource.description,
      mimeType: resource.mimeType,
    }));
  }

  async readResource(uri: string, options?: any): Promise<any> {
    if (!this.client) {
      throw new Error('Not connected. Call connect() first.');
    }

    const result = await this.client.readResource({ uri });
    return result.contents;
  }

  async listPrompts(options?: any): Promise<MCPPrompt[]> {
    if (!this.client) {
      throw new Error('Not connected. Call connect() first.');
    }

    const result = await this.client.listPrompts();
    return result.prompts.map((prompt: any) => ({
      name: prompt.name,
      description: prompt.description,
      arguments: prompt.arguments,
    }));
  }

  async getPrompt(name: string, args?: Record<string, any>, options?: any): Promise<any> {
    if (!this.client) {
      throw new Error('Not connected. Call connect() first.');
    }

    const result = await this.client.getPrompt({ name, arguments: args || {} });
    return result.messages;
  }
}
