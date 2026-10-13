import test from 'node:test';
import assert from 'node:assert/strict';
import { onRequest } from '../functions/api/coord/[[path]].js';

// BH-2323: the coord proxy lets exactly two job writes through, POST
// jobs/<id>/retry and POST jobs/<id>/requeue, and stamps their actor the way it
// stamps hub/* POSTs. Every other jobs/* write stays 405 from a browser.

const JOBS = 'https://harness-jobs.operator.workers.dev';
const CONSOLE = 'https://harness-console.operator.workers.dev';
const SECRET = 'test-harness-secret';
const ID = 'build-cromford-BH-1-1';

function stubFetch({ signedIn = true } = {}) {
  const seen = [];
  const real = globalThis.fetch;
  globalThis.fetch = async (input, init = {}) => {
    const target = typeof input === 'string' ? input : input.url;
    if (target.startsWith(CONSOLE)) return new Response('', { status: signedIn ? 200 : 403 });
    seen.push({ url: target, method: init.method, headers: init.headers || {}, body: init.body });
    return new Response(JSON.stringify({ job_id: ID, decision: 'queued_for_retry', reason: 'r' }), {
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
      headers: { cookie: `dash=jobactions${++cookieSeq}`, 'content-type': 'application/json' },
      body
    }),
    env: { HARNESS_SECRET: SECRET },
    params: { path: rest.split('/') }
  });

for (const verb of ['retry', 'requeue']) {
  test(`1/2: POST jobs/:id/${verb} is forwarded with the bearer, the body and actor 'console'`, async () => {
    const f = stubFetch();
    try {
      const res = await call(`jobs/${ID}/${verb}`, 'POST', JSON.stringify({ detail: 'x' }));
      assert.equal(res.status, 200);
      assert.equal(JSON.parse(await res.text()).decision, 'queued_for_retry');
      assert.equal(f.seen.length, 1);
      assert.equal(f.seen[0].url, `${JOBS}/api/jobs/${ID}/${verb}`);
      assert.equal(f.seen[0].method, 'POST');
      assert.equal(f.seen[0].headers.authorization, `Bearer ${SECRET}`);
      assert.deepEqual(JSON.parse(f.seen[0].body), { detail: 'x', actor: 'console' });
    } finally { f.restore(); }
  });
}

test('3: a client-sent actor on a job action is overwritten with console', async () => {
  const f = stubFetch();
  try {
    await call(`jobs/${ID}/retry`, 'POST', JSON.stringify({ detail: 'x', actor: 'mallory' }));
    await call(`jobs/${ID}/requeue`, 'POST', JSON.stringify({ actor: { name: 'x' } }));
    assert.equal(f.seen.length, 2);
    for (const s of f.seen) assert.equal(JSON.parse(s.body).actor, 'console', s.url);
    assert.equal(JSON.parse(f.seen[0].body).detail, 'x', 'the rest of the body is untouched');
  } finally { f.restore(); }
});

test('4: a job-action body that is not a JSON object is refused 400 and never reaches the worker', async () => {
  const f = stubFetch();
  try {
    for (const body of ['', 'null', '[]', 'not json', '"console"']) {
      for (const verb of ['retry', 'requeue']) {
        const res = await call(`jobs/${ID}/${verb}`, 'POST', body);
        assert.equal(res.status, 400, `${verb} ${JSON.stringify(body)}`);
      }
    }
    assert.equal(f.seen.length, 0);
  } finally { f.restore(); }
});

test('5: every other jobs write stays 405 and never reaches the worker', async () => {
  const f = stubFetch();
  try {
    const cases = [
      ['PUT', `jobs/${ID}/retry`], ['PATCH', `jobs/${ID}/requeue`], ['DELETE', `jobs/${ID}/retry`],
      // TEST-CHANGE (BH-2406): POST jobs/:id/abandon is now forwarded; its own
      // suite, job-abandon-proxy.bh-2406.test.js, pins it and its 405 variants.
      ['POST', `jobs/${ID}/beat`], ['POST', `jobs/${ID}/phase`],
      ['POST', 'jobs'], ['POST', `jobs/${ID}/retry/extra`], ['POST', 'jobs//retry'],
      ['POST', 'jobs/../retry'], ['POST', 'jobs/./requeue'], ['POST', `jobs/${ID}`],
      ['DELETE', `jobs/${ID}`], ['POST', `x/jobs/${ID}/retry`], ['POST', 'jobs/retry'],
    ];
    for (const [method, rest] of cases) {
      const res = await call(rest, method, JSON.stringify({ detail: 'x' }));
      assert.equal(res.status, 405, `${method} ${rest}`);
    }
    assert.equal(f.seen.length, 0);
  } finally { f.restore(); }
});

test('6: GET jobs/:id still forwards (regression)', async () => {
  const f = stubFetch();
  try {
    const res = await call(`jobs/${ID}`, 'GET');
    assert.equal(res.status, 200);
    assert.equal(f.seen.length, 1);
    assert.equal(f.seen[0].url, `${JOBS}/api/jobs/${ID}`);
  } finally { f.restore(); }
});

test('7: an unsigned cookie on a job action answers 403 and never reaches the worker', async () => {
  const f = stubFetch({ signedIn: false });
  try {
    const res = await call(`jobs/${ID}/requeue`, 'POST', JSON.stringify({ detail: 'x' }));
    assert.equal(res.status, 403);
    assert.equal(f.seen.length, 0);
  } finally { f.restore(); }
});

test('8: a job action forwards only detail and the stamped actor; max_attempts and unknown fields never reach the worker', async () => {
  const f = stubFetch();
  try {
    for (const verb of ['retry', 'requeue']) {
      await call(`jobs/${ID}/${verb}`, 'POST',
        JSON.stringify({ detail: 'x', max_attempts: 20, lane: 'other', actor: 'mallory' }));
    }
    await call(`jobs/${ID}/requeue`, 'POST', JSON.stringify({ max_attempts: 20 }));
    assert.equal(f.seen.length, 3);
    assert.deepEqual(JSON.parse(f.seen[0].body), { detail: 'x', actor: 'console' });
    assert.deepEqual(JSON.parse(f.seen[1].body), { detail: 'x', actor: 'console' });
    assert.deepEqual(JSON.parse(f.seen[2].body), { actor: 'console' });
    for (const s of f.seen) assert.ok(!s.body.includes('max_attempts'), s.body);
  } finally { f.restore(); }
});

test('9: hub/* POSTs keep their whole body (the allowlist is for job actions only)', async () => {
  const f = stubFetch();
  try {
    await call('hub/promote', 'POST', JSON.stringify({ confirm: true, expected_epoch: 7, actor: 'mallory' }));
    assert.deepEqual(JSON.parse(f.seen[0].body), { confirm: true, expected_epoch: 7, actor: 'console' });
  } finally { f.restore(); }
});
