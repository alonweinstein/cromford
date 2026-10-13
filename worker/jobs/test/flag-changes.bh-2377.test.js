// BH-2377 (BH-2330.2): every pause-flag write the console makes leaves a
// `flag` row in config_changes, the one audit store (the operator's RESUME of
// 2026-09-27: no flag_changes table), and GET /api/flag-changes reads them.
//
// WHAT IS PINNED, through the REAL worker.fetch on a schema.sql database
// behind the node:sqlite shim:
//   F1  PUT /api/flags on a new flag writes one row NULL -> {"active":1};
//       the response body is unchanged ({flag} only);
//   F2  the same active with a new reason writes nothing; a flip writes one;
//       the 400s (bad name, no active) write nothing;
//   F3  all-off then all-on write one 'all-off' row each; all-on with no row
//       is NULL -> {"active":0}; the 400s write nothing and touch no flag row;
//       a repeated all-off writes nothing; the response keys are unchanged;
//   F4  GET /api/flag-changes filters by name, carries only flag rows,
//       measures truncated; a bad or empty name is a 400;
//   N1  no flag_changes or settings_changes table exists afterwards.
import test from 'node:test';
import assert from 'node:assert/strict';
import worker from '../src/index.js';
import { openDb } from './lib/d1-sqlite.bh-1030.js';

const SECRET = 'test-secret';

async function withDb(t, fn) {
  const opened = await openDb();
  if (opened === null) {
    t.skip('node:sqlite unavailable in this runtime');
    return;
  }
  await fn(opened);
}

const call = (DB, method, path, body) => worker.fetch(
  new Request(`https://jobs.test${path}`, {
    method,
    headers: { authorization: `Bearer ${SECRET}`, 'content-type': 'application/json' },
    body: body === undefined ? undefined : JSON.stringify(body),
  }),
  { DB, HARNESS_SECRET: SECRET },
).then(async (res) => ({ status: res.status, body: await res.json().catch(() => null) }));

const rows = (db) => db.prepare(
  'SELECT kind, name, before_json, after_json, actor, reason FROM config_changes ORDER BY id',
).all().map((r) => ({ ...r }));

const flagRow = (db, name) => db.prepare('SELECT * FROM pause_flags WHERE name=?').get(name);

test('F1 PUT /api/flags on a new flag writes one flag row, response unchanged', (t) => withDb(t, async ({ db, DB }) => {
  const res = await call(DB, 'PUT', '/api/flags', { name: 'lane-off-x', active: 1, actor: 'console', reason: 'r' });
  assert.equal(res.status, 200);
  assert.deepEqual(rows(db), [
    { kind: 'flag', name: 'lane-off-x', before_json: null, after_json: '{"active":1}', actor: 'console', reason: 'r' },
  ]);
  // F1d
  assert.deepEqual(Object.keys(res.body), ['flag']);
  const { updated_at, ...rest } = res.body.flag;
  assert.equal(typeof updated_at, 'string');
  // TEST-CHANGE BH-5635: the row gains the nullable `value` column (NULL when absent).
  assert.deepEqual(rest, { name: 'lane-off-x', active: 1, actor: 'console', reason: 'r', value: null });
}));

test('F2 same active + new reason writes nothing; a flip writes one; 400s write nothing', (t) => withDb(t, async ({ db, DB }) => {
  await call(DB, 'PUT', '/api/flags', { name: 'lane-off-x', active: 1, actor: 'console', reason: 'r' });
  const again = await call(DB, 'PUT', '/api/flags', { name: 'lane-off-x', active: true, actor: 'console', reason: 'r2' });
  assert.equal(again.status, 200);
  assert.equal(again.body.flag.reason, 'r2');
  assert.equal(rows(db).length, 1);

  const off = await call(DB, 'PUT', '/api/flags', { name: 'lane-off-x', active: 0, actor: 'operator', reason: 'back' });
  assert.equal(off.status, 200);
  const all = rows(db);
  assert.equal(all.length, 2);
  assert.deepEqual(all[1], { kind: 'flag', name: 'lane-off-x', before_json: '{"active":1}', after_json: '{"active":0}', actor: 'operator', reason: 'back' });

  // F2c
  const bad = await call(DB, 'PUT', '/api/flags', { name: '../x', active: 1 });
  assert.equal(bad.status, 400);
  const noActive = await call(DB, 'PUT', '/api/flags', { name: 'lane-off-y' });
  assert.equal(noActive.status, 400);
  assert.equal(rows(db).length, 2);
  assert.equal(flagRow(db, 'lane-off-y'), undefined);
}));

