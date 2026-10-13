import test from 'node:test';
import assert from 'node:assert/strict';
import { api, AuthError } from '../src/api.js';
import { logOutcome } from '../src/lib/logstate.js';

// BH-2656: a log pane's poll reads the box_console_commands row first, through
// the coord proxy, and only falls back to /api/dash/logs/<id> when the jobs
// worker does not serve that route yet (404 `unknown endpoint`, until #2654
// deploys). Every case goes through the real api.logs and then logOutcome, so
// what is asserted is what the pane would render.

// A fetch stub routed by URL. `routes` maps a URL prefix to [status, body].
function stubFetch(routes) {
  const calls = [];
  globalThis.fetch = async (url) => {
    const u = String(url);
    calls.push(u);
    const hit = Object.keys(routes).find((p) => u.startsWith(p));
    if (!hit) throw new Error(`unexpected fetch ${u}`);
    const [status, body] = routes[hit];
    return {
      ok: status >= 200 && status < 300,
      status,
      text: async () => (body === undefined ? '' : JSON.stringify(body))
    };
  };
  return calls;
}

const ROW = '/api/coord/box-console-commands/';
const DASH = '/api/dash/logs/';

const doneRow = (over = {}) => ({
  command_id: 'c1',
  status: 'done',
  ok: 1,
  result: 'ok',
  body: JSON.stringify({ content: 'tail\n', bytes: 5 }),
  ...over
});

test('A1: a done row renders its tail from the row read alone (bare row)', async () => {
  const calls = stubFetch({ [ROW]: [200, doneRow()] });
  const out = logOutcome(await api.logs('c1'));
  assert.equal(out.state, 'ready');
  assert.equal(out.content, 'tail\n');
  assert.equal(out.commandId, 'c1');
  assert.deepEqual(calls, ['/api/coord/box-console-commands/c1']);
});

test('A1: a done row wrapped as {command: row} reads the same', async () => {
  const calls = stubFetch({ [ROW]: [200, { command: doneRow() }] });
  const out = logOutcome(await api.logs('c1'));
  assert.equal(out.state, 'ready');
  assert.equal(out.content, 'tail\n');
  assert.equal(out.commandId, 'c1');
  assert.equal(calls.length, 1);
});

test('A1b: a failed row with a parseable body is ready, not pending', async () => {
  stubFetch({ [ROW]: [200, doneRow({ status: 'failed', ok: 0, result: 'refused', body: JSON.stringify({ missing: true }) })] });
  const res = await api.logs('c1');
  assert.equal(res.status, 'ready');
  const out = logOutcome(res);
  assert.equal(out.state, 'refused', 'the row result passes through to logOutcome');
});

test('A2: an expired row is fetch_failed and retryable, no fallback', async () => {
  const calls = stubFetch({ [ROW]: [200, { command_id: 'c1', status: 'expired', body: null }] });
  const out = logOutcome(await api.logs('c1'));
  assert.equal(out.state, 'fetch_failed');
  assert.equal(out.retryable, true);
  assert.equal(calls.length, 1);
});

for (const status of ['queued', 'claimed']) {
  test(`A3: a ${status} row is pending`, async () => {
    const calls = stubFetch({ [ROW]: [200, { command_id: 'c1', status, body: null }] });
    const res = await api.logs('c1');
    assert.equal(res.status, 'pending');
    assert.equal(logOutcome(res).state, 'pending');
    assert.equal(calls.length, 1);
  });
}

test('A3c: an unknown row status stays pending, never an empty ready', async () => {
  stubFetch({ [ROW]: [200, { command_id: 'c1', status: 'something_new' }] });
  assert.equal((await api.logs('c1')).status, 'pending');
});

test('A4: a 404 unknown endpoint falls back exactly once to /api/dash/logs', async () => {
  const fallback = { status: 'ready', log: { content: 'x' } };
  const calls = stubFetch({
    [ROW]: [404, { error: 'unknown endpoint' }],
    [DASH]: [200, fallback]
  });
  const res = await api.logs('c/1');
  assert.deepEqual(res, fallback, 'the fallback body is returned as-is');
  assert.equal(logOutcome(res).state, 'ready');
  assert.deepEqual(calls, ['/api/coord/box-console-commands/c%2F1', '/api/dash/logs/c%2F1']);
});

test('A4b: a 404 from the fallback itself is rethrown, no third request', async () => {
  const calls = stubFetch({
    [ROW]: [404, { error: 'unknown endpoint' }],
    [DASH]: [404, { error: 'not found' }]
  });
  await assert.rejects(api.logs('c1'), (e) => e.status === 404);
  assert.equal(calls.length, 2);
});

test('A5: a 500 on the row read is rethrown and never falls back', async () => {
  const calls = stubFetch({ [ROW]: [500, { error: 'boom' }], [DASH]: [200, { status: 'ready' }] });
  await assert.rejects(api.logs('c1'), (e) => e.status === 500);
  assert.equal(calls.length, 1);
});

test('A5b: a network failure is rethrown and never falls back', async () => {
  const calls = [];
  globalThis.fetch = async (url) => { calls.push(String(url)); throw new TypeError('fetch failed'); };
  await assert.rejects(api.logs('c1'), /network unreachable/);
  assert.equal(calls.length, 1);
});

for (const body of ['not json', null, '', 'null', '42']) {
  test(`A6: a done row with body ${JSON.stringify(body)} is fetch_failed, not empty`, async () => {
    stubFetch({ [ROW]: [200, doneRow({ body })] });
    const out = logOutcome(await api.logs('c1'));
    assert.equal(out.state, 'fetch_failed');
    assert.equal(out.commandId, 'c1');
  });
}

test('A7: a 404 carrying unauthorized is an AuthError and never falls back', async () => {
  const calls = stubFetch({ [ROW]: [404, { error: 'unauthorized' }], [DASH]: [200, { status: 'ready' }] });
  await assert.rejects(api.logs('c1'), (e) => e instanceof AuthError);
  assert.equal(calls.length, 1);
});
