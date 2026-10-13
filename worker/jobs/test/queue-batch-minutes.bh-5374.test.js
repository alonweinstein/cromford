import test from 'node:test';
import assert from 'node:assert/strict';
import worker from '../src/index.js';
import { openDb } from './lib/d1-sqlite.bh-1030.js';

// BH-5374 (BH-5356.2): the queue waste ledger. One row per (repo, draft_pr,
// run_id) of a Mergify batch draft's CI run, written by bmin_tick in
// bin/lib/mc-batch-minutes.sh, read back as a per-day rollup by the console's
// QUEUE WASTE section on /ci.
//
// Everything goes through the real worker.fetch (bearer, path, body parsing)
// against node:sqlite running worker/jobs/schema.sql, so the upsert and the
// rollup SQL are what is tested, not a pattern match on them.
//
// determinism: ok-file clock-rolling-window open() pins Date to NOW_MS with t.mock.timers before every call, and the route's window anchor is nowIso() = new Date(), so ?days=N always ends on 2026-10-08 whatever the wall clock says

const SECRET = 'test-secret';
const NOW_MS = Date.parse('2026-10-08T12:00:00Z');
const TODAY = '2026-10-08';
const YESTERDAY = '2026-10-07';
const REPO = 'example-org/cromford';

async function open(t) {
  t.mock.timers.enable({ apis: ['Date'], now: NOW_MS });
  const env = await openDb();
  if (!env) t.skip('node:sqlite unavailable on this runtime');
  return env;
}

async function call(DB, method, path, body, { bearer = true } = {}) {
  const init = { method, headers: {} };
  if (bearer) init.headers.authorization = `Bearer ${SECRET}`;
  if (body !== undefined) {
    init.body = JSON.stringify(body);
    init.headers['content-type'] = 'application/json';
  }
  const res = await worker.fetch(new Request(`https://jobs.test${path}`, init), { DB, HARNESS_SECRET: SECRET });
  return { status: res.status, body: await res.json() };
}

const row = (over = {}) => ({
  repo: REPO, draft_pr: 5001, run_id: 9001, outcome: 'reset', minutes: 18, source: 'billable',
  reused_min: 0, reused_known: 0, workflow: 'harness-ci', head_sha: 'a'.repeat(40),
  closed_at: `${TODAY}T10:00:00Z`, box: 'hub', ...over,
});
const count = (db) => db.prepare('SELECT COUNT(*) AS n FROM queue_batch_minutes').get().n;

test('1 PUT is an idempotent upsert on (repo, draft_pr, run_id)', async (t) => {
  const env = await open(t); if (!env) return;
  const a = await call(env.DB, 'PUT', '/api/queue-batch-minutes', row({ minutes: 18 }));
  assert.equal(a.status, 200, JSON.stringify(a.body));
  assert.equal(a.body.ok, true);
  assert.equal(a.body.row.day, TODAY, 'day is the UTC date of closed_at');
  const b = await call(env.DB, 'PUT', '/api/queue-batch-minutes', row({ minutes: 21, outcome: 'red' }));
  assert.equal(b.status, 200);
  assert.equal(count(env.db), 1, 'the same key twice is one row');
  const r = env.db.prepare('SELECT minutes, outcome, day FROM queue_batch_minutes').get();
  assert.equal(r.minutes, 21);
  assert.equal(r.outcome, 'red');
  // A different run of the same draft is its own row.
  await call(env.DB, 'PUT', '/api/queue-batch-minutes', row({ run_id: 9002 }));
  assert.equal(count(env.db), 2);
});

