import test from 'node:test';
import assert from 'node:assert/strict';
import { h, render as mount } from 'preact';
import { flush } from './helpers/settle.js';

// BH-5430: the merge-queue break-risk score in Mission Control. The pure lib is
// driven directly, the MERGE QUEUE view is rendered server-side (the
// merge-queue.bh-3158 split) and mounted into a small fake DOM for the header
// clicks, and the api helper is driven against a stubbed fetch.

globalThis.window = globalThis.window || {
  location: { pathname: '/merge-queue', search: '', hash: '' },
  dispatchEvent() {}, addEventListener() {}, removeEventListener() {},
  history: { pushState() {}, replaceState() {} }, scrollTo() {},
  localStorage: { getItem() { return null; }, setItem() {} }
};

const { render } = await import('preact-render-to-string');
const { api } = await import('../src/api.js');
const { QR_READ_LIMIT, latestByPr, scoreFor, riskBadge, reasonLines, riskTarget } = await import('../src/lib/queue-risk.js');
const { MergeQueueView } = await import('../src/screens/MergeQueue.js');

const REPO = 'example-org/cromford';
const T1 = '2026-10-08T10:00:00Z';
const T2 = '2026-10-08T11:00:00Z';
const T3 = '2026-10-08T12:00:00Z';
const REASONS = 'shared_lib:+30(bin/lib/x.sh),registry:+25(catalog/y.tsv)';
const score = (id, pr, over = {}) => ({
  id, repo: REPO, pr, head_sha: 'a'.repeat(40), project: 'cromford', score: 55, threshold: 50,
  route: 'solo', mode: 'enforce', reasons: REASONS, created_at: T1, updated_at: T1, ...over
});
const mq = (pr, over = {}) => ({ project: 'cromford', pr, status: 'queued', repo: REPO, reason: `r${pr}`,
  enqueued_by: 'conductor', enqueued_at: T1, updated_at: T1, ...over });
const okRes = (data) => ({ data, error: null, loading: false, reload() {} });
const errRes = (msg = 'boom') => ({ data: null, error: new Error(msg), loading: false, reload() {} });
const visible = (s) => s.replace(/<[^>]*>/g, ' ').replace(/&amp;/g, '&').replace(/\s+/g, ' ');

const baseProps = (over = {}) => ({
  project: null,
  mq: [okRes({ merge_queue: [mq(41), mq(42)] }), okRes({ merge_queue: [] }), okRes({ merge_queue: [] })],
  held: okRes({ rows: [], n_total: 0 }),
  mqChanges: okRes({ changes: [] }),
  heldChanges: okRes({ changes: [] }),
  setting: okRes({ key: 'merge_queue_rows_only', setting: null, source: 'none' }),
  reload() {},
  risk: okRes({ rows: [], truncated: false }),
  tier: null,
  onTier() {},
  qrisk: okRes({ rows: [score(1, 41)], truncated: false }),
  riskOpen: null,
  nowMs: Date.parse(T3),
  ...over
});
const view = (over) => render(h(MergeQueueView, baseProps(over)));
// The MERGE QUEUE section only: it ends where RISK TIERS begins.
const queuePart = (out) => out.slice(out.indexOf('<span class="section__title">MERGE QUEUE</span>'), out.indexOf('RISK TIERS'));
// The <td> holding the BREAK RISK cell of the row whose PR link is #<pr>.
const rowOf = (out, pr) => {
  const part = queuePart(out);
  const at = part.indexOf(`>#${pr}<`);
  assert.ok(at >= 0, `no queue row for #${pr}`);
  const start = part.lastIndexOf('<tr', at);
  return part.slice(start, part.indexOf('</tr>', at) + 5);
};
const riskCell = (tr) => {
  const at = tr.indexOf('class="qr-cell"');
  assert.ok(at >= 0, `no BREAK RISK cell in ${tr}`);
  return tr.slice(tr.lastIndexOf('<', at), tr.indexOf('</td>', at));
};

