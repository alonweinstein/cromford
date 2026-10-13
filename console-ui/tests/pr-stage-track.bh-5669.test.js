import test from 'node:test';
import assert from 'node:assert/strict';
import { h, render as mount } from 'preact';
import { flush } from './helpers/settle.js';

// BH-5669 (BH-5008 child 3): a PR's merge-queue stage track. The component is
// MOUNTED on a small DOM so its poll runs, against a stubbed
// api.mergeQueueLive; P6 mounts the real TicketView, which reaches the track
// through the JobsTable TICKET cell.

globalThis.window = globalThis.window || {
  location: { pathname: '/t/BH-1', search: '' },
  dispatchEvent() {}, addEventListener() {}, removeEventListener() {},
  history: { pushState() {}, replaceState() {} }, scrollTo() {},
  localStorage: { getItem() { return null; }, setItem() {} }
};

const { render } = await import('preact-render-to-string');
const { api } = await import('../src/api.js');
const { PrStageTrack, QUEUE_STATIONS, __resetSharedLive } = await import('../src/ui/pr-stage-track.js');
const { StationTrack, STATIONS } = await import('../src/ui/line.js');
const { TicketView } = await import('../src/screens/Ticket.js');
const { jobRows } = await import('../src/lib/jobs.js');

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
const esc = (s) => String(s).replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/"/g, '&quot;');
function serialize(n) {
  if (n.nodeType === 3) return esc(n.data);
  const attrs = Object.entries(n.attrs).map(([k, v]) => ` ${k}="${esc(v)}"`).join('');
  return `<${n.localName}${attrs}>${n.childNodes.map(serialize).join('')}</${n.localName}>`;
}
function makeDoc() {
  const doc = new FakeNode(9, '#document');
  doc.createElement = (t) => new FakeNode(1, t);
  doc.createElementNS = (_, t) => new FakeNode(1, t);
  doc.createTextNode = (d) => new FakeNode(3, null, d);
  return doc;
}

const R = 'Example-Org/example-repo';
const AT = '2026-10-09T03:10:00Z';
const U1 = `https://github.com/${R}/actions/runs/7001/job/17001`;
const U3 = `https://github.com/${R}/actions/runs/7003/job/17003`;
const B = (draft, o) => ({
  repo: R, draft, url: `https://github.com/${R}/pull/${draft}`, members: [], base_sha: null, stage: 'batched',
  checks: { done: 0, total: 0 }, progress: null, eta_s: null, eta_basis: null, failing: null, bisect: null, outcome: null, ...o,
});
const BODY = {
  batches: [
    B(9001, { members: [101, 102, 103], stage: 'failing', checks: { done: 10, total: 14 }, failing: { name: 'Jobs worker', url: U1 } }),
    B(9002, { members: [101, 102], bisect: { step: 1, steps: 2, parent: 9001 } }),
    B(9003, { members: [101], stage: 'failing', checks: { done: 1, total: 14 }, failing: { name: 'Jobs worker', url: U3 }, bisect: { step: 2, steps: 2, parent: 9002 } }),
  ],
  waiting: [],
  prs: {
    [`${R}#103`]: { stage: 'checking', detail: '#9001', batch: 9001, at: AT, key: 'BH-103', project: 'example' },
    [`${R}#102`]: { stage: 'batched', detail: '#9002', batch: 9002, at: AT, key: null, project: null },
    [`${R}#101`]: { stage: 'dequeued', detail: 'Jobs worker failed on #101 alone', batch: 9003, at: AT, key: 'BH-1', project: 'example' },
    [`${R}#104`]: { stage: 'ci_red', detail: null, batch: null, at: AT, key: null, project: null },
    [`${R}#105`]: { stage: 'queued', detail: '3', batch: null, at: AT, key: null, project: null },
  },
  as_of: AT, complete: true,
};

async function mountWith(body, vnode) {
  __resetSharedLive();
  let calls = 0;
  const realApi = api.mergeQueueLive;
  api.mergeQueueLive = async () => { calls += 1; if (body instanceof Error) throw body; return body; };
  const prevDoc = globalThis.document;
  globalThis.document = makeDoc();
  const root = globalThis.document.createElement('div');
  mount(vnode, root);
  await flush();
  const html = serialize(root).replace(/^<div>|<\/div>$/g, '');
  mount(null, root);
  api.mergeQueueLive = realApi;
  globalThis.document = prevDoc;
  return { html, calls };
}

