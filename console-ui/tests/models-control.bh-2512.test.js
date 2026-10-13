import test, { afterEach } from 'node:test';
import assert from 'node:assert/strict';
import { render } from 'preact-render-to-string';
import { h, render as mount } from 'preact';
import { api } from '../src/api.js';
import { onRequest } from '../functions/api/coord/[[path]].js';
import * as models from '../src/lib/models.js';
import { ModelsView, ModelRoleView, ModelsScreen, ModelRoleScreen } from '../src/screens/Models.js';
import { flush } from './helpers/settle.js';

// BH-2512 — the Models page gets the two writes the worker already had
// (POST model-routes/remove, PUT model-prices/source) and an UNROUTED STAGES
// list. Both halves are driven: the coord proxy that admits the writes, the
// api client that sends them, the lib actions that confirm and map outcomes,
// and the rendered screen. Namespace import on purpose: a missing export fails
// its own test, not the whole file.

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
const proxy = (rest, method, body) => onRequest({
  request: new Request(`https://console.example.pages.dev/api/coord/${rest}`, {
    method, headers: { cookie: `dash=bh2512-${++cookieSeq}`, 'content-type': 'application/json' },
    body: body === undefined ? undefined : JSON.stringify(body)
  }),
  env: { HARNESS_SECRET: SECRET },
  params: { path: rest.split('/') }
});

// ─────────────────────────────────────────────────────────────── proxy

test('P1: POST model-routes/remove forwards role, expected_version, reason; actor stamped, extras dropped', async () => {
  const f = stubFetch();
  try {
    const res = await proxy('model-routes/remove', 'POST', { role: 'stage.foo', expected_version: 7, reason: 'r', actor: 'mallory', smuggled: 1, expected_hub_version: 3 });
    assert.equal(res.status, 200);
    assert.equal(f.seen.length, 1);
    assert.equal(f.seen[0].url, `${JOBS}/api/model-routes/remove`);
    assert.equal(f.seen[0].method, 'POST');
    assert.deepEqual(JSON.parse(f.seen[0].body), { role: 'stage.foo', expected_version: 7, reason: 'r', actor: 'console' });
  } finally { f.restore(); }
});

test('P2: remove forwards project (so the worker\'s hub-only 400 fires); PUT on that path is 405', async () => {
  const f = stubFetch();
  try {
    await proxy('model-routes/remove', 'POST', { role: 'stage.foo', project: 'p1' });
    assert.deepEqual(JSON.parse(f.seen[0].body), { role: 'stage.foo', project: 'p1', actor: 'console' });
    const res = await proxy('model-routes/remove', 'PUT', { role: 'stage.foo' });
    assert.equal(res.status, 405);
    assert.equal(f.seen.length, 1, 'the 405 sent nothing');
  } finally { f.restore(); }
});

test('P3: PUT model-prices/source forwards model and price_source only; vendor and non-strings dropped', async () => {
  const f = stubFetch();
  try {
    const res = await proxy('model-prices/source', 'PUT', { model: 'm-a', price_source: 'vendor-direct', vendor: { prompt: 1, completion: 1 }, actor: 'x' });
    assert.equal(res.status, 200);
    assert.equal(f.seen[0].url, `${JOBS}/api/model-prices/source`);
    assert.equal(f.seen[0].method, 'PUT');
    assert.deepEqual(JSON.parse(f.seen[0].body), { model: 'm-a', price_source: 'vendor-direct', actor: 'console' });
    await proxy('model-prices/source', 'PUT', { model: 42, price_source: 'openrouter' });
    assert.deepEqual(JSON.parse(f.seen[1].body), { price_source: 'openrouter', actor: 'console' });
  } finally { f.restore(); }
});

test('P4: POST on model-prices/source is 405 and never forwarded', async () => {
  const f = stubFetch();
  try {
    const res = await proxy('model-prices/source', 'POST', { model: 'm-a', price_source: 'openrouter' });
    assert.equal(res.status, 405);
    assert.equal(f.seen.length, 0);
  } finally { f.restore(); }
});

