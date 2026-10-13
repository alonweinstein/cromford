import test from 'node:test';
import assert from 'node:assert/strict';
import worker from '../src/index.js';

// BH-1269: the two /api/merge-trains routes, driven through the worker's REAL
// fetch handler over a node:sqlite database.
//
// WHY A REAL DATABASE. Every claim worth making about this slice is made by
// SQL: that a second PUT keeps the members the first one sent (the lane writes
// the row three times and only the first call knows them), that created_at is
// set once so a train cannot postpone its own age, and that the listing comes
// back newest-first. A pattern-matching stub would answer `changes:1` to all of
// it and pass a worker that loses a train's members the moment it lands.

const SECRET = 'test-secret';
const ISO_RE = /^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z$/;

let DatabaseSync = null;
try { ({ DatabaseSync } = await import('node:sqlite')); } catch { DatabaseSync = null; }

function d1(db) {
  const exec = (sql, binds) => {
    const stmt = db.prepare(sql);
    if (/^\s*(SELECT|PRAGMA)\b/i.test(sql)) {
      return { results: stmt.all(...binds), meta: { changes: 0 } };
    }
    const r = stmt.run(...binds);
    return { results: [], meta: { changes: Number(r.changes) } };
  };
  const make = (sql, binds) => ({
    _sql: sql, _binds: binds,
    bind: (...b) => make(sql, b),
    run: async () => exec(sql, binds),
    first: async () => { const r = exec(sql, binds); return r.results.length ? r.results[0] : null; },
    all: async () => exec(sql, binds),
  });
  return { prepare: (sql) => make(sql, []) };
}

function fresh() {
  const db = new DatabaseSync(':memory:');
  return { db, env: { DB: d1(db), HARNESS_SECRET: SECRET } };
}

async function call(env, method, path, body, opts = {}) {
  const headers = {};
  if (opts.auth !== false) headers.authorization = 'Bearer ' + SECRET;
  const init = { method, headers };
  if (body !== undefined) {
    headers['content-type'] = 'application/json';
    init.body = JSON.stringify(body);
  }
  const res = await worker.fetch(new Request('https://jobs.test' + path, init), env);
  return { status: res.status, body: await res.json().catch(() => null) };
}

const rowOf = (db, branch) =>
  db.prepare('SELECT * FROM merge_trains WHERE branch=?1').get(branch) ?? null;

// ── 1 ───────────────────────────────────────────────────────────────────────
test('GET /api/merge-trains on an empty database answers 200 and creates the table', async (t) => {
  if (!DatabaseSync) { t.skip('node:sqlite unavailable on this runtime'); return; }
  const { db, env } = fresh();

  const r = await call(env, 'GET', '/api/merge-trains');
  assert.equal(r.status, 200);
  assert.deepEqual(r.body.merge_trains, []);
  assert.match(r.body.as_of, ISO_RE);

  const tbl = db.prepare("SELECT name FROM sqlite_master WHERE type='table' AND name='merge_trains'").get();
  assert.ok(tbl, 'ensureTable did not create merge_trains');
  db.close();
});

// ── 2 ───────────────────────────────────────────────────────────────────────
test('both routes are bearer-gated and a malformed PUT writes nothing', async (t) => {
  if (!DatabaseSync) { t.skip('node:sqlite unavailable on this runtime'); return; }
  const { db, env } = fresh();
  await call(env, 'GET', '/api/merge-trains');

  const ok = { project: 'cromford', branch: 'batch/cromford/x', outcome: 'creating' };
  assert.equal((await call(env, 'PUT', '/api/merge-trains', ok, { auth: false })).status, 401);
  assert.equal((await call(env, 'GET', '/api/merge-trains', undefined, { auth: false })).status, 401);

  // No project, no branch, and an outcome that is not one of the five.
  assert.equal((await call(env, 'PUT', '/api/merge-trains', { ...ok, project: '' })).status, 400);
  assert.equal((await call(env, 'PUT', '/api/merge-trains', { ...ok, branch: '' })).status, 400);
  assert.equal((await call(env, 'PUT', '/api/merge-trains', { ...ok, outcome: 'shipped' })).status, 400);
  // `red` was in the first draft of this set and nothing ever wrote it.
  assert.equal((await call(env, 'PUT', '/api/merge-trains', { ...ok, outcome: 'red' })).status, 400);

  assert.equal(db.prepare('SELECT COUNT(*) AS n FROM merge_trains').get().n, 0);
  db.close();
});

