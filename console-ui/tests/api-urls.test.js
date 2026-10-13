import test from 'node:test';
import assert from 'node:assert/strict';
import { api, PIPELINE_SHIPPED_LIMIT } from '../src/api.js';

// The URL a screen asks for is a contract with the worker, and one of these
// parameters is load-bearing enough to be worth pinning: without
// `shipped_limit` the pipeline route falls back to its own default — everything
// merged in the last 14 days — and five fleet repos merged ~313 PRs in the last
// fortnight. `.kb__col` has no max-height, so that is a SHIPPED column a few
// hundred cards tall.

// A fetch stub that records the URL and answers with the smallest valid body.
function captureFetch() {
  const calls = [];
  globalThis.fetch = async (url) => {
    calls.push(String(url));
    return { ok: true, status: 200, text: async () => JSON.stringify({ ok: true }) };
  };
  return calls;
}

const paramsOf = (url) => new URL(url, 'https://console.test').searchParams;

test('the pipeline read asks for a bounded SHIPPED column', async () => {
  const calls = captureFetch();
  await api.pipeline(null);
  assert.equal(calls.length, 1);
  assert.equal(paramsOf(calls[0]).get('shipped_limit'), '50');
  assert.equal(PIPELINE_SHIPPED_LIMIT, 50, 'the request and the constant agree');
  assert.ok(calls[0].startsWith('/api/dash/kanban/pipeline?'), 'same route, same origin');
});

test('the bound rides alongside the parameters that were already there', async () => {
  const calls = captureFetch();
  await api.pipeline('project-3', { includeArchived: true });
  const q = paramsOf(calls[0]);
  assert.equal(q.get('project'), 'project-3');
  assert.equal(q.get('include'), 'archived', 'the console\'s own archive parameter is untouched');
  assert.equal(q.get('shipped_limit'), '50');
});

test('a caller can ask for a different bound', async () => {
  const calls = captureFetch();
  await api.pipeline(null, { shippedLimit: 200 });
  assert.equal(paramsOf(calls[0]).get('shipped_limit'), '200');
});

// The live read is the other URL worth pinning: the whole mission view is a
// cursor walk, and a `since` that does not ride along re-sends every event on
// every 5s tick. The job id is path data and can carry a slash.
test('the live read pins the coord route and the cursor', async () => {
  const calls = captureFetch();
  await api.live('build-x/y', 41);
  assert.equal(calls.length, 1);
  // determinism: ok `since` is an event-id cursor, not a rolling time window
  assert.equal(calls[0], '/api/coord/jobs/build-x%2Fy/live?since=41');
  await api.live('job-1');
  // determinism: ok the default cursor is the first event id, not a clock read
  assert.equal(calls[1], '/api/coord/jobs/job-1/live?since=0', 'no cursor means from the start');
});

// BH-2368: the alert action helpers. The action enum is checked in the browser,
// the same way lanesAll checks its path word: a typo must be a refusal, not a
// POST the worker reads as something else.
function captureRequests() {
  const calls = [];
  globalThis.fetch = async (url, init = {}) => {
    calls.push({ url: String(url), method: init.method || 'GET', body: init.body === undefined ? undefined : JSON.parse(init.body) });
    return { ok: true, status: 200, text: async () => JSON.stringify({ ok: true }) };
  };
  return calls;
}

test('alertAction POSTs the id and action to the coord actions route', async () => {
  const calls = captureRequests();
  await api.alertAction('a1', 'ack');
  assert.equal(calls.length, 1);
  assert.equal(calls[0].url, '/api/coord/alerts/actions');
  assert.equal(calls[0].method, 'POST');
  assert.deepEqual(calls[0].body, { id: 'a1', action: 'ack' }, 'no note key when there is no note');
  await api.alertAction('a1', 'note', 'hi');
  assert.deepEqual(calls[1].body, { id: 'a1', action: 'note', note: 'hi' });
  await api.alertAction('a1', 'snooze', '');
  assert.deepEqual(calls[2].body, { id: 'a1', action: 'snooze' }, 'an empty note is omitted');
  await api.alertAction('a1', 'resolve');
  assert.equal(calls[3].body.action, 'resolve');
});

test('alertAction refuses an action outside ack|snooze|resolve|note without a fetch', async () => {
  const calls = captureRequests();
  await assert.rejects(api.alertAction('a1', 'delete'), /alertAction takes/);
  assert.equal(calls.length, 0);
});

test('alertActions reads the log for one alert, with and without a limit', async () => {
  const calls = captureRequests();
  await api.alertActions('a1', 20);
  assert.equal(calls[0].method, 'GET');
  assert.ok(calls[0].url.startsWith('/api/coord/alerts/actions?'), calls[0].url);
  assert.equal(paramsOf(calls[0].url).get('id'), 'a1');
  assert.equal(paramsOf(calls[0].url).get('limit'), '20');
  await api.alertActions('a1');
  assert.equal(paramsOf(calls[1].url).get('limit'), null, 'no limit means the worker default');
});
