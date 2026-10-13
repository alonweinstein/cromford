import test from 'node:test';
import assert from 'node:assert/strict';
import { render } from 'preact-render-to-string';
import { h, render as mount } from 'preact';
import { api } from '../src/api.js';
import {
  availableActions, requestBody, confirmOpts, actionOutcome, runJobAction
} from '../src/lib/job-actions.js';
import { JobActions } from '../src/ui/JobActions.js';
import { JobScreen } from '../src/screens/Job.js';
import { BuildScreen } from '../src/screens/Build.js';
import { flush } from './helpers/settle.js';

// BH-2323: RETRY / REQUEUE on the Job and Build screens. Job rows here have the
// shape decorateJob (worker/jobs/src/lib/core.js) gives every jobs read, and
// the answers are the ones worker/jobs/src/routes/job-retry.js returns.

const ID = 'build-cromford-BH-1-1';
const row = (over) => ({
  id: ID, project: 'cromford', kind: 'build', stage: 'execute', box: 'hub-1',
  ticket_id: 'BH-1', status: 'running', heartbeating: true, beat_age_s: 30, activity_age_s: 30,
  created_at: '2026-09-25T10:00:00Z', updated_at: '2026-09-25T10:00:00Z', meta: null, ...over
});
const STALLED = row({ beat_age_s: 1200, activity_age_s: 1200 });
const QUIET = row({ heartbeating: false, beat_age_s: null, activity_age_s: 1200 });
const ORPHANED = row({ status: 'orphaned', activity_age_s: 1200 });
const RUNNING = row({});
const DONE = row({ status: 'done' });

// One answer per call, in order; the last answer repeats.
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

// Routed by URL, for the mounted screens that make several reads.
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

// A native dialog anywhere in the flow is a failure, never a prompt.
globalThis.confirm = () => { throw new Error('native confirm called'); };
globalThis.alert = () => { throw new Error('native alert called'); };

// TEST-CHANGE (BH-2406): ABANDON joins the list on every non-terminal row but a
// freshly beating one; the RETRY / REQUEUE rules this test pins are unchanged.
// The ABANDON cases are pinned in job-abandon.bh-2406.test.js.
test('1: availableActions offers RETRY only on a running-but-silent row, REQUEUE also on orphaned', () => {
  assert.deepEqual(availableActions(STALLED), ['retry', 'requeue', 'abandon']);
  assert.deepEqual(availableActions(QUIET), ['retry', 'requeue', 'abandon']);
  assert.deepEqual(availableActions(ORPHANED), ['requeue', 'abandon']);
  for (const j of [row({ status: 'queued_for_retry' }), row({ status: 'parked' }), row({ status: 'failed' })]) {
    assert.deepEqual(availableActions(j), ['abandon'], JSON.stringify(j && j.status));
  }
  for (const j of [RUNNING, DONE, row({ status: 'budget_stopped' }), row({ status: 'weird' }), null, undefined]) {
    assert.deepEqual(availableActions(j), [], JSON.stringify(j && j.status));
  }
});

test('2: api.retryJob / api.requeueJob POST to the coord proxy with no actor in the body', async () => {
  let calls = fakeFetch([200, { decision: 'queued_for_retry', reason: 'r' }]);
  await api.retryJob(ID, requestBody('retry'));
  assert.equal(calls.length, 1);
  assert.equal(calls[0].url, `/api/coord/jobs/${ID}/retry`);
  assert.equal(calls[0].method, 'POST');
  assert.ok(!('actor' in calls[0].body), 'the proxy sets the actor');
  assert.deepEqual(calls[0].body, { detail: 'operator retry from Mission Control' });

  calls = fakeFetch([200, { decision: 'held', reason: 'r' }]);
  await api.requeueJob('a/b c', requestBody('requeue'));
  assert.equal(calls[0].url, '/api/coord/jobs/a%2Fb%20c/requeue');
  assert.equal(calls[0].method, 'POST');
  assert.deepEqual(calls[0].body, { detail: 'operator requeue from Mission Control' });
});

test('3: a cancelled confirm sends nothing, returns null and reloads nothing', async () => {
  const calls = fakeFetch([200, { decision: 'queued_for_retry', reason: 'r' }]);
  let reloads = 0;
  for (const answer of [false, undefined, 'yes', 1]) {
    const out = await runJobAction({ apiObj: api, job: STALLED, action: 'retry', confirm: async () => answer, reload: () => { reloads += 1; } });
    assert.equal(out, null);
  }
  assert.equal(calls.length, 0);
  assert.equal(reloads, 0);
});

