# DataGrout Conduit - Core Concepts

This document explains the key concepts behind DataGrout Conduit and how it enhances standard MCP.

## The Drop-in Strategy

Conduit is designed as a **drop-in replacement** for standard MCP clients. Replace one import line and immediately get:

- 10-100x token efficiency
- Cost tracking with receipts
- Semantic discovery
- Formal verification (CTCs)
- Runtime policy enforcement

```python
# Before
from mcp import Client

# After
from datagrout.conduit import Client

# Everything else stays the same
```

## How It Works

### 1. Transparent Enhancement

When `hide_3rd_party_tools=True` (default), Conduit returns only DataGrout gateway tools from `list_tools()`:

- `data-grout/discovery.discover` - Semantic tool search
- `data-grout/discovery.perform` - Direct execution
- `data-grout/discovery.guide` - Guided workflows
- `data-grout/flow.into` - Workflow orchestration
- `data-grout/prism.focus` - Type transformation

Your agent naturally calls these, unlocking the full intelligence layer.

### 2. Automatic Routing

All `call_tool()` requests automatically route through `discovery.perform`, which:

- Tracks credits with itemized receipts
- Applies policy enforcement (PII redaction, side effects)
- Enables BYOK discounts
- Provides cost estimates

You get enterprise features without changing agent code.

## Key Features

### Semantic Discovery

**Problem**: Standard MCP returns ALL tools. With Salesforce (1000+ tools) + QuickBooks (500+ tools), agents get overwhelmed.

**Solution**: `discover()` uses semantic search to return only relevant tools.

```python
results = await client.discover(
    query="find unpaid invoices",
    integrations=["salesforce", "quickbooks"]
)
# Returns: Top 10 most relevant tools (0.95+ semantic score)
```

### Credit System

Every operation returns an itemized receipt:

```python
{
  "receipt_id": "rcp_abc123",
  "estimated_credits": 5.0,
  "actual_credits": 4.2,
  "savings": 0.8,
  "breakdown": {
    "salesforce_api_call": 2.0,
    "type_transformation": 1.5,
    "planning": 0.7
  }
}
```

Agents can:
- Get cost estimates before execution
- Make budget-aware decisions
- Track spending per workflow

### Neurosymbolic Runtime

**Traditional LLM Workflow** (7+ calls, 150k+ tokens):
1. Agent gets goal
2. Agent calls `tools/list` (1500 tools!)
3. Agent asks LLM to filter tools (50k tokens)
4. Agent asks LLM to plan workflow (50k tokens)
5. Agent executes step 1
6. Agent asks LLM for next step (30k tokens)
7. ... repeat for each step

**DataGrout Workflow** (2 calls, 3.5k tokens):
1. Agent calls `discover()` with goal
2. DataGrout's Prolog engine plans workflow symbolically
3. Agent calls `flow.into()` with plan
4. Done (92% token reduction)

The symbolic planning engine:
- Finds type-safe paths through tool graph
- Respects policy constraints
- Optimizes for cost (Pareto frontiers)
- No LLM needed for deterministic logic

### Guided Workflows

Like a MUD (multi-user dungeon) game, agents navigate step-by-step:

```python
session = await client.guide(
    goal="Create invoice from lead email",
    policy={"max_cost": 10.0}
)

while session.status == "ready":
    # System presents viable options
    for opt in session.options:
        print(f"{opt.label} (cost: {opt.cost})")
    
    # Agent chooses
    session = await session.choose("option_1")

result = await session.complete()
```

Benefits:
- No multi-turn token explosion
- Policy enforced at each step
- Agent can't deviate from validated paths
- Formal verification via CTCs

### Cognitive Trust Certificates (CTCs)

Every `flow.into()` workflow gets a cryptographically signed CTC proving:

- ✅ **Cycle-free**: No infinite loops
- ✅ **Type-safe**: All transformations valid
- ✅ **Policy-compliant**: No unauthorized operations
- ✅ **Budget-respecting**: Stays under cost limit
- ✅ **Credentials available**: Has access to required systems
- ✅ **Inputs consumed**: All required data provided

CTCs enable:
- Audit trails for compliance
- Reproducible workflows
- Skill reuse (validated workflows become tools)

### Type Transformation (Prism)

**Problem**: Salesforce Lead has different schema than QuickBooks Customer. Agents manually map fields.

**Solution**: Semantic types + adapters.

```python
transformed = await client.prism_focus(
    data=lead_data,
    source_type="crm.lead@1",
    target_type="billing.customer@1"
)
# Automatically finds adapter and transforms
```

The system:
- Maintains semantic type registry
- Stores adapter DAGs between types
- Auto-enriches missing fields (e.g., fetch address from email)
- Reports unmappable fields

## Architecture

```
┌─────────────────────────────────────────────┐
│          Your Agent (unchanged)             │
│  Uses standard MCP: list_tools, call_tool  │
└─────────────────┬───────────────────────────┘
                  │
                  ▼
┌─────────────────────────────────────────────┐
│         DataGrout Conduit (SDK)             │
│  - Transparent routing                      │
│  - Receipt tracking                         │
│  - Native DataGrout methods                 │
└─────────────────┬───────────────────────────┘
                  │
                  ▼
┌─────────────────────────────────────────────┐
│      DataGrout Gateway (gateway.datagrout.ai)
│                                             │
│  ┌──────────────────────────────────────┐  │
│  │  INTELLIGENCE LAYER                  │  │
│  │  - Semantic Discovery (embeddings)   │  │
│  │  - Symbolic Planning (Prolog)        │  │
│  │  - Type System (Semio)               │  │
│  │  - Policy Engine (Guards/Redaction)  │  │
│  └──────────────────────────────────────┘  │
│                                             │
│  ┌──────────────────────────────────────┐  │
│  │  HUB LAYER                           │  │
│  │  - Integration connectors            │  │
│  │  - Multiplexer/Demultiplexer         │  │
│  │  - Credential management             │  │
│  └──────────────────────────────────────┘  │
└─────────────────┬───────────────────────────┘
                  │
                  ▼
┌─────────────────────────────────────────────┐
│      Enterprise Systems                     │
│  Salesforce, QuickBooks, etc.               │
└─────────────────────────────────────────────┘
```

## Why This Matters

### For Individual Developers

- Write agents faster (use semantic discovery instead of hardcoding tools)
- Debug easily (receipts show exactly what happened)
- Stay in budget (cost-aware from the start)

### For Enterprises

- **Trust**: CTCs provide formal verification for compliance
- **Security**: Policy enforcement at runtime (no PII leaks)
- **Cost control**: Credit system with agent-level budgets
- **Private data**: Private Connectors keep data on-premise

### For AI Providers

- **Token efficiency**: 10-100x reduction = 10-100x more requests per $$
- **Reliability**: Symbolic planning eliminates hallucinated workflows
- **Composability**: Skills (validated workflows) become reusable tools

## Next Steps

- [Python Documentation](../python/README.md)
- [TypeScript Documentation](../typescript/README.md)
- [API Reference](./API.md)
- [Enterprise Guide](./ENTERPRISE.md)
