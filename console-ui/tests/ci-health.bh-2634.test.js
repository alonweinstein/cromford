import test from 'node:test';
import assert from 'node:assert/strict';
import { render } from 'preact-render-to-string';
import { h } from 'preact';
import { api } from '../src/api.js';
import { onRequest } from '../functions/api/coord/[[path]].js';
import { ROUTES, NAV } from '../src/app.js';
import { Modal } from '../src/ui/Modal.js';
import {
  ciHealthRows, flakeRows, quarantineFormState, makeQuarantineAction, sinceDay,
  FLAKES_LIMIT, FLAKE_WINDOW_DAYS
} from '../src/lib/ci-health.js';
import { CiHealthScreen, CiHealthView, QuarantineForm } from '../src/screens/CiHealth.js';

// BH-2634 (BH-2517.3): the /ci screen. Three reads (ci-health, flakes,
// quarantine), the quarantine change history, and one audited write (PUT
// metrics/flakes/quarantine through the coord proxy, actor stamped there).

const JOBS = 'https://harness-jobs.operator.workers.dev';
const SECRET = 'test-harness-secret';
const BH = 'example-org/cromford';
const TS = 'example-org/project-5';

const flake = (repo, test, head, kind = 'flake', day = '2026-09-25', workflow = 'harness-ci') =>
  ({ repo, workflow, test, head, kind, day, created_at: `${day}T10:00:00Z` });
const qrow = (repo, test, active = 1) =>
  ({ repo, test, active, actor: 'console', reason: 'flaky on arm', updated_at: '2026-09-24T09:00:00Z' });
const hrow = (repo, metric, payload) => ({ repo, metric, payload, box: 'hub', as_of: '2026-09-26T10:00:00Z' });

// ------------------------------------------------------------ 1. null, never 0

test('1 ciHealthRows: absent / unread / unreadable are null with their state, never 0', () => {
  const health = { rows: [
    hrow(BH, 'minutes', { unread: true }),
    hrow(BH, 'runners', { unreadable: true }),
    hrow(TS, 'minutes', { est_24h: 12.5, note: '', day_max: 3, runner_match: 1, at: 't' }),
    hrow(TS, 'runners', { label: 'fly', total: 3, online: 2, idle: 1, busy: 1, offline: 1, rc: 0 }),
    hrow('example-org/project-3', 'runners', { online: 'x', total: 3 }),
  ] };
  const { rows } = ciHealthRows(health, { flakes: [] }, { rows: [] });
  const by = Object.fromEntries(rows.map((r) => [r.repo, r]));
  assert.equal(by[BH].minutes24h, null);
  assert.equal(by[BH].minutesState, 'unread');
  assert.equal(by[BH].runners, null);
  assert.equal(by[BH].runnersState, 'unread');
  assert.equal(by[TS].minutes24h, 12.5);
  assert.equal(by[TS].minutesState, 'ok');
  assert.deepEqual(by[TS].runners, { online: 2, total: 3 });
  assert.equal(by[TS].runnersState, 'ok');
  assert.equal(by['example-org/project-3'].minutes24h, null);
  assert.equal(by['example-org/project-3'].minutesState, 'absent', 'no minutes row pushed');
  assert.equal(by['example-org/project-3'].runners, null);
  assert.equal(by['example-org/project-3'].runnersState, 'unread', 'a non-numeric online is unread');
  // Health read failed: every row unread, never absent, never 0.
  const failed = ciHealthRows(null, { flakes: [flake(BH, 't1', 'a')] }, { rows: [] });
  assert.equal(failed.rows[0].minutesState, 'unread');
  assert.equal(failed.rows[0].runnersState, 'unread');
  assert.equal(failed.rows[0].minutes24h, null);
  for (const r of [...rows, ...failed.rows]) {
    for (const k of ['minutes24h', 'runners']) assert.notEqual(r[k], 0, `${r.repo}.${k}`);
  }
});

// ------------------------------------------------------------ 2. distinct heads

