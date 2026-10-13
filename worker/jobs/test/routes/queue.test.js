import test from 'node:test';
import assert from 'node:assert/strict';
import { call, iso, now, worker } from '../lib/harness.js';

const QUEUED = (over) => ({
  project: 'project-3', ticket_key: 'TK-109', ticket_id: '109', status: 'queued',
  target: 'fly', attempt: 0, requested_by: 'box-project-3-2',
  claimed_by: null, claimed_at: null, enqueued_at: iso(600e3), finished_at: null,
  reason: null, meta: null, updated_at: iso(600e3),
  ...over
});
test('queue: an enqueue is a row keyed on project + KEY', async () => {
  const r = await call('/api/queue', { method: 'POST', body: {
    project: 'project-3', key: 'TK-109', ticket_id: '109', target: 'fly',
    attempt: 0, requested_by: 'box-project-3-2'
  } });
  assert.equal(r.status, 201);
  assert.equal(r.body.queued.ticket_key, 'TK-109');
  assert.equal(r.body.queued.target, 'fly');
  assert.equal(r.body.duplicate, false);
  const ins = r.db._calls.find((c) => /INSERT INTO build_queue/.test(c.sql));
  assert.ok(ins, 'the enqueue must write a row');
  assert.match(ins.sql, /ON CONFLICT\(project, ?ticket_key\)/,
    'the upsert must be keyed on the same pair the file queue is keyed on');
});

test('queue: enqueueing the same build twice while it waits writes nothing', async () => {
  // The file queue was idempotent because a filename can only exist once.
  // run-build.sh, the fly requeue and a triage relaunch all enqueue the same
  // key, so a second row — or a reset attempt counter — is a duplicate build.
  const r = await call('/api/queue', {
    method: 'POST',
    body: { project: 'project-3', key: 'TK-109', ticket_id: '109', target: 'fly' },
    state: { queue: [QUEUED()] }
  });
  assert.equal(r.status, 200);
  assert.equal(r.body.duplicate, true);
  assert.equal(r.body.queued.ticket_key, 'TK-109');
  assert.equal(r.db._calls.filter((c) => /INSERT INTO build_queue/.test(c.sql)).length, 0,
    'a duplicate enqueue must not write');
});

test('queue: a build already CLAIMED is also a duplicate, not a new queue entry', async () => {
  // The expensive one. fly-dispatch re-enqueued TK-70 mid-build (2026-08-13)
  // and the leftover spawned a second build after the reap.
  const r = await call('/api/queue', {
    method: 'POST',
    body: { project: 'project-3', key: 'TK-109' },
    state: { queue: [QUEUED({ status: 'claimed', claimed_by: 'fly-machine-1' })] }
  });
  assert.equal(r.status, 200);
  assert.equal(r.body.duplicate, true);
  assert.equal(r.body.queued.claimed_by, 'fly-machine-1');
  assert.equal(r.db._calls.filter((c) => /INSERT INTO build_queue/.test(c.sql)).length, 0);
});

test('queue: re-queueing a FINISHED build is a real new attempt', async () => {
  // A ticket genuinely built again later — a fix round, a revert, a human
  // relaunch — must not be refused as a duplicate of work that is over.
  const r = await call('/api/queue', {
    method: 'POST',
    body: { project: 'project-3', key: 'TK-109' },
    state: { queue: [QUEUED({ status: 'done', attempt: 1 })] }
  });
  assert.equal(r.status, 201);
  assert.equal(r.body.duplicate, false);
  assert.equal(r.body.queued.attempt, 2, 'the attempt counter carries across the re-queue');
});

test('queue: claim takes the OLDEST queued row and compare-and-swaps it', async () => {
  const state = { queue: [
    QUEUED({ ticket_key: 'TK-2', enqueued_at: iso(60e3) }),
    QUEUED({ ticket_key: 'TK-1', enqueued_at: iso(9000e3) })
  ] };
  const r = await call('/api/queue/claim', { method: 'POST', body: { project: 'project-3', box: 'hub' }, state });
  assert.equal(r.status, 200);
  assert.equal(r.body.queued.ticket_key, 'TK-1', 'FIFO by enqueued_at, not by key order');
  assert.equal(r.body.queued.status, 'claimed');
  assert.equal(r.body.queued.claimed_by, 'hub');
  const cas = r.db._calls.find((c) => /UPDATE build_queue SET status='claimed'/.test(c.sql));
  assert.ok(cas, 'the claim must write');
  assert.match(cas.sql, /AND status='queued'/,
    'the claim must be a compare-and-swap — without the status in the WHERE clause two dispatchers both take one row');
});

