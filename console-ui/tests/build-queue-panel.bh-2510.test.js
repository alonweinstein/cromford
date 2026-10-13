import test, { afterEach, mock } from 'node:test';
import assert from 'node:assert/strict';
import { h } from 'preact';
import { render } from 'preact-render-to-string';
import {
  BUILD_STATUSES, ACTION_COPY, buildQueueState, allowedActions, actionBody, buildCells, actionMessage
} from '../src/lib/build-queue-panel.js';
import BuildQueuePanel, { BuildQueueView } from '../src/screens/BuildQueuePanel.js';
import { flush } from './helpers/settle.js';

// BH-3151 (BH-2510.1): the BUILD QUEUE table on /p/<project>. The pure half
// (which action a row offers, the body sent, the banner read off the answer)
// and the rendered table, driven through the real screen with a faked fetch.

const ok = (queue) => ({ data: { queue }, error: null });
const rows = (n, status = 'queued') => Array.from({ length: n }, (_, i) => ({ ticket_key: `BH-${i}`, status }));

test('BUILD_STATUSES: the three live statuses, one read each', () => {
  assert.deepEqual(BUILD_STATUSES, ['ready', 'queued', 'claimed']);
});

test('allowedActions: claimed releases, queued and ready drop, everything else nothing', () => {
  assert.deepEqual(allowedActions({ status: 'claimed' }), ['release']);
  assert.deepEqual(allowedActions({ status: 'queued' }), ['drop']);
  assert.deepEqual(allowedActions({ status: 'ready' }), ['drop']);
  assert.deepEqual(allowedActions({ status: 'done' }), []);
  assert.deepEqual(allowedActions({ status: 'failed' }), []);
  assert.deepEqual(allowedActions({ status: 'dropped' }), []);
  assert.deepEqual(allowedActions({ status: 'weird' }), []);
  assert.deepEqual(allowedActions({}), []);
  assert.deepEqual(allowedActions(null), []);
});

test('actionBody: never carries actor, even when the row has one; reason trimmed', () => {
  const b = actionBody('p', { ticket_key: 'BH-1', status: 'claimed', actor: 'forged' }, 'release', '  dead box  ');
  assert.deepEqual(b, { project: 'p', key: 'BH-1', action: 'release', reason: 'dead box' });
  assert.equal('actor' in b, false);
});

test('buildCells: ages are null when the stamp is absent, never 0', (t) => {
  // clock pinned so the 5-minute age is exact, not a race with the real clock
  const NOW = Date.parse('2026-09-28T12:00:00Z');
  mock.timers.enable({ apis: ['Date'], now: NOW });
  t.after(() => mock.timers.reset());
  const c = buildCells({ ticket_key: 'BH-1', status: 'queued', target: 'fly', attempt: 0, claimed_by: null, machine: null,
    enqueued_at: new Date(NOW - 5 * 60000).toISOString(), claimed_at: null });
  assert.equal(c.key, 'BH-1');
  assert.equal(c.status, 'queued');
  assert.equal(c.target, 'fly');
  assert.equal(c.attempt, 0);
  assert.equal(c.claimed_by, null);
  assert.equal(c.machine, null);
  assert.equal(c.enqueuedMin, 5);
  assert.equal(c.claimedMin, null);
  assert.equal(buildCells({ ticket_key: 'x' }).enqueuedMin, null);
});

test('buildQueueState: loading until every read has answered', () => {
  const s = buildQueueState([ok([]), { data: null, error: null }, ok([])]);
  assert.equal(s.kind, 'loading');
});

test('buildQueueState: one failed read is an error, never an empty table', () => {
  const err = new Error('boom');
  const s = buildQueueState([ok(rows(2)), { data: null, error: err }, ok([])]);
  assert.equal(s.kind, 'error');
  assert.equal(s.error, err);
  // a failed refresh still holding stale rows is an error too
  const stale = buildQueueState([ok([]), ok([]), { data: { queue: rows(3) }, error: err }]);
  assert.equal(stale.kind, 'error');
  // a body without its array is an error
  assert.equal(buildQueueState([ok([]), { data: {}, error: null }, ok([])]).kind, 'error');
});

