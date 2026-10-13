// BH-2996 (BH-2992.2, item 1, worker side): two hub writes keep their reason in
// config_changes — PUT /api/telegram-topics (kind telegram_topic) and the
// console seed apply POST /api/settings/seed-registry/apply (kind
// registry_seed, in the same batch as its `applied` update).
//
// WHAT IS PINNED, on a REAL schema.sql database behind the node:sqlite shim and
// through the real worker.fetch:
//   H1  a topics PUT with a reason gives one telegram_topic row, name = project;
//   H2  the same thread_id again adds no row;
//   H3  a PUT without actor or reason is a 200 stored as actor 'api', reason NULL;
//   H4  a changed thread_id adds a row whose before is {"thread_id":<old>};
//   H5  a seed apply gives exactly one registry_seed row, name = plan_fp,
//       after = {plan_fp, run_id}, with the caller's actor and reason;
//   H6  a refused apply (409 plan_moved) writes no config_changes row.
import test from 'node:test';
import assert from 'node:assert/strict';
import worker from '../src/index.js';
import { openDb } from './lib/d1-sqlite.bh-1030.js';

const SECRET = 'test-secret';

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

const rows = (db, kind) => db.prepare('SELECT * FROM config_changes WHERE kind=? ORDER BY id').all(kind);
const total = (db) => db.prepare('SELECT count(*) AS n FROM config_changes').get().n;

async function withDb(t, fn) {
  const opened = await openDb();
  if (opened === null) {
    t.skip('node:sqlite unavailable in this runtime');
    return;
  }
  await fn(opened);
}

const TOPICS = '/api/telegram-topics';

test('H1 a topics PUT with a reason writes one telegram_topic row', (t) => withDb(t, async ({ db, DB }) => {
  const r = await call(DB, TOPICS, { body: { project: 'project-5', thread_id: 42, actor: 'operator', reason: 'new topic' } });
  assert.equal(r.status, 200, JSON.stringify(r.body));
  assert.deepEqual(r.body, { topic: { project: 'project-5', thread_id: 42 } });
  const c = rows(db, 'telegram_topic');
  assert.equal(c.length, 1);
  assert.equal(c[0].name, 'project-5');
  assert.equal(c[0].before_json, null);
  assert.equal(c[0].after_json, '{"thread_id":42}');
  assert.equal(c[0].actor, 'operator');
  assert.equal(c[0].reason, 'new topic');
  assert.equal(total(db), 1);
}));

test('H2 the same thread_id again adds no row', (t) => withDb(t, async ({ db, DB }) => {
  assert.equal((await call(DB, TOPICS, { body: { project: 'project-5', thread_id: 42, reason: 'a' } })).status, 200);
  const again = await call(DB, TOPICS, { body: { project: 'project-5', thread_id: 42, actor: 'x', reason: 'b' } });
  assert.equal(again.status, 200);
  assert.equal(rows(db, 'telegram_topic').length, 1);
}));

test('H3 a PUT without actor or reason succeeds and stores api / NULL', (t) => withDb(t, async ({ db, DB }) => {
  const r = await call(DB, TOPICS, { body: { project: 'project-3', thread_id: 7 } });
  assert.equal(r.status, 200);
  const c = rows(db, 'telegram_topic');
  assert.equal(c.length, 1);
  assert.equal(c[0].actor, 'api');
  assert.equal(c[0].reason, null);
}));

test('H4 a changed thread_id adds a second row with the old thread as before', (t) => withDb(t, async ({ db, DB }) => {
  assert.equal((await call(DB, TOPICS, { body: { project: 'project-5', thread_id: 42 } })).status, 200);
  const moved = await call(DB, TOPICS, { body: { project: 'project-5', thread_id: 99, actor: 'operator', reason: 'moved' } });
  assert.equal(moved.status, 200);
  const c = rows(db, 'telegram_topic');
  assert.equal(c.length, 2);
  assert.equal(c[1].before_json, '{"thread_id":42}');
  assert.equal(c[1].before_json, c[0].after_json);
  assert.equal(c[1].after_json, '{"thread_id":99}');
  assert.equal(c[1].reason, 'moved');
}));

// ── the seed apply ─────────────────────────────────────────────────────────
// The registry-seed-apply.bh-2521 freshFleet shape: two boxes that ticked a
// lane recently and reported a harness commit recently, so the gate passes.
const ANCHOR = Date.now();  // determinism: ok the single anchor; every fixture below is ago(s) off it
const ago = (s) => new Date(ANCHOR - s * 1000).toISOString().replace(/\.\d{3}Z$/, 'Z');
function freshFleet(db) {
  for (const [box, age] of [['box-hub', 120], ['box-project-4-1', 300]]) {
    db.prepare(`INSERT INTO lane_ticks (lane, project, box, last_tick_at, last_outcome, updated_at)
                VALUES ('review-prs','-',?,?,'ran',?)`).run(box, ago(60), ago(60));
    db.prepare('INSERT INTO box_status (box, harness_commit, harness_reported_at, updated_at) VALUES (?,?,?,?)')
      .run(box, 'abc123', ago(age), ago(0));
  }
}
const APPLY = '/api/settings/seed-registry/apply';

test('H5 a seed apply writes one registry_seed row with the reason', (t) => withDb(t, async ({ db, DB }) => {
  freshFleet(db);
  const plan = await call(DB, '/api/settings/seed-registry/plan', { method: 'GET' });
  assert.equal(plan.status, 200);
  const fp = plan.body.plan_fp;
  assert.match(String(fp), /^[0-9a-f]{64}$/);
  const r = await call(DB, APPLY, { method: 'POST', body: { plan_fp: fp, actor: 'operator', reason: 'r1' } });
  assert.equal(r.status, 200, JSON.stringify(r.body));
  const c = rows(db, 'registry_seed');
  assert.equal(c.length, 1);
  assert.equal(c[0].name, fp);
  assert.equal(c[0].before_json, null);
  assert.deepEqual(JSON.parse(c[0].after_json), { plan_fp: fp, run_id: r.body.id });
  assert.equal(c[0].actor, 'operator');
  assert.equal(c[0].reason, 'r1');
  assert.equal(total(db), 1, 'the seed itself writes no other audit row');
  const run = db.prepare('SELECT status FROM registry_seed_runs WHERE id=?').get(r.body.id);
  assert.equal(run.status, 'applied');
}));

test('H6 a refused apply (409 plan_moved) writes no config_changes row', (t) => withDb(t, async ({ db, DB }) => {
  freshFleet(db);
  const r = await call(DB, APPLY, { method: 'POST', body: { plan_fp: '0'.repeat(64), actor: 'operator', reason: 'r1' } });
  assert.equal(r.status, 409);
  assert.equal(r.body.error, 'plan_moved');
  assert.equal(total(db), 0);
}));
