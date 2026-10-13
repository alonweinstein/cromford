import test from 'node:test';
import assert from 'node:assert/strict';
import worker from '../src/index.js';
import { openDb } from './lib/d1-sqlite.bh-1030.js';

// BH-2670 (BH-2530.1) — the five `fix_round_jobs` routes, driven through
// worker.fetch against THE SQL THAT SHIPS (schema.sql in node:sqlite).
//
// Real SQLite for the deploy-queue reason: every guarantee here is a property
// of a statement. The enqueue dedup is the partial unique index plus
// `ON CONFLICT DO NOTHING`, the claim is a CAS that names the box, finish is a
// CAS on `status='claimed' AND claimed_by=?`, and adopt is a CAS on
// `status='done'`. A stub answering `changes:1` would pass a route with none.
//
// The races are real: `hooks.beforeRun` runs the OTHER writer's statement
// against the same database immediately before the route's own write.

const SECRET = 'test-secret';
const P = 'project-3';
const CK = 'project-3#123@abc1234';
const ARGS = ['project-3', '123', 'abc1234', 'fix', '/b', 'x'];

const TEST_NOW = Date.now();   // determinism: ok the ONE anchor the stale-claim fixtures are derived from
const ago = (mins) => new Date(TEST_NOW - mins * 60e3).toISOString().replace(/\.\d{3}Z$/, 'Z');

async function fixture(hooks = {}) {
  const opened = await openDb(hooks);
  assert.ok(opened, 'node:sqlite is required for this suite — CI runs node 22');
  const { db, DB } = opened;
  const call = (path, { method = 'POST', body, secret = SECRET, raw } = {}) => {
    const req = new Request(`https://jobs.test${path}`, {
      method,
      headers: {
        ...(secret ? { authorization: `Bearer ${secret}` } : {}),
        'content-type': 'application/json',
      },
      ...(raw !== undefined ? { body: raw } : body === undefined ? {} : { body: JSON.stringify(body) }),
    });
    return worker.fetch(req, { DB, HARNESS_SECRET: SECRET })
      .then(async (res) => ({ status: res.status, body: await res.json().catch(() => null) }));
  };
  const row = (id) => db.prepare('SELECT * FROM fix_round_jobs WHERE id=?').get(id) ?? null;
  const count = () => db.prepare('SELECT COUNT(*) n FROM fix_round_jobs').get().n;
  const seed = (over = {}) => {
    const r = {
      project: P, cap_key: CK, box: 'box-a', args: JSON.stringify(ARGS), record_in: null,
      hotfix: 0, status: 'queued', attempt: 0, claimed_by: null, claimed_at: null,
      enqueued_at: '2026-09-26T10:00:00Z', updated_at: '2026-09-26T10:00:00Z', ...over,
    };
    const res = db.prepare(`INSERT INTO fix_round_jobs (project, cap_key, box, args, record_in, hotfix,
                  status, attempt, claimed_by, claimed_at, enqueued_at, updated_at)
                  VALUES (?,?,?,?,?,?,?,?,?,?,?,?)`)
      .run(r.project, r.cap_key, r.box, r.args, r.record_in, r.hotfix, r.status, r.attempt,
           r.claimed_by, r.claimed_at, r.enqueued_at, r.updated_at);
    return Number(res.lastInsertRowid);
  };
  const enq = (over = {}) => call('/api/fix-rounds', {
    body: { project: P, cap_key: CK, box: 'box-a', hotfix: 0, args: ARGS, ...over },
  });
  return { db, call, row, count, seed, enq };
}

// ── 1. ENQUEUE ───────────────────────────────────────────────────────────────

