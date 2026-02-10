# DataGrout Conduit - TypeScript SDK

Production-ready MCP client for TypeScript/JavaScript with enterprise features built-in.

## Installation

```bash
npm install @datagrout/conduit
# or
yarn add @datagrout/conduit
# or
pnpm add @datagrout/conduit
```

## Quick Start

```typescript
import { Client } from '@datagrout/conduit';

// Connect to DataGrout gateway
const client = new Client('https://gateway.datagrout.ai/servers/{your-server-uuid}/mcp');

// Standard MCP methods (enhanced automatically)
const tools = await client.listTools();
const result = await client.callTool('salesforce@1/get_lead@1', {id: '123'});

// DataGrout-specific features
const results = await client.discover({query: 'find unpaid invoices', limit: 10});
const session = await client.guide({goal: 'create invoice from lead'});
const receipt = client.getLastReceipt();
```

## Features

### Drop-in Replacement

Replace your MCP client import with Conduit:

```typescript
// Before
import { Client } from '@modelcontextprotocol/sdk';

// After
import { Client } from '@datagrout/conduit';

// Everything else stays the same
```

### Automatic Discovery

When `hide3rdPartyTools=true` (default), `listTools()` returns only DataGrout gateway tools. Your agent automatically uses semantic discovery:

```typescript
// Agent calls standard MCP
const tools = await client.listTools();
// Returns: [discover, perform, guide, flow.into, prism.focus, ...]

// Agent naturally calls discover
const results = await client.callTool('data-grout/discovery.discover', {
  query: 'find unpaid invoices'
});
// Gets filtered, relevant tools for its task
```

### Cost Tracking

Every operation tracks credits automatically:

```typescript
const result = await client.callTool('salesforce@1/get_lead@1', {id: '123'});

const receipt = client.getLastReceipt();
console.log(`Credits used: ${receipt.actualCredits}`);
console.log(`Breakdown:`, receipt.breakdown);
```

### Dual Transport Modes

```typescript
// Mode 1: MCP-backed (uses @modelcontextprotocol/sdk)
const client = new Client({url, transport: 'mcp'});

// Mode 2: Pure JSONRPC (no MCP dependency)
const client = new Client({url, transport: 'jsonrpc'});
```

## API Reference

### Client Configuration

```typescript
new Client(options: {
  url: string;
  auth?: AuthConfig;
  hide3rdPartyTools?: boolean;
  transport?: 'mcp' | 'jsonrpc';
});
```

### Standard MCP Methods

- `listTools()` - List available tools (enhanced with discovery)
- `callTool(name, arguments)` - Execute tool (enhanced with perform)
- `listResources()` - List resources
- `readResource(uri)` - Read resource
- `listPrompts()` - List prompts
- `getPrompt(name, arguments)` - Get prompt

### DataGrout Methods

- `discover(options)` - Semantic tool search
- `perform(options)` - Direct tool execution
- `performBatch(calls)` - Batch execution
- `guide(options)` - Guided workflow
- `flowInto(options)` - Workflow orchestration
- `prismFocus(options)` - Type transformation

### Receipt Methods

- `getLastReceipt()` - Get receipt from last operation
- `estimateCost(tool, args)` - Estimate credits before execution

## Examples

See [examples/](./examples/) directory for complete working examples:

- `basicUsage.ts` - Getting started
- `discoveryDemo.ts` - Semantic tool discovery
- `guidedWorkflow.ts` - Stateful workflow navigation
- `batchOperations.ts` - Parallel tool execution
- `costTracking.ts` - Credit management

## Requirements

- Node.js 18+
- TypeScript 5.0+ (for TypeScript users)

## License

MIT
