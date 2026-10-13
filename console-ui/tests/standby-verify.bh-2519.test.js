import test from 'node:test';
import assert from 'node:assert/strict';
import { render } from 'preact-render-to-string';
import { h, render as mount } from 'preact';
import { html } from '../src/router.js';
import { Modal } from '../src/ui/Modal.js';
import {
  STANDBY_VERIFY_LIMIT, verifyBody, verifyOutcome, submitVerify, confirmOpts, historyView, lastVerifyByBox
} from '../src/lib/standby-verify.js';
import { useStandbyVerifyRuns, StandbyVerifyCell, StandbyVerifyDetail } from '../src/screens/hub/StandbyVerify.js';
import { flush } from './helpers/settle.js';

// BH-2519 (BH-2642): standby VERIFY from Mission Control. The payload is the
// GET /api/hub/standby/verify answer ({runs, truncated, as_of}) over the
// standby_verify_runs columns in worker/jobs/schema.sql, and every api call in
// the mounted cases goes through the real api object over a fake fetch.

const SHA = 'b'.repeat(64);
const RUN_OK = {
  id: 21, box: 'sb-1', of_hub: 'hub-a', status: 'ok', requested_by: 'console',
  requested_at: '2026-09-26T10:00:00Z', claimed_at: '2026-09-26T10:01:00Z',
  finished_at: '2026-09-26T10:07:00Z', verdict_detail: 'restored 4 dbs, integrity ok',
  sha256: SHA, snapshot_ts: '2026-09-26T09:30:00Z'
};
const RUN_FAIL = {
  id: 19, box: 'sb-1', of_hub: 'hub-a', status: 'fail', requested_by: 'console',
  requested_at: '2026-09-25T10:00:00Z', claimed_at: '2026-09-25T10:01:00Z',
  finished_at: '2026-09-25T10:03:00Z', verdict_detail: 'sha mismatch', sha256: null, snapshot_ts: null
};
const RUN_OTHER = {
  id: 22, box: 'sb-2', of_hub: 'hub-a', status: 'requested', requested_by: 'console',
  requested_at: '2026-09-26T11:00:00Z', claimed_at: null, finished_at: null,
  verdict_detail: null, sha256: null, snapshot_ts: null
};
const PAYLOAD = { runs: [RUN_OTHER, RUN_OK, RUN_FAIL], truncated: false, as_of: '2026-09-26T11:05:00Z' };
const ROW = { box: 'sb-1', of_hub: 'hub-a' };
const COPY = "Runs a scratch restore of hub-a's latest backup ON sb-1 and checks it. Nothing on either live tree is touched.";
const noop = () => {};

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

const httpError = (status, body) => Object.assign(new Error(body.error), { status, body });

// ---- the pure lib ------------------------------------------------------------

test('P5: verifyBody is exactly {box, confirm:true}; a blank box throws', () => {
  assert.deepEqual(verifyBody('sb-1'), { box: 'sb-1', confirm: true });
  for (const b of ['', '  ', null, undefined, 3]) assert.throws(() => verifyBody(b), /box required/, JSON.stringify(b));
  assert.equal(STANDBY_VERIFY_LIMIT, 20);
});

test('P6: deduped reads already queued; 409 unknown_standby and a no-id answer are failures', () => {
  const d = verifyOutcome('sb-1', { result: { deduped: true, id: 8 } });
  assert.equal(d.tone, 'warn');
  assert.equal(d.text, 'A verify for sb-1 is already queued (#8).');
  const u = verifyOutcome('sb-1', { error: httpError(409, { error: 'unknown_standby' }) });
  assert.deepEqual(u, { tone: 'bad', text: 'Verify failed: sb-1 is not a known standby.' });
  const c = verifyOutcome('sb-1', { error: httpError(400, { error: 'confirm_required' }) });
  assert.deepEqual(c, { tone: 'bad', text: 'Verify failed: confirm_required' });
  const noId = verifyOutcome('sb-1', { result: { ok: true } });
  assert.deepEqual(noId, { tone: 'bad', text: 'Verify failed: unexpected answer (no run id).' });
  assert.deepEqual(verifyOutcome('sb-1', { result: { id: 4 } }), { tone: 'ok', text: 'Queued verify #4 for sb-1.' });
});