test('fix-rounds 1: enqueue answers 201, a repeat is a duplicate that writes nothing, adopted leaves the index', async () => {
  const f = await fixture();
  const a = await f.enq({ hotfix: true, record_in: '{"round":1}' });
  assert.equal(a.status, 201, JSON.stringify(a.body));
  assert.equal(a.body.duplicate, false);
  assert.equal(a.body.job.status, 'queued');
  assert.equal(a.body.job.attempt, 0);
  assert.equal(a.body.job.hotfix, 1);
  assert.equal(a.body.job.box, 'box-a');
  assert.equal(a.body.job.record_in, '{"round":1}');
  assert.deepEqual(a.body.job.args, ARGS, 'args round-trips as the array that was sent');
  assert.equal(typeof a.body.as_of, 'string');

  const b = await f.enq({ hotfix: 0 });
  assert.equal(b.status, 200, JSON.stringify(b.body));
  assert.equal(b.body.duplicate, true);
  assert.equal(b.body.job.id, a.body.job.id);
  assert.equal(b.body.job.hotfix, 1, 'the duplicate answers the row that exists, unchanged');
  assert.equal(f.count(), 1, 'a duplicate writes nothing');

  // claimed and done are still open: a repeat is still a duplicate, never a second paid round.
  f.db.prepare("UPDATE fix_round_jobs SET status='done' WHERE id=?").run(a.body.job.id);
  const c = await f.enq();
  assert.equal(c.status, 200);
  assert.equal(c.body.duplicate, true);
  assert.equal(f.count(), 1);

  f.db.prepare("UPDATE fix_round_jobs SET status='adopted' WHERE id=?").run(a.body.job.id);
  const d = await f.enq();
  assert.equal(d.status, 201, 'an adopted row is history, not an open round');
  assert.notEqual(d.body.job.id, a.body.job.id);
  assert.equal(f.count(), 2);
  f.db.close();
});

test('fix-rounds 2: a concurrent enqueue writes one row and answers the loser as a duplicate', async () => {
  let raced = false;
  let db;
  const f = await fixture({
    beforeRun(sql) {
      if (raced || !/INSERT INTO fix_round_jobs/.test(sql)) return;
      raced = true;
      db.prepare(`INSERT INTO fix_round_jobs (project, cap_key, box, args, status, attempt, enqueued_at, updated_at)
                  VALUES (?,?,?,?, 'queued', 0, '2026-09-26T10:00:00Z', '2026-09-26T10:00:00Z')`)
        .run(P, CK, 'box-b', JSON.stringify(ARGS));
    },
  });
  db = f.db;
  const r = await f.enq();
  assert.ok(raced, 'the hook never fired — this case proves nothing unless the INSERT really ran');
  assert.equal(r.status, 200, JSON.stringify(r.body));
  assert.equal(r.body.duplicate, true);
  assert.equal(r.body.job.box, 'box-b', 'the answer is the row the racer wrote');
  assert.equal(f.count(), 1);
  f.db.close();
});

test('fix-rounds 3: record_in over 256 KB is 413 and writes nothing; exactly 256 KB is accepted', async () => {
  const f = await fixture();
  const over = await f.enq({ record_in: 'x'.repeat(256 * 1024 + 1) });
  assert.equal(over.status, 413, JSON.stringify(over.body));
  assert.equal(over.body.max, 256 * 1024);
  assert.equal(f.count(), 0, 'an oversized record is refused, never truncated and stored');
  // bytes, not code units: 'é' is two bytes, so this is 256 KB + 2 in 128 KB + 1 characters.
  const mb = await f.enq({ record_in: 'é'.repeat(128 * 1024 + 1) });
  assert.equal(mb.status, 413);
  assert.equal(f.count(), 0);
  const exact = await f.enq({ record_in: 'x'.repeat(256 * 1024) });
  assert.equal(exact.status, 201);
  assert.equal(f.row(exact.body.job.id).record_in.length, 256 * 1024, 'stored whole');
  f.db.close();
});

test('fix-rounds 4: enqueue refuses bad shapes with 400 and writes nothing', async () => {
  const f = await fixture();
  const bad = [
    { args: ARGS.slice(0, 5) },
    { args: [...ARGS, 'y'] },
    { args: [1, 'a', 'b', 'c', 'd', 'e'] },
    { args: 'a b c d e f' },
    { project: undefined },
    { project: 'bad project' },
    { box: 'a b' },
    { box: '' },
    { cap_key: '' },
    { cap_key: 'a\nb' },
    { cap_key: 7 },
    { hotfix: 2 },
    { hotfix: '1' },
    { record_in: 42 },
  ];
  for (const over of bad) {
    const r = await f.enq(over);
    assert.equal(r.status, 400, `${JSON.stringify(over)} → ${r.status} ${JSON.stringify(r.body)}`);
  }
  const junk = await f.call('/api/fix-rounds', { raw: '{not json' });
  assert.equal(junk.status, 400);
  assert.equal(f.count(), 0);
  // absent hotfix is 0, false is 0
  const ok = await f.enq({ hotfix: undefined });
  assert.equal(ok.status, 201);
  assert.equal(ok.body.job.hotfix, 0);
  f.db.close();
});

