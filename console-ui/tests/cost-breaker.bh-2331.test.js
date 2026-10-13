import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { render } from 'preact-render-to-string';
import { h } from 'preact';
import { api } from '../src/api.js';
import { onRequest } from '../functions/api/coord/[[path]].js';
import {
  isAutohaltReason, autohaltTrips, autohaltState, callGuardRows, resetFormState,
  makeResetAction, GUARD_LIMIT
} from '../src/lib/cost-breaker.js';
import { CostBreakerView, ResetForm } from '../src/screens/CostBreaker.js';

// BH-2331: the COST BREAKER section on /costs. Three reads (pause flags,
// settings, call-guard) and one audited write (DELETE /api/call-guard through
// the coord proxy, actor stamped there).

const JOBS = 'https://harness-jobs.operator.workers.dev';
const SECRET = 'test-harness-secret';

// The two reason shapes bin/pipeline-health.sh's cb_halt writes, verbatim.
const RATE = '$161.20/PR over 24h (cost autohalt)';
const ZERO = '$643 spend with 0 merged PR(s) over 7d (zero-merge breaker)';

// ------------------------------------------------------------ 1. classifier

test('1 isAutohaltReason: only the two literal cb_halt suffixes match', () => {
  assert.equal(isAutohaltReason(RATE), true);
  assert.equal(isAutohaltReason(ZERO), true);
  assert.equal(isAutohaltReason(`  ${RATE}  `), true, 'trimmed');
  for (const neg of [
    'cost autohalt review by operator', '(cost autohalt) investigating', 'paused for cost',
    'zero-merge breaker test', 'cost autohalt', '', null, undefined, 42
  ]) {
    assert.equal(isAutohaltReason(neg), false, JSON.stringify(neg));
  }
});

// ------------------------------------------------------------ 2. trips

const flagRow = (name, reason, active = 1, extra = {}) => ({
  name, active, reason, actor: 'pipeline-health', updated_at: '2026-09-25T10:00:00Z', ...extra
});

test('2 autohaltTrips: exactly the real project trips, string active accepted', () => {
  const payload = {
    flags: [
      flagRow('paused-project-5', RATE, 1, { updated_at: '2026-09-25T09:00:00Z' }),
      flagRow('paused-project-3', ZERO, '1'),
      flagRow('paused-all', RATE),
      flagRow('paused-box-x', RATE),
      flagRow('paused-project-4', RATE, 0),
      flagRow('paused-project-1', 'cost review', 1, { actor: 'console' }),
      flagRow('paused-lane-y', ZERO),
      flagRow('cost-autohalt-off', RATE),
    ]
  };
  const { trips, unreadable } = autohaltTrips(payload);
  assert.equal(unreadable, false);
  assert.deepEqual(trips.map((t) => t.project).sort(), ['project-3', 'project-5']);
  const ts = trips.find((t) => t.project === 'project-5');
  // BH-5526: a paused-<p> breaker row is a legacy trip, kind 'pause' (the breaker now writes spend-hold-<p>).
  assert.deepEqual(ts, { project: 'project-5', kind: 'pause', reason: RATE, since: '2026-09-25T09:00:00Z', actor: 'pipeline-health' });
});

test('2b autohaltTrips: an unreadable payload is flagged, never "no trips"', () => {
  for (const bad of [{}, null, undefined, { flags: 'x' }]) {
    const r = autohaltTrips(bad);
    assert.equal(r.unreadable, true, JSON.stringify(bad));
    assert.deepEqual(r.trips, []);
  }
  assert.equal(autohaltTrips({ flags: [] }).unreadable, false);
});

// ------------------------------------------------------------ 3. state

const settingsWith = (value) => ({
  settings: [
    { key: 'lane.merge-conductor.mc_max_prs', value: '12' },
    ...(value === undefined ? [] : [{ key: 'lane.pipeline-health.cost_autohalt', value }])
  ]
});

test('3 autohaltState: row 0 off, row 1 on, absent default on, junk default + note, unloaded null', () => {
  assert.deepEqual(
    { on: autohaltState(settingsWith('0')).on, source: autohaltState(settingsWith('0')).source },
    { on: false, source: 'settings' });
  assert.deepEqual(
    { on: autohaltState(settingsWith('1')).on, source: autohaltState(settingsWith('1')).source },
    { on: true, source: 'settings' });
  const absent = autohaltState(settingsWith(undefined));
  assert.equal(absent.on, true);
  assert.equal(absent.source, 'default');
  assert.equal(absent.note, undefined);
  const junk = autohaltState(settingsWith('yes'));
  assert.equal(junk.on, true);
  assert.equal(junk.source, 'default');
  assert.equal(junk.raw, 'yes');
  assert.match(junk.note, /yes/);
  assert.equal(autohaltState(null).on, null);
  assert.equal(autohaltState({}).on, null);
});

