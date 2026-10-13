// BH-3985: GET /api/metrics/extra-usage pages with `until` (inclusive,
// newest-first, the cost-rows convention), a failed poll keeps the vendor's
// error body, and account-usage answers a 12h window for the poller's flat
// check. Runs the worker's REAL SQL on schema.sql behind the node:sqlite shim.
import test from 'node:test';
import assert from 'node:assert/strict';
import worker from '../src/index.js';
import { openDb } from './lib/d1-sqlite.bh-1030.js';
import { usageWindow } from '../src/lib/account-usage.js';

const SECRET = 'test-secret';
const T0 = Date.parse('2026-09-01T00:00:00Z');
const isoZ = (ms) => new Date(ms).toISOString().replace(/\.\d{3}Z$/, 'Z');

const call = (DB, path, { method = 'GET', body } = {}) => worker.fetch(new Request(`https://jobs.test${path}`, {
  method,
  headers: { authorization: `Bearer ${SECRET}`, 'content-type': 'application/json' },
  body: body === undefined ? undefined : JSON.stringify(body),
}), { DB, HARNESS_SECRET: SECRET }).then(async (res) => ({ status: res.status, body: await res.json() }));

const seed = (db, box, n, stepMs = 60e3, offsetMs = 0) => {
  const ins = db.prepare(
    `INSERT INTO extra_usage_snapshots (box, ts, extra_used_usd, status) VALUES (?,?,?,?)`);
  const out = [];
  for (let i = 0; i < n; i += 1) {
    const ts = isoZ(T0 + offsetMs + i * stepMs);
    ins.run(box, ts, i, 'ok');
    out.push(`${box}|${ts}`);
  }
  return out;
};

const newestFirst = (rows) => rows.every((r, i) => i === 0
  || r.ts < rows[i - 1].ts || (r.ts === rows[i - 1].ts && r.box < rows[i - 1].box));

test('BH-3985 extra-usage paging and error bodies on a real schema', async (t) => {
  if ((await openDb()) === null) {
    t.skip('node:sqlite unavailable in this runtime');
    return;
  }

  await t.test('1500 snapshots page across two calls with until', async () => {
    const { db, DB } = await openDb();
    const seeded = new Set(seed(db, 'project-6-account', 1500));
    const p1 = await call(DB, '/api/metrics/extra-usage?box=project-6-account&limit=1000');
    assert.equal(p1.status, 200);
    assert.equal(p1.body.snapshots.length, 1000);
    assert.equal(p1.body.until, null);
    assert.ok(newestFirst(p1.body.snapshots), 'page 1 newest-first');
    assert.equal(p1.body.snapshots[0].ts, isoZ(T0 + 1499 * 60e3));
    const oldest = p1.body.snapshots.at(-1).ts;
    const p2 = await call(DB, `/api/metrics/extra-usage?box=project-6-account&limit=1000&until=${encodeURIComponent(oldest)}`);
    assert.equal(p2.status, 200);
    assert.equal(p2.body.until, oldest);
    assert.equal(p2.body.snapshots.length, 501, 'the remaining 500 plus the inclusive boundary row');
    assert.ok(newestFirst(p2.body.snapshots), 'page 2 newest-first');
    assert.equal(p2.body.snapshots[0].ts, oldest, 'inclusive: the boundary row opens page 2');
    const k1 = p1.body.snapshots.map((r) => `${r.box}|${r.ts}`);
    const k2 = p2.body.snapshots.map((r) => `${r.box}|${r.ts}`);
    const both = k1.filter((k) => k2.includes(k));
    assert.deepEqual(both, [`project-6-account|${oldest}`], 'only the boundary row is on both pages');
    const union = new Set([...k1, ...k2]);
    assert.equal(union.size, 1500, 'no gaps, no duplicates after the PK dedupe');
    assert.deepEqual([...union].sort(), [...seeded].sort());
  });

  await t.test('without box, two interleaved boxes page in a total (ts, box) order', async () => {
    const { db, DB } = await openDb();
    // Same-second rows on two boxes: a ts-only order could split them
    // nondeterministically across a page edge.
    // project-6-account is inserted first on purpose: with ORDER BY ts DESC
    // alone SQLite returns these ties hub-gmail first, so this order is what
    // makes the box DESC tiebreak observable.
    const seeded = new Set([...seed(db, 'project-6-account', 700), ...seed(db, 'hub-gmail', 700)]);
    const p1 = await call(DB, '/api/metrics/extra-usage?limit=1000');
    assert.equal(p1.body.snapshots.length, 1000);
    assert.ok(newestFirst(p1.body.snapshots));
    const oldest = p1.body.snapshots.at(-1).ts;
    const p2 = await call(DB, `/api/metrics/extra-usage?limit=1000&until=${encodeURIComponent(oldest)}`);
    assert.ok(newestFirst(p2.body.snapshots));
    const union = new Set([...p1.body.snapshots, ...p2.body.snapshots].map((r) => `${r.box}|${r.ts}`));
    assert.deepEqual([...union].sort(), [...seeded].sort());
  });

  await t.test('an error snapshot stores its error_body; ok leaves it null; a replay never blanks it', async () => {
    const { DB } = await openDb();
    const errBody = 'HTTP 500: {"type":"error","error":{"type":"api_error","message":"boom"}}';
    const ts = '2026-10-03T17:28:00Z';
    let r = await call(DB, '/api/metrics/extra-usage', {
      method: 'POST', body: { box: 'project-6-account', ts, status: 'error', error_body: errBody },
    });
    assert.equal(r.status, 200);
    assert.equal(r.body.snapshot.error_body, errBody);
    r = await call(DB, '/api/metrics/extra-usage', {
      method: 'POST', body: { box: 'project-6-account', ts, status: 'error', error_body: '' },
    });
    assert.equal(r.body.snapshot.error_body, errBody, 'a replay with an empty body keeps the stored one');
    r = await call(DB, '/api/metrics/extra-usage', {
      method: 'POST', body: { box: 'project-6-account', ts: '2026-10-03T17:43:00Z', extra_used_usd: 13.93 },
    });
    assert.equal(r.body.snapshot.status, 'ok');
    assert.equal(r.body.snapshot.error_body, null);
    const g = await call(DB, '/api/metrics/extra-usage?box=project-6-account');
    assert.equal(g.body.snapshots.find((s) => s.ts === ts).error_body, errBody);
  });
});

test('window=12h resolves to 12h; junk still resolves to 5h', () => {
  const now = Date.parse('2026-10-03T18:00:00Z');
  assert.deepEqual(usageWindow({ window: '12h', now }),
    { window: '12h', from: '2026-10-03T06:00:00Z', to: '2026-10-03T18:00:00Z' });
  assert.equal(usageWindow({ window: 'bogus', now }).window, '5h');
});
