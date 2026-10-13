import test from 'node:test';
import assert from 'node:assert/strict';
import worker from '../src/index.js';

// BH-1613: a per-model price source. `model_prices.price_source` is
// 'vendor-direct' or NULL (= priced from OpenRouter). One route writes it —
// PUT /api/model-prices/source — and the refresh's whole-table POST never names
// it, so the 04:30 upsert cannot clear an operator's mark.
//
// The database starts with the PRE-BH-1613 model_prices table (no
// price_source column), the shape the live D1 has today, so every test here
// also proves ensureColumns reaches a table that already exists.

const SECRET = 'test-secret';

let DatabaseSync = null;
try { ({ DatabaseSync } = await import('node:sqlite')); } catch { DatabaseSync = null; }

// A D1-shaped adapter over node:sqlite: the surface these two routes use is
// prepare().bind().run()/first()/all() and batch(). D1 takes undefined for a
// NULL bind; node:sqlite refuses it, so binds are normalised here and the
// worker's own binds stay unchanged.
function d1(db) {
  const norm = (v) => (v === undefined || v === null ? null : (typeof v === 'boolean' ? (v ? 1 : 0) : v));
  const exec = (sql, binds) => {
    const stmt = db.prepare(sql);
    if (/^\s*(SELECT|PRAGMA)\b/i.test(sql)) return { results: stmt.all(...binds), meta: { changes: 0 } };
    const r = stmt.run(...binds);
    return { results: [], meta: { changes: Number(r.changes) } };
  };
  const make = (sql, binds) => ({
    _sql: sql,
    _binds: binds,
    bind: (...b) => make(sql, b.map(norm)),
    run: async () => exec(sql, binds),
    first: async () => { const r = exec(sql, binds); return r.results.length ? r.results[0] : null; },
    all: async () => exec(sql, binds),
  });
  return {
    prepare: (sql) => make(sql, []),
    batch: async (stmts) => stmts.map((s) => exec(s._sql, s._binds)),
  };
}

const req = (method, path, body) => new Request(`https://jobs.test${path}`, {
  method,
  headers: { authorization: `Bearer ${SECRET}`, 'content-type': 'application/json' },
  body: body === undefined ? undefined : JSON.stringify(body),
});

const OLD_CREATE = `CREATE TABLE model_prices (
  model TEXT PRIMARY KEY, slug TEXT, prompt REAL, completion REAL, cache_read REAL,
  cache_write REAL, cliff_tokens INTEGER, source TEXT, updated_at TEXT NOT NULL)`;

const ROWS = [
  { model: 'grok-4.7', slug: 'x-ai/grok-4.7', prompt: 0.000002, completion: 0.000006, cache_read: 0.0000005, cliff_tokens: 200000 },
  { model: 'claude-opus-5', slug: 'anthropic/claude-opus-5', prompt: 0.000005, completion: 0.000025 },
];

async function setup() {
  const db = new DatabaseSync(':memory:');
  db.exec(OLD_CREATE);
  const env = { DB: d1(db), HARNESS_SECRET: SECRET };
  const post = await worker.fetch(req('POST', '/api/model-prices', { source: 'openrouter', rows: ROWS }), env);
  assert.equal(post.status, 200, await post.clone().text());
  return { db, env };
}
const getTable = async (env) => {
  const r = await worker.fetch(req('GET', '/api/model-prices'), env);
  assert.equal(r.status, 200, await r.clone().text());
  return r.json();
};
const putSource = (env, body, auth = true) => worker.fetch(auth ? req('PUT', '/api/model-prices/source', body)
  : new Request('https://jobs.test/api/model-prices/source', { method: 'PUT', body: JSON.stringify(body) }), env);

test('B1: PUT marks one model vendor-direct and GET carries it on that row only', async (t) => {
  if (!DatabaseSync) { t.skip('node:sqlite unavailable on this runtime'); return; }
  const { db, env } = await setup();
  const r = await putSource(env, { model: 'grok-4.7', price_source: 'vendor-direct' });
  assert.equal(r.status, 200, await r.clone().text());
  const b = await r.json();
  assert.equal(b.model, 'grok-4.7');
  assert.equal(b.price_source, 'vendor-direct');
  const g = await getTable(env);
  assert.equal(g.per_token['grok-4.7'].price_source, 'vendor-direct');
  assert.equal('price_source' in g.per_token['claude-opus-5'], false, 'an unmarked row carries no key');
  db.close();
});

test('B2: PUT openrouter clears the mark and GET omits the key again', async (t) => {
  if (!DatabaseSync) { t.skip('node:sqlite unavailable on this runtime'); return; }
  const { db, env } = await setup();
  assert.equal((await putSource(env, { model: 'grok-4.7', price_source: 'vendor-direct' })).status, 200);
  const r = await putSource(env, { model: 'grok-4.7', price_source: 'OpenRouter' });
  assert.equal(r.status, 200, await r.clone().text());
  assert.equal((await r.json()).price_source, 'openrouter');
  const g = await getTable(env);
  assert.equal('price_source' in g.per_token['grok-4.7'], false);
  assert.equal(db.prepare("SELECT price_source FROM model_prices WHERE model='grok-4.7'").get().price_source, null);
  db.close();
});

test('B3: the refresh\'s whole-table POST after a PUT leaves the mark set', async (t) => {
  if (!DatabaseSync) { t.skip('node:sqlite unavailable on this runtime'); return; }
  const { db, env } = await setup();
  assert.equal((await putSource(env, { model: 'grok-4.7', price_source: 'vendor-direct' })).status, 200);
  const post = await worker.fetch(req('POST', '/api/model-prices', { source: 'openrouter', rows: ROWS }), env);
  assert.equal(post.status, 200);
  const g = await getTable(env);
  assert.equal(g.per_token['grok-4.7'].price_source, 'vendor-direct');
  assert.equal(g.per_token['grok-4.7'].prompt, 0.000002);
  db.close();
});

test('B4: a bad value or missing model is 400, an unknown model is 404, and nothing changes', async (t) => {
  if (!DatabaseSync) { t.skip('node:sqlite unavailable on this runtime'); return; }
  const { db, env } = await setup();
  const snap = () => JSON.stringify(db.prepare('SELECT * FROM model_prices ORDER BY model').all());
  await getTable(env); // migrates the column in, so the snapshot compares like with like
  const before = snap();
  const bad = await putSource(env, { model: 'grok-4.7', price_source: 'vendor_direct' });
  assert.equal(bad.status, 400);
  assert.match((await bad.json()).error, /vendor-direct.*openrouter/);
  assert.equal((await putSource(env, { price_source: 'vendor-direct' })).status, 400);
  assert.equal((await putSource(env, { model: 'grok-4.7' })).status, 400);
  const miss = await putSource(env, { model: 'no-such-model', price_source: 'vendor-direct' });
  assert.equal(miss.status, 404);
  assert.match((await miss.json()).error, /no-such-model/);
  assert.equal(snap(), before);
  assert.equal(db.prepare('SELECT COUNT(*) AS n FROM model_prices').get().n, 2);
  db.close();
});

test('B5: no bearer is 401', async (t) => {
  if (!DatabaseSync) { t.skip('node:sqlite unavailable on this runtime'); return; }
  const { db, env } = await setup();
  const r = await putSource(env, { model: 'grok-4.7', price_source: 'vendor-direct' }, false);
  assert.equal(r.status, 401);
  assert.ok(db.prepare('SELECT * FROM model_prices').all().every((x) => !x.price_source), 'nothing was marked');
  db.close();
});
