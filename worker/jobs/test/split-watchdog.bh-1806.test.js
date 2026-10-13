import test from 'node:test';
import assert from 'node:assert/strict';
import worker from '../src/index.js';
import { openDb } from './lib/d1-sqlite.bh-1030.js';

// BH-1806 (BH-1793.1): the split-watchdog action ledger routes, driven through
// the worker's real fetch handler against node:sqlite running the shipped SQL.
//   POST /api/split-watchdog   record one action; repeats+1 on the same
//                              (project, child, step, reason_fp)
//   GET  /api/split-watchdog   point lookup on the full key, or the project's list
// reason_fp is computed HERE, never taken from the client: sha1 of the trimmed,
// whitespace-collapsed reason, first 12 hex.
const SECRET = 'test-secret';

const call = (o, path, { method = 'GET', body, auth = true } = {}) => {
  const headers = { 'content-type': 'application/json' };
  if (auth) headers.authorization = `Bearer ${SECRET}`;
  const req = new Request(`https://jobs.test${path}`, {
    method, headers, ...(body === undefined ? {} : { body: JSON.stringify(body) }),
  });
  return worker.fetch(req, { DB: o.DB, HARNESS_SECRET: SECRET })
    .then(async (res) => ({ status: res.status, body: await res.json().catch(() => null) }));
};

const BASE = { project: 'cromford', family: 'BH-1793', child: 'BH-1806', step: 'enqueue', reason: 'PLAN_STALE', outcome: 'acted' };
const post = (o, over = {}) => call(o, '/api/split-watchdog', { method: 'POST', body: { ...BASE, ...over } });
const count = (o) => o.db.prepare('SELECT COUNT(*) AS n FROM split_watchdog_actions').get().n;
const qs = (o) => new URLSearchParams(o).toString();

test('(c1) first POST: recorded, repeats 1, first true, 12-hex reason_fp', async (t) => {
  const o = await openDb();
  if (!o) return t.skip('node:sqlite unavailable');
  const r = await post(o);
  assert.equal(r.status, 200, JSON.stringify(r.body));
  assert.equal(r.body.recorded, true);
  assert.equal(r.body.repeats, 1);
  assert.equal(r.body.first, true);
  assert.match(r.body.reason_fp, /^[0-9a-f]{12}$/);
  const row = o.db.prepare('SELECT * FROM split_watchdog_actions').get();
  assert.equal(row.family, 'BH-1793');
  assert.equal(row.outcome, 'acted');
  assert.equal(row.reason, 'PLAN_STALE');
  assert.equal(row.first_at, row.last_at);
});

test('(c2) same key again: repeats 2, first false, outcome and last_at move, first_at does not', async (t) => {
  const o = await openDb();
  if (!o) return t.skip('node:sqlite unavailable');
  await post(o);
  o.db.exec("UPDATE split_watchdog_actions SET first_at='2026-01-01T00:00:00.000Z', last_at='2026-01-01T00:00:00.000Z'");
  const r = await post(o, { outcome: 'skipped', family: 'OTHER', reason_fp: 'ffffffffffff' });
  assert.equal(r.status, 200, JSON.stringify(r.body));
  assert.equal(r.body.repeats, 2);
  assert.equal(r.body.first, false);
  assert.equal(count(o), 1);
  const row = o.db.prepare('SELECT * FROM split_watchdog_actions').get();
  assert.equal(row.outcome, 'skipped');
  assert.equal(row.repeats, 2);
  assert.equal(row.first_at, '2026-01-01T00:00:00.000Z');
  assert.notEqual(row.last_at, '2026-01-01T00:00:00.000Z');
  assert.equal(row.family, 'BH-1793', 'family keeps its first value');
  assert.notEqual(row.reason_fp, 'ffffffffffff', 'a client reason_fp is ignored');
  const r3 = await post(o);
  assert.equal(r3.body.repeats, 3);
});

test('(c3) same key, different reason: a new row', async (t) => {
  const o = await openDb();
  if (!o) return t.skip('node:sqlite unavailable');
  await post(o);
  const r = await post(o, { reason: 'NO_PR' });
  assert.equal(r.body.first, true);
  assert.equal(r.body.repeats, 1);
  assert.equal(count(o), 2);
  const r2 = await post(o, { child: 'BH-1807' });
  assert.equal(r2.body.first, true, 'a different child with the same reason is its own row');
  assert.equal(count(o), 3);
});

