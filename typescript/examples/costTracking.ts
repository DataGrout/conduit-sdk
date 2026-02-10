/**
 * Cost tracking and estimation example for DataGrout Conduit
 */

import { Client } from '@datagrout/conduit';

async function main() {
  const client = new Client({
    url: 'https://gateway.datagrout.ai/servers/YOUR_SERVER_UUID/mcp',
    auth: { bearer: 'YOUR_API_KEY' },
  });

  await client.connect();

  try {
    // Get cost estimate before execution
    console.log('=== Cost Estimation ===');
    const estimate = await client.estimateCost('salesforce@1/query_leads@1', {
      query: 'SELECT Id, Email FROM Lead LIMIT 100',
    });

    console.log('Estimated credits:', estimate);

    // Execute and compare
    console.log('\n=== Executing Tool ===');
    const result = await client.perform({
      tool: 'salesforce@1/query_leads@1',
      args: { query: 'SELECT Id, Email FROM Lead LIMIT 100' },
    });

    const receipt = client.getLastReceipt();
    if (receipt) {
      console.log(`\nActual credits: ${receipt.actualCredits}`);
      console.log(`Estimated: ${receipt.estimatedCredits}`);
      console.log(`Savings: ${receipt.savings} credits`);

      console.log('\nBreakdown:');
      for (const [key, value] of Object.entries(receipt.breakdown || {})) {
        console.log(`  ${key}: ${value}`);
      }

      // BYOK information
      if (receipt.byok?.enabled) {
        console.log(`\nBYOK enabled: ${receipt.byok.discount}% discount`);
      }
    }
  } finally {
    await client.disconnect();
  }
}

main().catch(console.error);
