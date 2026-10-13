import test, { afterEach } from 'node:test';
import assert from 'node:assert/strict';
import { render } from 'preact-render-to-string';
import { h, render as mount } from 'preact';
import { onRequest } from '../functions/api/coord/[[path]].js';
import { api } from '../src/api.js';
import {
  routingState, haltBody, haltDisabledReason, changeCells, haltAction, haltFormState, currentHalt, ROUTING_CHANGES_LIMIT
} from '../src/lib/routing.js';
import { RoutingView, RoutingPanel } from '../src/screens/RoutingPanel.js';
import { flush } from './helpers/settle.js';

// BH-2328: the ROUTING section of /p/<project>. The payloads are the worker's
// own answers in worker/jobs/src/routes/routing.js (GET /api/routing/<p>,
// GET /api/routing-changes, PUT /api/routing) and settings.js
// (GET /api/settings/<key> -> {key, setting, source}).

const JOBS = 'https://harness-jobs.operator.workers.dev';
const SECRET = 'test-harness-secret';

const ROW = { project: 'project-3', builder: 'pool', pool_app: 'bh-pool-project-3', halted: 1, updated_at: '2026-09-25T10:00:00Z' };
const KNOB_ON = { key: 'routing_rows', setting: { key: 'routing_rows', value: 'on' }, source: 'settings' };
const KNOB_OFF = { key: 'routing_rows', setting: { key: 'routing_rows', value: 'off' }, source: 'settings' };
const KNOB_NONE = { key: 'routing_rows', setting: null, source: 'none' };
const CHANGES = {
  changes: [
    { id: 3, project: 'project-3', before_builder: 'pool', before_pool_app: 'bh-pool-project-3', before_halted: 0,
      after_builder: 'pool', after_pool_app: 'bh-pool-project-3', after_halted: 1, actor: 'console', reason: 'drill', at: '2026-09-25T10:00:00Z' },
    { id: 1, project: 'project-3', before_builder: null, before_pool_app: null, before_halted: null,
      after_builder: 'local', after_pool_app: null, after_halted: 0, actor: 'seed', reason: null, at: '2026-09-20T08:00:00Z' },
    { id: 2, project: 'project-3', before_builder: 'local', before_pool_app: null, before_halted: 0,
      after_builder: 'pool', after_pool_app: 'bh-pool-project-3', after_halted: 0, actor: 'harness-sync', reason: 'deploy', at: '2026-09-22T09:00:00Z' }
  ],
  truncated: false,
  as_of: '2026-09-25T10:05:00Z'
};
const err = (status, message = `http_${status}`) => Object.assign(new Error(message), { status });

// ---- proxy (the real onRequest) ---------------------------------------------

function stubWorker(status = 200, payload = { routing: ROW }) {
  const seen = [];
  const real = globalThis.fetch;
  globalThis.fetch = async (input, init = {}) => {
    const target = typeof input === 'string' ? input : input.url;
    if (target.startsWith('https://harness-console.operator.workers.dev')) return new Response('', { status: 200 });
    seen.push({ url: target, method: init.method, headers: init.headers || {}, body: init.body });
    return new Response(JSON.stringify(payload), { status, headers: { 'content-type': 'application/json' } });
  };
  return { seen, restore: () => { globalThis.fetch = real; } };
}

let cookieSeq = 0;
const call = (rest, method, body, path = rest.split('/').filter(Boolean)) =>
  onRequest({
    request: new Request(`https://console.example.pages.dev/api/coord/${rest}`, {
      method,
      headers: { cookie: `dash=routing${++cookieSeq}`, 'content-type': 'application/json' },
      body
    }),
    env: { HARNESS_SECRET: SECRET },
    params: { path }
  });

const PUT_BODY = { project: 'project-3', builder: 'pool', pool_app: 'x', halted: 1, reason: 'drill' };

test('P1: PUT routing reaches the jobs worker with the bearer; every other routing write is 405', async () => {
  const f = stubWorker();
  try {
    const res = await call('routing', 'PUT', JSON.stringify(PUT_BODY));
    assert.equal(res.status, 200);
    // Lead fix round: the proxy reads the current row (server-side) before the write.
    assert.equal(f.seen.length, 2);
    assert.equal(f.seen[0].url, `${JOBS}/api/routing/project-3`);
    assert.equal(f.seen[0].method, 'GET');
    assert.equal(f.seen[1].url, `${JOBS}/api/routing`);
    assert.equal(f.seen[1].method, 'PUT');
    assert.equal(f.seen[1].headers.authorization, `Bearer ${SECRET}`);
  } finally { f.restore(); }

  const g = stubWorker();
  try {
    for (const [rest, method, path] of [
      ['routing/project-3', 'PUT'],
      ['routing-changes', 'PUT'],
      ['routing', 'POST'],
      ['routing', 'DELETE'],
      ['routing/', 'PUT', ['routing', '']],
      ['Routing', 'PUT'],
      ['routing', 'PATCH']
    ]) {
      const res = await call(rest, method, JSON.stringify(PUT_BODY), path);
      assert.equal(res.status, 405, `${method} /${rest}`);
      assert.match(await res.text(), /not allowed/, `${method} /${rest}`);
    }
    assert.equal(g.seen.length, 0, 'no refused write reached the worker');
  } finally { g.restore(); }
});

