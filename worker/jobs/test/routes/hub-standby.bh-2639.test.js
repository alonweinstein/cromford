import test from 'node:test';
import assert from 'node:assert/strict';
import worker from '../../src/index.js';
import { openDb } from '../lib/d1-sqlite.bh-1030.js';

// BH-2639 (BH-2519.1): the standby heartbeat, GET /api/hub/recovery reading
// standby_status, and the four standby verify queue routes, driven through the
// real worker.fetch against real SQLite and the real schema.sql. Red on the
// contract branch: both route modules are empty, so every standby route 404s
// and recovery still answers the hardcoded `standby: []`.

const SECRET = 'test-secret';
const NOW_MS = Date.parse('2026-09-26T12:00:00Z');
const iso = (sAgo) => new Date(NOW_MS - sAgo * 1000).toISOString().replace(/\.\d{3}Z$/, 'Z');
const SHA = 'b'.repeat(64);
const TS = '20260926T010203Z';

async function open(t, hooks = {}) {
  t.mock.timers.enable({ apis: ['Date'], now: NOW_MS });
  const env = await openDb(hooks);
  if (!env) { t.skip('node:sqlite unavailable on this runtime'); return null; }
  for (const b of ['sb-1', 'sb-2', 'hub']) {
    env.db.prepare('INSERT INTO box_status (box, updated_at) VALUES (?, ?)').run(b, iso(60));
  }
  return env;
}

async function call(DB, method, path, body) {
  const init = { method, headers: { authorization: `Bearer ${SECRET}` } };
  if (body !== undefined) {
    init.body = JSON.stringify(body);
    init.headers['content-type'] = 'application/json';
  }
  const res = await worker.fetch(new Request(`https://jobs.test${path}`, init), { DB, HARNESS_SECRET: SECRET });
  return { status: res.status, body: await res.json() };
}

const standbys = (db) => db.prepare('SELECT * FROM standby_status ORDER BY box').all();
const runs = (db) => db.prepare('SELECT * FROM standby_verify_runs ORDER BY id').all();
const run = (db, id) => db.prepare('SELECT * FROM standby_verify_runs WHERE id=?').get(id);
const audits = (db, action) => db.prepare('SELECT * FROM hub_lease_changes WHERE action=? ORDER BY id').all(action);
const seedStandby = (db, box, of = 'hub', at = iso(30)) =>
  db.prepare('INSERT INTO standby_status (box,of_hub,snapshot,ok,reported_at) VALUES (?,?,?,?,?)').run(box, of, TS, 1, at);
function seedRun(db, over = {}) {
  const r = { box: 'sb-1', of_hub: 'hub', status: 'requested', requested_at: iso(600), claimed_at: null, ...over };
  return Number(db.prepare(
    'INSERT INTO standby_verify_runs (box,of_hub,status,requested_by,requested_at,claimed_at) VALUES (?,?,?,?,?,?)',
  ).run(r.box, r.of_hub, r.status, 'console', r.requested_at, r.claimed_at).lastInsertRowid);
}
const hb = (over = {}) => ({ box: 'sb-1', of: 'hub', snapshot: TS, ok: true, ...over });
const HB = '/api/hub/standby/heartbeat';
const VERIFY = '/api/hub/standby/verify';
const CLAIM = '/api/hub/standby/verify/claim';
const result = (id) => `/api/hub/standby/verify/${id}/result`;

// ── POST /api/hub/standby/heartbeat ────────────────────────────────────────

test('H1: a heartbeat upserts one row per box, stamped with now', async (t) => {
  const env = await open(t); if (!env) return;
  const r = await call(env.DB, 'POST', HB, hb());
  assert.equal(r.status, 200, JSON.stringify(r.body));
  assert.equal(r.body.ok, true);
  assert.deepEqual(r.body.standby, { box: 'sb-1', of_hub: 'hub', snapshot: TS, ok: 1, reported_at: iso(0) });
  t.mock.timers.tick(90_000);
  const r2 = await call(env.DB, 'POST', HB, hb({ ok: false, of: 'hub-2' }));
  assert.equal(r2.status, 200);
  const rows = standbys(env.db);
  assert.equal(rows.length, 1, 'the same row, not a second one');
  assert.equal(rows[0].ok, 0);
  assert.equal(rows[0].of_hub, 'hub-2');
  assert.equal(rows[0].reported_at, iso(-90));
  assert.deepEqual(r2.body.standby, { ...rows[0] });
});

