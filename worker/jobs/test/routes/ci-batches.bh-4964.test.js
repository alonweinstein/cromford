import test from 'node:test';
import assert from 'node:assert/strict';
import worker from '../../src/index.js';
import { openDb } from '../lib/d1-sqlite.bh-1030.js';

// BH-4971 (BH-4964.3) — PUT/GET /api/ci-batches, the per-merge-queue-batch CI
// cost ledger bin/ci-batch-ledger.sh writes: one row per Harness CI run_id.
//
// Driven through the real worker.fetch (D2) over the real schema.sql in
// node:sqlite, so the route table, the bearer, body parsing and the upsert SQL
// are what run. Deleting the ROUTES spread in src/index.js turns every case
// here into the router's 404.

const SECRET = 'test-secret';
const NOW_MS = Date.parse('2026-10-07T09:00:00Z');

async function open(t) {
  t.mock.timers.enable({ apis: ['Date'], now: NOW_MS });
  const env = await openDb();
  if (!env) t.skip('node:sqlite unavailable on this runtime');
  return env;
}

async function call(DB, method, path, body, { secret = SECRET } = {}) {
  const init = { method, headers: {} };
  if (secret !== null) init.headers.authorization = `Bearer ${secret}`;
  if (body !== undefined) {
    init.body = JSON.stringify(body);
    init.headers['content-type'] = 'application/json';
  }
  const res = await worker.fetch(new Request(`https://jobs.test${path}`, init), { DB, HARNESS_SECRET: SECRET });
  return { status: res.status, body: await res.json() };
}

const put = (DB, b, o) => call(DB, 'PUT', '/api/ci-batches', b, o);
const get = (DB, q, o) => call(DB, 'GET', `/api/ci-batches${q}`, undefined, o);
const count = (db) => db.prepare('SELECT COUNT(*) AS n FROM ci_batches').get().n;

test('B1: a second PUT of the same run_id updates the one row, never adds one', async (t) => {
  const env = await open(t); if (!env) return;
  const a = await put(env.DB, { run_id: 101, repo: 'A/x', billed_min: 5, mode: 'batch-selected' });
  assert.equal(a.status, 200, JSON.stringify(a.body));
  assert.equal(a.body.ok, true);
  assert.equal(a.body.row.billed_min, 5);
  const b = await put(env.DB, { run_id: 101, repo: 'A/x', billed_min: 7, mode: 'batch-selected' });
  assert.equal(b.status, 200, JSON.stringify(b.body));
  assert.equal(count(env.db), 1);
  const row = env.db.prepare('SELECT * FROM ci_batches WHERE run_id = 101').get();
  assert.equal(row.billed_min, 7);
  assert.equal(row.mode, 'batch-selected');
  assert.equal(row.as_of, '2026-10-07T09:00:00Z');
});

test('B2: GET filters on repo and since; the PUT values come back as sent', async (t) => {
  const env = await open(t); if (!env) return;
  for (const [run_id, repo, completed_at] of [
    [1, 'A/x', '2026-10-01T10:00:00Z'], [2, 'A/x', '2026-10-05T10:00:00Z'], [3, 'B/y', '2026-10-05T11:00:00Z'],
  ]) {
    const r = await put(env.DB, { run_id, repo, completed_at, billed_min: 1 });
    assert.equal(r.status, 200, JSON.stringify(r.body));
  }
  const onlyA = await get(env.DB, '?repo=A%2Fx');
  assert.equal(onlyA.status, 200);
  assert.deepEqual(onlyA.body.rows.map((r) => r.run_id), [2, 1], 'newest completed first');
  assert.equal(onlyA.body.truncated, false);
  const sinceA = await get(env.DB, '?repo=A%2Fx&since=2026-10-03');
  assert.deepEqual(sinceA.body.rows.map((r) => r.run_id), [2]);
  const sinceT = await get(env.DB, '?since=2026-10-05T10:30:00Z');
  assert.deepEqual(sinceT.body.rows.map((r) => r.run_id), [3]);
  const all = await get(env.DB, '');
  assert.equal(all.body.rows.length, 3);

  const sent = {
    run_id: 900, repo: 'example-org/cromford', billed_min: 5, mode: 'batch-selected', selected: 12, total: 900,
    head_ref: 'mergify/merge-queue/main/abc', head_sha: 'f'.repeat(40), escalation: null, conclusion: 'success', run_attempt: 2,
    started_at: '2026-10-06T10:00:00Z', completed_at: '2026-10-06T10:20:00Z', wall_s: 1200,
  };
  assert.equal((await put(env.DB, sent)).status, 200);
  const back = await get(env.DB, '?repo=example-org%2Fcromford');
  assert.equal(back.body.rows.length, 1);
  const row = back.body.rows[0];
  for (const [k, v] of Object.entries(sent)) assert.equal(row[k], v, k);
  assert.equal(row.as_of, '2026-10-07T09:00:00Z');
});

