import test from 'node:test';
import assert from 'node:assert/strict';
import worker from '../../src/index.js';
import { ADOPTION_COUNTS_SQL, ADOPTION_RECENT_SQL } from '../../src/routes/preplans.js';
import { openDb } from '../lib/d1-sqlite.bh-1030.js';

// BH-2571 (BH-2543.1) — GET /api/preplans/adoption, the numbers the pre-plan
// cadence gate and the console read.
//
// Driven through the real worker.fetch (D2) over the real schema.sql in
// node:sqlite, so the route table, the bearer and the SQL itself are what run.
// The contract is pinned in bin/lib/preplan-cadence.sh: bought = adopted +
// stale, rate = adopted/bought and null (never 0) when nothing was bought,
// `days` outside 1-30 is a 400 and never clamped, `recent` capped at 50 with
// recent_truncated saying so.

const SECRET = 'test-secret';
const NOW_MS = Date.parse('2026-09-26T09:00:00Z');
const SINCE_7 = '2026-09-19T09:00:00Z';

async function open(t) {
  t.mock.timers.enable({ apis: ['Date'], now: NOW_MS });
  const env = await openDb();
  if (!env) t.skip('node:sqlite unavailable on this runtime');
  return env;
}

async function get(DB, path, { secret = SECRET } = {}) {
  const init = { method: 'GET', headers: {} };
  if (secret !== null) init.headers.authorization = `Bearer ${secret}`;
  const res = await worker.fetch(new Request(`https://jobs.test${path}`, init), { DB, HARNESS_SECRET: SECRET });
  return { status: res.status, body: await res.json() };
}

function job(db, id, project) {
  db.prepare(`INSERT INTO jobs (id, project, ticket_id, kind, box, stage, status, created_at, updated_at)
              VALUES (?, ?, ?, 'build', 'box-1', 'plan', 'running', ?, ?)`)
    .run(id, project, `T-${id}`, '2026-09-10T00:00:00Z', '2026-09-10T00:00:00Z');
}
function ev(db, jobId, stage, verdict, createdAt, detail = null) {
  db.prepare(`INSERT INTO stage_events (job_id, stage, verdict, actor, detail, created_at)
              VALUES (?, ?, ?, 'box-1', ?, ?)`).run(jobId, stage, verdict, detail, createdAt);
}

// p1: 3 ADOPTED + 1 STALE + 2 MISS in the window, one ADOPTED 8 days old, and
// three rows that must never count. p2: a job and no events. p3: only MISS.
function seed(db) {
  for (let i = 1; i <= 7; i++) job(db, `j${i}`, 'p1');
  job(db, 'jp2', 'p2'); job(db, 'j8', 'p3'); job(db, 'j9', 'p3');
  ev(db, 'j1', 'preplan', 'ADOPTED', '2026-09-25T10:00:00Z', 'fresh against abc');
  ev(db, 'j2', 'preplan', 'ADOPTED', '2026-09-25T11:00:00Z');
  ev(db, 'j3', 'preplan', 'ADOPTED', '2026-09-24T10:00:00Z');
  ev(db, 'j4', 'preplan', 'STALE', '2026-09-24T12:00:00Z', 'thread moved');
  ev(db, 'j5', 'preplan', 'MISS', '2026-09-23T10:00:00Z');
  ev(db, 'j6', 'preplan', 'MISS', '2026-09-23T11:00:00Z');
  ev(db, 'j7', 'preplan', 'ADOPTED', '2026-09-18T09:00:00Z'); // 8 days old
  // negatives
  ev(db, 'j1', 'preplan', 'APPROVE', '2026-09-25T12:00:00Z');
  ev(db, 'j1', 'preplan', null, '2026-09-25T12:30:00Z');
  ev(db, 'j2', 'plan', 'ADOPTED', '2026-09-25T12:00:00Z');
  ev(db, 'j3', 'preplan', 'ADOPTED', '2026-09-19T08:59:59Z'); // one second before since
  ev(db, 'j8', 'preplan', 'MISS', '2026-09-25T10:00:00Z');
  ev(db, 'j9', 'preplan', 'MISS', '2026-09-25T10:05:00Z');
}

test('A1: p1 aggregates in the window, old and off-contract rows excluded', async (t) => {
  const env = await open(t); if (!env) return;
  seed(env.db);
  const r = await get(env.DB, '/api/preplans/adoption?days=7'); // determinism: ok open() pins Date to NOW_MS via t.mock.timers, so the window is fixed against the fixtures
  assert.equal(r.status, 200, JSON.stringify(r.body));
  const p1 = r.body.projects.find((p) => p.project === 'p1');
  assert.deepEqual(p1, { project: 'p1', adopted: 3, stale: 1, miss: 2, off: 0, bought: 4, rate: 0.75, builds: 6, hit_rate: 0.5 });
  assert.equal(r.body.since, SINCE_7);
  assert.equal(r.body.window_days, 7);
  assert.equal(r.body.as_of, '2026-09-26T09:00:00Z');
});

