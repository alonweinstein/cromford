import test from 'node:test';
import assert from 'node:assert/strict';
import { onRequest } from '../functions/api/coord/[[path]].js';

// BH-2995 (BH-2992.1): the two /hub writes BH-2521 added, the SEED REGISTRY
// apply and the CHAT BINDINGS edit, refuse a blank reason at the coord proxy.
// Driven through the real onRequest with fetch stubbed (the
// registry-seed-proxy.bh-2521 harness).

const JOBS = 'https://harness-jobs.operator.workers.dev';
const SECRET = 'test-harness-secret';

function stubFetch() {
  const seen = [];
  const real = globalThis.fetch;
  globalThis.fetch = async (input, init = {}) => {
    const target = typeof input === 'string' ? input : input.url;
    if (target.startsWith('https://harness-console.operator.workers.dev')) return new Response('', { status: 200 });
    seen.push({ url: target, method: init.method, body: init.body });
    return new Response(JSON.stringify({ ok: true }), {
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
      headers: { cookie: `dash=hubreason${++cookieSeq}`, 'content-type': 'application/json' },
      body
    }),
    env: { HARNESS_SECRET: SECRET },
    params: { path: rest.split('/') }
  });

const FP = 'a'.repeat(64);
const ROWS = [
  ['settings/seed-registry/apply', 'POST', { plan_fp: FP }],
  ['telegram-topics', 'PUT', { project: 'project-3', thread_id: 12 }]
];
const MISSING = Symbol('missing');

test('R1: a blank, non-string or missing reason is 400 reason required and nothing is forwarded', async () => {
  const f = stubFetch();
  try {
    for (const [rest, method, base] of ROWS) {
      for (const reason of ['', '   ', null, 42, MISSING]) {
        const body = reason === MISSING ? { ...base } : { ...base, reason };
        const res = await call(rest, method, JSON.stringify(body));
        assert.equal(res.status, 400, `${method} ${rest} reason=${String(reason)}`);
        assert.deepEqual(await res.json(), { error: 'reason required' });
      }
    }
    assert.equal(f.seen.length, 0);
  } finally { f.restore(); }
});

test('R2: a good reason is forwarded with the stamped actor, the browser actor dropped', async () => {
  const f = stubFetch();
  try {
    for (const [rest, method, base] of ROWS) {
      const res = await call(rest, method, JSON.stringify({ ...base, reason: 'fix drift', actor: 'mallory' }));
      assert.equal(res.status, 200, `${method} ${rest}`);
    }
    assert.equal(f.seen.length, 2);
    assert.equal(f.seen[0].url, `${JOBS}/api/settings/seed-registry/apply`);
    assert.deepEqual(JSON.parse(f.seen[0].body), { plan_fp: FP, reason: 'fix drift', actor: 'console' });
    assert.equal(f.seen[1].url, `${JOBS}/api/telegram-topics`);
    assert.deepEqual(JSON.parse(f.seen[1].body), { project: 'project-3', thread_id: 12, reason: 'fix drift', actor: 'console' });
  } finally { f.restore(); }
});

test('R3: negative control, POST hub/restore-lab with no reason is still forwarded', async () => {
  const f = stubFetch();
  try {
    const res = await call('hub/restore-lab', 'POST', JSON.stringify({ box: 'lab-1', snapshot: 's1', confirm: 'lab-1' }));
    assert.notEqual(res.status, 400);
    assert.equal(f.seen.length, 1);
    assert.equal(f.seen[0].url, `${JOBS}/api/hub/restore-lab`);
  } finally { f.restore(); }
});

test('R4: a telegram reason survives the validator while a string thread_id is still dropped', async () => {
  const f = stubFetch();
  try {
    await call('telegram-topics', 'PUT', JSON.stringify({ project: 'project-3', thread_id: '12', reason: 'why' }));
    assert.equal(f.seen.length, 1);
    assert.deepEqual(JSON.parse(f.seen[0].body), { project: 'project-3', reason: 'why', actor: 'console' });
  } finally { f.restore(); }
});
