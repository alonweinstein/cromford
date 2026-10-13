// A pause flag flip leaves a trace. Every value-changing PUT /api/flags for a
// `paused-*` name appends one `flag` row to config_changes (the one audit
// store, BH-2513), in the same batch as the upsert: actor, reason, the old and
// the new value. Before this, a Mission Control RESUME (setCoordFlag ->
// PUT /api/flags {name:'paused-<p>', active:0}) left no record of who resumed a
// board or why.
//
// Pinned on a REAL schema.sql database behind the node:sqlite shim, through the
// real worker.fetch:
//   F1 a create writes one row (before NULL, after {active}, actor, reason);
//   F2 a flip logs before and after; a same-value write logs nothing;
//   F3 a flag that is not `paused-*` IS audited too (BH-2377 audits every
//      changed flag; TEST-CHANGE below);
//   F4 no actor is recorded as 'api', never blank; the response shape is unchanged.
import test from 'node:test';
import assert from 'node:assert/strict';
import worker from '../src/index.js';
import { openDb } from './lib/d1-sqlite.bh-1030.js';

const SECRET = 'test-secret';
const put = (DB, body) => worker.fetch(new Request('https://jobs.test/api/flags', {
  method: 'PUT',
  headers: { 'content-type': 'application/json', authorization: `Bearer ${SECRET}` },
  body: JSON.stringify(body),
}), { DB, HARNESS_SECRET: SECRET }).then(async (res) => ({ status: res.status, body: await res.json().catch(() => null) }));

const rows = (db, name) =>
  db.prepare("SELECT * FROM config_changes WHERE kind='flag' AND name=? ORDER BY id").all(name);

async function withDb(t, fn) {
  const opened = await openDb();
  if (opened === null) { t.skip('node:sqlite unavailable in this runtime'); return; }
  await fn(opened);
}

test('F1 a paused-* create writes one flag row with actor and reason', (t) => withDb(t, async ({ db, DB }) => {
  const r = await put(DB, { name: 'paused-project-3', active: 1, actor: 'console', reason: 'release freeze' });
  assert.equal(r.status, 200, JSON.stringify(r.body));
  assert.deepEqual(Object.keys(r.body), ['flag']);
  const got = rows(db, 'paused-project-3');
  assert.equal(got.length, 1);
  assert.equal(got[0].before_json, null);
  assert.equal(got[0].after_json, '{"active":1}');
  assert.equal(got[0].actor, 'console');
  assert.equal(got[0].reason, 'release freeze');
}));

test('F2 a RESUME flip logs old and new; a same-value write logs nothing', (t) => withDb(t, async ({ db, DB }) => {
  await put(DB, { name: 'paused-project-3', active: 1, actor: 'console', reason: 'freeze' });
  await put(DB, { name: 'paused-project-3', active: 1, actor: 'poll' });
  assert.equal(rows(db, 'paused-project-3').length, 1, 'a republish of the same value is not a decision');
  const r = await put(DB, { name: 'paused-project-3', active: 0, actor: 'mission-control', reason: 'resume' });
  assert.equal(r.status, 200);
  const got = rows(db, 'paused-project-3');
  assert.equal(got.length, 2);
  assert.equal(got[1].before_json, '{"active":1}');
  assert.equal(got[1].after_json, '{"active":0}');
  assert.equal(got[1].actor, 'mission-control');
  assert.equal(got[1].reason, 'resume');
}));

// TEST-CHANGE: the operator's BH-2377 RESUME (2026-09-27 19:32Z) asks for every changed
// flag to be audited; F3 pinned the interim paused-* scope from #3078.
test('F3 a flag that is not paused-* is audited too', (t) => withDb(t, async ({ db, DB }) => {
  const r = await put(DB, { name: 'automerge-disabled', active: 1, actor: 'console' });
  assert.equal(r.status, 200);
  const got = rows(db, 'automerge-disabled');
  assert.equal(got.length, 1);
  assert.equal(got[0].before_json, null);
  assert.equal(got[0].after_json, '{"active":1}');
  assert.equal(got[0].actor, 'console');
}));

test('F4 a flip with no actor is recorded as api, never blank', (t) => withDb(t, async ({ db, DB }) => {
  await put(DB, { name: 'paused-project-4', active: 1 });
  const got = rows(db, 'paused-project-4');
  assert.equal(got.length, 1);
  assert.equal(got[0].actor, 'api');
  assert.equal(got[0].reason, null);
}));
