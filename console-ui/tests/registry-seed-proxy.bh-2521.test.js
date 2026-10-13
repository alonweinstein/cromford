import test from 'node:test';
import assert from 'node:assert/strict';
import { onRequest } from '../functions/api/coord/[[path]].js';
import { api } from '../src/api.js';

// BH-2521 (contract slice BH-2675): the coord proxy admits exactly two new
// writes, the /hub SEED REGISTRY apply (POST settings/seed-registry/apply) and
// the CHAT BINDINGS edit (PUT telegram-topics). Both carry the proxy-stamped
// actor and only their listed, typed fields. The plain CLI seed verb, POST
// settings/seed-registry, stays 405 from a browser.

const JOBS = 'https://harness-jobs.operator.workers.dev';
const SECRET = 'test-harness-secret';

function stubFetch() {
  const seen = [];
  const real = globalThis.fetch;
  globalThis.fetch = async (input, init = {}) => {
    const target = typeof input === 'string' ? input : input.url;
    if (target.startsWith('https://harness-console.operator.workers.dev')) return new Response('', { status: 200 });
    seen.push({ url: target, method: init.method, headers: init.headers || {}, body: init.body });
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
      headers: { cookie: `dash=seedreg${++cookieSeq}`, 'content-type': 'application/json' },
      body
    }),
    env: { HARNESS_SECRET: SECRET },
    params: { path: rest.split('/') }
  });

const FP = 'a'.repeat(64);

test('POST settings/seed-registry/apply forwards plan_fp and the stamped actor, nothing else', async () => {
  const f = stubFetch();
  try {
    const res = await call('settings/seed-registry/apply', 'POST',
      JSON.stringify({ plan_fp: FP, reason: 'r', actor: 'mallory', prune: true }));
    assert.equal(res.status, 200);
    assert.equal(f.seen.length, 1);
    assert.equal(f.seen[0].url, `${JOBS}/api/settings/seed-registry/apply`);
    assert.equal(f.seen[0].method, 'POST');
    assert.equal(f.seen[0].headers.authorization, `Bearer ${SECRET}`);
    assert.deepEqual(JSON.parse(f.seen[0].body), { plan_fp: FP, reason: 'r', actor: 'console' });
  } finally { f.restore(); }
});

test('a non-string plan_fp is dropped before the worker', async () => {
  const f = stubFetch();
  try {
    for (const plan_fp of [123, [FP], { fp: FP }, null, true]) {
      await call('settings/seed-registry/apply', 'POST', JSON.stringify({ plan_fp, reason: 'r' }));
    }
    assert.equal(f.seen.length, 5);
    for (const s of f.seen) assert.deepEqual(JSON.parse(s.body), { reason: 'r', actor: 'console' }, s.body);
  } finally { f.restore(); }
});

test('the plain CLI seed verb and its siblings stay 405 and never reach the worker', async () => {
  const f = stubFetch();
  try {
    for (const [rest, method] of [
      ['settings/seed-registry', 'POST'],
      ['settings/seed-registry/plan', 'POST'],
      ['settings/seed-registry/apply', 'PUT'],
      ['settings/seed-registry/apply/', 'POST'],
      ['telegram-topics', 'POST'],
      ['telegram-topics/project-3', 'PUT']
    ]) {
      const res = await call(rest, method, JSON.stringify({ plan_fp: FP, project: 'project-3', thread_id: 1 }));
      assert.equal(res.status, 405, `${method} ${rest}`);
    }
    assert.equal(f.seen.length, 0);
  } finally { f.restore(); }
});

test('PUT telegram-topics forwards project, thread_id and the stamped actor only', async () => {
  const f = stubFetch();
  try {
    const res = await call('telegram-topics', 'PUT',
      JSON.stringify({ project: 'project-3', thread_id: 12, reason: 'r', actor: 'mallory', x: 1 }));
    assert.equal(res.status, 200);
    assert.equal(f.seen.length, 1);
    assert.equal(f.seen[0].url, `${JOBS}/api/telegram-topics`);
    assert.equal(f.seen[0].method, 'PUT');
    assert.deepEqual(JSON.parse(f.seen[0].body), { project: 'project-3', thread_id: 12, reason: 'r', actor: 'console' });
  } finally { f.restore(); }
});

test('PUT telegram-topics drops a non-integer thread_id and a non-string project', async () => {
  const f = stubFetch();
  try {
    for (const thread_id of ['12', 12.5, null, true, [12]]) {
      await call('telegram-topics', 'PUT', JSON.stringify({ project: 'project-3', thread_id, reason: 'r' }));
    }
    await call('telegram-topics', 'PUT', JSON.stringify({ project: 5, thread_id: 7, reason: 'r' }));
    assert.equal(f.seen.length, 6);
    for (const s of f.seen.slice(0, 5)) assert.deepEqual(JSON.parse(s.body), { project: 'project-3', reason: 'r', actor: 'console' }, s.body);
    assert.deepEqual(JSON.parse(f.seen[5].body), { thread_id: 7, reason: 'r', actor: 'console' });
  } finally { f.restore(); }
});

test('the five api methods hit the exact URL, method and body, with no actor', async () => {
  const seen = [];
  const real = globalThis.fetch;
  globalThis.fetch = async (url, init = {}) => {
    seen.push({ url, method: init.method || 'GET', body: init.body });
    return new Response('{"ok":true}', { status: 200, headers: { 'content-type': 'application/json' } });
  };
  try {
    await api.seedPlan();
    await api.seedApply(FP, 'why');
    await api.seedRuns();
    await api.telegramTopics();
    await api.telegramTopicSet('project-3', 12, 'why');
  } finally { globalThis.fetch = real; }
  assert.deepEqual(seen, [
    { url: '/api/coord/settings/seed-registry/plan', method: 'GET', body: undefined },
    { url: '/api/coord/settings/seed-registry/apply', method: 'POST', body: JSON.stringify({ plan_fp: FP, reason: 'why' }) },
    { url: '/api/coord/settings/seed-registry/runs', method: 'GET', body: undefined },
    { url: '/api/coord/telegram-topics', method: 'GET', body: undefined },
    { url: '/api/coord/telegram-topics', method: 'PUT', body: JSON.stringify({ project: 'project-3', thread_id: 12, reason: 'why' }) }
  ]);
});
