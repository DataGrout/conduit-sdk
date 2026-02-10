"""Workflow orchestration example for DataGrout Conduit."""

import asyncio
from datagrout.conduit import Client


async def main():
    """Demonstrate multi-step workflow orchestration."""
    
    async with Client(
        "https://gateway.datagrout.ai/servers/YOUR_SERVER_UUID/mcp",
        auth={"bearer": "YOUR_API_KEY"}
    ) as client:
        
        # Define a multi-step workflow
        print("=== Workflow Orchestration ===")
        
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
        ]
        
        # Execute workflow with CTC validation
        result = await client.flow_into(
            plan=plan,
            validate_ctc=True,
            save_as_skill=True,
            input_data={"email": "john@acme.com"}
        )
        
        print(f"Workflow completed: {result}")
        
        # Check receipt
        receipt = client.get_last_receipt()
        if receipt:
            print(f"\nTotal credits used: {receipt.actual_credits}")
            print(f"Breakdown by step:")
            for key, value in receipt.breakdown.items():
                print(f"  {key}: {value}")


if __name__ == "__main__":
    asyncio.run(main())
