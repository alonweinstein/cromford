import test from 'node:test';
import assert from 'node:assert/strict';
import { onRequest } from '../functions/api/coord/[[path]].js';

// BH-5839: the ticket page's Step in composer writes through the coord proxy
// as POST `steer` exactly. The proxy stamps the actor, forwards only the five
// composer fields as strings, and keeps the box-side steer routes (take,
// settle, claim, the delivered report and the outbox GET) at 405 from a browser. Same harness shape as
// coord-write-allowlist.bh-2405.test.js.

const JOBS = 'https://harness-jobs.operator.workers.dev';
const CONSOLE = 'https://harness-console.operator.workers.dev';
const SECRET = 'fixture-harness-secret';

function stubFetch() {
  const seen = [];
  const real = globalThis.fetch;
  globalThis.fetch = async (input, init = {}) => {
    const target = typeof input === 'string' ? input : input.url;
    if (target.startsWith(CONSOLE)) return new Response('', { status: 200 });
    seen.push({ url: target, method: init.method, body: init.body });
    return new Response('{}', { status: 200, headers: { 'content-type': 'application/json' } });
  };
  return { seen, restore: () => { globalThis.fetch = real; } };
}

let cookieSeq = 0;
const call = (rest, method, body, search = '') =>
  onRequest({
    request: new Request(`https://console.example.pages.dev/api/coord/${rest}${search}`, {
      method,
      headers: { cookie: `dash=bh5839-${++cookieSeq}`, 'content-type': 'application/json' },
      body
    }),
    env: { HARNESS_SECRET: SECRET },
    params: { path: rest.split('/') }
  });

const NOTE = {
  project: 'cromford', ticket: 'BH-5839', job_id: 'build-cromford-BH-5839-1', mode: 'now', text: 'Use the helper'
};

test('P1 POST steer forwards the five composer fields and the stamped actor; actor and extras from the browser never travel', async () => {
  const f = stubFetch();
  try {
    const res = await call('steer', 'POST', JSON.stringify({ ...NOTE, actor: 'mallory', smuggled: 1 }), '?actor=mallory');
    assert.equal(res.status, 200);
    assert.equal(f.seen.length, 1);
    assert.equal(f.seen[0].url, `${JOBS}/api/steer`, 'no query string travels on a body write');
    assert.equal(f.seen[0].method, 'POST');
    const fwd = JSON.parse(f.seen[0].body);
    assert.deepEqual(Object.keys(fwd).sort(), ['actor', 'job_id', 'mode', 'project', 'text', 'ticket']);
    assert.equal(fwd.actor, 'console');
    for (const k of Object.keys(NOTE)) assert.equal(fwd[k], NOTE[k], k);
    assert.equal('smuggled' in fwd, false);
  } finally { f.restore(); }
});

test('P2 the box-side steer routes (the outbox GET too) and other verbs on steer stay 405 and forward nothing', async () => {
  const f = stubFetch();
  try {
    for (const [rest, method] of [
      ['steer/take', 'POST'], ['steer/settle', 'POST'], ['steer/1/claim', 'POST'], ['steer/1/delivered', 'POST'],
      ['steer', 'PUT'], ['steer', 'DELETE'], ['steer/outbox', 'POST'], ['steer/outbox', 'GET']
    ]) {
      const res = await call(rest, method, method === 'GET' ? undefined : JSON.stringify({ job_id: 'x', ok: true }));
      assert.equal(res.status, 405, `${method} ${rest}`);
      assert.equal((await res.json()).error, `method ${method} not allowed on /api/coord/${rest}`);
    }
    assert.equal(f.seen.length, 0);
  } finally { f.restore(); }
});

test('P3 a non-string field is not forwarded (ok: isStr), so the worker never sees a number for mode', async () => {
  const f = stubFetch();
  try {
    await call('steer', 'POST', JSON.stringify({ ...NOTE, mode: 1, job_id: { id: 'x' } }));
    assert.equal(f.seen.length, 1);
    const fwd = JSON.parse(f.seen[0].body);
    assert.equal('mode' in fwd, false, 'a numeric mode is dropped');
    assert.equal('job_id' in fwd, false, 'an object job_id is dropped');
    assert.equal(fwd.text, NOTE.text);
    assert.equal(fwd.actor, 'console');
  } finally { f.restore(); }
});

test('P4 the page read GET steer still passes: only the outbox GET is box-only', async () => {
  const f = stubFetch();
  try {
    const res = await call('steer', 'GET', undefined, '?project=cromford&ticket=BH-5839');
    assert.equal(res.status, 200);
    assert.equal(f.seen.length, 1);
    assert.match(f.seen[0].url, /\/api\/steer\?project=cromford&ticket=BH-5839$/);
  } finally { f.restore(); }
});
