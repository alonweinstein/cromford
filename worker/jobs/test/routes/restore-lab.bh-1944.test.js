import test from 'node:test';
import assert from 'node:assert/strict';
import worker from '../../src/index.js';
import { openDb } from '../lib/d1-sqlite.bh-1030.js';

// BH-1944 (BH-1909.2): the four restore-lab routes, driven through the real
// worker.fetch against real SQLite and the real schema.sql. Every write here is
// a compare-and-swap judged by meta.changes, so the SQL is the behaviour and a
// pattern-matching stub would prove nothing about it. Red on the contract
// branch: every route answers 501.

const SECRET = 'test-secret';
// The clock is pinned: the routes stamp rows with the router's t, and the TTL
// cases sit one second either side of a boundary.
const NOW_MS = Date.parse('2026-09-24T12:00:00Z');
const iso = (sAgo) => new Date(NOW_MS - sAgo * 1000).toISOString().replace(/\.\d{3}Z$/, 'Z');
const BOX = 'box-project-3-2';
const SHA = 'a'.repeat(64);
const TS = '20260924T120000Z';

async function open(t, hooks = {}) {
  t.mock.timers.enable({ apis: ['Date'], now: NOW_MS });
  const env = await openDb(hooks);
  if (!env) { t.skip('node:sqlite unavailable on this runtime'); return null; }
  env.db.prepare('INSERT INTO box_status (box, updated_at) VALUES (?, ?)').run(BOX, iso(60));
  env.db.prepare('INSERT INTO box_status (box, updated_at) VALUES (?, ?)').run('hub', iso(60));
  return env;
}

async function call(DB, method, path, body, secret = SECRET) {
  const init = { method, headers: {} };
  if (secret) init.headers.authorization = `Bearer ${secret}`;
  if (body !== undefined) {
    init.body = JSON.stringify(body);
    init.headers['content-type'] = 'application/json';
  }
  const res = await worker.fetch(new Request(`https://jobs.test${path}`, init), { DB, HARNESS_SECRET: SECRET });
  return { status: res.status, body: await res.json() };
}

const runs = (db) => db.prepare('SELECT * FROM restore_lab_runs ORDER BY id').all();
const audits = (db, action) => db.prepare('SELECT * FROM hub_lease_changes WHERE action=? ORDER BY id').all(action);
const row = (db, id) => db.prepare('SELECT * FROM restore_lab_runs WHERE id=?').get(id);
function seedRun(db, over = {}) {
  const r = {
    box: BOX, snapshot: 'latest', status: 'requested', requested_by: 'console', requested_at: iso(600),
    claimed_by: null, claimed_at: null, ...over,
  };
  const res = db.prepare(
    'INSERT INTO restore_lab_runs (box,snapshot,status,requested_by,requested_at,claimed_by,claimed_at) VALUES (?,?,?,?,?,?,?)',
  ).run(r.box, r.snapshot, r.status, r.requested_by, r.requested_at, r.claimed_by, r.claimed_at);
  return Number(res.lastInsertRowid);
}
const req = (over = {}) => ({ box: BOX, actor: 'console', confirm: true, ...over });

// ── POST /api/hub/restore-lab ──────────────────────────────────────────────

test('C2-T1a: an unconfirmed request is 400 confirm_required, audited once each, and writes no run', async (t) => {
  const env = await open(t); if (!env) return;
  const bodies = [req({ confirm: undefined }), req({ confirm: 'true' }), req({ confirm: 1 }), req({ confirm: 'yes' })];
  for (const b of bodies) {
    const r = await call(env.DB, 'POST', '/api/hub/restore-lab', b);
    assert.equal(r.status, 400, JSON.stringify(b));
    assert.deepEqual(r.body, { error: 'confirm_required' });
  }
  const a = audits(env.db, 'restore_lab_refused');
  assert.equal(a.length, 4, 'one refused row per attempt');
  for (const x of a) {
    assert.equal(x.outcome, 'refused:confirm');
    assert.equal(x.target, BOX);
    assert.equal(x.actor, 'console');
    assert.equal(x.at, iso(0));
  }
  assert.equal(runs(env.db).length, 0);
  // No actor at all is still on the record.
  const r = await call(env.DB, 'POST', '/api/hub/restore-lab', { box: BOX });
  assert.equal(r.status, 400);
  assert.equal(audits(env.db, 'restore_lab_refused').at(-1).actor, 'unknown');
});

