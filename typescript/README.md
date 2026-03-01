# DataGrout Conduit — TypeScript SDK

Production-ready MCP client with mTLS identity, OAuth 2.1, semantic discovery, and cost tracking.

## Installation

```bash
npm install @datagrout/conduit
```

## Quick Start

```typescript
import { Client } from '@datagrout/conduit';

const client = new Client('https://gateway.datagrout.ai/servers/{uuid}/mcp');
await client.connect();

const tools = await client.listTools();
const result = await client.callTool('salesforce@1/get_lead@1', { id: '123' });

await client.disconnect();
```

## Authentication

### Bearer Token

```typescript
const client = new Client({
  url: 'https://gateway.datagrout.ai/servers/{uuid}/mcp',
  auth: { bearer: 'your-access-token' },
});
```

### OAuth 2.1 (client_credentials)

```typescript
const client = new Client({
  url: 'https://gateway.datagrout.ai/servers/{uuid}/mcp',
  auth: {
    clientCredentials: {
      clientId: 'your-client-id',
      clientSecret: 'your-client-secret',
    },
  },
});
```

The SDK automatically fetches, caches, and refreshes JWTs before they expire.

### mTLS (Mutual TLS)

After bootstrapping, the client certificate handles authentication at the TLS layer — no tokens needed.

```typescript
import { Client, ConduitIdentity } from '@datagrout/conduit';

// Auto-discover from env vars, CONDUIT_IDENTITY_DIR, or ~/.conduit/
const client = new Client({
  url: 'https://gateway.datagrout.ai/servers/{uuid}/mcp',
  identityAuto: true,
});

// Explicit identity from files
const identity = ConduitIdentity.fromPaths('certs/client.pem', 'certs/client_key.pem');
const client = new Client({ url: '...', identity });

// Multiple agents on one machine
const client = new Client({
  url: '...',
  identityDir: '/opt/agents/agent-a/.conduit',
  identityAuto: true,
});
```

#### Identity Auto-Discovery Order

1. `CONDUIT_MTLS_CERT` + `CONDUIT_MTLS_KEY` environment variables (inline PEM)
2. `CONDUIT_IDENTITY_DIR` environment variable (directory path)
3. `~/.conduit/identity.pem` + `~/.conduit/identity_key.pem`
4. `.conduit/` relative to the current working directory

For DataGrout URLs (`*.datagrout.ai`), auto-discovery runs silently even without `identityAuto: true`.

#### Bootstrapping an mTLS Identity

First-run provisioning — generates a keypair, registers with the DataGrout CA, and saves certs locally. After this, the token is never needed again.

```typescript
import {
  generateKeypair,
  registerIdentity,
  saveIdentity,
} from '@datagrout/conduit';

const keypair = generateKeypair();
const { identity } = await registerIdentity(keypair, {
  endpoint: 'https://app.datagrout.ai/api/v1/substrate/identity',
  authToken: 'your-access-token',
  name: 'my-laptop',
});
saveIdentity(identity);  // saves to ~/.conduit/
```

## Semantic Discovery

When `useIntelligentInterface` is enabled, `listTools()` returns only DataGrout's meta-tools. Agents use semantic search instead of enumerating raw integrations:

```typescript
const client = new Client({
  url: '...',
  useIntelligentInterface: true,
});

// Semantic search across all connected integrations
const results = await client.discover({ query: 'find unpaid invoices', limit: 5 });

// Direct execution with cost tracking
const result = await client.perform({
  tool: 'salesforce@1/get_lead@1',
  args: { id: '123' },
});
```

## Cost Tracking

Every tool call returns a receipt with credit usage:

```typescript
import { extractMeta } from '@datagrout/conduit';

const result = await client.callTool('salesforce@1/get_lead@1', { id: '123' });
const meta = extractMeta(result);

if (meta) {
  console.log(`Credits: ${meta.receipt.netCredits}`);
  console.log(`Savings: ${meta.receipt.savings}`);
}
```

## Transports

```typescript
// JSONRPC (default) — lightweight, supports mTLS
const client = new Client({ url, transport: 'jsonrpc' });

// MCP — full MCP protocol over Streamable HTTP
const client = new Client({ url, transport: 'mcp' });
```

## API Reference

### Client Options

```typescript
new Client(options: {
  url: string;
  auth?: { bearer?: string; apiKey?: string; clientCredentials?: {...} };
  transport?: 'mcp' | 'jsonrpc';
  useIntelligentInterface?: boolean;
  identity?: ConduitIdentity;
  identityAuto?: boolean;
  identityDir?: string;
  disableMtls?: boolean;
  timeout?: number;
});
```

### Standard MCP Methods

| Method | Description |
|---|---|
| `connect()` | Initialize connection |
| `disconnect()` | Close connection |
| `listTools()` | List available tools |
| `callTool(name, args)` | Execute a tool |
| `listResources()` | List resources |
| `readResource(uri)` | Read a resource |
| `listPrompts()` | List prompts |
| `getPrompt(name, args)` | Get a prompt |

### DataGrout Extensions

| Method | Description |
|---|---|
| `discover(options)` | Semantic tool search |
| `perform(options)` | Direct tool execution with tracking |
| `performBatch(calls)` | Parallel tool execution |
| `guide(options)` | Guided multi-step workflow |
| `flowInto(options)` | Workflow orchestration |
| `prismFocus(options)` | Type transformation |
| `estimateCost(tool, args)` | Pre-execution credit estimate |

## Requirements

- Node.js 18+
- TypeScript 5.0+ (for TypeScript users)

## License

MIT