test('2 ciHealthRows: flakes / reds / flake rate are counted in distinct heads', () => {
  const flakes = { flakes: [
    flake(BH, 't1', 'A'), flake(BH, 't2', 'A'), flake(BH, 't1', 'A', 'flake', '2026-09-25', 'other-wf'),
    flake(BH, 't1', 'B'), flake(BH, 'job:build', 'B', 'red'), flake(BH, 'job:build', 'C', 'red'),
  ] };
  const [r] = ciHealthRows({ rows: [] }, flakes, { rows: [] }).rows;
  assert.equal(r.flakes7d, 2);
  assert.equal(r.reds7d, 2);
  assert.equal(r.flakeRate, 2 / 3);
  // A repo with no flake rows at all: rate null, not 0/0.
  const [q] = ciHealthRows({ rows: [hrow(TS, 'minutes', { est_24h: 1 })] }, { flakes: [] }, { rows: [] }).rows;
  assert.equal(q.flakes7d, 0);
  assert.equal(q.flakeRate, null);
  // Flakes read failed: all three null.
  const [f] = ciHealthRows({ rows: [hrow(TS, 'minutes', { est_24h: 1 })] }, null, { rows: [] }).rows;
  assert.equal(f.flakes7d, null);
  assert.equal(f.reds7d, null);
  assert.equal(f.flakeRate, null);
});

// ------------------------------------------------------------ 3. union, capped

test('3 ciHealthRows: a repo only in quarantine gets a row; capped at the worker limit', () => {
  const { rows, capped } = ciHealthRows({ rows: [] }, { flakes: [] }, { rows: [qrow('example-org/lonely', 'x'), qrow('example-org/lonely', 'y', 0)] });
  assert.deepEqual(rows.map((r) => r.repo), ['example-org/lonely']);
  assert.equal(rows[0].quarantined, 1, 'only active rows count');
  assert.equal(capped, false);
  assert.equal(FLAKES_LIMIT, 2000);
  assert.equal(FLAKE_WINDOW_DAYS, 7);
  const many = { flakes: Array.from({ length: FLAKES_LIMIT }, (_, i) => flake(BH, 't', `h${i}`)) };
  assert.equal(ciHealthRows(null, many, null).capped, true);
  assert.equal(ciHealthRows(null, { flakes: many.flakes.slice(1) }, null).capped, false);
  // Quarantine read failed: null, not 0.
  assert.equal(ciHealthRows(null, many, null).rows[0].quarantined, null);
  assert.equal(sinceDay(Date.parse('2026-09-26T23:00:00Z'), 7), '2026-09-19');
});

// ------------------------------------------------------------ 4. flakeRows

test('4 flakeRows: per test, distinct flaky heads, last day, toggleable only for real tests with a known state', () => {
  const flakes = { flakes: [
    flake(BH, 't1', 'A', 'flake', '2026-09-20'), flake(BH, 't1', 'A', 'flake', '2026-09-22', 'wf2'),
    flake(BH, 't1', 'B', 'flake', '2026-09-24'), flake(BH, 'job:build', 'C'), flake(BH, 'workflow:.github/x.yml', 'D'),
    flake(BH, 'red-only', 'E', 'red'), flake(TS, 't1', 'Z'),
  ] };
  const quarantine = { rows: [qrow(BH, 'old-flake'), qrow(TS, 't1')] };
  const { rows } = flakeRows(flakes, quarantine, BH);
  const by = Object.fromEntries(rows.map((r) => [r.test, r]));
  assert.deepEqual(Object.keys(by).sort(), ['job:build', 'old-flake', 't1', 'workflow:.github/x.yml']);
  assert.equal(by.t1.flakyHeads, 2);
  assert.equal(by.t1.lastDay, '2026-09-24');
  assert.equal(by.t1.quarantined, false);
  assert.equal(by.t1.toggleable, true);
  assert.equal(by['job:build'].toggleable, false);
  assert.equal(by['workflow:.github/x.yml'].toggleable, false);
  assert.equal(by['old-flake'].flakyHeads, 0);
  assert.equal(by['old-flake'].quarantined, true);
  assert.equal(by['old-flake'].toggleable, true);
  // Quarantine read failed: state unknown, nothing is toggleable.
  const unknown = flakeRows(flakes, null, BH).rows;
  assert.ok(unknown.length > 0);
  for (const r of unknown) {
    assert.equal(r.quarantined, null);
    assert.equal(r.toggleable, false);
  }
  assert.equal(flakeRows(null, quarantine, BH), null, 'flakes read failed is not "no flaky tests"');
});