test('A2: a project with no events in the window is absent', async (t) => {
  const env = await open(t); if (!env) return;
  seed(env.db);
  const r = await get(env.DB, '/api/preplans/adoption');
  assert.deepEqual(r.body.projects.map((p) => p.project), ['p1', 'p3']);
  assert.equal(r.body.days.some((d) => d.project === 'p2'), false);
});

test('A3: nothing bought is rate null, never 0', async (t) => {
  const env = await open(t); if (!env) return;
  seed(env.db);
  const r = await get(env.DB, '/api/preplans/adoption');
  const p3 = r.body.projects.find((p) => p.project === 'p3');
  assert.deepEqual(p3, { project: 'p3', adopted: 0, stale: 0, miss: 2, off: 0, bought: 0, rate: null, builds: 2, hit_rate: 0 });
});

test('A4: per-day rows for p1, sorted by project then day', async (t) => {
  const env = await open(t); if (!env) return;
  seed(env.db);
  const r = await get(env.DB, '/api/preplans/adoption');
  const p1 = r.body.days.filter((d) => d.project === 'p1');
  assert.deepEqual(p1, [
    { project: 'p1', day: '2026-09-23', adopted: 0, stale: 0, miss: 2, off: 0, rate: null, builds: 2, hit_rate: 0 },
    { project: 'p1', day: '2026-09-24', adopted: 1, stale: 1, miss: 0, off: 0, rate: 0.5, builds: 2, hit_rate: 0.5 },
    { project: 'p1', day: '2026-09-25', adopted: 2, stale: 0, miss: 0, off: 0, rate: 1, builds: 2, hit_rate: 1 },
  ]);
  assert.deepEqual(r.body.days.map((d) => d.project), ['p1', 'p1', 'p1', 'p3']);
});

test('A5: ?project filters; a bad name is 400; empty means all', async (t) => {
  const env = await open(t); if (!env) return;
  seed(env.db);
  const r = await get(env.DB, '/api/preplans/adoption?project=p1');
  assert.equal(r.status, 200);
  assert.deepEqual(r.body.projects.map((p) => p.project), ['p1']);
  assert.ok(r.body.recent.every((e) => e.project === 'p1'));
  assert.ok(r.body.days.every((d) => d.project === 'p1'));
  const bad = await get(env.DB, '/api/preplans/adoption?project=bad!name');
  assert.equal(bad.status, 400);
  assert.equal(bad.body.error, 'project must match [A-Za-z0-9._-]{1,64}');
  const empty = await get(env.DB, '/api/preplans/adoption?project=');
  assert.equal(empty.status, 200);
  assert.deepEqual(empty.body.projects.map((p) => p.project), ['p1', 'p3']);
});

test('A6: days outside 1-30 or non-integer is a 400, never clamped; absent is 7', async (t) => {
  const env = await open(t); if (!env) return;
  seed(env.db);
  for (const d of ['0', '31', 'abc', '7.5', '-1', '']) {
    const r = await get(env.DB, `/api/preplans/adoption?days=${d}`); // determinism: ok open() pins Date to NOW_MS via t.mock.timers, so the window is fixed against the fixtures
    assert.equal(r.status, 400, `days=${d} answered ${r.status}`);
    assert.equal(r.body.error, 'days must be an integer 1-30');
  }
  const def = await get(env.DB, '/api/preplans/adoption');
  assert.equal(def.body.window_days, 7);
  const d30 = await get(env.DB, '/api/preplans/adoption?days=30'); // determinism: ok open() pins Date to NOW_MS via t.mock.timers, so the window is fixed against the fixtures
  assert.equal(d30.status, 200);
  assert.equal(d30.body.window_days, 30);
  // the 8-day-old ADOPTED and the one-second-early one are inside 30 days
  assert.equal(d30.body.projects.find((p) => p.project === 'p1').adopted, 5);
  const d1 = await get(env.DB, '/api/preplans/adoption?days=1'); // determinism: ok open() pins Date to NOW_MS via t.mock.timers, so the window is fixed against the fixtures
  assert.equal(d1.body.since, '2026-09-25T09:00:00Z');
  assert.equal(d1.body.projects.find((p) => p.project === 'p1').adopted, 2);
});