test('(c4) 400 on a missing project/family/child/step or a malformed step; nothing written', async (t) => {
  const o = await openDb();
  if (!o) return t.skip('node:sqlite unavailable');
  for (const f of ['project', 'family', 'child', 'step']) {
    const body = { ...BASE };
    delete body[f];
    const r = await call(o, '/api/split-watchdog', { method: 'POST', body });
    assert.equal(r.status, 400, `missing ${f}`);
    assert.match(r.body.error, new RegExp(f));
    const e = await call(o, '/api/split-watchdog', { method: 'POST', body: { ...BASE, [f]: '' } });
    assert.equal(e.status, 400, `empty ${f}`);
  }
  const s = await post(o, { step: 'Enqueue!' });
  assert.equal(s.status, 400);
  assert.equal(count(o), 0);
});

test('(c5) a DB with no table: POST self-creates it through ensureTable', async (t) => {
  const { DatabaseSync } = await import('node:sqlite').catch(() => ({}));
  if (!DatabaseSync) return t.skip('node:sqlite unavailable');
  const { d1 } = await import('./lib/d1-sqlite.bh-1030.js');
  const db = new DatabaseSync(':memory:');
  const o = { db, DB: d1(db) };
  const r = await post(o);
  assert.equal(r.status, 200, JSON.stringify(r.body));
  assert.equal(r.body.first, true);
  assert.equal(count(o), 1);
});

test('(c6) GET point lookup by reason_fp or by reason; an unknown key is 200 + null', async (t) => {
  const o = await openDb();
  if (!o) return t.skip('node:sqlite unavailable');
  const fp = (await post(o)).body.reason_fp;
  const key = { project: 'cromford', child: 'BH-1806', step: 'enqueue' };
  const a = await call(o, `/api/split-watchdog?${qs({ ...key, reason_fp: fp })}`);
  assert.equal(a.status, 200);
  assert.equal(a.body.split_watchdog_action.outcome, 'acted');
  assert.equal(a.body.split_watchdog_action.reason_fp, fp);
  const b = await call(o, `/api/split-watchdog?${qs({ ...key, reason: '  PLAN_STALE ' })}`);
  assert.equal(b.status, 200);
  assert.deepEqual(b.body.split_watchdog_action, a.body.split_watchdog_action);
  const c = await call(o, `/api/split-watchdog?${qs({ ...key, reason: 'NEVER' })}`);
  assert.equal(c.status, 200);
  assert.ok('split_watchdog_action' in c.body);
  assert.equal(c.body.split_watchdog_action, null);
  // An empty reason is a real key too.
  await post(o, { reason: '' });
  const d = await call(o, `/api/split-watchdog?${qs({ ...key, reason: '' })}`);
  assert.equal(d.body.split_watchdog_action.outcome, 'acted');
});

test('(c6b) write and lookup share one key: a 600-char reason is found by the same text; bad key parts are 400 on both verbs', async (t) => {
  const o = await openDb();
  if (!o) return t.skip('node:sqlite unavailable');
  const key = { project: 'cromford', child: 'BH-1806', step: 'enqueue' };
  const long = 'x'.repeat(600);
  const w = await post(o, { reason: long });
  assert.equal(w.status, 200);
  const r = await call(o, `/api/split-watchdog?${qs({ ...key, reason: long })}`);
  assert.equal(r.status, 200);
  assert.notEqual(r.body.split_watchdog_action, null);
  assert.equal(r.body.split_watchdog_action.reason_fp, w.body.reason_fp);
  assert.equal(r.body.split_watchdog_action.reason.length, 500);
  // Two long reasons that share the stored 500-char prefix are two actions.
  const other = await post(o, { reason: long + 'y' });
  assert.equal(other.body.first, true);
  assert.notEqual(other.body.reason_fp, w.body.reason_fp);
  // An over-long child is refused on both sides, never truncated on one.
  const bigChild = 'c'.repeat(200);
  const before = count(o);
  assert.equal((await post(o, { child: bigChild })).status, 400);
  assert.equal(count(o), before);
  assert.equal((await call(o, `/api/split-watchdog?${qs({ ...key, child: bigChild, reason: 'PLAN_STALE' })}`)).status, 400);
  // A malformed step or reason_fp on the lookup is a 400, not a lookup of another key.
  assert.equal((await call(o, `/api/split-watchdog?${qs({ ...key, step: 'Bad Step', reason: 'PLAN_STALE' })}`)).status, 400);
  assert.equal((await call(o, `/api/split-watchdog?${qs({ ...key, reason_fp: 'nothex' })}`)).status, 400);
  assert.equal((await call(o, `/api/split-watchdog?${qs({ ...key, child: '', reason: 'PLAN_STALE' })}`)).status, 400);
});