test('C2-T1b: an unknown box is 409 unknown_box and writes no run', async (t) => {
  const env = await open(t); if (!env) return;
  const r = await call(env.DB, 'POST', '/api/hub/restore-lab', req({ box: 'nope' }));
  assert.equal(r.status, 409);
  assert.deepEqual(r.body, { error: 'unknown_box' });
  const dots = await call(env.DB, 'POST', '/api/hub/restore-lab', req({ box: '..' }));
  assert.equal(dots.status, 409, '.. is not a box the fleet has heard from');
  assert.equal(runs(env.db).length, 0);
});

test('C2-T1c: a bad snapshot or box is 400 and writes no run; a real stamp is accepted', async (t) => {
  const env = await open(t); if (!env) return;
  for (const snapshot of ['../x', '2026-09-24', 'latest/..', 'latest/../../etc', '20260924T1200Z', '20260924T120000Z;rm', '', 7]) {
    const r = await call(env.DB, 'POST', '/api/hub/restore-lab', req({ snapshot }));
    assert.equal(r.status, 400, `snapshot ${JSON.stringify(snapshot)}`);
    assert.match(r.body.error, /snapshot/);
  }
  for (const box of ['a/b', '', 'a b', 'x'.repeat(65), undefined]) {
    const r = await call(env.DB, 'POST', '/api/hub/restore-lab', req({ box }));
    assert.equal(r.status, 400, `box ${JSON.stringify(box)}`);
    assert.match(r.body.error, /box/);
  }
  assert.equal(runs(env.db).length, 0);
  const ok = await call(env.DB, 'POST', '/api/hub/restore-lab', req({ snapshot: TS }));
  assert.equal(ok.status, 201);
  assert.equal(ok.body.run.snapshot, TS);
});

test('C2-T1d: a first request is 201 requested, with its audit row in the same write', async (t) => {
  const env = await open(t); if (!env) return;
  const r = await call(env.DB, 'POST', '/api/hub/restore-lab', req());
  assert.equal(r.status, 201);
  assert.equal(r.body.deduped, false);
  assert.equal(r.body.status, 'requested');
  assert.equal(r.body.id, r.body.run.id);
  assert.equal(r.body.run.box, BOX);
  assert.equal(r.body.run.snapshot, 'latest');
  assert.equal(r.body.run.requested_by, 'console');
  assert.equal(r.body.run.requested_at, iso(0));
  const a = audits(env.db, 'restore_lab_request');
  assert.equal(a.length, 1);
  assert.equal(a[0].target, BOX);
  assert.equal(a[0].outcome, 'ok');
  assert.equal(a[0].actor, 'console');
});

test('C2-T1e: the same request again is 200 deduped with the same id; a finished run does not block a new one', async (t) => {
  const env = await open(t); if (!env) return;
  const first = await call(env.DB, 'POST', '/api/hub/restore-lab', req());
  const again = await call(env.DB, 'POST', '/api/hub/restore-lab', req({ actor: 'mcp' }));
  assert.equal(again.status, 200);
  assert.equal(again.body.deduped, true);
  assert.equal(again.body.id, first.body.id);
  assert.equal(runs(env.db).length, 1);
  env.db.prepare(`UPDATE restore_lab_runs SET status='ok' WHERE id=?`).run(first.body.id);
  const fresh = await call(env.DB, 'POST', '/api/hub/restore-lab', req());
  assert.equal(fresh.status, 201);
  assert.equal(fresh.body.deduped, false);
  assert.notEqual(fresh.body.id, first.body.id);
});

// ── GET /api/hub/restore-lab ───────────────────────────────────────────────

test('C2-T2: GET lists the last 20 runs newest first and says when it cut', async (t) => {
  const env = await open(t); if (!env) return;
  const empty = await call(env.DB, 'GET', '/api/hub/restore-lab');
  assert.equal(empty.status, 200);
  assert.deepEqual(empty.body.runs, []);
  assert.equal(empty.body.truncated, false);
  assert.equal(empty.body.as_of, iso(0));
  for (let i = 0; i < 21; i++) seedRun(env.db, { snapshot: `2026092${i % 10}T0000${String(i).padStart(2, '0')}Z`, status: 'ok' });
  const r = await call(env.DB, 'GET', '/api/hub/restore-lab');
  assert.equal(r.body.runs.length, 20);
  assert.equal(r.body.truncated, true);
  const ids = r.body.runs.map((x) => x.id);
  assert.deepEqual(ids, [...ids].sort((a, b) => b - a));
  assert.equal(ids[0], 21);
});

// ── POST /api/hub/restore-lab/claim ───────────────────────────────────────

