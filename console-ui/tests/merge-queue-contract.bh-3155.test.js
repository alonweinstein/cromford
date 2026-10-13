import test from 'node:test';
import assert from 'node:assert/strict';
import { api } from '../src/api.js';
import { MqRowActions, HeldReleaseButton } from '../src/screens/merge-queue-actions.js';

// BH-3155 (BH-2325.0 contract): the four merge-queue / held-page client calls
// and the two action-cell stubs. The URL, method and body are a contract with
// the coord proxy and the worker routes the sibling tickets add.

// A fetch stub that records the URL and init and answers the smallest valid body.
function captureFetch() {
  const calls = [];
  globalThis.fetch = async (url, init = {}) => {
    calls.push({ url: String(url), init });
    return { ok: true, status: 200, text: async () => JSON.stringify({ ok: true }) };
  };
  return calls;
}

const paramsOf = (url) => new URL(url, 'https://console.test').searchParams;

test('mergeQueue with no filters asks for the bare path', async () => {
  const calls = captureFetch();
  await api.mergeQueue({});
  await api.mergeQueue();
  assert.deepEqual(calls.map((c) => c.url), ['/api/coord/merge-queue', '/api/coord/merge-queue']);
  assert.equal(calls[0].init.method ?? 'GET', 'GET');
});

test('mergeQueue sends each present filter, encoded, and omits absent ones', async () => {
  const calls = captureFetch();
  await api.mergeQueue({ project: 'project-3 os', status: 'held', limit: 5 });
  const q = paramsOf(calls[0].url);
  assert.ok(calls[0].url.startsWith('/api/coord/merge-queue?'));
  assert.equal(q.get('project'), 'project-3 os');
  assert.equal(q.get('status'), 'held');
  assert.equal(q.get('limit'), '5');
  assert.ok(/project-3(\+|%20)os/.test(calls[0].url), `the space is encoded: ${calls[0].url}`);
  await api.mergeQueue({ project: 'project-3' });
  assert.equal(calls[1].url, '/api/coord/merge-queue?project=project-3');
  assert.ok(!calls[1].url.includes('undefined'));
});

test('setMergeQueue is a JSON PATCH to the merge-queue path', async () => {
  const calls = captureFetch();
  await api.setMergeQueue({ a: 1 });
  assert.equal(calls[0].url, '/api/coord/merge-queue');
  assert.equal(calls[0].init.method, 'PATCH');
  assert.equal(calls[0].init.headers['content-type'], 'application/json');
  assert.equal(calls[0].init.body, '{"a":1}');
});

test('heldPages asks for the held list, with limit only when given', async () => {
  const calls = captureFetch();
  await api.heldPages(20);
  await api.heldPages();
  assert.equal(calls[0].url, '/api/coord/conductor/held?limit=20');
  assert.equal(calls[1].url, '/api/coord/conductor/held');
  assert.equal(calls[0].init.method ?? 'GET', 'GET');
});

test('releaseHeldPage is a JSON POST to the release path', async () => {
  const calls = captureFetch();
  await api.releaseHeldPage({ id: 1 });
  assert.equal(calls[0].url, '/api/coord/conductor/held/release');
  assert.equal(calls[0].init.method, 'POST');
  assert.equal(calls[0].init.headers['content-type'], 'application/json');
  assert.equal(calls[0].init.body, '{"id":1}');
});

test('both action-cell stubs render nothing and never call onDone', () => {
  let done = 0;
  const onDone = () => { done++; };
  assert.equal(typeof MqRowActions, 'function');
  assert.equal(typeof HeldReleaseButton, 'function');
  for (const rowsOnly of ['on', 'off', 'unread']) {
    assert.equal(MqRowActions({ row: {}, rowsOnly, onDone }), null);
  }
  assert.equal(HeldReleaseButton({ row: {}, onDone }), null);
  assert.equal(done, 0);
});
