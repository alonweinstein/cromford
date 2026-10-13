import test from 'node:test';
import assert from 'node:assert/strict';
import { render } from 'preact-render-to-string';
import { h, render as mount } from 'preact';
import { api } from '../src/api.js';
import {
  availableActions, requestBody, confirmOpts, actionOutcome, runJobAction, abandonReasonError
} from '../src/lib/job-actions.js';
import { JobActions } from '../src/ui/JobActions.js';
import { JobScreen } from '../src/screens/Job.js';
import { BuildScreen } from '../src/screens/Build.js';
import { flush } from './helpers/settle.js';

// BH-2406: ABANDON on the Job and Build screens. The in-app confirm carries a
// reason field and stays disabled until the reason says something; confirm
// sends ONE POST to /api/coord/jobs/:id/abandon with {reason} and nothing
// else. Rows are shaped like decorateJob's; answers like
// worker/jobs/src/routes/job-abandon.js's.

const ID = 'build-cromford-BH-9-1';
const row = (over) => ({
  id: ID, project: 'cromford', kind: 'build', stage: 'execute', box: 'hub-1',
  ticket_id: 'BH-9', status: 'running', heartbeating: true, beat_age_s: 30, activity_age_s: 30,
  created_at: '2026-09-25T10:00:00Z', updated_at: '2026-09-25T10:00:00Z', meta: null, ...over
});
const STALLED = row({ beat_age_s: 1200, activity_age_s: 1200 });
const QUIET = row({ heartbeating: false, beat_age_s: null, activity_age_s: 1200 });
const ORPHANED = row({ status: 'orphaned', activity_age_s: 1200 });
const PARKED = row({ status: 'parked', activity_age_s: 1200 });
const RUNNING = row({});
const DONE = row({ status: 'done' });

function fakeFetch(...answers) {
  const calls = [];
  globalThis.fetch = async (url, init = {}) => {
    calls.push({ url: String(url), method: init.method || 'GET', body: init.body ? JSON.parse(init.body) : undefined });
    const a = answers[Math.min(calls.length - 1, answers.length - 1)];
    if (a instanceof Error) throw a;
    const [status, body] = a;
    return { ok: status >= 200 && status < 300, status, text: async () => JSON.stringify(body) };
  };
  return calls;
}
function routedFetch(route) {
  const calls = [];
  globalThis.fetch = async (url, init = {}) => {
    const u = String(url);
    const method = init.method || 'GET';
    calls.push({ url: u, method, body: init.body ? JSON.parse(init.body) : undefined });
    const [status, body] = route(u, method);
    return { ok: status >= 200 && status < 300, status, text: async () => JSON.stringify(body) };
  };
  return calls;
}

globalThis.confirm = () => { throw new Error('native confirm called'); };
globalThis.alert = () => { throw new Error('native alert called'); };
globalThis.prompt = () => { throw new Error('native prompt called'); };

// ---- pure half ------------------------------------------------------------------
test('1: availableActions offers ABANDON on every non-terminal row except a freshly beating one', () => {
  const cases = [
    [STALLED, ['retry', 'requeue', 'abandon']],
    [QUIET, ['retry', 'requeue', 'abandon']],
    [ORPHANED, ['requeue', 'abandon']],
    [row({ status: 'queued_for_retry' }), ['abandon']],
    [PARKED, ['abandon']],
    [row({ status: 'failed' }), ['abandon']],
    [RUNNING, []], [DONE, []], [row({ status: 'budget_stopped' }), []],
    [row({ status: 'abandoned' }), []], [row({ status: 'weird' }), []], [null, []], [undefined, []],
  ];
  for (const [j, want] of cases) assert.deepEqual(availableActions(j), want, JSON.stringify(j && j.status));
});

test('2: abandonReasonError wants a real reason under 512 characters', () => {
  for (const blank of ['', '   ', '\n\t ', null, undefined]) {
    assert.equal(abandonReasonError(blank), 'Say why you are abandoning this job.', JSON.stringify(blank));
  }
  assert.equal(abandonReasonError('x'.repeat(513)), 'Keep the reason under 512 characters.');
  assert.equal(abandonReasonError('x'.repeat(512)), null);
  assert.equal(abandonReasonError('  stuck  '), null);
  assert.deepEqual(requestBody('abandon', '  stuck  '), { reason: 'stuck' });
});

