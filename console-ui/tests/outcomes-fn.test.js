import test from 'node:test';
import assert from 'node:assert/strict';
import { onRequest } from '../functions/api/outcomes/[[path]].js';

// The Pages Function's own contract, which no screen test can reach: it must
// fail CLOSED (no session, unreachable console and a missing secret are three
// different refusals), it must be READ-ONLY, it must never leak the bearer to
// the browser, and a partial upstream failure must be NAMED rather than
// rendered as an empty table.

const OK_BODIES = {
  '/api/metrics/outcomes': { outcomes: [{ repo: 'o/a', pr: 'p', outcome: 'reverted' }] },
  '/api/ledger': { ledgers: [{ key: 'p', status: 'merged' }] },
  '/api/metrics/pr-costs': { pr_costs: [{ pr_url: 'p', cost_usd: 1 }] },
  '/api/metrics/burn': { burn_days: [{ day: '2026-08-29', usd_equiv: 5 }] },
  '/api/review-gate': { gates: [{ repo: 'o/a', tightened: 1 }], thresholds: [{ scope: '*', tighten_rate: 0.2 }] }
};

// The function delegates the session check to the console worker over fetch and
// then fans out to harness-jobs over the same fetch, so the only way to test it
// is to be both. `plan` decides what each upstream path answers.
function withFetch(plan, fn) {
  const real = globalThis.fetch;
  const calls = [];
  globalThis.fetch = async (url, init) => {
    const u = String(url);
    calls.push({ url: u, init });
    const answer = plan(u, init);
    if (answer instanceof Error) throw answer;
    return answer;
  };
  return Promise.resolve(fn(calls)).finally(() => { globalThis.fetch = real; });
}

const jsonRes = (body, status = 200) =>
  new Response(JSON.stringify(body), { status, headers: { 'content-type': 'application/json' } });

// A fresh cookie per test: the function caches session verdicts per cookie for
// a minute at module scope, so a shared value would let one test's grant answer
// the next test's refusal.
let n = 0;
const cookie = () => `dash=tok${n++}`;

const happyPlan = (u) => {
  if (u.includes('harness-console')) return new Response('', { status: 200 });
  for (const [path, body] of Object.entries(OK_BODIES)) {
    if (u.includes(path)) return jsonRes(body);
  }
  return jsonRes({}, 404);
};

const req = (opts = {}) => new Request('https://console.example/api/outcomes/summary', {
  method: opts.method || 'GET',
  headers: opts.cookie === null ? {} : { cookie: opts.cookie || cookie() }
});

// --- refusals ----------------------------------------------------------------

test('no HARNESS_SECRET is a 503 that says so, not a 401', () => withFetch(happyPlan, async () => {
  // An operator who IS signed in must not be told they are signed out because
  // the Pages project is missing a variable — that sends them to re-login
  // forever instead of to the settings page.
  const res = await onRequest({ request: req(), env: {} });
  assert.equal(res.status, 503);
  assert.match((await res.json()).error, /HARNESS_SECRET/);
}));

test('no cookie is 403 and never reaches harness-jobs', () => withFetch(happyPlan, async (calls) => {
  const res = await onRequest({ request: req({ cookie: null }), env: { HARNESS_SECRET: 's' } });
  assert.equal(res.status, 403);
  assert.equal(calls.filter((c) => c.url.includes('harness-jobs')).length, 0);
}));

test('the console refusing the cookie is 403', () => withFetch(
  (u) => (u.includes('harness-console') ? new Response('', { status: 302 }) : jsonRes({})),
  async () => {
    const res = await onRequest({ request: req(), env: { HARNESS_SECRET: 's' } });
    assert.equal(res.status, 403);
  }
));

test('an UNREACHABLE console is a refusal, never a grant', () => withFetch(
  (u) => (u.includes('harness-console') ? new Error('down') : jsonRes({})),
  async (calls) => {
    const res = await onRequest({ request: req(), env: { HARNESS_SECRET: 's' } });
    assert.equal(res.status, 403);
    assert.equal(calls.filter((c) => c.url.includes('harness-jobs')).length, 0);
  }
));

// --- read-only ---------------------------------------------------------------

for (const method of ['POST', 'PUT', 'PATCH', 'DELETE']) {
  test(`${method} is refused — nothing on OUTCOMES writes`, () => withFetch(happyPlan, async (calls) => {
    const res = await onRequest({
      request: req({ method }), env: { HARNESS_SECRET: 's' }
    });
    assert.equal(res.status, 405);
    // The gate this screen renders is decided by bin/review-tighten.sh. A
    // dashboard that could flip it would be a second, unreviewed merge path.
    assert.equal(calls.filter((c) => c.url.includes('harness-jobs')).length, 0);
  }));
}

// --- the happy path ----------------------------------------------------------