test('(c7) GET list: newest first, family/since/outcome filters, limit + truncated, 400s', async (t) => {
  const o = await openDb();
  if (!o) return t.skip('node:sqlite unavailable');
  await post(o, { child: 'A', family: 'F1' });
  await post(o, { child: 'B', family: 'F1', outcome: 'skipped' });
  await post(o, { child: 'C', family: 'F2' });
  await post(o, { project: 'elsewhere', child: 'Z' });
  const set = o.db.prepare('UPDATE split_watchdog_actions SET last_at=? WHERE child=?');
  set.run('2026-09-26T10:00:00.000Z', 'A');
  set.run('2026-09-28T10:00:00.000Z', 'B');
  set.run('2026-09-27T10:00:00.000Z', 'C');
  const all = await call(o, '/api/split-watchdog?project=cromford');
  assert.equal(all.status, 200);
  assert.deepEqual(all.body.rows.map((r) => r.child), ['B', 'C', 'A']);
  assert.equal(all.body.truncated, false);
  assert.equal(all.body.project, 'cromford');
  const fam = await call(o, '/api/split-watchdog?project=cromford&family=F1');
  assert.deepEqual(fam.body.rows.map((r) => r.child), ['B', 'A']);
  const since = await call(o, '/api/split-watchdog?project=cromford&since=2026-09-27');
  assert.deepEqual(since.body.rows.map((r) => r.child), ['B', 'C']);
  const acted = await call(o, '/api/split-watchdog?project=cromford&outcome=acted');
  assert.deepEqual(acted.body.rows.map((r) => r.child), ['C', 'A']);
  const two = await call(o, '/api/split-watchdog?project=cromford&limit=2');
  assert.equal(two.body.rows.length, 2);
  assert.equal(two.body.truncated, true);
  const three = await call(o, '/api/split-watchdog?project=cromford&limit=3');
  assert.equal(three.body.truncated, false);
  assert.equal((await call(o, '/api/split-watchdog?project=cromford&limit=abc')).status, 400);
  assert.equal((await call(o, '/api/split-watchdog?project=cromford&limit=0')).status, 400);
  assert.equal((await call(o, '/api/split-watchdog')).status, 400);
  // limit above 500 is clamped, not refused: 501 rows answer 500 + truncated.
  const ins = o.db.prepare("INSERT INTO split_watchdog_actions (project,family,child,step,reason_fp,repeats,first_at,last_at) VALUES ('big','F','c'||?,'enqueue','000000000000',1,'2026-09-28T00:00:00Z','2026-09-28T00:00:00Z')");
  for (let i = 0; i < 501; i++) ins.run(i);
  const big = await call(o, '/api/split-watchdog?project=big&limit=9999');
  assert.equal(big.status, 200);
  assert.equal(big.body.rows.length, 500);
  assert.equal(big.body.truncated, true);
});

test('(c8) fp normalization: whitespace collapses, case does not', async (t) => {
  const o = await openDb();
  if (!o) return t.skip('node:sqlite unavailable');
  const a = await post(o, { reason: 'a  b' });
  const b = await post(o, { reason: ' a b ' });
  assert.equal(a.body.reason_fp, b.body.reason_fp);
  assert.equal(b.body.repeats, 2);
  const u = await post(o, { reason: 'PLAN_STALE' });
  const l = await post(o, { reason: 'plan_stale' });
  assert.notEqual(u.body.reason_fp, l.body.reason_fp);
  assert.equal(l.body.first, true);
  assert.equal(count(o), 3);
});

test('(c9) no bearer: 401 on both verbs', async (t) => {
  const o = await openDb();
  if (!o) return t.skip('node:sqlite unavailable');
  assert.equal((await call(o, '/api/split-watchdog', { method: 'POST', body: BASE, auth: false })).status, 401);
  assert.equal((await call(o, '/api/split-watchdog?project=cromford', { auth: false })).status, 401);
});
