// BH-4844 (Mission Control wave 2): the APPEARANCE screen at /settings/appearance.
//
// The pure view is rendered to a string; the screen itself is mounted through
// the real ROUTES table and matchRoute into a small fake DOM against a stubbed
// fetch, so the settings-row read goes through the real api.js and a click on
// USE goes through the real handler to localStorage and :root.

import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { h, render as mount } from 'preact';
import { flush } from './helpers/settle.js';
import { assertNoRawHeaders } from './legibility.bh-3558.js';

const store = new Map();
globalThis.window = globalThis.window || {
  location: { pathname: '/settings/appearance', search: '' },
  dispatchEvent() {}, addEventListener() {}, removeEventListener() {},
  history: { pushState() {}, replaceState() {} }, scrollTo() {}
};
const events = [];
window.dispatchEvent = (e) => { events.push(e); return true; };
window.localStorage = {
  getItem: (k) => (store.has(k) ? store.get(k) : null),
  setItem: (k, v) => { store.set(k, String(v)); },
  removeItem: (k) => { store.delete(k); }
};

const { ROUTES } = await import('../src/app.js');
const { matchRoute } = await import('../src/router.js');
const { AppearanceScreen, AppearanceView } = await import('../src/screens/Appearance.js');
const { LaneDetailScreen, SettingsView } = await import('../src/screens/Settings.js');
const { BUILTIN_THEMES } = await import('../src/theme/themes.js');
const { THEME_CHANGE_EVENT } = await import('../src/theme/tokens.js');
const { render } = await import('preact-render-to-string');

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const noop = () => {};

// ------------------------------------------------------------- fake DOM

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
  removeChild(n) { this.childNodes.splice(this.childNodes.indexOf(n), 1); n.parentNode = null; return n; }
  remove() { if (this.parentNode) this.parentNode.removeChild(this); }
  setAttribute(k, v) { this.attrs[k] = String(v); }
  removeAttribute(k) { delete this.attrs[k]; }
  getAttribute(k) { return k in this.attrs ? this.attrs[k] : null; }
  // preact names the event 'Click' here: 'onclick' is not a property of a fake node.
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
  const html = new FakeNode(1, 'html');
  html.props = new Map();
  html.style = { setProperty: (k, v) => html.props.set(k, v) };
  doc.documentElement = html;
  doc.metas = { 'color-scheme': new FakeNode(1, 'meta'), 'theme-color': new FakeNode(1, 'meta') };
  doc.querySelector = (sel) => doc.metas[(sel.match(/name="([^"]+)"/) || [])[1]] || null;
  globalThis.document = doc;
  return doc;
}
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

async function mountPath(p) {
  const doc = installDom();
  const hit = ROUTES.map(([pat, C]) => [matchRoute(pat, p), C]).find(([params]) => params);
  assert.ok(hit, `a route matches ${p}`);
  const el = doc.createElement('div');
  mounted.add(el);
  mount(h(hit[1], hit[0]), el);
  await flush();
  return { doc, el, C: hit[1], text: () => el.textContent };
}

const view = (over = {}) => render(h(AppearanceView, {
  activeId: 'mill', viewerId: null, fleet: { state: 'ok', id: null, hasRow: false, raw: null },
  saveFailed: false, onPick: noop, onClearPick: noop, ...over
}));

// -------------------------------------------------------------- tests

test('P1 /settings/appearance is APPEARANCE, and a real lane id still opens the lane', () => {
  const hit = (p) => ROUTES.find(([pat]) => matchRoute(pat, p));
  assert.equal(hit('/settings/appearance')[1], AppearanceScreen);
  assert.equal(hit('/settings/merge-conductor')[1], LaneDetailScreen);
});

