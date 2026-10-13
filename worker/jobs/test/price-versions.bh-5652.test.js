import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import worker from '../src/index.js';
import { d1 } from './lib/d1-sqlite.bh-1030.js';

// BH-5652 (BH-5637.1): prices as versioned DB rows.
//
// Every model, Fly and slug row carries a `version` and an `effective_at`. A
// write that CHANGES a rate bumps the version and writes one price_audit row in
// the same D1 batch. A write that changes nothing writes nothing, so the daily
// refresh re-posting the whole table is a no-op on the history.
//
// Through worker.fetch, the production entry point, on a node:sqlite database
// that never saw schema.sql: each route creates its own tables (BH-658). The
// clock is mocked because nowIso() has one-second resolution and W3 needs
// effective_at to move.

const SECRET = 'test-secret';
const ROOT = (p) => fileURLToPath(new URL(`../../../${p}`, import.meta.url));
const FLY_FILE = JSON.parse(readFileSync(ROOT('catalog/fly-prices.json'), 'utf8'));
const SLUG_FILE = JSON.parse(readFileSync(ROOT('catalog/model-slugs.json'), 'utf8'));

let DatabaseSync = null;
try { ({ DatabaseSync } = await import('node:sqlite')); } catch { DatabaseSync = null; }

const T0 = Date.parse('2026-10-09T01:00:00Z');
const iso = (ms) => new Date(ms).toISOString().replace(/\.\d{3}Z$/, 'Z');

const req = (method, path, body, auth = true) => new Request(`https://jobs.test${path}`, {
  method,
  headers: { ...(auth ? { authorization: `Bearer ${SECRET}` } : {}), 'content-type': 'application/json' },
  body: body === undefined ? undefined : JSON.stringify(body),
});

function fresh(t) {
  t.mock.timers.enable({ apis: ['Date'], now: T0 });
  const db = new DatabaseSync(':memory:');
  return { db, env: { DB: d1(db), HARNESS_SECRET: SECRET } };
}

async function call(env, method, path, body, status = 200) {
  const res = await worker.fetch(req(method, path, body), env);
  const text = await res.text();
  assert.equal(res.status, status, `${method} ${path}: ${text}`);
  return JSON.parse(text);
}
const postModels = (env, source, rows) => call(env, 'POST', '/api/model-prices', { source, rows });
const getModel = async (env, m) => (await call(env, 'GET', '/api/model-prices')).per_token[m];
const audit = (db, kind, key) => db.prepare(
  'SELECT kind, key, version, old_json, new_json, source, effective_at FROM price_audit WHERE kind=? AND key=? ORDER BY version'
).all(kind, key);

const M = 'fixture-model-a';
const RATES = { prompt: 6e-6, completion: 3e-5, cache_read: 6e-7, cache_write: 7.5e-6 };

test('W1: a new model gets version 1, effective_at = the POST time, one audit row with no old rates', async (t) => {
  if (!DatabaseSync) { t.skip('node:sqlite unavailable on this runtime'); return; }
  const { db, env } = fresh(t);
  const res = await postModels(env, 'openrouter', [{ model: M, slug: 'vendor/fixture-model-a', ...RATES }]);
  assert.equal(res.accepted, 1, 'accepted counts rows, not statements');
  assert.equal(res.as_of, iso(T0));
  const e = await getModel(env, M);
  assert.strictEqual(e.version, 1);
  assert.equal(e.effective_at, iso(T0));
  assert.equal(e.prompt, RATES.prompt, 'the rest of the entry is unchanged');
  const a = audit(db, 'model', M);
  assert.equal(a.length, 1);
  assert.equal(a[0].version, 1);
  assert.equal(a[0].old_json, null);
  assert.deepEqual(JSON.parse(a[0].new_json),
    { prompt: 6e-6, completion: 3e-5, cache_read: 6e-7, cache_write: 7.5e-6, cliff_tokens: null });
  assert.equal(a[0].source, 'openrouter');
  assert.equal(a[0].effective_at, iso(T0));
  db.close();
});