// ------------------------------------------------------------ 4. guard rows

const guardRow = (fp, paid, refused, extra = {}) => ({
  project: 'project-5', stage: 'review', fp, paid, refused, last_at: '2026-09-25T11:00:00Z', ...extra
});

test('4 callGuardRows: numbers coerced, capHit only when refused > 0, capped at the worker LIMIT', () => {
  const { rows, capped, unreadable } = callGuardRows({ rows: [guardRow('a', '3', '2'), guardRow('b', 1, 0)] });
  assert.equal(unreadable, false);
  assert.equal(capped, false);
  assert.equal(rows[0].paid, 3);
  assert.equal(rows[0].refused, 2);
  assert.equal(rows[0].capHit, true);
  assert.equal(rows[1].capHit, false);
  assert.equal(GUARD_LIMIT, 200);
  const many = (n) => ({ rows: Array.from({ length: n }, (_, i) => guardRow(`fp${i}`, 1, 0)) });
  assert.equal(callGuardRows(many(200)).capped, true);
  assert.equal(callGuardRows(many(199)).capped, false);
  assert.equal(callGuardRows({}).unreadable, true);
});

// ------------------------------------------------------------ 5. form

test('5 resetFormState: blank reason blocks confirm', () => {
  assert.equal(resetFormState('').blocked, true);
  assert.equal(resetFormState('   ').blocked, true);
  assert.equal(resetFormState(undefined).blocked, true);
  assert.equal(resetFormState('loop').blocked, false);
});

// ------------------------------------------------------------ 6. proxy

function stubProxyFetch({ probe = 200 } = {}) {
  const seen = [];
  const real = globalThis.fetch;
  globalThis.fetch = async (input, init = {}) => {
    const target = typeof input === 'string' ? input : input.url;
    if (target.startsWith('https://harness-console.operator.workers.dev')) {
      return new Response('', { status: probe });
    }
    seen.push({ url: target, method: init.method, headers: init.headers });
    return new Response(JSON.stringify({ reset: 2 }), {
      status: 200, headers: { 'content-type': 'application/json' }
    });
  };
  return { seen, restore: () => { globalThis.fetch = real; } };
}

let seq = 0;
const call = (rest, { method = 'GET', search = '' } = {}) =>
  onRequest({
    request: new Request(`https://console.example.pages.dev/api/coord/${rest}${search}`, {
      method, headers: { cookie: `dash=cb${++seq}` }
    }),
    env: { HARNESS_SECRET: SECRET },
    params: { path: rest.split('/').filter(Boolean) }
  });

test('6 proxy: DELETE call-guard reaches the worker with actor stamped console, never the client value', async () => {
  const f = stubProxyFetch();
  try {
    const res = await call('call-guard', {
      method: 'DELETE', search: '?project=project-5&stage=review&fp=a%2Fb+c&reason=loop&actor=mallory'
    });
    assert.equal(res.status, 200);
    assert.equal(f.seen.length, 1);
    const u = new URL(f.seen[0].url);
    assert.equal(`${u.origin}${u.pathname}`, `${JOBS}/api/call-guard`);
    assert.equal(f.seen[0].method, 'DELETE');
    assert.equal(f.seen[0].headers.authorization, `Bearer ${SECRET}`);
    assert.equal(u.searchParams.get('actor'), 'console');
    assert.deepEqual(u.searchParams.getAll('actor'), ['console']);
    assert.equal(u.searchParams.get('project'), 'project-5');
    assert.equal(u.searchParams.get('stage'), 'review');
    assert.equal(u.searchParams.get('fp'), 'a/b c');
    assert.equal(u.searchParams.get('reason'), 'loop');
  } finally {
    f.restore();
  }
});

test('6b proxy: a DELETE without an actor still gets one', async () => {
  const f = stubProxyFetch();
  try {
    await call('call-guard', { method: 'DELETE', search: '?project=p&stage=s&fp=f&reason=r' });
    assert.equal(new URL(f.seen[0].url).searchParams.get('actor'), 'console');
  } finally {
    f.restore();
  }
});

test('6c proxy: only DELETE call-guard is admitted; neighbours stay 405 with zero upstream calls', async () => {
  for (const [rest, method] of [
    // TEST-CHANGE BH-4153: DELETE flags is now an admitted row (the /flags CLEAR,
    // reason required); its neighbour flags/x is what must stay 405.
    ['call-guard/claim', 'DELETE'], ['call-guard/settle', 'DELETE'], ['flags/x', 'DELETE'],
    ['jobs/j1', 'DELETE'], ['settings', 'DELETE'], ['call-guard', 'POST'], ['call-guard', 'PUT']
  ]) {
    const f = stubProxyFetch();
    try {
      const res = await call(rest, { method });
      assert.equal(res.status, 405, `${method} /${rest}`);
      assert.equal(f.seen.length, 0, `${method} /${rest} reached the jobs worker`);
    } finally {
      f.restore();
    }
  }
});

