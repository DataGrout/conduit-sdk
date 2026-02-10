# DataGrout Conduit

**Production-Ready MCP Client**

Drop-in replacement for standard MCP clients with enterprise features built-in.

## What is Conduit?

Conduit is an intelligent MCP client that provides:
- 🧠 **10-100x token efficiency** via neurosymbolic runtime
- 💰 **Built-in cost tracking** with itemized receipts
- 🔍 **Semantic discovery** (solves the N×M problem for 1000+ tools)
- 🔒 **Formal verification** with Cognitive Trust Certificates (CTCs)
- 🛡️ **Runtime policy enforcement** (PII redaction, side effects)
- ✅ **Drop-in compatible** with standard MCP

## Quick Start

### Python

```bash
pip install datagrout-conduit
```

```python
# Before: Standard MCP
# from mcp import Client

# After: DataGrout Conduit (zero code changes)
from datagrout.conduit import Client

client = Client("https://gateway.datagrout.ai/servers/{uuid}/mcp")

# Standard MCP methods work, but now enhanced
tools = await client.list_tools()  # Automatically filtered via discovery
result = await client.call_tool("salesforce@1/get_lead@1", {"id": "123"})

# Plus DataGrout-specific features
results = await client.discover(query="find unpaid invoices", limit=10)
session = await client.guide(goal="create invoice from lead")
```

### TypeScript

```bash
npm install @datagrout/conduit
```

```typescript
// Before: Standard MCP
// import { Client } from '@modelcontextprotocol/sdk';

// After: DataGrout Conduit (zero code changes)
import { Client } from '@datagrout/conduit';

const client = new Client('https://gateway.datagrout.ai/servers/{uuid}/mcp');

// Standard MCP methods work, but now enhanced
const tools = await client.listTools();  // Automatically filtered
const result = await client.callTool('salesforce@1/get_lead@1', {id: '123'});

// Plus DataGrout-specific features
const results = await client.discover({query: 'find unpaid invoices', limit: 10});
const session = await client.guide({goal: 'create invoice from lead'});
```

## Why Conduit?

### The N×M Problem

Standard MCP `tools/list` returns ALL tools. With enterprise integrations like Salesforce (1000+ tools) and QuickBooks (500+ tools), agents get overwhelmed.

**Solution**: Conduit automatically uses semantic discovery to return only relevant tools for your agent's task.

### Token Efficiency

Traditional agents make 7+ LLM calls per multi-step workflow, burning 150k+ tokens.

**Solution**: Conduit's server-side symbolic planning reduces this to 2 LLM calls and 3.5k tokens (92% reduction).

### Cost Transparency

Every operation returns an itemized receipt showing exactly what you spent and why.

### Formal Safety

Cognitive Trust Certificates (CTCs) provide cryptographic proof that workflows are:
- Cycle-free (no infinite loops)
- Type-safe (all transformations valid)
- Policy-compliant (no unauthorized operations)
- Budget-respecting (no cost overruns)

## Available Languages

- **Python** - `pip install datagrout-conduit`
- **TypeScript** - `npm install @datagrout/conduit`

Additional languages coming soon: Rust, Elixir, Go, Ruby

## Documentation

- [Python Documentation](./python/README.md)
- [TypeScript Documentation](./typescript/README.md)
- [Concepts](./docs/concepts/)
- [API Reference](./docs/api/)

## Powered By

DataGrout Conduit is powered by [DataGrout](https://datagrout.ai) - The Cognitive Integration Marketplace.

**FHIM Stack:**
- 🏗️ **Foundry** - Design tools and agents
- 🎯 **Hub** - Connect to real systems
- 🧠 **Intelligence** - Neurosymbolic execution
- 💾 **Memory** - Curated context (coming soon)

## License

MIT (or your preferred license)
