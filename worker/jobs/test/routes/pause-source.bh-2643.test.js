import test from 'node:test';
import assert from 'node:assert/strict';
import { CLAIM, call, iso } from '../lib/harness.js';

// BH-2643: a builder's pause check is this claim, and the claim reads only the
// pause_flags row. The refusal used to say "flags/<name> is active", which
// named a box file the builder never read, and on 2026-09-26 an investigation
// chased stale box-local copies for it. The reason now names the row and its
// updated_at, and a row that is off pauses nothing: the worker has no file
// input, so no box's stale flags/ file can refuse a claim.

const ROW = (over) => ({ name: 'paused-cromford', active: 1, actor: 'box-hub',
  reason: 'console', updated_at: '2026-09-26T01:26:10Z', ...over });
const BH = () => CLAIM({ project: 'cromford', box: 'pool-cromford-7844153a366178',
  ticket_id: 'BH-2512', lane: 'build/cromford/claude' });

test('an active row refuses the claim and names the row, not a file', async () => {
  const r = await call('/api/jobs', { ...BH(), state: { jobs: [], flags: [ROW()] } });
  assert.equal(r.status, 409);
  assert.equal(r.body.scope, 'pause');
  assert.match(r.body.reason,
    /^paused: pause_flags row paused-cromford is active \(updated 2026-09-26T01:26:10Z\) — console \(set by box-hub\)$/);
  assert.doesNotMatch(r.body.reason, /flags\//);
});

test('a row that is off does not pause the builder', async () => {
  const r = await call('/api/jobs', {
    ...BH(), state: { jobs: [], flags: [ROW({ active: 0, updated_at: iso(0) })] }
  });
  assert.equal(r.status, 201);
  assert.notEqual(r.body.refused, true);
});