test('3: the ABANDON confirm is a danger dialog that says it is final and what it does not do', () => {
  const o = confirmOpts('abandon', PARKED);
  assert.equal(o.title, 'ABANDON JOB');
  assert.equal(o.tone, 'danger');
  assert.equal(o.confirmLabel, 'ABANDON');
  assert.ok(o.body.includes(ID));
  assert.match(o.body, /final/i);
  assert.match(o.body, /does not stop a process/);
  assert.match(o.body, /does not close a PR/);
  assert.doesNotMatch(o.body, /—/);
  assert.match(confirmOpts('abandon', QUIET).body, /may still be alive/);
});

test('4: actionOutcome for abandon: abandoned is ok, already is a warning, errors and no-decision are failures', () => {
  assert.deepEqual(actionOutcome('abandon', { result: { decision: 'abandoned', reason: 'stuck' } }),
    { tone: 'ok', text: 'ABANDON: Abandoned: stuck' });
  const already = actionOutcome('abandon', { result: { decision: 'already', already: true, reason: 'already abandoned' } });
  assert.equal(already.tone, 'warn');
  assert.match(already.text, /Nothing changed/);
  const err = (status, body) => Object.assign(new Error(body.error), { status, body });
  assert.equal(actionOutcome('abandon', { error: err(409, { error: 'illegal job transition' }) }).tone, 'bad');
  assert.equal(actionOutcome('abandon', { error: err(500, { error: 'boom' }) }).tone, 'bad');
  assert.equal(actionOutcome('abandon', { result: {} }).tone, 'bad');
  assert.equal(actionOutcome('abandon', { result: null }).tone, 'bad');
});

test('5: api.abandonJob POSTs to the coord proxy with the reason and no actor', async () => {
  const calls = fakeFetch([200, { decision: 'abandoned', reason: 'r' }]);
  await api.abandonJob('build-x-BH-1-1', { reason: 'r' });
  assert.equal(calls.length, 1);
  assert.equal(calls[0].url, '/api/coord/jobs/build-x-BH-1-1/abandon');
  assert.equal(calls[0].method, 'POST');
  assert.deepEqual(calls[0].body, { reason: 'r' });
});

// The reason field is the component's; the lib hands it the form object it
// reads back. `typed` is what the fake dialog "types" before answering.
const drive = async ({ answer, typed }) => {
  let reloads = 0;
  let asked = null;
  const out = await runJobAction({
    apiObj: api, job: PARKED, action: 'abandon',
    reasonForm: (text, form) => ({ text, form }),
    confirm: async (o) => { asked = o; if (typed !== undefined) o.body.form.reason = typed; return answer; },
    reload: () => { reloads += 1; }
  });
  return { out, reloads, asked };
};

test('6: runJobAction(abandon): cancel or a blank reason sends nothing; confirm sends one POST with {reason}', async () => {
  let calls = fakeFetch([200, { decision: 'abandoned', reason: 'stuck' }]);
  for (const answer of [false, undefined, 'yes']) {
    const r = await drive({ answer, typed: 'stuck' });
    assert.equal(r.out, null);
    assert.equal(r.reloads, 0);
  }
  const blank = await drive({ answer: true, typed: '   ' });
  assert.equal(blank.out.tone, 'bad');
  assert.match(blank.out.text, /Say why/);
  assert.equal(blank.reloads, 0);
  assert.equal(calls.length, 0, 'no POST without a confirmed, non-blank reason');

  calls = fakeFetch([200, { decision: 'abandoned', reason: 'stuck' }]);
  const r = await drive({ answer: true, typed: ' stuck ' });
  assert.equal(r.asked.confirmBlocked, true, 'the dialog opens with ABANDON disabled');
  assert.equal(r.asked.tone, 'danger');
  assert.deepEqual(calls.map((c) => [c.method, c.url, c.body]), [['POST', `/api/coord/jobs/${ID}/abandon`, { reason: 'stuck' }]]);
  assert.equal(r.reloads, 1);
  assert.deepEqual(r.out, { tone: 'ok', text: 'ABANDON: Abandoned: stuck' });
});

