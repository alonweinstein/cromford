import test from 'node:test';
import assert from 'node:assert/strict';
import worker from '../src/index.js';
import { openDb } from './lib/d1-sqlite.bh-1030.js';

// BH-1026.1 — the four `deploy_queue` routes, driven against THE SQL THAT SHIPS.
//
// WHY REAL SQLITE AND NOT THE PATTERN-MATCHED FAKE DB. Three of the four claims
// here are properties of a STATEMENT, not of the JavaScript around it: the put's
// `ON CONFLICT(project, sha) DO UPDATE` (a repeat request must RE-OPEN a
// terminal row, never be swallowed), the claim's compare-and-swap (`AND
// status='queued'` is the whole defence against two trains firing two hooks for
// one sha) and the depart's `AND status='claimed'` guard. A stub that answers
// `changes:1` to every UPDATE passes a route with no CAS at all.
//
// The interleaving in the concurrent-claim case is real: `hooks.beforeRun` runs
// the OTHER claimant's CAS against the same database immediately before the
// route's own UPDATE executes, which is the race a single-threaded test can
// otherwise never produce.

const SECRET = 'test-secret';
const P = 'project-3';
const SHA = 'a'.repeat(40);
const SHA2 = 'b'.repeat(40);

// ONE clock read for the whole file. The stale-claim cases are the only ones
// that cannot be frozen in calendar time: the route compares `updated_at`
// against its OWN `nowIso()`, so an age fixture has to be relative to the
// instant the suite runs. Everything else below uses fixed 2026-09-22 strings.
const TEST_NOW = Date.now();   // determinism: ok the ONE anchor every age fixture below is derived from
const ago = (mins) => new Date(TEST_NOW - mins * 60e3).toISOString().replace(/\.\d{3}Z$/, 'Z');

// prepare() order IS execution order for these handlers (each one prepares,
// binds and awaits in sequence), so the log is what answers "did anything SELECT
// before the CAS".
function recorded(DB, seen) {
  return {
    prepare(sql) { seen.push(sql); return DB.prepare(sql); },
    batch(stmts) { return DB.batch(stmts); },
  };
}

async function fixture(hooks = {}) {
  const opened = await openDb(hooks);
  assert.ok(opened, 'node:sqlite is required for this suite — CI runs node 22');
  const { db, DB } = opened;
  const seen = [];
  const call = (path, { method = 'POST', body, secret = SECRET } = {}) => {
    const req = new Request(`https://jobs.test${path}`, {
      method,
      headers: {
        ...(secret ? { authorization: `Bearer ${secret}` } : {}),
        'content-type': 'application/json',
      },
      ...(body === undefined ? {} : { body: JSON.stringify(body) }),
    });
    return worker.fetch(req, { DB: recorded(DB, seen), HARNESS_SECRET: SECRET })
      .then(async (res) => ({ status: res.status, body: await res.json().catch(() => null) }));
  };
  const row = (sha, project = P) =>
    db.prepare('SELECT * FROM deploy_queue WHERE project=? AND sha=?').get(project, sha) ?? null;
  const count = () => db.prepare('SELECT COUNT(*) n FROM deploy_queue').get().n;
  const seed = (over = {}) => {
    const r = {
      project: P, sha: SHA, build_dir: '/b', status: 'queued', claimed_by: null,
      reason: null, enqueued_at: '2026-09-22T10:00:00Z', departed_at: null,
      updated_at: '2026-09-22T10:00:00Z', ...over,
    };
    db.prepare(`INSERT INTO deploy_queue (project, sha, build_dir, status, claimed_by, reason,
                  enqueued_at, departed_at, updated_at) VALUES (?,?,?,?,?,?,?,?,?)`)
      .run(r.project, r.sha, r.build_dir, r.status, r.claimed_by, r.reason,
           r.enqueued_at, r.departed_at, r.updated_at);
    return r;
  };
  return { db, DB, seen, call, row, count, seed };
}

// ── PUT ──────────────────────────────────────────────────────────────────────

