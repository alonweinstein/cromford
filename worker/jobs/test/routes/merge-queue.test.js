import test from 'node:test';
import assert from 'node:assert/strict';
import { call, iso } from '../lib/harness.js';

const MQ = (over) => ({
  project: 'project-3', pr: 41, status: 'queued', repo: 'example-org/project-3',
  reason: null, enqueued_by: 'hub',
  enqueued_at: iso(600e3), updated_at: iso(600e3), ...over
});

test('merge queue: an enqueue is a row keyed on project + PR', async () => {
  const r = await call('/api/merge-queue', { method: 'POST', body: {
    project: 'project-3', pr: 41, repo: 'example-org/project-3',
    reason: 'tier-1 APPROVE from pool build TK-9', enqueued_by: 'hub'
  } });
  assert.equal(r.status, 201);
  assert.equal(r.body.merge.pr, 41);
  assert.equal(r.body.merge.status, 'queued');
  // The reason is the whole point: `.blocked` as a FILENAME could record that a
  // PR was stopped and nothing about what stopped it.
  assert.match(r.body.merge.reason, /tier-1 APPROVE/);
  const ins = r.db._calls.find((c) => /INSERT INTO merge_queue/.test(c.sql));
  assert.match(ins.sql, /ON CONFLICT\(project, ?pr\)/);
});

test('merge queue: enqueueing a PR that is already queued writes nothing', async () => {
  const r = await call('/api/merge-queue', {
    method: 'POST', body: { project: 'project-3', pr: 41 },
    state: { mergeQueue: [MQ()] }
  });
  assert.equal(r.status, 200);
  assert.equal(r.body.duplicate, true);
  assert.equal(r.db._calls.filter((c) => /INSERT INTO merge_queue/.test(c.sql)).length, 0);
});

test('merge queue: a BLOCKED PR is re-queueable — fidelity to the file, not a new policy', async () => {
  // bin/tier2-merge-sweep.sh tests `[ -f <Q>/<num> ]` and never the `.blocked`
  // sibling, so a parked PR is re-enqueued on its next pass TODAY. This table
  // describes that behaviour rather than quietly changing it.
  const r = await call('/api/merge-queue', {
    method: 'POST', body: { project: 'project-3', pr: 41 },
    state: { mergeQueue: [MQ({ status: 'blocked', reason: 'rebase CONFLICTS' })] }
  });
  assert.equal(r.status, 201);
  assert.equal(r.body.duplicate, false);
  assert.equal(r.body.merge.status, 'queued');
});

test('merge queue: a closed PR is DROPPED, never landed', async () => {
  // `landed` for a PR that closed without merging would put a lie in the one
  // ledger a merge decision reads.
  const r = await call('/api/merge-queue', {
    method: 'PATCH', body: { project: 'project-3', pr: 41, status: 'dropped', reason: 'dequeued: PR state=CLOSED' },
    state: { mergeQueue: [MQ()] } });
  assert.equal(r.status, 200);
  assert.equal(r.body.merge.status, 'dropped');
  assert.match(r.body.merge.reason, /CLOSED/);
});

test('merge queue: landed is not a trap, and an unknown status is refused', async () => {
  const back = await call('/api/merge-queue', {
    method: 'PATCH', body: { project: 'project-3', pr: 41, status: 'queued' },
    state: { mergeQueue: [MQ({ status: 'landed' })] } });
  assert.equal(back.status, 200, 'a landed PR can be re-queued (a revert, a reopen)');
  const bad = await call('/api/merge-queue', {
    method: 'PATCH', body: { project: 'project-3', pr: 41, status: 'merged' },
    state: { mergeQueue: [MQ()] } });
  assert.equal(bad.status, 409, 'an unknown status drives every screen — refuse it rather than store it');
});

test('merge queue: a PATCH for a PR that is not queued is a 404', async () => {
  const r = await call('/api/merge-queue', {
    method: 'PATCH', body: { project: 'project-3', pr: 999, status: 'landed' } });
  assert.equal(r.status, 404);
});

test('merge queue: list is FIFO and filters by project and status', async () => {
  const state = { mergeQueue: [
    MQ({ pr: 2, enqueued_at: iso(60e3) }),
    MQ({ pr: 1, enqueued_at: iso(9000e3) }),
    MQ({ pr: 3, status: 'blocked' }),
    MQ({ pr: 4, project: 'project-4' }),
  ] };
  const q = await call('/api/merge-queue?project=project-3&status=queued', { state });
  // FIFO by enqueued_at is what `ls -tr` gave the directory; a queue that
  // reorders landings is a different queue.
  assert.deepEqual(q.body.merge_queue.map((m) => m.pr), [1, 2]);
});

test('merge queue: a bad pr or project is refused, and no bearer is a 401', async () => {
  const noPr = await call('/api/merge-queue', { method: 'POST', body: { project: 'project-3' } });
  assert.equal(noPr.status, 400);
  const negative = await call('/api/merge-queue', { method: 'POST', body: { project: 'project-3', pr: -3 } });
  assert.equal(negative.status, 400);
  const unauth = await call('/api/merge-queue', { secret: null });
  assert.equal(unauth.status, 401);
});

test('merge queue: the enqueue respects the transition graph, not just the upsert', async () => {
  // The upsert sets status='queued' unconditionally, so this route could walk a
  // row into `queued` from a state the graph forbids. Every move it makes today
  // is legal — the point is that the GRAPH decides, or the next status added
  // here disagrees with PATCH silently.
  const legal = await call('/api/merge-queue', {
    method: 'POST', body: { project: 'project-3', pr: 41 },
    state: { mergeQueue: [MQ({ status: 'landed' })] } });
  assert.equal(legal.status, 201, 'landed -> queued is legal (a revert, a reopen)');
  const check = legal.db._calls.some((c) => /FROM merge_queue WHERE project/.test(c.sql));
  assert.ok(check, 'the enqueue must READ the current status before overwriting it');
});

test('merge queue: FIFO has a tiebreak, because same-second enqueues are real', async () => {
  // bin/merge-queue.sh materialises rows by touching files, and `ls -tr` orders
  // by mtime — two rows enqueued in the same second would tie there as well, so
  // the order has to be defined here or landings reorder.
  const state = { mergeQueue: [
    MQ({ pr: 9, enqueued_at: '2026-09-10T01:00:00Z' }),
    MQ({ pr: 3, enqueued_at: '2026-09-10T01:00:00Z' }),
  ] };
  const r = await call('/api/merge-queue?project=project-3&status=queued', { state });
  assert.deepEqual(r.body.merge_queue.map((m) => m.pr), [3, 9]);
  const sql = r.db._calls.find((c) => /FROM merge_queue/.test(c.sql)).sql;
  assert.match(sql, /ORDER BY enqueued_at ASC, pr ASC/);
  assert.ok(/LIMIT [1-9]\d*$/.test(sql), `limit must stay positive, got: ${sql}`);
});