test('4: a confirmed action sends one POST, reloads once, and reports the worker decision', async () => {
  const cases = [
    ['retry', 'queued_for_retry', 'ok'],
    ['retry', 'parked', 'warn'],
    ['retry', 'orphaned', 'warn'],
    ['requeue', 'held', 'warn'],
    ['requeue', 'already', 'warn'],
    ['requeue', 'queued_for_retry', 'ok'],
  ];
  for (const [action, decision, tone] of cases) {
    const reason = `because ${decision} said so`;
    const calls = fakeFetch([200, { job_id: ID, decision, reason }]);
    let reloads = 0;
    let asked = null;
    const out = await runJobAction({
      apiObj: api, job: STALLED, action, confirm: async (o) => { asked = o; return true; }, reload: () => { reloads += 1; }
    });
    assert.equal(calls.length, 1, `${action} ${decision}`);
    assert.equal(calls[0].url, `/api/coord/jobs/${ID}/${action}`);
    assert.equal(reloads, 1);
    assert.equal(out.tone, tone, `${action} ${decision}`);
    assert.ok(out.text.includes(reason), out.text);
    assert.deepEqual(asked, confirmOpts(action, STALLED));
    if (decision !== 'queued_for_retry') assert.doesNotMatch(out.text, /\bqueued\b/i, out.text);
  }
});

test('5: a 409, a 500, a network throw and a decision-less 200 all read as a failure', async () => {
  const cases = [
    [[409, { error: 'illegal transition', refused: true }], /REQUEUE failed: .*illegal transition/],
    [[500, { error: 'boom' }], /REQUEUE failed: boom/],
    [new Error('down'), /REQUEUE failed: network unreachable/],
    [[200, {}], /REQUEUE failed: unexpected answer/],
    [[200, { reason: 'x' }], /REQUEUE failed: unexpected answer/],
    [[404, { error: 'no such job' }], /REQUEUE failed: no such job/],
  ];
  for (const [answer, re] of cases) {
    fakeFetch(answer);
    const out = await runJobAction({ apiObj: api, job: ORPHANED, action: 'requeue', confirm: async () => true, reload: () => {} });
    assert.equal(out.tone, 'bad', JSON.stringify(answer));
    assert.match(out.text, re);
  }
  assert.equal(actionOutcome('retry', { result: null }).tone, 'bad');
});

test('6: JobActions renders the buttons the row allows and nothing otherwise', () => {
  const stalled = render(h(JobActions, { job: STALLED }));
  assert.match(stalled, />RETRY</);
  assert.match(stalled, />REQUEUE</);
  const orphaned = render(h(JobActions, { job: ORPHANED }));
  assert.match(orphaned, />REQUEUE</);
  assert.doesNotMatch(orphaned, />RETRY</);
  assert.equal(render(h(JobActions, { job: RUNNING })), '');
  assert.equal(render(h(JobActions, { job: DONE })), '');
  assert.equal(render(h(JobActions, { job: null })), '');
});

test('6: confirm copy names the job and uses no em dash', () => {
  for (const a of ['retry', 'requeue']) {
    const o = confirmOpts(a, STALLED);
    assert.equal(o.title, a === 'retry' ? 'RETRY JOB' : 'REQUEUE JOB');
    assert.equal(o.tone, 'warn');
    assert.ok(o.body.includes(ID));
    assert.doesNotMatch(o.body, /—/);
  }
});

test('6b: RETRY on a quiet row says plainly the job may still be alive; a stalled row does not', () => {
  const quiet = confirmOpts('retry', QUIET).body;
  assert.match(quiet, /may still be (alive|running)/i);
  assert.match(quiet, /never heartbeat/i);
  assert.doesNotMatch(quiet, /—/);
  assert.doesNotMatch(confirmOpts('retry', STALLED).body, /may still be/i);
  assert.match(confirmOpts('requeue', QUIET).body, /may still be (alive|running)/i);
});

// ---- 7/8: mounted, clicked, and through the real screens (D2) ----------------

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
  doc.hidden = false;
  globalThis.document = doc;
  globalThis.window = globalThis.window || { dispatchEvent() {}, addEventListener() {}, removeEventListener() {} };
  return doc;
}

