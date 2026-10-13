import test from 'node:test';
import assert from 'node:assert/strict';
import { h, render as mount, options } from 'preact';
import { flush } from './helpers/settle.js';

// BH-5667 (BH-5008 child 1): the console's live merge-queue data hook and the
// four seam components the siblings fill in. The pure view state is driven
// directly; api.mergeQueueLive and the coord proxy are driven against a
// stubbed fetch; the seams are proved MOUNTED by recording every vnode type
// the real MergeQueueView, JobsTable and JobsScreen create.

globalThis.window = globalThis.window || {
  location: { pathname: '/jobs', search: '' },
  dispatchEvent() {}, addEventListener() {}, removeEventListener() {},
  history: { pushState() {}, replaceState() {} }, scrollTo() {},
  localStorage: { getItem() { return null; }, setItem() {} }
};

const { render } = await import('preact-render-to-string');
const { api } = await import('../src/api.js');
const { liveViewState, liveFetcher, LIVE_INTERVAL_MS } = await import('../src/ui/merge-queue-live-data.js');
const { MergeQueueBatches, MergeQueueStrip } = await import('../src/ui/merge-queue-live.js');
const { MergeQueueWaiting } = await import('../src/ui/merge-queue-waiting.js');
const { PrStageTrack } = await import('../src/ui/pr-stage-track.js');
const { MergeQueueView } = await import('../src/screens/MergeQueue.js');
const { JobsTable, JobsScreen } = await import('../src/screens/Jobs.js');
const { onRequest } = await import('../functions/api/coord/[[path]].js');

const BODY = (batches = [], extra = {}) => ({ batches, waiting: [], prs: {}, as_of: '2026-10-09T03:10:00Z', complete: true, ...extra });
const BATCH = { repo: 'Example-Org/example-repo', draft: 9001, members: [101, 102, 103], checks: { done: 10, total: 14 } };
const polled = (o) => ({ data: null, error: null, loading: false, fetchedAt: null, ...o });
const stamped = (project, version, body) => ({ project, version, body });

// ------------------------------------------------------------ liveViewState

test('L1 a load error with no data is error, never empty (D23)', () => {
  const s = liveViewState(polled({ error: new Error('http_503') }), null, 1);
  assert.equal(s.state, 'error');
  assert.equal(s.error, 'http_503');
  assert.deepEqual(s.batches, []);
});

test('L1 an ok answer with no batches is empty; with batches it is ok', () => {
  const empty = liveViewState(polled({ data: stamped(null, 1, BODY()), fetchedAt: 5 }), null, 1);
  assert.equal(empty.state, 'empty');
  assert.equal(empty.complete, true);
  assert.equal(empty.fetchedAt, 5);
  const ok = liveViewState(polled({ data: stamped('project-3', 2, BODY([BATCH], { complete: false })) }), 'project-3', 2);
  assert.equal(ok.state, 'ok');
  assert.deepEqual(ok.batches, [BATCH]);
  assert.equal(ok.complete, false);
  assert.equal(ok.error, null);
});

test('L1 an answer for another project or an older version is dropped: loading, no data shown', () => {
  const otherProject = liveViewState(polled({ data: stamped('project-3', 2, BODY([BATCH])), loading: true }), 'project-2', 2);
  assert.equal(otherProject.state, 'loading');
  assert.deepEqual(otherProject.batches, []);
  const olderVersion = liveViewState(polled({ data: stamped('project-3', 1, BODY([BATCH])) }), 'project-3', 2);
  assert.equal(olderVersion.state, 'loading');
  assert.deepEqual(olderVersion.batches, []);
  // An error left over from the old project while the new one loads is not this project's error.
  const pending = liveViewState(polled({ data: stamped('project-3', 1, BODY([BATCH])), error: new Error('old'), loading: true }), 'project-2', 2);
  assert.equal(pending.state, 'loading');
});

