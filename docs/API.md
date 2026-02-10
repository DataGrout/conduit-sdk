# DataGrout Conduit - API Reference

Complete API documentation for Python and TypeScript SDKs.

## Client

### Constructor

**Python:**
```python
Client(
    url: str,
    auth: dict = None,
    hide_3rd_party_tools: bool = True,
    transport: str = "jsonrpc",
    **kwargs
)
```

**TypeScript:**
```typescript
new Client(options: {
  url: string;
  auth?: AuthConfig;
  hide3rdPartyTools?: boolean;
  transport?: 'mcp' | 'jsonrpc';
  timeout?: number;
})
```

**Parameters:**
- `url` - Gateway URL (e.g., `https://gateway.datagrout.ai/servers/{uuid}/mcp`)
- `auth` - Authentication config
  - `bearer` - Bearer token
  - `basic` - Basic auth (username, password)
  - `custom` - Custom headers
- `hide_3rd_party_tools` - If true, only return DataGrout tools from `list_tools()`
- `transport` - Transport mode: `"mcp"` (official SDK) or `"jsonrpc"` (direct HTTP)
- `timeout` - Request timeout in milliseconds (TypeScript only)

### Standard MCP Methods

#### list_tools()

List available tools (enhanced with discovery).

**Python:**
```python
tools = await client.list_tools()
```

**TypeScript:**
```typescript
const tools = await client.listTools();
```

**Returns:**
```python
[
  {
    "name": "data-grout/discovery.discover",
    "description": "Semantic tool discovery...",
    "inputSchema": {...}
  },
  ...
]
```

#### call_tool()

Execute a tool (automatically routed through `discovery.perform`).

**Python:**
```python
result = await client.call_tool(
    "salesforce@1/get_lead@1",
    {"id": "00Q5G00000ABC123"}
)
```

**TypeScript:**
```typescript
const result = await client.callTool(
  'salesforce@1/get_lead@1',
  {id: '00Q5G00000ABC123'}
);
```

**Returns:** Tool-specific result with automatic receipt tracking.

#### list_resources()

List available resources.

**Python:**
```python
resources = await client.list_resources()
```

**TypeScript:**
```typescript
const resources = await client.listResources();
```

#### read_resource()

Read a resource by URI.

**Python:**
```python
content = await client.read_resource("file://data/config.json")
```

**TypeScript:**
```typescript
const content = await client.readResource('file://data/config.json');
```

#### list_prompts()

List available prompts.

**Python:**
```python
prompts = await client.list_prompts()
```

**TypeScript:**
```typescript
const prompts = await client.listPrompts();
```

#### get_prompt()

Get a prompt with optional arguments.

**Python:**
```python
prompt = await client.get_prompt("summarize", {"format": "json"})
```

**TypeScript:**
```typescript
const prompt = await client.getPrompt('summarize', {format: 'json'});
```

### DataGrout Methods

#### discover()

Semantic tool discovery with natural language queries.

**Python:**
```python
results = await client.discover(
    query="find unpaid invoices",
    goal=None,                      # Alternative to query
    limit=10,
    min_score=0.0,
    integrations=["salesforce"],    # Filter by integration
    servers=None,                    # Filter by server ID
)
```

**TypeScript:**
```typescript
const results = await client.discover({
  query: 'find unpaid invoices',
  goal: undefined,
  limit: 10,
  minScore: 0.0,
  integrations: ['salesforce'],
  servers: undefined,
});
```

**Returns:**
```python
{
  "query_used": "find unpaid invoices",
  "results": [
    {
      "tool_name": "salesforce@1/query_opportunities@1",
      "integration": "salesforce",
      "score": 0.95,
      "description": "Query opportunities with SOQL",
      "input_schema": {...}
    },
    ...
  ],
  "total": 47,
  "limit": 10
}
```

#### perform()

Direct tool execution with credit tracking.

**Python:**
```python
result = await client.perform(
    tool="salesforce@1/get_lead@1",
    args={"id": "00Q5G00000ABC123"},
    demux=False,           # Enable demultiplexing
    demux_mode="strict",   # "strict" or "fuzzy"
)
```

**TypeScript:**
```typescript
const result = await client.perform({
  tool: 'salesforce@1/get_lead@1',
  args: {id: '00Q5G00000ABC123'},
  demux: false,
  demuxMode: 'strict',
});
```

**Returns:** Tool result with receipt tracked internally.

#### perform_batch()

Execute multiple tools in parallel.

**Python:**
```python
results = await client.perform_batch([
    {"tool": "salesforce@1/get_lead@1", "args": {"id": "123"}},
    {"tool": "quickbooks@1/get_invoice@1", "args": {"id": "INV-001"}},
])
```

**TypeScript:**
```typescript
const results = await client.performBatch([
  {tool: 'salesforce@1/get_lead@1', args: {id: '123'}},
  {tool: 'quickbooks@1/get_invoice@1', args: {id: 'INV-001'}},
]);
```

**Returns:** Array of results (same order as input).

#### guide()

Start or continue guided workflow.

**Python:**
```python
session = await client.guide(
    goal="Create invoice from lead",
    policy={
        "max_steps": 5,
        "max_cost": 10.0,
        "require_approval": ["write", "delete"]
    },
    session_id=None,    # Continue existing session
    choice=None,        # Choose option (when continuing)
)
```

**TypeScript:**
```typescript
const session = await client.guide({
  goal: 'Create invoice from lead',
  policy: {
    max_steps: 5,
    max_cost: 10.0,
    require_approval: ['write', 'delete'],
  },
  sessionId: undefined,
  choice: undefined,
});
```

