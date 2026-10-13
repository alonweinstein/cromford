import test from 'node:test';
import assert from 'node:assert/strict';
import { onRequest } from '../functions/api/coord/[[path]].js';
import { api } from '../src/api.js';

// BH-5643 (BH-5635.4). A flag row carries an optional `value` (a wip limit is
// a flag whose file holds a number). The coord proxy's PUT `flags` row admits
// it beside name/active/reason, still stamps the actor itself and still drops
// any other key. api.setFlag is the console's writer for it. P1-P3 go through
// the real Pages onRequest with globalThis.fetch stubbed, the
// coord-write-allowlist.bh-2405 way; P4 drives the real api.js.

const JOBS = 'https://harness-jobs.operator.workers.dev';
const CONSOLE = 'https://harness-console.operator.workers.dev';

function stubFetch() {
  const seen = [];
  const real = globalThis.fetch;
  globalThis.fetch = async (input, init = {}) => {
    const target = typeof input === 'string' ? input : input.url;
    if (target.startsWith(CONSOLE)) return new Response('', { status: 200 });
    seen.push({ url: target, method: init.method, body: init.body });
    return new Response('{"ok":true}', { status: 200, headers: { 'content-type': 'application/json' } });
  };
  return { seen, restore: () => { globalThis.fetch = real; } };
}

let cookieSeq = 0;
const putFlags = (body) =>
  onRequest({
    request: new Request('https://console.example.pages.dev/api/coord/flags', {
      method: 'PUT',
      headers: { cookie: `dash=bh5643-${++cookieSeq}`, 'content-type': 'application/json' },
      body
    }),
    env: { HARNESS_SECRET: 'test-harness-secret-fixture' },
    params: { path: ['flags'] }
  });

test('P1: PUT flags forwards value to the worker', async () => {
  const f = stubFetch();
  try {
    const res = await putFlags(JSON.stringify({ name: 'wip-limit-a', active: 1, value: '5', reason: 'r' }));
    assert.equal(res.status, 200);
    assert.equal(f.seen.length, 1);
    assert.equal(f.seen[0].url, `${JOBS}/api/flags`);
    assert.equal(f.seen[0].method, 'PUT');
    assert.deepEqual(JSON.parse(f.seen[0].body), { name: 'wip-limit-a', active: 1, value: '5', reason: 'r', actor: 'console' });
  } finally { f.restore(); }
});

test('P2: PUT flags drops smuggled and __proto__ keys', async () => {
  const f = stubFetch();
  try {
    await putFlags('{"name":"wip-limit-a","active":1,"value":"5","smuggled":1,"__proto__":{"x":1}}');
    const sent = JSON.parse(f.seen[0].body);
    assert.deepEqual(Object.keys(sent).sort(), ['active', 'actor', 'name', 'value']);
    assert.equal(Object.prototype.hasOwnProperty.call(sent, '__proto__'), false);
    assert.equal(sent.smuggled, undefined);
  } finally { f.restore(); }
});

test('P3: a browser actor on PUT flags is replaced by the stamped actor', async () => {
  const f = stubFetch();
  try {
    await putFlags(JSON.stringify({ name: 'paused-a', active: 1, value: '3', actor: 'mallory', reason: 'r' }));
    const sent = JSON.parse(f.seen[0].body);
    assert.equal(sent.actor, 'console');
    assert.equal(sent.value, '3');
  } finally { f.restore(); }
});

test('P4: api.setFlag sends value as a string only when given, with no actor', async () => {
  const calls = [];
  const real = globalThis.fetch;
  globalThis.fetch = async (url, init = {}) => {
    calls.push({ url: String(url), method: init.method, body: JSON.parse(init.body) });
    return { ok: true, status: 200, text: async () => '{"ok":true}' };
  };
  try {
    await api.setFlag('wip-limit-x', true, 5, 'r');
    await api.setFlag('paused-x', false, null, 'r');
    assert.equal(calls.length, 2);
    assert.equal(calls[0].url, '/api/coord/flags');
    assert.equal(calls[0].method, 'PUT');
    assert.deepEqual(calls[0].body, { name: 'wip-limit-x', active: 1, reason: 'r', value: '5' });
    assert.deepEqual(calls[1].body, { name: 'paused-x', active: 0, reason: 'r' });
    assert.equal('value' in calls[1].body, false);
    assert.equal('actor' in calls[0].body, false);
  } finally { globalThis.fetch = real; }
});