test('P2: the proxy stamps actor console over whatever the browser sent', async () => {
  const f = stubWorker();
  try {
    const sent = { project: 'project-3', halted: 1, reason: 'drill', actor: 'operator' };
    const res = await call('routing', 'PUT', JSON.stringify(sent));
    assert.equal(res.status, 200);
    assert.equal(JSON.parse(f.seen[1].body).actor, 'console');
    // No actor sent at all: it is still the console's.
    await call('routing', 'PUT', JSON.stringify({ project: 'project-3', halted: 1 }));
    assert.equal(JSON.parse(f.seen[3].body).actor, 'console');
  } finally { f.restore(); }
});

// A worker stub that answers by method + path: GET /api/routing/<p> from
// `rows` (absent = 404, a number = that status), PUT /api/routing echoes the
// row the upsert would leave.
function stubRouting(rows) {
  const seen = [];
  const real = globalThis.fetch;
  const reply = (status, body) => new Response(JSON.stringify(body), { status, headers: { 'content-type': 'application/json' } });
  globalThis.fetch = async (input, init = {}) => {
    const target = typeof input === 'string' ? input : input.url;
    if (target.startsWith('https://harness-console.operator.workers.dev')) return new Response('', { status: 200 });
    const method = init.method || 'GET';
    seen.push({ url: target, method, headers: init.headers || {}, body: init.body });
    const path = new URL(target).pathname;
    if (method === 'GET' && path.startsWith('/api/routing/')) {
      const r = rows[decodeURIComponent(path.slice('/api/routing/'.length))];
      if (r === undefined) return reply(404, { error: 'not found' });
      if (typeof r === 'number') return reply(r, { error: `http_${r}` });
      return reply(200, { routing: r });
    }
    if (method === 'PUT' && path === '/api/routing') {
      const b = JSON.parse(init.body);
      return reply(200, { routing: { project: b.project, builder: b.builder, pool_app: b.pool_app ?? null, halted: Number(b.halted) } });
    }
    return reply(599, { error: `unrouted ${method} ${path}` });
  };
  return { seen, restore: () => { globalThis.fetch = real; } };
}

test('P4: the halt-only write never forwards builder, pool_app or any other browser field', async () => {
  const cur = { project: 'project-3', builder: 'local', pool_app: null, halted: 0, updated_at: 't' };
  const f = stubRouting({ 'project-3': cur });
  try {
    const forged = { project: 'project-3', builder: 'pool', pool_app: 'evil-app', halted: 1, reason: ' drill ',
      actor: 'operator', updated_at: 'x', extra: 'y' };
    const res = await call('routing', 'PUT', JSON.stringify(forged));
    assert.equal(res.status, 200);
    assert.deepEqual(f.seen.map((s) => [s.method, s.url]), [
      ['GET', `${JOBS}/api/routing/project-3`],
      ['PUT', `${JOBS}/api/routing`]
    ]);
    assert.equal(f.seen[0].headers.authorization, `Bearer ${SECRET}`);
    // builder and pool_app are the SERVER's current row; only halted moved.
    assert.deepEqual(JSON.parse(f.seen[1].body),
      { project: 'project-3', builder: 'local', pool_app: null, halted: 1, reason: 'drill', expected_updated_at: 't', actor: 'console' });
    const out = await res.json();
    assert.deepEqual({ ...out.routing }, { project: 'project-3', builder: 'local', pool_app: null, halted: 1 });
  } finally { f.restore(); }

  // A pool row keeps its own pool_app, whatever the browser named.
  const pool = { project: 'project-3', builder: 'pool', pool_app: 'bh-pool-project-3', halted: 1 };
  const g = stubRouting({ 'project-3': pool });
  try {
    const res = await call('routing', 'PUT', JSON.stringify({ project: 'project-3', builder: 'fly1', pool_app: 'x', halted: 0, reason: 'fixed' }));
    assert.equal(res.status, 200);
    assert.deepEqual(JSON.parse(g.seen[1].body),
      { project: 'project-3', builder: 'pool', pool_app: 'bh-pool-project-3', halted: 0, reason: 'fixed', actor: 'console' });
  } finally { g.restore(); }
});

