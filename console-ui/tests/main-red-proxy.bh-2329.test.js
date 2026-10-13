import test from 'node:test';
import assert from 'node:assert/strict';
import { onRequest } from '../functions/api/coord/[[path]].js';

// BH-2329.3: the Project page's CLEAR on a main-red banner is a POST to
// main-red/clear through the coord proxy. The proxy allows exactly that path,
// stamps actor 'console' over whatever the browser sent (the worker records it
// in main_red_events), and keeps every other main-red write at 405.

const JOBS = 'https://harness-jobs.operator.workers.dev';
const SECRET = 'test-harness-secret';

function stubFetch(status = 200, payload = { cleared: true }) {
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
const call = (rest, method, body, search = '') =>
  onRequest({
    request: new Request(`https://console.example.pages.dev/api/coord/${rest}${search}`, {
      method,
      headers: { cookie: `dash=mainred${++cookieSeq}`, 'content-type': 'application/json' },
      body
    }),
    env: { HARNESS_SECRET: SECRET },
    params: { path: rest.split('/').filter(Boolean) }
  });

test('POST main-red/clear is forwarded with the bearer and a browser-sent actor is overwritten with console', async () => {
  const f = stubFetch();
  try {
    const sent = { name: 'main-red-example-org-project-3', reason: 'flaky runner', sha: 'abcdef1234567890', actor: 'mallory' };
    const res = await call('main-red/clear', 'POST', JSON.stringify(sent));
    assert.equal(res.status, 200);
    assert.equal(f.seen.length, 1);
    assert.equal(f.seen[0].url, `${JOBS}/api/main-red/clear`);
    assert.equal(f.seen[0].method, 'POST');
    assert.equal(f.seen[0].headers.authorization, `Bearer ${SECRET}`);
    const fwd = JSON.parse(f.seen[0].body);
    assert.equal(fwd.actor, 'console');
    assert.equal(fwd.name, sent.name);
    assert.equal(fwd.reason, sent.reason);
    assert.equal(fwd.sha, sent.sha);
  } finally { f.restore(); }
});

test('main-red/clear forwards only name, reason and sha plus the stamped actor, never extra browser fields', async () => {
  const f = stubFetch();
  try {
    const sent = {
      name: 'main-red-example-org-project-3', reason: 'flaky runner', sha: 'abcdef1234567890',
      actor: 'mallory', active: 0, confirm: true, cleared_by: 'mallory', note: { nested: 1 }
    };
    const res = await call('main-red/clear', 'POST', JSON.stringify(sent));
    assert.equal(res.status, 200);
    assert.equal(f.seen.length, 1);
    assert.deepEqual(JSON.parse(f.seen[0].body),
      { name: sent.name, reason: sent.reason, sha: sent.sha, actor: 'console' });
  } finally { f.restore(); }
});

test('main-red/clear drops a missing or non-string field rather than forwarding it', async () => {
  const f = stubFetch();
  try {
    const res = await call('main-red/clear', 'POST', JSON.stringify({ name: 'main-red-x', reason: 7, sha: { $ne: '' } }));
    assert.equal(res.status, 200);
    assert.deepEqual(JSON.parse(f.seen[0].body), { name: 'main-red-x', actor: 'console' });
  } finally { f.restore(); }
});

test('a worker 409 on main-red/clear passes straight through', async () => {
  const f = stubFetch(409, { error: 'moved to a new sha' });
  try {
    const res = await call('main-red/clear', 'POST', JSON.stringify({ name: 'main-red-x', reason: 'r' }));
    assert.equal(res.status, 409);
    assert.deepEqual(JSON.parse(await res.text()), { error: 'moved to a new sha' });
  } finally { f.restore(); }
});

test('a non-object body on main-red/clear is 400 and never reaches the worker', async () => {
  const f = stubFetch();
  try {
    for (const body of ['"x"', '[]', 'null', 'not json']) {
      const res = await call('main-red/clear', 'POST', body);
      assert.equal(res.status, 400, `body=${body}`);
    }
    assert.equal(f.seen.length, 0);
  } finally { f.restore(); }
});

test('PUT and POST main-red (the detector upsert) and other main-red writes stay 405', async () => {
  const f = stubFetch();
  try {
    for (const [rest, method] of [
      ['main-red', 'PUT'],
      ['main-red', 'POST'],
      ['main-red/clear', 'PUT'],
      ['main-red/clear', 'DELETE'],
      ['main-red/clear/x', 'POST'],
      ['main-red/unclear', 'POST']
    ]) {
      const res = await call(rest, method, JSON.stringify({ name: 'main-red-x', active: 0 }));
      assert.equal(res.status, 405, `${method} ${rest}`);
    }
    assert.equal(f.seen.length, 0);
  } finally { f.restore(); }
});

test('GET main-red is forwarded with its query and no body', async () => {
  const f = stubFetch(200, { main_red: [] });
  try {
    const res = await call('main-red', 'GET', undefined, '?all=1');
    assert.equal(res.status, 200);
    assert.equal(f.seen.length, 1);
    assert.equal(f.seen[0].url, `${JOBS}/api/main-red?all=1`);
    assert.equal(f.seen[0].method, 'GET');
    assert.equal(f.seen[0].body, undefined);
  } finally { f.restore(); }
});

test('neighbor: POST hub/promote is still actor-stamped console', async () => {
  const f = stubFetch();
  try {
    const res = await call('hub/promote', 'POST', JSON.stringify({ target: 'b', expected_epoch: 1, confirm: true, actor: 'mallory' }));
    assert.equal(res.status, 200);
    assert.equal(JSON.parse(f.seen[0].body).actor, 'console');
  } finally { f.restore(); }
});
