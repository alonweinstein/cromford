import test from 'node:test';
import assert from 'node:assert/strict';
import { onRequest } from '../functions/api/coord/[[path]].js';

// BH-2105: the coord proxy's write allowlist gains exactly one path, POST
// hub/promote, so the /hub PROMOTE modal reaches the jobs worker. The proxy
// forwards the body untouched; the worker enforces confirm:true and
// expected_epoch. Every other hub write stays 405 from a browser.

const JOBS = 'https://harness-jobs.operator.workers.dev';
const SECRET = 'test-harness-secret';

function stubFetch(status = 200, payload = { ok: true, epoch_before: 7, epoch_after: 8 }) {
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
const call = (rest, method, body, path = rest.split('/').filter(Boolean)) =>
  onRequest({
    request: new Request(`https://console.example.pages.dev/api/coord/${rest}`, {
      method,
      headers: { cookie: `dash=hubpromote${++cookieSeq}`, 'content-type': 'application/json' },
      body
    }),
    env: { HARNESS_SECRET: SECRET },
    params: { path }
  });

const SENT = JSON.stringify({
  target: 'box-2', expected_epoch: 7, actor: 'console', reason: 'drill', confirm: true
});

test('POST hub/promote is forwarded to the jobs worker with the bearer and the untouched body', async () => {
  const f = stubFetch();
  try {
    const res = await call('hub/promote', 'POST', SENT);
    assert.equal(res.status, 200);
    assert.deepEqual(JSON.parse(await res.text()), { ok: true, epoch_before: 7, epoch_after: 8 });
    assert.equal(f.seen.length, 1);
    assert.equal(f.seen[0].url, `${JOBS}/api/hub/promote`);
    assert.equal(f.seen[0].method, 'POST');
    assert.equal(f.seen[0].headers.authorization, `Bearer ${SECRET}`);
    assert.equal(f.seen[0].body, SENT);
    const fwd = JSON.parse(f.seen[0].body);
    assert.equal(fwd.confirm, true);
    assert.equal(fwd.expected_epoch, 7);
  } finally { f.restore(); }
});

test('a worker refusal (409 stale_epoch) passes straight through, not as a success', async () => {
  const f = stubFetch(409, { error: 'stale_epoch' });
  try {
    const res = await call('hub/promote', 'POST', SENT);
    assert.equal(res.status, 409);
    assert.deepEqual(JSON.parse(await res.text()), { error: 'stale_epoch' });
    assert.equal(f.seen.length, 1);
  } finally { f.restore(); }
});

test('every other hub verb and path stays 405 and never reaches the worker', async () => {
  const f = stubFetch();
  try {
    for (const [rest, method, path] of [
      ['hub/promote', 'PUT'],
      ['hub/promote', 'DELETE'],
      ['hub/promote', 'PATCH'],
      ['hub/promote/x', 'POST'],
      // What the handler sees if the router keeps a trailing empty segment.
      ['hub/promote/', 'POST', ['hub', 'promote', '']],
      ['hub/lease/promote', 'POST'],
      ['hub-lease/promote', 'POST'],
      ['hub/lease/renew', 'POST'],
      ['hub/restore-lab/claim', 'POST'],
      ['hub/recovery', 'POST'],
      ['hub/lease', 'PUT'],
      ['hub', 'POST'],
      ['HUB/PROMOTE', 'POST']
    ]) {
      const res = await call(rest, method, method === 'GET' ? undefined : SENT, path);
      assert.equal(res.status, 405, `${method} /${rest}`);
      assert.match(await res.text(), /not allowed/, `${method} /${rest}`);
    }
    assert.equal(f.seen.length, 0, `reached the jobs worker: ${JSON.stringify(f.seen.map((s) => s.url))}`);
  } finally { f.restore(); }
});
