//! Semantic type transformation with Prism

use datagrout_conduit::{ClientBuilder, Transport};
use serde_json::json;

#[tokio::main]
async fn main() -> Result<(), Box<dyn std::error::Error>> {
    tracing_subscriber::fmt::init();

    println!("=== DataGrout Conduit - Type Transformation Example ===\n");

    // Create and connect client
    let client = ClientBuilder::new()
        .url("https://gateway.datagrout.ai/servers/{your-uuid}/mcp")
        .transport(Transport::Mcp)
        .auth_bearer("your-token-here")
        .build()?;

    client.connect().await?;
    println!("✓ Connected\n");

    // Example 1: Transform CRM lead to billing customer
    println!("--- Transform: CRM Lead → Billing Customer ---");

    let lead_data = json!({
        "id": "lead_123",
        "name": "John Doe",
        "email": "john@example.com",
        "company": "Acme Corp",
        "phone": "+1-555-0100",
        "status": "qualified"
    });

    let customer = client
        .prism_focus()
        .data(lead_data.clone())
        .source_type("crm.lead@1")
        .target_type("billing.customer@1")
        .execute()
        .await?;

    println!("Input (CRM lead):");
    println!("{}", serde_json::to_string_pretty(&lead_data)?);
    println!("\nOutput (Billing customer):");
    println!("{}", serde_json::to_string_pretty(&customer)?);

    // Example 2: Transform customer to support ticket
    println!("\n--- Transform: Billing Customer → Support Ticket ---");

    let ticket = client
        .prism_focus()
        .data(customer.clone())
        .source_type("billing.customer@1")
        .target_type("support.ticket@1")
        .execute()
        .await?;

    println!("Input (Billing customer):");
    println!("{}", serde_json::to_string_pretty(&customer)?);
    println!("\nOutput (Support ticket):");
    println!("{}", serde_json::to_string_pretty(&ticket)?);

    // Example 3: Chain transformations
    println!("\n--- Chain Transformations ---");
    println!("Lead → Customer → Ticket → Email");

    let email = client
        .prism_focus()
        .data(ticket)
        .source_type("support.ticket@1")
        .target_type("email.message@1")
        .execute()
        .await?;

    println!("\nFinal output (Email):");
    println!("{}", serde_json::to_string_pretty(&email)?);

    println!("\n💡 Prism automatically:");
    println!("  • Infers structural mappings");
    println!("  • Handles field renaming");
    println!("  • Fills semantic holes");
    println!("  • Validates type constraints");

    client.disconnect().await?;
    println!("\n✓ Done");

    Ok(())
}
