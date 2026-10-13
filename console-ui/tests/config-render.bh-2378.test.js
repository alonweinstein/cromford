import test from 'node:test';
import assert from 'node:assert/strict';
import { h, render as mount } from 'preact';
import { flush } from './helpers/settle.js';

// BH-2378 (BH-2330.3): the /config list screen. ConfigView is rendered
// server-side from props; the modals and writes are driven through the routed
// ConfigScreen (the real ROUTES table and matchRoute) in a small fake DOM
// against a stubbed fetch, so every read and write goes through the real api.js.

globalThis.window = globalThis.window || {
  location: { pathname: '/config', search: '' },
  dispatchEvent() {}, addEventListener() {}, removeEventListener() {},
  history: { pushState() {}, replaceState() {} }, scrollTo() {}
};

const { ConfigView } = await import('../src/screens/Config.js');
const { ROUTES } = await import('../src/app.js');
const { matchRoute } = await import('../src/router.js');
const { render } = await import('preact-render-to-string');

// ---------------------------------------------------------------- fixtures
// determinism: ok-file clock-now-js the one clock read is NOW below, captured
// once at load. Every fixture timestamp is AT, a fixed 5-minute offset from it
// (the screen renders "5m" ago against the real clock, so the anchor must be
// real); no case asserts a calendar date.
const NOW = Date.now();
const AT = new Date(NOW - 5 * 60000).toISOString();
const s = (key, value = '1', actor = 'seed') => ({ key, value, note: null, actor, updated_at: AT });
const SETTINGS = [
  s('routing_rows'), s('lib.call-guard.call_guard_stages'), s('merge-conductor.mode', 'auto', 'merge-conductor'),
  s('lane.merge-conductor.mc_max_prs', '12'), s('hub.promote_enabled'), s('gh.quota.reserve', '600', 'hub-1')
];
const NAMED = ['gh.quota.reserve', 'hub.promote_enabled', 'merge-conductor.mode', 'routing_rows'];
const FLAGS = [
  { name: 'pause-all', active: 0, actor: 'console', reason: 'drill over', updated_at: AT },
  { name: 'paused-project-3', active: 1, actor: 'project-3', reason: 'deploy', updated_at: AT }
];
const CHANGES = [
  { id: 2, kind: 'cost_cap', name: 'conf.cost-caps.day', actor: 'console', reason: 'raise', at: AT },
  { id: 1, kind: 'setting', name: 'gh.quota.reserve', actor: 'hub-1', reason: null, at: AT }
];
const ok = (data) => ({ data, error: null, loading: false, reload() {} });
const view = (over = {}) => render(h(ConfigView, {
  settings: ok({ settings: SETTINGS }), flags: ok({ flags: FLAGS }),
  changes: { loading: false, error: null, data: { changes: CHANGES, truncated: false } },
  filter: '', showLane: false, onFilter() {}, onShowLane() {}, onEdit() {}, onToggle() {}, busy: false, note: null,
  ...over
}));
const count = (hay, re) => (hay.match(re) || []).length;

test('R1: every non-lane setting links to its history; there is no create-key control', () => {
  const out = view();
  for (const k of NAMED) assert.match(out, new RegExp(`<a[^>]*href="/config/setting/${k}"`), k);
  assert.doesNotMatch(out, /lane\.merge-conductor\.mc_max_prs/);
  assert.doesNotMatch(out, /NEW KEY|ADD KEY|>ADD</i);
  assert.match(out, /ALL SETTINGS &amp; FLAGS/);
});

test('R1b: RECENT CHANGES rows of any kind link to /config/<kind>/<name>; the heading says newest 50', () => {
  const out = view();
  assert.match(out, /RECENT CHANGES[^<]*newest 50/);
  assert.match(out, /<a[^>]*href="\/config\/cost_cap\/conf.cost-caps.day"/);
  assert.match(out, /<a[^>]*href="\/config\/setting\/gh.quota.reserve"[^>]*>gh.quota.reserve/);
  assert.match(out, /2 recent changes/);
  assert.doesNotMatch(out, /showing the newest 50/);
  const many = Array.from({ length: 60 }, (_, i) => ({ ...CHANGES[1], id: i, name: `k${i}` }));
  const t = view({ changes: { loading: false, error: null, data: { changes: many, truncated: false } } });
  assert.match(t, /showing the newest 50/);
  assert.equal(count(t, /href="\/config\/setting\/k\d+"/g), 50);
});