test('P7: lastVerifyByBox picks the newest run per box whatever the input order', () => {
  const tie = { ...RUN_OK, id: 30 };
  const got = lastVerifyByBox([RUN_FAIL, RUN_OK, RUN_OTHER, { ...RUN_OTHER, id: 2, requested_at: '2026-09-20T00:00:00Z' }]);
  assert.deepEqual(Object.keys(got).sort(), ['sb-1', 'sb-2']);
  assert.equal(got['sb-1'].id, 21);
  assert.equal(got['sb-2'].id, 22);
  assert.equal(lastVerifyByBox([RUN_OK, tie])['sb-1'].id, 30, 'same requested_at: higher id wins');
  assert.equal(lastVerifyByBox([tie, RUN_OK])['sb-1'].id, 30, 'same requested_at: higher id wins either order');
  assert.deepEqual(lastVerifyByBox([]), {});
});

test('P8: submitVerify sends one call only when the dialog answers literally true', async () => {
  for (const x of [false, 'true', 1, undefined, {}]) {
    let sent = 0;
    const apiObj = { standbyVerify: async () => { sent++; return { id: 1 }; } };
    assert.equal(await submitVerify(async () => x, apiObj, 'sb-1'), null, JSON.stringify(x));
    assert.equal(sent, 0, `ask=${JSON.stringify(x)} sent a request`);
  }
  const bodies = [];
  const apiObj = { standbyVerify: async (b) => { bodies.push(b); return { id: 9, status: 'requested', deduped: false }; } };
  const out = await submitVerify(async () => true, apiObj, 'sb-1');
  assert.deepEqual(bodies, [{ box: 'sb-1', confirm: true }]);
  assert.deepEqual(out, { tone: 'ok', text: 'Queued verify #9 for sb-1.' });
  const thrown = await submitVerify(async () => true,
    { standbyVerify: async () => { throw httpError(409, { error: 'unknown_standby' }); } }, 'sb-1');
  assert.equal(thrown.tone, 'bad');
  assert.doesNotMatch(thrown.text, /Queued/);
});

test('P9: a payload with no runs array is an error, never an empty history', () => {
  for (const bad of [{}, { runs: null }, { runs: 'x' }, null, { error: 'not_implemented' }]) {
    assert.throws(() => historyView(bad), /bad response/, JSON.stringify(bad));
  }
  assert.equal(historyView({ runs: [], truncated: 'true' }).truncated, false);
  assert.equal(historyView({ runs: [], truncated: true }).truncated, true);
});

test('confirmOpts is the in-app Modal with the exact title, body and labels', () => {
  const opts = confirmOpts('sb-1', 'hub-a');
  assert.deepEqual(opts, { title: 'VERIFY STANDBY', body: COPY, confirmLabel: 'VERIFY', cancelLabel: 'CANCEL', tone: 'warn' });
  const out = render(h(Modal, { ...opts, onConfirm: noop, onCancel: noop }));
  assert.match(out, /aria-label="VERIFY STANDBY"/);
  assert.match(out, />CANCEL</);
  assert.match(out, />VERIFY</);
});

// ---- render-to-string: the cell and the detail -------------------------------

test('R1: the cell shows the pill, an age and VERIFY; with no last run it reads never verified', () => {
  const ok = render(h(StandbyVerifyCell, { row: ROW, last: RUN_OK, onQueued: noop }));
  assert.match(ok, /class="tag tag--green"[^>]*>ok</);
  assert.match(ok, /\b\d+[mhd] ago\b/);
  assert.match(ok, /<button[^>]*class="btn btn--warn"[^>]*>VERIFY<\/button>/);
  assert.doesNotMatch(ok, /never verified/);
  const failed = render(h(StandbyVerifyCell, { row: ROW, last: RUN_FAIL, onQueued: noop }));
  assert.match(failed, /class="tag tag--bad"[^>]*>fail</);
  const open = render(h(StandbyVerifyCell, { row: ROW, last: RUN_OTHER, onQueued: noop }));
  assert.match(open, /class="tag tag--warn"[^>]*>requested</);
  const never = render(h(StandbyVerifyCell, { row: ROW, last: undefined, onQueued: noop }));
  assert.match(never, /never verified/);
  assert.match(never, />VERIFY<\/button>/);
});

