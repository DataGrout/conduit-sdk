"""Basic usage example for DataGrout Conduit."""

import asyncio
from datagrout.conduit import Client


async def main():
    """Demonstrate basic Conduit usage."""
    
    # Initialize client (uses MCP transport by default)
    async with Client(
        "https://gateway.datagrout.ai/servers/YOUR_SERVER_UUID/mcp",
        auth={"bearer": "YOUR_API_KEY"}
    ) as client:
        
        # List tools (automatically filtered to DataGrout tools)
        print("=== Available Tools ===")
        tools = await client.list_tools()
        for tool in tools:
            print(f"  - {tool['name']}: {tool['description']}")
        
        # Call a tool (standard MCP method)
        print("\n=== Calling Tool ===")
        result = await client.call_tool(
            "salesforce@1/get_lead@1",
            {"id": "00Q5G00000ABC123"}
        )
        print(f"Result: {result}")
        
        # Check receipt
        receipt = client.get_last_receipt()
        if receipt:
            print(f"\nCredits used: {receipt.actual_credits}")
            print(f"Estimated: {receipt.estimated_credits}")
            print(f"Savings: {receipt.savings}")


if __name__ == "__main__":
    asyncio.run(main())
