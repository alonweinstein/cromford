import test from 'node:test';
import assert from 'node:assert/strict';
import { onRequest } from '../functions/api/coord/[[path]].js';

// BH-2519 (BH-2642): the coord proxy's write table gains exactly one row, POST
// hub/standby/verify with {box, confirm}. The actor is stamped by the proxy, a
// browser of_hub never travels, and the box-side verify routes (claim,
// <id>/result, heartbeat) stay 405 from a browser.

const JOBS = 'https://harness-jobs.operator.workers.dev';
const SECRET = 'test-harness-secret';

function stubFetch() {
  const seen = [];
  const real = globalThis.fetch;
  globalThis.fetch = async (input, init = {}) => {
    const target = typeof input === 'string' ? input : input.url;
    if (target.startsWith('https://harness-console.operator.workers.dev')) return new Response('', { status: 200 });
    seen.push({ url: target, method: init.method, headers: init.headers || {}, body: init.body });
    return new Response(JSON.stringify({ id: 5, status: 'requested', deduped: false }), {
      status: 201, headers: { 'content-type': 'application/json' }
    });
  };
  return { seen, restore: () => { globalThis.fetch = real; } };
}

let cookieSeq = 0;
const call = (rest, method, body) =>
  onRequest({
    request: new Request(`https://console.example.pages.dev/api/coord/${rest}`, {
      method,
      headers: { cookie: `dash=standbyverify${++cookieSeq}`, 'content-type': 'application/json' },
      body
    }),
    env: { HARNESS_SECRET: SECRET },
    params: { path: rest.split('/') }
  });

test('X1: POST hub/standby/verify forwards {box, confirm} plus the stamped actor, never of_hub or the browser actor', async () => {
  const f = stubFetch();
  try {
    const res = await call('hub/standby/verify', 'POST',
      JSON.stringify({ box: 'sb-1', confirm: true, actor: 'evil', of_hub: 'x' }));
    assert.equal(res.status, 201);
    assert.equal(f.seen.length, 1);
    assert.equal(f.seen[0].url, `${JOBS}/api/hub/standby/verify`);
    assert.equal(f.seen[0].method, 'POST');
    assert.equal(f.seen[0].headers.authorization, `Bearer ${SECRET}`);
    const body = JSON.parse(f.seen[0].body);
    assert.deepEqual(body, { box: 'sb-1', confirm: true, actor: 'console' });
    assert.notEqual(body.actor, 'evil');
    assert.equal('of_hub' in body, false);
  } finally { f.restore(); }
});

test('X2: the box-side verify routes and a PUT answer 405 and never reach the worker', async () => {
  const f = stubFetch();
  try {
    const body = JSON.stringify({ box: 'sb-1', confirm: true });
    for (const [rest, method] of [
      ['hub/standby/verify/claim', 'POST'],
      ['hub/standby/verify/7/result', 'POST'],
      ['hub/standby/heartbeat', 'POST'],
      ['hub/standby/verify', 'PUT'],
    ]) {
      const res = await call(rest, method, body);
      assert.equal(res.status, 405, `${method} ${rest}`);
    }
    assert.equal(f.seen.length, 0, 'nothing reached the jobs worker');
  } finally { f.restore(); }
});

test('X3: POST hub/restore-lab still forwards {box, snapshot, confirm, actor}', async () => {
  const f = stubFetch();
  try {
    const res = await call('hub/restore-lab', 'POST', JSON.stringify({ box: 'hub-1', snapshot: 'latest', confirm: true }));
    assert.equal(res.status, 201);
    assert.equal(f.seen.length, 1);
    assert.equal(f.seen[0].url, `${JOBS}/api/hub/restore-lab`);
    assert.deepEqual(JSON.parse(f.seen[0].body), { box: 'hub-1', snapshot: 'latest', confirm: true, actor: 'console' });
  } finally { f.restore(); }
});
