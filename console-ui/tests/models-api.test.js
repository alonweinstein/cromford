import test from 'node:test';
import assert from 'node:assert/strict';
import { api } from '../src/api.js';
import { onRequest } from '../functions/api/coord/[[path]].js';

// BH-1510.3 — the MODELS screen's wire contract, both halves: what src/api.js
// puts on the wire, and the coord proxy letting the two writes through. A
// screen that renders an edit form the proxy 405s is a control panel that
// controls nothing (the same reason settings-api.test.js exists).

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

test('the reads go through the coord proxy, project-scoped when a tab is', async () => {
  const f = captureFetch();
  try {
    await api.modelRoutes();
    await api.modelRoutes('project-4');
    await api.modelRoute('build.qa');
    await api.modelRoute('build.qa', 'project-4');
    await api.modelPrices();
    await api.modelRouteChanges({ role: 'build.qa' });
    await api.modelRouteChanges({ role: 'build.qa', project: 'project-4', limit: 50 });
    await api.llmSpend({ stage: 'qa', project: 'project-4', since: '2026-09-15T00:00:00Z' });
    assert.deepEqual(f.calls.map((c) => c.url), [
      '/api/coord/model-routes',
      '/api/coord/model-routes?project=project-4',
      '/api/coord/model-routes/build.qa',
      '/api/coord/model-routes/build.qa?project=project-4',
      '/api/coord/model-prices',
      '/api/coord/model-route-changes?role=build.qa',
      '/api/coord/model-route-changes?role=build.qa&project=project-4&limit=50',
      '/api/coord/metrics/llm-spend?stage=qa&project=project-4&since=2026-09-15T00%3A00%3A00Z'
    ]);
  } finally {
    f.restore();
  }
});

test('a ladder write is a PUT of the whole ladder; a reset is a POST to its own route', async () => {
  const f = captureFetch();
  try {
    const body = { role: 'build.qa', project: 'project-4', ladder: [{ model: 'm', runner: 'claude' }], actor: 'console', reason: 'r' };
    await api.putModelRoute(body);
    await api.resetModelRoute({ role: 'build.qa', project: 'project-4', actor: 'console', reason: 'r' });
    assert.equal(f.calls[0].url, '/api/coord/model-routes');
    assert.equal(f.calls[0].method, 'PUT');
    assert.deepEqual(JSON.parse(f.calls[0].body), body);
    assert.equal(f.calls[1].url, '/api/coord/model-routes/reset');
    assert.equal(f.calls[1].method, 'POST');
  } finally {
    f.restore();
  }
});

// ------------------------------------------------------------ the proxy

function stubProxyFetch() {
  const seen = [];
  const real = globalThis.fetch;
  globalThis.fetch = async (url, init = {}) => {
    const u = String(url);
    if (u.endsWith('/api/dash/fleet')) return new Response('{}', { status: 200 });
    seen.push({ url: u, method: init.method || 'GET', body: init.body });
    return new Response(JSON.stringify({ ok: true }), { status: 200, headers: { 'content-type': 'application/json' } });
  };
  return { seen, restore: () => { globalThis.fetch = real; } };
}

const call = (rest, { method = 'GET', body } = {}) => onRequest({
  request: new Request(`https://console.test/api/coord/${rest}`, {
    method, headers: { cookie: `dash=bh-1510-3-${method}-${rest}` },
    ...(body === undefined ? {} : { body: JSON.stringify(body) })
  }),
  env: { HARNESS_SECRET: SECRET },
  params: { path: rest.split('?')[0].split('/') }
});

test('PUT /model-routes and POST /model-routes/reset reach the worker', async () => {
  const f = stubProxyFetch();
  try {
    const put = await call('model-routes', { method: 'PUT', body: { role: 'build.qa', ladder: [] } });
    assert.equal(put.status, 200);
    assert.equal(f.seen[0].url, `${JOBS}/api/model-routes`);
    assert.equal(f.seen[0].method, 'PUT');
    const reset = await call('model-routes/reset', { method: 'POST', body: { role: 'build.qa', project: 'project-4' } });
    assert.equal(reset.status, 200);
    assert.equal(f.seen[1].url, `${JOBS}/api/model-routes/reset`);
    assert.equal(f.seen[1].method, 'POST');
  } finally {
    f.restore();
  }
});

test('the allowlist stays narrow around the new writes', async () => {
  for (const [rest, method] of [
    ['model-routes', 'POST'], ['model-routes', 'DELETE'], ['model-routes/reset', 'PUT'],
    ['model-routes/build.qa', 'PUT'], ['model-route-changes', 'POST'], ['model-prices', 'POST']
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
