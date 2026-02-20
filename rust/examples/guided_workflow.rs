//! Guided workflow example

use datagrout_conduit::{ClientBuilder, Transport};

#[tokio::main]
async fn main() -> Result<(), Box<dyn std::error::Error>> {
    tracing_subscriber::fmt::init();

    println!("=== DataGrout Conduit - Guided Workflow Example ===\n");

    // Create and connect client
    let client = ClientBuilder::new()
        .url("https://gateway.datagrout.ai/servers/{your-uuid}/mcp")
        .transport(Transport::Mcp)
        .auth_bearer("your-token-here")
        .build()?;

    client.connect().await?;
    println!("✓ Connected\n");

    // Start guided workflow
    println!("--- Starting Guided Workflow ---");
    let mut session = client
        .guide()
        .goal("Create an invoice from a lead")
        .execute()
        .await?;

    println!("Session ID: {}", session.session_id());
    println!("Status: {}", session.status());

    // Workflow loop
    while session.status() != "completed" && session.status() != "failed" {
        println!("\n--- Step {} ---", session.state().step.unwrap_or(0));

        // Show available options
        if let Some(options) = session.options() {
            println!("Available options:");
            for (i, option) in options.iter().enumerate() {
                println!("  {}. {}", i + 1, option.label);
                if let Some(desc) = &option.description {
                    println!("     {}", desc);
                }
            }

            // In a real app, you'd prompt the user
            // For this example, we'll just choose the first option
            if let Some(first_option) = options.first() {
                println!("\nChoosing: {}", first_option.label);

                session = session.choose(&first_option.id).await?;

                println!("New status: {}", session.status());
            } else {
                break;
            }
        } else {
            // No options available, workflow might be waiting or completed
            break;
        }
    }

    // Get final result
    if session.status() == "completed" {
        println!("\n✅ Workflow Completed!");

        match session.complete().await {
            Ok(result) => {
                println!("\nFinal result:");
                println!("{}", serde_json::to_string_pretty(&result)?);
            }
            Err(e) => {
                println!("Error getting result: {}", e);
            }
        }
    } else {
        println!("\n❌ Workflow ended with status: {}", session.status());
    }

    // Guide sessions don't return a per-step receipt directly; check the last
    // flow_into/execute result for _meta if available.

    client.disconnect().await?;
    println!("\n✓ Done");

    Ok(())
}
