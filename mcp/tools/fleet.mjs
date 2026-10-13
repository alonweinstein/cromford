import { forward } from '../lib/tools.mjs';

export const tools = [{
  name: 'fleet_status',
  description: 'The fleet at a glance.',
  kind: 'read',
  inputSchema: { type: 'object', properties: {}, additionalProperties: false },
  handler: (args, ctx) => forward(ctx, 'GET', '/api/dash/fleet'),
}];
