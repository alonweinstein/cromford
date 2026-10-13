import test from 'node:test';
import assert from 'node:assert/strict';
import { api } from '../src/api.js';
import { onRequest } from '../functions/api/coord/[[path]].js';
import { CostCapsSection } from '../src/screens/CostCaps.js';
import { CostCapHistorySection } from '../src/screens/CostCapHistory.js';

// BH-2563 (BH-2511.0): the console half of the cost-caps contract. The two
// api helpers build the coord URLs and never send an actor; the coord proxy
// admits a PUT to exactly `cost-caps` with the actor stamped, and nothing else
// on that path (the seed stays hub-bearer only); the two Costs-page sections
// are exported mount points (filled in by BH-2566 and BH-2567).

const JOBS = 'https://harness-jobs.operator.workers.dev';
const CONSOLE = 'https://harness-console.operator.workers.dev';

// ---- api helpers ----------------------------------------------------------
function captureFetch() {
  const calls = [];
  globalThis.fetch = async (url, init = {}) => {
    calls.push({ url: String(url), method: init.method || 'GET', body: init.body });
    return { ok: true, status: 200, text: async () => JSON.stringify({ ok: true }) };
  };
  return calls;
}

test('A1: putCostCap PUTs key/value/reason to /api/coord/cost-caps and sends no actor', async () => {
  const calls = captureFetch();
  await api.putCostCap({ key: 'conf.cost-caps.default', value: '100 5', reason: 'r' });
  assert.equal(calls.length, 1);
  assert.equal(calls[0].url, '/api/coord/cost-caps');
  assert.equal(calls[0].method, 'PUT');
  const body = JSON.parse(calls[0].body);
  assert.deepEqual(Object.keys(body), ['key', 'value', 'reason']);
  assert.deepEqual(body, { key: 'conf.cost-caps.default', value: '100 5', reason: 'r' });
});

test('A2: costCapChanges({key, limit}) GETs the audit trail with both parameters', async () => {
  const calls = captureFetch();
  await api.costCapChanges({ key: 'conf.cost-caps.default', limit: 20 });
  assert.equal(calls.length, 1);
  assert.equal(calls[0].method, 'GET');
  assert.equal(calls[0].url, '/api/coord/cost-cap-changes?key=conf.cost-caps.default&limit=20');
});

test('A3: costCapChanges() with no filter carries no query string', async () => {
  const calls = captureFetch();
  await api.costCapChanges();
  assert.deepEqual(calls.map((c) => c.url), ['/api/coord/cost-cap-changes']);
});

// ---- coord proxy ----------------------------------------------------------
function stubFetch() {
  const seen = [];
  globalThis.fetch = async (input, init = {}) => {
    const target = typeof input === 'string' ? input : input.url;
    if (target.startsWith(CONSOLE)) return new Response('', { status: 200 });
    seen.push({ url: target, method: init.method, body: init.body });
    return new Response('{}', { status: 200, headers: { 'content-type': 'application/json' } });
  };
  return seen;
}

let cookieSeq = 0;
const call = (rest, method, body, search = '') =>
  onRequest({
    request: new Request(`https://console.example.pages.dev/api/coord/${rest}${search}`, {
      method,
      headers: { cookie: `dash=bh2563-${++cookieSeq}`, 'content-type': 'application/json' },
      body
    }),
    env: { HARNESS_SECRET: 'test-harness-secret' },
    params: { path: rest.split('/') }
  });

test('X1: PUT cost-caps is forwarded once, allowlisted fields only, actor stamped console, no query', async () => {
  const seen = stubFetch();
  const legit = { key: 'conf.cost-caps.default', value: '100 5', reason: 'raise for the demo' };
  const res = await call('cost-caps', 'PUT', JSON.stringify({ ...legit, actor: 'mallory', smuggled: 1 }), '?actor=m');
  assert.equal(res.status, 200);
  assert.equal(seen.length, 1);
  assert.equal(seen[0].url, `${JOBS}/api/cost-caps`);
  assert.equal(seen[0].method, 'PUT');
  assert.deepEqual(JSON.parse(seen[0].body), { ...legit, actor: 'console' });
});

test('X2: POST cost-caps/seed is 405 and reaches nothing', async () => {
  const seen = stubFetch();
  const res = await call('cost-caps/seed', 'POST', JSON.stringify({ rows: [{ key: 'k', value: 'v' }] }));
  assert.equal(res.status, 405);
  assert.equal(seen.length, 0);
});

test('X3: PUT cost-caps/seed is 405 and reaches nothing', async () => {
  const seen = stubFetch();
  const res = await call('cost-caps/seed', 'PUT', JSON.stringify({ key: 'k', value: 'v', reason: 'r' }));
  assert.equal(res.status, 405);
  assert.equal(seen.length, 0);
});

test('X4: no other verb on cost-caps is admitted', async () => {
  const seen = stubFetch();
  for (const method of ['POST', 'DELETE', 'PATCH']) {
    const res = await call('cost-caps', method, method === 'DELETE' ? undefined : JSON.stringify({ key: 'k', value: 'v' }));
    assert.equal(res.status, 405, method);
  }
  assert.equal(seen.length, 0);
});

test('X5: GET cost-cap-changes is forwarded with its query intact', async () => {
  const seen = stubFetch();
  const res = await call('cost-cap-changes', 'GET', undefined, '?key=k&limit=5');
  assert.equal(res.status, 200);
  assert.equal(seen.length, 1);
  assert.equal(seen[0].url, `${JOBS}/api/cost-cap-changes?key=k&limit=5`);
});

// ---- mount points ---------------------------------------------------------
// BH-2566 filled in CostCapsSection and BH-2567 CostCapHistorySection (both
// hook-using components now, so a bare call throws); their renders are proved
// in cost-caps.bh-2511.test.js and cost-cap-history.bh-2511.test.js.
test('S1: both Costs-page sections are exported functions', () => {
  assert.equal(typeof CostCapsSection, 'function');
  assert.equal(typeof CostCapHistorySection, 'function');
});
