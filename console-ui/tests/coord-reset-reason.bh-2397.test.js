import test from 'node:test';
import assert from 'node:assert/strict';
import { onRequest } from '../functions/api/coord/[[path]].js';

// BH-2397 item 2: the call-guard RESET reason is enforced at the coord proxy,
// not only in the browser. A DELETE /api/coord/call-guard with a missing,
// empty or whitespace reason is a 400 and never reaches the jobs worker (whose
// "manual reset" default stays, for the box CLI's own path).

const JOBS = 'https://harness-jobs.operator.workers.dev';
const SECRET = 'test-harness-secret';

// Same shape as tests/coord-live-fn.test.js: the session probe answered by URL,
// every other fetch recorded as an upstream call.
function stubFetch({ consoleStatus = 200 } = {}) {
  const seen = [];
  const real = globalThis.fetch;
  globalThis.fetch = async (input, init = {}) => {
    const target = typeof input === 'string' ? input : input.url;
    if (target.startsWith('https://harness-console.operator.workers.dev')) {
      return new Response('', { status: consoleStatus });
    }
    seen.push({ url: target, method: init.method });
    return new Response(JSON.stringify({ reset: 1 }), {
      status: 200, headers: { 'content-type': 'application/json' }
    });
  };
  return { seen, restore: () => { globalThis.fetch = real; } };
}

let cookieSeq = 0;
const del = (search) => onRequest({
  request: new Request(`https://console.example.pages.dev/api/coord/call-guard${search}`, {
    method: 'DELETE', headers: { cookie: `dash=reason${++cookieSeq}` }
  }),
  env: { HARNESS_SECRET: SECRET },
  params: { path: ['call-guard'] }
});

const BASE = '?project=project-5&stage=review&fp=abc';

test('a missing, empty or whitespace reason is a 400 with zero upstream calls', async () => {
  for (const tail of ['', '&reason=', '&reason=%20%20%20', '&reason=+%09+']) {
    const f = stubFetch();
    try {
      const res = await del(BASE + tail);
      assert.equal(res.status, 400, `reason tail ${JSON.stringify(tail)}`);
      assert.match(JSON.parse(await res.text()).error, /reason is required/);
      assert.equal(f.seen.length, 0, `reason tail ${JSON.stringify(tail)} reached the jobs worker`);
    } finally {
      f.restore();
    }
  }
});

test('a real reason is forwarded once, actor stamped console', async () => {
  const f = stubFetch();
  try {
    const res = await del(`${BASE}&reason=why&actor=mallory`);
    assert.equal(res.status, 200);
    assert.equal(f.seen.length, 1);
    const u = new URL(f.seen[0].url);
    assert.equal(`${u.origin}${u.pathname}`, `${JOBS}/api/call-guard`);
    assert.equal(f.seen[0].method, 'DELETE');
    assert.equal(u.searchParams.get('reason'), 'why');
    assert.deepEqual(u.searchParams.getAll('actor'), ['console']);
  } finally {
    f.restore();
  }
});

test('an unauthenticated DELETE with a blank reason is still a 403: auth runs first', async () => {
  const f = stubFetch({ consoleStatus: 401 });
  try {
    const res = await del(`${BASE}&reason=`);
    assert.equal(res.status, 403);
    assert.equal(f.seen.length, 0);
  } finally {
    f.restore();
  }
});

test('the reason check is scoped to DELETE call-guard: a GET call-guard with no reason still passes', async () => {
  const f = stubFetch();
  try {
    const res = await onRequest({
      request: new Request('https://console.example.pages.dev/api/coord/call-guard?hours=24', {
        headers: { cookie: `dash=reason${++cookieSeq}` }
      }),
      env: { HARNESS_SECRET: SECRET },
      params: { path: ['call-guard'] }
    });
    assert.equal(res.status, 200);
    assert.equal(f.seen.length, 1);
  } finally {
    f.restore();
  }
});
