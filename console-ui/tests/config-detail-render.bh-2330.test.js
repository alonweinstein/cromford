import test from 'node:test';
import assert from 'node:assert/strict';
import { h, render as mount } from 'preact';
import { flush } from './helpers/settle.js';

// BH-2379 (BH-2330.4): /config/:kind/:name, one config row's current value
// and its full config_changes history. The view is rendered to a string for
// every load state; the wired screen is mounted into a small fake DOM against
// a stubbed fetch, reached through the real ROUTES table and matchRoute, so
// its reads go through the real api.js.

globalThis.window = globalThis.window || {
  location: { pathname: '/config', search: '' },
  dispatchEvent() {}, addEventListener() {}, removeEventListener() {},
  history: { pushState() {}, replaceState() {} }, scrollTo() {}
};

const { CONFIG_KINDS } = await import('../../worker/jobs/src/lib/config-changes.js');
const { CONFIG_KIND_VALUES, isKnownKind, historyRows, sideText, currentFor, DETAIL_LIMIT } =
  await import('../src/lib/config-detail.js');
const { ConfigDetailView } = await import('../src/screens/ConfigDetail.js');
const { ROUTES } = await import('../src/app.js');
const { matchRoute } = await import('../src/router.js');
const { render } = await import('preact-render-to-string');

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
  // Preact lowercases an event name only when the element has the on* property.
  get onclick() { return null; }
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
  get textContent() { return this.nodeType === 3 ? String(this.data) : this.childNodes.map((c) => c.textContent).join(''); }
}

function installDom() {
  const doc = new FakeNode(9, '#document');
  doc.createElement = (t) => new FakeNode(1, t);
  doc.createElementNS = (_, t) => new FakeNode(1, t);
  doc.createTextNode = (d) => new FakeNode(3, null, d);
  doc.hidden = false;
  globalThis.document = doc;
  return doc;
}
// A failed assertion skips a test's own unmount; a still-mounted screen keeps
// polling and the process never exits, so every root is unmounted afterwards.
const mounted = new Set();
test.afterEach(() => { for (const r of mounted) mount(null, r); mounted.clear(); });
const all = (n, out = []) => { out.push(n); n.childNodes.forEach((c) => all(c, out)); return out; };
const click = (el) => el.listeners.click.call(el, { type: 'click', target: el, currentTarget: el, preventDefault() {}, stopPropagation() {} });

function stubFetch(answer) {
  const calls = [];
  globalThis.fetch = async (url) => {
    calls.push(String(url));
    const body = await answer(String(url));
    return { ok: true, status: 200, text: async () => JSON.stringify(body) };
  };
  return calls;
}

async function mountPath(path) {
  const doc = installDom();
  const hit = ROUTES.map(([p, C]) => [matchRoute(p, path), C]).find(([params]) => params);
  assert.ok(hit, `a route matches ${path}`);
  const root = doc.createElement('div');
  mounted.add(root);
  mount(h(hit[1], hit[0]), root);
  await flush();
  return { root, text: () => root.textContent, unmount: () => mount(null, root) };
}

const AT = '2026-09-27T20:00:00Z';
const change = (id, before_json, after_json, actor, reason, at = AT) =>
  ({ id, kind: 'setting', name: 'gh.quota.reserve', before_json, after_json, actor, reason, at });
const THREE = [
  change(1, null, '{"value":"700"}', 'operator', 'first cut', '2026-09-25T10:00:00Z'),
  change(2, '{"value":"800"}', '{"value":"900"}', 'zed', null, '2026-09-26T10:00:00Z'),
  change(3, '{"value":"900"}', 'null', 'api', 'retired', '2026-09-27T10:00:00Z')
];
const ok = (data) => ({ data, error: null, loading: false });
const hist = (kind, name, res) => ok({ kind, name, res });
const view = (props) => render(h(ConfigDetailView, { known: true, onRetryHistory: () => {}, onRetryCurrent: () => {}, ...props }));
const noCurrent = { data: null, error: null, loading: false };
const text = (s) => s.replace(/<[^>]*>/g, '');

