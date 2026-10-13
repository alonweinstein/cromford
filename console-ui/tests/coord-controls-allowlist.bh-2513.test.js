import test from 'node:test';
import assert from 'node:assert/strict';
import { onRequest } from '../functions/api/coord/[[path]].js';

// BH-2513 (slice BH-2619): the Controls editors' four PUTs are allowlist rows
// with needsReason. Each forwards only its listed fields plus a stamped actor,
// and refuses a blank or non-string reason before anything reaches the worker.
// DELETE rules and PUT review-gate stay off the table.

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
      headers: { cookie: `dash=bh2513-${++cookieSeq}`, 'content-type': 'application/json' },
      body
    }),
    env: { HARNESS_SECRET: SECRET },
    params: { path: rest.split('/') }
  });

const ROUTES = [
  ['review-gate/thresholds', { scope: 'hub', window_days: 14, min_merges: 5, tighten_rate: 0.2, clear_rate: 0.05, note: 'n' }],
  ['rules', { scope: 'hub', selector: 'lane:x', kind: 'cap', max_concurrent: 2, note: 'n' }],
  ['retry-policies', { lane: 'build', max_attempts: 3, backoff_seconds: 60, escalate_allowed: 1, note: 'n' }],
  ['contracts', { phase: 'plan', artifact_kind: 'file', pattern: 'plan.md', note: 'n' }]
];

for (const [rest, legit] of ROUTES) {
  test(`P1: PUT ${rest} forwards only its fields plus reason, actor stamped, no query`, async () => {
    const f = stubFetch();
    try {
      const res = await call(rest, 'PUT', JSON.stringify({ ...legit, actor: 'someone-else', smuggled: 1, reason: 'why' }), '?actor=mallory&smuggled=1');
      assert.equal(res.status, 200);
      assert.equal(f.seen.length, 1);
      assert.equal(f.seen[0].url, `${JOBS}/api/${rest}`);
      assert.equal(f.seen[0].method, 'PUT');
      assert.deepEqual(JSON.parse(f.seen[0].body), { ...legit, reason: 'why', actor: 'console' });
    } finally { f.restore(); }
  });

  test(`P1b: PUT ${rest} forwards a padded reason exactly as sent`, async () => {
    const f = stubFetch();
    try {
      const res = await call(rest, 'PUT', JSON.stringify({ ...legit, reason: ' why ' }));
      assert.equal(res.status, 200);
      assert.equal(JSON.parse(f.seen[0].body).reason, ' why ');
    } finally { f.restore(); }
  });

  test(`P2: PUT ${rest} with a missing, blank or non-string reason is a 400 and reaches nothing`, async () => {
    const f = stubFetch();
    try {
      const bad = [{}, { reason: '' }, { reason: '  ' }, { reason: 42 }, { reason: ['x'] }, { reason: null }, { reason: {} }];
      for (const extra of bad) {
        const res = await call(rest, 'PUT', JSON.stringify({ ...legit, ...extra }));
        assert.equal(res.status, 400, JSON.stringify(extra));
        assert.equal((await res.json()).error, 'a reason is required', JSON.stringify(extra));
      }
      assert.equal(f.seen.length, 0);
    } finally { f.restore(); }
  });

  test(`P2b: PUT ${rest} with a non-object body is the JSON-object 400, not the reason 400`, async () => {
    const f = stubFetch();
    try {
      const res = await call(rest, 'PUT', '[{"reason":"x"}]');
      assert.equal(res.status, 400);
      assert.match((await res.json()).error, /must carry a JSON object body/);
      assert.equal(f.seen.length, 0);
    } finally { f.restore(); }
  });
}

test('P3: DELETE rules, PUT review-gate and the neighbouring verbs stay 405 and reach nothing', async () => {
  const f = stubFetch();
  try {
    const off = [['DELETE', 'rules'], ['PUT', 'review-gate'], ['POST', 'rules'], ['PUT', 'rules/x'], ['DELETE', 'contracts']];
    for (const [method, rest] of off) {
      const res = await call(rest, method, JSON.stringify({ reason: 'why', scope: 'hub' }));
      assert.equal(res.status, 405, `${method} ${rest}`);
      assert.equal((await res.json()).error, `method ${method} not allowed on /api/coord/${rest}`);
    }
    assert.equal(f.seen.length, 0);
  } finally { f.restore(); }
});
