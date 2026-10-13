import test from 'node:test';
import assert from 'node:assert/strict';
import { onRequest } from '../functions/api/coord/[[path]].js';

// BH-2369 (BH-2324 child 2): the coord proxy opens exactly one alerts write,
// POST alerts/actions, and stamps its actor as the console. Every other alerts
// write a browser could aim at stays 405 (D15).

const JOBS = 'https://harness-jobs.operator.workers.dev';
const SECRET = 'test-harness-secret';

function stubFetch(status = 200, payload = { alert: { id: 'a1', state: 'triaged' }, action: { id: 1 }, as_of: 'T' }) {
  const seen = [];
  const real = globalThis.fetch;
  globalThis.fetch = async (input, init = {}) => {
    const target = typeof input === 'string' ? input : input.url;
    if (target.startsWith('https://harness-console.operator.workers.dev')) return new Response('', { status: 200 });
    seen.push({ url: target, method: init.method, headers: init.headers || {}, body: init.body });
    return new Response(JSON.stringify(payload), { status, headers: { 'content-type': 'application/json' } });
  };
  return { seen, restore: () => { globalThis.fetch = real; } };
}

let cookieSeq = 0;
const call = (rest, method, body) =>
  onRequest({
    request: new Request(`https://console.example.pages.dev/api/coord/${rest}`, {
      method,
      headers: { cookie: `dash=alertactions${++cookieSeq}`, 'content-type': 'application/json' },
      body
    }),
    env: { HARNESS_SECRET: SECRET },
    params: { path: rest.split('/').filter(Boolean) }
  });

test('POST alerts/actions is forwarded with the bearer and the actor stamped as the console', async () => {
  const f = stubFetch();
  try {
    const res = await call('alerts/actions', 'POST', JSON.stringify({ id: 'a1', action: 'ack', actor: 'medic@hub', note: 'n' }));
    assert.equal(res.status, 200);
    assert.equal(f.seen.length, 1);
    assert.equal(f.seen[0].url, `${JOBS}/api/alerts/actions`);
    assert.equal(f.seen[0].method, 'POST');
    assert.equal(f.seen[0].headers.authorization, `Bearer ${SECRET}`);
    assert.deepEqual(JSON.parse(f.seen[0].body), { id: 'a1', action: 'ack', actor: 'console', note: 'n' });
  } finally { f.restore(); }
});

test('a body that is not a JSON object is a 400 and never reaches the worker', async () => {
  const f = stubFetch();
  try {
    for (const body of ['[1]', '"x"', 'not json', 'null']) {
      const res = await call('alerts/actions', 'POST', body);
      assert.equal(res.status, 400, `400 for ${body}`);
    }
    assert.equal(f.seen.length, 0);
  } finally { f.restore(); }
});

test('a worker 409 passes straight through', async () => {
  const f = stubFetch(409, { error: 'claimed', claimed_by: 'medic@hub', as_of: 'T' });
  try {
    const res = await call('alerts/actions', 'POST', JSON.stringify({ id: 'a1', action: 'snooze' }));
    assert.equal(res.status, 409);
    assert.deepEqual(JSON.parse(await res.text()), { error: 'claimed', claimed_by: 'medic@hub', as_of: 'T' });
    assert.equal(f.seen.length, 1);
  } finally { f.restore(); }
});

test('every other alerts write stays 405 and never fetches', async () => {
  const f = stubFetch();
  try {
    for (const [rest, method] of [
      ['alerts/state', 'PATCH'],
      ['alerts/resolve', 'POST'],
      ['alerts/claim', 'POST'],
      ['alerts/note', 'POST'],
      ['alerts/flush', 'POST'],
      ['alerts/actions', 'PUT'],
      ['alerts/actions', 'PATCH'],
      ['alerts/actions', 'DELETE'],
      ['alerts/actions/x', 'POST'],
    ]) {
      const res = await call(rest, method, JSON.stringify({ id: 'a1' }));
      assert.equal(res.status, 405, `${method} ${rest}`);
    }
    assert.equal(f.seen.length, 0);
  } finally { f.restore(); }
});

test('GET alerts/actions still passes through with its query', async () => {
  const f = stubFetch(200, { actions: [], truncated: false, as_of: 'T' });
  try {
    const res = await onRequest({
      request: new Request('https://console.example.pages.dev/api/coord/alerts/actions?id=a1&limit=5', {
        headers: { cookie: `dash=alertactions${++cookieSeq}` }
      }),
      env: { HARNESS_SECRET: SECRET },
      params: { path: ['alerts', 'actions'] }
    });
    assert.equal(res.status, 200);
    assert.equal(f.seen[0].url, `${JOBS}/api/alerts/actions?id=a1&limit=5`);
  } finally { f.restore(); }
});