const stations = (html) => [...html.matchAll(/<div class="(st(?: [a-z]+)?)">([\s\S]*?)<\/div>/g)].map((m) => m[1]);
const links = (html) => [...html.matchAll(/<a([^>]*)>([^<]*)<\/a>/g)]
  .map((m) => ({ href: (m[1].match(/href="([^"]*)"/) || [])[1] || null, text: m[2] }));

test('P1 a checking member shows Checks 10/14 at the third station, failed', async () => {
  const { html } = await mountWith(BODY, h(PrStageTrack, { repo: R, pr: 103 }));
  assert.match(html, /Checks 10\/14/);
  assert.match(html, /aria-label="[^"]*at Checks 10\/14 \(fail\)"/);
  assert.deepEqual(stations(html), ['st done', 'st done', 'st fail', 'st', 'st', 'st']);
  assert.match(html, /^<div class="track-scroll">/);
});

test('P1 each queue stage maps to its station and label', async () => {
  const cases = [
    [`${R}#105`, 105, 0, 'Queued (#3)'],
    [`${R}#102`, 102, 1, 'In batch #9002 with 1 other'],
  ];
  for (const [, pr, at, label] of cases) {
    const { html } = await mountWith(BODY, h(PrStageTrack, { repo: R, pr }));
    const st = stations(html);
    assert.equal(st.indexOf(st.find((c) => c !== 'st done')), at, `${label} station`);
    assert.match(html, new RegExp(label.replace(/[()#]/g, '\\$&')));
  }
  for (const [stage, at, label] of [['merging', 3, 'Merging'], ['merged', 4, 'Merged'], ['deploy_verified', 5, 'Deploy verified']]) {
    const body = { ...BODY, prs: { [`${R}#300`]: { stage, detail: '#9001', batch: 9001, at: AT, key: null, project: null } } };
    const { html } = await mountWith(body, h(PrStageTrack, { repo: R, pr: 300 }));
    assert.match(html, new RegExp(`at ${label} \\(fail\\)|at ${label} \\(now\\)`));
    assert.equal(stations(html).filter((c) => c === 'st done').length, at, stage);
  }
});

test('P2 the dequeued culprit links its dequeue line to the failing check run', async () => {
  const { html } = await mountWith(BODY, h(PrStageTrack, { repo: R, pr: 101 }));
  assert.ok(links(html).some((l) => l.href === U3 && l.text === 'Dequeued: Jobs worker failed on #101 alone'), html);
  assert.match(html, /at Dequeued \(fail\)/);
  // A failure line with no url is plain text, never href="null".
  const noUrl = { ...BODY, batches: BODY.batches.map((b) => (b.draft === 9003 ? { ...b, failing: { name: 'Jobs worker', url: null } } : b)) };
  const r = await mountWith(noUrl, h(PrStageTrack, { repo: R, pr: 101 }));
  assert.match(r.html, /Dequeued: Jobs worker failed on #101 alone/);
  assert.doesNotMatch(r.html, /href="null"/);
  assert.ok(!links(r.html).some((l) => l.text.startsWith('Dequeued')));
});

test('P3 a member of the bisect draft: Failing (the parent check) then Splitting (the draft), in that order', async () => {
  const { html } = await mountWith(BODY, h(PrStageTrack, { repo: R, pr: 102 }));
  const ls = links(html);
  assert.deepEqual(ls, [
    { href: U1, text: 'Failing: Jobs worker' },
    { href: `https://github.com/${R}/pull/9002`, text: 'Splitting: testing #101, #102, step 1 of 2' },
  ]);
  const one = await mountWith(BODY, h(PrStageTrack, { repo: R, pr: 101 }));
  assert.ok(links(one.html).some((l) => l.text === 'Splitting: testing #101 alone, step 2 of 2'));
});

test('P4 no entry, a stage outside the queue track, a load error or no answer render nothing', async () => {
  for (const [body, pr] of [[BODY, 999], [BODY, 104], [new Error('http_503'), 103]]) {
    const { html } = await mountWith(body, h(PrStageTrack, { repo: R, pr }));
    assert.equal(html, '', `pr ${pr}`);
  }
  const none = await mountWith(BODY, h(PrStageTrack, { ticket: 'BH-404', project: 'example' }));
  assert.equal(none.html, '');
  // A key match with a different project is not this ticket.
  const other = await mountWith(BODY, h(PrStageTrack, { ticket: 'BH-103', project: 'project-2' }));
  assert.equal(other.html, '');
});

test('P5 StationTrack with no stations prop is unchanged; with stations it draws those', () => {
  for (const at of [null, 0, 3, 7]) {
    const props = { at, state: 'now', times: ['20:58Z'], label: 'BH-1' };
    assert.equal(render(h(StationTrack, props)), render(h(StationTrack, { ...props, stations: STATIONS })));
  }
  assert.deepEqual(QUEUE_STATIONS, ['Queued', 'In batch', 'Checks', 'Merging', 'Merged', 'Deploy verified']);
  const out = render(h(StationTrack, { at: 2, state: 'now', stations: QUEUE_STATIONS }));
  assert.deepEqual([...out.matchAll(/<span class="lbl">([^<]*)<\/span>/g)].map((m) => m[1]), QUEUE_STATIONS);
  assert.deepEqual([...out.matchAll(/<span class="node">([^<]*)<\/span>/g)].map((m) => m[1]), ['01', '02', '03', '04', '05', '06']);
  assert.match(out, /width:calc\(\(100% - 28px\) \* 0\.4\)/);
  assert.match(out, /aria-label="at Checks \(now\)"|aria-label="Checks \(now\)"/);
});

const JOB = (n) => ({
  id: `build-example-BH-1-${n}`, status: 'running', project: 'example', kind: 'build', ticket_id: 'BH-1',
  box: 'project-3', attempts: 1, spent_usd: 1, budget_usd: 5, age_s: 60, activity_age_s: 5, heartbeating: false,
  created_at: '2026-10-09T03:00:00Z', phase: null,
});

test('P6 the real TicketView for BH-1 shows the dequeue line; three tracks make one request', async () => {
  const rows = jobRows({ jobs: [JOB(1), JOB(2), JOB(3)] });
  assert.equal(rows.length, 3);
  const { html, calls } = await mountWith(BODY, h(TicketView, { ticket: 'BH-1', rows, asOf: AT }));
  assert.ok(links(html).some((l) => l.href === U3 && l.text === 'Dequeued: Jobs worker failed on #101 alone'));
  assert.equal((html.match(/Dequeued: Jobs worker failed on #101 alone/g) || []).length, 3, 'one track per job row');
  assert.equal(calls, 1, 'the tracks share one poll');
});