// ------------------------------------------------------------ 5. form

test('5 quarantineFormState: a blank reason blocks', () => {
  for (const reason of ['', '   ', undefined, null]) assert.equal(quarantineFormState({ reason }).blocked, true, JSON.stringify(reason));
  assert.equal(quarantineFormState({ reason: 'flaky on arm' }).blocked, false);
  assert.equal(quarantineFormState({ reason: 'x' }).hint, '');
});

// ------------------------------------------------------------ 6. the toggle action

const t1 = { test: 't1', flakyHeads: 2, lastDay: '2026-09-24', quarantined: false, toggleable: true };

function actionHarness({ confirmAnswer = true, reason = '  flaky on arm  ', put }) {
  const log = { puts: [], msgs: [], reloads: 0, pending: [] };
  const act = makeQuarantineAction({
    confirm: async (opts) => { log.opts = opts; if (opts.form) opts.form.reason = reason; return confirmAnswer; },
    put: put || (async (b) => { log.puts.push(b); return { ok: true }; }),
    reload: () => { log.reloads++; },
    onMsg: (m) => log.msgs.push(m),
    onPending: (k) => log.pending.push(k),
  });
  return { act, log };
}

test('6 toggle: cancel sends nothing; good sends exactly {repo,test,active,reason}; only ok:true is success', async () => {
  const cancel = actionHarness({ confirmAnswer: false });
  await cancel.act(BH, t1);
  assert.equal(cancel.log.puts.length, 0);
  assert.equal(cancel.log.msgs.length, 0);
  assert.equal(cancel.log.opts.confirmBlocked, true, 'confirm starts blocked');

  const good = actionHarness({});
  await good.act(BH, t1);
  assert.equal(good.log.puts.length, 1);
  assert.deepEqual(Object.keys(good.log.puts[0]), ['repo', 'test', 'active', 'reason']);
  assert.deepEqual(good.log.puts[0], { repo: BH, test: 't1', active: 1, reason: 'flaky on arm' });
  assert.equal(good.log.msgs[0].ok, true);
  assert.equal(good.log.reloads, 1);

  const off = actionHarness({});
  await off.act(BH, { ...t1, quarantined: true });
  assert.equal(off.log.puts[0].active, 0);

  const blank = actionHarness({ reason: '   ' });
  await blank.act(BH, t1);
  assert.equal(blank.log.puts.length, 0);
  assert.equal(blank.log.msgs[0].ok, false);

  const noOk = actionHarness({ put: async () => ({ upserted: 1 }) });
  await noOk.act(BH, t1);
  assert.equal(noOk.log.msgs[0].ok, false, 'an answer without ok:true is not success');
  assert.equal(noOk.log.reloads, 0);

  const thrown = actionHarness({ put: async () => { throw new Error('http_409'); } });
  await thrown.act(BH, t1);
  assert.equal(thrown.log.msgs[0].ok, false);
  assert.match(thrown.log.msgs[0].text, /failed — http_409/);
  assert.equal(thrown.log.reloads, 0);
  assert.deepEqual(thrown.log.pending, [`${BH}|t1`, null]);
});

test('6b toggle: a job: row, an unknown state and a second click in flight send nothing', async () => {
  for (const row of [{ ...t1, test: 'job:build', toggleable: false }, { ...t1, quarantined: null, toggleable: false }]) {
    const hx = actionHarness({});
    await hx.act(BH, row);
    assert.equal(hx.log.puts.length, 0, row.test);
    assert.equal(hx.log.opts, undefined, 'no modal either');
  }
  let release;
  const sent = [];
  const hx = actionHarness({ put: (b) => { sent.push(b); return new Promise((r) => { release = r; }); } });
  const first = hx.act(BH, t1);
  await new Promise((r) => setImmediate(r));
  await hx.act(BH, t1);
  release({ ok: true });
  await first;
  assert.equal(sent.length, 1);
});

