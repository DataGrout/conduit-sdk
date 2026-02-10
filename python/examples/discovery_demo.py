"""Semantic discovery example for DataGrout Conduit."""

import asyncio
from datagrout.conduit import Client


async def main():
    """Demonstrate semantic discovery."""
    
    async with Client(
        "https://gateway.datagrout.ai/servers/YOUR_SERVER_UUID/mcp",
        auth={"bearer": "YOUR_API_KEY"}
    ) as client:
        
        # Discover tools by query
        print("=== Discovering Tools ===")
        results = await client.discover(
            query="find unpaid invoices",
            limit=10,
            integrations=["salesforce", "quickbooks"]
        )
        
        print(f"Query: {results.query_used}")
        print(f"Found {results.total} tools:\n")
        
        for tool in results.results:
            print(f"  {tool.tool_name}")
            print(f"    Integration: {tool.integration}")
            print(f"    Score: {tool.score:.2f}")
            print(f"    Description: {tool.description}")
            print()
        
        # Perform a tool call
        if results.results:
            tool_name = results.results[0].tool_name
            print(f"=== Executing Top Tool: {tool_name} ===")
            
            result = await client.perform(
                tool=tool_name,
                args={"limit": 5}
            )
            print(f"Result: {result}")
            
            # Check cost
            receipt = client.get_last_receipt()
            if receipt:
                print(f"\nCredits used: {receipt.actual_credits}")


if __name__ == "__main__":
    asyncio.run(main())
