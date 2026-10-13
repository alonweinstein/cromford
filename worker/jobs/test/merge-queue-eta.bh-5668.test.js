// BH-5668 (BH-5008 child 2): check-duration medians, batch progress and ETA.
// The pure ETA functions are driven directly. The medians writer and the live
// route go through the REAL worker.fetch, signed, onto the REAL schema.sql in
// node:sqlite, with the #5667 fixture's deliveries.
//
// determinism: ok-file clock-pinned setup() pins Date to NOW_MS with t.mock.timers, so the route's as_of (nowIso) is NOW and every elapsed time below is exact
import test from 'node:test';
import assert from 'node:assert/strict';
import worker from '../src/index.js';
import { openDb } from './lib/d1-sqlite.bh-1030.js';
import {
  REPO, SECRET, DRAFT, deliveries, sendDelivery, checkDelivery, CHECK_NAMES, COMPLETED,
} from './fixtures/merge-queue-bh-5008.js';
import { jobClass } from '../src/lib/merge-queue-stage.js';
import { batchEta, classMedians, expectedOf } from '../src/lib/merge-queue-eta.js';

const NOW = '2026-10-09T03:10:00Z';
const NOW_MS = Date.parse(NOW);
const SETTING_AT = '2026-10-09T00:00:00Z';
const ago = (s) => new Date(NOW_MS - s * 1000).toISOString().replace(/\.\d{3}Z$/, 'Z');
const round3 = (x) => Math.round(x * 1000) / 1000;

function txBatch(db) {
  return async (stmts) => {
    db.exec('BEGIN');
    try {
      const out = [];
      for (const s of stmts) out.push(await s.run());
      db.exec('COMMIT');
      return out;
    } catch (e) {
      db.exec('ROLLBACK');
      throw e;
    }
  };
}

async function setup(t) {
  t.mock.timers.enable({ apis: ['Date'], now: NOW_MS });
  const o = await openDb();
  if (!o) { t.skip('node:sqlite unavailable'); return null; }
  o.DB.batch = txBatch(o.db);
  const setSetting = (k, v) => o.db.prepare(`INSERT OR REPLACE INTO settings (key,value,note,actor,updated_at) VALUES (?,?,?,?,?)`)
    .run(k, v, 'test', 'test', SETTING_AT);
  setSetting('merge_queue_repos', REPO);
  const env = { DB: o.DB, HARNESS_SECRET: 'bearer', GITHUB_WEBHOOK_SECRET: SECRET };
  const get = async (path) => {
    const res = await worker.fetch(new Request(`https://jobs.test${path}`, { headers: { authorization: 'Bearer bearer' } }), env);
    return { status: res.status, body: await res.json().catch(() => null) };
  };
  const medianRow = (name) => {
    const r = o.db.prepare(`SELECT * FROM merge_queue_check_medians WHERE repo=? AND name=?`).get(REPO, name);
    return r ? { ...r } : null;
  };
  return { ...o, env, get, setSetting, medianRow };
}

// One green (or red) completion of check `name` on its own batch draft, so N
// runs are N check rows. Run i starts at base + i min and lasts `dur` s.
const BASE_MS = Date.parse('2026-10-08T00:00:00Z');
const isoAt = (ms) => new Date(ms).toISOString().replace(/\.\d{3}Z$/, 'Z');
function run(i, dur, { name = 'build', conclusion = 'success' } = {}) {
  const start = BASE_MS + i * 60000;
  return checkDelivery(`e-${name}-${i}-${conclusion}`, {
    name, action: 'completed', status: 'completed', conclusion,
    ref: `mergify/merge-queue/e5-${i}`, draft: 7000 + i,
    started_at: isoAt(start), completed_at: isoAt(start + dur * 1000),
  });
}

function stubFetch() {
  const real = globalThis.fetch;
  const calls = [];
  globalThis.fetch = async (...a) => { calls.push(a); throw new Error('no network in this test'); };
  return { calls, restore: () => { globalThis.fetch = real; } };
}

