//! Basic Conduit SDK usage example

use datagrout_conduit::{ClientBuilder, Transport};
use serde_json::json;

#[tokio::main]
async fn main() -> Result<(), Box<dyn std::error::Error>> {
    // Initialize logging
    tracing_subscriber::fmt::init();

    println!("=== DataGrout Conduit - Basic Example ===\n");

    // Create client
    let client = ClientBuilder::new()
        .url("https://gateway.datagrout.ai/servers/{your-uuid}/mcp")
        .transport(Transport::Mcp) // or Transport::JsonRpc
        .auth_bearer("your-token-here")
        .max_retries(3)
        .build()?;

    println!("✓ Client created");

    // Connect and initialize
    client.connect().await?;
    println!("✓ Connected and initialized");

    // Get server info
    if let Some(info) = client.server_info().await {
        println!("\nServer: {} v{}", info.name, info.version);
    }

    // List tools
    println!("\n--- Listing Tools ---");
    let tools = client.list_tools().await?;
    println!("Found {} tools", tools.len());

    for tool in tools.iter().take(5) {
        println!("  • {} - {}", tool.name, tool.description.as_deref().unwrap_or(""));
    }

    // Call a tool
    if !tools.is_empty() {
        let tool_name = &tools[0].name;
        println!("\n--- Calling Tool: {} ---", tool_name);

        let result = client
            .call_tool(tool_name, json!({}))
            .await?;

        println!("Result: {}", serde_json::to_string_pretty(&result)?);
    }

    // List resources
    println!("\n--- Listing Resources ---");
    let resources = client.list_resources().await?;
    println!("Found {} resources", resources.len());

    // List prompts
    println!("\n--- Listing Prompts ---");
    let prompts = client.list_prompts().await?;
    println!("Found {} prompts", prompts.len());

    // Disconnect
    client.disconnect().await?;
    println!("\n✓ Disconnected");

    Ok(())
}
