/**
 * Semantic discovery example for DataGrout Conduit
 */

import { Client } from '@datagrout/conduit';

async function main() {
  const client = new Client({
    url: 'https://gateway.datagrout.ai/servers/YOUR_SERVER_UUID/mcp',
    auth: { bearer: 'YOUR_API_KEY' },
  });

  await client.connect();

  try {
    // Discover tools by query
    console.log('=== Discovering Tools ===');
    const results = await client.discover({
      query: 'find unpaid invoices',
      limit: 10,
      integrations: ['salesforce', 'quickbooks'],
    });

    console.log(`Query: ${results.queryUsed}`);
    console.log(`Found ${results.total} tools:\n`);

    for (const tool of results.results) {
      console.log(`  ${tool.toolName}`);
      console.log(`    Integration: ${tool.integration}`);
      console.log(`    Score: ${tool.score?.toFixed(2)}`);
      console.log(`    Description: ${tool.description}`);
      console.log();
    }

    // Perform a tool call
    if (results.results.length > 0) {
      const toolName = results.results[0].toolName;
      console.log(`=== Executing Top Tool: ${toolName} ===`);

      const result = await client.perform({
        tool: toolName,
        args: { limit: 5 },
      });
      console.log('Result:', result);

      // Check cost
      const receipt = client.getLastReceipt();
      if (receipt) {
        console.log(`\nCredits used: ${receipt.actualCredits}`);
      }
    }
  } finally {
    await client.disconnect();
  }
}

main().catch(console.error);
