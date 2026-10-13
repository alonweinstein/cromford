import test from 'node:test';
import assert from 'node:assert/strict';
import { onRequest } from '../functions/api/coord/[[path]].js';

// BH-1946: the coord proxy's write allowlist gains exactly one path, POST
// hub/restore-lab, so the RESTORE LAB panel's confirm reaches the jobs worker
// (which re-checks confirm:true itself). The box-only routes under it stay 405
// from a browser.

const JOBS = 'https://harness-jobs.operator.workers.dev';
const SECRET = 'test-harness-secret';

function stubFetch() {
  const seen = [];
  const real = globalThis.fetch;
  globalThis.fetch = async (input, init = {}) => {
    const target = typeof input === 'string' ? input : input.url;
    if (target.startsWith('https://harness-console.operator.workers.dev')) return new Response('', { status: 200 });
    seen.push({ url: target, method: init.method, headers: init.headers || {}, body: init.body });
    return new Response(JSON.stringify({ id: 5, status: 'requested' }), {
      status: 201, headers: { 'content-type': 'application/json' }
    });
  };
  return { seen, restore: () => { globalThis.fetch = real; } };
}

let cookieSeq = 0;
// params.path is split as-is, so a trailing slash reaches the proxy as an empty segment.
const call = (rest, method, body) =>
  onRequest({
    request: new Request(`https://console.example.pages.dev/api/coord/${rest}`, {
      method,
      headers: { cookie: `dash=restorelab${++cookieSeq}`, 'content-type': 'application/json' },
      body
    }),
    env: { HARNESS_SECRET: SECRET },
    params: { path: rest.split('/') }
  });

// The forwarded body is the page's body PLUS the proxy-stamped actor (BH-1946
// review): the page sends no actor, and requested_by must never be missing or
// whatever a browser typed. This case used to assert the body byte-for-byte
// unchanged; the stamp is the deliberate difference, and every field the page
// sent still arrives as sent.
test('POST hub/restore-lab is forwarded with the bearer, the body, and the proxy-stamped actor', async () => {
  const f = stubFetch();
  try {
    const sent = { box: 'hub-1', snapshot: 'latest', confirm: true };
    const res = await call('hub/restore-lab', 'POST', JSON.stringify(sent));
    assert.equal(res.status, 201);
    assert.deepEqual(JSON.parse(await res.text()), { id: 5, status: 'requested' });
    assert.equal(f.seen.length, 1);
    assert.equal(f.seen[0].url, `${JOBS}/api/hub/restore-lab`);
    assert.equal(f.seen[0].method, 'POST');
    assert.equal(f.seen[0].headers.authorization, `Bearer ${SECRET}`);
    assert.deepEqual(JSON.parse(f.seen[0].body), { ...sent, actor: 'console' });
  } finally { f.restore(); }
});

test('a client-sent actor on a hub POST is overwritten by the proxy, on both hub writes', async () => {
  const f = stubFetch();
  try {
    await call('hub/restore-lab', 'POST', JSON.stringify({ box: 'hub-1', snapshot: 'latest', confirm: true, actor: 'mallory' }));
    await call('hub/promote', 'POST', JSON.stringify({ target: 'box-2', expected_epoch: 7, confirm: true, actor: 'operator' }));
    await call('hub/promote', 'POST', JSON.stringify({ target: 'box-2', expected_epoch: 7, confirm: true, actor: { name: 'x' } }));
    assert.equal(f.seen.length, 3);
    for (const s of f.seen) assert.equal(JSON.parse(s.body).actor, 'console', s.url);
    assert.equal(JSON.parse(f.seen[0].body).box, 'hub-1', 'the rest of the body is untouched');
    assert.equal(JSON.parse(f.seen[1].body).expected_epoch, 7);
  } finally { f.restore(); }
});

test('a hub POST whose body is not a JSON object is refused 400 and never reaches the worker', async () => {
  const f = stubFetch();
  try {
    for (const body of ['not json', '[{"actor":"x"}]', 'null', '"console"', '']) {
      const res = await call('hub/restore-lab', 'POST', body);
      assert.equal(res.status, 400, JSON.stringify(body));
    }
    assert.equal(f.seen.length, 0, 'nothing reached the jobs worker');
  } finally { f.restore(); }
});

test('the box-only restore-lab routes, other verbs and other spellings stay 405', async () => {
  const f = stubFetch();
  try {
    for (const [rest, method] of [
      ['hub/restore-lab/claim', 'POST'],
      ['hub/restore-lab/7/result', 'POST'],
      ['hub/restore-lab/', 'POST'],
      ['HUB/RESTORE-LAB', 'POST'],
      ['hub/restore-lab', 'PUT'],
      ['hub/restore-lab', 'PATCH'],
      ['hub/restore-lab', 'DELETE'],
    ]) {
      const res = await call(rest, method, method === 'DELETE' ? undefined : '{}');
      assert.equal(res.status, 405, `${method} ${rest}`);
    }
    assert.equal(f.seen.length, 0, 'nothing reached the jobs worker');
  } finally { f.restore(); }
});
