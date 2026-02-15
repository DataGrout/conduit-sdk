//! Cost tracking and credit management example

use datagrout_conduit::{ClientBuilder, Transport};
use serde_json::json;

#[tokio::main]
async fn main() -> Result<(), Box<dyn std::error::Error>> {
    tracing_subscriber::fmt::init();

    println!("=== DataGrout Conduit - Cost Tracking Example ===\n");

    // Create and connect client
    let client = ClientBuilder::new()
        .url("https://gateway.datagrout.ai/servers/{your-uuid}/mcp")
        .transport(Transport::Mcp)
        .auth_bearer("your-token-here")
        .build()?;

    client.connect().await?;
    println!("✓ Connected\n");

    // Example 1: Estimate cost before execution
    println!("--- Cost Estimation ---");

    let estimate = client
        .estimate_cost(
            "salesforce@1/get_lead@1",
            json!({"id": "lead_123"}),
        )
        .await?;

    println!("Estimated cost: {} credits", estimate.get("estimated_credits")
        .and_then(|v| v.as_f64())
        .unwrap_or(0.0)
    );

    // Example 2: Execute and track actual cost
    println!("\n--- Execute with Tracking ---");

    let result = client
        .perform("salesforce@1/get_lead@1")
        .args(json!({"id": "lead_123"}))
        .execute()
        .await?;

    println!("Result: {}", serde_json::to_string_pretty(&result)?);

    // Check receipt
    if let Some(receipt) = client.last_receipt().await {
        println!("\n📄 Receipt:");
        println!("  ID: {}", receipt.id);
        println!("  Estimated: {} credits", 
            receipt.tool_calls.iter().map(|c| c.cost).sum::<u64>()
        );
        println!("  Actual: {} credits", receipt.total_cost);
        println!("  Timestamp: {}", receipt.timestamp);

        println!("\n  Tool calls:");
        for call in &receipt.tool_calls {
            println!("    • {} - {} credits", call.name, call.cost);
        }
    }

    // Example 3: Batch operations with aggregated costs
    println!("\n--- Batch Operations ---");

    let tools = vec![
        ("salesforce@1/get_lead@1", json!({"id": "lead_1"})),
        ("salesforce@1/get_lead@1", json!({"id": "lead_2"})),
        ("salesforce@1/get_lead@1", json!({"id": "lead_3"})),
    ];

    println!("Executing {} operations in parallel...", tools.len());

    for (tool, args) in tools {
        let _ = client
            .perform(tool)
            .args(args)
            .execute()
            .await?;
    }

    // Check aggregated receipt
    if let Some(receipt) = client.last_receipt().await {
        println!("\n📄 Aggregated Receipt:");
        println!("  Total operations: {}", receipt.tool_calls.len());
        println!("  Total cost: {} credits", receipt.total_cost);

        let avg_cost = if !receipt.tool_calls.is_empty() {
            receipt.total_cost / receipt.tool_calls.len() as u64
        } else {
            0
        };
        println!("  Average cost per operation: {} credits", avg_cost);
    }

    // Example 4: Budget-aware execution
    println!("\n--- Budget-Aware Execution ---");

    let max_budget = 1000; // credits
    let mut spent = 0u64;

    let tasks = vec![
        ("salesforce@1/get_lead@1", json!({"id": "lead_1"})),
        ("salesforce@1/get_lead@1", json!({"id": "lead_2"})),
        ("salesforce@1/get_lead@1", json!({"id": "lead_3"})),
    ];

    for (tool, args) in tasks {
        // Estimate first
        let estimate = client.estimate_cost(tool, args.clone()).await?;
        let estimated_cost = estimate
            .get("estimated_credits")
            .and_then(|v| v.as_f64())
            .unwrap_or(0.0) as u64;

        if spent + estimated_cost > max_budget {
            println!("⚠️  Budget exceeded! Stopping.");
            println!("   Spent: {} credits", spent);
            println!("   Budget: {} credits", max_budget);
            break;
        }

        // Execute
        let _ = client.perform(tool).args(args).execute().await?;

        if let Some(receipt) = client.last_receipt().await {
            spent = receipt.total_cost;
            println!("✓ Executed {} (spent: {}/{} credits)", tool, spent, max_budget);
        }
    }

    client.disconnect().await?;
    println!("\n✓ Done");

    Ok(())
}