test('F3 all-off then all-on each write one all-off row; repeats write nothing', (t) => withDb(t, async ({ db, DB }) => {
  const off = await call(DB, 'POST', '/api/lanes/all-off', { actor: 'operator', reason: 'stop' });
  assert.equal(off.status, 200);
  assert.equal(off.body.all_off, true);
  // F3d
  assert.deepEqual(Object.keys(off.body).sort(), ['all_off', 'as_of', 'flag']);

  // F3e
  const offAgain = await call(DB, 'POST', '/api/lanes/all-off', { actor: 'operator', reason: 'still stopped' });
  assert.equal(offAgain.status, 200);
  assert.equal(rows(db).length, 1);

  const on = await call(DB, 'POST', '/api/lanes/all-on', { actor: 'operator', reason: 'go' });
  assert.equal(on.status, 200);
  assert.equal(on.body.all_off, false);
  assert.deepEqual(Object.keys(on.body).sort(), ['all_off', 'as_of', 'flag']);
  assert.deepEqual(rows(db), [
    { kind: 'flag', name: 'all-off', before_json: null, after_json: '{"active":1}', actor: 'operator', reason: 'stop' },
    { kind: 'flag', name: 'all-off', before_json: '{"active":1}', after_json: '{"active":0}', actor: 'operator', reason: 'go' },
  ]);

  const onAgain = await call(DB, 'POST', '/api/lanes/all-on', { actor: 'operator', reason: 'go again' });
  assert.equal(onAgain.status, 200);
  assert.equal(rows(db).length, 2);
}));

test('F3b all-on on a fresh DB is a create: NULL -> {"active":0}', (t) => withDb(t, async ({ db, DB }) => {
  const on = await call(DB, 'POST', '/api/lanes/all-on', { actor: 'operator', reason: 'go' });
  assert.equal(on.status, 200);
  assert.deepEqual(rows(db), [
    { kind: 'flag', name: 'all-off', before_json: null, after_json: '{"active":0}', actor: 'operator', reason: 'go' },
  ]);
}));

test('F3c all-off without a reason or an actor is a 400 and writes nothing', (t) => withDb(t, async ({ db, DB }) => {
  const noReason = await call(DB, 'POST', '/api/lanes/all-off', { actor: 'operator' });
  assert.equal(noReason.status, 400);
  const noActor = await call(DB, 'POST', '/api/lanes/all-off', { reason: 'stop' });
  assert.equal(noActor.status, 400);
  assert.equal(rows(db).length, 0);
  assert.equal(flagRow(db, 'all-off'), undefined);
}));

test('F4 GET /api/flag-changes filters by name, carries only flag rows, measures truncated', (t) => withDb(t, async ({ db, DB }) => {
  await call(DB, 'PUT', '/api/flags', { name: 'lane-off-x', active: 1, actor: 'console', reason: 'r' });
  await call(DB, 'POST', '/api/lanes/all-off', { actor: 'operator', reason: 'stop' });
  await call(DB, 'POST', '/api/lanes/all-on', { actor: 'operator', reason: 'go' });
  db.prepare(
    "INSERT INTO config_changes (kind, name, before_json, after_json, actor, reason, at) VALUES ('setting','all-off',NULL,'{}','api',NULL,'2026-09-27T20:00:00Z')",
  ).run();

  const byName = await call(DB, 'GET', '/api/flag-changes?name=all-off');
  assert.equal(byName.status, 200);
  assert.deepEqual(byName.body.changes.map((r) => [r.kind, r.name, r.after_json]), [
    ['flag', 'all-off', '{"active":0}'],
    ['flag', 'all-off', '{"active":1}'],
  ]);
  assert.equal(byName.body.truncated, false);
  assert.equal(typeof byName.body.as_of, 'string');

  const every = await call(DB, 'GET', '/api/flag-changes');
  assert.equal(every.status, 200);
  assert.equal(every.body.changes.length, 3);
  assert.ok(every.body.changes.every((r) => r.kind === 'flag'));

  const one = await call(DB, 'GET', '/api/flag-changes?limit=1');
  assert.equal(one.status, 200);
  assert.equal(one.body.changes.length, 1);
  assert.equal(one.body.truncated, true);
}));

test('F4b a bad or empty name is a 400, never an unfiltered read', (t) => withDb(t, async ({ db, DB }) => {
  await call(DB, 'PUT', '/api/flags', { name: 'lane-off-x', active: 1, actor: 'console', reason: 'r' });
  for (const q of ['name=../x', 'name=', 'name=a%20b']) {
    const res = await call(DB, 'GET', `/api/flag-changes?${q}`);
    assert.equal(res.status, 400, q);
    assert.equal(res.body.changes, undefined, q);
  }
}));

test('N1 no flag_changes or settings_changes table exists after the writes', (t) => withDb(t, async ({ db, DB }) => {
  await call(DB, 'PUT', '/api/flags', { name: 'lane-off-x', active: 1, actor: 'console', reason: 'r' });
  await call(DB, 'POST', '/api/lanes/all-off', { actor: 'operator', reason: 'stop' });
  await call(DB, 'GET', '/api/flag-changes');
  const found = db.prepare(
    "SELECT name FROM sqlite_master WHERE name IN ('flag_changes','settings_changes')",
  ).all();
  assert.deepEqual(found, []);
}));
