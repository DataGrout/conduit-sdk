"""Type transformation example for DataGrout Conduit."""

import asyncio
from datagrout.conduit import Client


async def main():
    """Demonstrate semantic type transformation with Prism."""
    
    async with Client(
        "https://gateway.datagrout.ai/servers/YOUR_SERVER_UUID/mcp",
        auth={"bearer": "YOUR_API_KEY"}
    ) as client:
        
        # Transform CRM lead to billing customer
        print("=== Type Transformation ===")
        
        lead_data = {
            "id": "00Q5G00000ABC123",
            "email": "john@acme.com",
            "company": "Acme Corp",
            "status": "qualified"
        }
        
        print(f"Source (crm.lead@1): {lead_data}")
        
        transformed = await client.prism_focus(
            data=lead_data,
            source_type="crm.lead@1",
            target_type="billing.customer@1"
        )
        
        print(f"\nTarget (billing.customer@1): {transformed}")
        
        # The transformation automatically:
        # - Finds adapter between types
        # - Maps fields (id -> external_id, etc.)
        # - Enriches missing fields if possible
        # - Reports any missing required fields


if __name__ == "__main__":
    asyncio.run(main())
