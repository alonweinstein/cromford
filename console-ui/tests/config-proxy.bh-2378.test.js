import test from 'node:test';
import assert from 'node:assert/strict';
import { onRequest } from '../functions/api/coord/[[path]].js';

// BH-2378 (BH-2330.3): the /config EDIT modal requires a reason, and the coord
// proxy's PUT settings row is what carries it to the worker. Driven through the
// real onRequest with fetch stubbed (the hub-write-reason-proxy.bh-2995 harness).

const SECRET = 'test-harness-secret';

function stubFetch() {
  const seen = [];
  const real = globalThis.fetch;
  globalThis.fetch = async (input, init = {}) => {
    const target = typeof input === 'string' ? input : input.url;
    if (target.startsWith('https://harness-console.operator.workers.dev')) return new Response('', { status: 200 });
    seen.push({ url: target, method: init.method, body: init.body });
    return new Response(JSON.stringify({ ok: true }), {
      status: 200, headers: { 'content-type': 'application/json' }
    });
  };
  return { seen, restore: () => { globalThis.fetch = real; } };
}

let cookieSeq = 0;
const call = (rest, method, body) =>
  onRequest({
    request: new Request(`https://console.example.pages.dev/api/coord/${rest}`, {
      method,
      headers: { cookie: `dash=bh2378-${++cookieSeq}`, 'content-type': 'application/json' },
      body
    }),
    env: { HARNESS_SECRET: SECRET },
    params: { path: rest.split('/') }
  });

test('P1: PUT settings forwards the reason, stamps the actor, and drops unknown fields', async () => {
  const f = stubFetch();
  try {
    const res = await call('settings', 'PUT', JSON.stringify({ key: 'gh.quota.reserve', value: '700', reason: 'raise', actor: 'mallory', x: 1 }));
    assert.equal(res.status, 200);
    assert.equal(f.seen.length, 1);
    assert.equal(f.seen[0].method, 'PUT');
    assert.deepEqual(JSON.parse(f.seen[0].body), { key: 'gh.quota.reserve', value: '700', reason: 'raise', actor: 'console' });
  } finally { f.restore(); }
});

test('P2: PUT settings with no reason is still forwarded (the SETTINGS page knob writes send none)', async () => {
  const f = stubFetch();
  try {
    const res = await call('settings', 'PUT', JSON.stringify({ key: 'lane.merge-conductor.mc_max_prs', value: '12', note: 'n' }));
    assert.equal(res.status, 200);
    assert.deepEqual(JSON.parse(f.seen[0].body), { key: 'lane.merge-conductor.mc_max_prs', value: '12', note: 'n', actor: 'console' });
  } finally { f.restore(); }
});