test('C2-T3a: a claim takes the oldest requested run', async (t) => {
  const env = await open(t); if (!env) return;
  const a = seedRun(env.db);
  seedRun(env.db, { snapshot: TS });
  const r = await call(env.DB, 'POST', '/api/hub/restore-lab/claim', { claimer: 'hub' });
  assert.equal(r.status, 200);
  assert.equal(r.body.run.id, a);
  assert.equal(r.body.run.status, 'claimed');
  assert.equal(r.body.run.claimed_by, 'hub');
  assert.equal(r.body.run.claimed_at, iso(0));
  const none = await call(env.DB, 'POST', '/api/hub/restore-lab/claim', { claimer: 'hub' });
  assert.notEqual(none.body.run.id, a, 'a fresh claim is not re-offered');
  const empty = await call(env.DB, 'POST', '/api/hub/restore-lab/claim', { claimer: 'hub' });
  assert.deepEqual(empty.body, { run: null });
});

test('C2-T3b: a claim that loses the race answers run:null and leaves the winner', async (t) => {
  const hooks = {};
  const env = await open(t, hooks); if (!env) return;
  const id = seedRun(env.db);
  hooks.beforeRun = (sql) => {
    if (/UPDATE restore_lab_runs SET status='claimed'/.test(sql)) {
      hooks.beforeRun = null;
      env.db.prepare(`UPDATE restore_lab_runs SET status='claimed', claimed_by='other', claimed_at=? WHERE id=?`).run(iso(0), id);
    }
  };
  const r = await call(env.DB, 'POST', '/api/hub/restore-lab/claim', { claimer: 'hub' });
  assert.equal(r.status, 200);
  assert.deepEqual(r.body, { run: null });
  assert.equal(row(env.db, id).claimed_by, 'other');
});

test('C2-T3c: a claim older than the 1800s fallback TTL is re-offered; a younger one is not', async (t) => {
  const env = await open(t); if (!env) return;
  const young = seedRun(env.db, { status: 'claimed', claimed_by: 'dead', claimed_at: iso(1799) });
  let r = await call(env.DB, 'POST', '/api/hub/restore-lab/claim', { claimer: 'hub' });
  assert.deepEqual(r.body, { run: null });
  assert.equal(row(env.db, young).claimed_by, 'dead');
  const edge = seedRun(env.db, { snapshot: TS, status: 'claimed', claimed_by: 'dead', claimed_at: iso(1800) });
  r = await call(env.DB, 'POST', '/api/hub/restore-lab/claim', { claimer: 'hub' });
  assert.deepEqual(r.body, { run: null }, 'exactly at the TTL is not stale');
  env.db.prepare('UPDATE restore_lab_runs SET claimed_at=? WHERE id=?').run(iso(1801), edge);
  r = await call(env.DB, 'POST', '/api/hub/restore-lab/claim', { claimer: 'hub' });
  assert.equal(r.body.run.id, edge);
  assert.equal(r.body.run.claimed_by, 'hub');
  assert.equal(r.body.run.claimed_at, iso(0));
});

test('C2-T3d: the settings row sets the TTL; a row nobody can parse falls back to 1800', async (t) => {
  const env = await open(t); if (!env) return;
  const setTtl = (v) => env.db.prepare(
    `INSERT INTO settings (key,value,updated_at) VALUES ('restore_lab_claim_ttl_s',?,?) ON CONFLICT(key) DO UPDATE SET value=excluded.value`,
  ).run(v, iso(0));
  const id = seedRun(env.db, { status: 'claimed', claimed_by: 'dead', claimed_at: iso(61) });
  for (const bad of ['abc', '0', '-5']) {
    setTtl(bad);
    const r = await call(env.DB, 'POST', '/api/hub/restore-lab/claim', { claimer: 'hub' });
    assert.deepEqual(r.body, { run: null }, `ttl ${bad} falls back to 1800`);
  }
  setTtl('60');
  const r = await call(env.DB, 'POST', '/api/hub/restore-lab/claim', { claimer: 'hub' });
  assert.equal(r.body.run.id, id);
});

test('C2-T3e: a claim without a valid claimer is 400', async (t) => {
  const env = await open(t); if (!env) return;
  seedRun(env.db);
  for (const claimer of ['', 'a b', undefined]) {
    const r = await call(env.DB, 'POST', '/api/hub/restore-lab/claim', { claimer });
    assert.equal(r.status, 400, JSON.stringify(claimer));
  }
  assert.equal(runs(env.db)[0].status, 'requested');
});

// ── POST /api/hub/restore-lab/:id/result ──────────────────────────────────

