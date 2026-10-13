import test from 'node:test';
import assert from 'node:assert/strict';
import { flyUnreadableReason, flyMachines, flyOrphans, flyProjectProps } from '../src/lib/fly.js';

// BH-667. The payloads below are the ones the console Worker really sends: the
// fly_errors-with-a-confident-zero shape it sends today, and the unreadable
// shape docs/DASH-MACHINES-UNREADABLE.md asks it to send next.

const job = (n) => ({ machine: `md17d4f${n}`, key: `BH-6${n}`, spawned_at: '2026-09-17T18:00:00Z' });
const machine = (n) => ({ id: `md17d4f${n}`, role: 'pool', state: 'started', region: 'iad' });

test('every reader gets the fly_errors list along with its block, from one payload read', () => {
  const data = {
    boxes: { 'hub-1': '2 min ago' },
    fly: {
      'cromford': { machine_count: 0, machines: [], orphan_jobs: [job(1)] },
      'project-3': { machine_count: 2, machines: [machine(1), machine(2)], orphan_jobs: [] }
    },
    fly_errors: [{ project: 'cromford', error: 'FLY_API_TOKEN_CROMFORD unset' }]
  };
  const out = flyProjectProps(data);
  assert.deepEqual(out.map((p) => p.project), ['cromford', 'project-3'], 'one entry per project, in payload order');
  for (const p of out) {
    assert.equal(p.flyErrors, data.fly_errors, 'the errors ride along with every block');
    assert.equal(p.fly, data.fly[p.project]);
  }
  // Which is the whole point: the unreadable project is unreadable, its
  // neighbour is not, and neither reader has to go looking for the list.
  assert.equal(flyUnreadableReason(out[0].fly, out[0].flyErrors, out[0].project), 'FLY_API_TOKEN_CROMFORD unset');
  assert.equal(flyUnreadableReason(out[1].fly, out[1].flyErrors, out[1].project), null);
});

test('a payload with no fly lane, or none at all, yields no readers and does not throw', () => {
  assert.deepEqual(flyProjectProps({ boxes: {} }), []);
  assert.deepEqual(flyProjectProps(null), []);
  assert.deepEqual(flyProjectProps({ fly: { 'project-3': {} } })[0].flyErrors, [], 'a missing error list is empty, not undefined');
});

test('the unreadable flag marks the block unreadable and carries its own reason', () => {
  const block = { unreadable: true, unreadable_reason: 'fly token unset for this project' };
  assert.equal(flyUnreadableReason(block, [], 'cromford'), 'fly token unset for this project');
});

test('a null machine_count is absent, not zero', () => {
  assert.equal(flyUnreadableReason({ machine_count: null }, [], 'cromford'), 'fly not enumerated');
});

test('the 2026-09-17 case: an error entry beats the block\'s own zero and six orphans', () => {
  const block = { machine_count: 0, machines: [], orphan_jobs: [1, 2, 3, 4, 5, 6].map(job) };
  const errors = [{ project: 'cromford', error: 'FLY_API_TOKEN_CROMFORD unset' }];
  const reason = flyUnreadableReason(block, errors, 'cromford');
  assert.equal(reason, 'FLY_API_TOKEN_CROMFORD unset');
  assert.deepEqual(flyOrphans(block, reason), [], 'six claimed jobs are not six orphans');
  assert.equal(flyMachines(block, reason), null, 'not [] — we never looked');
});

test('a readable block with three machines and no orphans is readable', () => {
  const block = { machine_count: 3, machines: [1, 2, 3].map(machine), orphan_jobs: [] };
  const reason = flyUnreadableReason(block, [], 'cromford');
  assert.equal(reason, null);
  assert.equal(flyMachines(block, reason).length, 3);
  assert.deepEqual(flyOrphans(block, reason), []);
});

test('a readable block still reports its real orphans', () => {
  const block = { machine_count: 1, machines: [machine(1)], orphan_jobs: [job(8), job(9)] };
  const reason = flyUnreadableReason(block, [], 'cromford');
  assert.equal(reason, null);
  assert.equal(flyOrphans(block, reason).length, 2, 'the fix must not suppress all orphan detection');
});

test('another project missing its token does not mark this one unreadable', () => {
  const block = { machine_count: 2, machines: [1, 2].map(machine), orphan_jobs: [] };
  const errors = [{ project: 'harness-console', error: 'FLY_API_TOKEN_HARNESS_CONSOLE unset' }];
  assert.equal(flyUnreadableReason(block, errors, 'cromford'), null);
});

test('the Worker may drop machine_count instead of nulling it', () => {
  const dropped = { unreadable: true, unreadable_reason: 'fly token unset for this project' };
  assert.equal(flyUnreadableReason(dropped, [], 'cromford'), 'fly token unset for this project');
  assert.equal(flyUnreadableReason({}, [], 'cromford'), 'fly not enumerated', 'no count, no list');
  assert.equal(flyUnreadableReason({ machines: [machine(1)] }, [], 'cromford'), null,
    'a block carrying its machines has been read, counted or not');
});

test('a missing block or missing error list does not throw', () => {
  assert.equal(flyUnreadableReason({ machine_count: 0 }, undefined, 'cromford'), null);
  assert.equal(flyUnreadableReason(undefined, undefined, 'cromford'), 'fly not enumerated');
  assert.equal(flyMachines(undefined, null).length, 0);
  assert.deepEqual(flyOrphans(undefined, null), []);
});