test('A7: recent is capped at 50, newest first, and says when it was', async (t) => {
  const env = await open(t); if (!env) return;
  // One job per row: the aggregate counts distinct jobs (A13), so 51 rows on
  // one job would count 2 and this case would stop proving the cap is on
  // `recent` only.
  const at = (i) => new Date(NOW_MS - (i + 1) * 60000).toISOString().replace(/\.\d{3}Z$/, 'Z');
  for (let i = 0; i < 50; i++) { job(env.db, `jx${i}`, 'p1'); ev(env.db, `jx${i}`, 'preplan', 'MISS', at(i)); }
  const fifty = await get(env.DB, '/api/preplans/adoption');
  assert.equal(fifty.body.recent.length, 50);
  assert.equal(fifty.body.recent_truncated, false);
  job(env.db, 'jx', 'p1');
  ev(env.db, 'jx', 'preplan', 'ADOPTED', at(-0.5)); // the 51st, and the newest
  const r = await get(env.DB, '/api/preplans/adoption');
  assert.equal(r.body.recent.length, 50);
  assert.equal(r.body.recent_truncated, true);
  assert.equal(r.body.recent[0].verdict, 'ADOPTED');
  assert.equal(r.body.recent[0].created_at, at(-0.5));
  assert.deepEqual(Object.keys(r.body.recent[0]).sort(),
    ['created_at', 'detail', 'job_id', 'project', 'ticket_id', 'verdict']);
  assert.equal(r.body.recent[0].ticket_id, 'T-jx');
  const times = r.body.recent.map((e) => e.created_at);
  assert.deepEqual(times, [...times].sort().reverse());
  // the aggregate still counts all 51, whatever recent holds
  assert.equal(r.body.projects[0].miss + r.body.projects[0].adopted, 51);
});

test('A8: off-contract verdicts, other stages and pre-window rows are never counted', async (t) => {
  const env = await open(t); if (!env) return;
  seed(env.db);
  const r = await get(env.DB, '/api/preplans/adoption');
  assert.equal(r.body.recent.some((e) => e.verdict === 'APPROVE' || e.verdict === null), false);
  assert.equal(r.body.recent.some((e) => e.created_at === '2026-09-19T08:59:59Z'), false);
  assert.equal(r.body.recent.filter((e) => e.job_id === 'j2').length, 1, 'the stage=plan row leaked into recent');
  assert.equal(r.body.recent.length, 8);
});

test('A9: EXPLAIN QUERY PLAN on the shipped SQL uses idx_events_stage_created', async (t) => {
  const env = await open(t); if (!env) return;
  for (const [name, sql] of [['counts', ADOPTION_COUNTS_SQL], ['recent', ADOPTION_RECENT_SQL]]) {
    for (const project of [null, 'p1']) {
      const plan = env.db.prepare(`EXPLAIN QUERY PLAN ${sql}`).all(SINCE_7, project);
      const text = plan.map((p) => p.detail).join(' | ');
      assert.match(text, /idx_events_stage_created/, `${name} project=${project}: ${text}`);
    }
  }
});

test('A10: the response key set is exactly the contract', async (t) => {
  const env = await open(t); if (!env) return;
  const r = await get(env.DB, '/api/preplans/adoption');
  assert.equal(r.status, 200);
  assert.deepEqual(Object.keys(r.body).sort(),
    ['as_of', 'days', 'projects', 'recent', 'recent_truncated', 'since', 'window_days']);
  assert.deepEqual(r.body.projects, []);
  assert.deepEqual(r.body.days, []);
  assert.deepEqual(r.body.recent, []);
  assert.equal(r.body.recent_truncated, false);
});

test('A11: no bearer, no numbers', async (t) => {
  const env = await open(t); if (!env) return;
  const r = await get(env.DB, '/api/preplans/adoption', { secret: null });
  assert.equal(r.status, 401);
});

test('A12: GET /api/preplans?project= still answers its own index', async (t) => {
  const env = await open(t); if (!env) return;
  seed(env.db);
  const r = await get(env.DB, '/api/preplans?project=p1');
  assert.equal(r.status, 200, JSON.stringify(r.body));
  assert.deepEqual(Object.keys(r.body).sort(), ['as_of', 'preplans']);
  assert.deepEqual(r.body.preplans, []);
});

test('A13: a POST retried by jobs/req.sh (two rows, one job) counts once', async (t) => {
  const env = await open(t); if (!env) return;
  seed(env.db);
  // j1's ADOPTED, j4's STALE and j5's MISS each landed twice: the first POST
  // reached D1 but its reply was lost, so bin/lib/jobs/req.sh sent it again.
  ev(env.db, 'j1', 'preplan', 'ADOPTED', '2026-09-25T10:00:03Z', 'fresh against abc');
  ev(env.db, 'j4', 'preplan', 'STALE', '2026-09-24T12:00:02Z', 'thread moved');
  ev(env.db, 'j5', 'preplan', 'MISS', '2026-09-23T10:00:01Z');
  const r = await get(env.DB, '/api/preplans/adoption');
  const p1 = r.body.projects.find((p) => p.project === 'p1');
  assert.deepEqual(p1, { project: 'p1', adopted: 3, stale: 1, miss: 2, off: 0, bought: 4, rate: 0.75, builds: 6, hit_rate: 0.5 });
  const d24 = r.body.days.find((d) => d.project === 'p1' && d.day === '2026-09-24');
  assert.deepEqual(d24, { project: 'p1', day: '2026-09-24', adopted: 1, stale: 1, miss: 0, off: 0, rate: 0.5, builds: 2, hit_rate: 0.5 });
});