test('queue: a claimant that loses EVERY race is told so, and never handed the same build', async () => {
  // CONTRACT CHANGED 2026-09-10 (review of #222), and this test changed with it
  // rather than being deleted. It used to assert a 409 on the FIRST loss for an
  // unkeyed claim; that made losing the race for the oldest row cost a whole
  // tick while other work sat queued behind it. An unkeyed claim now walks on
  // to the next candidate. What has NOT changed, and is still asserted here, is
  // the thing that matters: the loser is never handed a row somebody else took.
  const state = { queue: [QUEUED()], queueCasLost: true };
  const r = await call('/api/queue/claim', { method: 'POST', body: { project: 'project-3', box: 'hub' }, state });
  assert.notEqual(r.status, 200, 'a lost race must never come back as a claim');
  assert.deepEqual(r.body.skipped, ['TK-109'], 'and it must name what it could not take');
});

test('queue: an empty queue is a 404 — a real answer, not an outage', async () => {
  // bin/jobs-client.sh turns a 404 into rc 2 and does NOT burn the daily
  // unreachable-worker alert on it. "Nothing to build" is the normal shape of a
  // quiet project and must never look like a broken coordination DB.
  const r = await call('/api/queue/claim', { method: 'POST', body: { project: 'project-3', box: 'hub' } });
  assert.equal(r.status, 404);
});

test('queue: a claim for one target never takes another target\'s work', async () => {
  const state = { queue: [
    QUEUED({ ticket_key: 'LOCAL-1', target: 'local', enqueued_at: iso(9000e3) }),
    QUEUED({ ticket_key: 'FLY-1', target: 'fly', enqueued_at: iso(60e3) })
  ] };
  const r = await call('/api/queue/claim', { method: 'POST', body: { project: 'project-3', box: 'hub', target: 'fly' }, state });
  assert.equal(r.status, 200);
  assert.equal(r.body.queued.ticket_key, 'FLY-1');
});

test('queue: a named key claims exactly that row, and only while it is queued', async () => {
  // The local launch path knows which build it is about to run; it does not
  // want the oldest, it wants THIS one, and it must not take one already taken.
  const state = { queue: [QUEUED({ ticket_key: 'TK-7' }), QUEUED({ ticket_key: 'TK-8' })] };
  const ok = await call('/api/queue/claim', { method: 'POST', body: { project: 'project-3', box: 'b1', key: 'TK-8' }, state });
  assert.equal(ok.status, 200);
  assert.equal(ok.body.queued.ticket_key, 'TK-8');
  const taken = await call('/api/queue/claim', {
    method: 'POST', body: { project: 'project-3', box: 'b2', key: 'TK-8' },
    state: { queue: [QUEUED({ ticket_key: 'TK-8', status: 'claimed', claimed_by: 'b1' })] }
  });
  assert.equal(taken.status, 404, 'a row that is not queued is not claimable');
});

test('queue: complete stamps a terminal row; release puts it back with no claimant', async () => {
  const state = { queue: [QUEUED({ status: 'claimed', claimed_by: 'fly-1' })] };
  const done = await call('/api/queue', {
    method: 'PATCH', body: { project: 'project-3', key: 'TK-109', status: 'done', reason: 'PR_CREATED' }, state });
  assert.equal(done.status, 200);
  assert.equal(done.body.queued.status, 'done');
  assert.ok(done.body.queued.finished_at, 'a terminal row records when it ended');

  const rel = await call('/api/queue', {
    method: 'PATCH', body: { project: 'project-3', key: 'TK-109', status: 'queued', reason: 'push failed' }, state });
  assert.equal(rel.status, 200);
  assert.equal(rel.body.queued.status, 'queued');
  assert.equal(rel.body.queued.claimed_by, null,
    'a released row must carry no claimant, or the next claim reads it as still in flight');
});