test('P5: no row, an unreadable row, a bad project or a bad halted is refused and never written', async () => {
  const f = stubRouting({ broken: 500 });
  try {
    const nothing = await call('routing', 'PUT', JSON.stringify({ project: 'ghost', halted: 1, reason: 'x' }));
    assert.equal(nothing.status, 404, 'a HALT never creates a routing row');
    assert.match(await nothing.text(), /no routing row/);
    const unread = await call('routing', 'PUT', JSON.stringify({ project: 'broken', halted: 1, reason: 'x' }));
    assert.equal(unread.status, 502);
    assert.match(await unread.text(), /could not read the routing row/);
    assert.equal(f.seen.filter((s) => s.method === 'PUT').length, 0);
    const reads = f.seen.length;
    for (const body of [
      { halted: 1, reason: 'x' },
      { project: '', halted: 1, reason: 'x' },
      { project: 7, halted: 1, reason: 'x' },
      { project: 'project-3', reason: 'x' },
      { project: 'project-3', halted: 'yes', reason: 'x' },
      { project: 'project-3', halted: 2, reason: 'x' }
    ]) {
      const res = await call('routing', 'PUT', JSON.stringify(body));
      assert.equal(res.status, 400, JSON.stringify(body));
    }
    assert.equal(f.seen.length, reads, 'a malformed body reaches the worker not even as a read');
  } finally { f.restore(); }
});

test('P6: an UNHALT with a blank or missing reason is 400 and never forwarded', async () => {
  const f = stubRouting({ 'project-3': ROW });
  try {
    for (const body of [
      { project: 'project-3', halted: 0 },
      { project: 'project-3', halted: 0, reason: '   ' },
      { project: 'project-3', halted: false, reason: '' },
      { project: 'project-3', halted: 0, reason: 42 }
    ]) {
      const res = await call('routing', 'PUT', JSON.stringify(body));
      assert.equal(res.status, 400, JSON.stringify(body));
      assert.match(await res.text(), /UNHALT needs a reason/);
    }
    assert.equal(f.seen.length, 0);
    const ok = await call('routing', 'PUT', JSON.stringify({ project: 'project-3', halted: 0, reason: 'lane fixed' }));
    assert.equal(ok.status, 200);
    assert.equal(JSON.parse(f.seen[1].body).reason, 'lane fixed');
  } finally { f.restore(); }
});

test('P3: a PUT routing body that is not a JSON object is 400 and never forwarded', async () => {
  const f = stubWorker();
  try {
    for (const body of ['"x"', '[]', 'not json', 'null']) {
      const res = await call('routing', 'PUT', body);
      assert.equal(res.status, 400, body);
      assert.match(await res.text(), /JSON object/, body);
    }
    assert.equal(f.seen.length, 0);
    // The reads still pass untouched.
    const r = await call('routing/project-3', 'GET');
    assert.equal(r.status, 200);
    assert.equal(f.seen[0].url, `${JOBS}/api/routing/project-3`);
  } finally { f.restore(); }
});

// ---- api client -------------------------------------------------------------

// Answers by URL; `routes` maps a URL prefix to [status, body] or a list of
// them consumed in order (the last repeats).
function fakeFetch(routes) {
  const calls = [];
  const used = {};
  globalThis.fetch = async (url, init = {}) => {
    const u = String(url);
    calls.push({ url: u, method: init.method || 'GET', body: init.body ? JSON.parse(init.body) : undefined });
    const key = Object.keys(routes).filter((k) => u.startsWith(k)).sort((a, b) => b.length - a.length)[0];
    if (!key) return { ok: false, status: 599, text: async () => JSON.stringify({ error: `unrouted ${u}` }) };
    const list = Array.isArray(routes[key][0]) ? routes[key] : [routes[key]];
    const i = Math.min(used[key] || 0, list.length - 1);
    used[key] = (used[key] || 0) + 1;
    const [status, body] = list[i];
    return { ok: status >= 200 && status < 300, status, text: async () => JSON.stringify(body) };
  };
  return calls;
}

test('A1: the api client hits the exact URLs, methods and bodies; a 404 row read carries status 404', async () => {
  const calls = fakeFetch({ '/api/coord/': [200, { ok: true }] });
  await api.routing('a.b');
  await api.routingChanges('p', 50);
  await api.putRouting(PUT_BODY);
  await api.coordSetting('routing_rows');
  assert.deepEqual(calls.map((c) => [c.method, c.url]), [
    ['GET', '/api/coord/routing/a.b'],
    ['GET', '/api/coord/routing-changes?project=p&limit=50'],
    ['PUT', '/api/coord/routing'],
    ['GET', '/api/coord/settings/routing_rows']
  ]);
  assert.deepEqual(calls[2].body, PUT_BODY);
  assert.equal(ROUTING_CHANGES_LIMIT, 50);
  await api.routingChanges('p');
  assert.equal(calls[4].url, '/api/coord/routing-changes?project=p&limit=50');
  await api.routing('we/ird');
  assert.equal(calls[5].url, '/api/coord/routing/we%2Fird');

  fakeFetch({ '/api/coord/routing/': [404, { error: 'not found' }] });
  await assert.rejects(api.routing('nope'), (e) => e.status === 404);
});

// ---- helpers ----------------------------------------------------------------