// ------------------------------------------------------------ C1 the lib

test('C1 latestByPr keeps the newest row per repo#pr (updated_at, then id); bad input is an empty map', () => {
  const rows = [
    score(1, 41, { updated_at: T1, route: 'batch', score: 10 }),
    score(3, 41, { updated_at: T3, route: 'solo', score: 80, head_sha: 'b'.repeat(40) }),
    score(2, 41, { updated_at: T2, route: 'batch', score: 20 }),
    score(4, 42, { updated_at: T1 }),
    score(5, 42, { updated_at: T1, score: 90 }),
    score(6, 41, { repo: 'example-org/other', project: 'other', updated_at: T1, score: 1 }),
  ];
  const m = latestByPr(rows);
  assert.equal(m.get('example-org/cromford#41').id, 3, 'newest updated_at wins, whatever the input order');
  assert.equal(m.get('example-org/cromford#42').id, 5, 'a tie on updated_at goes to the higher id');
  assert.equal(m.get('example-org/other#41').id, 6, 'repos never mix');
  assert.equal(m.size, 3);
  assert.equal(latestByPr(null).size, 0);
  assert.equal(latestByPr([null, {}, { repo: REPO }]).size, 0);
  assert.equal(QR_READ_LIMIT, 200);
  // A queue row joins on repo + pr; a row with no repo falls back to project.
  assert.equal(scoreFor(m, mq(41)).id, 3);
  assert.equal(scoreFor(m, mq(41, { repo: null })).id, 3);
  assert.equal(scoreFor(m, mq(41, { repo: 'example-org/Cromford' })).id, 3);
  assert.equal(scoreFor(m, mq(99)), null);
  assert.equal(scoreFor(m, mq(41, { repo: null, project: 'project-3' })), null);
});

test('C1 riskBadge and reasonLines: plain words, never a guess', () => {
  const b = riskBadge(score(1, 41));
  assert.equal(b.label, 'solo');
  assert.equal(b.score, 55);
  assert.equal(b.title, 'shared lib +30 (bin/lib/x.sh), registry +25 (catalog/y.tsv)');
  assert.deepEqual(riskBadge(null), { label: '—', score: null, title: 'no break-risk score recorded for this PR' });
  assert.equal(riskBadge(score(1, 41, { route: 'weird' })).label, '—');
  const nul = riskBadge(score(1, 41, { score: null, route: 'batch', reasons: 'files-unavailable' }));
  assert.deepEqual([nul.label, nul.score, nul.title], ['batch', null, 'files unavailable']);
  assert.deepEqual(reasonLines('shared_lib:+30(bin/lib/x.sh),rows-unreadable,size:+15(412 lines, 3 files)'), [
    { signal: 'shared lib', weight: 30, path: 'bin/lib/x.sh', text: 'shared lib +30 (bin/lib/x.sh)' },
    { signal: 'rows unreadable', weight: null, path: null, text: 'rows unreadable' },
    { signal: 'size', weight: 15, path: '412 lines, 3 files', text: 'size +15 (412 lines, 3 files)' },
  ]);
  assert.deepEqual(reasonLines(''), []);
  assert.deepEqual(reasonLines(null), []);
  assert.deepEqual(riskTarget('example-org/cromford', '#41'), { repo: 'example-org/cromford', pr: 41 });
  assert.equal(riskTarget('example-org/cromford', ''), null);
  assert.equal(riskTarget(null, '#41'), null);
  assert.equal(riskTarget('x', '#abc'), null);
});

