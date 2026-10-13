// BH-2376 (BH-2330.1): every value-changing PUT /api/settings appends one
// `setting` row to the generic config_changes table, in the same batch as the
// upsert, and GET /api/settings-changes is a filtered read of it. There is one
// audit store (the operator's RESUME of 2026-09-27): no settings_changes table.
//
// WHAT IS PINNED, on a REAL schema.sql database behind the node:sqlite shim and
// through the real worker.fetch:
//   S2  a create writes one row (before NULL, after the value, actor, reason); response keys unchanged;
//   S3  a same-value write logs nothing; a changed value logs before and after;
//   S4  GET /api/settings-changes: newest first, limit/truncated, bad key 400, kind `setting` only;
//   S5  every refusal returns before any row; a token never reaches after_json;
//   S5b a reason over 512 chars is a 400 and writes nothing;
//   S6  reason goes on the change row only, falls back to note; a note-only rewrite logs nothing;
//   S7  POST /api/settings/seed-registry logs no `setting` row;
//   S8  a cap write is audited only as `cost_cap`, on both routes that write one;
//   S9  a JSON number is logged as its stored string;
//   S10 no settings_changes table exists.
import test from 'node:test';
import assert from 'node:assert/strict';
import worker from '../src/index.js';
import { REGISTRY_SEED_ACTOR } from '../src/lib/core.js';
import { openDb, clearCapSeeds } from './lib/d1-sqlite.bh-1030.js';

const SECRET = 'test-secret';
const K = 'bh2376.test.knob'; // unseeded: schema.sql seeds gh.quota.reserve

const call = (DB, path, { method = 'PUT', body } = {}) => {
  const req = new Request(`https://jobs.test${path}`, {
    method,
    headers: { 'content-type': 'application/json', authorization: `Bearer ${SECRET}` },
    body: body === undefined ? undefined : JSON.stringify(body),
  });
  return worker.fetch(req, { DB, HARNESS_SECRET: SECRET }).then(async (res) => ({
    status: res.status, body: await res.json().catch(() => null),
  }));
};
const put = (DB, body) => call(DB, '/api/settings', { body });
const get = (DB, path) => call(DB, path, { method: 'GET' });

const rows = (db, name, kind = 'setting') =>
  db.prepare('SELECT * FROM config_changes WHERE kind=? AND name=? ORDER BY id').all(kind, name);
const nCfg = (db) => db.prepare('SELECT count(*) AS n FROM config_changes').get().n;

async function withDb(t, fn) {
  const opened = await openDb();
  if (opened === null) {
    t.skip('node:sqlite unavailable in this runtime');
    return;
  }
  clearCapSeeds(opened.db); // BH-4155: start from a table with no cap row
  await fn(opened);
}

test('S2 a create writes one setting row; the response is still {setting}', (t) => withDb(t, async ({ db, DB }) => {
  const r = await put(DB, { key: K, value: '700', actor: 'console', reason: 'raise' });
  assert.equal(r.status, 200, JSON.stringify(r.body));
  assert.deepEqual(Object.keys(r.body), ['setting']);
  assert.equal(r.body.setting.value, '700');
  const got = rows(db, K);
  assert.equal(got.length, 1);
  assert.equal(got[0].name, K);
  assert.equal(got[0].before_json, null);
  assert.equal(got[0].after_json, '{"value":"700"}');
  assert.equal(got[0].actor, 'console');
  assert.equal(got[0].reason, 'raise');
}));

test('S3 a same-value write logs nothing; a changed value logs before and after', (t) => withDb(t, async ({ db, DB }) => {
  assert.equal((await put(DB, { key: K, value: '700', actor: 'console' })).status, 200);
  const same = await put(DB, { key: K, value: '700', actor: 'wake' });
  assert.equal(same.status, 200);
  assert.equal(rows(db, K).length, 1, 'a republish of the same value is not a change');
  assert.equal((await put(DB, { key: K, value: '800', actor: 'operator' })).status, 200);
  const got = rows(db, K);
  assert.equal(got.length, 2);
  assert.equal(got[1].before_json, '{"value":"700"}');
  assert.equal(got[1].after_json, '{"value":"800"}');
  assert.equal(got[1].actor, 'operator');
  assert.equal(got[1].reason, null);
}));

test('S4 GET /api/settings-changes reads setting rows, newest first, with limit and truncated', (t) => withDb(t, async ({ db, DB }) => {
  await put(DB, { key: K, value: '700' });
  await put(DB, { key: K, value: '800' });
  await put(DB, { key: 'other.key', value: 'x' });
  db.prepare(
    "INSERT INTO config_changes (kind, name, before_json, after_json, actor, reason, at) VALUES ('cost_cap','conf.cost-caps.default',NULL,'{}','api',NULL,'t')",
  ).run();

  const r = await get(DB, `/api/settings-changes?key=${K}`);
  assert.equal(r.status, 200, JSON.stringify(r.body));
  assert.deepEqual(r.body.changes.map((c) => JSON.parse(c.after_json).value), ['800', '700']);
  assert.ok(r.body.changes.every((c) => c.kind === 'setting' && c.name === K));
  assert.equal(r.body.truncated, false);
  assert.ok(r.body.as_of);

  const one = await get(DB, `/api/settings-changes?key=${K}&limit=1`);
  assert.equal(one.status, 200);
  assert.equal(one.body.changes.length, 1);
  assert.equal(JSON.parse(one.body.changes[0].after_json).value, '800');
  assert.equal(one.body.truncated, true);

  const bad = await get(DB, '/api/settings-changes?key=BAD%20KEY');
  assert.equal(bad.status, 400);
  assert.match(bad.body.error, /key must match/);

  const all = await get(DB, '/api/settings-changes');
  assert.equal(all.status, 200);
  assert.equal(all.body.changes.length, 3);
  assert.ok(all.body.changes.every((c) => c.kind === 'setting'), 'a cost_cap row is not a setting change');
}));