test('6d proxy: an unauthenticated DELETE is 403 and never reaches the worker', async () => {
  const f = stubProxyFetch({ probe: 401 });
  try {
    const res = await call('call-guard', { method: 'DELETE', search: '?project=p&stage=s&fp=f' });
    assert.equal(res.status, 403);
    assert.equal(f.seen.length, 0);
  } finally {
    f.restore();
  }
});

test('6e proxy: a GET call-guard keeps its query untouched (no actor added)', async () => {
  const f = stubProxyFetch();
  try {
    await call('call-guard', { search: '?hours=24' });
    assert.equal(f.seen[0].url, `${JOBS}/api/call-guard?hours=24`);
  } finally {
    f.restore();
  }
});

// ------------------------------------------------------------ 7. api client

function captureFetch(reply = { reset: 1 }) {
  const calls = [];
  const real = globalThis.fetch;
  globalThis.fetch = async (url, init = {}) => {
    calls.push({ url: String(url), method: init.method || 'GET' });
    return { ok: true, status: 200, text: async () => JSON.stringify(reply) };
  };
  return { calls, restore: () => { globalThis.fetch = real; } };
}

test('7 api.resetCallGuard / api.callGuard put the right URL and verb on the wire, no actor', async () => {
  const f = captureFetch();
  try {
    await api.resetCallGuard({ project: 'p a', stage: 'review', fp: 'x/y', reason: 'r' });
    assert.equal(f.calls[0].method, 'DELETE');
    assert.equal(f.calls[0].url, '/api/coord/call-guard?project=p+a&stage=review&fp=x%2Fy&reason=r');
    assert.equal(f.calls[0].url.includes('actor'), false);
    await api.callGuard();
    assert.equal(f.calls[1].url, '/api/coord/call-guard?hours=24');
    assert.equal(f.calls[1].method, 'GET');
  } finally {
    f.restore();
  }
});

// ------------------------------------------------------------ 7b. the RESET action

const target = { project: 'project-5', stage: 'review', fp: 'abc', key: 'project-5|review|abc' };

function actionHarness({ confirmAnswer = true, reason = 'loop', reset }) {
  const log = { resets: [], msgs: [], reloads: 0, pending: [] };
  const confirm = async (opts) => {
    // The body is a form function; the test types into the value object it was given.
    log.opts = opts;
    if (opts.form) opts.form.reason = reason;
    return confirmAnswer;
  };
  const act = makeResetAction({
    confirm,
    reset: reset || (async (args) => { log.resets.push(args); return { reset: 3 }; }),
    reload: () => { log.reloads++; },
    onMsg: (m) => log.msgs.push(m),
    onPending: (k) => log.pending.push(k),
  });
  return { act, log };
}

test('7b RESET: cancel sends nothing; confirm sends the reason and reports the worker count', async () => {
  const cancel = actionHarness({ confirmAnswer: false });
  await cancel.act(target);
  assert.equal(cancel.log.resets.length, 0);
  assert.equal(cancel.log.msgs.length, 0);
  assert.equal(cancel.log.opts.tone, 'danger');
  assert.equal(cancel.log.opts.confirmBlocked, true, 'confirm starts blocked on a blank reason');

  const ok = actionHarness({});
  await ok.act(target);
  assert.deepEqual(ok.log.resets, [{ project: 'project-5', stage: 'review', fp: 'abc', reason: 'loop' }]);
  assert.deepEqual(ok.log.msgs, [{ ok: true, text: 'reset 3 paid row(s) for project-5/review' }]);
  assert.equal(ok.log.reloads, 1);
  assert.deepEqual(ok.log.pending, [target.key, null]);
});

test('7c RESET: a blank reason never sends; a failure is shown as a failure, never success', async () => {
  const blank = actionHarness({ reason: '   ' });
  await blank.act(target);
  assert.equal(blank.log.resets.length, 0);
  assert.equal(blank.log.msgs[0].ok, false);

  const err = actionHarness({ reset: async () => { throw new Error('http_503'); } });
  await err.act(target);
  assert.equal(err.log.msgs.length, 1);
  assert.equal(err.log.msgs[0].ok, false);
  assert.match(err.log.msgs[0].text, /http_503/);
  assert.equal(err.log.reloads, 0);
  assert.deepEqual(err.log.pending, [target.key, null], 'pending clears on failure too');

  const nocount = actionHarness({ reset: async () => ({ ok: true }) });
  await nocount.act(target);
  assert.equal(nocount.log.msgs[0].ok, false, 'a 200 without a reset count is not claimed as a reset');
});