test('H1: routingState maps row / 404 / 500 and the knob to true / false / null', () => {
  const on = { data: KNOB_ON, error: null };
  assert.deepEqual(routingState({ data: { routing: ROW }, error: null }, on), { kind: 'row', row: ROW, rowsOn: true });
  assert.deepEqual(routingState({ data: null, error: err(404, 'not found') }, on), { kind: 'none', rowsOn: true });
  const e500 = err(500);
  assert.deepEqual(routingState({ data: null, error: e500 }, on), { kind: 'error', error: e500, rowsOn: true });
  // A refresh that failed after an earlier success is an error, never the stale row.
  assert.equal(routingState({ data: { routing: ROW }, error: e500 }, on).kind, 'error');
  assert.equal(routingState({ data: null, error: null }, on).kind, 'loading');
  const row = { data: { routing: ROW }, error: null };
  assert.equal(routingState(row, { data: KNOB_OFF, error: null }).rowsOn, false);
  assert.equal(routingState(row, { data: KNOB_NONE, error: null }).rowsOn, false);
  assert.equal(routingState(row, { data: { key: 'routing_rows', setting: { value: 'ON ' } }, error: null }).rowsOn, false);
  assert.equal(routingState(row, { data: null, error: err(503) }).rowsOn, null);
  assert.equal(routingState(row, { data: KNOB_ON, error: err(503) }).rowsOn, null);
  assert.equal(routingState(row, { data: null, error: null }).rowsOn, null);
  assert.equal(routingState(row, { data: { ok: true }, error: null }).rowsOn, null, 'a malformed knob answer is unknown');
});

test('H2/H5: haltBody carries only project, halted and reason; a blank HALT reason defaults, an UNHALT one does not', () => {
  const fresh = { project: 'project-3', builder: 'pool', pool_app: 'x', halted: 0, updated_at: 't', actor: 'x' };
  assert.deepEqual(haltBody(fresh, true, '  '), { project: 'project-3', halted: 1, reason: 'HALT from Mission Control' });
  assert.deepEqual(haltBody({ ...fresh, halted: 1 }, false, ' lane fixed '), { project: 'project-3', halted: 0, reason: 'lane fixed' });
  assert.deepEqual(haltBody({ ...fresh, halted: 1 }, false, ''), { project: 'project-3', halted: 0, reason: '' });
  assert.equal(haltBody(fresh, true, undefined).reason, 'HALT from Mission Control');
  assert.equal(haltBody(fresh, true, '  stuck lane  ').reason, 'stuck lane');
});

test('H7: haltFormState blocks only an UNHALT with a blank reason', () => {
  assert.equal(haltFormState(true, '').blocked, false);
  assert.equal(haltFormState(false, '').blocked, true);
  assert.equal(haltFormState(false, '   ').blocked, true);
  assert.equal(haltFormState(false, undefined).blocked, true);
  assert.equal(haltFormState(false, 'lane fixed').blocked, false);
  assert.match(haltFormState(false, '').hint, /reason/);
});

test('H8: currentHalt is the newest change that SET halted, or null when the log does not hold it', () => {
  assert.deepEqual(currentHalt({ data: CHANGES, error: null }),
    { found: true, actor: 'console', reason: 'drill', at: '2026-09-25T10:00:00Z' });
  // A later write that kept halted=1 (a builder move) is not the halt.
  const moved = { ...CHANGES, changes: [
    { id: 9, before_builder: 'pool', before_halted: 1, after_builder: 'local', after_halted: 1, actor: 'seed', reason: 'move', at: 't9' },
    ...CHANGES.changes] };
  assert.equal(currentHalt({ data: moved, error: null }).reason, 'drill');
  // A row CREATED halted is its own halt.
  const born = { changes: [{ id: 1, before_builder: null, before_halted: null, after_halted: 1, actor: 'seed', reason: null, at: 't1' }] };
  assert.deepEqual(currentHalt({ data: born, error: null }), { found: true, actor: 'seed', reason: null, at: 't1' });
  assert.deepEqual(currentHalt({ data: { changes: [CHANGES.changes[1]] }, error: null }), { found: false, why: 'not in the newest 50 changes' });
  assert.deepEqual(currentHalt({ data: null, error: err(500) }), { found: false, why: 'the change log could not be read' });
  assert.deepEqual(currentHalt({ data: null, error: null }), { found: false, why: 'the change log is still loading' });
});

test('H3: haltDisabledReason is null only for a row with routing_rows on', () => {
  assert.equal(haltDisabledReason({ kind: 'row', row: ROW, rowsOn: true }), null);
  assert.equal(haltDisabledReason({ kind: 'none', rowsOn: true }),
    'no routing row for this project; seed it with routing-seed-rows.sh --apply');
  assert.equal(haltDisabledReason({ kind: 'row', row: ROW, rowsOn: false }),
    'routing_rows is off: rows do not drive flags/ yet, so a HALT here would stop nothing');
  assert.equal(haltDisabledReason({ kind: 'row', row: ROW, rowsOn: null }), 'could not read routing_rows');
  assert.equal(haltDisabledReason({ kind: 'error', error: err(500), rowsOn: true }), 'routing could not be read');
  assert.equal(haltDisabledReason({ kind: 'loading', rowsOn: null }), 'routing is loading');
});