// ── 5. LIST ──────────────────────────────────────────────────────────────────

test('fix-rounds 5: the list filters, orders by id, bounds at limit and says truncated', async () => {
  const f = await fixture();
  const empty = await f.call('/api/fix-rounds?limit=1', { method: 'GET' });
  assert.equal(empty.status, 200);
  assert.deepEqual(empty.body.fix_round_jobs, []);
  assert.equal(empty.body.truncated, false);

  const i1 = f.seed({ cap_key: 'k1', box: 'box-a' });
  const i2 = f.seed({ cap_key: 'k2', box: 'box-b', status: 'claimed', claimed_by: 'box-b' });
  const i3 = f.seed({ cap_key: 'k3', box: 'box-a', project: 'other' });

  const all = await f.call('/api/fix-rounds', { method: 'GET' });
  assert.deepEqual(all.body.fix_round_jobs.map((r) => r.id), [i1, i2, i3]);
  assert.equal(all.body.truncated, false);
  assert.deepEqual(all.body.fix_round_jobs[0].args, ARGS);

  const byKey = await f.call(`/api/fix-rounds?project=${P}&cap_key=k2`, { method: 'GET' });
  assert.deepEqual(byKey.body.fix_round_jobs.map((r) => r.id), [i2]);
  const byBox = await f.call('/api/fix-rounds?box=box-a', { method: 'GET' });
  assert.deepEqual(byBox.body.fix_round_jobs.map((r) => r.id), [i1, i3]);
  const bySt = await f.call('/api/fix-rounds?status=claimed', { method: 'GET' });
  assert.deepEqual(bySt.body.fix_round_jobs.map((r) => r.id), [i2]);

  const two = await f.call('/api/fix-rounds?limit=2', { method: 'GET' });
  assert.deepEqual(two.body.fix_round_jobs.map((r) => r.id), [i1, i2]);
  assert.equal(two.body.truncated, true, 'a capped list says so');
  const three = await f.call('/api/fix-rounds?limit=3', { method: 'GET' });
  assert.equal(three.body.truncated, false);

  for (const q of ['limit=0', 'limit=501', 'limit=abc', 'limit=1.5', 'limit=', 'status=bogus']) {
    const r = await f.call(`/api/fix-rounds?${q}`, { method: 'GET' });
    assert.equal(r.status, 400, `${q} → ${r.status}`);
  }
  f.db.close();
});

// ── 6-8. CLAIM ───────────────────────────────────────────────────────────────

test('fix-rounds 6: a claim takes only rows addressed to its own box, oldest first, and stamps them', async () => {
  const f = await fixture();
  const a1 = f.seed({ cap_key: 'k1', box: 'box-a' });
  const a2 = f.seed({ cap_key: 'k2', box: 'box-a' });

  const b = await f.call('/api/fix-rounds/claim', { body: { box: 'box-b' } });
  assert.equal(b.status, 404, 'box B is never handed box A\'s row');
  assert.equal(b.body.error, 'nothing queued');
  assert.equal(f.row(a1).status, 'queued');

  const r = await f.call('/api/fix-rounds/claim', { body: { box: 'box-a' } });
  assert.equal(r.status, 200, JSON.stringify(r.body));
  assert.equal(r.body.claimed, true);
  assert.equal(r.body.job.id, a1, 'oldest first');
  assert.equal(r.body.job.status, 'claimed');
  assert.equal(r.body.job.claimed_by, 'box-a');
  assert.equal(r.body.job.attempt, 1);
  assert.ok(r.body.job.claimed_at);
  assert.deepEqual(r.body.job.args, ARGS);

  const r2 = await f.call('/api/fix-rounds/claim', { body: { box: 'box-a' } });
  assert.equal(r2.body.job.id, a2);
  const r3 = await f.call('/api/fix-rounds/claim', { body: { box: 'box-a' } });
  assert.equal(r3.status, 404, 'a fresh claim is never re-offered, even to its holder');

  for (const body of [{}, { box: '' }, { box: 'a b' }]) {
    const x = await f.call('/api/fix-rounds/claim', { body });
    assert.equal(x.status, 400);
  }
  f.db.close();
});

