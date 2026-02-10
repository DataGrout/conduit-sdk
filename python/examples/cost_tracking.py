"""Cost tracking and estimation example for DataGrout Conduit."""

import asyncio
from datagrout.conduit import Client


async def main():
    """Demonstrate cost tracking and estimation."""
    
    async with Client(
        "https://gateway.datagrout.ai/servers/YOUR_SERVER_UUID/mcp",
        auth={"bearer": "YOUR_API_KEY"}
    ) as client:
        
        # Get cost estimate before execution
        print("=== Cost Estimation ===")
        estimate = await client.estimate_cost(
            tool="salesforce@1/query_leads@1",
            args={"query": "SELECT Id, Email FROM Lead LIMIT 100"}
        )
        
        print(f"Estimated credits: {estimate}")
        
        # Execute and compare
        print("\n=== Executing Tool ===")
        result = await client.perform(
            tool="salesforce@1/query_leads@1",
            args={"query": "SELECT Id, Email FROM Lead LIMIT 100"}
        )
        
        receipt = client.get_last_receipt()
        if receipt:
            print(f"\nActual credits: {receipt.actual_credits}")
            print(f"Estimated: {receipt.estimated_credits}")
            print(f"Savings: {receipt.savings} credits")
            
            print("\nBreakdown:")
            for key, value in receipt.breakdown.items():
                print(f"  {key}: {value}")
            
            # BYOK information
            if receipt.byok.get("enabled"):
                print(f"\nBYOK enabled: {receipt.byok['discount']}% discount")


if __name__ == "__main__":
    asyncio.run(main())
