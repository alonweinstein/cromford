import test from 'node:test';
import assert from 'node:assert/strict';
import { onRequest } from '../functions/api/coord/[[path]].js';
import { api } from '../src/api.js';

// BH-2518 (BH-2658 contract): the coord proxy admits exactly one new write,
// POST box-commands, with a flat allowlist and the proxy-stamped actor. The
// box-lane routes under it (claim, :id/result) stay 405 from a browser, and the
// read is the proxy's generic GET pass-through with its query string.

const JOBS = 'https://harness-jobs.operator.workers.dev';
const SECRET = 'test-harness-secret';

function stubFetch() {
  const seen = [];
  const real = globalThis.fetch;
  globalThis.fetch = async (input, init = {}) => {
    const target = typeof input === 'string' ? input : input.url;
    if (target.startsWith('https://harness-console.operator.workers.dev')) return new Response('', { status: 200 });
    seen.push({ url: target, method: init.method || (typeof input === 'string' ? 'GET' : input.method), headers: init.headers || {}, body: init.body });
    return new Response(JSON.stringify({ id: 7, status: 'requested' }), {
      status: 201, headers: { 'content-type': 'application/json' }
    });
  };
  return { seen, restore: () => { globalThis.fetch = real; } };
}

let cookieSeq = 0;
// params.path is split as-is, so a trailing slash reaches the proxy as an empty segment.
const call = (rest, method, body, query = '') =>
  onRequest({
    request: new Request(`https://console.example.pages.dev/api/coord/${rest}${query}`, {
      method,
      headers: { cookie: `dash=boxcmd${++cookieSeq}`, 'content-type': 'application/json' },
      body
    }),
    env: { HARNESS_SECRET: SECRET },
    params: { path: rest.split('/') }
  });

test('POST box-commands forwards exactly the allowlisted keys plus the stamped actor', async () => {
  const f = stubFetch();
  try {
    const sent = {
      box: 'hub', type: 'fly_machine_stop', target: 'abc12345', project: 'p', app: 'a',
      reason: 'stray', confirm: true, actor: 'mallory', args: { x: 1 }, status: 'ok', requested_by: 'eve'
    };
    const res = await call('box-commands', 'POST', JSON.stringify(sent));
    assert.equal(res.status, 201);
    assert.equal(f.seen.length, 1);
    assert.equal(f.seen[0].url, `${JOBS}/api/box-commands`);
    assert.equal(f.seen[0].method, 'POST');
    assert.equal(f.seen[0].headers.authorization, `Bearer ${SECRET}`);
    const fwd = JSON.parse(f.seen[0].body);
    assert.deepEqual(fwd, {
      box: 'hub', type: 'fly_machine_stop', target: 'abc12345', project: 'p', app: 'a',
      reason: 'stray', confirm: true, actor: 'console'
    });
    assert.equal(fwd.confirm, true, 'a boolean confirm arrives as a boolean, like restore-lab');
  } finally { f.restore(); }
});

test('other verbs on box-commands and the box-lane sub-routes are 405 and never reach the worker', async () => {
  const f = stubFetch();
  try {
    const body = JSON.stringify({ box: 'hub', type: 'backup_now', reason: 'x', confirm: true });
    for (const m of ['DELETE', 'PUT', 'PATCH']) {
      const res = await call('box-commands', m, body);
      assert.equal(res.status, 405, m);
    }
    for (const rest of ['box-commands/claim', 'box-commands/9/result', 'box-commands/']) {
      const res = await call(rest, 'POST', body);
      assert.equal(res.status, 405, rest);
    }
    assert.equal(f.seen.length, 0, 'nothing reached the jobs worker');
  } finally { f.restore(); }
});

test('a box-commands POST whose body is not a JSON object is refused 400', async () => {
  const f = stubFetch();
  try {
    for (const body of ['[]', '"x"', 'null', 'not json']) {
      const res = await call('box-commands', 'POST', body);
      assert.equal(res.status, 400, body);
    }
    assert.equal(f.seen.length, 0);
  } finally { f.restore(); }
});

test('GET box-commands?box=hub is forwarded with its query string', async () => {
  const f = stubFetch();
  try {
    const res = await call('box-commands', 'GET', undefined, '?box=hub');
    assert.equal(res.status, 201);
    assert.equal(f.seen.length, 1);
    assert.equal(f.seen[0].url, `${JOBS}/api/box-commands?box=hub`);
  } finally { f.restore(); }
});

test('api.boxCommand and api.boxCommands hit the coord routes', async () => {
  const real = globalThis.fetch;
  const calls = [];
  globalThis.fetch = async (url, init = {}) => {
    calls.push({ url: String(url), method: init.method || 'GET', body: init.body });
    return { ok: true, status: 200, text: async () => JSON.stringify({ ok: true }) };
  };
  try {
    const body = { box: 'hub', type: 'backup_now', target: '', reason: 'nightly missed', confirm: true };
    await api.boxCommand(body);
    await api.boxCommands();
    await api.boxCommands('hub 1');
    assert.deepEqual(calls[0], { url: '/api/coord/box-commands', method: 'POST', body: JSON.stringify(body) });
    assert.deepEqual(calls[1], { url: '/api/coord/box-commands', method: 'GET', body: undefined });
    assert.deepEqual(calls[2], { url: '/api/coord/box-commands?box=hub%201', method: 'GET', body: undefined });
  } finally { globalThis.fetch = real; }
});