test('W2: the same rates again bump nothing and write no audit row (NULL cliff over NULL, slug-only change)', async (t) => {
  if (!DatabaseSync) { t.skip('node:sqlite unavailable on this runtime'); return; }
  const { db, env } = fresh(t);
  await postModels(env, 'openrouter', [{ model: M, ...RATES }]);
  t.mock.timers.tick(60_000);
  await postModels(env, 'openrouter', [{ model: M, ...RATES }]);
  t.mock.timers.tick(60_000);
  // The slug is not a rate: a changed slug alone is not a new price.
  await postModels(env, 'openrouter', [{ model: M, slug: 'vendor/fixture-model-a', ...RATES }]);
  const e = await getModel(env, M);
  assert.strictEqual(e.version, 1);
  assert.equal(e.effective_at, iso(T0), 'effective_at stays at the first write');
  assert.equal(e.slug, 'vendor/fixture-model-a', 'the upsert still applied the slug');
  assert.equal(audit(db, 'model', M).length, 1);
  db.close();
});

test('W3: a changed prompt is version 2, effective_at moves, audit v2 holds old and new rates', async (t) => {
  if (!DatabaseSync) { t.skip('node:sqlite unavailable on this runtime'); return; }
  const { db, env } = fresh(t);
  await postModels(env, 'openrouter', [{ model: M, ...RATES, cliff_tokens: 200000 }]);
  t.mock.timers.tick(120_000);
  await postModels(env, 'openrouter', [{ model: M, ...RATES, prompt: 5e-6, cliff_tokens: 200000 }]);
  const e = await getModel(env, M);
  assert.strictEqual(e.version, 2);
  assert.equal(e.effective_at, iso(T0 + 120_000));
  assert.equal(e.prompt, 5e-6);
  const a = audit(db, 'model', M);
  assert.deepEqual(a.map((r) => r.version), [1, 2]);
  assert.equal(JSON.parse(a[1].old_json).prompt, 6e-6);
  assert.equal(JSON.parse(a[1].new_json).prompt, 5e-6);
  assert.equal(JSON.parse(a[1].new_json).cliff_tokens, 200000);
  assert.equal(a[1].effective_at, iso(T0 + 120_000));
  // A NULL cliff where there was one IS a change.
  t.mock.timers.tick(1000);
  await postModels(env, 'openrouter', [{ model: M, ...RATES, prompt: 5e-6 }]);
  assert.strictEqual((await getModel(env, M)).version, 3);
  assert.equal(audit(db, 'model', M).length, 3);
  db.close();
});

test('W4: a catalog POST never bumps an existing row; on a new model it inserts v1 with one audit row', async (t) => {
  if (!DatabaseSync) { t.skip('node:sqlite unavailable on this runtime'); return; }
  const { db, env } = fresh(t);
  await postModels(env, 'openrouter', [{ model: M, ...RATES }]);
  t.mock.timers.tick(60_000);
  await postModels(env, 'catalog', [
    { model: M, ...RATES, prompt: 9e-6 },
    { model: 'fixture-model-b', prompt: 3e-6, completion: 1.5e-5 },
  ]);
  const e = await getModel(env, M);
  assert.strictEqual(e.version, 1);
  assert.equal(e.prompt, 6e-6, 'BH-1890: the live rate stands');
  assert.equal(e.effective_at, iso(T0));
  assert.equal(audit(db, 'model', M).length, 1, 'no audit row for a row the catalog did not write');
  const s = await getModel(env, 'fixture-model-b');
  assert.strictEqual(s.version, 1);
  assert.equal(s.effective_at, iso(T0 + 60_000));
  const a = audit(db, 'model', 'fixture-model-b');
  assert.equal(a.length, 1);
  assert.equal(a[0].source, 'catalog');
  db.close();
});

// The numbers of catalog/fly-prices.json, nested as the file nests them.
function flyNumbers(file) {
  const out = {};
  for (const [k, v] of Object.entries(file)) {
    if (typeof v === 'number') out[k] = v;
    else if (v && typeof v === 'object' && !Array.isArray(v)) {
      const sub = {};
      for (const [k2, v2] of Object.entries(v)) if (typeof v2 === 'number') sub[k2] = v2;
      if (Object.keys(sub).length) out[k] = sub;
    }
  }
  return out;
}