// ── pure ETA ────────────────────────────────────────────────────────────────
test('E1 name medians: eta = sum of (median - elapsed) over open checks, progress weighted by median', () => {
  const checks = [
    { name: 'A', job_class: 'A', status: 'completed', started_at: ago(600) },
    { name: 'B', job_class: 'B', status: 'in_progress', started_at: ago(200) },
  ];
  const medians = [{ name: 'A', job_class: 'A', median_s: 300 }, { name: 'B', job_class: 'B', median_s: 600 }];
  assert.deepEqual(batchEta(checks, medians, NOW_MS), { progress: 0.333, eta_s: 400, eta_basis: 'name' });
});

test('E1 a check past its median adds 0, never a negative', () => {
  const checks = [{ name: 'B', job_class: 'B', status: 'in_progress', started_at: ago(900) }];
  const r = batchEta(checks, [{ name: 'B', job_class: 'B', median_s: 600 }], NOW_MS);
  assert.equal(r.eta_s, 0);
  assert.equal(r.eta_basis, 'name');
});

test('E2 class fallback: a shard with no name row uses its job_class median', () => {
  const name = 'Tests, traced (shard 7/8)';
  assert.equal(jobClass(name), 'Tests, traced');
  const medians = [
    { name: 'Tests, traced (shard 1/8)', job_class: 'Tests, traced', median_s: 400 },
    { name: 'Tests, traced (shard 2/8)', job_class: 'Tests, traced', median_s: 560 },
  ];
  assert.equal(classMedians(medians).get('Tests, traced'), 480);
  const byName = new Map(medians.map((m) => [m.name, m.median_s]));
  assert.deepEqual(expectedOf(name, 'Tests, traced', byName, classMedians(medians)), { s: 480, source: 'class' });
  const r = batchEta([{ name, job_class: 'Tests, traced', status: 'queued', started_at: null }], medians, NOW_MS);
  assert.deepEqual(r, { progress: 0, eta_s: 480, eta_basis: 'class' });
});

test('E3 neither a name nor a class median: eta_s null, basis partial, progress still a number', () => {
  const checks = [
    { name: 'A', job_class: 'A', status: 'completed', started_at: ago(600) },
    { name: 'new', job_class: 'new', status: 'in_progress', started_at: ago(10) },
  ];
  const r = batchEta(checks, [{ name: 'A', job_class: 'A', median_s: 300 }], NOW_MS);
  assert.equal(r.eta_s, null);
  assert.equal(r.eta_basis, 'partial');
  assert.equal(typeof r.progress, 'number');
  assert.ok(r.progress >= 0 && r.progress <= 1);
  assert.equal(r.progress, 0.5, 'the unknown check weighs the mean of the known weights (300)');
});

test('E3 a median of 0 counts as missing, never as a 0 s estimate', () => {
  const r = batchEta([{ name: 'z', job_class: 'z', status: 'queued' }], [{ name: 'z', job_class: 'z', median_s: 0 }], NOW_MS);
  assert.deepEqual([r.eta_s, r.eta_basis], [null, 'partial']);
});

test('E4 equal share: an unknown weight is the mean of the known weights; none known = done/total', () => {
  const medians = [{ name: 'A', job_class: 'A', median_s: 300 }, { name: 'B', job_class: 'B', median_s: 600 }];
  const checks = [
    { name: 'A', job_class: 'A', status: 'queued' },
    { name: 'B', job_class: 'B', status: 'queued' },
    { name: 'U', job_class: 'U', status: 'completed' },
  ];
  assert.equal(batchEta(checks, medians, NOW_MS).progress, round3(450 / 1350));
  const none = [
    { name: 'x', job_class: 'x', status: 'completed' },
    { name: 'y', job_class: 'y', status: 'queued' },
    { name: 'z', job_class: 'z', status: 'queued' },
    { name: 'w', job_class: 'w', status: 'queued' },
  ];
  assert.equal(batchEta(none, [], NOW_MS).progress, 0.25);
});

