import test from 'node:test';
import assert from 'node:assert/strict';
import { h, render as mount, options } from 'preact';
import { flush } from './helpers/settle.js';

// BH-3158 (BH-2325.3): the read-only /merge-queue screen. The pure lib is
// driven directly, the view is rendered server-side for each state, and the
// screen itself is mounted through the real ROUTES table into a small fake DOM
// against a stubbed fetch, so every read goes through the real api.js.

globalThis.window = globalThis.window || {
  location: { pathname: '/merge-queue', search: '' },
  dispatchEvent() {}, addEventListener() {}, removeEventListener() {},
  history: { pushState() {}, replaceState() {} }, scrollTo() {},
  localStorage: { getItem() { return null; }, setItem() {} }
};

const { render } = await import('preact-render-to-string');
const { ROUTES, NAV, FleetContext } = await import('../src/app.js');
const { matchRoute } = await import('../src/router.js');
const { KanbanScreen } = await import('../src/screens/Kanban.js');
const { MqRowActions, HeldReleaseButton } = await import('../src/screens/merge-queue-actions.js');
const { CONFIG_KINDS } = await import('../../worker/jobs/src/lib/config-changes.js');
const {
  MQ_READ_LIMIT, MQ_STATUSES, mqRows, auditRows, rowsOnlyState, rowsOnlyBanner
} = await import('../src/lib/merge-queue.js');
const { MergeQueueScreen, MergeQueueView } = await import('../src/screens/MergeQueue.js');

const T1 = '2026-09-28T10:00:00Z';
const T2 = '2026-09-28T11:00:00Z';
const T3 = '2026-09-28T12:00:00Z';
const mq = (pr, status = 'queued', enqueued_at = T1, project = 'project-3') =>
  ({ project, pr, status, repo: `example-org/${project}`, reason: `r${pr}`, enqueued_by: 'conductor', enqueued_at, updated_at: enqueued_at });
const okRes = (data) => ({ data, error: null, reload() {} });
const errRes = (msg = 'boom') => ({ data: null, error: new Error(msg), reload() {} });
const mqRes = (rows) => okRes({ merge_queue: rows, as_of: T3 });
const many = (n, status = 'queued') => Array.from({ length: n }, (_, i) => mq(i + 1, status));

// ------------------------------------------------------------ lib

test('A1 MQ_READ_LIMIT is the worker max, and landed is never a read status', () => {
  assert.equal(MQ_READ_LIMIT, 500);
  assert.deepEqual(MQ_STATUSES, ['queued', 'blocked', 'dropped']);
});

test('A2 mqRows: a failed read is failed, never an empty list; 500 rows is capped, 499 is not', () => {
  const r = mqRows(mqRes([mq(1), mq(2)]), errRes(), mqRes([]));
  assert.equal(r.rows.length, 2);
  assert.deepEqual(r.failed, ['blocked']);
  assert.deepEqual(r.capped, []);
  // data:{} (no array) and data:null are failed too.
  assert.deepEqual(mqRows(okRes({}), okRes(null), mqRes([])).failed, ['queued', 'blocked']);
  assert.deepEqual(mqRows(mqRes(many(500)), mqRes([]), mqRes([])).capped, ['queued']);
  assert.deepEqual(mqRows(mqRes(many(499)), mqRes([]), mqRes([])).capped, []);
  // A row keeps the status the worker gave it.
  assert.equal(mqRows(mqRes([mq(9, 'blocked')]), mqRes([]), mqRes([])).rows[0].status, 'blocked');
});

test('A3 rowsOnlyState mirrors _flag_on_row: 1|on|true|yes is on, a failed read is unread', () => {
  assert.equal(rowsOnlyState(errRes()), 'unread');
  assert.equal(rowsOnlyState({ data: null, error: null }), 'unread');
  assert.equal(rowsOnlyState(null), 'unread');
  assert.equal(rowsOnlyState(okRes({ setting: null, source: 'none' })), 'off');
  for (const v of ['1', 'on', ' TRUE ', 'yes']) {
    assert.equal(rowsOnlyState(okRes({ setting: { value: v }, source: 'settings' })), 'on', v);
  }
  for (const v of ['0', 'off', '', 'onn', 'false', ' ', 'no', '1x', null]) {
    assert.equal(rowsOnlyState(okRes({ setting: { value: v }, source: 'settings' })), 'off', String(v));
  }
});