test('deploy-queue: a repeat request while the row waits is a duplicate and writes nothing', async () => {
  const f = await fixture();
  const first = await f.call('/api/deploy-queue', { body: { project: P, sha: SHA, build_dir: '/b1' } });
  assert.equal(first.status, 201);
  assert.equal(first.body.duplicate, false);
  assert.equal(first.body.deploy.status, 'queued');

  f.seen.length = 0;
  const again = await f.call('/api/deploy-queue', { body: { project: P, sha: SHA, build_dir: '/b2' } });
  assert.equal(again.status, 200);
  assert.equal(again.body.duplicate, true);
  assert.equal(f.count(), 1, 'two requests for one sha are ONE row — that is the (project, sha) collapse');
  assert.equal(f.seen.filter((s) => /INSERT INTO deploy_queue/.test(s)).length, 0,
    'a duplicate request must not write');
  assert.equal(f.row(SHA).build_dir, '/b1', 'and must not overwrite the build dir of the request in flight');
  f.db.close();
});

test('deploy-queue: a request for a DEPARTED sha re-opens the row', async () => {
  // The case that forces it: bin/deploy-train.sh self-sources a departure
  // exactly when a sha has already departed `done` and production is STILL not
  // serving it. Swallowed as a duplicate, the train reads an empty queue and
  // production stays stale with no departure and no alert.
  const f = await fixture();
  f.seed({ status: 'done', departed_at: '2026-09-22T10:05:00Z', reason: 'VERIFIED', claimed_by: 'box-a' });
  const r = await f.call('/api/deploy-queue', { body: { project: P, sha: SHA, build_dir: 'self-sourced' } });
  assert.equal(r.status, 201);
  assert.equal(r.body.duplicate, false);
  const after = f.row(SHA);
  assert.equal(after.status, 'queued', 'the retry must RE-OPEN the row');
  assert.equal(after.departed_at, null, 'a re-opened row has not departed yet');
  assert.equal(after.reason, null, 'and carries no verdict from the departure before it');
  assert.equal(after.claimed_by, null, 'nor the claimant of the departure before it');
  assert.equal(after.build_dir, 'self-sourced', 'the new build dir wins when one is sent');
  assert.equal(after.enqueued_at, r.body.as_of, 'the wait starts again from the new request');
  assert.equal(f.count(), 1);
  f.db.close();
});

test('deploy-queue: a request for a CLAIMED sha is a duplicate — an in-flight departure is never reset', async () => {
  const f = await fixture();
  f.seed({ status: 'claimed', claimed_by: 'box-a', updated_at: '2026-09-22T10:01:00Z' });
  f.seen.length = 0;
  const r = await f.call('/api/deploy-queue', { body: { project: P, sha: SHA } });
  assert.equal(r.status, 200);
  assert.equal(r.body.duplicate, true);
  assert.equal(f.seen.filter((s) => /INSERT INTO deploy_queue|UPDATE deploy_queue/.test(s)).length, 0,
    'a claimed row must not be written at all');
  assert.equal(f.row(SHA).status, 'claimed');
  assert.equal(f.row(SHA).claimed_by, 'box-a', 'the claimant is intact');
  f.db.close();
});

test('deploy-queue: the sha is validated and normalised once, at the route', async () => {
  const f = await fixture();
  assert.equal((await f.call('/api/deploy-queue', { body: { sha: SHA } })).status, 400,
    'no project is a 400');
  assert.equal((await f.call('/api/deploy-queue', { body: { project: P } })).status, 400,
    'no sha is a 400');
  assert.equal((await f.call('/api/deploy-queue', { body: { project: P, sha: 'xyz' } })).status, 400,
    'a sha that is not hex is a 400');
  assert.equal((await f.call('/api/deploy-queue', { body: { project: P, sha: 'abc' } })).status, 400,
    'a sha shorter than 7 is a 400');
  assert.equal((await f.call('/api/deploy-queue', { body: { project: P, sha: 'a'.repeat(65) } })).status, 400,
    'a sha longer than 64 is a 400');

  const up = await f.call('/api/deploy-queue', { body: { project: P, sha: '  ABC1234  ' } });
  assert.equal(up.status, 201);
  assert.equal(up.body.deploy.sha, 'abc1234');
  assert.ok(f.row('abc1234'), 'the stored key is the normalised one');
  // Same identity, asked for in the other case: the duplicate proves the
  // normalisation happens on the LOOKUP too, not only on the write (D17).
  const again = await f.call('/api/deploy-queue', { body: { project: P, sha: 'ABC1234' } });
  assert.equal(again.body.duplicate, true);
  assert.equal(f.count(), 1);

  assert.equal((await f.call('/api/deploy-queue', { body: { project: P, sha: SHA }, secret: null })).status, 401);
  f.db.close();
});