// ──────────────────────────────────────────────────────────── api client

test('A1: removeModelRoute, setModelPriceSource and the unrouted list read put the right thing on the wire', async () => {
  const calls = [];
  const real = globalThis.fetch;
  globalThis.fetch = async (url, init = {}) => {
    calls.push({ url: String(url), method: init.method || 'GET', body: init.body });
    return { ok: true, status: 200, text: async () => '{}' };
  };
  try {
    await api.removeModelRoute({ role: 'stage.foo', reason: 'r', expected_version: 2 });
    await api.setModelPriceSource({ model: 'm-a', price_source: 'vendor-direct' });
    await api.modelRoutes(null, '2026-09-19T00:00:00Z');
    await api.modelRoutes('p1', '2026-09-19T00:00:00Z');
    await api.modelRoutes();
    await api.modelRoutes('p1');
  } finally { globalThis.fetch = real; }
  assert.deepEqual(calls.map((c) => [c.method, c.url]), [
    ['POST', '/api/coord/model-routes/remove'],
    ['PUT', '/api/coord/model-prices/source'],
    ['GET', '/api/coord/model-routes?unrouted_since=2026-09-19T00%3A00%3A00Z'],
    ['GET', '/api/coord/model-routes?project=p1&unrouted_since=2026-09-19T00%3A00%3A00Z'],
    ['GET', '/api/coord/model-routes'],
    ['GET', '/api/coord/model-routes?project=p1']
  ]);
  assert.deepEqual(JSON.parse(calls[0].body), { role: 'stage.foo', reason: 'r', expected_version: 2 });
  assert.deepEqual(JSON.parse(calls[1].body), { model: 'm-a', price_source: 'vendor-direct' });
});

// ──────────────────────────────────────────────────────────────── actions

function harness({ answer = true, fail = null } = {}) {
  const log = { confirms: [], removes: [], prices: [], refreshes: 0, notes: [] };
  const failWith = () => { if (!fail) return; const e = new Error(fail.message || 'boom'); e.status = fail.status; e.body = fail.body; throw e; };
  const actions = models.makeModelActions({
    confirm: async (o) => { log.confirms.push(o); return answer; },
    writeLadder: async () => ({}),
    resetLadder: async () => ({}),
    removeLadder: async (b) => { log.removes.push(b); failWith(); return {}; },
    writePriceSource: async (b) => { log.prices.push(b); failWith(); return {}; },
    refresh: () => { log.refreshes++; },
    onNote: (n) => log.notes.push(n)
  });
  return { actions, log };
}
const TWO = [{ position: 0, model: 'm-a', runner: 'claude' }, { position: 1, model: 'm-b', runner: 'codex' }];

test('L1: removeRoute on the hub confirms every rung going, sends {role, reason, expected_version}, answers written', async () => {
  const { actions, log } = harness();
  const out = await actions.removeRoute({ role: 'stage.foo', project: null, current: TWO, version: 4 });
  assert.equal(out.status, 'written');
  assert.equal(log.confirms.length, 1);
  assert.equal(log.confirms[0].tone, 'warn');
  assert.deepEqual(log.confirms[0].changes.map((c) => [c.position, c.after]), [[0, null], [1, null]]);
  assert.match(log.confirms[0].note, /RUNNER_FOO/);
  assert.match(log.confirms[0].note, /claude/);
  assert.match(log.confirms[0].note, /deploy/);
  assert.deepEqual(log.removes, [{ role: 'stage.foo', actor: 'console', reason: models.DEFAULT_REMOVE_REASON, expected_version: 4 }]);
  assert.equal(log.refreshes, 1);

  const other = harness();
  await other.actions.removeRoute({ role: 'openrouter.floor', current: TWO, version: 1 });
  assert.doesNotMatch(other.log.confirms[0].note, /RUNNER_/);
  assert.match(other.log.confirms[0].note, /floor rung is skipped/);

  const cancelled = harness({ answer: false });
  assert.equal((await cancelled.actions.removeRoute({ role: 'stage.foo', current: TWO })).status, 'cancelled');
  assert.equal(cancelled.log.removes.length, 0);
});