test('H2: a bad box is 400 and writes nothing', async (t) => {
  const env = await open(t); if (!env) return;
  for (const box of ['bad box!', '', undefined, 'x'.repeat(65), 7]) {
    const r = await call(env.DB, 'POST', HB, hb({ box }));
    assert.equal(r.status, 400, String(box));
  }
  assert.equal(standbys(env.db).length, 0);
});

test('H3: a box with no box_status row is 409 unknown_box and writes nothing', async (t) => {
  const env = await open(t); if (!env) return;
  const r = await call(env.DB, 'POST', HB, hb({ box: 'ghost' }));
  assert.equal(r.status, 409);
  assert.deepEqual(r.body, { error: 'unknown_box' });
  assert.equal(standbys(env.db).length, 0);
});

test('H4: an `of` outside [a-z0-9-]{1,64} is 400 and writes nothing', async (t) => {
  const env = await open(t); if (!env) return;
  for (const of of ['Hub', 'hub_1', '', 'h'.repeat(65), undefined, 3]) {
    const r = await call(env.DB, 'POST', HB, hb({ of }));
    assert.equal(r.status, 400, String(of));
  }
  assert.equal(standbys(env.db).length, 0);
});

test('H5: a snapshot that is not a stamp is stored as null, never rejected', async (t) => {
  const env = await open(t); if (!env) return;
  for (const snapshot of ['latest', '', 123, undefined]) {
    const r = await call(env.DB, 'POST', HB, hb({ snapshot }));
    assert.equal(r.status, 200, String(snapshot));
    assert.equal(r.body.standby.snapshot, null);
    assert.equal(standbys(env.db)[0].snapshot, null);
  }
});

test('H6: ok that is not the JSON literal true/false is 400 and writes nothing', async (t) => {
  const env = await open(t); if (!env) return;
  for (const ok of ['true', 0, 1, undefined, null]) {
    const r = await call(env.DB, 'POST', HB, hb({ ok }));
    assert.equal(r.status, 400, String(ok));
  }
  assert.equal(standbys(env.db).length, 0);
});

// ── GET /api/hub/recovery ──────────────────────────────────────────────────

test('R1: recovery lists the standby_status boxes by name and carries the rows', async (t) => {
  const env = await open(t); if (!env) return;
  seedStandby(env.db, 'sb-2', 'hub', iso(40));
  seedStandby(env.db, 'sb-1', 'hub', iso(20));
  const r = await call(env.DB, 'GET', '/api/hub/recovery');
  assert.equal(r.status, 200);
  assert.deepEqual(r.body.role.standby, ['sb-1', 'sb-2']);
  assert.equal(r.body.role.standby_note, null);
  assert.equal(r.body.standbys.length, 2);
  assert.deepEqual(r.body.standbys[0], { box: 'sb-1', of_hub: 'hub', snapshot: TS, ok: 1, reported_at: iso(20) });
  assert.equal(r.body.standbys[1].box, 'sb-2');
});

test('R2: an empty standby_status says so; a missing table is 503', async (t) => {
  const env = await open(t); if (!env) return;
  const r = await call(env.DB, 'GET', '/api/hub/recovery');
  assert.equal(r.status, 200);
  assert.deepEqual(r.body.role.standby, []);
  assert.equal(r.body.role.standby_note, 'no standby has reported a heartbeat yet');
  assert.deepEqual(r.body.standbys, []);
  env.db.exec('DROP TABLE standby_status');
  const r2 = await call(env.DB, 'GET', '/api/hub/recovery');
  assert.equal(r2.status, 503);
});

test('R3: a heartbeat through the route is what recovery then shows', async (t) => {
  const env = await open(t); if (!env) return;
  assert.equal((await call(env.DB, 'POST', HB, hb())).status, 200);
  const r = await call(env.DB, 'GET', '/api/hub/recovery');
  assert.deepEqual(r.body.role.standby, ['sb-1']);
  assert.equal(r.body.standbys[0].reported_at, iso(0));
});

// ── POST /api/hub/standby/verify ───────────────────────────────────────────

test('V1: an unconfirmed verify is 400, audited once per attempt, no run', async (t) => {
  const env = await open(t); if (!env) return;
  seedStandby(env.db, 'sb-1');
  for (const confirm of [undefined, 'true', 1]) {
    const r = await call(env.DB, 'POST', VERIFY, { box: 'sb-1', actor: 'console', confirm });
    assert.equal(r.status, 400);
    assert.deepEqual(r.body, { error: 'confirm_required' });
  }
  const a = audits(env.db, 'standby_verify_refused');
  assert.equal(a.length, 3);
  for (const x of a) {
    assert.equal(x.outcome, 'refused:confirm');
    assert.equal(x.target, 'sb-1');
    assert.equal(x.actor, 'console');
  }
  assert.equal(runs(env.db).length, 0);
});

