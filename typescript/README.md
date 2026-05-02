# DataGrout Conduit — TypeScript SDK

Production-ready MCP client with mTLS identity, OAuth 2.1, semantic discovery, and cost tracking.

## Installation

```bash
npm install @datagrout/conduit@0.4.0
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

1. `identityDir` option (if provided)
2. `CONDUIT_MTLS_CERT` + `CONDUIT_MTLS_KEY` environment variables (inline PEM)
3. `CONDUIT_IDENTITY_DIR` environment variable (directory path)
4. `~/.conduit/identity.pem` + `~/.conduit/identity_key.pem`
5. `.conduit/` relative to the current working directory

For DataGrout URLs (`*.datagrout.ai`), auto-discovery runs silently even without `identityAuto: true`.

#### Bootstrapping an mTLS Identity

One-call provisioning — generates a keypair, registers with the DataGrout CA, saves certs locally, and returns a connected client. After this, the token is never needed again.

```typescript
import { Client } from '@datagrout/conduit';

// One-call bootstrap with a one-time access token
const client = await Client.bootstrapIdentity({
  url: 'https://gateway.datagrout.ai/servers/{uuid}/mcp',
  authToken: 'your-one-time-token',
  name: 'my-agent',
});

// All subsequent runs: mTLS auto-discovered from ~/.conduit/
const client = new Client('https://gateway.datagrout.ai/servers/{uuid}/mcp');
await client.connect();
```

You can also use the registration functions directly:

```typescript
import { generateKeypair, registerIdentity, saveIdentityToDir } from '@datagrout/conduit';

const { publicKeyPem, privateKeyPem } = generateKeypair();
const reg = await registerIdentity(publicKeyPem, {
  authToken: 'your-access-token',
  name: 'my-agent',
});
await saveIdentityToDir(reg.certPem, privateKeyPem, '~/.conduit', reg.caCertPem);
```

## Semantic Discovery & Intelligent Interface

For DataGrout URLs, the Intelligent Interface is enabled by default — `listTools()` returns only `data-grout@1/discovery.discover@1` and `data-grout@1/discovery.perform@1`. Agents use semantic search instead of enumerating raw integrations:

```typescript
// Intelligent Interface auto-enabled for DG URLs
const client = new Client('https://gateway.datagrout.ai/servers/{uuid}/mcp');
await client.connect();

// Semantic search across all connected integrations
const results = await client.discover({ query: 'find unpaid invoices', limit: 5 });

// Direct execution with cost tracking
const result = await client.perform('salesforce@1/get_lead@1', { id: '123' });
```

Pass `useIntelligentInterface: false` to opt out and see all raw tools.

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
// MCP (default) — full MCP protocol over Streamable HTTP
const client = new Client({ url });

// JSONRPC — lightweight, stateless, same tools and auth
const client = new Client({ url, transport: 'jsonrpc' });

// WebSocket — bidirectional push
const client = new Client({
  url: 'wss://gateway.datagrout.ai/servers/{uuid}/ws',
  transport: 'websocket',
});
```

### WebSocket transport

The WebSocket transport uses the `datagrout-jsonrpc.v1` subprotocol over a single persistent `wss://` connection. Concurrent requests are multiplexed; responses correlated by JSON-RPC `id` via `Map<string, { resolve, reject }>`.

```typescript
import { Client } from '@datagrout/conduit';

const client = new Client({
  url: 'wss://gateway.datagrout.ai/servers/{uuid}/ws',
  auth: { bearer: 'your-token' },
  transport: 'websocket',
});
await client.connect();

// Subscribe to server-pushed events
const sub = await client.subscribe('agents.my-agent-id.events');

for await (const event of sub) {
  console.log(event.event, event.data);
}

await client.unsubscribe(sub.id);
await client.disconnect();
```

You can also call `await sub.recv()` for one-event-at-a-time consumption:

```typescript
const event = await sub.recv();
console.log(event.event, event.data);
```

Supported topics:

| Topic | Fires when |
|-------|-----------|
| `agents.<agent_id>.events` | Agent lifecycle events (plan started, IC completed, grounding failed, …) |
| `tools.<tool_name>.results` | A specific tool call completes |
| `tasks.<task_id>.*` | Long-running background task transitions |
| `flows.<flow_id>.*` | `flow.into` progress and completion |
| `governor.<server_uuid>` | Governor percept events (file change, schedule, webhook) |

**Reconnection**: after a disconnect, calls raise `NotInitializedError`. Re-call `connect()` and re-subscribe — subscriptions do not survive reconnects in v0.4.

## API Reference

### Client Options

```typescript
new Client(options: {
  url: string;
  auth?: { bearer?: string; apiKey?: string; clientCredentials?: {...} };
  transport?: 'mcp' | 'jsonrpc' | 'websocket';
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