test('fix-rounds 6b: the claim CAS itself names the box, so a wrong candidate can never be taken', async () => {
  // Swap the row to another box between the candidate read and the CAS: the
  // CAS must refuse it, which is what makes cross-box claiming impossible.
  let raced = false;
  let db;
  const f = await fixture({
    beforeRun(sql) {
      if (raced || !/UPDATE fix_round_jobs SET status='claimed'/.test(sql)) return;
      raced = true;
      db.prepare("UPDATE fix_round_jobs SET box='box-z'").run();
    },
  });
  db = f.db;
  const id = f.seed();
  const r = await f.call('/api/fix-rounds/claim', { body: { box: 'box-a' } });
  assert.ok(raced);
  assert.equal(r.status, 409, JSON.stringify(r.body));
  assert.equal(f.row(id).status, 'queued', 'box-z\'s row was not taken by box-a');
  f.db.close();
});

test('fix-rounds 7: a claim race has exactly one winner per row, and the loser walks on', async () => {
  // one row: the racer takes it → 409
  {
    let raced = false;
    let db;
    const f = await fixture({
      beforeRun(sql) {
        if (raced || !/UPDATE fix_round_jobs SET status='claimed'/.test(sql)) return;
        raced = true;
        db.prepare("UPDATE fix_round_jobs SET status='claimed', claimed_by='box-a-2', attempt=attempt+1 WHERE status='queued'").run();
      },
    });
    db = f.db;
    const id = f.seed();
    const r = await f.call('/api/fix-rounds/claim', { body: { box: 'box-a' } });
    assert.ok(raced);
    assert.equal(r.status, 409, JSON.stringify(r.body));
    assert.equal(r.body.refused, true);
    assert.equal(r.body.scope, 'fix-rounds');
    assert.equal(f.row(id).claimed_by, 'box-a-2', 'the racer keeps the row');
    assert.equal(f.row(id).attempt, 1, 'claimed once, not twice');
    f.db.close();
  }
  // two rows: the racer takes the first, the route walks to the second
  {
    let raced = false;
    let db;
    const f = await fixture({
      beforeRun(sql) {
        if (raced || !/UPDATE fix_round_jobs SET status='claimed'/.test(sql)) return;
        raced = true;
        db.prepare("UPDATE fix_round_jobs SET status='claimed', claimed_by='racer', attempt=attempt+1 WHERE id=(SELECT MIN(id) FROM fix_round_jobs)").run();
      },
    });
    db = f.db;
    const i1 = f.seed({ cap_key: 'k1' });
    const i2 = f.seed({ cap_key: 'k2' });
    const r = await f.call('/api/fix-rounds/claim', { body: { box: 'box-a' } });
    assert.equal(r.status, 200, JSON.stringify(r.body));
    assert.equal(r.body.job.id, i2);
    assert.equal(f.row(i1).claimed_by, 'racer');
    assert.equal(f.row(i1).attempt, 1);
    assert.equal(f.row(i2).claimed_by, 'box-a');
    assert.equal(f.row(i2).attempt, 1);
    f.db.close();
  }
});