test('W5: the real catalog/fly-prices.json round-trips; a changed rate bumps only its key', async (t) => {
  if (!DatabaseSync) { t.skip('node:sqlite unavailable on this runtime'); return; }
  const { db, env } = fresh(t);
  const want = flyNumbers(FLY_FILE);
  const res = await call(env, 'POST', '/api/fly-prices', { source: 'catalog', prices: FLY_FILE });
  assert.equal(res.accepted, 5);
  let g = await call(env, 'GET', '/api/fly-prices');
  const { updated_at, versions, source, ...nested } = g;
  assert.deepEqual(nested, want, 'GET rebuilds the same numbers in the same nesting');
  assert.equal(updated_at, iso(T0));
  assert.equal(source, 'catalog');
  assert.deepEqual(versions, {
    seconds_per_month: 1, 'cpu_usd_per_core_month.shared': 1, 'cpu_usd_per_core_month.performance': 1,
    memory_usd_per_gb_month: 1, volume_usd_per_gb_month: 1,
  });

  // A replay changes nothing.
  t.mock.timers.tick(60_000);
  await call(env, 'POST', '/api/fly-prices', { source: 'catalog', prices: FLY_FILE });
  assert.equal(db.prepare("SELECT COUNT(*) n FROM price_audit WHERE kind='fly'").get().n, 5);

  t.mock.timers.tick(60_000);
  await call(env, 'POST', '/api/fly-prices', {
    source: 'catalog', prices: { ...FLY_FILE, memory_usd_per_gb_month: FLY_FILE.memory_usd_per_gb_month + 1 },
  });
  g = await call(env, 'GET', '/api/fly-prices');
  assert.equal(g.memory_usd_per_gb_month, FLY_FILE.memory_usd_per_gb_month + 1);
  assert.equal(g.versions.memory_usd_per_gb_month, 2);
  for (const k of Object.keys(g.versions)) if (k !== 'memory_usd_per_gb_month') assert.equal(g.versions[k], 1, k);
  const a = audit(db, 'fly', 'memory_usd_per_gb_month');
  assert.equal(a.length, 2);
  assert.deepEqual(JSON.parse(a[1].old_json), { value: FLY_FILE.memory_usd_per_gb_month });
  assert.deepEqual(JSON.parse(a[1].new_json), { value: FLY_FILE.memory_usd_per_gb_month + 1 });
  assert.equal(a[1].effective_at, iso(T0 + 120_000));

  // No number anywhere: 400, nothing written.
  await call(env, 'POST', '/api/fly-prices', { prices: { _comment: ['x'], updated_at: 'y', a: { b: 'c' } } }, 400);
  await call(env, 'POST', '/api/fly-prices', { prices: 'nope' }, 400);
  db.close();
});

test('W6: the real catalog/model-slugs.json round-trips; a changed slug bumps to v2; bad values are refused', async (t) => {
  if (!DatabaseSync) { t.skip('node:sqlite unavailable on this runtime'); return; }
  const { db, env } = fresh(t);
  const n = Object.keys(SLUG_FILE).length;
  assert.ok(n > 0, 'the catalog has slugs');
  const res = await call(env, 'POST', '/api/model-slugs', { source: 'catalog', slugs: SLUG_FILE });
  assert.equal(res.accepted, n);
  let g = await call(env, 'GET', '/api/model-slugs');
  assert.deepEqual(g.slugs, SLUG_FILE);
  assert.equal(g.updated_at, iso(T0));
  assert.equal(Object.keys(g.versions).length, n);
  assert.ok(Object.values(g.versions).every((v) => v === 1));

  const k = Object.keys(SLUG_FILE)[0];
  t.mock.timers.tick(60_000);
  const r2 = await call(env, 'POST', '/api/model-slugs', {
    source: 'catalog', slugs: { [k]: 'vendor/changed', bad1: '', bad2: 'x'.repeat(257), bad3: 7 },
  });
  assert.equal(r2.accepted, 1);
  assert.equal(r2.skipped, 3);
  g = await call(env, 'GET', '/api/model-slugs');
  assert.equal(g.slugs[k], 'vendor/changed');
  assert.equal(g.versions[k], 2);
  assert.equal(Object.keys(g.slugs).length, n, 'skipped entries were not written');
  const a = audit(db, 'slug', k);
  assert.equal(a.length, 2);
  assert.deepEqual(JSON.parse(a[1].old_json), { slug: SLUG_FILE[k] });
  assert.deepEqual(JSON.parse(a[1].new_json), { slug: 'vendor/changed' });

  await call(env, 'POST', '/api/model-slugs', { slugs: { a: '', b: 3 } }, 400);
  await call(env, 'POST', '/api/model-slugs', { slugs: ['x'] }, 400);
  const big = {};
  for (let i = 0; i < 501; i++) big[`m${i}`] = `v/m${i}`;
  await call(env, 'POST', '/api/model-slugs', { slugs: big }, 400);
  assert.equal(db.prepare('SELECT COUNT(*) n FROM model_slugs').get().n, n, 'a refused POST writes nothing');
  db.close();
});