test('A4 auditRows: both kinds merged newest first; released / queued → blocked; bad JSON never throws', () => {
  const m = { id: 1, kind: 'merge_queue', name: 'project-3#41', before_json: '{"status":"queued"}', after_json: '{"status":"blocked"}', actor: 'console', reason: 'flaky', at: T2 };
  const held = { id: 2, kind: 'held_page', name: 'example-org/project-3#41', before_json: '{"state":"held"}', after_json: 'null', actor: 'console', reason: 'ok', at: T3 };
  const kept = { id: 3, kind: 'held_page', name: 'example-org/x#2', before_json: null, after_json: '{"status":"held"}', actor: 'console', reason: null, at: T1 };
  const bad = { id: 4, kind: 'merge_queue', name: 'x#1', before_json: 'not json', after_json: '{oops', actor: 'api', reason: null, at: T1 };
  const r = auditRows(okRes({ changes: [m, bad], truncated: false }), okRes({ changes: [held, kept], truncated: true }));
  assert.deepEqual(r.rows.map((x) => x.change), ['released', 'queued → blocked', '— → —', '— → held']);
  assert.equal(r.rows[0].what, 'held_page example-org/project-3#41');
  assert.equal(r.rows[1].what, 'merge_queue project-3#41');
  assert.deepEqual(r.failed, []);
  assert.deepEqual(r.truncated, ['held_page']);
  const f = auditRows(errRes(), okRes({ changes: [held] }));
  assert.deepEqual(f.failed, ['merge_queue']);
  assert.equal(f.rows.length, 1);
});

// ------------------------------------------------------------ view

const baseProps = (over = {}) => ({
  project: null,
  mq: [mqRes([mq(41, 'queued', T1), mq(42, 'blocked', T2)]), mqRes([]), mqRes([])],
  held: okRes({ rows: [], n_total: 0 }),
  mqChanges: okRes({ changes: [] }),
  heldChanges: okRes({ changes: [] }),
  setting: okRes({ key: 'merge_queue_rows_only', setting: null, source: 'none' }),
  reload() {},
  ...over
});
const view = (over) => render(h(MergeQueueView, baseProps(over)));

test('A6 the rows-only banner is true in each state', () => {
  const on = view({ setting: okRes({ setting: { value: '1' }, source: 'settings' }) });
  assert.match(on, /Rows-only is ON/);
  assert.match(on, /role="status"/);
  const off = view({ setting: okRes({ setting: { value: '0' }, source: 'settings' }) });
  assert.match(off, /Rows-only is OFF/);
  const none = view();
  assert.match(none, /No merge_queue_rows_only row/);
  assert.match(none, /MERGE_QUEUE_ROWS_ONLY/);
  assert.doesNotMatch(none, /Rows-only is OFF/);
  const unread = view({ setting: errRes('coord 502') });
  assert.match(unread, /unreadable: coord 502/);
  assert.doesNotMatch(unread, /Rows-only is (ON|OFF)/);
  // The banner text comes from the lib, one sentence per state.
  assert.match(rowsOnlyBanner('unread', errRes('x')), /unreadable/);
});

test('A7 every identity cell links: PR to /pr, project to the filtered screen; a filter shows ALL PROJECTS', () => {
  const out = view();
  assert.match(out, /href="\/pr\/project-3\/41"/);
  assert.match(out, /href="\/merge-queue\?project=project-3"/);
  assert.match(out, /href="\/kanban"/);
  assert.doesNotMatch(out, /ALL PROJECTS/);
  const filtered = view({ project: 'project-3' });
  assert.match(filtered, /ALL PROJECTS/);
  assert.match(filtered, /href="\/merge-queue"/);
  const enc = view({ mq: [mqRes([mq(7, 'queued', T1, 'a b')]), mqRes([]), mqRes([])] });
  assert.match(enc, /href="\/merge-queue\?project=a%20b"/);
  assert.match(enc, /href="\/pr\/a%20b\/7"/);
});

test('A8 the MERGE QUEUE table defaults to oldest enqueued_at first', () => {
  const out = view({ mq: [mqRes([mq(303, 'queued', T3), mq(101, 'queued', T1), mq(202, 'queued', T2)]), mqRes([]), mqRes([])] });
  const at = (n) => out.indexOf(`href="/pr/project-3/${n}"`);
  assert.ok(at(101) > -1 && at(202) > -1 && at(303) > -1);
  assert.ok(at(101) < at(202) && at(202) < at(303), 'T1, T2, T3');
});

test('A9 a capped status says the newest rows are the missing ones', () => {
  const out = view({ mq: [mqRes(many(500)), mqRes([]), mqRes([])] });
  assert.match(out, /first 500 queued rows only/);
  assert.match(out, /newest/);
  assert.doesNotMatch(view(), /first 500/);
});