test('one call fans out to all five tables and returns them under stable keys', () => withFetch(happyPlan, async (calls) => {
  const res = await onRequest({ request: req(), env: { HARNESS_SECRET: 'sekrit' } });
  assert.equal(res.status, 200);
  const body = await res.json();
  assert.deepEqual(body.outcomes, OK_BODIES['/api/metrics/outcomes'].outcomes);
  assert.deepEqual(body.merges, OK_BODIES['/api/ledger'].ledgers);
  assert.deepEqual(body.pr_costs, OK_BODIES['/api/metrics/pr-costs'].pr_costs);
  assert.deepEqual(body.burn_days, OK_BODIES['/api/metrics/burn'].burn_days);
  assert.deepEqual(body.gates, OK_BODIES['/api/review-gate'].gates);
  // The thresholds ride the SAME response as the gates, so a rate can never be
  // rendered beside a threshold it was not judged against.
  assert.deepEqual(body.thresholds, OK_BODIES['/api/review-gate'].thresholds);
  assert.deepEqual(body.degraded, []);
  assert.equal(calls.filter((c) => c.url.includes('harness-jobs')).length, 5);
}));

test('the bearer goes to harness-jobs and never into the response', () => withFetch(happyPlan, async (calls) => {
  const res = await onRequest({ request: req(), env: { HARNESS_SECRET: 'sekrit' } });
  const text = await res.text();
  assert.equal(text.includes('sekrit'), false);
  const jobCalls = calls.filter((c) => c.url.includes('harness-jobs'));
  assert.equal(jobCalls.length > 0, true);
  for (const c of jobCalls) {
    assert.equal(c.init.headers.authorization, 'Bearer sekrit');
  }
  // ...and never to the console, which authenticates on the cookie alone.
  const consoleCalls = calls.filter((c) => c.url.includes('harness-console'));
  for (const c of consoleCalls) {
    assert.equal(Boolean(c.init && c.init.headers && c.init.headers.authorization), false);
  }
}));

test('every read carries a stated row cap rather than the caller\'s', () => withFetch(happyPlan, async (calls) => {
  await onRequest({ request: req(), env: { HARNESS_SECRET: 's' } });
  const urls = calls.filter((c) => c.url.includes('harness-jobs')).map((c) => c.url);
  assert.equal(urls.some((u) => u.includes('/api/metrics/outcomes?limit=500')), true);
  assert.equal(urls.some((u) => u.includes('/api/ledger?kind=merge&limit=500')), true);
  assert.equal(urls.some((u) => u.includes('/api/metrics/burn?days=90')), true);  // determinism: ok asserts the URL the function builds, not data inside a window
}));

// --- partial and total failure ----------------------------------------------

test('one upstream failing is NAMED, and the rest still render', () => withFetch(
  (u) => {
    if (u.includes('harness-console')) return new Response('', { status: 200 });
    if (u.includes('/api/metrics/pr-costs')) return jsonRes({ error: 'boom' }, 500);
    if (u.includes('/api/metrics/burn')) return new Error('unreachable');
    for (const [path, body] of Object.entries(OK_BODIES)) if (u.includes(path)) return jsonRes(body);
    return jsonRes({}, 404);
  },
  async () => {
    const res = await onRequest({ request: req(), env: { HARNESS_SECRET: 's' } });
    assert.equal(res.status, 200);
    const body = await res.json();
    // An empty table that read as "nothing happened" would be the opposite of
    // what happened, so the screen is told which read is missing.
    assert.deepEqual(body.degraded.sort(), ['burn_days: unreachable', 'pr_costs: http 500']);
    assert.deepEqual(body.pr_costs, []);
    assert.deepEqual(body.burn_days, []);
    assert.equal(body.outcomes.length, 1);
  }
));

test('a read that answers with the wrong shape yields an empty array, never a crash', () => withFetch(
  (u) => (u.includes('harness-console')
    ? new Response('', { status: 200 })
    : jsonRes({ outcomes: 'not an array' })),
  async () => {
    const res = await onRequest({ request: req(), env: { HARNESS_SECRET: 's' } });
    assert.equal(res.status, 200);
    const body = await res.json();
    assert.deepEqual(body.outcomes, []);
    assert.deepEqual(body.thresholds, []);
  }
));

test('everything failing is 502 — no view, not a degraded one', () => withFetch(
  (u) => (u.includes('harness-console') ? new Response('', { status: 200 }) : new Error('down')),
  async () => {
    const res = await onRequest({ request: req(), env: { HARNESS_SECRET: 's' } });
    assert.equal(res.status, 502);
  }
));

test('the payload is never cached by a shared hop', () => withFetch(happyPlan, async () => {
  const res = await onRequest({ request: req(), env: { HARNESS_SECRET: 's' } });
  assert.equal(res.headers.get('cache-control'), 'no-store');
}));