// ------------------------------------------------------------ 7. api helpers

function captureFetch(reply = { ok: true }) {
  const calls = [];
  const real = globalThis.fetch;
  globalThis.fetch = async (url, init = {}) => {
    calls.push({ url: String(url), method: init.method || 'GET', body: init.body });
    return { ok: true, status: 200, text: async () => JSON.stringify(reply) };
  };
  return { calls, restore: () => { globalThis.fetch = real; } };
}

test('7 api helpers hit the exact URLs; the PUT body carries no actor', async () => {
  const f = captureFetch();
  try {
    await api.ciHealth();
    await api.ciHealth('example-org/x');
    await api.flakes('example-org/x', '2026-09-19');
    await api.flakes(null, '2026-09-19');
    await api.flakeQuarantine();
    await api.flakeQuarantine('example-org/x');
    await api.flakeQuarantineChanges('r', 't a');
    await api.putFlakeQuarantine({ repo: 'r', test: 't', active: 1, reason: 'why', actor: 'mallory' });
    assert.deepEqual(f.calls.map((c) => c.url), [
      '/api/coord/ci-health',
      '/api/coord/ci-health?repo=example-org%2Fx',
      '/api/coord/metrics/flakes?repo=example-org%2Fx&since=2026-09-19&limit=2000',
      '/api/coord/metrics/flakes?since=2026-09-19&limit=2000',
      '/api/coord/metrics/flakes/quarantine?active=1',
      '/api/coord/metrics/flakes/quarantine?repo=example-org%2Fx&active=1',
      '/api/coord/metrics/flakes/quarantine/changes?repo=r&test=t+a&limit=50',
      '/api/coord/metrics/flakes/quarantine',
    ]);
    assert.deepEqual(f.calls.slice(0, 7).map((c) => c.method), Array(7).fill('GET'));
    const put = f.calls[7];
    assert.equal(put.method, 'PUT');
    assert.deepEqual(Object.keys(JSON.parse(put.body)), ['repo', 'test', 'active', 'reason']);
    assert.deepEqual(JSON.parse(put.body), { repo: 'r', test: 't', active: 1, reason: 'why' });
  } finally {
    f.restore();
  }
});

// ------------------------------------------------------------ 8. proxy

function stubProxyFetch() {
  const seen = [];
  const real = globalThis.fetch;
  globalThis.fetch = async (input, init = {}) => {
    const target = typeof input === 'string' ? input : input.url;
    if (target.startsWith('https://harness-console.operator.workers.dev')) return new Response('', { status: 200 });
    seen.push({ url: target, method: init.method, body: init.body });
    return new Response(JSON.stringify({ ok: true }), { status: 200, headers: { 'content-type': 'application/json' } });
  };
  return { seen, restore: () => { globalThis.fetch = real; } };
}

let seq = 0;
const call = (rest, { method = 'GET', body } = {}) =>
  onRequest({
    request: new Request(`https://console.example.pages.dev/api/coord/${rest}`, {
      method, headers: { cookie: `dash=ci${++seq}`, 'content-type': 'application/json' }, body
    }),
    env: { HARNESS_SECRET: SECRET },
    params: { path: rest.split('/').filter(Boolean) }
  });

test('8 proxy: the quarantine PUT forwards the four fields with actor stamped console', async () => {
  const f = stubProxyFetch();
  try {
    const res = await call('metrics/flakes/quarantine', {
      method: 'PUT', body: JSON.stringify({ repo: BH, test: 't1', active: 1, reason: 'why', actor: 'forged', smuggled: 1 })
    });
    assert.equal(res.status, 200);
    assert.equal(f.seen.length, 1);
    assert.equal(f.seen[0].url, `${JOBS}/api/metrics/flakes/quarantine`);
    assert.equal(f.seen[0].method, 'PUT');
    assert.deepEqual(JSON.parse(f.seen[0].body), { repo: BH, test: 't1', active: 1, reason: 'why', actor: 'console' });
  } finally {
    f.restore();
  }
});