test('A10 HELD PAGES: the GitHub link, the worker n_total, and the empty state', () => {
  const held = { repo: 'example-org/project-3', number: 41, state: 'held', head: 'abc', kind: 'review', text: 'needs a look', mark: 'm', mode: 'page', first_held_at: T1, last_seen_at: T2 };
  const out = view({ held: okRes({ rows: [held], n_total: 3 }) });
  assert.match(out, /href="https:\/\/github.com\/example-org\/project-3\/pull\/41"/);
  assert.match(out, /target="_blank"/);
  assert.match(out, /1 of 3/);
  assert.match(view(), /no held pages/);
  const unknown = view({ held: okRes({ rows: [held] }) });
  assert.match(unknown, /1 shown, total unknown/);
  assert.doesNotMatch(unknown, /1 of 0/);
});

test('A11 RECENT CONTROL CHANGES has WHEN/WHAT/CHANGE/ACTOR/REASON, newest first', () => {
  const c = (id, at, after) => ({ id, kind: 'merge_queue', name: `p#${id}`, before_json: '{"status":"queued"}', after_json: JSON.stringify({ status: after }), actor: 'console', reason: 'why', at });
  const out = view({ mqChanges: okRes({ changes: [c(1, T1, 'dropped'), c(2, T3, 'blocked')] }) });
  for (const hd of ['WHEN', 'WHAT', 'CHANGE', 'ACTOR', 'REASON']) assert.match(out, new RegExp(`>\\s*${hd}\\s*<`), hd);
  assert.ok(out.indexOf('merge_queue p#2') < out.indexOf('merge_queue p#1'));
  assert.match(out, /queued → blocked/);
  assert.match(view(), /no merge-queue or held-page changes yet/);
  assert.match(view({ heldChanges: okRes({ changes: [], truncated: true }) }), /latest 50 held_page changes only/);
  assert.doesNotMatch(view(), /latest 50/);
  const one = view({ heldChanges: errRes('nope') });
  assert.match(one, /held_page changes unreadable: nope/);
  const both = view({ mqChanges: errRes('a'), heldChanges: errRes('b') });
  assert.match(both, /could not load/);
  assert.doesNotMatch(both, /no merge-queue or held-page changes yet/);
});

test('A12 a failed read renders an error, never an empty state', () => {
  const one = view({ mq: [errRes('queued down'), mqRes([]), mqRes([])] });
  assert.match(one, /queued rows unreadable: queued down/);
  assert.doesNotMatch(one, /nothing queued, blocked or dropped/);
  assert.match(one, /no rows from the readable statuses/);
  assert.match(view({ mq: [mqRes([]), mqRes([]), mqRes([])] }), /nothing queued, blocked or dropped/);
  const all = view({ mq: [errRes('x'), errRes('y'), errRes('z')] });
  assert.match(all, /could not load/);
  assert.doesNotMatch(all, /nothing queued/);
  const held = view({ held: errRes('held down') });
  assert.match(held, /could not load — <b>held down/);
  assert.doesNotMatch(held, /no held pages/);
  // Not settled yet: a skeleton, never an empty state.
  const pending = { data: null, error: null, reload() {} };
  const loading = view({ mq: [pending, pending, pending], held: pending });
  assert.match(loading, /class="skel"/);
  assert.doesNotMatch(loading, /nothing queued|no held pages/);
});

test('A12b the action cells are the contract components, handed the row, rowsOnly and reload', () => {
  // The stubs render nothing, so the wiring is pinned on the vnodes the view creates.
  const seen = [];
  const prev = options.vnode;
  options.vnode = (v) => { if (v.type === MqRowActions || v.type === HeldReleaseButton) seen.push(v); if (prev) prev(v); };
  const reload = () => {};
  const held = { repo: 'example-org/project-3', number: 41, first_held_at: T1, last_seen_at: T2 };
  try {
    render(h(MergeQueueView, baseProps({ reload, setting: okRes({ setting: { value: 'on' } }), held: okRes({ rows: [held], n_total: 1 }) })));
  } finally {
    options.vnode = prev;
  }
  const rowCells = seen.filter((v) => v.type === MqRowActions);
  assert.deepEqual(rowCells.map((v) => v.props.row.pr).sort(), [41, 42]);
  for (const v of rowCells) {
    assert.equal(v.props.rowsOnly, 'on');
    assert.equal(v.props.onDone, reload);
  }
  const rel = seen.filter((v) => v.type === HeldReleaseButton);
  assert.equal(rel.length, 1);
  assert.equal(rel[0].props.row, held);
  assert.equal(rel[0].props.onDone, reload);
});