// ── CLAIM ────────────────────────────────────────────────────────────────────

test('deploy-queue: the claim is a compare-and-swap, and the loser of a real race gets 409', async () => {
  // The interleaving: the SECOND claimant's CAS lands against the same database
  // between this route's (nonexistent) read and its own UPDATE.
  let raced = false;
  let db;
  const f = await fixture({
    beforeRun(sql) {
      if (raced || !/UPDATE deploy_queue SET status='claimed'/.test(sql)) return;
      raced = true;
      db.prepare("UPDATE deploy_queue SET status='claimed', claimed_by='box-b', updated_at='2026-09-22T10:02:00Z' WHERE project=? AND sha=? AND status='queued'")
        .run(P, SHA);
    },
  });
  db = f.db;
  f.seed();
  f.seen.length = 0;

  const r = await f.call('/api/deploy-queue/claim', { body: { project: P, sha: SHA, box: 'box-a' } });
  assert.ok(raced, 'the hook never fired — this case proves nothing unless the CAS really ran');
  assert.equal(r.status, 409, 'the loser must never be handed a departure somebody else took');
  assert.equal(r.body.refused, true);
  assert.equal(r.body.scope, 'deploy-queue');
  assert.equal(r.body.deploy.claimed_by, 'box-b', 'and must be told who has it');
  assert.equal(f.row(SHA).claimed_by, 'box-b', 'the winner keeps the row');

  // NEVER A READ-THEN-WRITE: nothing may SELECT this table before the CAS.
  const upd = f.seen.findIndex((s) => /UPDATE deploy_queue/.test(s));
  const sel = f.seen.findIndex((s) => /SELECT \* FROM deploy_queue/.test(s));
  assert.ok(upd >= 0, 'the claim must write');
  assert.ok(sel === -1 || sel > upd,
    `a read before the CAS is a read-then-write: ${f.seen.join(' | ')}`);
  f.db.close();
});

test('deploy-queue: a claim takes a queued row and stamps the claimant', async () => {
  const f = await fixture();
  f.seed();
  const r = await f.call('/api/deploy-queue/claim', { body: { project: P, sha: SHA, box: 'box-a' } });
  assert.equal(r.status, 200);
  assert.equal(r.body.claimed, true);
  assert.equal(r.body.deploy.claimed_by, 'box-a');
  assert.equal(r.body.deploy.status, 'claimed');
  assert.equal(r.body.deploy.updated_at, r.body.as_of, 'the claim stamps updated_at — the age the re-offer reads');
  assert.equal(f.row(SHA).status, 'claimed');
  assert.equal(f.row(SHA).departed_at, null, 'claiming is not departing');
  assert.equal((await f.call('/api/deploy-queue/claim', { body: { project: P, box: 'b' } })).status, 400);
  assert.equal((await f.call('/api/deploy-queue/claim', { body: { project: P, sha: SHA } })).status, 400,
    'a claim with no box names no claimant and must be refused');
  f.db.close();
});

