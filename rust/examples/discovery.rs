//! Semantic discovery example

use datagrout_conduit::{ClientBuilder, Transport};

#[tokio::main]
async fn main() -> Result<(), Box<dyn std::error::Error>> {
    tracing_subscriber::fmt::init();

    println!("=== DataGrout Conduit - Discovery Example ===\n");

    // Create and connect client
    let client = ClientBuilder::new()
        .url("https://gateway.datagrout.ai/servers/{your-uuid}/mcp")
        .transport(Transport::Mcp)
        .auth_bearer("your-token-here")
        .build()?;

    client.connect().await?;
    println!("✓ Connected\n");

    // Example 1: Query-based discovery
    println!("--- Query-Based Discovery ---");
    let results = client
        .discover()
        .query("get lead by email")
        .integration("salesforce")
        .limit(10)
        .min_score(0.7)
        .execute()
        .await?;

    println!("Found {} tools:", results.total);
    for tool in &results.tools {
        println!(
            "  • {} (score: {:.2})",
            tool.tool.name,
            tool.score
        );
        if let Some(desc) = &tool.tool.description {
            println!("    {}", desc);
        }
    }

    // Example 2: Goal-based discovery
    println!("\n--- Goal-Based Discovery ---");
    let results = client
        .discover()
        .goal("I need to find a customer by their email address")
        .integration("salesforce")
        .limit(5)
        .execute()
        .await?;

    println!("Found {} matching tools:", results.total);
    for tool in &results.tools {
        println!(
            "  • {} (score: {:.2})",
            tool.tool.name,
            tool.score
        );
    }

    // Example 3: Direct tool execution with perform
    if let Some(tool) = results.tools.first() {
        println!("\n--- Executing Tool via Perform ---");
        let result = client
            .perform(&tool.tool.name)
            .args(serde_json::json!({
                "email": "john@example.com"
            }))
            .execute()
            .await?;

        println!("Result: {}", serde_json::to_string_pretty(&result)?);

        // Check receipt
        if let Some(receipt) = client.last_receipt().await {
            println!("\n📄 Receipt:");
            println!("  ID: {}", receipt.id);
            println!("  Total cost: {} credits", receipt.total_cost);
            println!("  Tool calls: {}", receipt.tool_calls.len());
        }
    }

    client.disconnect().await?;
    println!("\n✓ Done");

    Ok(())
}