test('queue: an unknown status is refused rather than stored', async () => {
  // These strings drive the dispatcher and the console. A typo that lands as a
  // permanent unknown is worse than a 409 the fail-open caller drops.
  const r = await call('/api/queue', {
    method: 'PATCH', body: { project: 'project-3', key: 'TK-109', status: 'finito' },
    state: { queue: [QUEUED()] } });
  assert.equal(r.status, 409);
});

test('queue: a PATCH for a row that does not exist is a 404, never a silent create', async () => {
  const r = await call('/api/queue', { method: 'PATCH', body: { project: 'project-3', key: 'ghost', status: 'done' } });
  assert.equal(r.status, 404);
});

test('queue: list filters by project and status', async () => {
  const state = { queue: [
    QUEUED({ project: 'project-3', ticket_key: 'A' }),
    QUEUED({ project: 'project-4', ticket_key: 'B' }),
    QUEUED({ project: 'project-3', ticket_key: 'C', status: 'done' })
  ] };
  const all = await call('/api/queue', { state });
  assert.equal(all.body.queue.length, 3);
  const mine = await call('/api/queue?project=project-3&status=queued', { state });
  assert.deepEqual(mine.body.queue.map((q) => q.ticket_key), ['A']);
});

test('queue: no bearer, no queue', async () => {
  const r = await call('/api/queue', { secret: null });
  assert.equal(r.status, 401);
  const c = await call('/api/queue/claim', { method: 'POST', body: { project: 'p', box: 'b' }, secret: 'nope' });
  assert.equal(c.status, 401);
});

test('queue: project and key are required, and a key is held to one path segment', async () => {
  const noProject = await call('/api/queue', { method: 'POST', body: { key: 'TK-1' } });
  assert.equal(noProject.status, 400);
  const noKey = await call('/api/queue', { method: 'POST', body: { project: 'project-3' } });
  assert.equal(noKey.status, 400);
  // The key was a FILENAME on every box in the fleet and still is on the
  // fallback path, so it is held to the same character class box names are.
  const bad = await call('/api/queue', { method: 'POST', body: { project: 'project-3', key: '../../etc/passwd' } });
  assert.equal(bad.status, 400);
});

test('queue: ?key= answers the status of ONE build', async () => {
  // The fly dispatcher's drain needs this per box file to tell "never enqueued"
  // (pull it, as today) from "already claimed or finished" (drop it). Without
  // the distinction a stale box file is pulled after its build was reaped and
  // the pool spawns a second machine for the key.
  const state = { queue: [QUEUED({ ticket_key: 'TK-9', status: 'claimed' }),
                          QUEUED({ ticket_key: 'TK-8', status: 'queued' })] };
  const r = await call('/api/queue?project=project-3&key=TK-9&limit=1', { state });
  assert.equal(r.status, 200);
  assert.deepEqual(r.body.queue.map((q) => [q.ticket_key, q.status]), [['TK-9', 'claimed']]);
  const none = await call('/api/queue?project=project-3&key=NOPE&limit=1', { state });
  assert.deepEqual(none.body.queue, [], 'no row is an empty list, which the client reads as rc 2');
});