test('L2: removeRoute refuses a project and an empty ladder without calling anything', async () => {
  const { actions, log } = harness();
  const a = await actions.removeRoute({ role: 'stage.foo', project: 'p1', current: TWO });
  assert.equal(a.status, 'invalid');
  assert.match(a.message, /RESET TO HUB/);
  const b = await actions.removeRoute({ role: 'stage.foo', current: [] });
  assert.equal(b.status, 'invalid');
  assert.equal(log.confirms.length, 0);
  assert.equal(log.removes.length, 0);
});

test('L3: a 409 on remove is stale + reload; a 500 is failed; neither is written', async () => {
  const stale = harness({ fail: { status: 409, body: { stale: 'project' } } });
  const s = await stale.actions.removeRoute({ role: 'stage.foo', current: TWO, version: 4 });
  assert.equal(s.status, 'stale');
  assert.equal(stale.log.refreshes, 1);
  const failed = harness({ fail: { status: 500, message: 'db down' } });
  const f = await failed.actions.removeRoute({ role: 'stage.foo', current: TWO, version: 4 });
  assert.equal(f.status, 'failed');
  assert.match(f.message, /db down/);
  assert.ok(failed.log.notes.every((n) => !n.ok));
});

test('L4: setPriceSource sends vendor-direct / openrouter, and the openrouter confirm says it clears vendor rates', async () => {
  const { actions, log } = harness();
  assert.equal((await actions.setPriceSource({ model: 'm-a', direct: false })).status, 'written');
  assert.equal((await actions.setPriceSource({ model: 'm-a', direct: true })).status, 'written');
  assert.deepEqual(log.prices, [
    { model: 'm-a', price_source: 'vendor-direct' },
    { model: 'm-a', price_source: 'openrouter' }
  ]);
  assert.match(log.confirms[0].note, /04:30/);
  assert.match(log.confirms[1].note, /clears/i);
  assert.doesNotMatch(log.confirms[0].note, /clears/i);
  assert.match(log.notes[0].text, /04:30/, 'the success note names when it takes effect, not a box resolve');
});

test('L5: a 404 on the price source is failed, never written', async () => {
  const { actions, log } = harness({ fail: { status: 404, message: 'not in model_prices: m-a' } });
  const out = await actions.setPriceSource({ model: 'm-a', direct: false });
  assert.equal(out.status, 'failed');
  assert.equal(log.refreshes, 0);
  assert.equal(log.notes[0].ok, false);
});

test('L6: unroutedRows: null on a failed ledger read, [] when empty, rows with links; priceRows per model', () => {
  assert.equal(models.unroutedRows({ unrouted_stages: null, unrouted_error: 'x' }, null), null);
  assert.deepEqual(models.unroutedRows({ unrouted_stages: [] }, null), []);
  const rows = models.unroutedRows({
    unrouted_stages: [
      { stage: 'foo', role: 'stage.foo', projects: ['p1'], calls: 3, last_seen: '2026-09-25T00:00:00Z', runners: ['claude'] },
      { stage: 'a/b', role: null, projects: ['p1'], calls: 1, last_seen: '2026-09-25T00:00:00Z', runners: [] }
    ]
  }, 'p1');
  assert.equal(rows[0].href, '/models/stage.foo?project=p1');
  assert.equal(rows[1].href, null);
  assert.equal(rows[0].calls, 3);

  const prices = models.priceRows({ per_token: {
    'm-b': { prompt: 0.000002, completion: 0.000008 },
    'm-a': { prompt: 0.000001, completion: 0.000004, price_source: 'vendor-direct', vendor_direct: { prompt: 1, completion: 2 } }
  } });
  assert.deepEqual(prices.map((p) => [p.model, p.price_in, p.price_out, p.direct, p.vendorRates]), [
    ['m-a', 1, 4, true, true],
    ['m-b', 2, 8, false, false]
  ]);
});

// ──────────────────────────────────────────────────────────────── render

