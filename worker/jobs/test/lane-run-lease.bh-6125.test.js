// BH-6125 (BH-6047 part 2 of 5): the lease heartbeat and the death count of the
// lane_runs queue. Driven through the REAL router (worker.fetch) over a real
// schema.sql database on the node:sqlite shim, as lane-runs.bh-6124.test.js.
// A lease expires by back-dating lease_until to a fixed past instant, never by
// waiting on the clock. The shell side is tests/lane-run-lease.bh-6125-test.sh.
import test from 'node:test';
import assert from 'node:assert/strict';
import worker from '../src/index.js';
import { sweepDead } from '../src/routes/lane-runs-lease.js';
import { openDb } from './lib/d1-sqlite.bh-1030.js';

const SECRET = 'fixture-harness-secret';
const PAST = '2000-01-01T00:00:00Z';
const NOW = '2026-10-12T12:00:00Z';

const call = (DB, method, path, body) => {
  const headers = { 'content-type': 'application/json', authorization: `Bearer ${SECRET}` };
  const req = new Request(`https://jobs.test${path}`, {
    method, headers, body: body === undefined ? undefined : JSON.stringify(body),
  });
  return worker.fetch(req, { DB, HARNESS_SECRET: SECRET })
    .then(async (res) => ({ status: res.status, body: await res.json().catch(() => null) }));
};
const enqueue = (DB, lane, project) => call(DB, 'POST', '/api/lane-runs', { lane, project, args: ['bin/x.sh'] });
const claim = (DB, machine) => call(DB, 'POST', '/api/lane-runs/claim', { machine });
const beat = (DB, id, body) => call(DB, 'POST', `/api/lane-runs/${id}/heartbeat`, body);
const report = (DB, id, body) => call(DB, 'POST', `/api/lane-runs/${id}/report`, body);
const row = (db, id) => db.prepare('SELECT * FROM lane_runs WHERE id = ?').get(id);
const expire = (db, id) => db.prepare('UPDATE lane_runs SET lease_until = ? WHERE id = ?').run(PAST, id);
const setSetting = (db, key, value) => db.prepare(
  "INSERT INTO settings (key,value,note,actor,updated_at) VALUES (?,?,'fixture','fixture',?) ON CONFLICT(key) DO UPDATE SET value=excluded.value"
).run(key, value, NOW);

