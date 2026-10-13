import test from 'node:test';
import assert from 'node:assert/strict';
import worker from '../../src/index.js';
import { openDb } from '../lib/d1-sqlite.bh-1030.js';

// BH-2633 (BH-2517.2) — PUT/GET /api/ci-health, the newest minutes and runners
// snapshot per repo that bin/ci-minutes-watch.sh and bin/testhost-tick.sh push
// through ci_health_put (bin/lib/jobs/cost.sh).
//
// Driven through the real worker.fetch (D2) over the real schema.sql in
// node:sqlite, so the route table, the bearer, body parsing and the upsert SQL
// are what run. Deleting the ROUTES spread in src/index.js turns every case
// here into the router's 404.

const SECRET = 'test-secret';
const NOW_MS = Date.parse('2026-09-26T09:00:00Z');

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

const put = (DB, b, o) => call(DB, 'PUT', '/api/ci-health', b, o);
const count = (db) => db.prepare('SELECT COUNT(*) AS n FROM ci_health').get().n;

test('W1: a metric outside minutes|runners is 400 and writes nothing', async (t) => {
  const env = await open(t); if (!env) return;
  for (const metric of ['cost', 'Minutes', 'runner', undefined]) {
    const r = await put(env.DB, { repo: 'A/x', metric, payload: { est_24h: 1 } });
    assert.equal(r.status, 400, `metric ${metric}: ${JSON.stringify(r.body)}`);
    assert.match(r.body.error, /minutes/);
  }
  assert.equal(count(env.db), 0);
  const noRepo = await put(env.DB, { metric: 'minutes', payload: { est_24h: 1 } });
  assert.equal(noRepo.status, 400);
  assert.equal(noRepo.body.error, 'repo required');
  assert.equal(count(env.db), 0);
});

test('W2: a payload that is not a JSON object is 400', async (t) => {
  const env = await open(t); if (!env) return;
  for (const payload of [[], null, 'x', 42, undefined]) {
    const r = await put(env.DB, { repo: 'A/x', metric: 'minutes', payload });
    assert.equal(r.status, 400, `payload ${JSON.stringify(payload)}: ${JSON.stringify(r.body)}`);
  }
  assert.equal(count(env.db), 0);
});

test('W3: the 8 KB cap is on serialised BYTES; 8192 is accepted, 8193 is not', async (t) => {
  const env = await open(t); if (!env) return;
  // {"k":"…"} is 8 bytes of frame around the string.
  const exact = { k: 'a'.repeat(8192 - 8) };
  assert.equal(Buffer.byteLength(JSON.stringify(exact)), 8192);
  const ok = await put(env.DB, { repo: 'A/x', metric: 'minutes', payload: exact });
  assert.equal(ok.status, 200, JSON.stringify(ok.body).slice(0, 200));

  // 8185 bytes of ASCII plus one 2-byte char is 8193 bytes but only 8192 chars:
  // a character-length check would take it.
  const multi = { k: 'a'.repeat(8192 - 8 - 1) + 'é' };
  assert.equal(JSON.stringify(multi).length, 8192);
  assert.equal(Buffer.byteLength(JSON.stringify(multi)), 8193);
  const big = await put(env.DB, { repo: 'B/y', metric: 'minutes', payload: multi });
  assert.equal(big.status, 400, JSON.stringify(big.body));
  const over = await put(env.DB, { repo: 'B/y', metric: 'minutes', payload: { k: 'a'.repeat(8192 - 7) } });
  assert.equal(over.status, 400);
  assert.equal(count(env.db), 1, 'only the 8192-byte payload was stored');
});

