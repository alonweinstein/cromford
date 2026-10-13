import test from 'node:test';
import assert from 'node:assert/strict';
import worker from '../src/index.js';
import { openDb, D1_MAX_BINDS } from './lib/d1-sqlite.bh-1030.js';

// BH-3944: POST /api/wakes/claim sliced scanned ids by 99 and bound box + time
// in front of them — 101 binds, one over D1's cap — so every claim scanning
// >= 99 rows threw (Cloudflare 1101) and wake-loop's `limit: 200` was dead.
// These run through `worker.fetch` with the bearer (D2) over the shared
// node:sqlite fake, which now throws on > 100 binds the way D1 does.

const SECRET = 'test-secret';
const NOW = '2026-10-03T12:00:00Z';

async function fixture(t) {
  const o = await openDb();
  if (!o) {
    t.skip('node:sqlite unavailable on this runtime');
    return null;
  }
  const ins = o.db.prepare(
    'INSERT INTO wakes (repo, kind, key, event, minute, at) VALUES (?,?,?,?,?,?) RETURNING id');
  let n = 0;
  const add = (repo, kind = 'pr') => {
    n += 1;
    return Number(ins.get(repo, kind, `k${n}`, kind, NOW.slice(0, 16) + ':00Z', NOW).id);
  };
  const seed = (count) => Array.from({ length: count }, () => add('example-org/x'));
  return { ...o, add, seed };
}

const call = (fx, method, path, body) => {
  const init = { method, headers: { authorization: `Bearer ${SECRET}`, 'content-type': 'application/json' } };
  if (body !== undefined) init.body = JSON.stringify(body);
  return worker.fetch(new Request(`https://jobs.test${path}`, init), { DB: fx.DB, HARNESS_SECRET: SECRET })
    .then(async (res) => ({ status: res.status, body: await res.json().catch(() => null) }));
};
const claim = (fx, body) => call(fx, 'POST', '/api/wakes/claim', body);
const claimsFor = (fx, box) =>
  Number(fx.db.prepare('SELECT count(*) n FROM wake_claims WHERE box=?').get(box).n);

const selectN = (fx, n) =>
  fx.DB.prepare('SELECT ' + Array(n).fill('?').join(',')).bind(...Array(n).fill(1)).all();

test('F1: the D1 fake rejects a statement with 101 binds', async (t) => {
  const fx = await fixture(t);
  if (!fx) return;
  assert.equal(D1_MAX_BINDS, 100);
  await assert.rejects(async () => selectN(fx, 101), /too many SQL variables/);
});

test('F2: the D1 fake accepts a statement with exactly 100 binds', async (t) => {
  const fx = await fixture(t);
  if (!fx) return;
  const r = await selectN(fx, 100);
  assert.equal(r.results.length, 1);
});

test('C1: a claim scanning 200 rows answers 200 and claims all 200 across slices', async (t) => {
  const fx = await fixture(t);
  if (!fx) return;
  const seeded = fx.seed(200);
  const r = await claim(fx, { box: 'a', repos: ['example-org/x'], limit: 200 });
  assert.equal(r.status, 200, JSON.stringify(r.body));
  assert.equal(r.body.wakes.length, 200);
  assert.deepEqual(r.body.wakes.map((w) => Number(w.id)), seeded, 'every seeded row, in id order');
  assert.equal(Number(r.body.scanned_top), seeded[199]);
  assert.equal(claimsFor(fx, 'a'), 200);
});

for (const n of [98, 99, 100, 197]) {
  test(`C2: slice boundary — ${n} rows are all claimed`, async (t) => {
    const fx = await fixture(t);
    if (!fx) return;
    const seeded = fx.seed(n);
    const r = await claim(fx, { box: 'a', repos: ['example-org/x'], limit: n });
    assert.equal(r.status, 200, JSON.stringify(r.body));
    assert.deepEqual(r.body.wakes.map((w) => Number(w.id)), seeded);
    assert.equal(claimsFor(fx, 'a'), n);
  });
}

test('C3: a repeat 200-row claim by the same box gets [] (dedupe holds across slices)', async (t) => {
  const fx = await fixture(t);
  if (!fx) return;
  const seeded = fx.seed(200);
  const first = await claim(fx, { box: 'a', repos: ['example-org/x'], limit: 200 });
  assert.equal(first.status, 200, JSON.stringify(first.body));
  const again = await claim(fx, { box: 'a', repos: ['example-org/x'], limit: 200 });
  assert.equal(again.status, 200, JSON.stringify(again.body));
  assert.deepEqual(again.body.wakes, []);
  assert.equal(Number(again.body.scanned_top), seeded[199]);
  assert.equal(claimsFor(fx, 'a'), 200);
});

test('C4: an ack of 200 ids answers 200 and acks all 200 (ack slice at the cap)', async (t) => {
  const fx = await fixture(t);
  if (!fx) return;
  const seeded = fx.seed(200);
  const r = await call(fx, 'POST', '/api/wakes/ack', { ids: seeded });
  assert.equal(r.status, 200, JSON.stringify(r.body));
  assert.equal(r.body.acked, 200);
});
