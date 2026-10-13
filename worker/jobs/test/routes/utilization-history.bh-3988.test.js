import test from 'node:test';
import assert from 'node:assert/strict';
import worker from '../../src/index.js';
import { openDb } from '../lib/d1-sqlite.bh-1030.js';

// BH-4012 (BH-3988.4) — the history form of GET /api/utilization:
// `?project=<p>&since=<iso>` answers that project's rows with hour >= since,
// ascending, capped at 500 with an explicit `truncated` flag. Its one reader is
// utilization_rows (bin/lib/jobs/utilization.sh), called by the went-quiet lane
// bin/utilization-quiet.sh.
//
// Driven through the real worker.fetch (D2) over the real schema.sql in
// node:sqlite, the same way as utilization.bh-3988.test.js.

// determinism: ok-file clock-rolling-window open() mocks Date to the fixed NOW_MS for every test and each since= is a literal or hoursAgo() off that same fixed 18:00Z anchor, so no window moves with the wall clock
const SECRET = 'test-secret';
const NOW_MS = Date.parse('2026-10-03T18:07:00Z');
const HOUR_MS = 3600000;

async function open(t) {
  t.mock.timers.enable({ apis: ['Date'], now: NOW_MS });
  const env = await openDb();
  if (!env) t.skip('node:sqlite unavailable on this runtime');
  return env;
}

async function get(DB, q = '') {
  const res = await worker.fetch(new Request(`https://jobs.test/api/utilization${q}`, {
    method: 'GET', headers: { authorization: `Bearer ${SECRET}` },
  }), { DB, HARNESS_SECRET: SECRET });
  return { status: res.status, body: await res.json() };
}

// The hour pattern `h` hours before the mocked now's hour (18:00Z).
const hoursAgo = (h) => new Date(Date.parse('2026-10-03T18:00:00Z') - h * HOUR_MS).toISOString().replace(/\.\d{3}Z$/, 'Z');
const seed = (db, project, hour) => db.prepare(
  "INSERT INTO utilization_snapshots (project, hour, verdict, payload, box, as_of) VALUES (?, ?, 'starved', ?, 'seed', '2026-01-01T00:00:00Z')"
).run(project, hour, JSON.stringify({ tickets: { ready: 0 }, builds: { free_slots: 2 } }));
const q = (project, since) => `?project=${encodeURIComponent(project)}&since=${encodeURIComponent(since)}`;

test('H-SINCE: only that project, hour >= since, the boundary row included', async (t) => {
  const env = await open(t); if (!env) return;
  for (const h of [100, 72, 1]) seed(env.db, 'acme', hoursAgo(h));
  for (const h of [50, 2]) seed(env.db, 'beta', hoursAgo(h));
  const r = await get(env.DB, q('acme', hoursAgo(72)));
  assert.equal(r.status, 200, JSON.stringify(r.body));
  assert.deepEqual(r.body.rows.map((x) => [x.project, x.hour]), [['acme', hoursAgo(72)], ['acme', hoursAgo(1)]]);
  assert.equal(r.body.truncated, false);
  assert.equal(r.body.as_of, '2026-10-03T18:07:00Z');
  assert.deepEqual(r.body.rows[0].payload, { tickets: { ready: 0 }, builds: { free_slots: 2 } });
  assert.equal(r.body.rows[0].verdict, 'starved');
});

test('H-ORDER: rows seeded out of order come back ascending by hour', async (t) => {
  const env = await open(t); if (!env) return;
  for (const h of [3, 10, 1, 7, 5]) seed(env.db, 'acme', hoursAgo(h));
  const r = await get(env.DB, q('acme', hoursAgo(24)));
  assert.equal(r.status, 200, JSON.stringify(r.body));
  assert.deepEqual(r.body.rows.map((x) => x.hour), [10, 7, 5, 3, 1].map(hoursAgo));
});