test('V2: a box that never sent a heartbeat is 409 unknown_standby, nothing written', async (t) => {
  const env = await open(t); if (!env) return;
  const r = await call(env.DB, 'POST', VERIFY, { box: 'sb-2', actor: 'console', confirm: true });
  assert.equal(r.status, 409);
  assert.deepEqual(r.body, { error: 'unknown_standby' });
  assert.equal(runs(env.db).length, 0);
  assert.equal(audits(env.db, 'standby_verify_request').length, 0);
  const bad = await call(env.DB, 'POST', VERIFY, { box: 'bad box', actor: 'console', confirm: true });
  assert.equal(bad.status, 400);
});

test('V3: a confirmed verify queues a run with of_hub copied, plus one audit row', async (t) => {
  const env = await open(t); if (!env) return;
  seedStandby(env.db, 'sb-1', 'hub-a');
  const r = await call(env.DB, 'POST', VERIFY, { box: 'sb-1', actor: 'operator', confirm: true });
  assert.equal(r.status, 201, JSON.stringify(r.body));
  assert.equal(r.body.deduped, false);
  assert.equal(r.body.status, 'requested');
  assert.equal(r.body.run.of_hub, 'hub-a');
  assert.equal(r.body.run.requested_by, 'operator');
  assert.equal(r.body.run.requested_at, iso(0));
  assert.equal(r.body.id, r.body.run.id);
  const a = audits(env.db, 'standby_verify_request');
  assert.equal(a.length, 1);
  assert.equal(a[0].target, 'sb-1');
  assert.equal(a[0].actor, 'operator');
  assert.equal(a[0].outcome, 'ok');
});

test('V4: a second verify while one is open dedups; after it finishes a new one is queued', async (t) => {
  const env = await open(t); if (!env) return;
  seedStandby(env.db, 'sb-1');
  const body = { box: 'sb-1', actor: 'console', confirm: true };
  const first = await call(env.DB, 'POST', VERIFY, body);
  const second = await call(env.DB, 'POST', VERIFY, body);
  assert.equal(second.status, 200);
  assert.equal(second.body.deduped, true);
  assert.equal(second.body.id, first.body.id);
  assert.equal(runs(env.db).length, 1);
  env.db.prepare("UPDATE standby_verify_runs SET status='ok' WHERE id=?").run(first.body.id);
  const third = await call(env.DB, 'POST', VERIFY, body);
  assert.equal(third.status, 201);
  assert.notEqual(third.body.id, first.body.id);
});

// ── GET /api/hub/standby/verify ────────────────────────────────────────────

test('V5: GET lists the last 20 runs newest first and says when it truncated', async (t) => {
  const env = await open(t); if (!env) return;
  for (let i = 0; i < 3; i++) seedRun(env.db, { status: 'ok' });
  let r = await call(env.DB, 'GET', VERIFY);
  assert.equal(r.status, 200);
  assert.equal(r.body.runs.length, 3);
  assert.equal(r.body.truncated, false);
  assert.equal(r.body.as_of, iso(0));
  for (let i = 0; i < 18; i++) seedRun(env.db, { status: 'fail' });
  r = await call(env.DB, 'GET', VERIFY);
  assert.equal(r.body.runs.length, 20);
  assert.equal(r.body.truncated, true);
  assert.deepEqual(r.body.runs.map((x) => x.id), Array.from({ length: 20 }, (_, i) => 21 - i));
});

// ── POST /api/hub/standby/verify/claim ─────────────────────────────────────

test('V6: only the run\'s own box can claim it, once', async (t) => {
  const env = await open(t); if (!env) return;
  const id = seedRun(env.db);
  const other = await call(env.DB, 'POST', CLAIM, { claimer: 'sb-2' });
  assert.equal(other.status, 200);
  assert.equal(other.body.run, null);
  assert.equal(run(env.db, id).status, 'requested');
  const mine = await call(env.DB, 'POST', CLAIM, { claimer: 'sb-1' });
  assert.equal(mine.status, 200);
  assert.equal(mine.body.run.id, id);
  assert.equal(mine.body.run.status, 'claimed');
  assert.equal(mine.body.run.claimed_at, iso(0));
  const again = await call(env.DB, 'POST', CLAIM, { claimer: 'sb-1' });
  assert.equal(again.body.run, null);
  assert.equal((await call(env.DB, 'POST', CLAIM, {})).status, 400);
});

