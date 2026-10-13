import test from 'node:test';
import assert from 'node:assert/strict';
import { onRequest } from '../functions/api/coord/[[path]].js';

// BH-2406: the coord proxy lets POST jobs/<id>/abandon through, stamps its
// actor server-side, and forwards ONLY the reason. Everything the browser adds
// (an actor, a status, max_attempts, a detail) is dropped before the worker.

const JOBS = 'https://harness-jobs.operator.workers.dev';
const CONSOLE = 'https://harness-console.operator.workers.dev';
const SECRET = 'test-harness-secret';
const ID = 'build-cromford-BH-9-1';

function stubFetch({ signedIn = true } = {}) {
  const seen = [];
  const real = globalThis.fetch;
  globalThis.fetch = async (input, init = {}) => {
    const target = typeof input === 'string' ? input : input.url;
    if (target.startsWith(CONSOLE)) return new Response('', { status: signedIn ? 200 : 403 });
    seen.push({ url: target, method: init.method, headers: init.headers || {}, body: init.body });
    return new Response(JSON.stringify({ job_id: ID, decision: 'abandoned', reason: 'r' }), {
      status: 200, headers: { 'content-type': 'application/json' }
    });
  };
  return { seen, restore: () => { globalThis.fetch = real; } };
}

let cookieSeq = 0;
const call = (rest, method, body) =>
  onRequest({
    request: new Request(`https://console.example.pages.dev/api/coord/${rest}`, {
      method,
      headers: { cookie: `dash=jobabandon${++cookieSeq}`, 'content-type': 'application/json' },
      body
    }),
    env: { HARNESS_SECRET: SECRET },
    params: { path: rest.split('/') }
  });

test('1: POST jobs/:id/abandon is forwarded with the bearer, and the body is exactly {reason, actor:"console"}', async () => {
  const f = stubFetch();
  try {
    const res = await call(`jobs/${ID}/abandon`, 'POST',
      JSON.stringify({ reason: 'r', actor: 'mallory', status: 'done', max_attempts: 20, detail: 'd', lane: 'x' }));
    assert.equal(res.status, 200);
    assert.equal(JSON.parse(await res.text()).decision, 'abandoned');
    assert.equal(f.seen.length, 1);
    assert.equal(f.seen[0].url, `${JOBS}/api/jobs/${ID}/abandon`);
    assert.equal(f.seen[0].method, 'POST');
    assert.equal(f.seen[0].headers.authorization, `Bearer ${SECRET}`);
    assert.deepEqual(JSON.parse(f.seen[0].body), { reason: 'r', actor: 'console' });
  } finally { f.restore(); }
});

test('2: a non-string reason is dropped, so the worker answers "reason required" itself', async () => {
  const f = stubFetch();
  try {
    await call(`jobs/${ID}/abandon`, 'POST', JSON.stringify({ reason: { x: 1 }, actor: 'mallory' }));
    await call(`jobs/${ID}/abandon`, 'POST', JSON.stringify({}));
    assert.deepEqual(f.seen.map((s) => JSON.parse(s.body)), [{ actor: 'console' }, { actor: 'console' }]);
  } finally { f.restore(); }
});

test('3: an abandon body that is not a JSON object is refused 400 and never reaches the worker', async () => {
  const f = stubFetch();
  try {
    for (const body of ['', 'null', '[]', 'not json', '"stuck"']) {
      const res = await call(`jobs/${ID}/abandon`, 'POST', body);
      assert.equal(res.status, 400, JSON.stringify(body));
    }
    assert.equal(f.seen.length, 0);
  } finally { f.restore(); }
});

test('4: other verbs and path shapes on abandon stay 405 and never reach the worker', async () => {
  const f = stubFetch();
  try {
    const cases = [
      ['PUT', `jobs/${ID}/abandon`], ['DELETE', `jobs/${ID}/abandon`], ['PATCH', `jobs/${ID}/abandon`],
      ['POST', `jobs/${ID}/abandon/extra`], ['POST', 'jobs/../abandon'], ['POST', 'jobs/./abandon'],
      ['POST', 'jobs//abandon'], ['POST', 'jobs/abandon'], ['POST', `x/jobs/${ID}/abandon`],
      ['POST', `jobs/${ID}/abandoned`],
    ];
    for (const [method, rest] of cases) {
      const res = await call(rest, method, JSON.stringify({ reason: 'x' }));
      assert.equal(res.status, 405, `${method} ${rest}`);
    }
    assert.equal(f.seen.length, 0);
  } finally { f.restore(); }
});

test('5: an unsigned cookie on abandon answers 403 and never reaches the worker', async () => {
  const f = stubFetch({ signedIn: false });
  try {
    const res = await call(`jobs/${ID}/abandon`, 'POST', JSON.stringify({ reason: 'x' }));
    assert.equal(res.status, 403);
    assert.equal(f.seen.length, 0);
  } finally { f.restore(); }
});

test('6: retry and requeue still forward only detail (no reason leaks across actions)', async () => {
  const f = stubFetch();
  try {
    for (const verb of ['retry', 'requeue']) {
      await call(`jobs/${ID}/${verb}`, 'POST', JSON.stringify({ detail: 'x', reason: 'r', actor: 'mallory' }));
    }
    assert.deepEqual(f.seen.map((s) => JSON.parse(s.body)),
      [{ detail: 'x', actor: 'console' }, { detail: 'x', actor: 'console' }]);
  } finally { f.restore(); }
});

test('7: after the merge with main, abandon drops every worker-shaped extra and any browser actor, and main\'s allowlists are untouched', async () => {
  const f = stubFetch();
  try {
    const extra = {
      reason: 'stuck for a day', actor: 'mallory', status: 'done', stage: 'merge', kind: 'triage',
      ticket_id: 'BH-1', project: 'other', job_id: 'x', max_attempts: 20, detail: 'd', name: 'n', sha: 'abc',
      note: 'n', meta: { actor: 'mallory' }
    };
    await call(`jobs/${ID}/abandon`, 'POST', JSON.stringify(extra));
    await call(`jobs/${ID}/abandon`, 'POST', '{"reason":"r","__proto__":{"actor":"mallory"},"actor":["mallory"]}');
    // main-red CLEAR keeps its own three strings (BH-2329.3), retry keeps detail (BH-2323).
    await call('main-red/clear', 'POST', JSON.stringify(extra));
    await call(`jobs/${ID}/retry`, 'POST', JSON.stringify(extra));
    const bodies = f.seen.map((s) => JSON.parse(s.body));
    assert.deepEqual(bodies[0], { reason: 'stuck for a day', actor: 'console' });
    assert.deepEqual(bodies[1], { reason: 'r', actor: 'console' });
    assert.deepEqual(bodies[2], { name: 'n', reason: 'stuck for a day', sha: 'abc', actor: 'console' });
    assert.deepEqual(bodies[3], { detail: 'd', actor: 'console' });
  } finally { f.restore(); }
});