const tabs = [{ id: 'hub', label: 'HUB' }, { id: 'p1', label: 'p1' }];
const noop = () => {};
const listView = (over = {}) => render(h(ModelsView, {
  tabs, activeTab: 'hub', rows: [], coverage: { exact: [], shared: [], partial: [], none: [] }, gaps: [],
  error: null, loading: false, asOf: null, onTab: noop, onReload: noop, ...over
}));
const UNROUTED = [{ stage: 'foo', role: 'stage.foo', href: '/models/stage.foo', projects: ['p1', 'p2'], calls: 5, last_seen: '2026-09-25T10:00:00Z', runners: ['codex'] }];

test('R1: one unrouted stage renders its section, a link to its role page, and DEFAULTS TO CLAUDE', () => {
  const out = listView({ unrouted: UNROUTED });
  assert.match(out, /UNROUTED STAGES/);
  assert.match(out, /href="\/models\/stage\.foo"/);
  assert.match(out, /DEFAULTS TO CLAUDE/);
  assert.match(out, /p1, p2/);
  assert.match(out, /codex/);
  assert.doesNotMatch(out, /EVERY STAGE IS ROUTED/);
});

test('R2: [] renders EVERY STAGE IS ROUTED; a failed ledger read renders the error and never the empty copy', () => {
  assert.match(listView({ unrouted: [] }), /EVERY STAGE IS ROUTED/);
  const err = listView({ unrouted: null, unroutedError: 'no such table: cost_rows' });
  assert.match(err, /could not read the cost ledger/);
  assert.match(err, /no such table: cost_rows/);
  assert.doesNotMatch(err, /EVERY STAGE IS ROUTED/);
});

test('R3: a truncated list says so', () => {
  assert.match(listView({ unrouted: UNROUTED, unroutedTruncated: true }), /showing the first 500 stage\/project pairs/);
  assert.doesNotMatch(listView({ unrouted: UNROUTED }), /showing the first 500/);
});

const roleView = (over = {}) => render(h(ModelRoleView, {
  role: 'stage.foo', project: null,
  route: { ladder: TWO, source: 'hub', scope_version: 5, provenance: [] },
  hub: null, row: null, prices: { per_token: { 'm-a': { prompt: 1, completion: 1 }, 'm-b': { prompt: 1, completion: 1 } } },
  runners: ['claude', 'codex'], changes: [], truncated: false, error: null, dialog: null, busy: null,
  note: null, onDismissNote: noop, actions: { saveLadder: noop, resetOverride: noop, removeRoute: noop }, ...over
}));

test('R4: REMOVE ROUTE shows on the hub scope of a role the hub holds, never on a project tab', () => {
  assert.match(roleView(), /REMOVE ROUTE/);
  assert.match(roleView({ route: { ladder: [], source: 'none', gapped: { rows: [{ position: 1, model: 'm-a', runner: 'claude' }] }, scope_version: 2 } }), /REMOVE ROUTE/);
  assert.doesNotMatch(roleView({ project: 'p1' }), /REMOVE ROUTE/);
  assert.doesNotMatch(roleView({ project: 'p1', route: { ladder: TWO, source: 'project', scope_version: 5 } }), /REMOVE ROUTE/);
  assert.doesNotMatch(roleView({ route: { ladder: [], source: 'none', scope_version: 0 } }), /REMOVE ROUTE/);
});

test('R5: MODEL PRICES renders per model with its toggle on the hub tab only', () => {
  const prices = [
    { model: 'm-a', price_in: 1, price_out: 4, direct: true, vendorRates: false },
    { model: 'm-b', price_in: 2, price_out: 8, direct: false, vendorRates: false }
  ];
  const hub = listView({ prices, onPriceSource: noop });
  assert.match(hub, /MODEL PRICES/);
  assert.match(hub, /m-a/);
  assert.match(hub, /USE OPENROUTER/);
  assert.match(hub, /MARK VENDOR-DIRECT/);
  assert.match(hub, /DIRECT/);
  const proj = listView({ activeTab: 'p1', prices, onPriceSource: noop });
  assert.doesNotMatch(proj, /MODEL PRICES/);
  assert.doesNotMatch(proj, /MARK VENDOR-DIRECT/);
});

