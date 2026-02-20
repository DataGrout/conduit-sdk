//! Batch operations and parallel execution example.

use datagrout_conduit::{extract_meta, ClientBuilder, Transport};
use serde_json::json;
use tokio::task::JoinSet;

#[tokio::main]
async fn main() -> Result<(), Box<dyn std::error::Error>> {
    tracing_subscriber::fmt::init();

    println!("=== DataGrout Conduit - Batch Operations Example ===\n");

    let client = ClientBuilder::new()
        .url("https://gateway.datagrout.ai/servers/{your-uuid}/mcp")
        .transport(Transport::Mcp)
        .auth_bearer("your-token-here")
        .build()?;

    client.connect().await?;
    println!("✓ Connected\n");

    // ── Sequential execution ──────────────────────────────────────────────────

    println!("--- Sequential Execution ---");

    let leads = vec!["lead_1", "lead_2", "lead_3"];

    for lead_id in &leads {
        let _result = client
            .perform("salesforce@1/get_lead@1")
            .args(json!({"id": lead_id}))
            .execute()
            .await?;

        println!("  ✓ Fetched lead: {}", lead_id);
    }

    // ── Parallel execution with JoinSet ───────────────────────────────────────

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
                println!("  ✓ Lead fetched");
            }
            Err(e) => {
                eprintln!("  ✗ Error: {}", e);
            }
        }
    }

    println!("Fetched {} leads in parallel", results.len());

    // ── Batch with per-call cost tracking ────────────────────────────────────

    println!("\n--- Batch with Cost Tracking ---");

    let operations = vec![
        ("salesforce@1/get_lead@1", json!({"id": "1"})),
        ("quickbooks@1/get_customer@1", json!({"id": "c1"})),
        ("stripe@1/get_charge@1", json!({"id": "ch_123"})),
    ];

    let mut total_net: f64 = 0.0;

    for (tool, args) in operations {
        let res = client.perform(tool).args(args).execute().await?;

        if let Some(meta) = extract_meta(&res) {
            let net = meta.receipt.net_credits;
            total_net += net;
            println!("  ✓ {} — {:.4} credits", tool, net);
        } else {
            println!("  ✓ {} (no receipt)", tool);
        }
    }

    println!("\n📄 Total net credits: {:.4}", total_net);

    client.disconnect().await?;
    println!("\n✓ Done");

    Ok(())
}