test('buildQueueState: capped per read (each has its own 500 clamp), not on the combined count', () => {
  assert.equal(buildQueueState([ok(rows(500)), ok([]), ok([])]).capped, true);
  const three = buildQueueState([ok(rows(499)), ok(rows(499)), ok(rows(499))]);
  assert.equal(three.kind, 'ok');
  assert.equal(three.capped, false);
  assert.equal(three.rows.length, 1497);
});

test('buildQueueState: ok concatenates the three reads', () => {
  const s = buildQueueState([ok(rows(1, 'ready')), ok(rows(2, 'queued')), ok(rows(1, 'claimed'))]);
  assert.equal(s.kind, 'ok');
  assert.deepEqual(s.rows.map((r) => r.status), ['ready', 'queued', 'queued', 'claimed']);
  assert.equal(s.capped, false);
});

test('ACTION_COPY: the warning each confirm carries', () => {
  assert.match(ACTION_COPY.release.body, /Only release a claim whose build is dead\. A live build keeps running and a second one can start\./);
  assert.match(ACTION_COPY.drop.body, /An explicit relaunch of the ticket can still re-queue it\./);
  assert.equal(ACTION_COPY.release.confirmLabel, 'RELEASE');
  assert.equal(ACTION_COPY.drop.confirmLabel, 'DROP');
});

test('actionMessage: read off the answer\'s decision, never assumed', () => {
  assert.deepEqual(actionMessage('release', { key: 'BH-1', decision: 'released' }), { ok: true, text: 'Released BH-1. It is queued again.' });
  assert.deepEqual(actionMessage('drop', { key: 'BH-1', decision: 'dropped' }), { ok: true, text: 'Dropped BH-1.' });
  assert.deepEqual(actionMessage('drop', { key: 'BH-1', decision: 'already' }), { ok: true, text: 'BH-1 was already dropped.' });
  const e = Object.assign(new Error('HTTP 409'), { status: 409, body: { error: 'row moved, reload', refused: true } });
  const m = actionMessage('drop', null, e);
  assert.equal(m.ok, false);
  assert.match(m.text, /row moved, reload/);
  const none = actionMessage('release', { key: 'BH-1' });
  assert.equal(none.ok, false, 'a 200 without a decision is not a success');
  assert.equal(actionMessage('release', { key: 'BH-1', decision: 'dropped' }).ok, false, 'a decision for the other action is not a success');
});

// ---- the rendered table ----------------------------------------------------
const LIVE = [
  { project: 'p', ticket_key: 'BH-2', status: 'claimed', target: 'fly', attempt: 1, claimed_by: 'fly-pool', machine: 'm-1',
    enqueued_at: '2026-09-28T10:00:00Z', claimed_at: '2026-09-28T10:05:00Z' },
  { project: 'p', ticket_key: 'BH-1', status: 'queued', target: 'local', attempt: 0, claimed_by: null, machine: null,
    enqueued_at: '2026-09-28T09:00:00Z', claimed_at: null },
];

test('BuildQueueView: headers, KEY drill-down, one action button per allowed action', () => {
  const out = render(h(BuildQueueView, { project: 'p', state: { kind: 'ok', rows: LIVE, capped: false }, busy: false, msg: null, onAction() {}, onRetry() {}, onDismiss() {} }));
  for (const hd of ['KEY', 'STATUS', 'TARGET', 'ATTEMPT', 'CLAIMED BY', 'MACHINE', 'ENQUEUED', 'CLAIMED', 'ACTION']) {
    assert.ok(out.includes(`>${hd}`), `header ${hd}`);
  }
  assert.ok(out.includes('href="/history?tab=builds&amp;project=p"'), 'KEY links to the builds history');
  assert.equal((out.match(/>RELEASE</g) || []).length, 1);
  assert.equal((out.match(/>DROP</g) || []).length, 1);
  // default sort is enqueued asc: BH-1 (09:00) before BH-2 (10:00)
  assert.ok(out.indexOf('BH-1') < out.indexOf('BH-2'), 'sorted by enqueued, oldest first');
  assert.ok(out.includes('tablewrap--wide'), 'the table scrolls inside its own wrapper');
  assert.ok(!out.includes('more rows exist'));
});

