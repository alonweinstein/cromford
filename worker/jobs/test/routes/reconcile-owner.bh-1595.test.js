// BH-1608 (BH-1595.1): the reconcile-prs owner heartbeat routes, driven through
// the REAL worker.fetch on a real SQLite database with schema.sql applied, so
// the upsert, the server-clock age and the latch are the worker's own SQL.
import test from 'node:test';
import assert from 'node:assert/strict';
import worker from '../../src/index.js';
import { openDb } from '../lib/d1-sqlite.bh-1030.js';

const SECRET = 's';
const call = (DB, method, path, body) => worker.fetch(
  new Request(`https://jobs.test${path}`, {
    method,
    headers: { authorization: `Bearer ${SECRET}`, 'content-type': 'application/json' },
    body: body === undefined ? undefined : JSON.stringify(body),
  }),
  { DB, HARNESS_SECRET: SECRET },
).then(async (res) => ({ status: res.status, body: await res.json().catch(() => null) }));

const agoIso = (s) => new Date(Date.now() - s * 1000).toISOString().replace(/\.\d{3}Z$/, 'Z');  // determinism: ok the route's SQL ages rows against the DB's own now, so the fixture must be anchored to the real clock
const row = (db) => db.prepare("SELECT * FROM reconcile_owner_beat WHERE lane='reconcile-prs'").get();

async function fresh(t) {
  const o = await openDb();
  if (!o) t.skip('node:sqlite unavailable on this runtime');
  return o;
}

test('beat upserts box and beat_at and never clears alerted_at; a bad box is 400', async (t) => {
  const o = await fresh(t); if (!o) return;
  o.db.prepare("UPDATE reconcile_owner_beat SET alerted_at='2026-09-23T00:00:00Z'").run();
  const r = await call(o.DB, 'POST', '/api/reconcile-prs/beat', { box: 'hub-x' });
  assert.equal(r.status, 200, JSON.stringify(r));
  const got = row(o.db);
  assert.equal(got.box, 'hub-x');
  assert.match(got.beat_at, /^\d{4}-\d\d-\d\dT\d\d:\d\d:\d\dZ$/);
  assert.equal(got.alerted_at, '2026-09-23T00:00:00Z', 'a beat must not clear the latch');
  for (const box of ['', 'bad box', undefined]) {
    const bad = await call(o.DB, 'POST', '/api/reconcile-prs/beat', { box });
    assert.equal(bad.status, 400, `box=${box}`);
  }
  o.db.prepare('DELETE FROM reconcile_owner_beat').run();
  const ins = await call(o.DB, 'POST', '/api/reconcile-prs/beat', { box: 'box-a' });
  assert.equal(ins.status, 200);
  assert.equal(row(o.db).box, 'box-a', 'a missing row is inserted');
});

test('owner prefers the settings row over the registry default', async (t) => {
  const o = await fresh(t); if (!o) return;
  let r = await call(o.DB, 'GET', '/api/reconcile-prs/owner');
  assert.equal(r.status, 200, JSON.stringify(r));
  assert.equal(r.body.owner, 'hub');
  assert.equal(r.body.owner_source, 'registry');
  o.db.prepare("INSERT INTO settings (key, value, actor, updated_at) VALUES ('lane.reconcile-prs.reconcile_prs_owner', 'box-a', 't', '2026-09-23T00:00:00Z')").run();
  r = await call(o.DB, 'GET', '/api/reconcile-prs/owner');
  assert.equal(r.body.owner, 'box-a');
  assert.equal(r.body.owner_source, 'settings');
});

test('age_s is server-clock age from expected_since when nobody beat, and tick_s is 600 for */10', async (t) => {
  const o = await fresh(t); if (!o) return;
  o.db.prepare('UPDATE reconcile_owner_beat SET expected_since=?, beat_at=NULL').run(agoIso(1860));
  let r = await call(o.DB, 'GET', '/api/reconcile-prs/owner');
  assert.equal(r.body.beat.beat_at, null);
  assert.ok(Math.abs(r.body.beat.age_s - 1860) <= 5, `age_s ~1860, got ${r.body.beat.age_s}`);
  assert.equal(r.body.tick_s, 600);
  assert.equal(r.body.beat.alerted, false);
  o.db.prepare('UPDATE reconcile_owner_beat SET beat_at=?').run(agoIso(60));
  r = await call(o.DB, 'GET', '/api/reconcile-prs/owner');
  assert.ok(Math.abs(r.body.beat.age_s - 60) <= 5, 'a beat takes precedence over expected_since');
});

test('a missing row answers beat:null, not a 500', async (t) => {
  const o = await fresh(t); if (!o) return;
  o.db.prepare('DELETE FROM reconcile_owner_beat').run();
  const r = await call(o.DB, 'GET', '/api/reconcile-prs/owner');
  assert.equal(r.status, 200);
  assert.equal(r.body.beat, null);
  assert.equal(typeof r.body.as_of, 'string');
});

test('latch PATCH sets and clears alerted_at; a non-boolean is 400', async (t) => {
  const o = await fresh(t); if (!o) return;
  let r = await call(o.DB, 'PATCH', '/api/reconcile-prs/owner/alert', { alerted: true });
  assert.equal(r.status, 200, JSON.stringify(r));
  assert.ok(row(o.db).alerted_at);
  assert.equal((await call(o.DB, 'GET', '/api/reconcile-prs/owner')).body.beat.alerted, true);
  r = await call(o.DB, 'PATCH', '/api/reconcile-prs/owner/alert', { alerted: false });
  assert.equal(r.status, 200);
  assert.equal(row(o.db).alerted_at, null);
  for (const alerted of ['true', 1, undefined]) {
    const bad = await call(o.DB, 'PATCH', '/api/reconcile-prs/owner/alert', { alerted });
    assert.equal(bad.status, 400, `alerted=${alerted}`);
  }
});
