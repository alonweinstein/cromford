import test from 'node:test';
import assert from 'node:assert/strict';
import worker from '../src/index.js';

// BH-1754: the vendor-direct PRICE lives in D1, next to BH-1613's mark, in five
// nullable columns (vendor_prompt, vendor_completion, vendor_cache_read,
// vendor_cache_write, vendor_cliff_tokens). PUT /api/model-prices/source writes
// them (optional `vendor` object), GET emits them as `vendor_direct` on a marked
// row only, and the refresh's whole-table POST never names them.
//
// The database starts with the PRE-BH-1754 model_prices table (price_source,
// no vendor columns), so every test also proves ensureColumns reaches it.

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
  cache_write REAL, cliff_tokens INTEGER, source TEXT, updated_at TEXT NOT NULL,
  price_source TEXT)`;

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

const VENDOR = { prompt: 0.000003, completion: 0.000009, cache_read: 0.00000075 };
const vendorCols = (db) => db.prepare(
  "SELECT price_source, vendor_prompt, vendor_completion, vendor_cache_read, vendor_cache_write, vendor_cliff_tokens FROM model_prices WHERE model='grok-4.7'"
).get();

test('D1: PUT vendor-direct with rates stores them and GET carries vendor_direct on that row', async (t) => {
  if (!DatabaseSync) { t.skip('node:sqlite unavailable on this runtime'); return; }
  const { db, env } = await setup();
  const r = await putSource(env, { model: 'grok-4.7', price_source: 'vendor-direct', vendor: VENDOR });
  assert.equal(r.status, 200, await r.clone().text());
  const g = await getTable(env);
  const row = g.per_token['grok-4.7'];
  assert.equal(row.price_source, 'vendor-direct');
  assert.deepEqual(row.vendor_direct, { prompt: 0.000003, completion: 0.000009, cache_read: 0.00000075, cache_write: null });
  assert.equal('cliff_tokens' in row.vendor_direct, false, 'no cliff given means no key');
  // The row's own rates are the refresh's, untouched by the PUT.
  assert.equal(row.prompt, 0.000002);
  assert.equal('vendor_direct' in g.per_token['claude-opus-5'], false);
  // With a cliff it is carried.
  assert.equal((await putSource(env, { model: 'grok-4.7', price_source: 'vendor-direct',
    vendor: { ...VENDOR, cliff_tokens: 256000 } })).status, 200);
  assert.equal((await getTable(env)).per_token['grok-4.7'].vendor_direct.cliff_tokens, 256000);
  db.close();
});

test('D2: PUT openrouter clears the mark AND the price; re-marking with no rates emits no vendor_direct', async (t) => {
  if (!DatabaseSync) { t.skip('node:sqlite unavailable on this runtime'); return; }
  const { db, env } = await setup();
  assert.equal((await putSource(env, { model: 'grok-4.7', price_source: 'vendor-direct',
    vendor: { ...VENDOR, cliff_tokens: 256000 } })).status, 200);
  assert.equal((await putSource(env, { model: 'grok-4.7', price_source: 'openrouter' })).status, 200);
  let row = (await getTable(env)).per_token['grok-4.7'];
  assert.equal('price_source' in row, false);
  assert.equal('vendor_direct' in row, false);
  assert.deepEqual({ ...vendorCols(db) }, { price_source: null, vendor_prompt: null, vendor_completion: null,
    vendor_cache_read: null, vendor_cache_write: null, vendor_cliff_tokens: null });
  assert.equal((await putSource(env, { model: 'grok-4.7', price_source: 'vendor-direct' })).status, 200);
  row = (await getTable(env)).per_token['grok-4.7'];
  assert.equal(row.price_source, 'vendor-direct');
  assert.equal('vendor_direct' in row, false);
  db.close();
});

test('D2b: re-marking vendor-direct with no rates keeps a stored price', async (t) => {
  if (!DatabaseSync) { t.skip('node:sqlite unavailable on this runtime'); return; }
  const { db, env } = await setup();
  assert.equal((await putSource(env, { model: 'grok-4.7', price_source: 'vendor-direct', vendor: VENDOR })).status, 200);
  assert.equal((await putSource(env, { model: 'grok-4.7', price_source: 'vendor-direct' })).status, 200);
  assert.equal((await getTable(env)).per_token['grok-4.7'].vendor_direct.prompt, 0.000003);
  db.close();
});

test('D3: the refresh\'s whole-table POST after a PUT leaves the vendor price and the mark', async (t) => {
  if (!DatabaseSync) { t.skip('node:sqlite unavailable on this runtime'); return; }
  const { db, env } = await setup();
  assert.equal((await putSource(env, { model: 'grok-4.7', price_source: 'vendor-direct', vendor: VENDOR })).status, 200);
  const moved = ROWS.map((r) => ({ ...r, prompt: 0.0000011, completion: 0.0000022 }));
  const post = await worker.fetch(req('POST', '/api/model-prices', { source: 'openrouter', rows: moved }), env);
  assert.equal(post.status, 200);
  const row = (await getTable(env)).per_token['grok-4.7'];
  assert.equal(row.prompt, 0.0000011, 'the POST did land');
  assert.equal(row.price_source, 'vendor-direct');
  assert.deepEqual(row.vendor_direct, { prompt: 0.000003, completion: 0.000009, cache_read: 0.00000075, cache_write: null });
  db.close();
});

test('D4: an unusable vendor price is 400 and nothing changes', async (t) => {
  if (!DatabaseSync) { t.skip('node:sqlite unavailable on this runtime'); return; }
  const { db, env } = await setup();
  await getTable(env); // migrates the columns in, so the snapshot compares like with like
  const snap = () => JSON.stringify(db.prepare('SELECT * FROM model_prices ORDER BY model').all());
  const before = snap();
  for (const vendor of [{ prompt: 0, completion: 0.000009 }, { prompt: -1, completion: 0.000009 },
    { prompt: 'x', completion: 0.000009 }, { prompt: 0.000003 }, { prompt: true, completion: 0.000009 }, 'nope',
    { ...VENDOR, cache_read: true }, { ...VENDOR, cache_write: 0 }, { ...VENDOR, cliff_tokens: 1.5 },
    { ...VENDOR, cliff_tokens: '256000' }]) {
    const r = await putSource(env, { model: 'grok-4.7', price_source: 'vendor-direct', vendor });
    assert.equal(r.status, 400, `vendor=${JSON.stringify(vendor)} must be refused`);
    assert.match((await r.json()).error, /prompt and completion|cache rates/);
  }
  const r = await putSource(env, { model: 'grok-4.7', price_source: 'openrouter', vendor: VENDOR });
  assert.equal(r.status, 400, 'rates only with vendor-direct');
  assert.equal(snap(), before);
  const g = await getTable(env);
  assert.equal(Object.values(g.per_token).some((e) => 'vendor_direct' in e), false);
  db.close();
});

test('D5: an unmarked row with stored vendor columns never carries vendor_direct', async (t) => {
  if (!DatabaseSync) { t.skip('node:sqlite unavailable on this runtime'); return; }
  const { db, env } = await setup();
  await getTable(env);
  db.exec("UPDATE model_prices SET vendor_prompt=0.000003, vendor_completion=0.000009 WHERE model='grok-4.7'");
  assert.equal('vendor_direct' in (await getTable(env)).per_token['grok-4.7'], false);
  db.close();
});