test('7: JobActions renders ABANDON as a danger button beside what the row allows', () => {
  const parked = render(h(JobActions, { job: PARKED }));
  assert.match(parked, /class="btn btn--danger"[^>]*>ABANDON</);
  assert.doesNotMatch(parked, />RETRY</);
  assert.doesNotMatch(parked, />REQUEUE</);
  const stalled = render(h(JobActions, { job: STALLED }));
  for (const l of ['RETRY', 'REQUEUE', 'ABANDON']) assert.match(stalled, new RegExp(`>${l}<`));
  assert.equal(render(h(JobActions, { job: row({ status: 'abandoned' }) })), '');
  assert.equal(render(h(JobActions, { job: RUNNING })), '');
});

// ---- mounted, typed into, and through the real screens (D2, D39) -----------------

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
  focus() { globalThis.document.activeElement = this; }
  // Enough of the selector language for Modal: "tag" and ".class tag", comma-joined.
  querySelectorAll(sel) {
    const parts = sel.split(',').map((p) => p.trim().split(/\s+/));
    const hasClassAbove = (n, cls) => {
      for (let p = n.parentNode; p && p !== this.parentNode; p = p.parentNode) {
        if ((p.attrs.class || '').split(/\s+/).includes(cls)) return true;
      }
      return false;
    };
    return all(this).slice(1).filter((n) => n.nodeType === 1 && parts.some((p) => (p.length === 1
      ? n.localName === p[0]
      : n.localName === p[1] && hasClassAbove(n, p[0].replace(/^\./, '')))));
  }
  querySelector(sel) { return this.querySelectorAll(sel)[0] || null; }
  get textContent() { return this.nodeType === 3 ? String(this.data) : this.childNodes.map((c) => c.textContent).join(''); }
}

function installDom() {
  const doc = new FakeNode(9, '#document');
  doc.createElement = (t) => new FakeNode(1, t);
  doc.createElementNS = (_, t) => new FakeNode(1, t);
  doc.createTextNode = (d) => new FakeNode(3, null, d);
  doc.hidden = false;
  doc.activeElement = null;
  globalThis.document = doc;
  globalThis.window = globalThis.window || { dispatchEvent() {}, addEventListener() {}, removeEventListener() {} };
  return doc;
}

const all = (n, out = []) => { out.push(n); n.childNodes.forEach((c) => all(c, out)); return out; };
const buttonIn = (root, label) => all(root).find((n) => n.localName === 'button' && n.textContent.trim() === label);
const dialogOf = (root) => all(root).find((n) => n.attrs && n.attrs.role === 'dialog');
const fire = (el, type, extra = {}) => el.listeners[type].call(el, { type, target: el, currentTarget: el, preventDefault() {}, stopPropagation() {}, ...extra });
const isDisabled = (n) => n.disabled === true || ('disabled' in n.attrs && n.attrs.disabled !== 'false');
// The row's ABANDON button lives outside the dialog; the dialog's confirm is its last button.
const rowButton = (root, label) => all(root).find((n) => n.localName === 'button' && n.textContent.trim() === label && !all(dialogOf(root) || new FakeNode(1, 'x')).includes(n));
const confirmOf = (dialog) => all(dialog).filter((n) => n.localName === 'button').pop();

