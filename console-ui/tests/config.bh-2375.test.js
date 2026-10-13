import test from 'node:test';
import assert from 'node:assert/strict';
import { h, render as mount } from 'preact';
import { flush } from './helpers/settle.js';

// BH-2375 (BH-2330.0): the /config route stubs. Both read the one audit store,
// config_changes, through GET /api/coord/config-changes. The screens are
// mounted into a small fake DOM against a stubbed fetch, reached through the
// real ROUTES table and matchRoute, so the read goes through the real api.js.

globalThis.window = globalThis.window || {
  location: { pathname: '/config', search: '' },
  dispatchEvent() {}, addEventListener() {}, removeEventListener() {},
  history: { pushState() {}, replaceState() {} }, scrollTo() {}
};

const { configHref } = await import('../src/lib/config.js');
const { api } = await import('../src/api.js');
const { ROUTES, NAV } = await import('../src/app.js');
const { matchRoute } = await import('../src/router.js');
const { SettingsView } = await import('../src/screens/Settings.js');
const { tabsFrom } = await import('../src/lib/settings.js');
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

function stubFetch(answer) {
  const calls = [];
  globalThis.fetch = async (url) => {
    calls.push(String(url));
    const body = await answer(String(url));
    return { ok: true, status: 200, text: async () => JSON.stringify(body) };
  };
  return calls;
}

const row = (id) => ({ id, kind: 'setting', name: 'a.b', before_json: null, after_json: '{}', actor: 'api', reason: null, at: '2026-09-27T20:00:00Z' });

// Mount the screen the real ROUTES table picks for `path`, with the params
// the real matchRoute hands it (the same two steps App takes).
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

test('C1/C2: configHref builds /config/<kind>/<name>, each segment encoded', () => {
  assert.equal(configHref('setting', 'a.b'), '/config/setting/a.b');
  assert.equal(configHref('flag', 'a/b c'), '/config/flag/a%2Fb%20c');
  assert.deepEqual(matchRoute('/config/:kind/:name', configHref('flag', 'a/b c')), { kind: 'flag', name: 'a/b c' });
});

test('C3: api.configChanges builds the query from what it is given, and nothing when given nothing', async () => {
  const calls = stubFetch(() => ({ changes: [], truncated: false }));
  await api.configChanges({ kind: 'setting', name: 'a.b', limit: 5 });
  await api.configChanges();
  assert.deepEqual(calls, ['/api/coord/config-changes?kind=setting&name=a.b&limit=5', '/api/coord/config-changes']);
});

test('C4: /config renders ALL SETTINGS & FLAGS and the count; truncated says more are not shown', async () => {
  const calls = stubFetch(() => ({ changes: [row(3), row(2), row(1)], truncated: false }));
  const s = await mountPath('/config');
  assert.match(s.text(), /ALL SETTINGS & FLAGS/);
  assert.match(s.text(), /3 recent changes/);
  assert.doesNotMatch(s.text(), /more not shown/);
  // BH-2378: the full screen also reads settings and flags, and asks the log
  // for its newest 50; the change-log read is still exactly one.
  assert.deepEqual(calls.filter((u) => u.startsWith('/api/coord/config-changes')), ['/api/coord/config-changes?limit=50']);
  s.unmount();

  stubFetch(() => ({ changes: [row(3), row(2)], truncated: true }));
  const t = await mountPath('/config');
  assert.match(t.text(), /2 recent changes \(more not shown\)/);
  t.unmount();
});

test('C5: /config/setting/a%2Fb reads kind=setting&name=a%2Fb once-encoded and shows kind and name', async () => {
  // BH-2379 replaced the stub's count line with the history table and added
  // the current-row read, so the detail page makes two reads in either order.
  const detailAnswer = (url) => (url.startsWith('/api/coord/settings/')
    ? { setting: null } : { changes: [row(1)], truncated: false });
  const calls = stubFetch(detailAnswer);
  const s = await mountPath('/config/setting/a%2Fb');
  assert.deepEqual([...calls].sort(), ['/api/coord/config-changes?kind=setting&name=a%2Fb&limit=500', '/api/coord/settings/a%2Fb']);
  assert.match(s.text(), /setting · a\/b/);
  assert.ok(all(s.root).some((n) => n.localName === 'td' && /\(created\) →/.test(n.textContent)), 'the history row renders');
  const back = all(s.root).find((n) => n.localName === 'a' && n.getAttribute('href') === '/config');
  assert.ok(back, 'a back link to /config');
  s.unmount();

  // A literal % in a name survives the round trip: matchRoute decodes once and
  // the screen must not decode again.
  const pct = stubFetch(detailAnswer);
  const p = await mountPath(configHref('setting', 'x%41'));
  assert.deepEqual([...pct].sort(), ['/api/coord/config-changes?kind=setting&name=x%2541&limit=500', '/api/coord/settings/x%2541']);
  assert.match(p.text(), /setting · x%41/);
  p.unmount();
});