test('8b proxy: the ledger PUT and the changes path stay refused with zero forwards', async () => {
  for (const [rest, method] of [
    ['metrics/flakes', 'PUT'], ['metrics/flakes/quarantine/changes', 'PUT'],
    ['metrics/flakes/quarantine', 'POST'], ['metrics/flakes/quarantine', 'DELETE']
  ]) {
    const f = stubProxyFetch();
    try {
      const res = await call(rest, { method, body: method === 'DELETE' ? undefined : JSON.stringify({ repo: 'r', test: 't', active: 1, reason: 'x' }) });
      assert.ok(res.status >= 400, `${method} /${rest} answered ${res.status}`);
      assert.equal(f.seen.length, 0, `${method} /${rest} reached the jobs worker`);
    } finally {
      f.restore();
    }
  }
});

// ------------------------------------------------------------ 9. the view

const loaded = (data) => ({ data, error: null, loading: false, reload: () => {} });
const failed = (msg) => ({ data: null, error: new Error(msg), loading: false, reload: () => {} });

const fleet = {
  health: loaded({ rows: [hrow(BH, 'minutes', { est_24h: 42 }), hrow(BH, 'runners', { online: 2, total: 3 })] }),
  flakes: loaded({ flakes: [flake(BH, 't1', 'A'), flake(BH, 'job:build', 'B'), flake(TS, 't9', 'C')] }),
  quarantine: loaded({ rows: [qrow(BH, 'old-flake')] }),
};
const view = (props) => render(h(CiHealthView, { onToggle: () => {}, onOpen: () => {}, pending: null, msg: null, ...fleet, ...props }));
const headers = (out) => (out.match(/<th\b[^>]*>/g) || []);