test('queue: ?reason_deferred=1 returns only the rows that STOOD DOWN', async () => {
  // The pool-cap refusal class (2026-09-11). bin/fly-pool.sh closed the row
  // `done` for a build that never ran, so the ticket was never offered again.
  // bin/jobs-watchdog.sh re-queues exactly those rows — and it can only find
  // them if it can ASK for them: this page is oldest-first and capped, so once
  // the table holds a page of finished builds an unfiltered scan would never
  // reach today's deferral.
  const state = { queue: [
    QUEUED({ ticket_key: 'TK-268', status: 'done',
             reason: 'BUILD_DEFERRED REFUSED box :: box max 1 already running' }),
    QUEUED({ ticket_key: 'TK-269', status: 'done',
             reason: 'PR_CREATED https://github.com/example-org/project-5/pull/77' }),
    QUEUED({ ticket_key: 'TK-270', status: 'failed',
             reason: 'died twice (state=gone) — parked for a human' }),
    QUEUED({ ticket_key: 'TK-271', status: 'done', reason: null }),
  ] };
  const r = await call('/api/queue?status=done&reason_deferred=1', { state });
  assert.equal(r.status, 200);
  assert.deepEqual(r.body.queue.map((q) => q.ticket_key), ['TK-268'],
    'a finished build, a death and a row with no reason are all NOT deferrals');
  // The REFUSED half is matched anywhere in the reason, not only at the start:
  // the concurrency refusal arrives as "REFUSED <scope> :: <rule>" inside the
  // line run-build.sh wrote.
  const refused = { queue: [QUEUED({ ticket_key: 'TK-1515', status: 'failed',
    reason: 'queue row closed after REFUSED box :: box max 1 already running' })] };
  const r2 = await call('/api/queue?status=failed&reason_deferred=1', { state: refused });
  assert.deepEqual(r2.body.queue.map((q) => q.ticket_key), ['TK-1515']);
  // Without the flag the route is unchanged — no filter, every row.
  const all = await call('/api/queue?status=done', { state });
  assert.equal(all.body.queue.length, 3);
});

test('queue: ?stale_min= returns CLAIMED rows whose claim went quiet', async () => {
  // A row claimed by a machine that then died is never closed, and the enqueue
  // guard treats `claimed` as accounted-for — so the ticket can never be queued
  // again. This is what the watchdog asks for.
  const state = { queue: [
    QUEUED({ ticket_key: 'FRESH', status: 'claimed', claimed_at: iso(60e3) }),
    QUEUED({ ticket_key: 'STUCK', status: 'claimed', claimed_at: iso(9 * 3600e3) }),
    QUEUED({ ticket_key: 'WAITING', status: 'queued', claimed_at: null }),
  ] };
  const r = await call('/api/queue?status=claimed&stale_min=360', { state });
  assert.deepEqual(r.body.queue.map((q) => q.ticket_key), ['STUCK']);
});

test('queue: an unkeyed claim walks past a row it LOST to the next one', async () => {
  // Losing the race for the oldest row is not "nothing to do": returning 409
  // would skip a whole tick while other work sits queued behind it. A claim for
  // a NAMED key still refuses, because there the caller wanted that row only.
  const state = { queue: [
    QUEUED({ ticket_key: 'TAKEN', enqueued_at: iso(9000e3) }),
    QUEUED({ ticket_key: 'MINE', enqueued_at: iso(60e3) }),
  ], queueCasLoseKeys: ['TAKEN'] };
  const r = await call('/api/queue/claim', { method: 'POST', body: { project: 'project-3', box: 'hub' }, state });
  assert.equal(r.status, 200, 'the walk must land on the next row, not give up on the tick');
  assert.equal(r.body.queued.ticket_key, 'MINE');
  assert.deepEqual(r.body.skipped, ['TAKEN'], 'and it must say which row it lost');
});

test('queue: a NAMED key still refuses when it loses — it wanted that row', async () => {
  const state = { queue: [QUEUED({ ticket_key: 'TK-9' })], queueCasLost: true };
  const r = await call('/api/queue/claim', {
    method: 'POST', body: { project: 'project-3', box: 'hub', key: 'TK-9' }, state });
  assert.equal(r.status, 409);
  assert.equal(r.body.refused, true);
});

test('queue and artifacts: a junk limit cannot become UNBOUNDED', async () => {
  // SQLite reads LIMIT -1 as "no limit", so a negative ?limit= would return the
  // whole table on a route meant to hand back a page.
  const state = { queue: [QUEUED()], jobs: [], artifacts: [] };
  const q = await call('/api/queue?limit=-1', { state });
  assert.equal(q.status, 200);
  const sql = q.db._calls.find((c) => /FROM build_queue/.test(c.sql)).sql;
  assert.ok(/LIMIT [1-9]\d*$/.test(sql), `limit must stay positive, got: ${sql}`);
  const a = await call('/api/artifacts?limit=-5', { state });
  const asql = a.db._calls.find((c) => /FROM job_artifacts a JOIN/.test(c.sql)).sql;
  assert.ok(/LIMIT [1-9]\d*$/.test(asql), `artifact limit must stay positive, got: ${asql}`);
});