test('L1 an error with older data for THIS request keeps the data and sets error', () => {
  const s = liveViewState(polled({ data: stamped(null, 3, BODY([BATCH])), error: new Error('network unreachable'), fetchedAt: 9 }), null, 3);
  assert.equal(s.state, 'ok');
  assert.deepEqual(s.batches, [BATCH]);
  assert.equal(s.error, 'network unreachable');
  assert.equal(s.fetchedAt, 9);
});

test('L1 a body with no batches array is an error, not an empty queue', () => {
  const s = liveViewState(polled({ data: stamped(null, 1, { error: 'x' }) }), null, 1);
  assert.equal(s.state, 'error');
});

// ------------------------------------------------------------ api + proxy

test('L2 api.mergeQueueLive reads GET /api/coord/merge-queue/live, with ?project= only when given', async () => {
  const seen = [];
  const real = globalThis.fetch;
  globalThis.fetch = async (url, init = {}) => {
    seen.push({ url: String(url), method: init.method || 'GET' });
    return new Response(JSON.stringify(BODY()), { status: 200, headers: { 'content-type': 'application/json' } });
  };
  try {
    await api.mergeQueueLive({ project: 'x' });
    await api.mergeQueueLive({ project: 'Example-Org/example repo' });
    await api.mergeQueueLive();
    const f = await liveFetcher('x', 4)();
    assert.deepEqual(f, { project: 'x', version: 4, body: BODY() });
  } finally { globalThis.fetch = real; }
  assert.equal(seen[0].url, '/api/coord/merge-queue/live?project=x');
  assert.equal(seen[1].url, '/api/coord/merge-queue/live?project=Example-Org%2Fexample%20repo');
  assert.equal(seen[2].url, '/api/coord/merge-queue/live');
  assert.ok(seen.every((s) => s.method === 'GET'));
  assert.equal(LIVE_INTERVAL_MS, 5000);
});

test('L3 the coord proxy forwards GET /api/coord/merge-queue/live to the worker route, query and all', async () => {
  const JOBS = 'https://harness-jobs.operator.workers.dev';
  const CONSOLE = 'https://harness-console.operator.workers.dev';
  const seen = [];
  const real = globalThis.fetch;
  globalThis.fetch = async (input, init = {}) => {
    const target = typeof input === 'string' ? input : input.url;
    if (target.startsWith(CONSOLE)) return new Response('', { status: 200 });
    seen.push({ url: target, method: init.method });
    return new Response(JSON.stringify(BODY()), { status: 200, headers: { 'content-type': 'application/json' } });
  };
  try {
    const res = await onRequest({
      request: new Request('https://console.example.pages.dev/api/coord/merge-queue/live?project=project-3', {
        method: 'GET', headers: { cookie: 'dash=bh5667-1' }
      }),
      env: { HARNESS_SECRET: 'test-harness-secret' },
      params: { path: ['merge-queue', 'live'] }
    });
    assert.equal(res.status, 200);
  } finally { globalThis.fetch = real; }
  assert.equal(seen.length, 1);
  assert.equal(seen[0].url, `${JOBS}/api/merge-queue/live?project=project-3`);
  assert.equal(seen[0].method, 'GET');
});

// ------------------------------------------------------------ seams

test('L4 seam components render nothing', () => {
  // MergeQueueBatches and MergeQueueStrip are filled by BH-5668 (child 2) and
  // call the live hook, so they are pinned by merge-queue-screen.bh-5668.test.js.
  // MergeQueueWaiting and PrStageTrack are filled by BH-5669 (child 3) and call
  // hooks too, so a direct call is no longer valid. Their first render is the
  // loading state, which renders nothing; their own suites pin the rest
  // (merge-queue-waiting.bh-5669.test.js, pr-stage-track.bh-5669.test.js).
  for (const C of [MergeQueueWaiting, PrStageTrack]) {
    assert.equal(render(h(C, {})), '', C.name);
  }
});

// Every component vnode created while fn runs: [type, props].
async function recordVnodes(fn) {
  const seen = [];
  const prev = options.vnode;
  options.vnode = (v) => { if (typeof v.type === 'function') seen.push([v.type, v.props]); if (prev) prev(v); };
  try { await fn(); } finally { options.vnode = prev; }
  return seen;
}

