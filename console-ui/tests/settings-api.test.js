import test from 'node:test';
import assert from 'node:assert/strict';
import { api } from '../src/api.js';
import { onRequest } from '../functions/api/coord/[[path]].js';

// Two contracts in one file, because a settings screen that renders perfectly
// and cannot write is the same thing as no settings screen:
//   1. the URLs and BODIES src/api.js puts on the wire, and
//   2. the Pages proxy actually letting those verbs through to harness-jobs.
// The second half is the one that would otherwise be found by a 405 on the
// operator's first click.

const JOBS = 'https://harness-jobs.operator.workers.dev';
const SECRET = 'test-harness-secret';

function captureFetch() {
  const calls = [];
  const real = globalThis.fetch;
  globalThis.fetch = async (url, init = {}) => {
    calls.push({ url: String(url), method: init.method || 'GET', body: init.body });
    return { ok: true, status: 200, text: async () => JSON.stringify({ ok: true }) };
  };
  return { calls, restore: () => { globalThis.fetch = real; } };
}

// ------------------------------------------------------------ read URLs

test('the registry and status reads go through the coord proxy', async () => {
  const f = captureFetch();
  try {
    await api.lanesRegistry();
    await api.lanesStatus();
    await api.lanesStatus('project-4');
    assert.equal(f.calls[0].url, '/api/coord/lanes/registry');
    assert.equal(f.calls[1].url, '/api/coord/lanes/status');
    assert.equal(f.calls[2].url, '/api/coord/lanes/status?project=project-4');
  } finally {
    f.restore();
  }
});

// ----------------------------------------------------------- write bodies

test('a lane flag write is a PUT to the existing flags route, body byte-for-byte', async () => {
  const f = captureFetch();
  try {
    await api.setCoordFlag('lane-off-alert-triage', true, 'turned off from Mission Control');
    assert.equal(f.calls[0].url, '/api/coord/flags');
    assert.equal(f.calls[0].method, 'PUT');
    assert.deepEqual(JSON.parse(f.calls[0].body), {
      name: 'lane-off-alert-triage', active: 1, actor: 'console',
      reason: 'turned off from Mission Control'
    });
  } finally {
    f.restore();
  }
});

test('a knob write is a PUT to the existing settings route, body byte-for-byte', async () => {
  const f = captureFetch();
  try {
    await api.setCoordSetting({
      key: 'lane.merge-conductor.mc_max_prs', value: 12, actor: 'console', note: 'set from Mission Control'
    });
    assert.equal(f.calls[0].url, '/api/coord/settings');
    assert.equal(f.calls[0].method, 'PUT');
    assert.deepEqual(JSON.parse(f.calls[0].body), {
      key: 'lane.merge-conductor.mc_max_prs', value: 12, actor: 'console', note: 'set from Mission Control'
    });
  } finally {
    f.restore();
  }
});

test('the master switches POST to their own routes', async () => {
  const f = captureFetch();
  try {
    await api.lanesAll('all-off', { actor: 'console', reason: 'all lanes stopped from Mission Control' });
    await api.lanesAll('all-on', { actor: 'console', reason: 'all lanes resumed from Mission Control' });
    assert.equal(f.calls[0].url, '/api/coord/lanes/all-off');
    assert.equal(f.calls[0].method, 'POST');
    assert.deepEqual(JSON.parse(f.calls[0].body), {
      actor: 'console', reason: 'all lanes stopped from Mission Control'
    });
    assert.equal(f.calls[1].url, '/api/coord/lanes/all-on');
  } finally {
    f.restore();
  }
});

test('nothing else can be posted through the all-switch helper', async () => {
  await assert.rejects(() => api.lanesAll('delete-everything', {}), /all-off|all-on/);
});

// -------------------------------------------------- the proxy allowlist

function stubProxyFetch() {
  const seen = [];
  const real = globalThis.fetch;
  globalThis.fetch = async (input, init = {}) => {
    const target = typeof input === 'string' ? input : input.url;
    if (target.startsWith('https://harness-console.operator.workers.dev')) {
      return new Response('', { status: 200 });
    }
    seen.push({ url: target, method: init.method, body: init.body });
    return new Response(JSON.stringify({ ok: true }), {
      status: 200, headers: { 'content-type': 'application/json' }
    });
  };
  return { seen, restore: () => { globalThis.fetch = real; } };
}

// The function memoises the session verdict for 60s, so every call needs its
// own cookie or a previous verdict answers for it.
let seq = 0;
const call = (rest, { method = 'GET', body = null, search = '' } = {}) =>
  onRequest({
    request: new Request(`https://console.example.pages.dev/api/coord/${rest}${search}`, {
      method, headers: { cookie: `dash=settings${++seq}` },
      ...(body ? { body: JSON.stringify(body) } : {})
    }),
    env: { HARNESS_SECRET: SECRET },
    params: { path: rest.split('/').filter(Boolean) }
  });

test('the lane reads forward as GETs, bearer attached in the Pages runtime', async () => {
  const f = stubProxyFetch();
  try {
    const res = await call('lanes/status', { search: '?project=project-4' });
    assert.equal(res.status, 200);
    assert.equal(f.seen[0].url, `${JOBS}/api/lanes/status?project=project-4`);
    await call('lanes/registry');
    assert.equal(f.seen[1].url, `${JOBS}/api/lanes/registry`);
  } finally {
    f.restore();
  }
});

test('PUT /settings reaches the worker — without this the knobs are a dead surface', async () => {
  const f = stubProxyFetch();
  try {
    const res = await call('settings', {
      method: 'PUT', body: { key: 'lane.merge-conductor.mc_max_prs', value: 12 }
    });
    assert.equal(res.status, 200, 'a knob write is allowed through');
    assert.equal(f.seen[0].url, `${JOBS}/api/settings`);
    assert.equal(f.seen[0].method, 'PUT');
    assert.deepEqual(JSON.parse(f.seen[0].body), { key: 'lane.merge-conductor.mc_max_prs', value: 12, actor: 'console' });
  } finally {
    f.restore();
  }
});

test('POST /lanes/all-off and /lanes/all-on reach the worker', async () => {
  for (const which of ['all-off', 'all-on']) {
    const f = stubProxyFetch();
    try {
      const res = await call(`lanes/${which}`, { method: 'POST', body: { actor: 'console' } });
      assert.equal(res.status, 200, which);
      assert.equal(f.seen[0].url, `${JOBS}/api/lanes/${which}`);
      assert.equal(f.seen[0].method, 'POST');
    } finally {
      f.restore();
    }
  }
});

test('the allowlist stays narrow — no DELETE, and no POST to anything else', async () => {
  for (const [rest, method] of [
    // TEST-CHANGE BH-4153: DELETE flags is now an admitted row (the /flags CLEAR,
    // reason required); its neighbour flags/x is what must stay 405.
    ['settings', 'DELETE'], ['flags/x', 'DELETE'], ['jobs/j1', 'POST'],
    ['lanes/status', 'POST'], ['settings', 'POST'], ['lanes/all-off', 'PUT'],
    // The allow-list matches the two all-switch paths EXACTLY, so a
    // neighbouring lanes/* verb a future phase might add is not admitted by
    // accident — it has to be added here on purpose.
    ['lanes/tick', 'POST'], ['lanes/registry', 'POST'], ['lanes', 'POST']
  ]) {
    const f = stubProxyFetch();
    try {
      const res = await call(rest, { method, body: {} });
      assert.equal(res.status, 405, `${method} /${rest}`);
      assert.equal(f.seen.length, 0, `${method} /${rest} reached the jobs worker`);
    } finally {
      f.restore();
    }
  }
});
