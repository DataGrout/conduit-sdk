"""Guided workflow example for DataGrout Conduit."""

import asyncio
from datagrout.conduit import Client


async def main():
    """Demonstrate guided workflow navigation."""
    
    async with Client(
        "https://gateway.datagrout.ai/servers/YOUR_SERVER_UUID/mcp",
        auth={"bearer": "YOUR_API_KEY"}
    ) as client:
        
        # Start a guided workflow
        print("=== Starting Guided Workflow ===")
        session = await client.guide(
            goal="Create invoice from Salesforce lead email",
            policy={
                "max_steps": 5,
                "max_cost": 10.0
            }
        )
        
        print(f"Session ID: {session.session_id}")
        print(f"Status: {session.status}")
        print(f"Message: {session.get_state().message}\n")
        
        # Navigate through options
        while session.status == "ready":
            state = session.get_state()
            
            print(f"=== Step {state.step} ===")
            print(f"Message: {state.message}")
            print(f"Total cost so far: {state.total_cost} credits\n")
            
            if not state.options:
                break
            
            print("Options:")
            for opt in state.options:
                viable = "✓" if opt.viable else "✗"
                print(f"  [{viable}] {opt.id}: {opt.label} (cost: {opt.cost})")
            
            # Choose first viable option
            viable_options = [opt for opt in state.options if opt.viable]
            if not viable_options:
                print("\nNo viable options remaining")
                break
            
            chosen = viable_options[0]
            print(f"\nChoosing: {chosen.id}")
            
            # Advance workflow
            session = await session.choose(chosen.id)
        
        # Check final result
        if session.status == "completed":
            print("\n=== Workflow Completed ===")
            result = await session.complete()
            print(f"Result: {result}")
        else:
            print(f"\nWorkflow ended with status: {session.status}")


if __name__ == "__main__":
    asyncio.run(main())