test('BuildQueueView: empty, capped, error and loading each render distinctly', () => {
  const base = { project: 'p', busy: false, msg: null, onAction() {}, onRetry() {}, onDismiss() {} };
  assert.ok(render(h(BuildQueueView, { ...base, state: { kind: 'ok', rows: [], capped: false } })).includes('nothing queued'));
  assert.ok(render(h(BuildQueueView, { ...base, state: { kind: 'ok', rows: LIVE, capped: true } })).includes('showing the first 500 per status; more rows exist'));
  const err = render(h(BuildQueueView, { ...base, state: { kind: 'error', error: new Error('worker down') } }));
  assert.ok(err.includes('worker down') && err.includes('RETRY'));
  assert.ok(!err.includes('nothing queued'), 'an error is never shown as an empty queue');
  const loading = render(h(BuildQueueView, { ...base, state: { kind: 'loading' } }));
  assert.ok(loading.includes('skel') && !loading.includes('nothing queued'));
  const banner = render(h(BuildQueueView, { ...base, state: { kind: 'ok', rows: [], capped: false }, msg: { ok: false, text: 'row moved, reload' } }));
  assert.ok(banner.includes('row moved, reload') && banner.includes('DISMISS'));
});

// ---- the production component, mounted with a faked fetch -------------------
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
  // preact registers `Click`/`Input` (the on* prop is not a DOM property here)
  // and its proxy looks the handler up by the event's own type, so keep both.
  addEventListener(t, fn) { this.listeners[t.toLowerCase()] = fn; (this.types = this.types || {})[t.toLowerCase()] = t; }
  removeEventListener(t) { delete this.listeners[t.toLowerCase()]; }
  focus() {}
  querySelector() { return null; }
  querySelectorAll() { return []; }
  get textContent() { return this.nodeType === 3 ? String(this.data) : this.childNodes.map((c) => c.textContent).join(''); }
}
const all = (n, out = []) => { out.push(n); n.childNodes.forEach((c) => all(c, out)); return out; };
let mounted = null;
afterEach(async () => {
  if (mounted) { const { render: mount } = await import('preact'); mount(null, mounted); mounted = null; }
});

async function mountPanel(respond) {
  const doc = new FakeNode(9, '#document');
  doc.createElement = (t) => new FakeNode(1, t);
  doc.createElementNS = (_, t) => new FakeNode(1, t);
  doc.createTextNode = (d) => new FakeNode(3, null, d);
  globalThis.document = doc;
  globalThis.window = globalThis.window || { dispatchEvent() {}, addEventListener() {}, removeEventListener() {} };
  const calls = [];
  globalThis.fetch = async (url, init = {}) => {
    const u = String(url);
    calls.push({ url: u, method: init.method || 'GET', body: init.body });
    const [status, body] = respond(u, init);
    return { ok: status < 300, status, text: async () => JSON.stringify(body) };
  };
  const { render: mount } = await import('preact');
  const root = doc.createElement('div');
  mount(h(BuildQueuePanel, { project: 'p' }), root);
  mounted = root;
  await flush();
  return { root, calls };
}
const byText = (root, tag, text) => all(root).filter((n) => n.localName === tag && n.textContent.trim() === text);
// The dialog's own confirm button (the table's button carries the same label).
const modalBtn = (root, text) => {
  const box = all(root).find((n) => n.attrs && n.attrs.class === 'modal__actions');
  return box ? byText(box, 'button', text)[0] : undefined;
};
const input = (root) => all(root).find((n) => n.localName === 'input');
// preact's listener proxy reads `this.l[e.type]`, so an event is fired on its node.
const fire = (node, type, extra = {}) => node.listeners[type].call(node, { type: node.types[type], ...extra });