test('P2 three preview cards, each wrapped in its own theme\'s tokens', () => {
  const out = view();
  const cards = [...out.matchAll(/<section class="theme-card[^"]*" data-theme-id="([^"]+)" style="([^"]*)"/g)];
  assert.deepEqual(cards.map((c) => c[1]), ['mill', 'paper', 'phosphor']);
  for (const [, id, style] of cards) {
    const t = BUILTIN_THEMES[id];
    assert.ok(style.includes(`--surface-0:${t.tokens['--surface-0']}`), `${id} card carries its own --surface-0`);
    assert.ok(style.includes(`--accent:${t.tokens['--accent']}`), `${id} card carries its own --accent`);
  }
  for (const name of ['Mill', 'Paper', 'Phosphor']) assert.match(out, new RegExp(`>${name}<`));
  for (const pill of ['OK', 'WARN', 'ERR', 'LIVE']) assert.match(out, new RegExp(`>${pill}<`));
});

test('P3 the active theme is pressed, the others are not; Mill says it is the default', () => {
  const out = view({ activeId: 'paper' });
  const pressed = [...out.matchAll(/<button[^>]*data-theme-pick="([^"]+)"[^>]*aria-pressed="(true|false)"|<button[^>]*aria-pressed="(true|false)"[^>]*data-theme-pick="([^"]+)"/g)]
    .map((m) => [m[1] || m[4], m[2] || m[3]]);
  assert.deepEqual(pressed, [['mill', 'false'], ['paper', 'true'], ['phosphor', 'false']]);
  assert.match(out, /Mill is the default\./);
});

test('P4 the fleet line names where the default came from and links to the row', () => {
  const none = view();
  assert.match(none, /Fleet default: <a [^>]*href="\/config\/setting\/ui\.theme\.default"[^>]*>Mill<\/a> \(no row\)/);
  const row = view({ fleet: { state: 'ok', id: 'phosphor', hasRow: true, raw: 'phosphor' }, activeId: 'phosphor' });
  assert.match(row, /Fleet default: <a [^>]*href="\/config\/setting\/ui\.theme\.default"[^>]*>Phosphor<\/a> \(settings row\)/);
  const bad = view({ fleet: { state: 'ok', id: null, hasRow: true, raw: 'neon' } });
  assert.match(bad, /\(the settings row says &quot;neon&quot;, which is not a theme\)/);
  const failed = view({ fleet: { state: 'error', id: 'paper', error: new Error('network unreachable') } });
  assert.match(failed, /Couldn.t read the settings row \(network unreachable\)/);
  assert.doesNotMatch(failed, /\(no row\)/);
  assert.match(view({ fleet: { state: 'loading', id: null } }), /Checking the settings row/);
  // The reset control only shows when there is a pick to clear.
  assert.doesNotMatch(none, /USE THE FLEET DEFAULT/);
  assert.match(view({ viewerId: 'phosphor', activeId: 'phosphor' }), /USE THE FLEET DEFAULT/);
  assert.match(view({ viewerId: 'phosphor', activeId: 'phosphor', saveFailed: true }), /Couldn.t save/);
});

test('P5 SETTINGS links to APPEARANCE', () => {
  const out = render(h(SettingsView, {
    tabs: [], activeTab: 'hub', rows: [], status: {}, error: null, loading: false, busy: null,
    note: null, actions: {}, dialog: null, onTab: noop, onReload: noop
  }));
  assert.match(out, /<a [^>]*href="\/settings\/appearance"[^>]*>APPEARANCE →<\/a>/);
});

test('P6 Appearance.js holds no colour of its own', () => {
  const src = fs.readFileSync(path.join(root, 'src', 'screens', 'Appearance.js'), 'utf8');
  assert.ok(src.length > 200);
  assert.doesNotMatch(src, /#[0-9a-fA-F]{3,8}\b|rgba?\(/);
});

test('P7 no raw field names in any header', () => {
  assertNoRawHeaders(view());
  assertNoRawHeaders(view({ viewerId: 'phosphor', activeId: 'phosphor' }));
});

test('P8 the mounted screen reads the row, and USE / fleet default repaint :root and persist', async () => {
  store.clear();
  events.length = 0;
  const calls = stubFetch(() => ({ key: 'ui.theme.default', setting: { key: 'ui.theme.default', value: 'mill-light' }, source: 'd1' }));
  const s = await mountPath('/settings/appearance');
  assert.equal(s.C, AppearanceScreen);
  // BH-4846: the screen also reads who this session writes as (SET AS FLEET
  // DEFAULT is gated on it) and every settings row (the custom themes).
  assert.deepEqual(calls, ['/api/coord/settings/ui.theme.default', '/api/coord/whoami', '/api/coord/settings']);
  assert.match(s.text(), /Fleet default: Paper \(settings row\)/);
  assert.equal(store.get('ui.theme.fleet'), 'paper');
  const click = (n) => n.listeners.Click.call(n, { type: 'Click' });
  const btn = (id) => all(s.el).find((n) => n.localName === 'button' && n.getAttribute('data-theme-pick') === id);
  assert.equal(btn('paper').getAttribute('aria-pressed'), 'true');

  click(btn('phosphor'));
  await flush();
  assert.equal(store.get('ui.theme'), 'phosphor');
  assert.equal(s.doc.documentElement.getAttribute('data-theme'), 'phosphor');
  assert.equal(s.doc.documentElement.props.get('--surface-0'), BUILTIN_THEMES.phosphor.tokens['--surface-0']);
  assert.equal(s.doc.metas['theme-color'].getAttribute('content'), BUILTIN_THEMES.phosphor.themeColor);
  assert.equal(btn('phosphor').getAttribute('aria-pressed'), 'true');
  assert.equal(btn('paper').getAttribute('aria-pressed'), 'false');
  assert.equal(events.at(-1).type, THEME_CHANGE_EVENT);
  assert.deepEqual(events.at(-1).detail, { id: 'phosphor' });

  const reset = all(s.el).find((n) => n.localName === 'button' && /USE THE FLEET DEFAULT/.test(n.textContent));
  assert.ok(reset, 'a reset control once there is a pick');
  click(reset);
  await flush();
  assert.equal(store.has('ui.theme'), false);
  assert.equal(s.doc.documentElement.getAttribute('data-theme'), 'paper');
  assert.equal(btn('paper').getAttribute('aria-pressed'), 'true');
});