test('E4 finished batch is done (eta 0 is a fact); a batch with no checks has no estimate', () => {
  assert.deepEqual(batchEta([], [], NOW_MS, { finished: true }), { progress: 1, eta_s: 0, eta_basis: 'done' });
  assert.deepEqual(batchEta([], [], NOW_MS), { progress: 0, eta_s: null, eta_basis: 'partial' });
});

// ── medians writer, through the real webhook ────────────────────────────────
test('E5 31 green runs: the median is over the newest 30; a failure after them writes nothing', async (t) => {
  const c = await setup(t); if (!c) return;
  for (let i = 1; i <= 31; i++) {
    const r = await sendDelivery(worker, c.env, run(i, i));
    assert.equal(r.status, 200, `run ${i}: ${JSON.stringify(r.body)}`);
  }
  const row = c.medianRow('build');
  assert.ok(row, 'a green completion writes the median row');
  assert.equal(row.samples, 30);
  assert.equal(row.median_s, 17, 'median of 2..31 is 16.5, rounded');
  assert.equal(row.job_class, 'build');
  const fail = await sendDelivery(worker, c.env, run(40, 9999, { conclusion: 'failure' }));
  assert.equal(fail.status, 200);
  assert.deepEqual(c.medianRow('build'), row, 'a failed completion does not touch the median row');
  assert.deepEqual(fail.body.queue, { rows: 1 }, 'only the check row changed');
});

test('E5 an in-progress check and a cancelled completion write no median', async (t) => {
  const c = await setup(t); if (!c) return;
  await sendDelivery(worker, c.env, run(1, 30, { conclusion: 'cancelled' }));
  await sendDelivery(worker, c.env, checkDelivery('e-created', { name: 'build', ref: 'mergify/merge-queue/e5-2', draft: 7002 }));
  assert.equal(c.medianRow('build'), null);
});

test('E5 a shard writes its own row with the job_class from jobClass', async (t) => {
  const c = await setup(t); if (!c) return;
  await sendDelivery(worker, c.env, run(1, 120, { name: 'tests (3)' }));
  const row = c.medianRow('tests (3)');
  assert.deepEqual([row.job_class, row.median_s, row.samples], ['tests', 120, 1]);
});

test('E6 the same green completion twice gives a byte-identical median row and 0 changed rows', async (t) => {
  const c = await setup(t); if (!c) return;
  for (let i = 1; i <= 4; i++) await sendDelivery(worker, c.env, run(i, i * 10));
  const first = c.medianRow('build');
  assert.deepEqual([first.median_s, first.samples], [25, 4]);
  const again = await sendDelivery(worker, c.env, run(4, 40));
  assert.equal(again.body.duplicate, true);
  // A completion is wake-bearing: its answer names `queue` only when a row changed.
  assert.equal(again.body.queue, undefined, 'the replay changed no queue row');
  assert.deepEqual(c.medianRow('build'), first);
  const fresh = await sendDelivery(worker, c.env, run(4, 40), { id: 'e-build-4-new-id' });
  assert.equal(fresh.body.queue, undefined, 'a new delivery id with the same payload changed no queue row');
  assert.deepEqual(c.medianRow('build'), first);
});

test('E7 the merge_queue_median_window settings row sets the sample window', async (t) => {
  const c = await setup(t); if (!c) return;
  for (let i = 1; i <= 8; i++) await sendDelivery(worker, c.env, run(i, i));
  assert.equal(c.medianRow('build').samples, 8);
  c.setSetting('merge_queue_median_window', '5');
  await sendDelivery(worker, c.env, run(9, 9));
  const row = c.medianRow('build');
  assert.equal(row.samples, 5);
  assert.equal(row.median_s, 7, 'median of 5..9');
});

