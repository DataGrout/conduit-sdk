//! Multi-step workflow orchestration example

use datagrout_conduit::{ClientBuilder, Transport};
use serde_json::json;

#[tokio::main]
async fn main() -> Result<(), Box<dyn std::error::Error>> {
    tracing_subscriber::fmt::init();

    println!("=== DataGrout Conduit - Flow Orchestration Example ===\n");

    // Create and connect client
    let client = ClientBuilder::new()
        .url("https://gateway.datagrout.ai/servers/{your-uuid}/mcp")
        .transport(Transport::Mcp)
        .auth_bearer("your-token-here")
        .build()?;

    client.connect().await?;
    println!("✓ Connected\n");

    // Define multi-step workflow
    let plan = vec![
        json!({
            "step": 1,
            "tool": "salesforce@1/search_leads@1",
            "args": {
                "query": "email = 'john@example.com'"
            },
            "output": "lead"
        }),
        json!({
            "step": 2,
            "tool": "quickbooks@1/create_customer@1",
            "args": {
                "name": "$lead.name",
                "email": "$lead.email"
            },
            "output": "customer"
        }),
        json!({
            "step": 3,
            "tool": "quickbooks@1/create_invoice@1",
            "args": {
                "customer_id": "$customer.id",
                "amount": 1000.00,
                "description": "Services for $lead.company"
            },
            "output": "invoice"
        }),
    ];

    println!("--- Executing Workflow ---");
    println!("Steps:");
    for (i, step) in plan.iter().enumerate() {
        println!("  {}. {}", i + 1, step["tool"].as_str().unwrap_or("unknown"));
    }

    // Execute with CTC validation
    let result = client
        .flow_into(plan.clone())
        .validate_ctc(true) // Generate CTC for formal verification
        .save_as_skill(false) // Don't save as reusable skill
        .input_data(json!({}))
        .execute()
        .await?;

    println!("\n✅ Workflow completed!");
    println!("\nFinal result:");
    println!("{}", serde_json::to_string_pretty(&result)?);

    if let Some(meta) = datagrout_conduit::extract_meta(&result) {
        let r = &meta.receipt;
        println!("\n📄 Receipt: {} — estimated {:.4} / actual {:.4} / net {:.4} credits",
            r.receipt_id, r.estimated_credits, r.actual_credits, r.net_credits);
    }

    // Example 2: Save as reusable skill
    println!("\n--- Saving as Reusable Skill ---");

    let result = client
        .flow_into(plan)
        .validate_ctc(true)
        .save_as_skill(true) // Save for reuse
        .execute()
        .await?;

    println!("✓ Workflow saved as skill!");
    if let Some(skill_id) = result.get("skill_id").and_then(|v| v.as_str()) {
        println!("  Skill ID: {}", skill_id);
        println!("  Reuse with: client.perform(\"skill/{}\", args)", skill_id);
    }

    client.disconnect().await?;
    println!("\n✓ Done");

    Ok(())
}