test('H-CAP: 501 rows answer the oldest 500 and truncated:true; 500 rows are truncated:false', async (t) => {
  const env = await open(t); if (!env) return;
  for (let h = 0; h < 501; h++) seed(env.db, 'acme', hoursAgo(h));
  const r = await get(env.DB, q('acme', hoursAgo(1000)));
  assert.equal(r.status, 200, JSON.stringify(r.body).slice(0, 300));
  assert.equal(r.body.rows.length, 500);
  assert.equal(r.body.truncated, true);
  assert.equal(r.body.rows[0].hour, hoursAgo(500));
  assert.equal(r.body.rows[499].hour, hoursAgo(1));

  env.db.prepare("DELETE FROM utilization_snapshots WHERE hour = ?").run(hoursAgo(0));
  const r2 = await get(env.DB, q('acme', hoursAgo(1000)));
  assert.equal(r2.body.rows.length, 500);
  assert.equal(r2.body.truncated, false);
});

test('H-NORMALISE: a since with minutes and ms compares exactly against stored hours', async (t) => {
  const env = await open(t); if (!env) return;
  seed(env.db, 'acme', '2026-10-03T10:00:00Z');
  seed(env.db, 'acme', '2026-10-03T11:00:00Z');
  const r = await get(env.DB, q('acme', '2026-10-03T10:30:00.000Z'));
  assert.equal(r.status, 200, JSON.stringify(r.body));
  assert.deepEqual(r.body.rows.map((x) => x.hour), ['2026-10-03T11:00:00Z']);
  // An offset form parses to the same instant.
  const r2 = await get(env.DB, q('acme', '2026-10-03T12:00:00+02:00'));
  assert.deepEqual(r2.body.rows.map((x) => x.hour), ['2026-10-03T10:00:00Z', '2026-10-03T11:00:00Z']);
});

test('H-400: one param alone, an empty project and a bad since are 400', async (t) => {
  const env = await open(t); if (!env) return;
  seed(env.db, 'acme', hoursAgo(1));
  const both = 'project and since are both required for the history form';
  for (const [query, error] of [
    ['?project=acme', both],
    [`?since=${encodeURIComponent(hoursAgo(5))}`, both],
    [`?project=&since=${encodeURIComponent(hoursAgo(5))}`, both],
    [`?project=%20%20&since=${encodeURIComponent(hoursAgo(5))}`, both],
    ['?project=acme&since=garbage', 'since must be an ISO timestamp'],
    ['?project=acme&since=', both],
  ]) {
    const r = await get(env.DB, query);
    assert.equal(r.status, 400, `${query}: ${JSON.stringify(r.body)}`);
    assert.equal(r.body.error, error, query);
  }
});

test('H-EMPTY: a project with no rows in range is 200 rows:[] truncated:false', async (t) => {
  const env = await open(t); if (!env) return;
  seed(env.db, 'acme', hoursAgo(100));
  const r = await get(env.DB, q('acme', hoursAgo(72)));
  assert.equal(r.status, 200, JSON.stringify(r.body));
  assert.deepEqual(r.body.rows, []);
  assert.equal(r.body.truncated, false);
});

test('H-503: an unapplied table answers 503 naming it on the history form', async (t) => {
  const env = await open(t); if (!env) return;
  env.db.exec('DROP TABLE utilization_snapshots');
  const r = await get(env.DB, q('acme', hoursAgo(72)));
  assert.equal(r.status, 503, JSON.stringify(r.body));
  assert.equal(r.body.error, 'utilization_snapshots schema not applied');
});

test('H-BARE: with no params GET still answers the newest row per project and no truncated key', async (t) => {
  const env = await open(t); if (!env) return;
  for (const h of [3, 2, 1]) { seed(env.db, 'acme', hoursAgo(h)); seed(env.db, 'beta', hoursAgo(h + 1)); }
  const r = await get(env.DB);
  assert.equal(r.status, 200, JSON.stringify(r.body));
  assert.deepEqual(r.body.rows.map((x) => [x.project, x.hour]), [['acme', hoursAgo(1)], ['beta', hoursAgo(2)]]);
  assert.equal('truncated' in r.body, false);
  assert.deepEqual(Object.keys(r.body).sort(), ['as_of', 'rows']);
});
