/**
 * Workflow orchestration example for DataGrout Conduit
 */

import { Client } from '@datagrout/conduit';

async function main() {
  const client = new Client({
    url: 'https://gateway.datagrout.ai/servers/YOUR_SERVER_UUID/mcp',
    auth: { bearer: 'YOUR_API_KEY' },
  });

  await client.connect();

  try {
    // Define a multi-step workflow
    console.log('=== Workflow Orchestration ===');

    const plan = [
      {
        step: 1,
        type: 'tool_call',
        tool: 'salesforce@1/get_lead@1',
        args: { email: '$input.email' },
        output: 'lead',
      },
      {
        step: 2,
        type: 'focus',
        source_type: 'crm.lead@1',
        target_type: 'billing.customer@1',
        input: '$lead',
        output: 'customer',
      },
      {
        step: 3,
        type: 'tool_call',
        tool: 'quickbooks@1/create_invoice@1',
        args: { customer: '$customer' },
        output: 'invoice',
      },
    ];

    // Execute workflow with CTC validation
    const result = await client.flowInto({
      plan,
      validateCtc: true,
      saveAsSkill: true,
      inputData: { email: 'john@acme.com' },
    });

    console.log('Workflow completed:', result);

    // Check receipt
    const receipt = client.getLastReceipt();
    if (receipt) {
      console.log(`\nTotal credits used: ${receipt.actualCredits}`);
      console.log('Breakdown by step:');
      for (const [key, value] of Object.entries(receipt.breakdown || {})) {
        console.log(`  ${key}: ${value}`);
      }
    }
  } finally {
    await client.disconnect();
  }
}

main().catch(console.error);