test('R6: the view with none of the new props still renders, and shows neither new section', () => {
  const out = listView();
  assert.match(out, /MODELS/);
  assert.doesNotMatch(out, /UNROUTED STAGES/);
  assert.doesNotMatch(out, /MODEL PRICES/);
});

// ──────────────────────────── the real screens, mounted (the production wiring)
// A minimal DOM (the routing-cas.bh-2488 FakeNode idiom) so the screens run
// their own hooks, their own api calls and their own confirm modal.

class FakeNode {
  constructor(nodeType, name, data) {
    this.nodeType = nodeType; this.localName = name; this.nodeName = name ? name.toUpperCase() : '#text';
    this.data = data; this.childNodes = []; this.parentNode = null; this.attrs = {}; this.style = {}; this.listeners = {};
  }
  // Preact lowercases an event name only when the element has the on* property.
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
  removeChild(n) { this.childNodes.splice(this.childNodes.indexOf(n), 1); n.parentNode = null; return n; }
  remove() { if (this.parentNode) this.parentNode.removeChild(this); }
  setAttribute(k, v) { this.attrs[k] = String(v); }
  removeAttribute(k) { delete this.attrs[k]; }
  getAttribute(k) { return k in this.attrs ? this.attrs[k] : null; }
  addEventListener(t, fn) { this.listeners[t] = fn; }
  removeEventListener(t) { delete this.listeners[t]; }
  focus() {}
  scrollIntoView() {}
  querySelector() { return null; }
  querySelectorAll() { return []; }
  get textContent() { return this.nodeType === 3 ? String(this.data) : this.childNodes.map((c) => c.textContent).join(''); }
}

function installDom(path, search = '') {
  const doc = new FakeNode(9, '#document');
  doc.createElement = (t) => new FakeNode(1, t);
  doc.createElementNS = (_, t) => new FakeNode(1, t);
  doc.createTextNode = (d) => new FakeNode(3, null, d);
  doc.getElementById = () => null;
  globalThis.document = doc;
  globalThis.window = {
    location: { pathname: path, search, hash: '' },
    dispatchEvent() {}, addEventListener() {}, removeEventListener() {}, scrollTo() {}
  };
  return doc;
}

function fakeFetch(routes) {
  const calls = [];
  globalThis.fetch = async (url, init = {}) => {
    const u = String(url);
    calls.push({ url: u, method: init.method || 'GET', body: init.body ? JSON.parse(init.body) : undefined });
    const key = Object.keys(routes).filter((k) => u.startsWith(k)).sort((a, b) => b.length - a.length)[0];
    if (!key) return { ok: false, status: 599, text: async () => JSON.stringify({ error: `unrouted ${u}` }) };
    const [status, body] = routes[key];
    return { ok: status >= 200 && status < 300, status, text: async () => JSON.stringify(body) };
  };
  return calls;
}

const all = (n, out = []) => { out.push(n); n.childNodes.forEach((c) => all(c, out)); return out; };
const button = (root, text) => all(root).find((n) => n.localName === 'button' && n.textContent.trim() === text);
const dialogOf = (root) => all(root).find((n) => n.attrs && n.attrs.role === 'dialog');
const click = (el) => el.listeners.click.call(el, { type: 'click', target: el, currentTarget: el, preventDefault() {}, stopPropagation() {} });

const mounted = [];
const realFetch = globalThis.fetch;
afterEach(() => { while (mounted.length) mount(null, mounted.pop()); globalThis.fetch = realFetch; });

const PRICES = { per_token: { 'm-a': { prompt: 0.000001, completion: 0.000004 } } };

