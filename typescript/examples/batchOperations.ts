/**
 * Batch operations example for DataGrout Conduit
 */

import { Client } from '@datagrout/conduit';

async function main() {
  const client = new Client({
    url: 'https://gateway.datagrout.ai/servers/YOUR_SERVER_UUID/mcp',
    auth: { bearer: 'YOUR_API_KEY' },
  });

  await client.connect();

  try {
    // Execute multiple tools in parallel
    console.log('=== Batch Tool Execution ===');

    const calls = [
      {
        tool: 'salesforce@1/get_lead@1',
        args: { id: '00Q5G00000ABC123' },
      },
      {
        tool: 'salesforce@1/get_lead@1',
        args: { id: '00Q5G00000DEF456' },
      },
      {
        tool: 'quickbooks@1/get_invoice@1',
        args: { id: 'INV-001' },
      },
    ];

    const results = await client.performBatch(calls);

    console.log(`Executed ${results.length} tools in parallel:\n`);
    for (let i = 0; i < results.length; i++) {
      console.log(`Call ${i + 1}:`, results[i]);
    }

    // Check cumulative cost
    const receipt = client.getLastReceipt();
    if (receipt) {
      console.log(`\nTotal credits used: ${receipt.actualCredits}`);
      console.log('Breakdown:', receipt.breakdown);
    }
  } finally {
    await client.disconnect();
  }
}

main().catch(console.error);