test('fix-rounds 8: a stale claim is re-offered only past the server-clock cutoff; junk stale_min never is', async () => {
  const f = await fixture();
  // claimed_by is always the row's own box: claim's CAS is WHERE ... box=?2.
  const id = f.seed({ status: 'claimed', claimed_by: 'box-a', box: 'box-a', attempt: 1,
    claimed_at: ago(30), updated_at: ago(30) });
  for (const stale_min of ['junk', -5, 0, 60, null, true, '']) {
    const r = await f.call('/api/fix-rounds/claim', { body: { box: 'box-a', stale_min } });
    assert.equal(r.status, 404, `stale_min=${JSON.stringify(stale_min)} → ${r.status}`);
    assert.equal(f.row(id).claimed_by, 'box-a');
    assert.equal(f.row(id).attempt, 1);
  }
  const r = await f.call('/api/fix-rounds/claim', { body: { box: 'box-a', stale_min: 10 } });
  assert.equal(r.status, 200, JSON.stringify(r.body));
  assert.equal(r.body.job.id, id);
  assert.equal(r.body.job.claimed_by, 'box-a');
  assert.equal(r.body.job.attempt, 2);

  // the claim records the box, not an attempt id: a late finish from the same
  // box's older session lands on the re-claimed round
  const late = await f.call('/api/fix-rounds/finish', { body: { id, box: 'box-a', result: 'done' } });
  assert.equal(late.status, 200, JSON.stringify(late.body));
  assert.equal(f.row(id).status, 'done');
  assert.equal(f.row(id).claimed_by, 'box-a');
  assert.equal(f.row(id).attempt, 2);
  f.db.close();
});

// ── 9. FINISH ────────────────────────────────────────────────────────────────

test('fix-rounds 9: finish is a CAS on the claimant, validates result before writing, and never truncates', async () => {
  const f = await fixture();
  const id = f.seed({ status: 'claimed', claimed_by: 'box-a', attempt: 1 });
  const q = f.seed({ cap_key: 'k-queued' });

  const wrong = await f.call('/api/fix-rounds/finish', { body: { id, box: 'box-b', result: 'done' } });
  assert.equal(wrong.status, 409, JSON.stringify(wrong.body));
  assert.equal(wrong.body.refused, true);
  assert.equal(wrong.body.job.claimed_by, 'box-a');
  assert.equal(f.row(id).status, 'claimed', 'a wrong-box finish never lands');

  const queued = await f.call('/api/fix-rounds/finish', { body: { id: q, box: 'box-a', result: 'done' } });
  assert.equal(queued.status, 409);
  assert.equal(f.row(q).status, 'queued');

  for (const result of ['setup-blocked', 'box-paused ', 'done ', 'done\nterminal', 'DONE', 'rebuild', 'bogus', 7, undefined]) {
    const r = await f.call('/api/fix-rounds/finish', { body: { id, box: 'box-a', result } });
    assert.equal(r.status, 400, `result=${JSON.stringify(result)} → ${r.status}`);
  }
  for (const bid of ['1', 0, -1, 1.5, undefined]) {
    const r = await f.call('/api/fix-rounds/finish', { body: { id: bid, box: 'box-a', result: 'done' } });
    assert.equal(r.status, 400, `id=${JSON.stringify(bid)}`);
  }
  const noBox = await f.call('/api/fix-rounds/finish', { body: { id, result: 'done' } });
  assert.equal(noBox.status, 400);
  const nonStr = await f.call('/api/fix-rounds/finish', { body: { id, box: 'box-a', result: 'done', record_out: {} } });
  assert.equal(nonStr.status, 400);
  const big = await f.call('/api/fix-rounds/finish', {
    body: { id, box: 'box-a', result: 'done', record_out: 'x'.repeat(256 * 1024 + 1) } });
  assert.equal(big.status, 413);
  assert.equal(f.row(id).status, 'claimed', 'every refusal above left the row untouched');
  assert.equal(f.row(id).record_out, null);

  const unknown = await f.call('/api/fix-rounds/finish', { body: { id: 9999, box: 'box-a', result: 'done' } });
  assert.equal(unknown.status, 404);

  const ok = await f.call('/api/fix-rounds/finish', {
    body: { id, box: 'box-a', result: 'setup-blocked npm-ci', record_out: '{"out":1}' } });
  assert.equal(ok.status, 200, JSON.stringify(ok.body));
  assert.equal(ok.body.job.status, 'done');
  assert.equal(ok.body.job.result, 'setup-blocked npm-ci');
  assert.equal(ok.body.job.record_out, '{"out":1}');
  assert.ok(ok.body.job.finished_at);

  const again = await f.call('/api/fix-rounds/finish', { body: { id, box: 'box-a', result: 'done' } });
  assert.equal(again.status, 409, 'a done row is not finished twice');
  f.db.close();
});