test('W4: the upsert keeps one row per (repo, metric) and overwrites it', async (t) => {
  const env = await open(t); if (!env) return;
  const a = await put(env.DB, { repo: 'A/x', metric: 'minutes', payload: { est_24h: 5 }, box: 'hub' });
  assert.equal(a.status, 200);
  assert.deepEqual(a.body.row, { repo: 'A/x', metric: 'minutes', payload: { est_24h: 5 }, box: 'hub', as_of: '2026-09-26T09:00:00Z' });
  t.mock.timers.tick(60_000);
  const b = await put(env.DB, { repo: 'A/x', metric: 'minutes', payload: { est_24h: 9 } });
  assert.equal(b.status, 200);
  assert.equal(count(env.db), 1);
  const row = env.db.prepare('SELECT * FROM ci_health WHERE repo=? AND metric=?').get('A/x', 'minutes');
  assert.deepEqual(JSON.parse(row.payload), { est_24h: 9 });
  assert.equal(row.as_of, '2026-09-26T09:01:00Z');
  assert.equal(row.box, null, 'a re-PUT without box overwrites box too');
  const c = await put(env.DB, { repo: 'A/x', metric: 'runners', payload: { total: 4 } });
  assert.equal(c.status, 200);
  assert.equal(count(env.db), 2);
});

test('W5: GET ?repo= answers that repo only, payload parsed; without repo, every repo', async (t) => {
  const env = await open(t); if (!env) return;
  await put(env.DB, { repo: 'A/x', metric: 'runners', payload: { total: 4 } });
  await put(env.DB, { repo: 'A/x', metric: 'minutes', payload: { est_24h: 5 } });
  await put(env.DB, { repo: 'B/y', metric: 'minutes', payload: { unread: true } });
  const r = await call(env.DB, 'GET', '/api/ci-health?repo=A/x');
  assert.equal(r.status, 200);
  assert.equal(r.body.as_of, '2026-09-26T09:00:00Z');
  assert.equal(r.body.truncated, false);
  assert.deepEqual(r.body.rows.map((x) => [x.repo, x.metric]), [['A/x', 'minutes'], ['A/x', 'runners']]);
  assert.deepEqual(r.body.rows[0].payload, { est_24h: 5 });
  assert.equal(typeof r.body.rows[1].payload, 'object');

  const all = await call(env.DB, 'GET', '/api/ci-health');
  assert.equal(all.status, 200);
  assert.deepEqual(all.body.rows.map((x) => x.repo), ['A/x', 'A/x', 'B/y']);

  // A stored value that does not parse is flagged, never dropped and never a 500.
  env.db.prepare("INSERT INTO ci_health VALUES ('C/z','minutes','{nope',NULL,'2026-09-26')").run();
  const bad = await call(env.DB, 'GET', '/api/ci-health?repo=C/z');
  assert.equal(bad.status, 200);
  assert.deepEqual(bad.body.rows, [{ repo: 'C/z', metric: 'minutes', payload: null, payload_error: 'unparseable', box: null, as_of: '2026-09-26' }]);
});

test('W5b: GET is bounded at 500 rows and says when it was cut', async (t) => {
  const env = await open(t); if (!env) return;
  const ins = env.db.prepare("INSERT INTO ci_health VALUES (?, 'minutes', '{}', NULL, 'x')");
  for (let i = 0; i < 501; i++) ins.run(`R/${String(i).padStart(4, '0')}`);
  const r = await call(env.DB, 'GET', '/api/ci-health');
  assert.equal(r.status, 200);
  assert.equal(r.body.rows.length, 500);
  assert.equal(r.body.truncated, true);
});

test('W6: an unapplied table is the house 503 on both verbs', async (t) => {
  const env = await open(t); if (!env) return;
  env.db.exec('DROP TABLE ci_health');
  const w = await put(env.DB, { repo: 'A/x', metric: 'minutes', payload: { est_24h: 1 } });
  assert.equal(w.status, 503);
  assert.equal(w.body.error, 'ci_health schema not applied');
  const r = await call(env.DB, 'GET', '/api/ci-health?repo=A/x');
  assert.equal(r.status, 503);
  assert.equal(r.body.error, 'ci_health schema not applied');
});

test('W7: no bearer is 401', async (t) => {
  const env = await open(t); if (!env) return;
  const w = await put(env.DB, { repo: 'A/x', metric: 'minutes', payload: {} }, { secret: null });
  assert.equal(w.status, 401);
  const r = await call(env.DB, 'GET', '/api/ci-health', undefined, { secret: null });
  assert.equal(r.status, 401);
  assert.equal(count(env.db), 0);
});