test('C1 api.queueRisk reads GET /api/coord/queue-risk with only the filters given', async () => {
  const seen = [];
  const real = globalThis.fetch;
  globalThis.fetch = async (url, init = {}) => {
    seen.push({ url: String(url), method: init.method || 'GET' });
    return new Response('{"rows":[],"truncated":false}', { status: 200, headers: { 'content-type': 'application/json' } });
  };
  try {
    await api.queueRisk({ repo: REPO, pr: 41, route: 'solo', limit: 200 });
    await api.queueRisk({ limit: QR_READ_LIMIT });
    await api.queueRisk();
  } finally { globalThis.fetch = real; }
  assert.equal(seen[0].url, '/api/coord/queue-risk?repo=example-org%2Fcromford&pr=41&route=solo&limit=200');
  assert.equal(seen[1].url, '/api/coord/queue-risk?limit=200');
  assert.equal(seen[2].url, '/api/coord/queue-risk');
  assert.ok(seen.every((s) => s.method === 'GET'));
});

// ------------------------------------------------------------ C2 the badge

test('C2 a queue row with a matching score row renders BREAK RISK "solo 55", reasons in title=, a link to ?project=&risk=#pr', () => {
  const out = view();
  const part = queuePart(out);
  assert.match(part, /BREAK RISK/);
  const cell = riskCell(rowOf(out, 41));
  assert.equal(visible(cell).trim(), 'solo 55');
  assert.match(cell, /class="tag tag--warn"/, 'solo is the warn style');
  assert.match(cell, /title="shared lib \+30 \(bin\/lib\/x\.sh\), registry \+25 \(catalog\/y\.tsv\)"/);
  assert.match(cell, /href="\/merge-queue\?project=cromford&amp;risk=example-org%2Fcromford#41"/);
  // batch is plain.
  const batch = riskCell(rowOf(view({ qrisk: okRes({ rows: [score(1, 41, { route: 'batch', score: 0, reasons: '' })] }) }), 41));
  assert.equal(visible(batch).trim(), 'batch 0');
  assert.match(batch, /class="tag"/);
  assert.doesNotMatch(batch, /tag--warn/);
  // The newest row for the PR is the one shown.
  const newer = riskCell(rowOf(view({ qrisk: okRes({ rows: [score(1, 41), score(2, 41, { updated_at: T2, route: 'batch', score: 30 })] }) }), 41));
  assert.equal(visible(newer).trim(), 'batch 30');
});

test('C2 ?risk=<repo>#<pr> expands a reasons row under that queue row: each signal, its weight and its path', () => {
  const closed = queuePart(view());
  assert.doesNotMatch(closed, /class="tbl-expand"/);
  const out = view({ riskOpen: { repo: REPO, pr: 41 } });
  const part = queuePart(out);
  const tr41 = part.indexOf('>#41<');
  const reasonsAt = part.indexOf('<tr class="tbl-expand"');
  assert.ok(reasonsAt > tr41, 'the reasons row is under #41');
  assert.ok(reasonsAt < part.indexOf('>#42<'), 'and above the next row');
  const reasons = part.slice(reasonsAt, part.indexOf('</tr>', reasonsAt));
  assert.match(reasons, /^<tr class="tbl-expand" id="41"/, 'the fragment target');
  assert.match(reasons, /class="qr-reasons"/);
  assert.match(reasons, /colspan="\d+"/);
  const v = visible(reasons);
  for (const s of ['shared lib', '+30', 'bin/lib/x.sh', 'registry', '+25', 'catalog/y.tsv', 'threshold 50', 'enforce']) {
    assert.ok(v.includes(s), `reasons row is missing ${s}: ${v}`);
  }
  // Another repo's #41 does not open it.
  assert.doesNotMatch(queuePart(view({ riskOpen: { repo: 'example-org/other', pr: 41 } })), /class="tbl-expand"/);
});

// ------------------------------------------------------------ C3 no score

test('C3 a queue row with no score row reads —, never low or batch', () => {
  const out = view();
  const cell = riskCell(rowOf(out, 42));
  assert.equal(visible(cell).trim(), '—');
  assert.doesNotMatch(cell, /low|batch|solo/i);
  assert.doesNotMatch(cell, /href=/, 'nothing to drill into');
});