// ── the live route, the observable outcome ──────────────────────────────────
// Seeded name medians for the 14 fixture checks: 100, 200, ..., 1400 s.
const SEEDED = new Map(CHECK_NAMES.map((n, i) => [n, (i + 1) * 100]));
function seedMedians(c) {
  for (const [name, m] of SEEDED) {
    c.db.prepare(`INSERT OR REPLACE INTO merge_queue_check_medians (repo,name,job_class,median_s,samples,updated_at) VALUES (?,?,?,?,?,?)`)
      .run(REPO, name, jobClass(name), m, 10, SETTING_AT);
  }
}

test('E8 GET /api/merge-queue/live: weighted progress and a non-null eta from D1 only', async (t) => {
  const c = await setup(t); if (!c) return;
  const f = stubFetch();
  try {
    for (const d of deliveries) assert.equal((await sendDelivery(worker, c.env, d)).status, 200);
    // The intake wrote medians for the 9 green completions (480 s each).
    assert.equal(c.medianRow('lint').median_s, 480);
    assert.equal(c.medianRow('Jobs worker'), null, 'the failed check has no median');
    seedMedians(c);
    const r = await c.get('/api/merge-queue/live');
    assert.equal(r.status, 200);
    assert.equal(r.body.as_of, NOW);
    const b = r.body.batches.find((x) => x.draft === DRAFT);
    assert.deepEqual(b.checks, { done: 10, total: 14 });
    const all = [...SEEDED.values()].reduce((a, x) => a + x, 0);
    const done = COMPLETED.reduce((a, n) => a + SEEDED.get(n), 0);
    assert.equal(b.progress, round3(done / all));
    assert.notEqual(b.progress, round3(10 / 14));
    // The fixture starts every check at 03:01:00; NOW is 03:10:00, so 540 s.
    const open = CHECK_NAMES.filter((n) => !COMPLETED.includes(n));
    const want = open.reduce((a, n) => a + Math.max(0, SEEDED.get(n) - 540), 0);
    assert.equal(want, 2840);
    assert.equal(b.eta_s, want);
    assert.equal(b.eta_basis, 'name');
    // stage and failing are child 3's (BH-5669): the failed check names them.
    assert.equal(b.stage, 'failing');
    assert.deepEqual(b.failing, { name: 'Jobs worker', url: `https://github.com/${REPO}/actions/runs/7001/job/${8000 + DRAFT}` });
    const empty = r.body.batches.find((x) => x.draft === 9002);
    assert.deepEqual([empty.progress, empty.eta_s, empty.eta_basis], [0, null, 'partial']);
    assert.equal(f.calls.length, 0, 'no network call');
  } finally { f.restore(); }
});

test('E9 an open check with no name and no class median makes the batch partial', async (t) => {
  const c = await setup(t); if (!c) return;
  for (const d of deliveries) await sendDelivery(worker, c.env, d);
  seedMedians(c);
  c.db.prepare(`DELETE FROM merge_queue_check_medians WHERE repo=? AND job_class='tests'`).run(REPO);
  const r = await c.get('/api/merge-queue/live');
  const b = r.body.batches.find((x) => x.draft === DRAFT);
  assert.equal(b.eta_s, null);
  assert.equal(b.eta_basis, 'partial');
  assert.equal(typeof b.progress, 'number');
});

test('E9 a finished batch inside the window answers done: progress 1, eta 0', async (t) => {
  const c = await setup(t); if (!c) return;
  for (const d of deliveries) await sendDelivery(worker, c.env, d);
  c.db.prepare(`UPDATE merge_queue_batches SET finished_at=?, outcome='merged' WHERE draft_pr=?`).run(ago(60), DRAFT);
  const r = await c.get('/api/merge-queue/live');
  const b = r.body.batches.find((x) => x.draft === DRAFT);
  assert.deepEqual([b.progress, b.eta_s, b.eta_basis], [1, 0, 'done']);
});