test('deploy-queue: stale_min re-offers a claim that went quiet, and only that one', async () => {
  const f = await fixture();
  f.seed({ sha: SHA, status: 'claimed', claimed_by: 'dead-box', updated_at: ago(45) });
  f.seed({ sha: SHA2, status: 'claimed', claimed_by: 'live-box', updated_at: ago(5) });
  const gone = 'c'.repeat(40);
  f.seed({ sha: gone, status: 'claimed', claimed_by: 'box-a', departed_at: ago(40), updated_at: ago(40) });

  const old = await f.call('/api/deploy-queue/claim', { body: { project: P, sha: SHA, box: 'box-n', stale_min: 30 } });
  assert.equal(old.status, 200, 'a claim quiet for 45 minutes is re-offered at stale_min 30');
  assert.equal(f.row(SHA).claimed_by, 'box-n');

  const fresh = await f.call('/api/deploy-queue/claim', { body: { project: P, sha: SHA2, box: 'box-n', stale_min: 30 } });
  assert.equal(fresh.status, 409, 'a claim 5 minutes old is a live train — never taken from under it');
  assert.equal(f.row(SHA2).claimed_by, 'live-box');

  const departed = await f.call('/api/deploy-queue/claim', { body: { project: P, sha: gone, box: 'box-n', stale_min: 30 } });
  assert.equal(departed.status, 409, 'a row that already departed is not re-offered by age');

  // D11: junk is NOT clamped to a number — it means no cutoff at all.
  f.seed({ sha: 'd'.repeat(40), status: 'claimed', claimed_by: 'dead-box', updated_at: ago(45) });
  const junk = await f.call('/api/deploy-queue/claim',
    { body: { project: P, sha: 'd'.repeat(40), box: 'box-n', stale_min: 'abc' } });
  assert.equal(junk.status, 409, 'stale_min="abc" is no cutoff, so the plain CAS refuses a claimed row');
  f.db.close();
});

test('deploy-queue: an unknown sha is a 404 and a terminal row is a 409', async () => {
  const f = await fixture();
  const none = await f.call('/api/deploy-queue/claim', { body: { project: P, sha: SHA, box: 'box-a' } });
  assert.equal(none.status, 404, '"nothing queued" is a real answer the client reads as rc 2');
  f.seed({ status: 'done', departed_at: '2026-09-22T10:05:00Z' });
  const done = await f.call('/api/deploy-queue/claim', { body: { project: P, sha: SHA, box: 'box-a' } });
  assert.equal(done.status, 409);
  assert.equal(f.row(SHA).status, 'done', 'a claim must never re-open a departed row');
  f.db.close();
});

// ── DEPART ───────────────────────────────────────────────────────────────────

test('deploy-queue: a departure is refused on a row that is not claimed', async () => {
  const f = await fixture();
  f.seed();
  const r = await f.call('/api/deploy-queue/depart', { body: { project: P, sha: SHA, status: 'done' } });
  assert.equal(r.status, 409);
  assert.equal(r.body.refused, true);
  assert.match(r.body.error, /queued/, 'the refusal says what the row actually is');
  assert.equal(f.row(SHA).departed_at, null, 'and nothing was stamped');
  assert.equal(f.row(SHA).status, 'queued');
  const ghost = await f.call('/api/deploy-queue/depart',
    { body: { project: P, sha: SHA2, status: 'done' } });
  assert.equal(ghost.status, 404, 'a departure for a row that does not exist is never a silent create');
  f.db.close();
});

test('deploy-queue: depart done stamps departed_at and keeps the claimant; depart queued is the release', async () => {
  const f = await fixture();
  f.seed({ status: 'claimed', claimed_by: 'box-a' });
  const done = await f.call('/api/deploy-queue/depart',
    { body: { project: P, sha: SHA, status: 'done', reason: 'VERIFIED live at abcd1234' } });
  assert.equal(done.status, 200);
  assert.equal(done.body.deploy.status, 'done');
  assert.equal(f.row(SHA).departed_at, done.body.as_of, 'departed_at is stamped only when the departure returns');
  assert.equal(f.row(SHA).claimed_by, 'box-a', 'which box ran the departure is ledger');
  assert.equal(f.row(SHA).reason, 'VERIFIED live at abcd1234');

  f.seed({ sha: SHA2, status: 'claimed', claimed_by: 'box-a' });
  const rel = await f.call('/api/deploy-queue/depart',
    { body: { project: P, sha: SHA2, status: 'queued', reason: 'production still not serving abcd1234' } });
  assert.equal(rel.status, 200);
  assert.equal(f.row(SHA2).status, 'queued');
  assert.equal(f.row(SHA2).departed_at, null, 'a released row has not departed');
  assert.equal(f.row(SHA2).claimed_by, null,
    'a released row must carry no claimant, or the next train reads it as in flight');
  assert.equal(f.row(SHA2).reason, 'production still not serving abcd1234');

  const bad = await f.call('/api/deploy-queue/depart', { body: { project: P, sha: SHA, status: 'merged' } });
  assert.equal(bad.status, 400, 'an unknown terminal status is refused rather than stored');
  assert.equal(f.row(SHA).status, 'done');
  f.db.close();
});