// ------------------------------------------------------------ route, nav, kanban

test('A13 /merge-queue is routed; the KANBAN tab lights for it; no new tab', () => {
  const route = ROUTES.find(([p]) => p === '/merge-queue');
  assert.ok(route);
  assert.equal(route[1], MergeQueueScreen);
  const kanban = NAV.find((n) => n.to === '/kanban');
  assert.equal(kanban.match('/merge-queue'), true);
  assert.equal(kanban.match('/merge-queues'), false);
  assert.equal(kanban.match('/merge-queue/x'), false);
  assert.equal(kanban.match('/kanban'), true);
  assert.equal(NAV.some((n) => n.to === '/merge-queue'), false);
});

test('A14 the Kanban header links to /merge-queue', () => {
  const out = render(h(FleetContext.Provider, { value: { data: { projects: [] } } }, h(KanbanScreen)));
  assert.match(out, /<a href="\/merge-queue" class="btn btn--sm">MERGE QUEUE<\/a>/);
});

// ------------------------------------------------------------ the screen, mounted

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

test('A5 the mounted screen reads three statuses for ?project=, held pages, both audit kinds and the setting', async () => {
  const calls = [];
  const real = globalThis.fetch;
  globalThis.fetch = async (url) => {
    const u = String(url);
    calls.push(u);
    const body = u.includes('/merge-queue/live') ? { batches: [], waiting: [], prs: {}, as_of: T3, complete: true }
      : u.includes('/merge-queue') ? { merge_queue: u.includes('status=queued') ? [mq(41)] : [], as_of: T3 }
      : u.includes('/conductor/held') ? { rows: [], n_total: 0 }
      : u.includes('/config-changes') ? { changes: [], truncated: false }
      : { key: 'merge_queue_rows_only', setting: { value: '1' }, source: 'settings' };
    return { ok: true, status: 200, text: async () => JSON.stringify(body) };
  };
  window.location.pathname = '/merge-queue';
  window.location.search = '?project=project-3';
  const doc = installDom();
  const root = doc.createElement('div');
  try {
    const hit = ROUTES.map(([p, C]) => [matchRoute(p, '/merge-queue'), C]).find(([params]) => params);
    mount(h(hit[1], hit[0]), root);
    await flush();
    const q = (s) => `/api/coord/merge-queue?project=project-3&status=${s}&limit=500`;
    assert.deepEqual(calls.filter((u) => u.includes('/merge-queue?')).sort(), [q('blocked'), q('dropped'), q('queued')]);
    // BH-5668: the RUNNING BATCHES table polls the live read for the same project.
    // BH-5669: the waiting line (MergeQueueWaiting) polls it too, for the same project.
    assert.deepEqual(calls.filter((u) => u.includes('/merge-queue/live')),
      ['/api/coord/merge-queue/live?project=project-3', '/api/coord/merge-queue/live?project=project-3']);
    assert.equal(calls.some((u) => u.includes('landed')), false);
    assert.ok(calls.includes('/api/coord/conductor/held?limit=500'));
    assert.ok(calls.includes(`/api/coord/config-changes?kind=${CONFIG_KINDS.MERGE_QUEUE}&limit=50`));
    assert.ok(calls.includes(`/api/coord/config-changes?kind=${CONFIG_KINDS.HELD_PAGE}&limit=50`));
    assert.ok(calls.includes('/api/coord/settings/merge_queue_rows_only'));
    // BH-5022: the RISK TIERS section's one read, every project, the worker cap.
    assert.ok(calls.includes('/api/coord/risk-tiers?limit=200'));
    // TEST-CHANGE (BH-5430): one more read, the MERGE QUEUE's BREAK RISK
    // column (every project, the worker cap). Main reads 10 since the live
    // batches and waiting lists (BH-5667), so the count is 11.
    assert.ok(calls.includes('/api/coord/queue-risk?limit=200'));
    assert.equal(calls.length, 11);
    const text = root.textContent;
    assert.match(text, /No batch is running\./);
    assert.match(text, /Rows-only is ON/);
    assert.match(text, /#41/);
    assert.match(text, /ALL PROJECTS/);
    assert.match(text, /no held pages/);
  } finally {
    mount(null, root);
    globalThis.fetch = real;
    window.location.search = '';
  }
});
