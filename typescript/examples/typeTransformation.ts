/**
 * Type transformation example for DataGrout Conduit
 */

import { Client } from '@datagrout/conduit';

async function main() {
  const client = new Client({
    url: 'https://gateway.datagrout.ai/servers/YOUR_SERVER_UUID/mcp',
    auth: { bearer: 'YOUR_API_KEY' },
  });

  await client.connect();

  try {
    // Transform CRM lead to billing customer
    console.log('=== Type Transformation ===');

    const leadData = {
      id: '00Q5G00000ABC123',
      email: 'john@acme.com',
      company: 'Acme Corp',
      status: 'qualified',
    };

    console.log('Source (crm.lead@1):', leadData);

    const transformed = await client.prismFocus({
      data: leadData,
      sourceType: 'crm.lead@1',
      targetType: 'billing.customer@1',
    });

    console.log('\nTarget (billing.customer@1):', transformed);

    // The transformation automatically:
    // - Finds adapter between types
    // - Maps fields (id -> external_id, etc.)
    // - Enriches missing fields if possible
    // - Reports any missing required fields
  } finally {
    await client.disconnect();
  }
}

main().catch(console.error);
