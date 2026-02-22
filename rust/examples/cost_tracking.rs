//! Cost tracking and credit management example.
//!
//! Demonstrates how to read the `_datagrout` block that DataGrout embeds in every
//! tool-call result using [`extract_meta`].

use datagrout_conduit::{extract_meta, ClientBuilder, Transport};
use serde_json::json;

#[tokio::main]
async fn main() -> Result<(), Box<dyn std::error::Error>> {
    tracing_subscriber::fmt::init();

    println!("=== DataGrout Conduit - Cost Tracking Example ===\n");

    let client = ClientBuilder::new()
        .url("https://gateway.datagrout.ai/servers/{your-uuid}/mcp")
        .transport(Transport::Mcp)
        .auth_bearer("your-token-here")
        .build()?;

    client.connect().await?;
    println!("✓ Connected\n");

    // ── Example 1: Execute and inspect the receipt ────────────────────────────

    println!("--- Execute with Cost Tracking ---");

    let result = client
        .perform("salesforce@1/get_lead@1")
        .args(json!({"id": "lead_123"}))
        .execute()
        .await?;

    println!("Result: {}", serde_json::to_string_pretty(&result)?);

    if let Some(meta) = extract_meta(&result) {
        let r = &meta.receipt;
        println!("\n📄 Receipt:");
        println!("  ID:               {}", r.receipt_id);
        println!("  Timestamp:        {}", r.timestamp);
        println!("  Estimated:        {} credits", r.estimated_credits);
        println!("  Actual:           {} credits", r.actual_credits);
        println!("  Net (after BYOK): {} credits", r.net_credits);
        println!("  Savings:          {} credits", r.savings);
        if let Some(before) = r.balance_before {
            println!("  Balance before:   {:.2}", before);
        }
        if let Some(after) = r.balance_after {
            println!("  Balance after:    {:.2}", after);
        }
        if r.byok.enabled {
            println!("  BYOK discount:    {:.0}%", r.byok.discount_rate * 100.0);
        }
    }

    // ── Example 2: Batch operations with per-call cost display ────────────────

    println!("\n--- Batch Operations ---");

    let tools = vec![
        ("salesforce@1/get_lead@1", json!({"id": "lead_1"})),
        ("salesforce@1/get_lead@1", json!({"id": "lead_2"})),
        ("salesforce@1/get_lead@1", json!({"id": "lead_3"})),
    ];

    let mut total_net: f64 = 0.0;

    for (tool, args) in tools.clone() {
        let res = client.perform(tool).args(args).execute().await?;

        if let Some(meta) = extract_meta(&res) {
            let net = meta.receipt.net_credits;
            total_net += net;
            println!("  ✓ {} — {:.4} credits", tool, net);
        } else {
            println!("  ✓ {} (no receipt in response)", tool);
        }
    }

    println!("  Total net credits: {:.4}", total_net);

    // ── Example 3: Budget-aware execution ────────────────────────────────────

    println!("\n--- Budget-Aware Execution ---");

    let max_budget: f64 = 10.0;
    let mut spent: f64 = 0.0;

    let tasks = vec![
        ("salesforce@1/get_lead@1", json!({"id": "lead_a"})),
        ("salesforce@1/get_lead@1", json!({"id": "lead_b"})),
        ("salesforce@1/get_lead@1", json!({"id": "lead_c"})),
    ];

    for (tool, args) in tasks {
        if spent >= max_budget {
            println!("⚠️  Budget exhausted ({:.2}/{:.2}). Stopping.", spent, max_budget);
            break;
        }

        let res = client.perform(tool).args(args).execute().await?;

        if let Some(meta) = extract_meta(&res) {
            spent += meta.receipt.net_credits;
            println!("  ✓ {} (spent so far: {:.4}/{:.2})", tool, spent, max_budget);
        }
    }

    client.disconnect().await?;
    println!("\n✓ Done");

    Ok(())
}
