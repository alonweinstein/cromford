import test, { afterEach } from 'node:test';
import assert from 'node:assert/strict';
import { h, render as mount } from 'preact';
import { trainCells, trainsCapped, TRAINS_SHOWN } from '../src/lib/merge-trains-panel.js';
import MergeTrainsPanel from '../src/screens/MergeTrainsPanel.js';
import { flush } from './helpers/settle.js';

// BH-3153 (BH-2510.3): the read-only MERGE TRAINS table in the QUEUES section
// of /p/<project>. Row shape from worker/jobs/src/routes/merge-trains.js:
// train_pr INTEGER|null, members csv|null, member_count INTEGER|null.

test('trainCells: a train PR links to /pr/<project>/<n>', () => {
  const c = trainCells({ train_pr: 42, members: '7,8' }, 'cromford');
  assert.equal(c.prHref, '/pr/cromford/42');
  assert.equal(c.prLabel, '#42');
  assert.equal(trainCells({ train_pr: 9 }, 'a b/c').prHref, '/pr/a%20b%2Fc/9');
});

test('trainCells: no train PR is plain text, never a link to /pr/x/0', () => {
  for (const v of [null, undefined, 0, '', ' ', 'abc', -3, 1.5]) {
    const c = trainCells({ train_pr: v }, 'cromford');
    assert.equal(c.prHref, null, `train_pr=${JSON.stringify(v)}`);
    assert.equal(c.prLabel, '—');
  }
});

test('trainCells: the members summary handles an empty list and a long one', () => {
  for (const v of [null, undefined, '', ' , ']) {
    const c = trainCells({ members: v }, 'cromford');
    assert.equal(c.membersSummary, 'none', `members=${JSON.stringify(v)}`);
    assert.deepEqual(c.members, []);
  }
  const c = trainCells({ members: '1,2,3,4,5' }, 'cromford');
  assert.equal(c.membersSummary, '#1, #2, #3 +2 more');
  assert.deepEqual(c.members.map((m) => m.href), [1, 2, 3, 4, 5].map((n) => `/pr/cromford/${n}`));
  assert.equal(trainCells({ members: '4,5' }, 'p').membersSummary, '#4, #5');
});

test('trainCells: a non-numeric member token is dropped', () => {
  assert.deepEqual(trainCells({ members: '12, x,15' }, 'p').members.map((m) => m.number), [12, 15]);
});

test('trainsCapped: 50 rows is capped, 49 is not', () => {
  assert.equal(TRAINS_SHOWN, 50);
  const rows = (n) => Array.from({ length: n }, (_, i) => ({ branch: `b${i}` }));
  assert.equal(trainsCapped(rows(50)), true);
  assert.equal(trainsCapped(rows(49)), false);
});