test('B3: an unapplied table answers 503 "ci_batches schema not applied" on both verbs', async (t) => {
  const env = await open(t); if (!env) return;
  env.db.exec('DROP TABLE ci_batches');
  const p = await put(env.DB, { run_id: 1, repo: 'A/x' });
  assert.equal(p.status, 503);
  assert.equal(p.body.error, 'ci_batches schema not applied');
  const g = await get(env.DB, '?repo=A%2Fx');
  assert.equal(g.status, 503);
  assert.equal(g.body.error, 'ci_batches schema not applied');
});

test('B4: bad input is a 400 naming the field, never a clamp; no bearer is 401', async (t) => {
  const env = await open(t); if (!env) return;
  for (const run_id of [undefined, 0, -1, 1.5, '7', null]) {
    const r = await put(env.DB, { run_id, repo: 'A/x' });
    assert.equal(r.status, 400, `run_id ${run_id}: ${JSON.stringify(r.body)}`);
    assert.equal(r.body.error, 'run_id required');
  }
  const noRepo = await put(env.DB, { run_id: 1 });
  assert.equal(noRepo.status, 400);
  assert.equal(noRepo.body.error, 'repo required');
  for (const f of ['selected', 'total', 'run_attempt', 'wall_s', 'billed_min']) {
    for (const v of [-1, 2.5, '3', true]) {
      const r = await put(env.DB, { run_id: 1, repo: 'A/x', [f]: v });
      assert.equal(r.status, 400, `${f}=${v}: ${JSON.stringify(r.body)}`);
      assert.match(r.body.error, new RegExp(f));
    }
  }
  assert.equal(count(env.db), 0);
  for (const q of ['?since=yesterday', '?since=2026-10-06T10:00', '?limit=0', '?limit=5001', '?limit=x']) {
    const r = await get(env.DB, q);
    assert.equal(r.status, 400, `${q}: ${JSON.stringify(r.body)}`);
  }
  assert.equal((await put(env.DB, { run_id: 1, repo: 'A/x' }, { secret: null })).status, 401);
  assert.equal((await get(env.DB, '', { secret: null })).status, 401);
  assert.equal(count(env.db), 0);
});

test('B5: a GET cut by its limit says truncated', async (t) => {
  const env = await open(t); if (!env) return;
  await put(env.DB, { run_id: 1, repo: 'A/x', completed_at: '2026-10-01T00:00:00Z' });
  await put(env.DB, { run_id: 2, repo: 'A/x', completed_at: '2026-10-02T00:00:00Z' });
  const r = await get(env.DB, '?repo=A%2Fx&limit=1');
  assert.equal(r.status, 200);
  assert.equal(r.body.truncated, true);
  assert.deepEqual(r.body.rows.map((x) => x.run_id), [2]);
  const full = await get(env.DB, '?repo=A%2Fx&limit=2');
  assert.equal(full.body.truncated, false);
  assert.equal(full.body.rows.length, 2);
});