const all = (n, out = []) => { out.push(n); n.childNodes.forEach((c) => all(c, out)); return out; };
const button = (root, label) => all(root).find((n) => n.localName === 'button' && n.textContent.trim() === label);
const dialogOf = (root) => all(root).find((n) => n.attrs && n.attrs.role === 'dialog');
const click = (el) => el.listeners.click.call(el, { type: 'click', target: el, currentTarget: el, preventDefault() {}, stopPropagation() {} });
const isDisabled = (n) => n.disabled === true || ('disabled' in n.attrs && n.attrs.disabled !== 'false');

test('7: the mounted buttons open the in-app dialog, cancel sends nothing, confirm sends one POST', async () => {
  const doc = installDom();
  const calls = fakeFetch([200, { job_id: ID, decision: 'held', reason: 'another live job owns BH-1' }]);
  let reloads = 0;
  const root = doc.createElement('div');
  mount(h(JobActions, { job: ORPHANED, onDone: () => { reloads += 1; } }), root);
  try {
  await flush();

  click(button(root, 'REQUEUE'));
  await flush();
  let dialog = dialogOf(root);
  assert.ok(dialog, 'the in-app dialog opened');
  assert.ok(dialog.textContent.includes(ID), dialog.textContent);
  assert.equal(calls.length, 0, 'opening the dialog sends nothing');
  assert.equal(isDisabled(button(root, 'REQUEUE')), true, 'disabled while the dialog is open');
  click(button(root, 'CANCEL'));
  await flush();
  assert.equal(dialogOf(root), undefined);
  assert.equal(calls.length, 0, 'cancel sends nothing');
  assert.equal(reloads, 0);
  assert.equal(isDisabled(button(root, 'REQUEUE')), false);

  click(button(root, 'REQUEUE'));
  await flush();
  dialog = dialogOf(root);
  const confirmBtn = all(dialog).filter((n) => n.localName === 'button').pop();
  click(confirmBtn);
  await flush();
  assert.deepEqual(calls.map((c) => [c.method, c.url]), [['POST', `/api/coord/jobs/${ID}/requeue`]]);
  assert.equal(reloads, 1);
  assert.match(root.textContent, /another live job owns BH-1/);
  assert.equal(dialogOf(root), undefined);
  assert.equal(isDisabled(button(root, 'REQUEUE')), false, 'enabled again after the POST');
  } finally { mount(null, root); }
});

test('8: the real JobScreen shows RETRY and REQUEUE for a stalled job, none for a done one', async () => {
  const doc = installDom();
  for (const [job, expectRetry] of [[STALLED, true], [DONE, false]]) {
    routedFetch(() => [200, { job, phases: [], events: [], ledgers: [], transcripts: [] }]);
    const root = doc.createElement('div');
    mount(h(JobScreen, { id: ID }), root);
    try {
      await flush();
      assert.match(root.textContent, new RegExp(ID));
      assert.equal(Boolean(button(root, 'RETRY')), expectRetry, job.status);
      assert.equal(Boolean(button(root, 'REQUEUE')), expectRetry, job.status);
    } finally { mount(null, root); }
  }
});

test('8: the real BuildScreen shows REQUEUE for its orphaned job, and nothing when no job joins', async () => {
  const doc = installDom();
  const build = { id: 9, project: 'cromford', ticket_key: 'BH-1', bkey: 'cromford:BH-1:x', stage: 'execute' };
  for (const [jobs, expect] of [[[ORPHANED], true], [[], false]]) {
    routedFetch((u) => {
      if (u.startsWith('/api/dash/builds/')) return [200, { build, timeline: [] }];
      if (u.startsWith('/api/coord/jobs?')) return [200, { jobs }];
      if (u.includes('/live?')) return [200, { job: ORPHANED, phases: [], events: [], cursor: 0 }];
      return [404, { error: 'nope' }];
    });
    const root = doc.createElement('div');
    mount(h(BuildScreen, { id: '9' }), root);
    try {
      await flush();
      await flush();
      assert.match(root.textContent, /BH-1/);
      assert.equal(Boolean(button(root, 'REQUEUE')), expect, `jobs=${jobs.length}`);
      assert.equal(Boolean(button(root, 'RETRY')), false);
    } finally { mount(null, root); }
  }
});