// ---- the component, mounted into a minimal DOM (queue-panel.bh-2510 pattern) ----
class FakeNode {
  constructor(nodeType, name, data) {
    Object.assign(this, { nodeType, localName: name, nodeName: name ? name.toUpperCase() : '#text', data,
      childNodes: [], parentNode: null, attrs: {}, style: {}, listeners: {} });
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
  get onclick() { return null; } // preact lowercases the event name only when on<name> exists
  focus() {}
  querySelector() { return null; }
  querySelectorAll() { return []; }
  get textContent() { return this.nodeType === 3 ? String(this.data) : this.childNodes.map((c) => c.textContent).join(''); }
}
const all = (n, out = []) => { out.push(n); n.childNodes.forEach((c) => all(c, out)); return out; };
const byTag = (root, tag) => all(root).filter((n) => n.localName === tag);
const mounted = [];
const realSetTimeout = globalThis.setTimeout;
afterEach(() => {
  while (mounted.length) mount(null, mounted.pop());
  globalThis.setTimeout = realSetTimeout;
});

const URL_50 = '/api/coord/merge-trains?project=cromford&limit=50';
const NOW = Date.now();  // determinism: ok every fixture timestamp below is an offset from this one read
const iso = (minAgo) => new Date(NOW - minAgo * 60000).toISOString();
const row = (o) => ({ project: 'cromford', repo: 'example-org/cromford', train_pr: null, members: null,
  member_count: null, union_sha: null, run_id: null, outcome: 'open', merge_sha: null, detail: null,
  train_group: null, created_at: iso(90), updated_at: iso(60), ...o });

// answer(url, n) -> {status, body}; every call is recorded.
async function mountPanel(answer) {
  const doc = new FakeNode(9, '#document');
  doc.createElement = (t) => new FakeNode(1, t);
  doc.createElementNS = (_, t) => new FakeNode(1, t);
  doc.createTextNode = (d) => new FakeNode(3, null, d);
  globalThis.document = doc;
  globalThis.window = globalThis.window || { dispatchEvent() {}, addEventListener() {}, removeEventListener() {} };
  const calls = [];
  globalThis.fetch = async (url, init = {}) => {
    calls.push({ url: String(url), method: init.method || 'GET' });
    const { status = 200, body } = answer(String(url), calls.length);
    return { ok: status < 400, status, text: async () => JSON.stringify(body) };
  };
  const root = doc.createElement('div');
  mount(h(MergeTrainsPanel, { project: 'cromford' }), root);
  mounted.push(root);
  await flush();
  await flush();
  return { root, calls };
}

test('mounted: six sortable headers, one GET of 50, PR link, newest first', async () => {
  const { root, calls } = await mountPanel(() => ({ body: { merge_trains: [
    row({ branch: 'train/old', train_pr: 41, members: '3,4', member_count: 2, updated_at: iso(120) }),
    row({ branch: 'train/new', train_pr: 42, members: '7,8,9', member_count: 3, updated_at: iso(5) }),
  ], as_of: iso(0) } }));
  const heads = byTag(root, 'th');
  assert.deepEqual(heads.map((t) => t.textContent.replace(/[↑↓]/g, '').trim()),
    ['BRANCH', 'OUTCOME', 'MEMBERS', 'MEMBER COUNT', 'TRAIN PR', 'UPDATED']);
  assert.ok(heads.every((t) => byTag(t, 'button').length === 1), 'every header sorts');
  assert.equal(heads[5].attrs['aria-sort'], 'descending');
  assert.ok(all(root).some((n) => n.attrs && n.attrs.class === 'tablewrap tablewrap--wide'), 'SortableTable wide');
  assert.deepEqual(calls.map((c) => [c.method, c.url]), [['GET', URL_50]]);
  const hrefs = byTag(root, 'a').map((a) => a.attrs.href);
  assert.ok(hrefs.includes('/pr/cromford/42'), hrefs.join(' '));
  assert.ok(hrefs.includes('/pr/cromford/7'), 'member links drill down');
  const bodyRows = byTag(byTag(root, 'tbody')[0], 'tr');
  assert.match(bodyRows[0].textContent, /train\/new/);
  assert.match(bodyRows[1].textContent, /train\/old/);
});

test('mounted: a null member_count and no train PR render as —, never 0 or a link', async () => {
  const { root } = await mountPanel(() => ({ body: { merge_trains: [row({ branch: 'train/x', outcome: 'creating' })] } }));
  const cells = byTag(byTag(root, 'tbody')[0], 'td').map((c) => c.textContent.trim());
  assert.deepEqual(cells.slice(0, 5), ['train/x', 'creating', 'none', '—', '—']);
  assert.deepEqual(byTag(root, 'a'), []);
});

test('mounted: an ok empty read says "no trains yet"', async () => {
  const { root } = await mountPanel(() => ({ body: { merge_trains: [] } }));
  assert.match(root.textContent, /no trains yet/);
  assert.equal(byTag(root, 'table').length, 0);
});

for (const [name, answer] of [
  ['a 500', () => ({ status: 500, body: { error: 'boom' } })],
  ['a body without merge_trains', () => ({ body: {} })],
]) {
  test(`mounted: ${name} is an ErrorBox with RETRY, never "no trains yet"`, async () => {
    const { root, calls } = await mountPanel(answer);
    assert.match(root.textContent, /could not load/);
    assert.match(root.textContent, /RETRY/);
    assert.doesNotMatch(root.textContent, /no trains yet/);
    const retry = byTag(root, 'button').find((b) => b.textContent.trim() === 'RETRY');
    assert.ok(retry, 'a RETRY button');
    assert.equal(calls.length, 1);
    retry.listeners.click.call(retry, { type: 'click', target: retry, currentTarget: retry });
    await flush();
    assert.equal(calls.length, 2, 'RETRY issues a second read');
    assert.ok(calls.every((c) => c.method === 'GET' && c.url === URL_50));
  });
}

test('mounted: a failed refresh with stale rows held is an ErrorBox, not the old table', async () => {
  const timers = [];
  globalThis.setTimeout = (fn, ms, ...a) => {
    if (ms === 30000) { timers.push(fn); return 0; }
    return realSetTimeout(fn, ms, ...a);
  };
  const { root } = await mountPanel((_, n) => (n === 1
    ? { body: { merge_trains: [row({ branch: 'train/a', train_pr: 5 })] } }
    : { status: 502, body: { error: 'down' } }));
  assert.match(root.textContent, /train\/a/);
  timers.shift()();
  await flush();
  assert.match(root.textContent, /could not load/);
  assert.equal(byTag(root, 'table').length, 0);
});

test('mounted: 50 rows shows the capped note, 49 does not', async () => {
  const many = (n) => Array.from({ length: n }, (_, i) => row({ branch: `train/${i}` }));
  const a = await mountPanel(() => ({ body: { merge_trains: many(50) } }));
  assert.match(a.root.textContent, /newest 50 shown; older trains exist/);
  assert.ok(a.calls.every((c) => c.method === 'GET'));
  mount(null, mounted.pop());
  const b = await mountPanel(() => ({ body: { merge_trains: many(49) } }));
  assert.doesNotMatch(b.root.textContent, /older trains exist/);
});

test('mounted: the read is polled every 30 s', async () => {
  const delays = [];
  globalThis.setTimeout = (fn, ms, ...a) => {
    if (ms !== 80) delays.push(ms);
    return ms === 30000 ? 0 : realSetTimeout(fn, ms, ...a);
  };
  await mountPanel(() => ({ body: { merge_trains: [] } }));
  assert.ok(delays.includes(30000), `scheduled delays: ${delays.join(', ')}`);
});

test('mounted: before the first answer it is a skeleton, neither an error nor "no trains yet"', async () => {
  const doc = new FakeNode(9, '#document');
  doc.createElement = (t) => new FakeNode(1, t);
  doc.createElementNS = (_, t) => new FakeNode(1, t);
  doc.createTextNode = (d) => new FakeNode(3, null, d);
  globalThis.document = doc;
  globalThis.fetch = () => new Promise(() => {});
  const root = doc.createElement('div');
  mount(h(MergeTrainsPanel, { project: 'cromford' }), root);
  mounted.push(root);
  await flush();
  assert.ok(all(root).some((n) => n.attrs && n.attrs.class === 'skel'), 'a skeleton while loading');
  assert.doesNotMatch(root.textContent, /could not load|no trains yet/);
});