test('K1: the console mirror of the kinds equals the worker CONFIG_KINDS', () => {
  assert.deepEqual([...CONFIG_KIND_VALUES], Object.values(CONFIG_KINDS));
  assert.equal(isKnownKind('setting'), true);
  assert.equal(isKnownKind('cost_cap'), true);
  assert.equal(isKnownKind('bogus'), false);
  assert.equal(isKnownKind(undefined), false);
  assert.equal(DETAIL_LIMIT, 500);
});

test('R6: history renders AT, BEFORE → AFTER, WHO, WHY with create, update and delete sides', () => {
  const out = view({ kind: 'setting', name: 'gh.quota.reserve',
    history: hist('setting', 'gh.quota.reserve', { changes: THREE, truncated: false }),
    current: ok({ kind: 'setting', name: 'gh.quota.reserve', res: { setting: null } }) });
  const heads = [...out.matchAll(/<th[^>]*>([\s\S]*?)<\/th>/g)].map((m) => text(m[1]).replace(/[↑↓]/g, '').trim());
  assert.deepEqual(heads, ['AT', 'BEFORE → AFTER', 'WHO', 'WHY']);
  const t = text(out);
  assert.match(t, /800 → 900/);
  assert.match(t, /\(created\) → 700/);
  assert.match(t, /900 → \(deleted\)/);
  for (const s of ['operator', 'zed', 'api', 'first cut', 'retired']) assert.ok(t.includes(s), s);
  assert.match(out, /<span class="na">—<\/span>/, 'a null reason is a dash');
  assert.match(out, /class="tablewrap/);
  assert.match(out, /href="\/config"/);
  // Newest first by default.
  assert.ok(t.indexOf('retired') < t.indexOf('first cut'));
});

test('R6b: the truncated notice shows only when truncated is exactly true', () => {
  const at = (truncated) => text(view({ kind: 'setting', name: 'k',
    history: hist('setting', 'k', { changes: THREE, truncated }), current: noCurrent }));
  assert.match(at(true), /showing the newest 3 changes; sorting covers only these/);
  assert.doesNotMatch(at(false), /showing the newest/);
  assert.doesNotMatch(at('yes'), /showing the newest/);
});

test('R7: an unknown kind renders "unknown kind" and fetches nothing', async () => {
  const calls = stubFetch(() => ({ changes: [], truncated: false }));
  const s = await mountPath('/config/bogus/x');
  assert.match(s.text(), /unknown kind: bogus/);
  assert.equal(calls.length, 0);
  s.unmount();
});

test('R8: a setting with no current row renders "no row" beside a populated history', () => {
  const t = text(view({ kind: 'setting', name: 'k',
    history: hist('setting', 'k', { changes: THREE.slice(0, 2), truncated: false }),
    current: ok({ kind: 'setting', name: 'k', res: { key: 'k', setting: null, source: 'none' } }) }));
  assert.match(t, /no row/);
  assert.match(t, /\(created\) → 700/);
  assert.match(t, /800 → 900/);
});

test('D3: a setting current row shows value, writer, note and an age', (tc) => {
  // Date pinned: the age is measured back from the clock, so the clock is AT
  // and the row was written five minutes before it.
  const ANCHOR = Date.parse(AT);
  tc.mock.timers.enable({ apis: ['Date'], now: ANCHOR });
  const updated = new Date(ANCHOR - 5 * 60000).toISOString();
  const t = text(view({ kind: 'setting', name: 'k', history: hist('setting', 'k', { changes: [], truncated: false }),
    current: ok({ kind: 'setting', name: 'k', res: { key: 'k', setting: { key: 'k', value: '800', actor: 'operator', note: 'why', updated_at: updated } } }) }));
  assert.match(t, /VALUE\s*800/);
  assert.match(t, /LAST WRITER\s*operator/);
  assert.match(t, /NOTE\s*why/);
  assert.match(t, /UPDATED\s*5m/);
  assert.doesNotMatch(t, /no row/);
});

test('D4: a flag current row shows state and reason; absent from a full list is not "no row"', () => {
  const flags = [{ name: 'x', active: 1, actor: 'operator', reason: 'r', updated_at: AT }];
  const t = text(view({ kind: 'flag', name: 'x', history: hist('flag', 'x', { changes: [], truncated: false }),
    current: ok({ kind: 'flag', name: 'x', res: { flags } }) }));
  assert.match(t, /STATE\s*active/);
  assert.match(t, /REASON\s*r/);
  const off = text(view({ kind: 'flag', name: 'x', history: hist('flag', 'x', { changes: [], truncated: false }),
    current: ok({ kind: 'flag', name: 'x', res: { flags: [{ ...flags[0], active: 0 }] } }) }));
  assert.match(off, /STATE\s*inactive/);

  const full = Array.from({ length: 500 }, (_, i) => ({ name: `f${i}`, active: 0 }));
  const capped = text(view({ kind: 'flag', name: 'x', history: hist('flag', 'x', { changes: [], truncated: false }),
    current: ok({ kind: 'flag', name: 'x', res: { flags: full } }) }));
  assert.match(capped, /not in the first 500 flags/);
  assert.doesNotMatch(capped, /no row/);
  const short = text(view({ kind: 'flag', name: 'x', history: hist('flag', 'x', { changes: [], truncated: false }),
    current: ok({ kind: 'flag', name: 'x', res: { flags: full.slice(0, 3) } }) }));
  assert.match(short, /no row/);
});

test('D5: the wired screen reads config-changes limit=500 plus the one current-row read', async () => {
  const answer = (url) => (url.startsWith('/api/coord/config-changes') ? { changes: [], truncated: false }
    : url.startsWith('/api/coord/settings/') ? { key: 'a.b', setting: null, source: 'none' } : { flags: [] });
  let calls = stubFetch(answer);
  const s = await mountPath('/config/setting/a.b');
  assert.deepEqual([...calls].sort(), ['/api/coord/config-changes?kind=setting&name=a.b&limit=500', '/api/coord/settings/a.b']);
  s.unmount();

  calls = stubFetch(answer);
  const f = await mountPath('/config/flag/x');
  assert.deepEqual([...calls].sort(), ['/api/coord/config-changes?kind=flag&name=x&limit=500', '/api/coord/flags']);
  assert.match(f.text(), /no row/);
  f.unmount();
});

test('D6: a failed refresh keeps the last rows and puts an ErrorBox above them', () => {
  const out = view({ kind: 'setting', name: 'k', current: noCurrent,
    history: { data: { kind: 'setting', name: 'k', res: { changes: THREE, truncated: false } }, error: new Error('network down'), loading: false } });
  const t = text(out);
  assert.match(t, /could not load — network down/);
  assert.match(t, /800 → 900/);
  assert.match(out, /RETRY/);
  assert.ok(t.indexOf('could not load') < t.indexOf('800 → 900'), 'the ErrorBox sits above the rows');
});

test('D7: zero rows render Empty; a body with no changes array is an ErrorBox, never Empty', () => {
  const empty = view({ kind: 'setting', name: 'k', current: noCurrent, history: hist('setting', 'k', { changes: [], truncated: false }) });
  assert.match(text(empty), /no changes recorded yet/);
  assert.doesNotMatch(empty, /<table/);
  const bad = text(view({ kind: 'setting', name: 'k', current: noCurrent, history: hist('setting', 'k', { error: 'x' }) }));
  assert.match(bad, /could not load — unexpected response/);
  assert.doesNotMatch(bad, /no changes recorded yet/);
});

test('D7b: a failed current read is its own ErrorBox; the history still renders', () => {
  const t = text(view({ kind: 'setting', name: 'k', history: hist('setting', 'k', { changes: THREE, truncated: false }),
    current: { data: null, error: new Error('HTTP 400'), loading: false } }));
  assert.match(t, /could not load — HTTP 400/);
  assert.doesNotMatch(t, /no row/);
  assert.match(t, /800 → 900/);
});

test('D8: a known kind with no current reader fetches only the history and says so', async () => {
  const calls = stubFetch(() => ({ changes: [change(1, null, '{"cap_usd":5}', 'operator', null)], truncated: false }));
  const s = await mountPath('/config/cost_cap/conf.cost-caps.default');
  assert.deepEqual(calls, ['/api/coord/config-changes?kind=cost_cap&name=conf.cost-caps.default&limit=500']);
  assert.match(s.text(), /history only; this page has no current-row reader for cost_cap/);
  assert.match(s.text(), /\(created\) → 5/);
  s.unmount();
});

test('D9: an answer for the previous record never paints over the current one', async () => {
  const doc = installDom();
  const Detail = ROUTES.find(([p]) => p === '/config/:kind/:name')[1];
  const resolvers = {};
  stubFetch((url) => (url.startsWith('/api/coord/config-changes')
    ? new Promise((r) => { resolvers[new URL(url, 'https://c.test').searchParams.get('name')] = r; })
    : { setting: null }));
  const root = doc.createElement('div');
  mounted.add(root);
  mount(h(Detail, { kind: 'setting', name: 'old' }), root);
  await flush();
  mount(h(Detail, { kind: 'setting', name: 'new' }), root);
  await flush();
  resolvers.new({ changes: [], truncated: false });
  await flush();
  resolvers.old({ changes: THREE, truncated: false });
  await flush();
  assert.match(root.textContent, /setting · new/);
  assert.match(root.textContent, /no changes recorded yet/);
  assert.doesNotMatch(root.textContent, /800 → 900/);
  mount(null, root);
});

test('Sort: clicking WHO reorders the rows by actor and flips aria-sort', async () => {
  stubFetch((url) => (url.startsWith('/api/coord/config-changes')
    ? { changes: THREE, truncated: false } : { setting: null }));
  const s = await mountPath('/config/setting/gh.quota.reserve');
  const actors = () => all(s.root).filter((n) => n.localName === 'tr').slice(1)
    .map((tr) => tr.childNodes.filter((c) => c.localName === 'td')[2].textContent.trim());
  const th = (label) => all(s.root).find((n) => n.localName === 'th' && n.textContent.includes(label));
  assert.deepEqual(actors(), ['api', 'zed', 'operator'], 'AT descending by default');
  assert.equal(th('AT').getAttribute('aria-sort'), 'descending');
  click(all(th('WHO')).find((n) => n.localName === 'button'));
  await flush();
  assert.deepEqual(actors(), ['api', 'operator', 'zed']);
  assert.equal(th('WHO').getAttribute('aria-sort'), 'ascending');
  click(all(th('WHO')).find((n) => n.localName === 'button'));
  await flush();
  assert.deepEqual(actors(), ['zed', 'operator', 'api']);
  assert.equal(th('WHO').getAttribute('aria-sort'), 'descending');
  s.unmount();
});

test('L1: the pure helpers', () => {
  assert.equal(sideText(null, 'before'), '(created)');
  assert.equal(sideText('null', 'after'), '(deleted)');
  assert.equal(sideText('{"value":"9"}', 'after'), '9');
  assert.equal(sideText('{"a":1,"b":null}', 'after'), 'a: 1 · b: —');
  assert.equal(sideText('{"a":null}', 'after'), '—');
  assert.equal(sideText('not json', 'after'), 'not json');
  assert.deepEqual(historyRows({ changes: [1], truncated: true }), { rows: [1], truncated: true });
  assert.deepEqual(historyRows({ error: 'x' }), { malformed: true });
  assert.deepEqual(historyRows(null), { malformed: true });
  assert.deepEqual(currentFor('setting', 'k', { setting: null }), { missing: true });
  assert.deepEqual(currentFor('setting', 'k', { error: 'x' }), { malformed: true });
  assert.deepEqual(currentFor('flag', 'x', { error: 'x' }), { malformed: true });
  assert.deepEqual(currentFor('cost_cap', 'x', {}), { none: true });
});
