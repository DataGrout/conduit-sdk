/**
 * MCP transport implementation using official SDK
 */

import { Transport } from './base';
import type { AuthConfig, MCPTool, MCPResource, MCPPrompt } from '../types';
import { Client } from '@modelcontextprotocol/sdk/client/index.js';
import { SSEClientTransport } from '@modelcontextprotocol/sdk/client/sse.js';
import { StdioClientTransport } from '@modelcontextprotocol/sdk/client/stdio.js';

export class MCPTransport extends Transport {
  private url: string;
  private auth?: AuthConfig;
  private client?: Client;
  private clientTransport?: SSEClientTransport | StdioClientTransport;

  constructor(url: string, auth?: AuthConfig) {
    super();
    this.url = url;
    this.auth = auth;
  }

  async connect(): Promise<void> {
    // Determine transport type from URL
    if (this.url.startsWith('stdio://')) {
      // Stdio transport (local process)
      const command = this.url.replace('stdio://', '');
      const parts = command.split(' ');
      
      this.clientTransport = new StdioClientTransport({
        command: parts[0],
        args: parts.slice(1),
      });
    } else if (this.url.startsWith('http://') || this.url.startsWith('https://')) {
      // SSE transport (HTTP/HTTPS)
      const headers: Record<string, string> = {};
      if (this.auth?.bearer) {
        headers['Authorization'] = `Bearer ${this.auth.bearer}`;
      } else if (this.auth?.apiKey) {
        headers['X-API-Key'] = this.auth.apiKey;
      }

      this.clientTransport = new SSEClientTransport(
        new URL(this.url),
        Object.keys(headers).length > 0 ? headers : undefined
      );
    } else {
      throw new Error(`Unsupported MCP URL scheme: ${this.url}`);
    }

    // Create and connect client
    this.client = new Client(
      {
        name: 'datagrout-conduit',
        version: '0.1.0',
      },
      {
        capabilities: {},
      }
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

    const result = await this.client.listTools();
    return result.tools.map((tool: any) => ({
      name: tool.name,
      description: tool.description,
      inputSchema: tool.inputSchema,
    }));
  }

  async callTool(name: string, args: Record<string, any>, options?: any): Promise<any> {
    if (!this.client) {
      throw new Error('Not connected. Call connect() first.');
    }

    const result = await this.client.callTool({ name, arguments: args });
    return result.content;
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