// ── 3 ───────────────────────────────────────────────────────────────────────
// The lane's real write sequence. Only the first call knows the members and the
// union sha; only the last knows the merge sha — and the row has to carry all
// of it at the end.
test('the three writes of one train accumulate, and created_at is set once', async (t) => {
  if (!DatabaseSync) { t.skip('node:sqlite unavailable on this runtime'); return; }
  const { db, env } = fresh();
  const branch = 'batch/cromford/20260921T120000Z-1-0';

  const a = await call(env, 'PUT', '/api/merge-trains', {
    project: 'cromford', branch, repo: 'example-org/cromford',
    outcome: 'creating', members: '101,102,103', union_sha: 'u'.repeat(40),
  });
  assert.equal(a.status, 200);
  assert.equal(a.body.train.member_count, 3, 'member_count is derived from the csv');
  const created = a.body.train.created_at;
  assert.match(created, ISO_RE);

  await call(env, 'PUT', '/api/merge-trains',
    { project: 'cromford', branch, outcome: 'open', train_pr: 900, run_id: '55' });
  const mid = rowOf(db, branch);
  assert.equal(mid.members, '101,102,103', 'the open write must not blank the members');
  assert.equal(mid.union_sha, 'u'.repeat(40), 'nor the union sha');
  assert.equal(mid.train_pr, 900);
  assert.equal(mid.run_id, '55');
  assert.equal(mid.outcome, 'open');

  await call(env, 'PUT', '/api/merge-trains',
    { project: 'cromford', branch, outcome: 'landed', merge_sha: 'm'.repeat(40) });
  const end = rowOf(db, branch);
  assert.equal(end.outcome, 'landed');
  assert.equal(end.merge_sha, 'm'.repeat(40));
  assert.equal(end.members, '101,102,103');
  assert.equal(end.run_id, '55');
  assert.equal(end.created_at, created, 'created_at must be written once, not on every upsert');
  assert.notEqual(end.updated_at, null);
  assert.equal(db.prepare('SELECT COUNT(*) AS n FROM merge_trains').get().n, 1);
  db.close();
});

// ── 4 ───────────────────────────────────────────────────────────────────────
test('the listing is newest-first, filters by project and outcome, and caps its limit', async (t) => {
  if (!DatabaseSync) { t.skip('node:sqlite unavailable on this runtime'); return; }
  const { db, env } = fresh();
  await call(env, 'GET', '/api/merge-trains');

  // created_at is the worker's own stamp and is the same second for all three,
  // so the tiebreak (branch DESC) is what the order assertion really reads —
  // which is the property that matters: two trains in one second never come
  // back in scan order.
  for (const [branch, outcome, project] of [
    ['batch/p/a', 'landed', 'cromford'],
    ['batch/p/b', 'open', 'cromford'],
    ['batch/p/c', 'abandoned', 'other-os'],
  ]) {
    assert.equal((await call(env, 'PUT', '/api/merge-trains', { project, branch, outcome })).status, 200);
  }

  const all = await call(env, 'GET', '/api/merge-trains');
  assert.deepEqual(all.body.merge_trains.map((r) => r.branch), ['batch/p/c', 'batch/p/b', 'batch/p/a']);

  const mine = await call(env, 'GET', '/api/merge-trains?project=cromford');
  assert.deepEqual(mine.body.merge_trains.map((r) => r.branch), ['batch/p/b', 'batch/p/a']);

  const open = await call(env, 'GET', '/api/merge-trains?project=cromford&outcome=open');
  assert.deepEqual(open.body.merge_trains.map((r) => r.branch), ['batch/p/b']);

  const one = await call(env, 'GET', '/api/merge-trains?limit=1');
  assert.equal(one.body.merge_trains.length, 1);
  // A junk limit falls back to the default rather than producing LIMIT NaN.
  assert.equal((await call(env, 'GET', '/api/merge-trains?limit=drop')).status, 200);
  db.close();
});

