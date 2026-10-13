import test from 'node:test';
import assert from 'node:assert/strict';
import { render } from 'preact-render-to-string';
import { h, render as mount } from 'preact';
import { flush } from './helpers/settle.js';

// BH-2567 (BH-2511.4): the Costs page's CAP HISTORY section over
// GET /api/coord/cost-cap-changes. The pure view is rendered with each load
// state as props; the wired section is mounted into a small fake DOM against a
// stubbed fetch, so the read, the KEY filter and "clear filter" go through the
// real api.js and lib/poll.js.

// The router reads window.location at first render; give SSR one.
globalThis.window = globalThis.window || {
  location: { pathname: '/costs', search: '' },
  dispatchEvent() {}, addEventListener() {}, removeEventListener() {},
  history: { pushState() {}, replaceState() {} }, scrollTo() {}
};
globalThis.confirm = () => { throw new Error('native confirm called'); };
globalThis.alert = () => { throw new Error('native alert called'); };
globalThis.prompt = () => { throw new Error('native prompt called'); };

const { CostCapHistorySection, CostCapHistoryView, loadChanges, LIMIT } = await import('../src/screens/CostCapHistory.js');
const { changeRows } = await import('../src/lib/cost-cap-changes.js');

const KEY = 'conf.cost-caps.default';
const change = (over) => ({
  id: 1, key: KEY, before_value: '50', after_value: '80', actor: 'operator@example.com',
  reason: 'busy week', at: '2026-09-01T10:00:00Z', ...over
});
const ROWS = [
  change({ id: 1, at: '2026-09-01T10:00:00Z' }),
  change({ id: 3, key: 'conf.cost-caps.project-3', at: '2026-09-03T10:00:00Z', before_value: null, reason: null }),
  change({ id: 2, at: '2026-09-02T10:00:00Z', after_value: '90' })
];
const loaded = (changes, truncated = false, key = null) => ({
  data: { key, res: { changes, truncated } }, error: null, loading: false, reload() {}
});
const view = (state, filterKey = null) =>
  render(h(CostCapHistoryView, { state, filterKey, onFilter() {}, onClear() {}, onRetry() {} }));

// ---------------------------------------------------------------- view ----