const okRes = (data) => ({ data, error: null, loading: false, reload() {} });

test('L5 MergeQueueView mounts MergeQueueBatches and MergeQueueWaiting with the project, above the queue', async () => {
  const props = {
    project: 'project-3',
    mq: [okRes({ merge_queue: [] }), okRes({ merge_queue: [] }), okRes({ merge_queue: [] })],
    held: okRes({ rows: [], n_total: 0 }),
    mqChanges: okRes({ changes: [] }), heldChanges: okRes({ changes: [] }),
    setting: okRes({ setting: null }), risk: okRes({ rows: [] }), reload() {}, nowMs: 0,
  };
  let out = '';
  const seen = await recordVnodes(() => { out = render(h(MergeQueueView, props)); });
  const types = seen.map(([t]) => t);
  for (const C of [MergeQueueBatches, MergeQueueWaiting]) {
    const hit = seen.find(([t]) => t === C);
    assert.ok(hit, `${C.name} is not mounted`);
    assert.equal(hit[1].project, 'project-3');
  }
  assert.ok(types.indexOf(MergeQueueBatches) < types.indexOf(MergeQueueWaiting));
  // The visible page is unchanged: the same sections, nothing new rendered.
  for (const title of ['MERGE QUEUE', 'RISK TIERS', 'HELD PAGES', 'RECENT CONTROL CHANGES']) assert.match(out, new RegExp(title));
});

const JOB = {
  id: 'build-project-3-TK-1-1', state: 'running', status: 'running', project: 'project-3', lane: 'build', key: 'TK-1',
  box: 'project-3', attempts: 1, spent_usd: 1, budget_usd: 5, age_s: 60, activity_age_s: 5, heartbeating: false,
  created_at: '2026-10-09T03:00:00Z', phase: null,
};

test('L5 JobsTable mounts PrStageTrack inside the TICKET cell and keeps its columns', async () => {
  let out = '';
  const seen = await recordVnodes(() => { out = render(h(JobsTable, { rows: [JOB] })); });
  const hit = seen.find(([t]) => t === PrStageTrack);
  assert.ok(hit, 'PrStageTrack is not mounted in the row');
  assert.equal(hit[1].project, 'project-3');
  assert.equal(hit[1].ticket, 'TK-1');
  assert.match(out, />TK-1</);
  const headers = [...out.matchAll(/<th[^>]*>([\s\S]*?)<\/th>/g)].map((m) => m[1].replace(/<[^>]+>/g, '').replace(/[▲▼↕\s]+$/u, '').trim());
  assert.deepEqual(headers.filter(Boolean).slice(0, 7), ['JOB', 'STATE', 'PROJECT', 'LANE', 'PHASE', 'ATTEMPTS', 'TICKET']);
});

// A small DOM, enough for preact to mount a screen and run its effects.
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

test('L5 JobsScreen mounts MergeQueueStrip once the jobs have loaded', async () => {
  const doc = new FakeNode(9, '#document');
  doc.createElement = (t) => new FakeNode(1, t);
  doc.createElementNS = (_, t) => new FakeNode(1, t);
  doc.createTextNode = (d) => new FakeNode(3, null, d);
  doc.hidden = false;
  const prevDoc = globalThis.document;
  globalThis.document = doc;
  const real = globalThis.fetch;
  globalThis.fetch = async (url) => {
    const u = String(url);
    const body = u.includes('/jobs') ? { jobs: [JOB], as_of: '2026-10-09T03:10:00Z' } : u.includes('/lanes') ? { lanes: [] }
      : u.includes('/burn') ? { days: [] } : { flags: [] };
    return { ok: true, status: 200, text: async () => JSON.stringify(body) };
  };
  const root = doc.createElement('div');
  try {
    const seen = await recordVnodes(async () => { mount(h(JobsScreen, {}), root); await flush(); });
    assert.ok(seen.some(([t]) => t === MergeQueueStrip), 'MergeQueueStrip is not mounted');
    assert.match(root.textContent, /JOBS/);
  } finally {
    mount(null, root);
    globalThis.fetch = real;
    globalThis.document = prevDoc;
  }
});