test('2 GET daily rolls up by outcome and lists the drafts of each day', async (t) => {
  const env = await open(t); if (!env) return;
  for (const r of [
    row({ draft_pr: 5001, run_id: 9001, outcome: 'reset', minutes: 18 }),
    row({ draft_pr: 5002, run_id: 9002, outcome: 'red', minutes: 5, reused_min: 2, reused_known: 1 }),
    row({ draft_pr: 5003, run_id: 9003, outcome: 'merged', minutes: 9 }),
    row({ draft_pr: 4990, run_id: 8990, outcome: 'reset', minutes: 4, closed_at: `${YESTERDAY}T23:59:00Z` }),
    row({ draft_pr: 4000, run_id: 8000, outcome: 'reset', minutes: 99, closed_at: '2026-09-01T10:00:00Z' }),
  ]) {
    const res = await call(env.DB, 'PUT', '/api/queue-batch-minutes', r);
    assert.equal(res.status, 200, JSON.stringify(res.body));
  }
  const res = await call(env.DB, 'GET', '/api/queue-batch-minutes/daily?days=7');
  assert.equal(res.status, 200, JSON.stringify(res.body));
  assert.equal(res.body.truncated, false);
  assert.deepEqual(res.body.days.map((d) => d.day), [TODAY, YESTERDAY], 'newest first, out-of-window days dropped, empty days omitted');
  const [today, yesterday] = res.body.days;
  assert.equal(today.discarded_min, 23, 'reset 18 + red 5; merged never counts');
  assert.equal(today.red_min, 5);
  assert.equal(today.reset_min, 18);
  assert.equal(today.merged_min, 9);
  assert.equal(today.bisect_min, 0);
  assert.equal(today.reused_min, 2);
  assert.equal(today.reused_known, 0, 'known only when every row of the day is');
  assert.equal(today.resets, 1);
  assert.equal(today.drafts.length, 3);
  assert.deepEqual(today.drafts.map((d) => d.draft_pr), [5001, 5002, 5003]);
  assert.deepEqual(Object.keys(today.drafts[0]).sort(),
    ['closed_at', 'draft_pr', 'minutes', 'outcome', 'repo', 'reused_known', 'reused_min', 'run_id', 'source', 'workflow']);
  assert.equal(yesterday.discarded_min, 4);
  assert.equal(yesterday.resets, 1);
  // Two runs of one reset draft are one reset.
  await call(env.DB, 'PUT', '/api/queue-batch-minutes', row({ draft_pr: 5001, run_id: 9011, minutes: 2 }));
  const again = await call(env.DB, 'GET', '/api/queue-batch-minutes/daily');
  assert.equal(again.body.days[0].resets, 1, 'resets counts distinct drafts, not runs');
  assert.equal(again.body.days[0].discarded_min, 25);
});

test('3 no bearer is 401 on both routes', async (t) => {
  const env = await open(t); if (!env) return;
  const put = await call(env.DB, 'PUT', '/api/queue-batch-minutes', row(), { bearer: false });
  assert.equal(put.status, 401);
  const get = await call(env.DB, 'GET', '/api/queue-batch-minutes/daily?days=7', undefined, { bearer: false });
  assert.equal(get.status, 401);
  assert.equal(count(env.db), 0);
});

test('4 out-of-range days and bad bodies are 400, and write nothing', async (t) => {
  const env = await open(t); if (!env) return;
  for (const q of ['0', '91', 'abc', '1.5', '']) {
    const res = await call(env.DB, 'GET', `/api/queue-batch-minutes/daily?days=${q}`);
    assert.equal(res.status, 400, `days=${q}`);
  }
  for (const bad of [
    { outcome: 'foo' }, { minutes: -1 }, { minutes: 1.5 }, { minutes: '18' }, { run_id: 0 }, { draft_pr: -3 },
    { repo: 'no-slash' }, { repo: '' }, { source: 'guess' }, { reused_known: 2 }, { reused_min: -1 },
    { closed_at: 'not a date' }, { closed_at: undefined },
  ]) {
    const res = await call(env.DB, 'PUT', '/api/queue-batch-minutes', row(bad));
    assert.equal(res.status, 400, JSON.stringify(bad));
  }
  assert.equal(count(env.db), 0);
});

test('5 a missing table answers 503, never a bodiless 500', async (t) => {
  const env = await open(t); if (!env) return;
  env.db.exec('DROP TABLE queue_batch_minutes');
  const put = await call(env.DB, 'PUT', '/api/queue-batch-minutes', row());
  assert.equal(put.status, 503);
  assert.equal(put.body.error, 'queue_batch_minutes schema not applied');
  const get = await call(env.DB, 'GET', '/api/queue-batch-minutes/daily?days=7');
  assert.equal(get.status, 503);
  assert.equal(get.body.error, 'queue_batch_minutes schema not applied');
});
