import test from 'node:test';
import assert from 'node:assert/strict';
import worker, { ROUTES } from '../src/index.js';
import { matchRoute } from '../src/lib/router.js';

// BH-3425 (BH-3422.0) — the model-watch contract routes are routed and behind
// the bearer. Their bodies are pinned by model-watch.bh-3426.test.js.

const SECRET = 's3cret';
const CALLS = [
  ['POST', '/api/model-watch'],
  ['GET', '/api/model-watch'],
  ['PUT', '/api/model-watch/state'],
  ['GET', '/api/model-watch/usage'],
];
const DB = new Proxy({}, { get() { throw new Error('an unauthenticated model-watch call touched the DB'); } });

function req(method, path, headers = {}) {
  const init = { method, headers: { 'content-type': 'application/json', ...headers } };
  if (method !== 'GET') init.body = JSON.stringify({ vendor: 'acme', model_id: 'm-1' });
  return new Request(`https://jobs.example${path}`, init);
}

test('R1 through worker.fetch: no bearer is a 401 on every model-watch route, DB untouched', async () => {
  for (const [method, path] of CALLS) {
    const res = await worker.fetch(req(method, path), { DB, HARNESS_SECRET: SECRET });
    assert.equal(res.status, 401, `${method} ${path} without a bearer`);
  }
});

test('R2 each (method, path) resolves to its own ROUTES entry; usage is not swallowed by the list route', () => {
  const hits = CALLS.map(([m, p]) => matchRoute(ROUTES, m, p));
  for (let i = 0; i < CALLS.length; i++) assert.ok(hits[i], `${CALLS[i].join(' ')} is routed`);
  assert.equal(new Set(hits.map((h) => h.entry)).size, CALLS.length, 'four distinct entries');
  assert.equal(hits[3].entry[1], '/api/model-watch/usage');
  assert.equal(matchRoute(ROUTES, 'DELETE', '/api/model-watch'), null);
});