test('R2: EDIT only on non-lane rows; with showLane a lane row links to its lane page and has no EDIT', () => {
  const out = view();
  assert.equal(count(out, />EDIT</g), NAMED.length);
  const lane = view({ showLane: true });
  assert.equal(count(lane, />EDIT</g), NAMED.length, 'lane/lib rows never get EDIT');
  assert.match(lane, /<a[^>]*href="\/settings\/merge-conductor"[^>]*>edit on lane page<\/a>/);
  assert.match(lane, /<a[^>]*href="\/settings"[^>]*>edit on lane page<\/a>/);
  assert.match(lane, /<input[^>]*type="checkbox"[^>]*checked/);
  assert.doesNotMatch(out, /<input[^>]*type="checkbox"[^>]*checked/, 'show lane knobs is off by default');
});

test('R3: flags render ON/OFF, a TURN ON/TURN OFF button and a history link', () => {
  const out = view();
  assert.match(out, /<a[^>]*href="\/config\/flag\/pause-all"/);
  assert.match(out, /<a[^>]*href="\/config\/flag\/paused-project-3"/);
  assert.equal(count(out, />TURN ON</g), 1);
  assert.equal(count(out, />TURN OFF</g), 1);
  assert.match(out, />ON</);
  assert.match(out, />OFF</);
});

