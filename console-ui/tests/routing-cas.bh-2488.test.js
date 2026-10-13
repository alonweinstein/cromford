import test, { afterEach } from 'node:test';
import assert from 'node:assert/strict';
import { h, render as mount } from 'preact';
import { onRequest } from '../functions/api/coord/[[path]].js';
import { haltAction } from '../src/lib/routing.js';
import { RoutingPanel } from '../src/screens/RoutingPanel.js';
import { flush } from './helpers/settle.js';

// BH-2488: the console's HALT write is a compare-and-swap. The proxy forwards
// the updated_at of the row it read as expected_updated_at; the worker answers
// 409 {error, routing} when the row moved in between (BH-2459). The UI shows
// "routing changed underneath you, try again", reloads the row, and never
// sends a second PUT on its own.

const JOBS = 'https://harness-jobs.operator.workers.dev';
const SECRET = 'test-harness-secret';
const CONFLICT = /routing changed underneath you, try again/;

const ROW = { project: 'project-3', builder: 'pool', pool_app: 'bh-pool-project-3', halted: 0, updated_at: '2026-09-25T10:00:00Z' };
const MOVED = { project: 'project-3', builder: 'local', pool_app: null, halted: 1, updated_at: '2026-09-25T10:00:07Z' };
const err = (status, message) => Object.assign(new Error(message), { status });

// ---- proxy: the worker's 409 passes through untouched -------------------------

test('P-CAS: a worker 409 reaches the browser with its status and body intact, after one read and one PUT', async () => {
  const seen = [];
  const real = globalThis.fetch;
  const reply = (status, body) => new Response(JSON.stringify(body), { status, headers: { 'content-type': 'application/json' } });
  globalThis.fetch = async (input, init = {}) => {
    const u = typeof input === 'string' ? input : input.url;
    if (u.startsWith('https://harness-console.operator.workers.dev')) return new Response('', { status: 200 });
    seen.push({ method: init.method || 'GET', url: u, body: init.body });
    if ((init.method || 'GET') === 'GET') return reply(200, { routing: ROW });
    return reply(409, { error: 'routing changed underneath you', routing: MOVED });
  };
  try {
    const res = await onRequest({
      request: new Request('https://console.example.pages.dev/api/coord/routing', {
        method: 'PUT', headers: { cookie: 'dash=cas-p', 'content-type': 'application/json' },
        body: JSON.stringify({ project: 'project-3', halted: 1, reason: 'drill' })
      }),
      env: { HARNESS_SECRET: SECRET },
      params: { path: ['routing'] }
    });
    assert.equal(res.status, 409);
    assert.deepEqual(await res.json(), { error: 'routing changed underneath you', routing: MOVED });
    assert.deepEqual(seen.map((s) => [s.method, s.url]), [
      ['GET', `${JOBS}/api/routing/project-3`],
      ['PUT', `${JOBS}/api/routing`]
    ]);
    assert.equal(JSON.parse(seen[1].body).expected_updated_at, ROW.updated_at);
  } finally { globalThis.fetch = real; }
});

// ---- lib: the 409 is its own outcome, and there is no retry -------------------

test('U1: haltAction on a 409 is ok:false with the conflict copy and exactly one PUT; other errors keep their text', async () => {
  let puts = 0;
  const apiObj = {
    routing: async () => ({ routing: ROW }),
    putRouting: async () => { puts += 1; throw err(409, 'routing changed underneath you'); }
  };
  const r = await haltAction({ apiObj, project: 'project-3', target: true, reason: 'drill' });
  assert.equal(r.ok, false);
  assert.equal(r.conflict, true);
  assert.match(r.text, CONFLICT);
  assert.match(r.text, /^HALT refused/);
  assert.equal(puts, 1, 'a 409 is never retried');

  let other = 0;
  const r2 = await haltAction({
    apiObj: { routing: async () => ({ routing: ROW }), putRouting: async () => { other += 1; throw err(400, 'valid project required'); } },
    project: 'project-3', target: true, reason: 'drill'
  });
  assert.deepEqual(r2, { ok: false, text: 'HALT refused — valid project required' });
  assert.equal(other, 1);
});

// ---- the real RoutingPanel, mounted: the reload runs on a 409 -----------------

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

const all = (n, out = []) => { out.push(n); n.childNodes.forEach((c) => all(c, out)); return out; };
const byLabel = (root, label) => all(root).find((n) => n.attrs && n.attrs['aria-label'] === label);
const button = (root, text) => all(root).find((n) => n.localName === 'button' && n.textContent.trim() === text);
const ev = (el, type) => ({ type, target: el, currentTarget: el, preventDefault() {}, stopPropagation() {} });
const click = (el) => el.listeners.click.call(el, ev(el, 'click'));
const dialogOf = (root) => all(root).find((n) => n.attrs && n.attrs.role === 'dialog');

const mounted = [];
afterEach(() => { while (mounted.length) mount(null, mounted.pop()); });

test('U2: the mounted panel shows the conflict copy on a 409, re-reads the row, renders it as it is now, and PUTs once', async () => {
  const doc = installDom();
  const calls = fakeFetch({
    // initial load, haltAction's fresh re-read, then the reload after the 409
    '/api/coord/routing/': [[200, { routing: ROW }], [200, { routing: ROW }], [200, { routing: MOVED }]],
    '/api/coord/settings/routing_rows': [200, { key: 'routing_rows', setting: { key: 'routing_rows', value: 'on' }, source: 'settings' }],
    '/api/coord/routing-changes': [200, { changes: [], truncated: false }],
    '/api/coord/routing': [409, { error: 'routing changed underneath you', routing: MOVED }]
  });
  const root = doc.createElement('div');
  mount(h(RoutingPanel, { project: 'project-3' }), root);
  mounted.push(root);
  await flush();
  assert.equal(byLabel(root, 'HALT').attrs['aria-pressed'], 'false');

  click(byLabel(root, 'HALT'));
  await flush();
  const input = byLabel(root, 'reason for this routing change');
  input.value = 'drill';
  input.listeners.input.call(input, ev(input, 'input'));
  click(button(dialogOf(root), 'HALT'));
  await flush();

  const puts = calls.filter((c) => c.method === 'PUT');
  assert.equal(puts.length, 1, 'a 409 is never retried');
  assert.match(root.textContent, CONFLICT);
  const after = calls.slice(calls.indexOf(puts[0]) + 1).map((c) => c.url);
  assert.ok(after.includes('/api/coord/routing/project-3'), `the row is re-read after the 409: ${after.join(' ')}`);
  // The toggle shows the row as the worker holds it now, not the stale one.
  assert.equal(byLabel(root, 'HALT').attrs['aria-pressed'], 'true');
  assert.match(root.textContent, /local/);
});
