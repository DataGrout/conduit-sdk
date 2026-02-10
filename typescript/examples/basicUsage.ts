/**
 * Basic usage example for DataGrout Conduit
 */

import { Client } from '@datagrout/conduit';

async function main() {
  // Initialize client (uses JSONRPC transport by default)
  const client = new Client({
    url: 'https://gateway.datagrout.ai/servers/YOUR_SERVER_UUID/mcp',
    auth: { bearer: 'YOUR_API_KEY' },
  });

  await client.connect();

  try {
    // List tools (automatically filtered to DataGrout tools)
    console.log('=== Available Tools ===');
    const tools = await client.listTools();
    for (const tool of tools) {
      console.log(`  - ${tool.name}: ${tool.description}`);
    }

    // Call a tool (standard MCP method)
    console.log('\n=== Calling Tool ===');
    const result = await client.callTool('salesforce@1/get_lead@1', {
      id: '00Q5G00000ABC123',
    });
    console.log('Result:', result);

    // Check receipt
    const receipt = client.getLastReceipt();
    if (receipt) {
      console.log(`\nCredits used: ${receipt.actualCredits}`);
      console.log(`Estimated: ${receipt.estimatedCredits}`);
      console.log(`Savings: ${receipt.savings}`);
    }
  } finally {
    await client.disconnect();
  }
}

main().catch(console.error);