test('8: the mounted ABANDON asks for a reason, keeps focus on it through a rerender, and sends one POST', async () => {
  const doc = installDom();
  const calls = fakeFetch([200, { job_id: ID, decision: 'abandoned', reason: 'stuck' }]);
  let reloads = 0;
  const root = doc.createElement('div');
  mount(h(JobActions, { job: PARKED, onDone: () => { reloads += 1; } }), root);
  try {
    await flush();
    fire(rowButton(root, 'ABANDON'), 'click');
    await flush();
    const dialog = dialogOf(root);
    assert.ok(dialog, 'the in-app dialog opened');
    assert.equal(dialog.attrs['aria-label'], 'ABANDON JOB');
    assert.ok(dialog.textContent.includes(ID), dialog.textContent);
    const ta = all(dialog).find((n) => n.localName === 'textarea');
    assert.ok(ta, 'the dialog carries a reason textarea');
    assert.equal(ta.attrs['aria-label'], 'Reason');
    assert.equal(ta.attrs.maxlength, '512');
    assert.equal(doc.activeElement, ta, 'focus starts on the reason');
    assert.equal(confirmOf(dialog).textContent.trim(), 'ABANDON');
    assert.equal(isDisabled(confirmOf(dialog)), true, 'ABANDON is disabled until a reason is typed');

    ta.value = '   ';
    fire(ta, 'input');
    await flush();
    assert.equal(isDisabled(confirmOf(dialogOf(root))), true, 'whitespace is not a reason');

    ta.value = 'stuck';
    fire(ta, 'input');
    await flush();
    assert.equal(isDisabled(confirmOf(dialogOf(root))), false, 'a reason enables ABANDON');
    assert.equal(doc.activeElement, ta, 'the enabling keystroke leaves focus on the reason (D39)');

    // A polling parent re-renders with a fresh onDone; focus must not move.
    mount(h(JobActions, { job: PARKED, onDone: () => { reloads += 1; } }), root);
    await flush();
    assert.equal(doc.activeElement, ta, 'a parent rerender leaves focus on the reason (D39)');
    assert.equal(all(dialogOf(root)).find((n) => n.localName === 'textarea'), ta, 'the same field, still there');
    assert.equal(calls.length, 0, 'typing sends nothing');

    fire(confirmOf(dialogOf(root)), 'click');
    await flush();
    assert.deepEqual(calls.map((c) => [c.method, c.url, c.body]), [['POST', `/api/coord/jobs/${ID}/abandon`, { reason: 'stuck' }]]);
    assert.equal(reloads, 1);
    assert.match(root.textContent, /ABANDON: Abandoned: stuck/);
    assert.equal(dialogOf(root), undefined);
  } finally { mount(null, root); }
});

test('9: Escape and CANCEL close the ABANDON dialog with nothing sent', async () => {
  const doc = installDom();
  const calls = fakeFetch([200, { decision: 'abandoned', reason: 'x' }]);
  const root = doc.createElement('div');
  mount(h(JobActions, { job: ORPHANED, onDone: () => {} }), root);
  try {
    await flush();
    fire(rowButton(root, 'ABANDON'), 'click');
    await flush();
    const ta = all(dialogOf(root)).find((n) => n.localName === 'textarea');
    ta.value = 'typed then thought better';
    fire(ta, 'input');
    await flush();
    fire(doc, 'keydown', { key: 'Escape' });
    await flush();
    assert.equal(dialogOf(root), undefined, 'Escape closes it');

    fire(rowButton(root, 'ABANDON'), 'click');
    await flush();
    fire(buttonIn(dialogOf(root), 'CANCEL'), 'click');
    await flush();
    assert.equal(dialogOf(root), undefined, 'CANCEL closes it');
    assert.equal(calls.length, 0);
  } finally { mount(null, root); }
});

test('10: the real JobScreen shows ABANDON (and not RETRY) for a parked job, nothing for a done one', async () => {
  const doc = installDom();
  for (const [job, expectAbandon] of [[PARKED, true], [DONE, false], [row({ status: 'abandoned' }), false]]) {
    routedFetch(() => [200, { job, phases: [], events: [], ledgers: [], transcripts: [] }]);
    const root = doc.createElement('div');
    mount(h(JobScreen, { id: ID }), root);
    try {
      await flush();
      assert.match(root.textContent, new RegExp(ID));
      assert.equal(Boolean(buttonIn(root, 'ABANDON')), expectAbandon, job.status);
      assert.equal(Boolean(buttonIn(root, 'RETRY')), false, job.status);
    } finally { mount(null, root); }
  }
});

test('11: the real BuildScreen shows REQUEUE and ABANDON for its orphaned job', async () => {
  const doc = installDom();
  const build = { id: 9, project: 'cromford', ticket_key: 'BH-9', bkey: 'cromford:BH-9:x', stage: 'execute' };
  routedFetch((u) => {
    if (u.startsWith('/api/dash/builds/')) return [200, { build, timeline: [] }];
    if (u.startsWith('/api/coord/jobs?')) return [200, { jobs: [ORPHANED] }];
    if (u.includes('/live?')) return [200, { job: ORPHANED, phases: [], events: [], cursor: 0 }];
    return [404, { error: 'nope' }];
  });
  const root = doc.createElement('div');
  mount(h(BuildScreen, { id: '9' }), root);
  try {
    await flush();
    await flush();
    assert.ok(buttonIn(root, 'REQUEUE'), 'REQUEUE');
    assert.ok(buttonIn(root, 'ABANDON'), 'ABANDON');
    assert.equal(Boolean(buttonIn(root, 'RETRY')), false);
  } finally { mount(null, root); }
});
