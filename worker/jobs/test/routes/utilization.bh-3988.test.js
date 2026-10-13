import test from 'node:test';
import assert from 'node:assert/strict';
import worker from '../../src/index.js';
import { openDb } from '../lib/d1-sqlite.bh-1030.js';

// BH-4008 (BH-3988 tracer) — PUT/GET /api/utilization, one row per (project,
// hour) that bin/utilization-push.sh writes through utilization_put
// (bin/lib/jobs/utilization.sh).
//
// Driven through the real worker.fetch (D2) over the real schema.sql in
// node:sqlite, so the route table, the bearer, body parsing, the upsert and the
// prune are what run. Deleting the ROUTES spread in src/index.js turns every
// case here into the router's 404.

const SECRET = 'test-secret';
const NOW_MS = Date.parse('2026-10-03T18:07:00Z');
const DAY_MS = 86400000;

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

const put = (DB, b, o) => call(DB, 'PUT', '/api/utilization', b, o);
const get = (DB, q = '') => call(DB, 'GET', `/api/utilization${q}`);
const count = (db) => db.prepare('SELECT COUNT(*) AS n FROM utilization_snapshots').get().n;
// The hour pattern for a moment `ms` before the mocked now.
const hourAgo = (ms) => new Date(NOW_MS - ms).toISOString().replace(/:\d\d:\d\d\.\d{3}Z$/, ':00:00Z');
const seed = (db, project, hour, payload = '{"builds":{}}') => db.prepare(
  "INSERT INTO utilization_snapshots (project, hour, verdict, payload, box, as_of) VALUES (?, ?, 'unknown', ?, 'seed', '2026-01-01T00:00:00Z')"
).run(project, hour, payload);
const good = (over = {}) => ({
  project: 'acme', hour: '2026-10-03T18:00:00Z', verdict: 'unknown',
  payload: { builds: { running: 1, pool_cap: 3, free_slots: 2 } }, box: 'hub', ...over,
});

test('U-400-project: an empty or missing project is 400 and writes nothing', async (t) => {
  const env = await open(t); if (!env) return;
  for (const project of ['', '   ', undefined]) {
    const r = await put(env.DB, good({ project }));
    assert.equal(r.status, 400, JSON.stringify(r.body));
    assert.equal(r.body.error, 'project required');
  }
  assert.equal(count(env.db), 0);
});

test('U-400-hour: a non-hour timestamp, a bare date and a missing hour are 400', async (t) => {
  const env = await open(t); if (!env) return;
  for (const hour of ['2026-10-03T18:30:00Z', '2026-10-03', undefined, '2026-10-03T18:00:00.000Z']) {
    const r = await put(env.DB, good({ hour }));
    assert.equal(r.status, 400, `hour ${hour}: ${JSON.stringify(r.body)}`);
    assert.match(r.body.error, /hour/);
  }
  assert.equal(count(env.db), 0);
});

test('U-400-verdict: a verdict outside the enum is 400', async (t) => {
  const env = await open(t); if (!env) return;
  for (const verdict of ['idle', 'Unknown', undefined]) {
    const r = await put(env.DB, good({ verdict }));
    assert.equal(r.status, 400, `verdict ${verdict}: ${JSON.stringify(r.body)}`);
    assert.match(r.body.error, /verdict/);
  }
  assert.equal(count(env.db), 0);
  for (const verdict of ['starved', 'paused', 'blocked', 'saturated', 'busy', 'unknown']) {
    const r = await put(env.DB, good({ verdict, project: `p-${verdict}` }));
    assert.equal(r.status, 200, `verdict ${verdict}: ${JSON.stringify(r.body)}`);
  }
  assert.equal(count(env.db), 6);
});