test('A1: loaded rows render one SortableTable with WHEN KEY BEFORE AFTER ACTOR REASON; null before/reason is —', () => {
  const out = view(loaded(ROWS));
  assert.match(out, /CAP HISTORY/);
  assert.match(out, /class="tablewrap/);
  const heads = [...out.matchAll(/<th(?:\s[^>]*)?>([\s\S]*?)<\/th>/g)].map((m) => m[1].replace(/<[^>]+>/g, '').replace(/[^A-Z]/g, ''));
  assert.deepEqual(heads, ['WHEN', 'KEY', 'BEFORE', 'AFTER', 'ACTOR', 'REASON']);
  const created = out.split('<tr').find((r) => r.includes('conf.cost-caps.project-3'));
  assert.ok(created, 'the created-cap row renders');
  assert.equal((created.match(/—/g) || []).length, 2, 'no before and no reason render as —');
  assert.doesNotMatch(out, />null</);
  assert.doesNotMatch(out, /no cap changes yet/);
});

test('A1b: an empty log renders "no cap changes yet" and no table', () => {
  const out = view(loaded([]));
  assert.match(out, /no cap changes yet/);
  assert.doesNotMatch(out, /<table/);
});

test('A2: default sort is WHEN descending', () => {
  const out = view(loaded(ROWS));
  const order = [...out.matchAll(/title="(2026-09-0\dT10:00:00Z)"/g)].map((m) => m[1].slice(0, 10));
  assert.deepEqual(order, ['2026-09-03', '2026-09-02', '2026-09-01']);
  const when = [...out.matchAll(/<th(\s[^>]*)?>([\s\S]*?)<\/th>/g)].find((m) => m[2].includes('WHEN'));
  assert.match(when[1], /aria-sort="descending"/);
});

test('A3: a failed read is an ErrorBox, never the empty copy; a malformed body is an error too', () => {
  const failed = view({ data: null, error: new Error('boom'), loading: false, reload() {} });
  assert.match(failed, /could not load/);
  assert.match(failed, /boom/);
  assert.match(failed, /RETRY/);
  assert.doesNotMatch(failed, /no cap changes yet/);

  const malformed = view({ data: { key: null, res: {} }, error: null, loading: false, reload() {} });
  assert.match(malformed, /unexpected response from \/api\/coord\/cost-cap-changes/);
  assert.doesNotMatch(malformed, /no cap changes yet/);

  // A refresh that fails after a good read keeps the rows AND says it failed.
  const stale = view({ ...loaded(ROWS), error: new Error('flaky') });
  assert.match(stale, /flaky/);
  assert.match(stale, /<table/);
});

test('A4: "showing the newest N" only when the body says truncated', () => {
  assert.match(view(loaded(ROWS.slice(0, 2), true)), /showing the newest 2/);
  assert.doesNotMatch(view(loaded(ROWS.slice(0, 2), false)), /showing the newest/);
});

test('A5: loading is a skeleton; a response for another key is loading, not the filtered table', () => {
  const loading = view({ data: null, error: null, loading: true, reload() {} });
  assert.match(loading, /class="skel"/);
  assert.doesNotMatch(loading, /<table/);
  assert.doesNotMatch(loading, /no cap changes yet/);

  const wrongKey = view(loaded(ROWS, false, 'conf.cost-caps.a'), 'conf.cost-caps.b');
  assert.match(wrongKey, /class="skel"/);
  assert.doesNotMatch(wrongKey, /<table/);
});

test('A7: an active filter shows its key and a "clear filter" control; the filtered empty copy names the key', () => {
  const out = view(loaded(ROWS.filter((r) => r.key === KEY), false, KEY), KEY);
  assert.match(out, new RegExp(`key: ${KEY}`));
  assert.match(out, /<button[^>]*>clear filter<\/button>/);
  assert.match(view(loaded([], false, KEY), KEY), new RegExp(`no cap changes for ${KEY} yet`));
  assert.doesNotMatch(view(loaded(ROWS)), /clear filter/);
});

test('changeRows: malformed only when changes is not an array; truncated only when the body says true', () => {
  assert.deepEqual(changeRows({ changes: ROWS, truncated: false }), { rows: ROWS, truncated: false, malformed: false });
  assert.equal(changeRows({ changes: [], truncated: true }).truncated, true);
  assert.equal(changeRows({ changes: [], truncated: 'yes' }).truncated, false);
  for (const bad of [null, undefined, {}, { changes: {} }, 'x']) assert.equal(changeRows(bad).malformed, true);
});

// ------------------------------------------------------------ the read ----

function stubFetch(answer = (url) => ({ changes: ROWS.filter((r) => !url.includes('key=') || url.includes(`key=${encodeURIComponent(KEY)}`) && r.key === KEY), truncated: false })) {
  const calls = [];
  globalThis.fetch = async (url) => {
    calls.push(String(url));
    const body = answer(String(url));
    return { ok: true, status: 200, text: async () => JSON.stringify(body) };
  };
  return calls;
}

test('A8: loadChanges sends key and limit and tags the answer with its key', async () => {
  const calls = stubFetch(() => ({ changes: [], truncated: false }));
  const tagged = await loadChanges('k');
  assert.equal(calls[0], '/api/coord/cost-cap-changes?key=k&limit=200');
  assert.deepEqual(tagged, { key: 'k', res: { changes: [], truncated: false } });
  const all = await loadChanges(null);
  assert.equal(all.key, null);
  assert.doesNotMatch(calls[1], /key=/);
  assert.equal(LIMIT, 200);
});

test('A9: the unfiltered read is /api/coord/cost-cap-changes?limit=200', async () => {
  const calls = stubFetch(() => ({ changes: [], truncated: false }));
  await loadChanges(null);
  assert.deepEqual(calls, ['/api/coord/cost-cap-changes?limit=200']);
});

// ---- mounted through the real CostCapHistorySection (D2) -------------------

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
const all = (n, out = []) => { out.push(n); n.childNodes.forEach((c) => all(c, out)); return out; };
const button = (root, text) => all(root).find((n) => n.localName === 'button' && n.textContent.trim() === text);
const fire = (el) => el.listeners.click.call(el, { type: 'click', target: el, currentTarget: el, preventDefault() {}, stopPropagation() {} });

test('A6: clicking a KEY in the mounted section re-reads with ?key=, and clear filter re-reads without it', async () => {
  const doc = installDom();
  const calls = stubFetch();
  const root = doc.createElement('div');
  mount(h(CostCapHistorySection, {}), root);
  try {
    await flush();
    assert.deepEqual(calls, ['/api/coord/cost-cap-changes?limit=200'], 'one read on mount');
    assert.match(root.textContent, /conf\.cost-caps\.project-3/);

    const keyCell = button(root, KEY);
    assert.ok(keyCell, 'the KEY cell is a button');
    fire(keyCell);
    await flush();
    assert.equal(calls.length, 2);
    assert.equal(calls[1], `/api/coord/cost-cap-changes?key=${encodeURIComponent(KEY)}&limit=200`);
    assert.match(root.textContent, new RegExp(`key: ${KEY}`));
    assert.doesNotMatch(root.textContent, /conf\.cost-caps\.project-3/, 'only the filtered key is shown');

    fire(button(root, 'clear filter'));
    await flush();
    assert.equal(calls.length, 3);
    assert.equal(calls[2], '/api/coord/cost-cap-changes?limit=200');
    assert.match(root.textContent, /conf\.cost-caps\.project-3/);
    assert.doesNotMatch(root.textContent, /clear filter/);
  } finally { mount(null, root); }
});