test('H4: changeCells renders transitions, (new) on a first write and — for a null pool_app', () => {
  const first = changeCells(CHANGES.changes[1]);
  assert.equal(first.builder, '(new) → local');
  assert.equal(first.pool_app, '(new) → —');
  assert.equal(first.halted, '(new) → 0');
  assert.equal(first.reason, '—');
  const halt = changeCells(CHANGES.changes[0]);
  assert.equal(halt.halted, '0 → 1');
  assert.equal(halt.builder, 'pool', 'an unchanged field is its value, not pool → pool');
  assert.equal(halt.actor, 'console');
  assert.equal(halt.reason, 'drill');
  const move = changeCells(CHANGES.changes[2]);
  assert.equal(move.builder, 'local → pool');
  assert.equal(move.pool_app, '— → bh-pool-project-3');
  assert.equal(move.halted, '0');
});

// ---- rendered view ----------------------------------------------------------

const noop = () => {};
const viewProps = (over = {}) => ({
  project: 'project-3',
  state: { kind: 'row', row: ROW, rowsOn: true },
  changes: { data: CHANGES, error: null },
  busy: false, msg: null, onHalt: noop, onRetryRow: noop, onRetryChanges: noop, onDismiss: noop,
  ...over
});
const toggleTag = (out) => (out.match(/<button[^>]*aria-label="HALT"[^>]*>/) || [])[0] || '';

test('R1: a halted pool row with rows on renders its values and a live pressed toggle', () => {
  const out = render(h(RoutingView, viewProps()));
  assert.match(out, /BUILDER<\/span>\s*<span class="kv__val">pool</);
  assert.match(out, /POOL APP<\/span>\s*<span class="kv__val">bh-pool-project-3</);
  assert.match(out, /class="tag tag--warn">HALTED</);
  assert.match(out, /ROWS DRIVE ROUTING<\/span>\s*<span class="kv__val">on</);
  const t = toggleTag(out);
  assert.match(t, /aria-pressed="true"/);
  assert.doesNotMatch(t, /disabled/);
});