test('S5 every refusal returns before any row, and a token never reaches after_json', (t) => withDb(t, async ({ db, DB }) => {
  const refusals = [
    { key: 'BAD KEY', value: '1' },
    { key: 'lane.doorbell-coverage-check.jobs_url', value: 'https://evil.test' },
    { key: 'account.x', value: 'sk-abc' },
    { key: K, value: '1', actor: REGISTRY_SEED_ACTOR },
  ];
  for (const body of refusals) {
    const r = await put(DB, body);
    assert.equal(r.status, 400, `${JSON.stringify(body)} → ${JSON.stringify(r.body)}`);
  }
  assert.equal(nCfg(db), 0);
  assert.equal(db.prepare("SELECT count(*) AS n FROM config_changes WHERE after_json LIKE '%sk-abc%'").get().n, 0);
}));

test('S5b a reason over 512 chars is a 400 and writes nothing', (t) => withDb(t, async ({ db, DB }) => {
  const r = await put(DB, { key: K, value: '700', reason: 'x'.repeat(513) });
  assert.equal(r.status, 400, JSON.stringify(r.body));
  assert.match(r.body.error, /reason/);
  assert.equal(nCfg(db), 0);
  assert.equal(db.prepare('SELECT count(*) AS n FROM settings WHERE key=?').get(K).n, 0);
  // 512 exactly is accepted.
  assert.equal((await put(DB, { key: K, value: '700', reason: 'y'.repeat(512) })).status, 200);
  assert.equal(rows(db, K)[0].reason.length, 512);
}));

test('S6 reason lives on the change row only and falls back to note; a note-only rewrite logs nothing', (t) => withDb(t, async ({ db, DB }) => {
  assert.equal((await put(DB, { key: K, value: '1', note: 'n1' })).status, 200);
  assert.equal(rows(db, K)[0].reason, 'n1');
  assert.equal((await put(DB, { key: K, value: '2', reason: 'r2' })).status, 200);
  const note = () => db.prepare('SELECT note FROM settings WHERE key=?').get(K).note;
  assert.equal(note(), 'n1', 'reason is never stored in settings.note');
  assert.equal(rows(db, K)[1].reason, 'r2');
  assert.equal((await put(DB, { key: K, value: '3', note: 'n3' })).status, 200);
  assert.equal(rows(db, K)[2].reason, 'n3');
  assert.equal((await put(DB, { key: K, value: '3', note: 'n4' })).status, 200);
  assert.equal(rows(db, K).length, 3, 'a note-only rewrite is not a value change');
  assert.equal(note(), 'n4');
}));

test('S7 POST /api/settings/seed-registry logs no setting row', (t) => withDb(t, async ({ db, DB }) => {
  const r = await call(DB, '/api/settings/seed-registry', { method: 'POST', body: {} });
  assert.equal(r.status, 200, JSON.stringify(r.body));
  assert.ok(r.body.changed > 0, 'the seed wrote rows, so the zero below means something');
  assert.equal(db.prepare("SELECT count(*) AS n FROM config_changes WHERE kind='setting'").get().n, 0);
}));

test('S8 a cap write is audited exactly once, as cost_cap, on both routes', (t) => withDb(t, async ({ db, DB }) => {
  const cap = 'conf.cost-caps.default';
  const a = await put(DB, { key: cap, value: '100 5', reason: 'why' });
  assert.equal(a.status, 200, JSON.stringify(a.body));
  assert.equal(rows(db, cap, 'cost_cap').length, 1);
  assert.equal(rows(db, cap).length, 0, 'no setting row for a cap key');
  assert.equal(nCfg(db), 1);
  const b = await call(DB, '/api/cost-caps', { body: { key: cap, value: '200 5', reason: 'bump' } });
  assert.equal(b.status, 200, JSON.stringify(b.body));
  assert.equal(rows(db, cap, 'cost_cap').length, 2);
  assert.equal(rows(db, cap).length, 0);
  assert.equal(nCfg(db), 2);
}));

test('S9 a JSON number is logged as its stored string', (t) => withDb(t, async ({ db, DB }) => {
  assert.equal((await put(DB, { key: K, value: 42 })).status, 200);
  assert.equal(rows(db, K)[0].after_json, '{"value":"42"}');
}));

test('S10 no settings_changes table exists', (t) => withDb(t, async ({ db, DB }) => {
  await put(DB, { key: K, value: '1' });
  assert.equal(db.prepare("SELECT count(*) AS n FROM sqlite_master WHERE name='settings_changes'").get().n, 0);
}));