// ── LIST ─────────────────────────────────────────────────────────────────────

test('deploy-queue: the list is bounded by project and status, FIFO with a sha tiebreak', async () => {
  const f = await fixture();
  f.seed({ sha: SHA2, enqueued_at: '2026-09-22T10:00:00Z' });
  f.seed({ sha: SHA, enqueued_at: '2026-09-22T10:00:00Z' });
  f.seed({ sha: 'c'.repeat(40), enqueued_at: '2026-09-22T09:00:00Z' });
  f.seed({ sha: 'd'.repeat(40), status: 'done', departed_at: '2026-09-22T09:30:00Z' });
  f.seed({ sha: 'e'.repeat(40), project: 'project-4' });

  f.seen.length = 0;
  const mine = await f.call('/api/deploy-queue?project=project-3&status=queued', { method: 'GET' });
  assert.equal(mine.status, 200);
  assert.deepEqual(mine.body.deploy_queue.map((d) => d.sha),
    ['c'.repeat(40), SHA, SHA2],
    'oldest first, and two rows enqueued in the same second break the tie on sha');
  const sql = f.seen.find((s) => /FROM deploy_queue/.test(s));
  assert.match(sql, /WHERE project=\?1 AND status=\?2/, 'both filters must ride the index, not a post-filter');
  assert.match(sql, /ORDER BY enqueued_at ASC, sha ASC/);
  assert.ok(/LIMIT [1-9]\d*$/.test(sql), `the page must stay bounded, got: ${sql}`);

  // SQLite reads LIMIT -1 as UNBOUNDED, so a negative or junk ?limit= must come
  // out POSITIVE. The clamp is `Math.min(Math.max(1, n || 200), 500)`, the same
  // one GET /api/queue ships, so -1 lands on 1 and not on the default — what
  // this pins is that it can never land on "the whole table".
  f.seen.length = 0;
  await f.call('/api/deploy-queue?limit=-1', { method: 'GET' });
  assert.match(f.seen.find((s) => /FROM deploy_queue/.test(s)), /LIMIT 1$/);
  f.seen.length = 0;
  await f.call('/api/deploy-queue?limit=abc', { method: 'GET' });
  assert.match(f.seen.find((s) => /FROM deploy_queue/.test(s)), /LIMIT 200$/);
  f.seen.length = 0;
  await f.call('/api/deploy-queue?limit=9999', { method: 'GET' });
  assert.match(f.seen.find((s) => /FROM deploy_queue/.test(s)), /LIMIT 500$/);

  const one = await f.call(`/api/deploy-queue?project=project-3&sha=${SHA.toUpperCase()}`, { method: 'GET' });
  assert.deepEqual(one.body.deploy_queue.map((d) => d.sha), [SHA],
    '?sha= is normalised the same way the write is');
  f.db.close();
});

test('deploy-queue: ?stale_min= returns only the claims that went quiet and never departed', async () => {
  const f = await fixture();
  f.seed({ sha: SHA, status: 'claimed', claimed_by: 'dead-box', updated_at: ago(45) });
  f.seed({ sha: SHA2, status: 'claimed', claimed_by: 'live-box', updated_at: ago(5) });
  f.seed({ sha: 'c'.repeat(40), status: 'claimed', claimed_by: 'box-a',
           departed_at: ago(40), updated_at: ago(40) });
  f.seed({ sha: 'd'.repeat(40), status: 'queued', updated_at: ago(99) });

  const r = await f.call('/api/deploy-queue?project=project-3&status=claimed&stale_min=30', { method: 'GET' });
  assert.deepEqual(r.body.deploy_queue.map((d) => d.sha), [SHA],
    'a fresh claim, a departed row and a queued row are none of them stranded claims');
  f.db.close();
});