test('7d RESET: a second click while the first is in flight sends nothing', async () => {
  let release;
  const sent = [];
  const h1 = actionHarness({ reset: (a) => { sent.push(a); return new Promise((r) => { release = r; }); } });
  const first = h1.act(target);
  await new Promise((r) => setImmediate(r));
  await h1.act(target);
  release({ reset: 1 });
  await first;
  assert.equal(sent.length, 1);
});

// ------------------------------------------------------------ 8. the view

const loaded = (data) => ({ data, error: null, loading: false, reload: () => {} });

const fixture = {
  settings: loaded(settingsWith('1')),
  flags: loaded({ flags: [flagRow('paused-project-5', RATE), flagRow('paused-project-1', 'cost review')] }),
  guard: loaded({ rows: [guardRow('hot', 3, 2), guardRow('cold', 1, 0), guardRow('warm', 2, 0, { project: 'project-3' })] }),
};

const view = (props) => render(h(CostBreakerView, { onReset: () => {}, pending: null, msg: null, ...props }));

test('8 CostBreakerView renders state, trips, CAP HIT on refused rows only, a RESET per guard row', () => {
  const out = view(fixture);
  assert.ok(out.includes('COST BREAKER'));
  assert.match(out, />ON</);
  assert.ok(out.includes('href="/p/project-5"'));
  assert.ok(out.includes('href="/p/project-3"'));
  assert.ok(out.includes('href="/settings/pipeline-health"'), 'links to the Settings lane');
  assert.ok(out.includes('flags/cost-autohalt-off'), 'the hub-local kill switch caveat');
  assert.equal(out.split('CAP HIT').length - 1, 1);
  assert.equal((out.match(/<button[^>]*>RESET<\/button>/g) || []).length, 3);
  assert.ok(out.includes('aria-sort'));
  assert.ok(out.includes(RATE));
  assert.ok(!out.includes('cost review'), 'an operator pause is not a breaker trip');
});

test('8b empty states, unloaded settings and a failed flags read', () => {
  const empty = view({
    ...fixture, flags: loaded({ flags: [] }), guard: loaded({ rows: [] })
  });
  assert.ok(empty.includes('no guarded calls in the last 24h'));
  assert.ok(empty.includes('no project is paused by the breaker'));

  const unknown = view({ ...fixture, settings: { data: null, error: new Error('http_500'), loading: false } });
  assert.match(unknown, />UNKNOWN</);
  assert.doesNotMatch(unknown, />ON</);

  const off = view({ ...fixture, settings: loaded(settingsWith('0')) });
  assert.match(off, />OFF</);

  const failed = view({ ...fixture, flags: { data: null, error: new Error('http_502'), loading: false } });
  assert.ok(failed.includes('http_502'));
  assert.ok(!failed.includes('no project is paused by the breaker'));

  const capped = view({ ...fixture, guard: loaded({ rows: Array.from({ length: 200 }, (_, i) => guardRow(`f${i}`, 1, 0)) }) });
  assert.ok(capped.includes('first 200 keys'));
});

test('8d BH-5526: a spend-hold row renders as a HOLD trip beside a legacy PAUSE, under a sortable KIND header', () => {
  const out = view({
    ...fixture,
    flags: loaded({ flags: [flagRow('spend-hold-project-9', RATE), flagRow('paused-project-5', RATE)] })
  });
  assert.ok(out.includes('href="/p/project-9"'), 'the held project links to its page');
  assert.match(out, />HOLD</);
  assert.match(out, />PAUSE</);
  assert.match(out, /<th[^>]*aria-sort[^>]*>[\s\S]*?KIND/, 'KIND is a sortable header');
  const empty = view({ ...fixture, flags: loaded({ flags: [] }) });
  assert.match(empty, /Only spend-hold-(&lt;|<)project(&gt;|>) rows/, 'the empty note names the hold rows');
});

test('8c the RESET form starts on its reason input', () => {
  const out = render(h(ResetForm, { row: target, value: { reason: '' }, onBlocked: () => {} }));
  const firstField = out.search(/<(input|select|textarea|button)\b/);
  assert.ok(firstField !== -1);
  assert.ok(out.slice(firstField).startsWith('<input'));
});

// ------------------------------------------------------------ 9. mount

test('9 Costs.js mounts the section', () => {
  const src = readFileSync(new URL('../src/screens/Costs.js', import.meta.url), 'utf8');
  assert.notEqual(src.indexOf("import { CostBreakerSection } from './CostBreaker.js'"), -1);
  assert.notEqual(src.indexOf('<${CostBreakerSection}/>'), -1);
});
