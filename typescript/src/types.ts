/**
 * Type definitions for DataGrout Conduit
 */

export interface Receipt {
  receiptId: string;
  estimatedCredits: number;
  actualCredits: number;
  netCredits: number;
  savings?: number;
  savingsBonus?: number;
  breakdown?: Record<string, any>;
  byok?: Record<string, any>;
}

export interface ToolInfo {
  toolName: string;
  integration: string;
  serverId?: string;
  score?: number;
  distance?: number;
  description?: string;
  sideEffects?: string;
  inputSchema?: Record<string, any>;
  outputSchema?: Record<string, any>;
}

export interface DiscoverResult {
  queryUsed: string;
  results: ToolInfo[];
  total: number;
  limit: number;
}

export interface PerformResult {
  success: boolean;
  result: any;
  tool: string;
  metadata?: Record<string, any>;
  receipt?: Receipt;
}

export interface GuideOptions {
  id: string;
  label: string;
  cost: number;
  viable: boolean;
  metadata?: Record<string, any>;
}

export interface GuideState {
  sessionId: string;
  step: string;
  message: string;
  status: string;
  options?: GuideOptions[];
  pathTaken?: string[];
  totalCost?: number;
  result?: any;
  progress?: string;
}

export interface AuthConfig {
  bearer?: string;
  basic?: {
    username: string;
    password: string;
  };
  custom?: Record<string, string>;
}

export interface ClientOptions {
  url: string;
  auth?: AuthConfig;
  hide3rdPartyTools?: boolean;
  transport?: 'mcp' | 'jsonrpc';
  timeout?: number;
}

export interface DiscoverOptions {
  query?: string;
  goal?: string;
  limit?: number;
  minScore?: number;
  integrations?: string[];
  servers?: string[];
}

export interface PerformOptions {
  tool: string;
  args: Record<string, any>;
  demux?: boolean;
  demuxMode?: 'strict' | 'fuzzy';
}

export interface GuideRequestOptions {
  goal?: string;
  policy?: Record<string, any>;
  sessionId?: string;
  choice?: string;
}

export interface FlowOptions {
  plan: Array<Record<string, any>>;
  validateCtc?: boolean;
  saveAsSkill?: boolean;
  inputData?: Record<string, any>;
}

export interface PrismFocusOptions {
  data: Record<string, any>;
  sourceType: string;
  targetType: string;
}

export interface MCPTool {
  name: string;
  description?: string;
  inputSchema?: Record<string, any>;
}

export interface MCPResource {
  uri: string;
  name?: string;
  description?: string;
  mimeType?: string;
}

export interface MCPPrompt {
  name: string;
  description?: string;
  arguments?: Array<{
    name: string;
    description?: string;
    required?: boolean;
  }>;
}
