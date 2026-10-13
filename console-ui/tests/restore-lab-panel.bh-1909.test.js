import test from 'node:test';
import assert from 'node:assert/strict';
import { render } from 'preact-render-to-string';
import { h, render as mount } from 'preact';
import { api } from '../src/api.js';
import { Modal } from '../src/ui/Modal.js';
import {
  historyView, panelState, requestBody, confirmCopy, confirmOpts, requestOutcome, submitRestore
} from '../src/lib/restore-lab.js';
import { RestoreLabView, RestoreLabPanel } from '../src/screens/hub/RestoreLab.js';
import { flush } from './helpers/settle.js';

// BH-1946 (BH-1909.4): the restore-lab panel of the HUB screen. The payload is
// the GET /api/hub/restore-lab answer in docs/HUB-RECOVERY-MCP.md and the
// restore_lab_runs columns in worker/jobs/schema.sql, and every api call goes
// through the real api object over a fake fetch.

const SHA = 'a'.repeat(64);
const RUN_OK = {
  id: 12, box: 'hub-1', snapshot: 'latest', status: 'ok', requested_by: 'console',
  requested_at: '2026-09-24T10:00:00Z', claimed_by: 'hub-2', claimed_at: '2026-09-24T10:01:00Z',
  finished_at: '2026-09-24T10:09:00Z', verdict_detail: 'restored 4 dbs, integrity ok',
  sha256: SHA, snapshot_ts: '2026-09-24T09:30:00Z'
};
const RUN_OPEN = {
  id: 13, box: 'ops-1', snapshot: 'latest', status: 'requested', requested_by: 'console',
  requested_at: '2026-09-24T11:00:00Z', claimed_by: null, claimed_at: null,
  finished_at: null, verdict_detail: null, sha256: null, snapshot_ts: null
};
const PAYLOAD = { runs: [RUN_OPEN, RUN_OK], truncated: false };
const COPY = "Restores hub-1's latest backup into a scratch dir on the hub and verifies it. Nothing on the live hub is touched.";

// One answer per call, in order; the last answer repeats.
function fakeFetch(...answers) {
  const calls = [];
  globalThis.fetch = async (url, init = {}) => {
    calls.push({ url: String(url), method: init.method || 'GET', body: init.body ? JSON.parse(init.body) : undefined });
    const [status, body] = answers[Math.min(calls.length - 1, answers.length - 1)];
    return { ok: status >= 200 && status < 300, status, text: async () => JSON.stringify(body) };
  };
  return calls;
}

const noop = () => {};
const viewProps = (over = {}) => ({
  state: 'rows', view: historyView(PAYLOAD), error: null, boxes: ['hub-1', 'ops-1'], box: 'hub-1',
  onBox: noop, onRequest: noop, busy: false, openId: null, onToggle: noop, outcome: null, onRetry: noop,
  ...over
});

test('1: history rows render from the contract payload in a sortable table', async () => {
  const calls = fakeFetch([200, PAYLOAD]);
  const payload = await api.restoreLabRuns();
  assert.deepEqual(calls.map((c) => [c.method, c.url]), [['GET', '/api/coord/hub/restore-lab']]);
  const view = historyView(payload);
  assert.equal(panelState({ view, error: null }), 'rows');
  const out = render(h(RestoreLabView, viewProps({ view })));
  assert.match(out, /RESTORE LAB/);
  assert.match(out, /hub-1/);
  assert.match(out, /ops-1/);
  assert.match(out, /class="tablewrap"/);
  const ths = out.match(/<th[^>]*aria-sort="[a-z]+"/g) || [];
  assert.equal(ths.length, 6, `six sortable headers, got ${ths.length}`);
  assert.equal((out.match(/aria-sort="descending"/g) || []).length, 1);
  assert.match(out, /aria-sort="descending"[^>]*>\s*<button[^>]*>\s*REQUESTED\b/);
  // Newest first: ops-1 (11:00) renders before hub-1 (10:00).
  assert.ok(out.indexOf('>ops-1<') < out.indexOf('>hub-1</button>'), 'default sort is requested_at desc');
});