// ── 10. ADOPT ────────────────────────────────────────────────────────────────

test('fix-rounds 10: adopt is a CAS done → adopted, so only one adopter ever wins', async () => {
  const f = await fixture();
  const d = f.seed({ status: 'done', claimed_by: 'box-a' });
  const q = f.seed({ cap_key: 'k-q' });
  const c = f.seed({ cap_key: 'k-c', status: 'claimed', claimed_by: 'box-a' });

  const r = await f.call('/api/fix-rounds/adopt', { body: { id: d } });
  assert.equal(r.status, 200, JSON.stringify(r.body));
  assert.equal(r.body.job.status, 'adopted');
  assert.ok(r.body.job.adopted_at);
  const again = await f.call('/api/fix-rounds/adopt', { body: { id: d } });
  assert.equal(again.status, 409);
  assert.equal(again.body.job.status, 'adopted');

  for (const id of [q, c]) {
    const x = await f.call('/api/fix-rounds/adopt', { body: { id } });
    assert.equal(x.status, 409, `adopt of ${f.row(id).status}`);
    assert.notEqual(f.row(id).status, 'adopted');
  }
  const unknown = await f.call('/api/fix-rounds/adopt', { body: { id: 9999 } });
  assert.equal(unknown.status, 404);
  const bad = await f.call('/api/fix-rounds/adopt', { body: { id: '1' } });
  assert.equal(bad.status, 400);
  f.db.close();
});

test('fix-rounds 10b: a concurrent adopt gives exactly one 200', async () => {
  let raced = false;
  let db;
  const f = await fixture({
    beforeRun(sql) {
      if (raced || !/UPDATE fix_round_jobs SET status='adopted'/.test(sql)) return;
      raced = true;
      db.prepare("UPDATE fix_round_jobs SET status='adopted', adopted_at='2026-09-26T11:00:00Z' WHERE status='done'").run();
    },
  });
  db = f.db;
  const id = f.seed({ status: 'done' });
  const r = await f.call('/api/fix-rounds/adopt', { body: { id } });
  assert.ok(raced);
  assert.equal(r.status, 409, JSON.stringify(r.body));
  assert.equal(f.row(id).adopted_at, '2026-09-26T11:00:00Z', 'the racer\'s adopt stands');
  f.db.close();
});

// ── 11. INDEX PIN ────────────────────────────────────────────────────────────

test('fix-rounds 11: the partial unique index refuses a second open row and admits one after adopt', async () => {
  const f = await fixture();
  const id = f.seed();
  assert.throws(() => f.seed({ box: 'box-b' }), /UNIQUE constraint failed/);
  f.db.prepare("UPDATE fix_round_jobs SET status='adopted' WHERE id=?").run(id);
  assert.doesNotThrow(() => f.seed({ box: 'box-b' }));
  assert.equal(f.count(), 2);
  f.db.close();
});

// ── 12. PRODUCTION ENTRY POINT ───────────────────────────────────────────────

test('fix-rounds 12: every route is bearer-gated and reachable through worker.fetch', async () => {
  const f = await fixture();
  const routes = [
    ['POST', '/api/fix-rounds'], ['GET', '/api/fix-rounds'], ['POST', '/api/fix-rounds/claim'],
    ['POST', '/api/fix-rounds/finish'], ['POST', '/api/fix-rounds/adopt'],
  ];
  for (const [method, path] of routes) {
    const noAuth = await f.call(path, { method, body: method === 'POST' ? {} : undefined, secret: null });
    assert.equal(noAuth.status, 401, `${method} ${path} without a bearer`);
    const authed = await f.call(path, { method, body: method === 'POST' ? {} : undefined });
    assert.notEqual(authed.body && authed.body.error, 'unknown endpoint', `${method} ${path} is not wired into ROUTES`);
    assert.equal(authed.status, method === 'GET' ? 200 : 400, `${method} ${path} → ${authed.status}`);
  }
  f.db.close();
});
