import test from 'node:test';
import assert from 'node:assert/strict';
import { onRequest } from '../functions/api/coord/[[path]].js';

// BH-4082 (slice C0): the Projects form's PUT is an allowlist row with
// needsReason. It forwards only the project's fleet.conf columns and the
// reason, stamps the actor itself, and refuses a blank reason before anything
// reaches the worker. There is no DELETE.

const JOBS = 'https://harness-jobs.operator.workers.dev';
const CONSOLE = 'https://harness-console.operator.workers.dev';
const SECRET = 'test-harness-secret';

function stubFetch() {
  const seen = [];
  const real = globalThis.fetch;
  globalThis.fetch = async (input, init = {}) => {
    const target = typeof input === 'string' ? input : input.url;
    if (target.startsWith(CONSOLE)) return new Response('', { status: 200 });
    seen.push({ url: target, method: init.method, body: init.body });
    return new Response('{}', { status: 200, headers: { 'content-type': 'application/json' } });
  };
  return { seen, restore: () => { globalThis.fetch = real; } };
}

let cookieSeq = 0;
const call = (rest, method, body, search = '') =>
  onRequest({
    request: new Request(`https://console.example.pages.dev/api/coord/${rest}${search}`, {
      method,
      headers: { cookie: `dash=bh4082-${++cookieSeq}`, 'content-type': 'application/json' },
      body
    }),
    env: { HARNESS_SECRET: SECRET },
    params: { path: rest.split('/') }
  });

const LEGIT = {
  project: 'project-3', repo: 'example-org/project-3', prod_url: 'https://os.project-3.example', board_api_prefix: '/api/feature-board',
  cron_offset: 6, box: 'box-project-3-2', tailnet_ip: '10.0.0.3', note: 'n'
};

test('A1: PUT projects forwards only its fields plus reason, actor stamped over the browser one', async () => {
  const f = stubFetch();
  try {
    const res = await call('projects', 'PUT', JSON.stringify({ ...LEGIT, actor: 'someone-else', smuggled: 1, reason: 'why' }), '?actor=mallory');
    assert.equal(res.status, 200);
    assert.equal(f.seen.length, 1);
    assert.equal(f.seen[0].url, `${JOBS}/api/projects`);
    assert.equal(f.seen[0].method, 'PUT');
    assert.deepEqual(JSON.parse(f.seen[0].body), { ...LEGIT, reason: 'why', actor: 'console' });
  } finally { f.restore(); }
});

test('A2: PUT projects with a missing, blank or non-string reason is a 400 and reaches nothing', async () => {
  const f = stubFetch();
  try {
    for (const extra of [{}, { reason: '' }, { reason: '  ' }, { reason: 42 }, { reason: null }]) {
      const res = await call('projects', 'PUT', JSON.stringify({ ...LEGIT, ...extra }));
      assert.equal(res.status, 400, JSON.stringify(extra));
      assert.equal((await res.json()).error, 'a reason is required', JSON.stringify(extra));
    }
    assert.equal(f.seen.length, 0);
  } finally { f.restore(); }
});

test('A3: DELETE projects and the neighbouring verbs stay 405 and reach nothing', async () => {
  const f = stubFetch();
  try {
    for (const [method, rest] of [['DELETE', 'projects'], ['POST', 'projects'], ['PUT', 'projects/project-3'], ['PATCH', 'projects']]) {
      const res = await call(rest, method, JSON.stringify({ ...LEGIT, reason: 'why' }));
      assert.equal(res.status, 405, `${method} ${rest}`);
    }
    assert.equal(f.seen.length, 0);
  } finally { f.restore(); }
});