test('BH-6125 lane_runs lease heartbeat and death count', async (t) => {
  const probe = await openDb();
  if (probe === null) { t.skip('node:sqlite unavailable in this runtime'); return; }
  const fresh = async () => openDb();

  await t.test('S1 schema.sql seeds lane_run.heartbeat_s=30 and lane_run.max_attempts=3', async () => {
    const { db } = await fresh();
    const val = (k) => (db.prepare('SELECT value FROM settings WHERE key = ?').get(k) || {}).value;
    assert.equal(val('lane_run.heartbeat_s'), '30');
    assert.equal(val('lane_run.max_attempts'), '3');
  });

  await t.test('W1 the claimer beats: 200, lease_until moves past the claim lease, heartbeat_at set', async () => {
    const { db, DB } = await fresh();
    const a = await enqueue(DB, 'demo', 'p1');
    const c = await claim(DB, 'm1');
    assert.equal(c.status, 200);
    // Pin the claim's lease and heartbeat to the past so the beat must move both.
    db.prepare('UPDATE lane_runs SET lease_until=?, heartbeat_at=? WHERE id=?').run(PAST, PAST, a.body.id);
    const h = await beat(DB, a.body.id, { machine: 'm1' });
    assert.equal(h.status, 200);
    assert.equal(h.body.id, a.body.id);
    assert.equal(h.body.status, 'claimed');
    const r = row(db, a.body.id);
    assert.equal(h.body.lease_until, r.lease_until);
    assert.ok(r.lease_until > PAST, `lease extended: ${r.lease_until}`);
    assert.ok(r.heartbeat_at > PAST, `heartbeat_at written: ${r.heartbeat_at}`);
    assert.equal((Date.parse(r.lease_until) - Date.parse(r.heartbeat_at)) / 1000, 120, 'lease is lane_run.lease_s from the beat');
    assert.equal(r.status, 'claimed');
    assert.equal(r.claimed_by, 'm1');
    assert.equal(r.attempts, 1, 'a beat is not a claim');
  });

  await t.test('W2 an expired lease nobody took is extended for its claimer', async () => {
    const { db, DB } = await fresh();
    const a = await enqueue(DB, 'demo', 'p1');
    await claim(DB, 'm1');
    expire(db, a.body.id);
    const h = await beat(DB, a.body.id, { machine: 'm1' });
    assert.equal(h.status, 200);
    assert.ok(row(db, a.body.id).lease_until > PAST);
  });

  await t.test('W3 after a take-over the old claimer gets 409 lost not_claimer and its report is refused', async () => {
    const { db, DB } = await fresh();
    const a = await enqueue(DB, 'demo', 'p1');
    await claim(DB, 'm1');
    expire(db, a.body.id);
    const c2 = await claim(DB, 'm10');
    assert.equal(c2.status, 200);
    assert.equal(c2.body.id, a.body.id);
    let r = row(db, a.body.id);
    assert.equal(r.attempts, 2);
    assert.equal(r.claimed_by, 'm10');
    const lease = r.lease_until;
    const hb = r.heartbeat_at;
    const h = await beat(DB, a.body.id, { machine: 'm1' });
    assert.equal(h.status, 409);
    assert.equal(h.body.error, 'lost');
    assert.equal(h.body.reason, 'not_claimer');
    assert.equal(h.body.id, a.body.id);
    assert.equal(h.body.claimed_by, undefined, 'the 409 never names the other claimer');
    r = row(db, a.body.id);
    assert.equal(r.lease_until, lease, 'a lost beat writes nothing');
    assert.equal(r.heartbeat_at, hb);
    const late = await report(DB, a.body.id, { machine: 'm1', rc: 0 });
    assert.equal(late.status, 409);
    assert.equal(late.body.reason, 'not_claimer');
    assert.equal(row(db, a.body.id).status, 'claimed');
    assert.equal((await beat(DB, a.body.id, { machine: 'm10' })).status, 200, 'the new claimer beats');
  });

  await t.test('W4 at max attempts an expired run dies rc 137, is never re-claimed, and leaves the live index', async () => {
    const { db, DB } = await fresh();
    const a = await enqueue(DB, 'demo', 'p1');
    const id = a.body.id;
    assert.equal((await claim(DB, 'm1')).status, 200);
    expire(db, id);
    assert.equal((await claim(DB, 'm2')).status, 200);
    expire(db, id);
    const c3 = await claim(DB, 'm3');
    assert.equal(c3.status, 200);
    assert.equal(c3.body.attempts, 3);
    expire(db, id);
    const c4 = await claim(DB, 'm4');
    assert.equal(c4.status, 204, 'the 4th claim finds nothing');
    const r = row(db, id);
    assert.equal(r.status, 'died');
    assert.equal(r.rc, 137);
    assert.equal(r.attempts, 3);
    assert.match(r.finished_at || '', /^\d{4}-\d\d-\d\dT\d\d:\d\d:\d\dZ$/);
    assert.equal(r.claimed_by, 'm3');
    assert.equal((await claim(DB, 'm5')).status, 204, 'died is terminal');
    const again = await enqueue(DB, 'demo', 'p1');
    assert.equal(again.status, 201, 'a died row is not live');
    assert.notEqual(again.body.id, id);
    const h = await beat(DB, id, { machine: 'm3' });
    assert.equal(h.status, 409);
    assert.equal(h.body.error, 'lost');
    assert.equal(h.body.reason, 'not_claimed');
    assert.equal(h.body.status, 'died');
  });

  await t.test('W5 heartbeat on a queued row, a done row, a missing row, and without a machine', async () => {
    const { db, DB } = await fresh();
    const a = await enqueue(DB, 'demo', 'p1');
    const q = await beat(DB, a.body.id, { machine: 'm1' });
    assert.equal(q.status, 409);
    assert.equal(q.body.error, 'lost');
    assert.equal(q.body.reason, 'not_claimed');
    assert.equal(q.body.status, 'queued');
    assert.equal(row(db, a.body.id).lease_until, null, 'no write on a queued row');
    await claim(DB, 'm1');
    assert.equal((await report(DB, a.body.id, { machine: 'm1', rc: 0 })).status, 200);
    const d = await beat(DB, a.body.id, { machine: 'm1' });
    assert.equal(d.status, 409);
    assert.equal(d.body.reason, 'not_claimed');
    assert.equal(d.body.status, 'done');
    const none = await beat(DB, 999, { machine: 'm1' });
    assert.equal(none.status, 409);
    assert.equal(none.body.error, 'lost');
    assert.equal(none.body.reason, 'no_row');
    for (const body of [{}, { machine: '' }, { machine: 'bad name' }]) {
      const b = await beat(DB, a.body.id, body);
      assert.equal(b.status, 400, JSON.stringify(body));
      assert.match(b.body.error, /machine is required/);
    }
    assert.equal((await call(DB, 'POST', '/api/lane-runs/abc/heartbeat', { machine: 'm1' })).status, 404);
  });

  await t.test('W6 sweepDead: the max setting, its fallback, live leases, other statuses, the count', async () => {
    const { db, DB } = await fresh();
    const env = { DB };
    const mk = (project, attempts, status, lease) => db.prepare(
      'INSERT INTO lane_runs (lane, project, args_json, enqueued_at, status, attempts, lease_until, claimed_by) VALUES (?,?,?,?,?,?,?,?)'
    ).run('demo', project, '["bin/x.sh"]', NOW, status, attempts, lease, 'm1').lastInsertRowid;

    setSetting(db, 'lane_run.max_attempts', '1');
    const one = mk('a1', 1, 'claimed', PAST);
    assert.equal(await sweepDead(env, NOW), 1, 'max 1, attempts 1, expired');
    assert.equal(row(db, one).status, 'died');
    assert.equal(row(db, one).rc, 137);
    assert.equal(row(db, one).finished_at, NOW);

    const two = mk('a2', 2, 'claimed', PAST);
    for (const v of ['abc', '0', '99', '', ' ']) {
      setSetting(db, 'lane_run.max_attempts', v);
      assert.equal(await sweepDead(env, NOW), 0, `max '${v}' falls back to 3`);
    }
    db.prepare("DELETE FROM settings WHERE key='lane_run.max_attempts'").run();
    assert.equal(await sweepDead(env, NOW), 0, 'no row falls back to 3');
    assert.equal(row(db, two).status, 'claimed');

    setSetting(db, 'lane_run.max_attempts', '3');
    mk('a3', 3, 'claimed', '2099-01-01T00:00:00Z');
    assert.equal(await sweepDead(env, NOW), 0, 'a live lease never dies');
    const doneId = mk('a4', 5, 'done', PAST);
    assert.equal(await sweepDead(env, NOW), 0, 'a done row is not touched');
    assert.equal(row(db, doneId).rc, null);
    mk('a5', 0, 'queued', null);
    assert.equal(await sweepDead(env, NOW), 0, 'a queued row is not touched');

    mk('a6', 3, 'claimed', PAST);
    mk('a7', 5, 'claimed', PAST);
    assert.equal(await sweepDead(env, NOW), 2, 'two eligible rows');
    assert.equal(await sweepDead(env, NOW), 0, 'idempotent');
  });
});
