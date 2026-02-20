# DataGrout Conduit - Python SDK

Production-ready MCP client for Python with enterprise features built-in.

## Installation

```bash
pip install datagrout-conduit
```

## Quick Start

```python
from datagrout.conduit import Client

# Connect to DataGrout gateway
client = Client("https://gateway.datagrout.ai/servers/{your-server-uuid}/mcp")

# Standard MCP methods (enhanced automatically)
tools = await client.list_tools()
result = await client.call_tool("salesforce@1/get_lead@1", {"id": "123"})

# DataGrout-specific features
results = await client.discover(query="find unpaid invoices", limit=10)
session = await client.guide(goal="create invoice from lead")
receipt = client.get_last_receipt()
```

## Features

### Drop-in Replacement

Replace your MCP client import with Conduit:

```python
# Before
from mcp import Client

# After
from datagrout.conduit import Client

# Everything else stays the same
```

### Automatic Discovery

When `hide_3rd_party_tools=True` (default), `list_tools()` returns only DataGrout gateway tools. Your agent automatically uses semantic discovery:

```python
# Agent calls standard MCP
tools = await client.list_tools()
# Returns: [discover, perform, guide, flow.into, prism.focus, ...]

# Agent naturally calls discover
results = await client.call_tool("data-grout/discovery.discover", {
    "query": "find unpaid invoices"
})
# Gets filtered, relevant tools for its task
```

### Cost Tracking

Every operation tracks credits automatically:

```python
result = await client.call_tool("salesforce@1/get_lead@1", {"id": "123"})

receipt = client.get_last_receipt()
print(f"Credits used: {receipt['actual_credits']}")
print(f"Breakdown: {receipt['breakdown']}")
```

### Dual Transport Modes

```python
# Mode 1: Pure JSONRPC (default — no extra dependencies)
client = Client(url, transport="jsonrpc")

# Mode 2: MCP-backed (uses the official mcp package)
client = Client(url, transport="mcp")
```

## API Reference

### Client Configuration

```python
Client(
    url: str,
    auth: dict = None,
    use_intelligent_interface: bool = False,
    transport: str = "jsonrpc",
    **kwargs
)
```

### Standard MCP Methods

- `list_tools()` - List available tools (enhanced with discovery)
- `call_tool(name, arguments)` - Execute tool (enhanced with perform)
- `list_resources()` - List resources
- `read_resource(uri)` - Read resource
- `list_prompts()` - List prompts
- `get_prompt(name, arguments)` - Get prompt

### DataGrout Methods

- `discover(query, limit, integrations)` - Semantic tool search
- `perform(tool, args, demux)` - Direct tool execution
- `perform_batch(calls)` - Batch execution
- `guide(goal, policy, session_id)` - Guided workflow
- `flow_into(plan, validate_ctc, save_as_skill)` - Workflow orchestration
- `prism_focus(data, source_type, target_type)` - Type transformation

### Receipt Methods

- `get_last_receipt()` - Get receipt from last operation
- `estimate_cost(tool, args)` - Estimate credits before execution

## Examples

See [examples/](./examples/) directory for complete working examples:

- `basic_usage.py` - Getting started
- `discovery_demo.py` - Semantic tool discovery
- `guided_workflow.py` - Stateful workflow navigation
- `batch_operations.py` - Parallel tool execution
- `cost_tracking.py` - Credit management

## Requirements

- Python 3.10+
- `mcp` package (for MCP transport mode)
- `httpx` (for JSONRPC transport mode)

## License

MIT