const result = (over = {}) => ({ claimer: 'hub', ok: true, detail: 'restored', sha256: SHA, snapshot_ts: TS, ...over });

test('C2-T4a: the claimer records ok with the verified sha and stamp', async (t) => {
  const env = await open(t); if (!env) return;
  const id = seedRun(env.db, { status: 'claimed', claimed_by: 'hub', claimed_at: iso(30) });
  const r = await call(env.DB, 'POST', `/api/hub/restore-lab/${id}/result`, result());
  assert.equal(r.status, 200);
  assert.equal(r.body.ok, true);
  const x = row(env.db, id);
  assert.equal(x.status, 'ok');
  assert.equal(x.finished_at, iso(0));
  assert.equal(x.sha256, SHA);
  assert.equal(x.snapshot_ts, TS);
  assert.equal(x.verdict_detail, 'restored');
  assert.deepEqual(r.body.run, { ...x });
});

test('C2-T4b: a non-claimer, a second post and an unknown id are each 409', async (t) => {
  const env = await open(t); if (!env) return;
  const id = seedRun(env.db, { status: 'claimed', claimed_by: 'hub', claimed_at: iso(30) });
  const before = { ...row(env.db, id) };
  const other = await call(env.DB, 'POST', `/api/hub/restore-lab/${id}/result`, result({ claimer: 'project-3' }));
  assert.equal(other.status, 409);
  assert.deepEqual(other.body, { error: 'not_claimed_by_you' });
  assert.deepEqual({ ...row(env.db, id) }, before);
  const first = await call(env.DB, 'POST', `/api/hub/restore-lab/${id}/result`, result());
  assert.equal(first.status, 200);
  const twice = await call(env.DB, 'POST', `/api/hub/restore-lab/${id}/result`, result({ ok: false, sha256: null, snapshot_ts: null }));
  assert.equal(twice.status, 409);
  assert.equal(row(env.db, id).status, 'ok');
  const unknown = await call(env.DB, 'POST', '/api/hub/restore-lab/999/result', result());
  assert.equal(unknown.status, 409);
  const requested = seedRun(env.db, { snapshot: TS });
  const unclaimed = await call(env.DB, 'POST', `/api/hub/restore-lab/${requested}/result`, result());
  assert.equal(unclaimed.status, 409);
  assert.equal(row(env.db, requested).status, 'requested');
});

test('C2-T4c: ok must be a real boolean, and ok:true needs a verified sha and stamp', async (t) => {
  const env = await open(t); if (!env) return;
  const id = seedRun(env.db, { status: 'claimed', claimed_by: 'hub', claimed_at: iso(30) });
  const bad = [
    result({ ok: 'true' }), result({ ok: 1 }), result({ ok: undefined }),
    result({ sha256: undefined }), result({ sha256: 'abc' }), result({ sha256: 'A'.repeat(64) }),
    result({ snapshot_ts: undefined }), result({ snapshot_ts: '../x' }),
    result({ ok: false, sha256: 'abc' }), result({ ok: false, snapshot_ts: 'latest' }),
    result({ detail: 'x'.repeat(501) }), result({ detail: 7 }),
    result({ claimer: '' }), result({ claimer: 'a b' }),
  ];
  for (const b of bad) {
    const r = await call(env.DB, 'POST', `/api/hub/restore-lab/${id}/result`, b);
    assert.equal(r.status, 400, JSON.stringify(b).slice(0, 120));
    assert.equal(row(env.db, id).status, 'claimed');
  }
  const fail = await call(env.DB, 'POST', `/api/hub/restore-lab/${id}/result`,
    { claimer: 'hub', ok: false, detail: 'REFUSED: sha256 mismatch' });
  assert.equal(fail.status, 200);
  const x = row(env.db, id);
  assert.equal(x.status, 'fail');
  assert.equal(x.verdict_detail, 'REFUSED: sha256 mismatch');
  assert.equal(x.sha256, null);
});

test('C2-T4d: every restore-lab route sits behind the bearer', async (t) => {
  const env = await open(t); if (!env) return;
  for (const [m, p] of [['POST', '/api/hub/restore-lab'], ['GET', '/api/hub/restore-lab'],
    ['POST', '/api/hub/restore-lab/claim'], ['POST', '/api/hub/restore-lab/1/result']]) {
    const r = await call(env.DB, m, p, m === 'POST' ? req() : undefined, null);
    assert.equal(r.status, 401, `${m} ${p}`);
  }
  assert.equal(runs(env.db).length, 0);
  assert.equal(audits(env.db, 'restore_lab_refused').length, 0);
});