test('R2/H6: an unhalted local row shows no HALTED tag and — for pool app; unknown knob is never "off"', () => {
  const local = { ...ROW, builder: 'local', pool_app: null, halted: 0 };
  const out = render(h(RoutingView, viewProps({ state: { kind: 'row', row: local, rowsOn: null } })));
  assert.doesNotMatch(out, /tag--warn">HALTED</);
  assert.match(out, /HALTED<\/span>\s*<span class="kv__val">no</);
  assert.match(out, /POOL APP<\/span>\s*<span class="kv__val">—</);
  assert.match(out, /ROWS DRIVE ROUTING<\/span>\s*<span class="kv__val">unknown</);
  assert.doesNotMatch(out, /ROWS DRIVE ROUTING<\/span>\s*<span class="kv__val">off/);
  assert.match(toggleTag(out), /aria-pressed="false"/);
  assert.match(toggleTag(out), /disabled/);
  assert.match(out, /could not read routing_rows/);
});

test('R3: the change log is a sortable table, newest first', () => {
  const out = render(h(RoutingView, viewProps()));
  assert.match(out, /tablewrap tablewrap--wide/);
  const ths = out.match(/<th[^>]*aria-sort="[a-z]+"/g) || [];
  assert.equal(ths.length, 6, `six sortable headers, got ${ths.length}`);
  assert.match(out, /aria-sort="descending"[^>]*>\s*<button[^>]*>\s*AT\b/);
  const i3 = out.indexOf('>drill<');
  const i2 = out.indexOf('>deploy<');
  const i1 = out.indexOf('(new) → local');
  assert.ok(i3 > 0 && i2 > i3 && i1 > i2, `newest first: ${i3} ${i2} ${i1}`);
});

test('R4: truncation note, empty copy, load error, and each disabled sentence', () => {
  const trunc = render(h(RoutingView, viewProps({ changes: { data: { ...CHANGES, truncated: true }, error: null } })));
  assert.match(trunc, /newest 50 shown; older changes exist/);
  const empty = render(h(RoutingView, viewProps({ changes: { data: { changes: [], truncated: false }, error: null } })));
  assert.match(empty, /no routing changes recorded for project-3/);
  assert.doesNotMatch(empty, /could not load/);
  const failed = render(h(RoutingView, viewProps({ changes: { data: null, error: err(500, 'boom') } })));
  assert.match(failed, /could not load/);
  assert.doesNotMatch(failed, /no routing changes recorded/);

  const none = render(h(RoutingView, viewProps({ state: { kind: 'none', rowsOn: true } })));
  assert.match(none, /no routing row/);
  assert.match(toggleTag(none), /disabled/);
  assert.match(none, /seed it with routing-seed-rows.sh --apply/);
  // A deleted row's history is still history.
  assert.match(none, />drill</);

  const off = render(h(RoutingView, viewProps({ state: { kind: 'row', row: ROW, rowsOn: false } })));
  assert.match(toggleTag(off), /disabled/);
  assert.match(off, /routing_rows is off: rows do not drive flags\/ yet, so a HALT here would stop nothing/);
  assert.match(off, /ROWS DRIVE ROUTING<\/span>\s*<span class="kv__val">off</);

  const rowErr = render(h(RoutingView, viewProps({ state: { kind: 'error', error: err(500, 'boom'), rowsOn: true } })));
  assert.match(rowErr, /could not load/);
  assert.doesNotMatch(rowErr, /not halted|>running</i);
  assert.match(toggleTag(rowErr), /disabled/);
});

// ---- the HALT action --------------------------------------------------------

test('R5: haltAction re-reads the row and PUTs the FRESH builder and pool_app; an already-matching row sends no PUT', async () => {
  const fresh = { ...ROW, builder: 'pool', pool_app: 'x', halted: 0 };
  let calls = fakeFetch({
    '/api/coord/routing/': [200, { routing: fresh }],
    '/api/coord/routing': [200, { routing: { ...fresh, halted: 1 } }]
  });
  const out = await haltAction({ apiObj: api, project: 'project-3', target: true, reason: ' drill ' });
  assert.deepEqual(calls.map((c) => [c.method, c.url]), [
    ['GET', '/api/coord/routing/project-3'],
    ['PUT', '/api/coord/routing']
  ]);
  assert.deepEqual(calls[1].body, { project: 'project-3', halted: 1, reason: 'drill' });
  assert.equal(out.ok, true);
  assert.match(out.text, /project-3 halted/);

  calls = fakeFetch({ '/api/coord/routing/': [200, { routing: { ...fresh, halted: 1 } }] });
  const same = await haltAction({ apiObj: api, project: 'project-3', target: true, reason: '' });
  assert.equal(calls.filter((c) => c.method === 'PUT').length, 0);
  assert.equal(same.text, 'already halted');

  calls = fakeFetch({ '/api/coord/routing/': [404, { error: 'not found' }] });
  const gone = await haltAction({ apiObj: api, project: 'project-3', target: true, reason: '' });
  assert.equal(calls.filter((c) => c.method === 'PUT').length, 0, 'a vanished row is never re-created');
  assert.equal(gone.ok, false);
  assert.match(gone.text, /^HALT refused — /);
});

test('R6: unhalt sends halted:0; a 400 is refused; success copy comes from the returned row', async () => {
  let calls = fakeFetch({
    '/api/coord/routing/': [200, { routing: ROW }],
    '/api/coord/routing': [200, { routing: { ...ROW, halted: 0 } }]
  });
  const ok = await haltAction({ apiObj: api, project: 'project-3', target: false, reason: ' lane fixed ' });
  assert.equal(calls[1].body.halted, 0);
  assert.equal(calls[1].body.reason, 'lane fixed');
  assert.equal(ok.ok, true);
  assert.match(ok.text, /project-3 unhalted/);

  // A blank UNHALT reason sends nothing at all, not even the re-read.
  calls = fakeFetch({ '/api/coord/routing': [200, { routing: ROW }] });
  const blank = await haltAction({ apiObj: api, project: 'project-3', target: false, reason: '  ' });
  assert.equal(calls.length, 0);
  assert.equal(blank.ok, false);
  assert.equal(blank.text, 'UNHALT refused — a reason is required');

  fakeFetch({
    '/api/coord/routing/': [200, { routing: ROW }],
    '/api/coord/routing': [400, { error: 'builder must be local, fly1 or pool' }]
  });
  const bad = await haltAction({ apiObj: api, project: 'project-3', target: false, reason: 'x' });
  assert.equal(bad.ok, false);
  assert.equal(bad.text, 'UNHALT refused — builder must be local, fly1 or pool');

  // The worker answered 200 but the row it returned is still halted: not a success.
  fakeFetch({
    '/api/coord/routing/': [200, { routing: ROW }],
    '/api/coord/routing': [200, { routing: ROW }]
  });
  const lied = await haltAction({ apiObj: api, project: 'project-3', target: false, reason: 'x' });
  assert.equal(lied.ok, false);
  assert.doesNotMatch(lied.text, /unhalted/);
});

// ---- the real RoutingPanel, mounted and clicked (D2) ------------------------

class FakeNode {
  constructor(nodeType, name, data) {
    this.nodeType = nodeType;
    this.localName = name;
    this.nodeName = name ? name.toUpperCase() : '#text';
    this.data = data;
    this.childNodes = [];
    this.parentNode = null;
    this.attrs = {};
    this.style = {};
    this.listeners = {};
  }
  get onclick() { return null; }
  get oninput() { return null; }
  get firstChild() { return this.childNodes[0] || null; }
  get nextSibling() {
    if (!this.parentNode) return null;
    const s = this.parentNode.childNodes;
    return s[s.indexOf(this) + 1] || null;
  }
  insertBefore(n, ref) {
    if (n.parentNode) n.parentNode.removeChild(n);
    n.parentNode = this;
    const i = ref ? this.childNodes.indexOf(ref) : -1;
    if (i < 0) this.childNodes.push(n); else this.childNodes.splice(i, 0, n);
    return n;
  }
  appendChild(n) { return this.insertBefore(n, null); }
  removeChild(n) {
    this.childNodes.splice(this.childNodes.indexOf(n), 1);
    n.parentNode = null;
    return n;
  }
  remove() { if (this.parentNode) this.parentNode.removeChild(this); }
  setAttribute(k, v) { this.attrs[k] = String(v); }
  removeAttribute(k) { delete this.attrs[k]; }
  getAttribute(k) { return k in this.attrs ? this.attrs[k] : null; }
  addEventListener(t, fn) { this.listeners[t] = fn; }
  removeEventListener(t) { delete this.listeners[t]; }
  focus() {}
  querySelector() { return null; }
  querySelectorAll() { return []; }
  get textContent() { return this.nodeType === 3 ? String(this.data) : this.childNodes.map((c) => c.textContent).join(''); }
}

function installDom() {
  const doc = new FakeNode(9, '#document');
  doc.createElement = (t) => new FakeNode(1, t);
  doc.createElementNS = (_, t) => new FakeNode(1, t);
  doc.createTextNode = (d) => new FakeNode(3, null, d);
  globalThis.document = doc;
  globalThis.window = globalThis.window || { dispatchEvent() {}, addEventListener() {}, removeEventListener() {} };
  return doc;
}

const all = (n, out = []) => { out.push(n); n.childNodes.forEach((c) => all(c, out)); return out; };
const byLabel = (root, label) => all(root).find((n) => n.attrs && n.attrs['aria-label'] === label);
const button = (root, text) => all(root).find((n) => n.localName === 'button' && n.textContent.trim() === text);
const ev = (el, type) => ({ type, target: el, currentTarget: el, preventDefault() {}, stopPropagation() {} });
const click = (el) => el.listeners.click.call(el, ev(el, 'click'));
const dialogOf = (root) => all(root).find((n) => n.attrs && n.attrs.role === 'dialog');

// Every mounted root is unmounted after its test: the panel polls every 30s,
// and a live timer would hold the test process open.
const mounted = [];
afterEach(() => { while (mounted.length) mount(null, mounted.pop()); });

async function mountPanel(routes) {
  const doc = installDom();
  const calls = fakeFetch(routes);
  const root = doc.createElement('div');
  mount(h(RoutingPanel, { project: 'project-3' }), root);
  mounted.push(root);
  await flush();
  return { root, calls };
}

test('D2: the mounted panel loads three reads, HALTs through the in-app modal with a typed reason, and reloads', async () => {
  const unhalted = { ...ROW, halted: 0 };
  const { root, calls } = await mountPanel({
    '/api/coord/routing/': [[200, { routing: unhalted }], [200, { routing: unhalted }], [200, { routing: ROW }]],
    '/api/coord/settings/routing_rows': [200, KNOB_ON],
    '/api/coord/routing-changes': [200, CHANGES],
    '/api/coord/routing': [200, { routing: ROW }]
  });
  assert.deepEqual(calls.map((c) => c.url).sort(), [
    '/api/coord/routing-changes?project=project-3&limit=50',
    '/api/coord/routing/project-3',
    '/api/coord/settings/routing_rows'
  ]);
  assert.match(root.textContent, /bh-pool-project-3/);
  const toggle = byLabel(root, 'HALT');
  assert.equal(toggle.attrs['aria-pressed'], 'false');
  click(toggle);
  await flush();
  const dialog = dialogOf(root);
  assert.ok(dialog, 'the in-app dialog opened');
  assert.match(dialog.textContent, /Halt new pool spawns for project-3\?/);
  assert.match(dialog.textContent, /A harness deploy clears it unless a pool-halt \.keep file holds the halt\./);
  assert.equal(calls.filter((c) => c.method === 'PUT').length, 0, 'opening the dialog sends nothing');
  const input = byLabel(root, 'reason for this routing change');
  input.value = 'lane stuck';
  input.listeners.input.call(input, ev(input, 'input'));
  click(button(dialogOf(root), 'HALT'));
  await flush();
  const puts = calls.filter((c) => c.method === 'PUT');
  assert.equal(puts.length, 1);
  assert.deepEqual(puts[0].body, { project: 'project-3', halted: 1, reason: 'lane stuck' });
  assert.match(root.textContent, /project-3 halted/);
  assert.ok(!dialogOf(root), 'dialog closed');
  // Reloaded after the write: the row and the change log were read again.
  const after = calls.slice(calls.indexOf(calls.find((c) => c.method === 'PUT')) + 1).map((c) => c.url);
  assert.ok(after.includes('/api/coord/routing/project-3'), after.join(' '));
  assert.ok(after.includes('/api/coord/routing-changes?project=project-3&limit=50'), after.join(' '));
  assert.equal(byLabel(root, 'HALT').attrs['aria-pressed'], 'true');
});

test('D2: cancel sends nothing; with routing_rows off the toggle is disabled and clicking it opens nothing', async () => {
  const live = await mountPanel({
    '/api/coord/routing/': [200, { routing: ROW }],
    '/api/coord/settings/routing_rows': [200, KNOB_ON],
    '/api/coord/routing-changes': [200, CHANGES]
  });
  click(byLabel(live.root, 'HALT'));
  await flush();
  assert.match(dialogOf(live.root).textContent, /Resume pool spawns for project-3\?/);
  click(button(dialogOf(live.root), 'CANCEL'));
  await flush();
  assert.equal(live.calls.filter((c) => c.method === 'PUT').length, 0);
  assert.ok(!dialogOf(live.root));

  const off = await mountPanel({
    '/api/coord/routing/': [200, { routing: ROW }],
    '/api/coord/settings/routing_rows': [200, KNOB_OFF],
    '/api/coord/routing-changes': [200, CHANGES]
  });
  const t = byLabel(off.root, 'HALT');
  assert.ok(t.disabled === true || 'disabled' in t.attrs, 'toggle disabled');
  assert.match(off.root.textContent, /routing_rows is off/);
});

test('D3: UNHALT shows who halted it and why, and CONFIRM stays disabled until a reason is typed', async () => {
  const { root, calls } = await mountPanel({
    '/api/coord/routing/': [[200, { routing: ROW }], [200, { routing: ROW }], [200, { routing: { ...ROW, halted: 0 } }]],
    '/api/coord/settings/routing_rows': [200, KNOB_ON],
    '/api/coord/routing-changes': [200, CHANGES],
    '/api/coord/routing': [200, { routing: { ...ROW, halted: 0 } }]
  });
  click(byLabel(root, 'HALT'));
  await flush();
  const dialog = dialogOf(root);
  assert.match(dialog.textContent, /Resume pool spawns for project-3\?/);
  assert.match(dialog.textContent, /Halted by console/);
  assert.match(dialog.textContent, /drill/);
  assert.match(dialog.textContent, /REASON \(REQUIRED\)/);
  const confirmBtn = () => button(dialogOf(root), 'UNHALT');
  assert.ok('disabled' in confirmBtn().attrs || confirmBtn().disabled === true, 'confirm starts disabled');
  click(confirmBtn());
  await flush();
  assert.equal(calls.filter((c) => c.method === 'PUT').length, 0, 'a disabled confirm sends nothing');
  const input = byLabel(root, 'reason for this routing change');
  input.value = '   ';
  input.listeners.input.call(input, ev(input, 'input'));
  await flush();
  assert.ok('disabled' in confirmBtn().attrs || confirmBtn().disabled === true, 'a blank reason keeps it disabled');
  input.value = 'lane fixed';
  input.listeners.input.call(input, ev(input, 'input'));
  await flush();
  assert.ok(!('disabled' in confirmBtn().attrs) && confirmBtn().disabled !== true, 'a reason enables confirm');
  click(confirmBtn());
  await flush();
  const puts = calls.filter((c) => c.method === 'PUT');
  assert.equal(puts.length, 1);
  assert.deepEqual(puts[0].body, { project: 'project-3', halted: 0, reason: 'lane fixed' });
  assert.match(root.textContent, /project-3 unhalted/);
});

test('D2: the real Project page mounts the ROUTING section with the panel in it', async () => {
  const { ProjectScreen } = await import('../src/screens/Project.js');
  const doc = installDom();
  const calls = fakeFetch({
    '/api/dash/p/project-3': [200, { board: {}, runs: [], builds: [], alerts: [], events: [] }],
    '/api/dash/costs': [200, { volume: [] }],
    '/api/coord/routing/': [200, { routing: ROW }],
    '/api/coord/settings/routing_rows': [200, KNOB_ON],
    '/api/coord/routing-changes': [200, CHANGES],
    '/api/': [200, {}]
  });
  const root = doc.createElement('div');
  mount(h(ProjectScreen, { project: 'project-3' }), root);
  mounted.push(root);
  await flush();
  await flush();
  assert.match(root.textContent, /ROUTING/);
  assert.match(root.textContent, /builder, pool and halt for this project, from the routing row/);
  assert.ok(byLabel(root, 'HALT'), 'the HALT toggle is on the Project page');
  assert.ok(calls.some((c) => c.url === '/api/coord/routing/project-3'));
});