test('R6: the detail lists this box\'s runs in a sortable table; a run expands; truncated says so', () => {
  const out = render(h(StandbyVerifyDetail, { box: 'sb-1', runs: PAYLOAD.runs, error: null, onRetry: noop }));
  assert.match(out, /class="tablewrap"/);
  const ths = out.match(/<th[^>]*aria-sort="[a-z]+"/g) || [];
  assert.equal(ths.length, 4, `four sortable headers, got ${ths.length}`);
  assert.match(out, /aria-sort="descending"[^>]*>\s*<button[^>]*>\s*REQUESTED\b/);
  assert.doesNotMatch(out, /2026-09-26T11:00:00Z/, 'sb-2 run is not in sb-1 detail');
  assert.ok(out.indexOf('2026-09-26T10:00:00Z') < out.indexOf('2026-09-25T10:00:00Z'), 'newest first');
  assert.match(out, /<button[^>]*aria-expanded="false"[^>]*>ok<\/button>/);
  assert.ok(!out.includes(SHA), 'collapsed by default');
  assert.doesNotMatch(out, /showing the last/);
  const trunc = render(h(StandbyVerifyDetail, { box: 'sb-1', runs: PAYLOAD.runs, error: null, onRetry: noop, truncated: true }));
  assert.match(trunc, /showing the last 20 runs/);
});

test('R7: a load error with no runs renders the error and RETRY, never "never verified"', async () => {
  const out = render(h(StandbyVerifyDetail, { box: 'sb-1', runs: [], error: new Error('HTTP 502'), onRetry: noop }));
  assert.match(out, /could not load/);
  assert.match(out, /HTTP 502/);
  assert.match(out, /RETRY/);
  assert.doesNotMatch(out, /never verified/i);
  const empty = render(h(StandbyVerifyDetail, { box: 'sb-1', runs: [], error: null, onRetry: noop }));
  assert.match(empty, /Never verified/);
  assert.doesNotMatch(empty, /could not load/);
  const stale = render(h(StandbyVerifyDetail, { box: 'sb-1', runs: PAYLOAD.runs, error: new Error('HTTP 502'), onRetry: noop }));
  assert.match(stale, /refresh failed: HTTP 502/);
  assert.match(stale, /aria-sort/);
  // RETRY really calls onRetry, on the mounted detail.
  const doc = installDom();
  const root = doc.createElement('div');
  let retried = 0;
  mount(h(StandbyVerifyDetail, { box: 'sb-1', runs: [], error: new Error('HTTP 502'), onRetry: () => { retried++; } }), root);
  await flush();
  click(button(root, 'RETRY'));
  assert.equal(retried, 1);
});

// ---- mounted: a minimal DOM (the restore-lab-panel.bh-1909 pattern) -----------

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
  get onchange() { return null; }
  get onkeydown() { return null; }
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
const dialogOf = (root) => all(root).find((n) => n.attrs && n.attrs.role === 'dialog');
const click = (el) => el.listeners.click.call(el, { type: 'click', target: el, currentTarget: el, preventDefault() {}, stopPropagation() {} });
const isDisabled = (n) => n.disabled === true || ('disabled' in n.attrs && n.attrs.disabled !== 'false');

function mountCell(answers) {
  const doc = installDom();
  const calls = fakeFetch(...answers);
  const root = doc.createElement('div');
  const queued = [];
  mount(h(StandbyVerifyCell, { row: ROW, last: RUN_OK, onQueued: () => queued.push(1) }), root);
  return { doc, root, calls, queued };
}