test('2: a deduped answer and a 409 already_open both say a restore is already queued', async () => {
  let calls = fakeFetch([200, { deduped: true, id: 7 }]);
  const a = await submitRestore(api, 'hub-1', true);
  assert.equal(calls.length, 1);
  assert.equal(a.tone, 'warn');
  assert.match(a.text, /already queued/);
  assert.match(a.text, /#7/);
  calls = fakeFetch([409, { error: 'already_open', id: 9 }]);
  const b = await submitRestore(api, 'hub-1', true);
  assert.equal(calls.length, 1);
  assert.equal(b.tone, 'warn');
  assert.match(b.text, /A restore for hub-1 is already queued \(#9\)\./);
  // A 409 that is not already_open is a failure, not "queued".
  fakeFetch([409, { error: 'not_claimed' }]);
  const c = await submitRestore(api, 'hub-1', true);
  assert.equal(c.tone, 'bad');
  assert.doesNotMatch(c.text, /queued/);
});

test('3: a 501 load and a malformed payload are errors, never an empty history', async () => {
  fakeFetch([501, { error: 'not_implemented', ticket: 'BH-1909' }]);
  await assert.rejects(api.restoreLabRuns(), (e) => e.status === 501 && e.message === 'not_implemented');
  assert.equal(panelState({ view: null, error: new Error('not_implemented') }), 'error');
  assert.equal(panelState({ view: null, error: null }), 'loading');
  assert.equal(panelState({ view: historyView({ runs: [] }), error: null }), 'empty');
  for (const bad of [{}, { runs: null }, { runs: 'x' }, null]) {
    assert.throws(() => historyView(bad), /bad response/, JSON.stringify(bad));
  }
});

test('4: the error render and the empty render are distinct', () => {
  const err = render(h(RestoreLabView, viewProps({ state: 'error', view: null, error: new Error('not_implemented') })));
  assert.match(err, /could not load/);
  assert.match(err, /not_implemented/);
  assert.match(err, /RETRY/);
  assert.doesNotMatch(err, /No restore runs yet/);
  const empty = render(h(RestoreLabView, viewProps({ state: 'empty', view: historyView({ runs: [] }) })));
  assert.match(empty, /No restore runs yet/);
  assert.doesNotMatch(empty, /could not load/);
});

test('5: the confirm dialog is the in-app Modal with the exact sentence', () => {
  assert.equal(confirmCopy('hub-1'), COPY);
  const out = render(h(Modal, { ...confirmOpts('hub-1'), onConfirm: noop, onCancel: noop }));
  assert.match(out, /role="dialog"/);
  assert.match(out, /aria-label="RESTORE LAB"/);
  assert.ok(out.includes(COPY.replace("'", '&#39;')) || out.includes(COPY), out);
});

test('6: confirm sends exactly one POST with snapshot latest and confirm:true', async () => {
  const calls = fakeFetch([201, { id: 3, status: 'requested' }]);
  const out = await submitRestore(api, 'hub-1', true);
  assert.equal(calls.length, 1);
  assert.equal(calls[0].method, 'POST');
  assert.equal(calls[0].url, '/api/coord/hub/restore-lab');
  assert.deepEqual(calls[0].body, { box: 'hub-1', snapshot: 'latest', confirm: true });
  assert.equal(out.tone, 'ok');
  assert.match(out.text, /Queued restore #3 for hub-1/);
});

test('7: cancel and every non-true confirm send nothing; failures never read as queued', async () => {
  for (const x of [false, 'true', 1, undefined, null]) {
    const calls = fakeFetch([201, { id: 3 }]);
    assert.equal(await submitRestore(api, 'hub-1', x), null, `confirmed=${JSON.stringify(x)}`);
    assert.equal(calls.length, 0, `confirmed=${JSON.stringify(x)} sent a request`);
  }
  for (const box of ['', '  ', null, undefined, 3]) assert.throws(() => requestBody(box), /box/);
  let calls = fakeFetch([201, { id: 3 }]);
  const blank = await submitRestore(api, '', true);
  assert.equal(calls.length, 0);
  assert.equal(blank.tone, 'bad');
  fakeFetch([200, { ok: true }]);
  const noId = await submitRestore(api, 'hub-1', true);
  assert.equal(noId.tone, 'bad');
  assert.doesNotMatch(noId.text, /Queued/);
  fakeFetch([501, { error: 'not_implemented' }]);
  const stub = await submitRestore(api, 'hub-1', true);
  assert.equal(stub.tone, 'bad');
  assert.match(stub.text, /not_implemented/);
  assert.equal(requestOutcome('hub-1', { error: Object.assign(new Error('x'), { status: 409, body: null }) }).tone, 'bad');
});

test('8: the box cell expands the run to its full row', () => {
  const open = render(h(RestoreLabView, viewProps({ openId: 12 })));
  assert.match(open, /<button[^>]*aria-expanded="true"[^>]*>hub-1<\/button>/);
  assert.match(open, /class="restore-lab__detail"/);
  assert.match(open, /restored 4 dbs, integrity ok/);
  assert.ok(open.includes(SHA), 'full sha256');
  assert.match(open, /2026-09-24T09:30:00Z/);
  assert.match(open, /2026-09-24T10:01:00Z/); // claimed_at
  const closed = render(h(RestoreLabView, viewProps({ openId: null })));
  assert.doesNotMatch(closed, /restore-lab__detail/);
  assert.doesNotMatch(closed, /aria-expanded="true"/);
});

test('9: the truncation note shows only when the worker says truncated', () => {
  const on = render(h(RestoreLabView, viewProps({ view: historyView({ ...PAYLOAD, truncated: true }) })));
  assert.match(on, /showing the last 20 runs/);
  for (const t of [false, undefined, 'true']) {
    const off = render(h(RestoreLabView, viewProps({ view: historyView({ runs: PAYLOAD.runs, truncated: t }) })));
    assert.doesNotMatch(off, /showing the last/, `truncated=${t}`);
  }
});

test('11: with no boxes the request button is disabled and says why', () => {
  const out = render(h(RestoreLabView, viewProps({ boxes: [], box: null })));
  assert.match(out, /<button[^>]*disabled[^>]*>Restore latest into scratch<\/button>/);
  assert.match(out, /no boxes known yet/);
  const live = render(h(RestoreLabView, viewProps()));
  assert.doesNotMatch(live, /<button[^>]*disabled[^>]*>Restore latest into scratch<\/button>/);
});

// ---- 10: the real RestoreLabPanel, mounted and clicked (D2) -----------------
// preact-render-to-string runs no effects or handlers, so this mounts the panel
// into a minimal DOM (only what preact and Modal touch) and drives it: the load
// on mount, the button, the in-app dialog, confirm or cancel, and the reload.

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
  // preact lowercases an event name only when the element has the on* property.
  get onclick() { return null; }
  get onchange() { return null; }
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

const all = (n, out = []) => { out.push(n); n.childNodes.forEach((c) => all(c, out)); return out; };
const button = (root, label) => all(root).find((n) => n.localName === 'button' && n.textContent.trim() === label);
const click = (el) => el.listeners.click.call(el, { type: 'click', target: el, currentTarget: el, preventDefault() {}, stopPropagation() {} });

async function mountPanel(answers) {
  const doc = installDom();
  const calls = fakeFetch(...answers);
  const root = doc.createElement('div');
  mount(h(RestoreLabPanel, { boxes: ['hub-1', 'ops-1'] }), root);
  await flush();
  return { root, calls };
}

test('10: render-to-string of the panel shows the loading section and fetches nothing', () => {
  const calls = fakeFetch([200, PAYLOAD]);
  const out = render(h(RestoreLabPanel, { boxes: ['hub-1'] }));
  assert.match(out, /RESTORE LAB/);
  assert.match(out, /class="skel"/);
  assert.match(out, /Restore latest into scratch/);
  assert.equal(calls.length, 0);
});

test('10: the mounted panel loads history, confirms in the Modal, POSTs once and reloads', async () => {
  const { root, calls } = await mountPanel([[200, PAYLOAD], [201, { id: 14, status: 'requested' }], [200, PAYLOAD]]);
  assert.deepEqual(calls.map((c) => c.method), ['GET']);
  assert.match(root.textContent, /ops-1/);
  assert.doesNotMatch(root.textContent, /could not load/);
  click(button(root, 'Restore latest into scratch'));
  await flush();
  const dialog = all(root).find((n) => n.attrs && n.attrs.role === 'dialog');
  assert.ok(dialog, 'the in-app dialog opened');
  assert.ok(dialog.textContent.includes(COPY), dialog.textContent);
  assert.equal(calls.length, 1, 'opening the dialog sends nothing');
  click(button(root, 'RESTORE'));
  await flush();
  assert.deepEqual(calls.map((c) => [c.method, c.url]), [
    ['GET', '/api/coord/hub/restore-lab'],
    ['POST', '/api/coord/hub/restore-lab'],
    ['GET', '/api/coord/hub/restore-lab'],
  ]);
  assert.deepEqual(calls[1].body, { box: 'hub-1', snapshot: 'latest', confirm: true });
  assert.match(root.textContent, /Queued restore #14 for hub-1\./);
  assert.ok(!all(root).some((n) => n.attrs && n.attrs.role === 'dialog'), 'dialog closed');
});

test('10: cancelling the mounted dialog sends nothing and reloads nothing', async () => {
  const { root, calls } = await mountPanel([[200, PAYLOAD]]);
  click(button(root, 'Restore latest into scratch'));
  await flush();
  click(button(root, 'CANCEL'));
  await flush();
  assert.deepEqual(calls.map((c) => c.method), ['GET']);
  assert.ok(!all(root).some((n) => n.attrs && n.attrs.role === 'dialog'), 'dialog closed');
  assert.doesNotMatch(root.textContent, /Queued/);
});

test('10: the mounted panel shows a 501 load as an error, and the box cell drills down', async () => {
  const failed = await mountPanel([[501, { error: 'not_implemented', ticket: 'BH-1909' }]]);
  assert.match(failed.root.textContent, /could not load/);
  assert.match(failed.root.textContent, /not_implemented/);
  assert.doesNotMatch(failed.root.textContent, /No restore runs yet/);
  const malformed = await mountPanel([[200, { ok: true }]]);
  assert.match(malformed.root.textContent, /bad response/);
  assert.doesNotMatch(malformed.root.textContent, /No restore runs yet/);
  const { root } = await mountPanel([[200, PAYLOAD]]);
  assert.ok(!root.textContent.includes(SHA));
  click(button(root, 'hub-1'));
  await flush();
  assert.ok(root.textContent.includes(SHA), 'expanded run shows its sha256');
  assert.match(root.textContent, /restored 4 dbs, integrity ok/);
});

test('12: a failed refresh keeps the last good rows and says the refresh failed', () => {
  const view = historyView(PAYLOAD);
  const error = new Error('HTTP 502');
  assert.equal(panelState({ view, error }), 'rows');
  const out = render(h(RestoreLabView, viewProps({ view, error })));
  assert.match(out, /ops-1/);
  assert.match(out, /refresh failed: HTTP 502; showing the last answer/);
  assert.doesNotMatch(out, /could not load/);
});

// preact sets `disabled` as an attribute on the fake DOM (it has no such property).
const isDisabled = (n) => n.disabled === true || ('disabled' in n.attrs && n.attrs.disabled !== 'false');

test('13: the button is disabled while the dialog is open, and a double click still sends one POST', async () => {
  const { root, calls } = await mountPanel([[200, PAYLOAD], [201, { id: 15, status: 'requested' }], [200, PAYLOAD]]);
  const btn = button(root, 'Restore latest into scratch');
  click(btn);
  click(btn);
  await flush();
  assert.equal(all(root).filter((n) => n.attrs && n.attrs.role === 'dialog').length, 1, 'one dialog');
  assert.equal(isDisabled(button(root, 'Restore latest into scratch')), true, 'busy while the dialog is open');
  click(button(root, 'RESTORE'));
  await flush();
  assert.deepEqual(calls.map((c) => c.method), ['GET', 'POST', 'GET']);
  assert.match(root.textContent, /Queued restore #15 for hub-1\./);
  assert.equal(isDisabled(button(root, 'Restore latest into scratch')), false, 'enabled again after the POST');
});