test('W7: GET /api/price-audit lists newest first, filters, caps limit at 200, refuses a bad kind and no bearer', async (t) => {
  if (!DatabaseSync) { t.skip('node:sqlite unavailable on this runtime'); return; }
  const { db, env } = fresh(t);
  for (const p of [1e-6, 2e-6, 3e-6]) {
    await postModels(env, 'openrouter', [{ model: M, prompt: p, completion: 1e-5 }]);
    t.mock.timers.tick(1000);
  }
  await postModels(env, 'openrouter', [{ model: 'other', prompt: 1e-6, completion: 1e-5 }]);
  await call(env, 'POST', '/api/model-slugs', { slugs: { [M]: 'anthropic/x' } });

  const r = await call(env, 'GET', `/api/price-audit?kind=model&key=${encodeURIComponent(M)}`);
  assert.equal(r.limit, 50, 'default limit');
  assert.deepEqual(r.rows.map((x) => x.version), [3, 2, 1], 'newest first');
  assert.deepEqual(r.rows[0], {
    kind: 'model', key: M, version: 3,
    old: { prompt: 2e-6, completion: 1e-5, cache_read: null, cache_write: null, cliff_tokens: null },
    new: { prompt: 3e-6, completion: 1e-5, cache_read: null, cache_write: null, cliff_tokens: null },
    source: 'openrouter', effective_at: iso(T0 + 2000),
  });
  assert.equal(r.rows[2].old, null, 'the first version has no old rates');

  const all = await call(env, 'GET', '/api/price-audit');
  assert.equal(all.rows.length, 5);
  assert.equal(all.rows[0].kind, 'slug', 'newest row across kinds comes first');
  const models = await call(env, 'GET', '/api/price-audit?kind=model');
  assert.equal(models.rows.length, 4);
  assert.ok(models.rows.every((x) => x.kind === 'model'));
  const one = await call(env, 'GET', '/api/price-audit?limit=1');
  assert.equal(one.rows.length, 1);

  const capped = await call(env, 'GET', '/api/price-audit?limit=999');
  assert.equal(capped.limit, 200);
  await call(env, 'GET', '/api/price-audit?kind=bogus', undefined, 400);
  const noauth = await worker.fetch(req('GET', '/api/price-audit', undefined, false), env);
  assert.equal(noauth.status, 401);
  db.close();
});

test('W8: a legacy model_prices table without the columns reads version 1; an unchanged POST fills effective_at, no audit', async (t) => {
  if (!DatabaseSync) { t.skip('node:sqlite unavailable on this runtime'); return; }
  const { db, env } = fresh(t);
  // The CREATE as it was on main before BH-5652, holding one live row.
  db.exec(`CREATE TABLE model_prices (
       model TEXT PRIMARY KEY, slug TEXT, prompt REAL, completion REAL, cache_read REAL,
       cache_write REAL, cliff_tokens INTEGER, source TEXT, updated_at TEXT NOT NULL,
       price_source TEXT, vendor_prompt REAL, vendor_completion REAL, vendor_cache_read REAL,
       vendor_cache_write REAL, vendor_cliff_tokens INTEGER)`);
  db.prepare(`INSERT INTO model_prices (model, prompt, completion, source, updated_at)
              VALUES (?, ?, ?, 'openrouter', '2026-10-01T00:00:00Z')`).run(M, 6e-6, 3e-5);

  const e0 = await getModel(env, M);
  assert.strictEqual(e0.version, 1, 'the column default reads 1');
  assert.equal('effective_at' in e0, false, 'no versioned write yet: the key is omitted, never null');

  t.mock.timers.tick(60_000);
  await postModels(env, 'openrouter', [{ model: M, prompt: 6e-6, completion: 3e-5 }]);
  const e1 = await getModel(env, M);
  assert.strictEqual(e1.version, 1, 'unchanged rates: no bump');
  assert.equal(e1.effective_at, iso(T0 + 60_000), 'the first versioned write fills effective_at');
  assert.equal(audit(db, 'model', M).length, 0, 'no audit row for history before the deploy');

  t.mock.timers.tick(60_000);
  await postModels(env, 'openrouter', [{ model: M, prompt: 7e-6, completion: 3e-5 }]);
  const e2 = await getModel(env, M);
  assert.strictEqual(e2.version, 2);
  const a = audit(db, 'model', M);
  assert.equal(a.length, 1);
  assert.equal(a[0].version, 2);
  db.close();
});
