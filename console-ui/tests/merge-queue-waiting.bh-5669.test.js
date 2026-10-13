import test from 'node:test';
import assert from 'node:assert/strict';
import { h, render as mount } from 'preact';
import { flush } from './helpers/settle.js';

// BH-5669 (BH-5008 child 3): the line of PRs waiting to be batched on
// /merge-queue. MergeQueueWaiting is MOUNTED on a small DOM against a stubbed
// api.mergeQueueLive, and its headers are clicked through the real
// SortableTable.

globalThis.window = globalThis.window || {
  location: { pathname: '/merge-queue', search: '' },
  dispatchEvent() {}, addEventListener() {}, removeEventListener() {},
  history: { pushState() {}, replaceState() {} }, scrollTo() {},
  localStorage: { getItem() { return null; }, setItem() {} }
};

const { api } = await import('../src/api.js');
const { MergeQueueWaiting } = await import('../src/ui/merge-queue-waiting.js');

class FakeNode {
  constructor(nodeType, name, data) {
    this.nodeType = nodeType; this.localName = name; this.nodeName = name ? name.toUpperCase() : '#text';
    this.data = data; this.childNodes = []; this.parentNode = null; this.attrs = {}; this.style = {}; this.listeners = {};
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
  addEventListener(t, fn) { this.listeners[t] = fn; }
  removeEventListener(t) { delete this.listeners[t]; }
  get textContent() { return this.nodeType === 3 ? String(this.data) : this.childNodes.map((c) => c.textContent).join(''); }
}
const all = (n, tag, out = []) => {
  if (n.localName === tag) out.push(n);
  n.childNodes.forEach((c) => all(c, tag, out));
  return out;
};

async function mountWith(body) {
  let calls = 0;
  const realApi = api.mergeQueueLive;
  api.mergeQueueLive = async () => { calls += 1; if (body instanceof Error) throw body; return body; };
  const prevDoc = globalThis.document;
  const doc = new FakeNode(9, '#document');
  doc.createElement = (t) => new FakeNode(1, t);
  doc.createElementNS = (_, t) => new FakeNode(1, t);
  doc.createTextNode = (d) => new FakeNode(3, null, d);
  globalThis.document = doc;
  const root = doc.createElement('div');
  mount(h(MergeQueueWaiting, { project: null }), root);
  await flush();
  const done = () => { mount(null, root); api.mergeQueueLive = realApi; globalThis.document = prevDoc; };
  return { root, done, calls: () => calls };
}

const R = 'Example-Org/example-repo';
const R2 = 'Another-Org/b-repo';
const W = (pr, position, o = {}) => ({ repo: R, pr, position, at: `2026-10-09T03:0${position % 10}:00Z`, key: null, ...o });
const BODY = (waiting, extra = {}) => ({ batches: [], waiting, prs: {}, as_of: '2026-10-09T03:10:00Z', complete: true, ...extra });
const bodyRows = (root) => all(all(root, 'tbody')[0] || root, 'tr').map((tr) => all(tr, 'td').map((td) => td.textContent.trim()));
const header = (root, label) => all(root, 'th').find((th) => th.textContent.trim().startsWith(label));
const click = async (th) => {
  const btn = all(th, 'button')[0];
  // preact registers the handler as 'Click' on a node with no onclick property.
  const type = btn.listeners.click ? 'click' : 'Click';
  btn.listeners[type].call(btn, { type, target: btn, currentTarget: btn, preventDefault() {} });
  await flush();
};

test('W1 the waiting line renders in position order whatever the payload order', async () => {
  const m = await mountWith(BODY([W(201, 3), W(202, 1), W(203, 2)]));
  try {
    assert.match(m.root.textContent, /Waiting to be batched/i);
    assert.deepEqual(bodyRows(m.root).map((r) => r[0]), ['#1', '#2', '#3']);
    assert.deepEqual(bodyRows(m.root).map((r) => r[1]), ['#202', '#203', '#201']);
  } finally { m.done(); }
});

test('W2 every header sorts: repo asc then desc with aria-sort; position is numeric (9 before 10)', async () => {
  const m = await mountWith(BODY([W(210, 10), W(209, 9, { repo: R2 }), W(201, 1)]));
  try {
    assert.deepEqual(bodyRows(m.root).map((r) => r[0]), ['#1', '#9', '#10']);
    assert.equal(header(m.root, 'POSITION').getAttribute('aria-sort'), 'ascending');
    await click(header(m.root, 'REPO'));
    assert.deepEqual(bodyRows(m.root).map((r) => r[2]), [R2, R, R]);
    assert.equal(header(m.root, 'REPO').getAttribute('aria-sort'), 'ascending');
    await click(header(m.root, 'REPO'));
    assert.deepEqual(bodyRows(m.root).map((r) => r[2]), [R, R, R2]);
    assert.equal(header(m.root, 'REPO').getAttribute('aria-sort'), 'descending');
    for (const label of ['PR', 'QUEUED AT']) assert.ok(all(header(m.root, label), 'button').length, `${label} sorts`);
    await click(header(m.root, 'POSITION'));
    assert.deepEqual(bodyRows(m.root).map((r) => r[0]), ['#1', '#9', '#10']);
  } finally { m.done(); }
});

test('W3 each PR links to GitHub; a row with a ticket key also links to /t/<key>', async () => {
  const m = await mountWith(BODY([W(201, 1, { key: 'BH-201' }), W(202, 2)]));
  try {
    const hrefs = all(m.root, 'a').map((a) => a.getAttribute('href'));
    assert.ok(hrefs.includes(`https://github.com/${R}/pull/201`));
    assert.ok(hrefs.includes(`https://github.com/${R}/pull/202`));
    assert.ok(hrefs.includes('/t/BH-201'));
    assert.equal(hrefs.filter((x) => x.startsWith('/t/')).length, 1);
  } finally { m.done(); }
});

test('W4 a load error with no data is the error box, never an empty line; complete:false says so', async () => {
  const e = await mountWith(new Error('http_503'));
  try {
    assert.match(e.root.textContent, /could not load/);
    assert.match(e.root.textContent, /http_503/);
  } finally { e.done(); }
  const inc = await mountWith(BODY([W(201, 1)], { complete: false }));
  try { assert.match(inc.root.textContent, /List may be incomplete/); } finally { inc.done(); }
  const full = await mountWith(BODY([W(201, 1)]));
  try { assert.doesNotMatch(full.root.textContent, /incomplete/); } finally { full.done(); }
  const empty = await mountWith(BODY([]));
  try { assert.equal(empty.root.textContent, ''); } finally { empty.done(); }
});
