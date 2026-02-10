/**
 * Base transport interface
 */

import type { MCPTool, MCPResource, MCPPrompt } from '../types';

export abstract class Transport {
  abstract connect(): Promise<void>;
  abstract disconnect(): Promise<void>;
  
  abstract listTools(options?: any): Promise<MCPTool[]>;
  abstract callTool(name: string, args: Record<string, any>, options?: any): Promise<any>;
  
  abstract listResources(options?: any): Promise<MCPResource[]>;
  abstract readResource(uri: string, options?: any): Promise<any>;
  
  abstract listPrompts(options?: any): Promise<MCPPrompt[]>;
  abstract getPrompt(name: string, args?: Record<string, any>, options?: any): Promise<any>;
}