test('R5: a failed poll keeps the rows under an ErrorBox; zero rows is Empty; malformed is a failure', () => {
  const kept = view({ settings: { data: { settings: SETTINGS }, error: new Error('network unreachable'), loading: false, reload() {} } });
  assert.match(kept, /could not load — <b>network unreachable/);
  assert.match(kept, /href="\/config\/setting\/gh.quota.reserve"/);

  const empty = view({ settings: ok({ settings: [] }), flags: ok({ flags: [] }), changes: { loading: false, error: null, data: { changes: [], truncated: false } } });
  assert.match(empty, /no settings rows/);
  assert.match(empty, /no flags/);
  assert.match(empty, /No changes recorded yet\./);
  assert.doesNotMatch(empty, /could not load/);

  const nomatch = view({ filter: 'zzz' });
  assert.match(nomatch, /no key matches &#39;zzz&#39;|no key matches 'zzz'/);

  const bad = view({ settings: ok({ error: 'x' }), flags: ok({ error: 'y' }) });
  assert.equal(count(bad, /could not load/g), 2);
  assert.doesNotMatch(bad, /no settings rows|no flags/);

  const first = view({ settings: { data: null, error: null, loading: true, reload() {} } });
  assert.match(first, /class="skel"/);
});

test('R6: every table has sortable aria-sort headers inside .tablewrap; the filter is a knob__input in a wrapping bar', () => {
  const out = view();
  assert.equal(count(out, /class="tablewrap/g), 3);
  assert.ok(count(out, /aria-sort="(ascending|descending|none)"/g) >= 3 * 4);
  assert.match(out, /<input[^>]*class="knob__input"[^>]*aria-label="filter by key"|<input[^>]*aria-label="filter by key"[^>]*class="knob__input"/);
  assert.match(out, /display:flex;flex-wrap:wrap/);
  // RECENT CHANGES sorts by AT, newest first.
  assert.match(out, /<th aria-sort="descending"[^>]*><button[^>]*>\s*AT/);
});

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
    const sib = this.parentNode.childNodes;
    return sib[sib.indexOf(this) + 1] || null;
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
  focus() { globalThis.document.activeElement = this; }
  get textContent() { return this.nodeType === 3 ? String(this.data) : this.childNodes.map((c) => c.textContent).join(''); }
  // Only the two selectors Modal.js asks for.
  querySelectorAll(sel) {
    const tags = sel.split(',').map((x) => x.trim().split(/\s+/).pop());
    const within = sel.includes('.modal__body') ? all(this).filter((n) => /\bmodal__body\b/.test(n.attrs.class || '')) : [this];
    return within.flatMap((r) => all(r).slice(1)).filter((n) => tags.includes(n.localName));
  }
  querySelector(sel) { return this.querySelectorAll(sel)[0] || null; }
}

function installDom() {
  const doc = new FakeNode(9, '#document');
  doc.createElement = (t) => new FakeNode(1, t);
  doc.createElementNS = (_, t) => new FakeNode(1, t);
  doc.createTextNode = (d) => new FakeNode(3, null, d);
  doc.hidden = false;
  doc.activeElement = null;
  globalThis.document = doc;
  return doc;
}
const all = (n, out = []) => { out.push(n); n.childNodes.forEach((c) => all(c, out)); return out; };
// Preact registers `onClick` as `Click` when the node has no `onclick` property,
// and its proxy looks the handler up by the event's own type.
const fire = (node, type, extra = {}) => {
  const key = Object.keys(node.listeners).find((k) => k.toLowerCase() === type);
  assert.ok(key, `a ${type} listener on <${node.localName}>`);
  return node.listeners[key].call(node, { type: key, target: node, currentTarget: node, button: 0, preventDefault() {}, ...extra });
};
const buttons = (root, label) => all(root).filter((n) => n.localName === 'button' && n.textContent.trim() === label);
const byLabel = (root, label) => all(root).find((n) => n.localName === 'input' && n.attrs['aria-label'] === label);
const typeInto = (node, v) => { node.value = v; fire(node, 'input'); };
const confirmBtn = (root) => {
  const actions = all(root).find((n) => /\bmodal__actions\b/.test(n.attrs.class || ''));
  return actions && actions.childNodes.filter((n) => n.localName === 'button').pop();
};
const disabled = (n) => n.getAttribute('disabled') !== null && n.getAttribute('disabled') !== 'false';

// Every GET answers from the fixtures; a PUT answers what `put` says.
function stubFetch({ put = () => [200, { ok: true }] } = {}) {
  const calls = [];
  globalThis.fetch = async (url, init = {}) => {
    const u = String(url);
    const method = init.method || 'GET';
    calls.push({ url: u, method, body: init.body ? JSON.parse(init.body) : null });
    let status = 200; let body;
    if (method !== 'GET') [status, body] = put(u, init);
    else if (u.startsWith('/api/coord/settings')) body = { settings: SETTINGS };
    else if (u.startsWith('/api/coord/flags')) body = { flags: FLAGS };
    else if (u.startsWith('/api/coord/config-changes')) body = { changes: CHANGES, truncated: false };
    else body = {};
    return { ok: status >= 200 && status < 300, status, text: async () => JSON.stringify(body) };
  };
  return calls;
}

async function mountConfig() {
  const doc = installDom();
  const hit = ROUTES.map(([p, C]) => [matchRoute(p, '/config'), C]).find(([params]) => params);
  assert.ok(hit, 'a route matches /config');
  const root = doc.createElement('div');
  const vnode = () => h(hit[1], hit[0]);
  mount(vnode(), root);
  await flush();
  return { root, text: () => root.textContent, rerender: () => mount(vnode(), root), unmount: () => mount(null, root) };
}

// The EDIT button on one settings row.
const editOn = (root, key) => {
  const row = all(root).find((n) => n.localName === 'tr' && n.childNodes[0] && n.childNodes[0].textContent === key);
  assert.ok(row, `a row for ${key}`);
  return all(row).find((n) => n.localName === 'button' && n.textContent.trim() === 'EDIT');
};

test('R4: EDIT and TURN ON/OFF open in-app modals whose confirm is blocked until value and reason are valid', async () => {
  const calls = stubFetch();
  const c = await mountConfig();
  assert.ok(calls.some((x) => x.url === '/api/coord/config-changes?limit=50'));
  assert.ok(calls.some((x) => x.url === '/api/coord/settings'));
  assert.ok(calls.some((x) => x.url === '/api/coord/flags'));

  fire(editOn(c.root, 'gh.quota.reserve'), 'click');
  await flush();
  const value = byLabel(c.root, 'value');
  const reason = byLabel(c.root, 'reason');
  assert.ok(value && reason, 'the EDIT modal has a value and a reason input');
  assert.equal(value.getAttribute('value') ?? value.value, '600', 'value is prefilled');
  assert.match(c.text(), /last written by hub-1 5m/);
  assert.ok(disabled(confirmBtn(c.root)), 'confirm starts blocked');
  assert.equal(globalThis.document.activeElement, value, 'focus starts on the value field');

  typeInto(reason, 'raise the reserve');
  await flush();
  assert.ok(!disabled(confirmBtn(c.root)), 'a valid value and reason enable confirm');
  typeInto(value, '   ');
  await flush();
  assert.ok(disabled(confirmBtn(c.root)), 'a blank value blocks again');
  assert.match(c.text(), /value is required/);
  typeInto(value, '700');
  typeInto(reason, '');
  await flush();
  assert.ok(disabled(confirmBtn(c.root)), 'clearing the reason blocks again');
  assert.match(c.text(), /reason is required/);
  typeInto(reason, 'x'.repeat(513));
  await flush();
  assert.ok(disabled(confirmBtn(c.root)), 'an over-long reason blocks');

  // CANCEL closes with no write.
  fire(buttons(c.root, 'CANCEL')[0], 'click');
  await flush();
  assert.equal(byLabel(c.root, 'reason'), undefined);
  assert.ok(!calls.some((x) => x.method === 'PUT'));

  fire(buttons(c.root, 'TURN OFF')[0], 'click');
  await flush();
  assert.equal(byLabel(c.root, 'value'), undefined, 'a toggle asks for no value');
  const why = byLabel(c.root, 'reason');
  assert.ok(why, 'the toggle modal has a reason input');
  assert.match(c.text(), /last written by project-3 5m/);
  assert.ok(disabled(confirmBtn(c.root)));
  typeInto(why, 'deploy done');
  await flush();
  assert.ok(!disabled(confirmBtn(c.root)));
  fire(buttons(c.root, 'CANCEL')[0], 'click');
  await flush();
  assert.ok(!calls.some((x) => x.method === 'PUT'));
  c.unmount();
});

test('R4b: a re-render mid-typing (a poll) keeps the typed values and focus', async () => {
  stubFetch();
  const c = await mountConfig();
  fire(editOn(c.root, 'gh.quota.reserve'), 'click');
  await flush();
  const reason = byLabel(c.root, 'reason');
  reason.focus();
  typeInto(byLabel(c.root, 'value'), '650');
  typeInto(reason, 'half typed');
  await flush();
  c.rerender();
  await flush();
  assert.equal(byLabel(c.root, 'reason'), reason, 'the same input node');
  assert.equal(reason.value, 'half typed');
  assert.equal(byLabel(c.root, 'value').value, '650');
  assert.equal(globalThis.document.activeElement, reason);
  assert.ok(!disabled(confirmBtn(c.root)));
  c.unmount();
});

test('R7: a refused write shows the worker error and no success; a 200 says what was set and re-reads', async () => {
  let calls = stubFetch({ put: () => [400, { error: 'value must be non-empty' }] });
  let c = await mountConfig();
  fire(editOn(c.root, 'gh.quota.reserve'), 'click');
  await flush();
  typeInto(byLabel(c.root, 'value'), ' 700 ');
  typeInto(byLabel(c.root, 'reason'), 'raise');
  await flush();
  fire(confirmBtn(c.root), 'click');
  await flush();
  const put = calls.find((x) => x.method === 'PUT');
  assert.equal(put.url, '/api/coord/settings');
  assert.deepEqual(put.body, { key: 'gh.quota.reserve', value: '700', reason: 'raise', actor: 'console' });
  assert.match(c.text(), /refused: value must be non-empty/);
  assert.doesNotMatch(c.text(), /set to/);
  assert.ok(!buttons(c.root, 'EDIT').some(disabled), 'busy clears after a refusal');
  c.unmount();

  calls = stubFetch();
  c = await mountConfig();
  fire(editOn(c.root, 'gh.quota.reserve'), 'click');
  await flush();
  typeInto(byLabel(c.root, 'value'), '700');
  typeInto(byLabel(c.root, 'reason'), 'raise');
  await flush();
  const before = calls.length;
  fire(confirmBtn(c.root), 'click');
  await flush();
  assert.match(c.text(), /gh\.quota\.reserve set to 700/);
  assert.doesNotMatch(c.text(), /refused/);
  const after = calls.slice(before).filter((x) => x.method === 'GET').map((x) => x.url);
  assert.ok(after.includes('/api/coord/settings'), 're-reads settings');
  assert.ok(after.includes('/api/coord/flags'), 're-reads flags');
  assert.ok(after.includes('/api/coord/config-changes?limit=50'), 're-reads the change log');

  // A flag toggle sends the flipped state with its reason.
  fire(buttons(c.root, 'TURN ON')[0], 'click');
  await flush();
  typeInto(byLabel(c.root, 'reason'), 'resume');
  await flush();
  fire(confirmBtn(c.root), 'click');
  await flush();
  const flagPut = calls.filter((x) => x.method === 'PUT').pop();
  assert.equal(flagPut.url, '/api/coord/flags');
  assert.deepEqual(flagPut.body, { name: 'pause-all', active: 1, actor: 'console', reason: 'resume' });
  assert.match(c.text(), /pause-all turned on/);
  c.unmount();
});

test('R7b: one busy latch; while a write is in flight every EDIT and toggle is disabled', async () => {
  let release;
  stubFetch({ put: () => { throw new Error('unused'); } });
  const real = globalThis.fetch;
  globalThis.fetch = async (url, init = {}) => {
    if ((init.method || 'GET') === 'PUT') {
      await new Promise((r) => { release = r; });
      return { ok: true, status: 200, text: async () => '{"ok":true}' };
    }
    return real(url, init);
  };
  const c = await mountConfig();
  fire(editOn(c.root, 'gh.quota.reserve'), 'click');
  await flush();
  typeInto(byLabel(c.root, 'reason'), 'raise');
  await flush();
  fire(confirmBtn(c.root), 'click');
  await flush();
  assert.ok(buttons(c.root, 'EDIT').length > 0);
  assert.ok(buttons(c.root, 'EDIT').every(disabled), 'every EDIT is disabled while busy');
  assert.ok([...buttons(c.root, 'TURN ON'), ...buttons(c.root, 'TURN OFF')].every(disabled));
  release();
  await flush();
  assert.ok(!buttons(c.root, 'EDIT').some(disabled));
  c.unmount();
});
