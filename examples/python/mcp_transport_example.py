"""Example: Using official MCP transport with Conduit."""

import asyncio
from datagrout.conduit import Client


async def stdio_example():
    """Connect to local MCP server via stdio."""
    print("=== Stdio Transport Example ===\n")

    async with Client(
        url="stdio://python -m my_mcp_server",
        transport="mcp"
    ) as client:
        # List available tools
        tools = await client.list_tools()
        print(f"Found {len(tools)} tools:")
        for tool in tools[:3]:  # Show first 3
            print(f"  - {tool['name']}")

        # Call a tool
        if tools:
            tool_name = tools[0]['name']
            print(f"\nCalling {tool_name}...")
            result = await client.call_tool(tool_name, {})
            print(f"Result: {result}")


async def sse_example():
    """Connect to DataGrout Gateway via SSE/HTTP."""
    print("\n=== SSE Transport Example ===\n")

    async with Client(
        url="https://gateway.datagrout.ai/servers/{uuid}/mcp",
        transport="mcp",
        auth={"bearer": "your-token-here"}
    ) as client:
        # Semantic discovery (DataGrout extension)
        print("Discovering Salesforce tools...")
        discovery = await client.discover(
            query="get lead by email",
            integrations=["salesforce"]
        )

        print(f"Found {len(discovery.tools)} tools:")
        for tool in discovery.tools:
            print(f"  - {tool.name} (score: {tool.score:.2f})")

        # Guided workflow (DataGrout extension)
        if discovery.tools:
            print("\nStarting guided workflow...")
            session = await client.guide(
                goal="Find lead with email john@example.com"
            )

            print(f"Session status: {session.status}")
            print(f"Available options: {len(session.options)}")

            # If choices available, select one
            if session.options:
                chosen = session.options[0]
                print(f"\nChoosing: {chosen.label}")
                next_session = await session.choose(chosen.id)
                print(f"New status: {next_session.status}")


async def compare_transports():
    """Compare MCP vs JSONRPC transport."""
    print("\n=== Transport Comparison ===\n")

    url = "https://gateway.datagrout.ai/servers/{uuid}/mcp"
    auth = {"bearer": "your-token"}

    # MCP transport (official SDK)
    print("Using MCP transport (official SDK):")
    async with Client(url=url, transport="mcp", auth=auth) as client:
        tools = await client.list_tools()
        print(f"  Tools found: {len(tools)}")
        print(f"  Transport: MCP (SSE, persistent connection)")

    # JSONRPC transport (lightweight)
    print("\nUsing JSONRPC transport (lightweight):")
    async with Client(url=url, transport="jsonrpc", auth=auth) as client:
        tools = await client.list_tools()
        print(f"  Tools found: {len(tools)}")
        print(f"  Transport: JSONRPC (HTTP, stateless)")


async def main():
    """Run all examples."""
    print("DataGrout Conduit - MCP Transport Examples")
    print("=" * 50)

    # Choose which examples to run
    # await stdio_example()
    # await sse_example()
    await compare_transports()


if __name__ == "__main__":
    asyncio.run(main())