test('U-400-payload: null, [], "x" and a 9000-byte object are 400 and write nothing', async (t) => {
  const env = await open(t); if (!env) return;
  for (const payload of [null, [], 'x', 42, undefined, { k: 'a'.repeat(9000) }]) {
    const r = await put(env.DB, good({ payload }));
    assert.equal(r.status, 400, `payload ${JSON.stringify(payload)?.slice(0, 40)}: ${JSON.stringify(r.body)}`);
    assert.match(r.body.error, /payload/);
  }
  assert.equal(count(env.db), 0);
});

test('U-UPSERT: a second PUT for the same (project, hour) replaces the first, as_of is its time', async (t) => {
  const env = await open(t); if (!env) return;
  const first = await put(env.DB, good({ payload: { builds: { running: 1 } } }));
  assert.equal(first.status, 200, JSON.stringify(first.body));
  assert.equal(first.body.row.as_of, '2026-10-03T18:07:00Z');
  t.mock.timers.tick(60000);
  const second = await put(env.DB, good({ payload: { builds: { running: 2 } }, box: 'other' }));
  assert.equal(second.status, 200, JSON.stringify(second.body));
  assert.equal(second.body.ok, true);
  assert.deepEqual(second.body.row, {
    project: 'acme', hour: '2026-10-03T18:00:00Z', verdict: 'unknown',
    payload: { builds: { running: 2 } }, box: 'other', as_of: '2026-10-03T18:08:00Z',
  });
  assert.equal(count(env.db), 1);
  const row = env.db.prepare('SELECT payload, box, as_of FROM utilization_snapshots').get();
  assert.deepEqual(JSON.parse(row.payload), { builds: { running: 2 } });
  assert.equal(row.box, 'other');
  assert.equal(row.as_of, '2026-10-03T18:08:00Z');
});

test('U-PRUNE: the default 35-day retention prunes only the putting project', async (t) => {
  const env = await open(t); if (!env) return;
  const a40 = hourAgo(40 * DAY_MS), a10 = hourAgo(10 * DAY_MS), b40 = hourAgo(40 * DAY_MS);
  seed(env.db, 'acme', a40);
  seed(env.db, 'acme', a10);
  seed(env.db, 'beta', b40);
  const r = await put(env.DB, good());
  assert.equal(r.status, 200, JSON.stringify(r.body));
  assert.equal(r.body.pruned, 1);
  const left = env.db.prepare('SELECT project, hour FROM utilization_snapshots ORDER BY project, hour').all()
    .map((x) => `${x.project} ${x.hour}`);
  assert.deepEqual(left, [`acme ${a10}`, 'acme 2026-10-03T18:00:00Z', `beta ${b40}`]);
});

test('U-CLAMP: retention_days clamps to 7..90, and a non-number is 400', async (t) => {
  const env = await open(t); if (!env) return;
  seed(env.db, 'acme', hourAgo(8 * DAY_MS));
  seed(env.db, 'acme', hourAgo(6 * DAY_MS));
  const lo = await put(env.DB, good({ retention_days: 1 }));
  assert.equal(lo.status, 200, JSON.stringify(lo.body));
  assert.equal(lo.body.pruned, 1, 'retention 1 acts as 7: the 8-day row goes, the 6-day row stays');
  assert.deepEqual(env.db.prepare("SELECT hour FROM utilization_snapshots WHERE project='acme' ORDER BY hour").all().map((x) => x.hour),
    [hourAgo(6 * DAY_MS), '2026-10-03T18:00:00Z']);

  seed(env.db, 'beta', hourAgo(89 * DAY_MS));
  seed(env.db, 'beta', hourAgo(91 * DAY_MS));
  const hi = await put(env.DB, good({ project: 'beta', retention_days: 500 }));
  assert.equal(hi.status, 200, JSON.stringify(hi.body));
  assert.equal(hi.body.pruned, 1, 'retention 500 acts as 90');
  assert.deepEqual(env.db.prepare("SELECT hour FROM utilization_snapshots WHERE project='beta' ORDER BY hour").all().map((x) => x.hour),
    [hourAgo(89 * DAY_MS), '2026-10-03T18:00:00Z']);

  const before = count(env.db);
  for (const retention_days of ['x', null, {}, '']) {
    const bad = await put(env.DB, good({ project: 'gamma', retention_days }));
    assert.equal(bad.status, 400, `retention ${JSON.stringify(retention_days)}: ${JSON.stringify(bad.body)}`);
    assert.match(bad.body.error, /retention_days/);
  }
  assert.equal(count(env.db), before);
});

