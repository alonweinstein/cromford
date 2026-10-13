import test from 'node:test';
import assert from 'node:assert/strict';
import { onRequest } from '../functions/api/coord/[[path]].js';

// The same-origin path the live view polls: /api/coord/jobs/<id>/live?since=.
// BH-520 adds no code here on purpose — this function already forwards every
// GET — so this file is the proof that the route it now needs is actually
// covered by that forwarding, with the bearer attached in the Pages runtime and
// the dash cookie still the only thing that buys the call.

const JOBS = 'https://harness-jobs.operator.workers.dev';
const SECRET = 'test-harness-secret';

// The function delegates the session check to the console worker over the SAME
// fetch it uses for the upstream call, so the stub has to answer both: the
// probe by URL, and the jobs worker with a recorded, asserted request.
function stubFetch({ consoleStatus = 200, consoleThrows = false, upstream } = {}) {
  const seen = [];
  const real = globalThis.fetch;
  globalThis.fetch = async (input, init = {}) => {
    const target = typeof input === 'string' ? input : input.url;
    if (target.startsWith('https://harness-console.operator.workers.dev')) {
      if (consoleThrows) throw new Error('console unreachable');
      return new Response('', { status: consoleStatus });
    }
    seen.push({ url: target, method: init.method, headers: init.headers || {} });
    if (typeof upstream === 'function') return upstream(target, init);
    return new Response(JSON.stringify({ events: [], cursor: 7 }), {
      status: 200, headers: { 'content-type': 'application/json' }
    });
  };
  return { seen, restore: () => { globalThis.fetch = real; } };
}

// The function memoises "is this cookie signed in" for 60s, so every test needs
// its own cookie or the previous test's verdict answers for it.
let cookieSeq = 0;
const freshCookie = () => `dash=live${++cookieSeq}`;

const call = (rest, { method = 'GET', cookie = freshCookie(), search = '', bind = true } = {}) =>
  onRequest({
    request: new Request(`https://console.example.pages.dev/api/coord/${rest}${search}`, {
      method,
      headers: cookie ? { cookie } : {}
    }),
    env: bind ? { HARNESS_SECRET: SECRET } : {},
    params: { path: rest.split('/').filter(Boolean) }
  });

const body = async (res) => JSON.parse(await res.text());

test('a signed-in GET reaches the jobs worker at the live route, cursor and all', async () => {
  const f = stubFetch();
  try {
    const res = await call('jobs/j1/live', { search: '?since=7' });
    assert.equal(res.status, 200);
    assert.equal((await body(res)).cursor, 7);
    assert.equal(f.seen.length, 1);
    assert.equal(f.seen[0].url, `${JOBS}/api/jobs/j1/live?since=7`);
    assert.equal(f.seen[0].method, 'GET');
    assert.equal(f.seen[0].headers.authorization, `Bearer ${SECRET}`);
  } finally {
    f.restore();
  }
});

test('the upstream status is passed through, so a 400 cursor stays a 400', async () => {
  const f = stubFetch({
    upstream: () => new Response(JSON.stringify({ error: 'since must be an event id' }), {
      status: 400, headers: { 'content-type': 'application/json' }
    })
  });
  try {
    const res = await call('jobs/j1/live', { search: '?since=1e3' });
    assert.equal(res.status, 400);
    assert.match((await body(res)).error, /since/);
    assert.equal(f.seen[0].url, `${JOBS}/api/jobs/j1/live?since=1e3`);
  } finally {
    f.restore();
  }
});

test('no dash cookie is a 403, and the jobs worker is never called', async () => {
  const f = stubFetch();
  try {
    const res = await call('jobs/j1/live', { cookie: null, search: '?since=7' });
    assert.equal(res.status, 403);
    assert.deepEqual(await body(res), { error: 'unauthorized' });
    assert.equal(f.seen.length, 0);
  } finally {
    f.restore();
  }
});

test('a cookie the console worker rejects buys nothing', async () => {
  const f = stubFetch({ consoleStatus: 403 });
  try {
    const res = await call('jobs/j1/live', { search: '?since=7' });
    assert.equal(res.status, 403);
    assert.equal(f.seen.length, 0, 'a rejected session still reached the jobs worker');
  } finally {
    f.restore();
  }
});

test('an unreachable console is a refusal, not a grant', async () => {
  const f = stubFetch({ consoleThrows: true });
  try {
    const res = await call('jobs/j1/live', { search: '?since=7' });
    assert.equal(res.status, 403);
    assert.equal(f.seen.length, 0);
  } finally {
    f.restore();
  }
});

test('a missing HARNESS_SECRET is a 503 that says so, not a 401', async () => {
  const f = stubFetch();
  try {
    const res = await call('jobs/j1/live', { bind: false, search: '?since=7' });
    assert.equal(res.status, 503);
    assert.match((await body(res)).error, /HARNESS_SECRET is not set/);
    assert.equal(f.seen.length, 0);
  } finally {
    f.restore();
  }
});

test('the live route is read-only — no verb but GET reaches it', async () => {
  for (const method of ['POST', 'PUT', 'PATCH', 'DELETE']) {
    const f = stubFetch();
    try {
      const res = await call('jobs/j1/live', { method, search: '?since=7' });
      assert.equal(res.status, 405, method);
      assert.match((await body(res)).error, /not allowed on \/api\/coord\/jobs\/j1\/live/);
      assert.equal(f.seen.length, 0, `${method} reached the jobs worker`);
    } finally {
      f.restore();
    }
  }
});