// ------------------------------------------------------------ C4 the sort, clicked

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
    // preact names an event 'click' (not 'Click') only when the node has the
    // onclick property, as a real element does.
    this.onclick = null;
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
const all = (n, pred, acc = []) => { if (pred(n)) acc.push(n); n.childNodes.forEach((c) => all(c, pred, acc)); return acc; };

test('C4 BREAK RISK sorts by the numeric score, null last both ways, and aria-sort follows the clicks', async () => {
  const doc = new FakeNode(9, '#document');
  doc.createElement = (t) => new FakeNode(1, t);
  doc.createElementNS = (_, t) => new FakeNode(1, t);
  doc.createTextNode = (d) => new FakeNode(3, null, d);
  globalThis.document = doc;
  const root = doc.createElement('div');
  // Input order 41, 42, 43, 44: no score, 9 (beats "10" only as a number), 100, 10.
  const props = baseProps({
    mq: [okRes({ merge_queue: [mq(41), mq(42), mq(43), mq(44)] }), okRes({ merge_queue: [] }), okRes({ merge_queue: [] })],
    qrisk: okRes({ rows: [score(2, 42, { score: 9, route: 'batch' }), score(3, 43, { score: 100 }), score(4, 44, { score: 10, route: 'batch' })] }),
  });
  try {
    mount(h(MergeQueueView, props), root);
    await flush();
    const table = all(root, (n) => n.localName === 'table')[0];
    const th = all(table, (n) => n.localName === 'th').find((n) => /BREAK RISK/.test(n.textContent));
    assert.ok(th, 'no BREAK RISK header');
    assert.equal(th.getAttribute('aria-sort'), 'none');
    const order = () => all(table, (n) => n.localName === 'tbody')[0].childNodes
      .filter((tr) => tr.localName === 'tr').map((tr) => (tr.textContent.match(/#(\d+)/) || [])[1]);
    const click = async () => {
      const btn = all(th, (n) => n.localName === 'button')[0];
      btn.listeners.click.call(btn, { type: 'click', target: btn, currentTarget: btn, preventDefault() {} });
      await flush();
    };
    await click();
    assert.equal(th.getAttribute('aria-sort'), 'ascending');
    assert.deepEqual(order(), ['42', '44', '43', '41'], 'ascending: 9, 10, 100, then no score');
    await click();
    assert.equal(th.getAttribute('aria-sort'), 'descending');
    assert.deepEqual(order(), ['43', '44', '42', '41'], 'descending: 100, 10, 9, and no score still last');
  } finally {
    mount(null, root);
  }
});

// ------------------------------------------------------------ C5 a failed read

test('C5 a failed queueRisk read keeps the queue table, shows — in the column and says the scores are unreadable', () => {
  const out = view({ qrisk: errRes('coord 502') });
  const part = queuePart(out);
  assert.match(part, /<table/);
  assert.match(part, />#41</);
  assert.match(part, />#42</);
  assert.equal(visible(riskCell(rowOf(out, 41))).trim(), '—');
  assert.equal(visible(riskCell(rowOf(out, 42))).trim(), '—');
  assert.match(visible(part), /break-risk scores unreadable: coord 502/);
  assert.doesNotMatch(visible(part), /could not load/, 'no ErrorBox: the queue is still readable');
  // The rest of the screen is not blanked.
  for (const s of ['RISK TIERS', 'HELD PAGES', 'RECENT CONTROL CHANGES']) assert.match(out, new RegExp(s));
  // A read that came back without a rows array is a failed read too, not "no scores".
  assert.match(visible(queuePart(view({ qrisk: okRes({}) }))), /break-risk scores unreadable/);
  // A good read with nothing for a PR says nothing about unreadable.
  assert.doesNotMatch(visible(queuePart(view())), /unreadable/);
  // Truncated says so.
  assert.match(visible(queuePart(view({ qrisk: okRes({ rows: [score(1, 41)], truncated: true }) }))), /newest 200 scores only/);
});
