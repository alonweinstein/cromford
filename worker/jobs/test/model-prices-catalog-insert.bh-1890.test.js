import test from 'node:test';
import assert from 'node:assert/strict';
import worker from '../src/index.js';
import { d1 } from './lib/d1-sqlite.bh-1030.js';

// BH-1890: a `source=catalog` POST to /api/model-prices only INSERTS. The
// deploy hook (bin/model-prices-deploy-sync.sh) POSTs the models the table
// lacked at its GET, and the 04:30Z refresh can land a live `openrouter` rate
// between that GET and this POST. With the old DO UPDATE upsert the committed
// catalog rate then replaced the live one. Every other source keeps upserting.
//
// Through worker.fetch, the production entry point, on a node:sqlite database
// that never saw schema.sql (the route creates its own table). The per-row
// source is not in the GET body, so it is read from the table directly.

const SECRET = 'test-secret';

let DatabaseSync = null;
try { ({ DatabaseSync } = await import('node:sqlite')); } catch { DatabaseSync = null; }

const req = (method, path, body) => new Request(`https://jobs.test${path}`, {
  method,
  headers: { authorization: `Bearer ${SECRET}`, 'content-type': 'application/json' },
  body: body === undefined ? undefined : JSON.stringify(body),
});

function fresh() {
  const db = new DatabaseSync(':memory:');
  return { db, env: { DB: d1(db), HARNESS_SECRET: SECRET } };
}

async function post(env, source, rows) {
  const res = await worker.fetch(req('POST', '/api/model-prices', { source, rows }), env);
  assert.equal(res.status, 200, `POST source=${source}: ${await res.clone().text()}`);
  return res.json();
}

const row = (db, model) => db.prepare('SELECT model, prompt, completion, source FROM model_prices WHERE model=?').get(model);

test('W1: a catalog POST never replaces a row the refresh wrote', async (t) => {
  if (!DatabaseSync) { t.skip('node:sqlite unavailable on this runtime'); return; }
  const { db, env } = fresh();
  await post(env, 'openrouter', [{ model: 'claude-opus-5-5', prompt: 6.1e-6, completion: 3.05e-5 }]);
  await post(env, 'catalog', [{ model: 'claude-opus-5-5', prompt: 6e-6, completion: 3e-5 }]);
  const r = row(db, 'claude-opus-5-5');
  assert.equal(r.source, 'openrouter', 'the live row keeps its source');
  assert.equal(r.prompt, 6.1e-6, 'the live rate stands');
  assert.equal(r.completion, 3.05e-5);

  const get = await worker.fetch(req('GET', '/api/model-prices'), env);
  assert.equal((await get.json()).per_token['claude-opus-5-5'].prompt, 6.1e-6, 'the GET serves the live rate');
  db.close();
});

test('W2: a catalog POST still inserts a model the table lacks', async (t) => {
  if (!DatabaseSync) { t.skip('node:sqlite unavailable on this runtime'); return; }
  const { db, env } = fresh();
  await post(env, 'catalog', [{ model: 'claude-opus-5-5', prompt: 6e-6, completion: 3e-5 }]);
  const r = row(db, 'claude-opus-5-5');
  assert.ok(r, 'the absent model is inserted');
  assert.equal(r.source, 'catalog');
  assert.equal(r.prompt, 6e-6);
  db.close();
});

test('W3: a non-catalog POST still upserts over a catalog row', async (t) => {
  if (!DatabaseSync) { t.skip('node:sqlite unavailable on this runtime'); return; }
  const { db, env } = fresh();
  await post(env, 'catalog', [{ model: 'claude-opus-5-5', prompt: 6e-6, completion: 3e-5 }]);
  await post(env, 'openrouter', [{ model: 'claude-opus-5-5', prompt: 5.5e-6, completion: 2.75e-5 }]);
  const r = row(db, 'claude-opus-5-5');
  assert.equal(r.source, 'openrouter', 'the refresh replaces the catalog row');
  assert.equal(r.prompt, 5.5e-6);
  db.close();
});

test('W4: a multi-row catalog POST inserts the absent row and leaves the present one', async (t) => {
  if (!DatabaseSync) { t.skip('node:sqlite unavailable on this runtime'); return; }
  const { db, env } = fresh();
  await post(env, 'openrouter', [{ model: 'claude-sonnet-5', prompt: 3.1e-6, completion: 1.5e-5 }]);
  const body = await post(env, 'catalog', [
    { model: 'claude-sonnet-5', prompt: 3e-6, completion: 1.5e-5 },
    { model: 'claude-opus-5-5', prompt: 6e-6, completion: 3e-5 },
  ]);
  assert.equal(body.accepted, 2);
  const s = row(db, 'claude-sonnet-5');
  assert.equal(s.source, 'openrouter');
  assert.equal(s.prompt, 3.1e-6);
  const o = row(db, 'claude-opus-5-5');
  assert.ok(o, 'the absent model is inserted in the same batch');
  assert.equal(o.source, 'catalog');
  db.close();
});