**Returns:** `GuidedSession` instance.

##### GuidedSession

**Properties:**
- `session_id` / `sessionId` - Unique session ID
- `status` - Current status ("ready", "completed", "failed")
- `options` - Available options at current step
- `result` - Final result (if completed)

**Methods:**

**Python:**
```python
# Choose an option
session = await session.choose("option_1")

# Get full state
state = session.get_state()

# Complete and get result
result = await session.complete()
```

**TypeScript:**
```typescript
// Choose an option
session = await session.choose('option_1');

// Get full state
const state = session.getState();

// Complete and get result
const result = await session.complete();
```

#### flow_into()

Multi-step workflow orchestration with CTC validation.

**Python:**
```python
result = await client.flow_into(
    plan=[
        {
            "step": 1,
            "type": "tool_call",
            "tool": "salesforce@1/get_lead@1",
            "args": {"email": "$input.email"},
            "output": "lead"
        },
        {
            "step": 2,
            "type": "focus",
            "source_type": "crm.lead@1",
            "target_type": "billing.customer@1",
            "input": "$lead",
            "output": "customer"
        },
        {
            "step": 3,
            "type": "tool_call",
            "tool": "quickbooks@1/create_invoice@1",
            "args": {"customer": "$customer"},
            "output": "invoice"
        }
    ],
    validate_ctc=True,      # Generate CTC
    save_as_skill=False,    # Save as reusable skill
    input_data={"email": "john@acme.com"}
)
```

**TypeScript:**
```typescript
const result = await client.flowInto({
  plan: [
    {
      step: 1,
      type: 'tool_call',
      tool: 'salesforce@1/get_lead@1',
      args: {email: '$input.email'},
      output: 'lead',
    },
    // ... more steps
  ],
  validateCtc: true,
  saveAsSkill: false,
  inputData: {email: 'john@acme.com'},
});
```

**Returns:** Workflow result with CTC (if requested).

#### prism_focus()

Semantic type transformation.

**Python:**
```python
transformed = await client.prism_focus(
    data=lead_data,
    source_type="crm.lead@1",
    target_type="billing.customer@1"
)
```

**TypeScript:**
```typescript
const transformed = await client.prismFocus({
  data: leadData,
  sourceType: 'crm.lead@1',
  targetType: 'billing.customer@1',
});
```

**Returns:** Transformed data in target type.

### Receipt Management

#### get_last_receipt()

Get receipt from last operation.

**Python:**
```python
receipt = client.get_last_receipt()
```

**TypeScript:**
```typescript
const receipt = client.getLastReceipt();
```

**Returns:**
```python
{
  "receipt_id": "rcp_abc123",
  "estimated_credits": 5.0,
  "actual_credits": 4.2,
  "net_credits": 4.2,
  "savings": 0.8,
  "savings_bonus": 0.0,
  "breakdown": {
    "salesforce_api": 2.0,
    "type_transform": 1.5,
    "planning": 0.7
  },
  "byok": {
    "enabled": true,
    "discount": 20
  }
}
```

#### estimate_cost()

Get cost estimate before execution.

**Python:**
```python
estimate = await client.estimate_cost(
    "salesforce@1/query_leads@1",
    {"query": "SELECT Id FROM Lead LIMIT 100"}
)
```

**TypeScript:**
```typescript
const estimate = await client.estimateCost(
  'salesforce@1/query_leads@1',
  {query: 'SELECT Id FROM Lead LIMIT 100'}
);
```

**Returns:** Cost estimate with breakdown.

## Error Handling

**Python:**
```python
from datagrout.conduit import Client

async with Client(url, auth=auth) as client:
    try:
        result = await client.perform(tool="...", args={...})
    except Exception as e:
        print(f"Error: {e}")
```

**TypeScript:**
```typescript
import { Client } from '@datagrout/conduit';

const client = new Client({url, auth});
await client.connect();

try {
  const result = await client.perform({tool: '...', args: {}});
} catch (error) {
  console.error('Error:', error);
} finally {
  await client.disconnect();
}
```

## Transport Options

### JSONRPC (Default, Recommended)

Simple HTTP transport with no MCP dependency.

**Python:**
```python
client = Client(url, transport="jsonrpc")
```

**TypeScript:**
```typescript
const client = new Client({url, transport: 'jsonrpc'});
```

### MCP (Official SDK)

Uses official MCP client libraries.

**Python:**
```python
client = Client(url, transport="mcp")
```

**TypeScript:**
```typescript
const client = new Client({url, transport: 'mcp'});
```

## Authentication

### Bearer Token

**Python:**
```python
client = Client(url, auth={"bearer": "sk_live_..."})
```

**TypeScript:**
```typescript
const client = new Client({
  url,
  auth: {bearer: 'sk_live_...'},
});
```

### Basic Auth

**Python:**
```python
client = Client(url, auth={
    "basic": {
        "username": "user",
        "password": "pass"
    }
})
```

**TypeScript:**
```typescript
const client = new Client({
  url,
  auth: {
    basic: {
      username: 'user',
      password: 'pass',
    },
  },
});
```

### Custom Headers

**Python:**
```python
client = Client(url, auth={
    "custom": {
        "X-API-Key": "...",
        "X-Tenant-ID": "..."
    }
})
```

**TypeScript:**
```typescript
const client = new Client({
  url,
  auth: {
    custom: {
      'X-API-Key': '...',
      'X-Tenant-ID': '...',
    },
  },
});
```
