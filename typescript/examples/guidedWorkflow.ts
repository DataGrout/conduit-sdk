/**
 * Guided workflow example for DataGrout Conduit
 */

import { Client } from '@datagrout/conduit';

async function main() {
  const client = new Client({
    url: 'https://gateway.datagrout.ai/servers/YOUR_SERVER_UUID/mcp',
    auth: { bearer: 'YOUR_API_KEY' },
  });

  await client.connect();

  try {
    // Start a guided workflow
    console.log('=== Starting Guided Workflow ===');
    let session = await client.guide({
      goal: 'Create invoice from Salesforce lead email',
      policy: {
        max_steps: 5,
        max_cost: 10.0,
      },
    });

    console.log(`Session ID: ${session.sessionId}`);
    console.log(`Status: ${session.status}`);
    console.log(`Message: ${session.getState().message}\n`);

    // Navigate through options
    while (session.status === 'ready') {
      const state = session.getState();

      console.log(`=== Step ${state.step} ===`);
      console.log(`Message: ${state.message}`);
      console.log(`Total cost so far: ${state.totalCost} credits\n`);

      if (!state.options || state.options.length === 0) {
        break;
      }

      console.log('Options:');
      for (const opt of state.options) {
        const viable = opt.viable ? '✓' : '✗';
        console.log(`  [${viable}] ${opt.id}: ${opt.label} (cost: ${opt.cost})`);
      }

      // Choose first viable option
      const viableOptions = state.options.filter((opt) => opt.viable);
      if (viableOptions.length === 0) {
        console.log('\nNo viable options remaining');
        break;
      }

      const chosen = viableOptions[0];
      console.log(`\nChoosing: ${chosen.id}`);

      // Advance workflow
      session = await session.choose(chosen.id);
    }

    // Check final result
    if (session.status === 'completed') {
      console.log('\n=== Workflow Completed ===');
      const result = await session.complete();
      console.log('Result:', result);
    } else {
      console.log(`\nWorkflow ended with status: ${session.status}`);
    }
  } finally {
    await client.disconnect();
  }
}

main().catch(console.error);
