# DataGrout Conduit - Quick Start

Get up and running with DataGrout Conduit in 5 minutes.

## Installation

### Python

```bash
pip install datagrout-conduit
```

### TypeScript

```bash
npm install @datagrout/conduit
```

## Get Your Server URL

1. Sign up at [datagrout.ai](https://datagrout.ai)
2. Create a server (connects your integrations)
3. Copy your server URL: `https://gateway.datagrout.ai/servers/{your-uuid}/mcp`
4. Generate an API key

## First Request

### Python

```python
import asyncio
from datagrout.conduit import Client

async def main():
    async with Client(
        "https://gateway.datagrout.ai/servers/YOUR_UUID/mcp",
        auth={"bearer": "YOUR_API_KEY"}
    ) as client:
        # Discover tools
        results = await client.discover(
            query="find unpaid invoices",
            limit=5
        )
        
        print(f"Found {results.total} relevant tools:")
        for tool in results.results:
            print(f"  - {tool.tool_name} (score: {tool.score:.2f})")
        
        # Execute top tool
        if results.results:
            result = await client.perform(
                tool=results.results[0].tool_name,
                args={"limit": 10}
            )
            print(f"\nResult: {result}")
            
            # Check cost
            receipt = client.get_last_receipt()
            print(f"Credits used: {receipt.actual_credits}")

asyncio.run(main())
```

### TypeScript

```typescript
import { Client } from '@datagrout/conduit';

async function main() {
  const client = new Client({
    url: 'https://gateway.datagrout.ai/servers/YOUR_UUID/mcp',
    auth: { bearer: 'YOUR_API_KEY' },
  });

  await client.connect();

  try {
    // Discover tools
    const results = await client.discover({
      query: 'find unpaid invoices',
      limit: 5,
    });

    console.log(`Found ${results.total} relevant tools:`);
    for (const tool of results.results) {
      console.log(`  - ${tool.toolName} (score: ${tool.score?.toFixed(2)})`);
    }

    // Execute top tool
    if (results.results.length > 0) {
      const result = await client.perform({
        tool: results.results[0].toolName,
        args: { limit: 10 },
      });
      console.log('\nResult:', result);

      // Check cost
      const receipt = client.getLastReceipt();
      console.log(`Credits used: ${receipt?.actualCredits}`);
    }
  } finally {
    await client.disconnect();
  }
}

main().catch(console.error);
```

## Drop-in Replacement

If you have existing MCP code, just change the import:

### Python

```python
# Before
from mcp import Client

# After
from datagrout.conduit import Client

# Everything else stays the same
client = Client(url)
tools = await client.list_tools()  # Now enhanced with discovery
result = await client.call_tool(name, args)  # Now tracked with receipts
```

### TypeScript

```typescript
// Before
import { Client } from '@modelcontextprotocol/sdk';

// After
import { Client } from '@datagrout/conduit';

// Everything else stays the same
const client = new Client(url);
const tools = await client.listTools();  // Now enhanced with discovery
const result = await client.callTool(name, args);  // Now tracked with receipts
```

## Common Patterns

### 1. Semantic Search → Execute

```python
# Discover relevant tools
results = await client.discover(query="get customer by email")

# Execute the best match
if results.results:
    result = await client.perform(
        tool=results.results[0].tool_name,
        args={"email": "john@acme.com"}
    )
```

### 2. Guided Workflow

```python
# Start a guided session
session = await client.guide(
    goal="Create invoice from Salesforce lead",
    policy={"max_cost": 10.0}
)

# Navigate through options
while session.status == "ready":
    viable = [opt for opt in session.options if opt.viable]
    if viable:
        session = await session.choose(viable[0].id)

# Get result
result = await session.complete()
```

### 3. Multi-step Workflow

```python
# Define workflow
plan = [
    {
        "step": 1,
        "type": "tool_call",
        "tool": "salesforce@1/get_lead@1",
        "args": {"email": "$input.email"},
        "output": "lead"
    },
    {
        "step": 2,
        "type": "tool_call",
        "tool": "quickbooks@1/create_customer@1",
        "args": {"lead": "$lead"},
        "output": "customer"
    }
]

# Execute with CTC validation
result = await client.flow_into(
    plan=plan,
    validate_ctc=True,
    input_data={"email": "john@acme.com"}
)
```

### 4. Cost Estimation

```python
# Estimate before executing
estimate = await client.estimate_cost(
    tool="salesforce@1/query_leads@1",
    args={"query": "SELECT * FROM Lead LIMIT 1000"}
)

print(f"Estimated cost: {estimate['credits']} credits")

# Decide whether to proceed
if estimate['credits'] < 5.0:
    result = await client.perform(...)
```

## Next Steps

- Read the [Concepts Guide](./CONCEPTS.md) to understand how Conduit works
- Check out [Examples](../python/examples/) for more patterns
- Browse the [API Reference](./API.md) for all available methods
- Learn about [Enterprise Features](./ENTERPRISE.md) for production use

## Getting Help

- Documentation: [conduit.datagrout.dev](https://conduit.datagrout.dev)
- GitHub Issues: [github.com/datagrout/conduit/issues](https://github.com/datagrout/conduit/issues)
- Discord: [discord.gg/datagrout](https://discord.gg/datagrout)
- Email: [hello@datagrout.ai](mailto:hello@datagrout.ai)