test('BuildQueuePanel (mounted): three reads, RELEASE through the modal with a reason, banner from the answer, reload', async () => {
  let released = false;
  const { root, calls } = await mountPanel((u, init) => {
    if (init.method === 'POST') { released = true; return [200, { project: 'p', key: 'BH-2', action: 'release', decision: 'released' }]; }
    const s = new URL(u, 'https://x').searchParams.get('status');
    if (s === 'claimed' && !released) return [200, { queue: [LIVE[0]] }];
    if (s === 'queued') return [200, { queue: released ? [LIVE[1], { ...LIVE[0], status: 'queued' }] : [LIVE[1]] }];
    return [200, { queue: [] }];
  });
  assert.deepEqual(calls.map((c) => `${c.method} ${c.url}`).sort(), [
    'GET /api/coord/queue?project=p&status=claimed&limit=500',
    'GET /api/coord/queue?project=p&status=queued&limit=500',
    'GET /api/coord/queue?project=p&status=ready&limit=500',
  ]);
  const rel = byText(root, 'button', 'RELEASE');
  assert.equal(rel.length, 1);
  fire(rel[0], 'click');
  await flush();
  assert.match(root.textContent, /Only release a claim whose build is dead/);
  const confirmBtn = modalBtn(root, 'RELEASE');
  assert.ok(confirmBtn, 'the dialog is open');
  assert.ok(confirmBtn.attrs.disabled !== undefined || confirmBtn.disabled, 'confirm is disabled until a reason is typed');
  const box = input(root);
  fire(box, 'input', { target: { value: 'box died' } });
  await flush();
  const live = modalBtn(root, 'RELEASE');
  assert.ok(!live.disabled && live.attrs.disabled === undefined, 'a reason enables confirm');
  fire(live, 'click');
  await flush();
  await flush();
  const post = calls.filter((c) => c.method === 'POST');
  assert.equal(post.length, 1);
  assert.equal(post[0].url, '/api/coord/queue/action');
  assert.deepEqual(JSON.parse(post[0].body), { project: 'p', key: 'BH-2', action: 'release', reason: 'box died' });
  assert.match(root.textContent, /Released BH-2\. It is queued again\./);
  assert.equal(calls.filter((c) => c.method === 'GET').length, 6, 'the three reads reload after the action');
  assert.equal(byText(root, 'button', 'RELEASE').length, 0, 'the released row now offers DROP');
});

test('BuildQueuePanel (mounted): a refused DROP shows the worker\'s error, not a success', async () => {
  const { root, calls } = await mountPanel((u, init) => {
    if (init.method === 'POST') return [409, { error: 'row moved, reload', refused: true }];
    const s = new URL(u, 'https://x').searchParams.get('status');
    return [200, { queue: s === 'queued' ? [LIVE[1]] : [] }];
  });
  fire(byText(root, 'button', 'DROP')[0], 'click');
  await flush();
  assert.match(root.textContent, /An explicit relaunch of the ticket can still re-queue it/);
  fire(input(root), 'input', { target: { value: 'client said no' } });
  await flush();
  fire(modalBtn(root, 'DROP'), 'click');
  await flush();
  await flush();
  assert.equal(calls.filter((c) => c.method === 'POST').length, 1);
  assert.match(root.textContent, /row moved, reload/);
  assert.doesNotMatch(root.textContent, /Dropped BH-1/);
  assert.equal(byText(root, 'button', 'DROP').length, 1, 'busy is reset: the button is back');
  const back = byText(root, 'button', 'DROP')[0];
  assert.ok(!back.disabled && back.attrs.disabled === undefined, 'the DROP button is enabled again');
});
