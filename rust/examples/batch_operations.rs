//! Batch operations and parallel execution example

use datagrout_conduit::{ClientBuilder, Transport};
use serde_json::json;
use tokio::task::JoinSet;

#[tokio::main]
async fn main() -> Result<(), Box<dyn std::error::Error>> {
    tracing_subscriber::fmt::init();

    println!("=== DataGrout Conduit - Batch Operations Example ===\n");

    // Create and connect client
    let client = ClientBuilder::new()
        .url("https://gateway.datagrout.ai/servers/{your-uuid}/mcp")
        .transport(Transport::Mcp)
        .auth_bearer("your-token-here")
        .build()?;

    client.connect().await?;
    println!("✓ Connected\n");

    // Example 1: Sequential execution
    println!("--- Sequential Execution ---");

    let leads = vec!["lead_1", "lead_2", "lead_3"];

    for lead_id in &leads {
        let _result = client
            .perform("salesforce@1/get_lead@1")
            .args(json!({"id": lead_id}))
            .execute()
            .await?;

        println!("✓ Fetched lead: {}", lead_id);
    }

    // Example 2: Parallel execution with JoinSet
    println!("\n--- Parallel Execution ---");

    let mut tasks = JoinSet::new();

    for lead_id in leads {
        let client_clone = client.clone();
        tasks.spawn(async move {
            client_clone
                .perform("salesforce@1/get_lead@1")
                .args(json!({"id": lead_id}))
                .execute()
                .await
        });
    }

    let mut results = Vec::new();
    while let Some(result) = tasks.join_next().await {
        match result? {
            Ok(data) => {
                results.push(data);
                println!("✓ Lead fetched");
            }
            Err(e) => {
                eprintln!("✗ Error: {}", e);
            }
        }
    }

    println!("Fetched {} leads in parallel", results.len());

    // Example 3: Batch with cost tracking
    println!("\n--- Batch with Cost Tracking ---");

    let operations = vec![
        ("salesforce@1/get_lead@1", json!({"id": "1"})),
        ("quickbooks@1/get_customer@1", json!({"id": "c1"})),
        ("stripe@1/get_charge@1", json!({"id": "ch_123"})),
    ];

    for (tool, args) in operations {
        let _ = client.perform(tool).args(args).execute().await?;

        if let Some(receipt) = client.last_receipt().await {
            println!(
                "✓ {} - {} credits",
                tool,
                receipt.tool_calls.last().map(|c| c.cost).unwrap_or(0)
            );
        }
    }

    // Check final aggregated receipt
    if let Some(receipt) = client.last_receipt().await {
        println!("\n📄 Total Receipt:");
        println!("  Operations: {}", receipt.tool_calls.len());
        println!("  Total cost: {} credits", receipt.total_cost);
    }

    client.disconnect().await?;
    println!("\n✓ Done");

    Ok(())
}