test('U-NEWEST: GET answers exactly the newest row per project, payload parsed', async (t) => {
  const env = await open(t); if (!env) return;
  for (const p of ['acme', 'beta']) {
    for (const h of ['16', '17', '18']) {
      const r = await put(env.DB, good({ project: p, hour: `2026-10-03T${h}:00:00Z`, payload: { h, p } }));
      assert.equal(r.status, 200, JSON.stringify(r.body));
    }
  }
  assert.equal(count(env.db), 6);
  const r = await get(env.DB);
  assert.equal(r.status, 200, JSON.stringify(r.body));
  assert.equal(r.body.as_of, '2026-10-03T18:07:00Z');
  assert.equal(r.body.rows.length, 2);
  assert.deepEqual(r.body.rows.map((x) => [x.project, x.hour, x.verdict, x.box]),
    [['acme', '2026-10-03T18:00:00Z', 'unknown', 'hub'], ['beta', '2026-10-03T18:00:00Z', 'unknown', 'hub']]);
  assert.deepEqual(r.body.rows[1].payload, { h: '18', p: 'beta' });
  // The history query form (BH-4012) filters: acme's rows only, ascending.
  const q = await get(env.DB, '?project=acme&since=2026-10-01T00:00:00Z');
  assert.equal(q.status, 200);
  assert.deepEqual(q.body.rows.map((x) => [x.project, x.hour]),
    ['16', '17', '18'].map((h) => ['acme', `2026-10-03T${h}:00:00Z`]));
  assert.equal(q.body.truncated, false);
});

test('U-EMPTY: GET on an empty table is 200 with no rows', async (t) => {
  const env = await open(t); if (!env) return;
  const r = await get(env.DB);
  assert.equal(r.status, 200, JSON.stringify(r.body));
  assert.deepEqual(r.body.rows, []);
});

test('U-UNPARSE: a stored payload that does not parse is flagged, not dropped', async (t) => {
  const env = await open(t); if (!env) return;
  seed(env.db, 'acme', '2026-10-03T18:00:00Z', '{');
  const r = await get(env.DB);
  assert.equal(r.status, 200, JSON.stringify(r.body));
  assert.equal(r.body.rows.length, 1);
  assert.equal(r.body.rows[0].payload, null);
  assert.equal(r.body.rows[0].payload_error, 'unparseable');
});

test('U-503: an unapplied table answers 503 naming it, on both verbs', async (t) => {
  const env = await open(t); if (!env) return;
  env.db.exec('DROP TABLE utilization_snapshots');
  const p = await put(env.DB, good());
  assert.equal(p.status, 503, JSON.stringify(p.body));
  assert.equal(p.body.error, 'utilization_snapshots schema not applied');
  const g = await get(env.DB);
  assert.equal(g.status, 503, JSON.stringify(g.body));
  assert.equal(g.body.error, 'utilization_snapshots schema not applied');
});

test('U-AUTH: the routes sit behind the bearer', async (t) => {
  const env = await open(t); if (!env) return;
  const none = await put(env.DB, good(), { secret: null });
  assert.equal(none.status, 401, JSON.stringify(none.body));
  const wrong = await put(env.DB, good(), { secret: 'nope' });
  assert.equal(wrong.status, 401);
  assert.equal(count(env.db), 0);
  const g = await call(env.DB, 'GET', '/api/utilization', undefined, { secret: null });
  assert.equal(g.status, 401);
  const ok = await put(env.DB, good());
  assert.equal(ok.status, 200, JSON.stringify(ok.body));
  assert.equal(count(env.db), 1);
});