test('M1: the mounted /models asks for the 7-day unrouted list, shows it, and MARK VENDOR-DIRECT PUTs the price source after the modal', async (t) => {
  // Date pinned (setTimeout left real, so flush() still ticks): the screen derives
  // its 7-day window from the clock, and the assertion measures back from here.
  const ANCHOR = Date.parse('2026-09-26T12:00:00Z');
  t.mock.timers.enable({ apis: ['Date'], now: ANCHOR });
  const doc = installDom('/models');
  const calls = fakeFetch({
    '/api/coord/model-routes': [200, {
      project: null, runners: ['claude'], gaps: [], as_of: '2026-09-26T00:00:00Z',
      roles: [{ role: 'stage.plan', source: 'hub', ladder: [{ position: 0, model: 'm-a', runner: 'claude' }] }],
      unrouted_stages: [{ stage: 'foo', role: 'stage.foo', projects: ['p1'], calls: 2, last_seen: '2026-09-25T00:00:00Z', runners: ['claude'] }],
      unrouted_since: '2026-09-19T00:00:00Z', unrouted_truncated: false
    }],
    '/api/coord/model-prices/source': [200, { model: 'm-a', price_source: 'vendor-direct' }],
    '/api/coord/model-prices': [200, PRICES]
  });
  const root = doc.createElement('div');
  mount(h(ModelsScreen, {}), root);
  mounted.push(root);
  await flush();

  const read = calls.find((c) => c.url.startsWith('/api/coord/model-routes'));
  assert.match(read.url, /[?&]unrouted_since=\d{4}-\d\d-\d\dT\d\d%3A\d\d%3A\d\dZ/);
  const since = decodeURIComponent(read.url.split('unrouted_since=')[1]);
  const back = (ANCHOR - Date.parse(since)) / 86400000;
  assert.ok(back > 6.99 && back < 7.01, `the window is 7 days, got ${back}`);
  assert.match(root.textContent, /UNROUTED STAGES/);
  assert.match(root.textContent, /DEFAULTS TO CLAUDE/);
  assert.match(root.textContent, /MODEL PRICES/);

  click(button(root, 'MARK VENDOR-DIRECT'));
  await flush();
  const dlg = dialogOf(root);
  assert.ok(dlg, 'an in-app modal, never a native confirm');
  assert.equal(calls.filter((c) => c.method === 'PUT').length, 0, 'nothing written before the confirm');
  click(button(dlg, 'MARK VENDOR-DIRECT'));
  await flush();
  const puts = calls.filter((c) => c.method === 'PUT');
  assert.deepEqual(puts.map((c) => [c.url, c.body]), [['/api/coord/model-prices/source', { model: 'm-a', price_source: 'vendor-direct' }]]);
  assert.match(root.textContent, /04:30/);
});

test('M2: the mounted hub role page REMOVE ROUTE POSTs the remove after the modal and says so', async () => {
  const doc = installDom('/models/stage.foo');
  const calls = fakeFetch({
    '/api/coord/model-routes/remove': [200, { removed: 2, role: 'stage.foo', tombstone: false }],
    '/api/coord/model-routes/stage.foo': [200, {
      role: 'stage.foo', project: null, ladder: TWO, source: 'hub', scope_version: 9, hub_scope_version: 9,
      gapped: null, provenance: [], runners: ['claude', 'codex']
    }],
    '/api/coord/model-route-changes': [200, { changes: [], truncated: false }],
    '/api/coord/model-prices': [200, PRICES]
  });
  const root = doc.createElement('div');
  mount(h(ModelRoleScreen, { role: 'stage.foo' }), root);
  mounted.push(root);
  await flush();

  click(button(root, 'REMOVE ROUTE'));
  await flush();
  const dlg = dialogOf(root);
  assert.ok(dlg);
  assert.match(dlg.textContent, /RUNNER_FOO/);
  click(button(dlg, 'REMOVE ROUTE'));
  await flush();
  const posts = calls.filter((c) => c.method === 'POST');
  assert.deepEqual(posts.map((c) => [c.url, c.body]), [['/api/coord/model-routes/remove',
    { role: 'stage.foo', actor: 'console', reason: models.DEFAULT_REMOVE_REASON, expected_version: 9 }]]);
  assert.match(root.textContent, /stage\.foo removal written/);
});
