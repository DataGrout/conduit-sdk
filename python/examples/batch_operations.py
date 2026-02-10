"""Batch operations example for DataGrout Conduit."""

import asyncio
from datagrout.conduit import Client


async def main():
    """Demonstrate parallel batch execution."""
    
    async with Client(
        "https://gateway.datagrout.ai/servers/YOUR_SERVER_UUID/mcp",
        auth={"bearer": "YOUR_API_KEY"}
    ) as client:
        
        # Execute multiple tools in parallel
        print("=== Batch Tool Execution ===")
        
        calls = [
            {
                "tool": "salesforce@1/get_lead@1",
                "args": {"id": "00Q5G00000ABC123"}
            },
            {
                "tool": "salesforce@1/get_lead@1",
                "args": {"id": "00Q5G00000DEF456"}
            },
            {
                "tool": "quickbooks@1/get_invoice@1",
                "args": {"id": "INV-001"}
            }
        ]
        
        results = await client.perform_batch(calls)
        
        print(f"Executed {len(results)} tools in parallel:\n")
        for i, result in enumerate(results):
            print(f"Call {i+1}: {result}")
        
        # Check cumulative cost
        receipt = client.get_last_receipt()
        if receipt:
            print(f"\nTotal credits used: {receipt.actual_credits}")
            print(f"Breakdown: {receipt.breakdown}")


if __name__ == "__main__":
    asyncio.run(main())