test('C6: an empty log and a failed read render different lines; loading is its own line', async () => {
  stubFetch(() => ({ changes: [], truncated: false }));
  const empty = await mountPath('/config');
  assert.match(empty.text(), /No changes recorded yet\./);
  assert.doesNotMatch(empty.text(), /Could not load/);
  empty.unmount();

  globalThis.fetch = async () => { throw new Error('network down'); };
  const failed = await mountPath('/config/flag/x');
  // BH-2379: the detail page shows a failed read as its ErrorBox, never as empty.
  assert.match(failed.text(), /could not load — \S/, "the box names why (api.js words a thrown fetch as network unreachable)");
  assert.doesNotMatch(failed.text(), /No changes recorded yet|no changes recorded yet/);
  failed.unmount();

  // A body with no changes array is a failure too, never "no changes".
  stubFetch(() => ({ error: 'nope' }));
  const malformed = await mountPath('/config');
  assert.match(malformed.text(), /Could not load the change log/);
  assert.doesNotMatch(malformed.text(), /No changes recorded yet/);
  malformed.unmount();

  let release;
  stubFetch(() => new Promise((r) => { release = r; }));
  const pending = await mountPath('/config');
  assert.match(pending.text(), /Loading the change log/);
  assert.doesNotMatch(pending.text(), /No changes recorded yet|Could not load/);
  release({ changes: [], truncated: false });
  pending.unmount();
});

test('C6b: an answer for the previous record never paints over the current one (D23)', async () => {
  const doc = installDom();
  const Detail = ROUTES.find(([p]) => p === '/config/:kind/:name')[1];
  const resolvers = {};
  stubFetch((url) => (url.startsWith('/api/coord/settings/') ? { setting: null }
    : new Promise((r) => { resolvers[new URL(url, 'https://c.test').searchParams.get('name')] = r; })));
  const root = doc.createElement('div');
  mounted.add(root);
  mount(h(Detail, { kind: 'setting', name: 'old' }), root);
  await flush();
  mount(h(Detail, { kind: 'setting', name: 'new' }), root);
  await flush();
  resolvers.new({ changes: [], truncated: false });
  await flush();
  resolvers.old({ changes: [row(1), row(2)], truncated: false });
  await flush();
  assert.match(root.textContent, /setting · new/);
  // BH-2379: the empty answer is the history's Empty copy, and the old rows never render.
  assert.match(root.textContent, /no changes recorded yet/);
  assert.ok(!all(root).some((n) => n.localName === 'table'), 'the previous record\'s rows never paint');
  mount(null, root);
});

test('C7: the SETTINGS tab is active on /config and /config/*, not on /configx', () => {
  const settings = NAV.find((n) => n.label === 'SETTINGS');
  assert.ok(settings);
  assert.equal(settings.match('/config'), true);
  assert.equal(settings.match('/config/setting/x'), true);
  assert.equal(settings.match('/settings'), true);
  assert.equal(settings.match('/configx'), false);
  assert.equal(NAV.filter((n) => n.match('/config')).length, 1, 'only one tab claims /config');
});

test('C8: /config is one click from the SETTINGS tab (a link on the SETTINGS page)', () => {
  const status = { scope: 'hub', projects: [], lanes: [] };
  const out = render(h(SettingsView, {
    tabs: tabsFrom(status), activeTab: 'hub', rows: [], status, error: null, loading: false, busy: null,
    note: null, actions: {}, accountActions: {}, dialog: null, onTab: () => {}, onReload: () => {}
  }));
  assert.match(out, /<a[^>]*href="\/config"[^>]*>ALL SETTINGS &amp; FLAGS →<\/a>/);
});