test('R2: VERIFY opens the in-app dialog; confirming POSTs {box, confirm:true} once, then onQueued', async () => {
  const { root, calls, queued } = mountCell([[201, { id: 31, status: 'requested', run: {}, deduped: false }]]);
  await flush();
  click(button(root, 'VERIFY'));
  await flush();
  const dialog = dialogOf(root);
  assert.ok(dialog, 'the in-app dialog opened');
  assert.equal(dialog.attrs['aria-label'], 'VERIFY STANDBY');
  assert.ok(dialog.textContent.includes(COPY), dialog.textContent);
  assert.equal(calls.length, 0, 'opening the dialog sends nothing');
  const confirmBtn = all(dialog).find((n) => n.localName === 'button' && n.textContent.trim() === 'VERIFY');
  click(confirmBtn);
  await flush();
  assert.deepEqual(calls.map((c) => [c.method, c.url]), [['POST', '/api/coord/hub/standby/verify']]);
  assert.deepEqual(calls[0].body, { box: 'sb-1', confirm: true });
  assert.equal(queued.length, 1, 'onQueued called once');
  assert.match(root.textContent, /Queued verify #31 for sb-1\./);
  assert.ok(!dialogOf(root), 'dialog closed');
  assert.equal(isDisabled(button(root, 'VERIFY')), false, 'enabled again after the POST');
});

test('R2b: a 409 unknown_standby answer is failure text, and still reloads the history', async () => {
  const { root, calls, queued } = mountCell([[409, { error: 'unknown_standby' }]]);
  await flush();
  click(button(root, 'VERIFY'));
  await flush();
  click(all(dialogOf(root)).find((n) => n.localName === 'button' && n.textContent.trim() === 'VERIFY'));
  await flush();
  assert.equal(calls.length, 1);
  assert.match(root.textContent, /Verify failed: sb-1 is not a known standby\./);
  assert.doesNotMatch(root.textContent, /Queued/);
  assert.equal(queued.length, 1);
});

test('R3: CANCEL, Escape and a double click send nothing extra', async () => {
  {
    const { root, calls, queued } = mountCell([[201, { id: 1 }]]);
    await flush();
    click(button(root, 'VERIFY'));
    await flush();
    click(button(root, 'CANCEL'));
    await flush();
    assert.equal(calls.length, 0, 'cancel sent a POST');
    assert.equal(queued.length, 0);
    assert.ok(!dialogOf(root));
    assert.equal(isDisabled(button(root, 'VERIFY')), false, 'enabled again after cancel');
  }
  {
    const { doc, root, calls, queued } = mountCell([[201, { id: 1 }]]);
    await flush();
    click(button(root, 'VERIFY'));
    await flush();
    assert.ok(dialogOf(root));
    doc.listeners.keydown({ key: 'Escape', preventDefault() {} });
    await flush();
    assert.equal(calls.length, 0, 'escape sent a POST');
    assert.equal(queued.length, 0);
    assert.ok(!dialogOf(root), 'escape closed the dialog');
  }
  {
    const { root, calls, queued } = mountCell([[201, { id: 2 }]]);
    await flush();
    const btn = button(root, 'VERIFY');
    click(btn);
    click(btn);
    await flush();
    assert.equal(all(root).filter((n) => n.attrs && n.attrs.role === 'dialog').length, 1, 'one dialog');
    const outer = all(root).find((n) => n.localName === 'button' && n.textContent.trim() === 'VERIFY' && !all(dialogOf(root)).includes(n));
    assert.equal(isDisabled(outer), true, 'busy while the dialog is open');
    click(all(dialogOf(root)).find((n) => n.localName === 'button' && n.textContent.trim() === 'VERIFY'));
    await flush();
    assert.equal(calls.length, 1, 'double click sent one POST');
    assert.equal(queued.length, 1);
  }
});

// The hook, mounted in a harness component that renders what it returns.
function Harness({ reloadKey, onValue }) {
  const v = useStandbyVerifyRuns(reloadKey);
  onValue(v);
  return html`<div>${v.runs.map((r) => html`<span key=${r.id}>run-${r.id} </span>`)}${v.error ? html`<b>err:${v.error.message}</b>` : null}</div>`;
}

test('R4: the hook GETs on mount and again on a reloadKey change; lastByBox is keyed by box', async () => {
  const doc = installDom();
  const calls = fakeFetch([200, PAYLOAD]);
  const root = doc.createElement('div');
  let last;
  mount(h(Harness, { reloadKey: 1, onValue: (v) => { last = v; } }), root);
  await flush();
  assert.deepEqual(calls.map((c) => [c.method, c.url]), [['GET', '/api/coord/hub/standby/verify']]);
  assert.deepEqual(Object.keys(last).sort(), ['error', 'lastByBox', 'reload', 'runs', 'truncated']);
  assert.equal(last.runs.length, 3);
  assert.equal(last.lastByBox['sb-1'].id, 21);
  assert.equal(last.lastByBox['sb-2'].id, 22);
  assert.equal(last.truncated, false);
  assert.equal(last.error, null);
  mount(h(Harness, { reloadKey: 2, onValue: (v) => { last = v; } }), root);
  await flush();
  assert.equal(calls.length, 2, 'reloadKey change refetches');
  last.reload();
  await flush();
  assert.equal(calls.length, 3, 'reload() refetches');
  // A failed refresh keeps the last good runs and sets error beside them.
  fakeFetch([502, { error: 'bad gateway' }]);
  last.reload();
  await flush();
  assert.equal(last.runs.length, 3, 'last good runs kept');
  assert.match(String(last.error && last.error.message), /bad gateway/);
  // A malformed answer is an error, not an empty history.
  const doc2 = installDom();
  fakeFetch([200, { ok: true }]);
  const root2 = doc2.createElement('div');
  mount(h(Harness, { reloadKey: 1, onValue: (v) => { last = v; } }), root2);
  await flush();
  assert.equal(last.runs.length, 0);
  assert.match(String(last.error && last.error.message), /bad response/);
});

test('R5: a stale response never overwrites a newer one', async () => {
  const doc = installDom();
  const pending = [];
  globalThis.fetch = (url, init = {}) => new Promise((resolve) => {
    pending.push((status, body) => resolve({ ok: status >= 200 && status < 300, status, text: async () => JSON.stringify(body) }));
  });
  const root = doc.createElement('div');
  let last;
  mount(h(Harness, { reloadKey: 1, onValue: (v) => { last = v; } }), root);
  await flush();
  mount(h(Harness, { reloadKey: 2, onValue: (v) => { last = v; } }), root);
  await flush();
  assert.equal(pending.length, 2, 'two GETs in flight');
  pending[1](200, { runs: [RUN_OTHER], truncated: false });
  await flush();
  pending[0](200, { runs: [RUN_OK, RUN_FAIL], truncated: true });
  await flush();
  assert.deepEqual(last.runs.map((r) => r.id), [22], 'the second answer stands');
  assert.equal(last.truncated, false);
  assert.match(root.textContent, /run-22/);
  assert.doesNotMatch(root.textContent, /run-21/);
});

test('R8: a mounted detail row expands to its full run (sha256, snapshot_ts, verdict_detail)', async () => {
  const doc = installDom();
  const root = doc.createElement('div');
  mount(h(StandbyVerifyDetail, { box: 'sb-1', runs: PAYLOAD.runs, error: null, onRetry: noop }), root);
  await flush();
  assert.ok(!root.textContent.includes(SHA));
  const toggle = all(root).find((n) => n.localName === 'button' && n.textContent.trim() === 'ok' && n.attrs['aria-expanded']);
  click(toggle);
  await flush();
  assert.equal(toggle.attrs['aria-expanded'], 'true');
  assert.ok(root.textContent.includes(SHA), 'expanded run shows its sha256');
  assert.match(root.textContent, /2026-09-26T09:30:00Z/);
  assert.match(root.textContent, /restored 4 dbs, integrity ok/);
  click(toggle);
  await flush();
  assert.ok(!root.textContent.includes(SHA), 'toggles closed');
});