test('9 repos table: six sortable headers, repo cells link to /ci?repo=, wrapped for scroll', () => {
  const out = view({});
  const ths = headers(out);
  assert.equal(ths.length, 6);
  for (const th of ths) assert.match(th, /aria-sort="/);
  for (const label of ['REPO', 'MINUTES 24H', 'RUNNERS', 'FLAKES 7D', 'FLAKE RATE', 'QUARANTINED']) assert.ok(out.includes(label), label);
  assert.ok(out.includes('href="/ci?repo=example-org%2Fcromford"'));
  assert.ok(out.includes('href="/ci?repo=example-org%2Fproject-5"'));
  assert.ok(out.includes('class="tablewrap'));
  assert.ok(out.includes('2/3'));
  assert.ok(out.includes('title="not pushed"'), 'project-5 has no minutes row');
});

test('9b flakes table for a repo: sortable, the job: toggle disabled, an open test shows its history', () => {
  const toggled = [];
  const repoProps = {
    repo: BH,
    repoFlakes: loaded({ flakes: [flake(BH, 't1', 'A'), flake(BH, 'job:build', 'B')] }),
    repoQuarantine: loaded({ rows: [qrow(BH, 'old-flake')] }),
    open: 'old-flake',
    history: loaded({ changes: [
      { id: 2, repo: BH, test: 'old-flake', before_active: 0, after_active: 1, actor: 'operator@example.com', reason: 'flaky on arm', at: '2026-09-24T09:00:00Z' },
      { id: 1, repo: BH, test: 'old-flake', before_active: null, after_active: 0, actor: 'console', reason: 'first write', at: '2026-09-20T09:00:00Z' },
    ] }),
    onToggle: (...a) => toggled.push(a),
  };
  const out = view(repoProps);
  assert.ok(out.includes('TEST') && out.includes('FLAKY HEADS') && out.includes('LAST SEEN') && out.includes('QUARANTINE'));
  const ths = headers(out);
  assert.ok(ths.length >= 6 + 4 + 4, `got ${ths.length} headers`);
  for (const th of ths) assert.match(th, /aria-sort="/);
  assert.match(out, /<button[^>]*disabled[^>]*title="[^"]*job:[^"]*"/, 'the job: row toggle is disabled with a reason');
  assert.ok(out.includes('aria-expanded="true"'));
  assert.ok(out.includes('off → on'));
  assert.ok(out.includes('— → off'));
  assert.ok(out.includes('flaky on arm'));
  assert.ok(out.includes('operator@example.com'));

  const none = view({ ...repoProps, repoFlakes: loaded({ flakes: [] }), repoQuarantine: loaded({ rows: [] }), open: null });
  assert.ok(none.includes(`no flaky tests for ${BH} in the last 7 days`));
  const broke = view({ ...repoProps, repoFlakes: failed('http_502'), open: null });
  assert.ok(broke.includes('http_502'));
  assert.ok(!broke.includes('no flaky tests for'));
});

test('9c the toggle button calls the injected handler, never a native dialog', () => {
  const src = CiHealthView.toString() + CiHealthScreen.toString();
  assert.equal(/window\.(confirm|alert|prompt)\s*\(/.test(src), false);
  const out = view({ repo: BH, repoFlakes: loaded({ flakes: [flake(BH, 't1', 'A')] }), repoQuarantine: loaded({ rows: [] }) });
  assert.match(out, /<button[^>]*>ON<\/button>/, 'an OFF test offers ON');
});

// ------------------------------------------------------------ 10. states

test('10 load failure, empty and data render distinctly', () => {
  const allFailed = view({ health: failed('http_503 ci-health'), flakes: failed('http_503 flakes'), quarantine: failed('http_404') });
  assert.ok(allFailed.includes('http_503 ci-health'));
  assert.ok(!allFailed.includes('no CI health pushed yet'));
  const empty = view({ health: loaded({ rows: [] }), flakes: loaded({ flakes: [] }), quarantine: loaded({ rows: [] }) });
  assert.ok(empty.includes('no CI health pushed yet'));
  assert.notEqual(allFailed, empty);
  // Some reads fail: the table still renders, the failures are named, no zeros invented.
  const partial = view({ health: failed('http_404'), quarantine: failed('http_404') });
  assert.ok(partial.includes('href="/ci?repo=example-org%2Fcromford"'));
  assert.match(partial, /minutes and runners unreadable/);
  assert.match(partial, /quarantine unreadable/);
  assert.ok(partial.includes('title="unread"'));
  const capped = view({ flakes: loaded({ flakes: Array.from({ length: FLAKES_LIMIT }, (_, i) => flake(BH, 't', `h${i}`)) }) });
  assert.ok(capped.includes('first 2000 flake rows only'));
  const loading = view({ health: { data: null, error: null, loading: true }, flakes: { data: null, error: null, loading: true }, quarantine: { data: null, error: null, loading: true } });
  assert.ok(loading.includes('class="skel"'));
});

// ------------------------------------------------------------ 11. route + nav

test('11 /ci is routed to CiHealthScreen and reachable from the nav; SETTINGS stays last', () => {
  const route = ROUTES.find(([p]) => p === '/ci');
  assert.ok(route, '/ci missing from ROUTES');
  assert.equal(route[1], CiHealthScreen);
  const tab = NAV.find((n) => n.to === '/ci');
  assert.ok(tab, '/ci missing from NAV');
  assert.equal(tab.label, 'CI');
  assert.equal(typeof tab.icon, 'function');
  assert.equal(tab.match('/ci'), true);
  assert.equal(NAV[NAV.length - 1].to, '/settings');
});

// ------------------------------------------------------------ 12. the modal body

test('12 the quarantine modal opens on its reason input with confirm disabled', () => {
  const out = render(h(Modal, {
    title: 'QUARANTINE', confirmBlocked: true, onConfirm: () => {}, onCancel: () => {},
    body: ({ setBlocked }) => h(QuarantineForm, { repo: BH, row: t1, next: true, value: { reason: '' }, onBlocked: setBlocked })
  }));
  const bodyAt = out.indexOf('modal__body');
  const firstField = out.slice(bodyAt).search(/<(input|select|textarea|button)\b/);
  assert.ok(firstField !== -1);
  assert.ok(out.slice(bodyAt + firstField).startsWith('<input'));
  assert.match(out, /<button[^>]*disabled[^>]*>CONFIRM<\/button>/);
});