// ── 5 ───────────────────────────────────────────────────────────────────────
test('an explicit member_count wins over the csv, and detail is bounded', async (t) => {
  if (!DatabaseSync) { t.skip('node:sqlite unavailable on this runtime'); return; }
  const { db, env } = fresh();
  const branch = 'batch/p/dropped';

  // A train that dropped a member while building knows the truth before the
  // list is rewritten, so its own count wins.
  await call(env, 'PUT', '/api/merge-trains', {
    project: 'p', branch, outcome: 'abandoned', members: '1,2,3', member_count: 2,
    detail: 'x'.repeat(900),
  });
  const r = rowOf(db, branch);
  assert.equal(r.member_count, 2);
  assert.ok(r.detail.length <= 500, 'detail must be bounded, got ' + r.detail.length);
  db.close();
});

// ── 6 (BH-1270) ─────────────────────────────────────────────────────────────
test('train_group rides the row, COALESCEs like every other optional field, and reaches a database that predates it', async (t) => {
  if (!DatabaseSync) { t.skip('node:sqlite unavailable on this runtime'); return; }
  const { db, env } = fresh();

  // TWO GROUPS OF ONE TICK, and the reader can tell them apart. Without this
  // column a parallel train is indistinguishable from a serial one that
  // happened to be quick, which is the first question a red union raises.
  await call(env, 'PUT', '/api/merge-trains',
    { project: 'p', branch: 'batch/p/g0', outcome: 'creating', members: '1,2', train_group: '0' });
  await call(env, 'PUT', '/api/merge-trains',
    { project: 'p', branch: 'batch/p/g1', outcome: 'creating', members: '3', train_group: '1' });
  assert.equal(rowOf(db, 'batch/p/g0').train_group, '0');
  assert.equal(rowOf(db, 'batch/p/g1').train_group, '1');

  // The lane writes the row again at every transition and only the first call
  // knows the group, so a later PUT that omits it must not blank it.
  await call(env, 'PUT', '/api/merge-trains',
    { project: 'p', branch: 'batch/p/g1', outcome: 'landed', merge_sha: 'abc' });
  const landed = rowOf(db, 'batch/p/g1');
  assert.equal(landed.train_group, '1', 'a PUT without train_group must COALESCE, not blank it');
  assert.equal(landed.outcome, 'landed');

  // ...and it comes back out of the listing.
  const list = await call(env, 'GET', '/api/merge-trains?project=p');
  assert.deepEqual(list.body.merge_trains.map((r) => r.train_group).sort(), ['0', '1']);
  db.close();
});

// ── 7 (BH-1270) ─────────────────────────────────────────────────────────────
test('a merge_trains table created BEFORE train_group existed gains the column on the next write', async (t) => {
  if (!DatabaseSync) { t.skip('node:sqlite unavailable on this runtime'); return; }
  const { db, env } = fresh();

  // THE LIVE DATABASE'S SHAPE. merge_trains shipped with BH-1269, and
  // ensureTable's `CREATE TABLE IF NOT EXISTS` can never widen a table that
  // already exists — so without ensureColumns the very first PUT carrying a
  // group would throw "no such column" and the route would 500 while the
  // client failed open, which is indistinguishable from a fleet running no
  // trains at all. This builds the OLD table by hand and drives the route.
  db.prepare(`CREATE TABLE merge_trains (
      project TEXT NOT NULL, branch TEXT NOT NULL, repo TEXT, train_pr INTEGER,
      members TEXT, member_count INTEGER, union_sha TEXT, run_id TEXT,
      outcome TEXT NOT NULL, merge_sha TEXT, detail TEXT,
      created_at TEXT NOT NULL, updated_at TEXT NOT NULL,
      PRIMARY KEY (project, branch))`).run();
  const cols0 = db.prepare('PRAGMA table_info(merge_trains)').all().map((c) => c.name);
  assert.ok(!cols0.includes('train_group'), 'the fixture must start WITHOUT the column');

  const r = await call(env, 'PUT', '/api/merge-trains',
    { project: 'p', branch: 'batch/p/old', outcome: 'open', members: '9', train_group: '1' });
  assert.equal(r.status, 200);
  assert.equal(rowOf(db, 'batch/p/old').train_group, '1');
  db.close();
});