test('V7: a stale claim is re-offered after the TTL (fallback 1800 s, settings row wins)', async (t) => {
  const env = await open(t); if (!env) return;
  const stale = seedRun(env.db, { status: 'claimed', claimed_at: iso(1801) });
  let r = await call(env.DB, 'POST', CLAIM, { claimer: 'sb-1' });
  assert.equal(r.body.run?.id, stale, 'seeded row 1800 is the schema seed; 1801 s is past it');
  env.db.prepare("UPDATE standby_verify_runs SET claimed_at=? WHERE id=?").run(iso(1799), stale);
  r = await call(env.DB, 'POST', CLAIM, { claimer: 'sb-1' });
  assert.equal(r.body.run, null);
  env.db.prepare("DELETE FROM settings WHERE key='standby_verify_claim_ttl_s'").run();
  env.db.prepare("UPDATE standby_verify_runs SET claimed_at=? WHERE id=?").run(iso(1801), stale);
  r = await call(env.DB, 'POST', CLAIM, { claimer: 'sb-1' });
  assert.equal(r.body.run?.id, stale, 'code fallback 1800 with no settings row');
  env.db.prepare("INSERT INTO settings (key,value,actor,updated_at) VALUES ('standby_verify_claim_ttl_s','600','t',?)").run(iso(0));
  env.db.prepare("UPDATE standby_verify_runs SET claimed_at=? WHERE id=?").run(iso(601), stale);
  r = await call(env.DB, 'POST', CLAIM, { claimer: 'sb-1' });
  assert.equal(r.body.run?.id, stale, 'the settings row wins');
});

// ── POST /api/hub/standby/verify/:id/result ────────────────────────────────

test('V8: result validation is restore-lab\'s; a good verdict is recorded', async (t) => {
  const env = await open(t); if (!env) return;
  const id = seedRun(env.db, { status: 'claimed', claimed_at: iso(10) });
  const bad = [
    { ok: 'true', sha256: SHA, snapshot_ts: TS },
    { ok: true },
    { ok: true, sha256: 'b'.repeat(63), snapshot_ts: TS },
    { ok: true, sha256: SHA, snapshot_ts: 'latest' },
    { ok: false, detail: 'x'.repeat(501) },
  ];
  for (const b of bad) {
    const r = await call(env.DB, 'POST', result(id), { claimer: 'sb-1', ...b });
    assert.equal(r.status, 400, JSON.stringify(b).slice(0, 80));
  }
  assert.equal(run(env.db, id).status, 'claimed');
  const good = await call(env.DB, 'POST', result(id), { claimer: 'sb-1', ok: true, sha256: SHA, snapshot_ts: TS, detail: 'restored' });
  assert.equal(good.status, 200);
  assert.equal(good.body.ok, true);
  assert.equal(good.body.run.status, 'ok');
  assert.equal(good.body.run.sha256, SHA);
  assert.equal(good.body.run.snapshot_ts, TS);
  assert.equal(good.body.run.finished_at, iso(0));
  const id2 = seedRun(env.db, { box: 'sb-2', status: 'claimed', claimed_at: iso(10) });
  const fail = await call(env.DB, 'POST', result(id2), { claimer: 'sb-2', ok: false, detail: 'sha mismatch' });
  assert.equal(fail.status, 200);
  assert.equal(fail.body.run.status, 'fail');
  assert.equal(fail.body.run.verdict_detail, 'sha mismatch');
});

test('V9: anyone but the claiming box, a finished run or an unknown id is 409', async (t) => {
  const env = await open(t); if (!env) return;
  const id = seedRun(env.db, { status: 'claimed', claimed_at: iso(10) });
  const before = run(env.db, id);
  const other = await call(env.DB, 'POST', result(id), { claimer: 'sb-2', ok: false, detail: 'x' });
  assert.equal(other.status, 409);
  assert.deepEqual(other.body, { error: 'not_claimed_by_you' });
  assert.deepEqual(run(env.db, id), before);
  const done = seedRun(env.db, { status: 'ok', claimed_at: iso(10) });
  assert.equal((await call(env.DB, 'POST', result(done), { claimer: 'sb-1', ok: false })).status, 409);
  assert.equal((await call(env.DB, 'POST', result(999), { claimer: 'sb-1', ok: false })).status, 409);
});
