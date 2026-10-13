import test from 'node:test';
import assert from 'node:assert/strict';
import { render } from 'preact-render-to-string';
import { h, render as mount } from 'preact';
import {
  ACTION_STATUS, mqActions, mqActionBody, heldReleaseBody, releasable, effectText, mqFormState,
  makeMqAction, makeReleaseAction
} from '../src/lib/merge-queue-actions.js';
import { MqRowActions, HeldReleaseButton } from '../src/screens/merge-queue-actions.js';
import { flush } from './helpers/settle.js';

// BH-3159 (BH-2325.4): HOLD / RESUME / DROP on a merge-queue row and RELEASE on
// a held page. The PATCH answers {merge:{...row, status}} and the release POST
// answers {released: <changes>} (worker PR #3194); api.request throws on any
// non-2xx, so a 404/409/502 reaches the action as a thrown Error.

// A native dialog anywhere in the flow is a failure, never a prompt.
globalThis.confirm = () => { throw new Error('native confirm called'); };
globalThis.alert = () => { throw new Error('native alert called'); };
globalThis.prompt = () => { throw new Error('native prompt called'); };

const MQ = { project: 'project-3', pr: 12, status: 'queued', reason: null, updated_at: '2026-09-28T12:00:00Z' };
const HELD = { repo: 'example-org/project-3', number: 44, state: 'aged', head: 'abc123', kind: 'stuck', text: 'owed page' };
const RELEASE_BODY = { repo: 'example-org/project-3', number: 44, state: 'aged', head: 'abc123', kind: 'stuck' };

// ---- the pure half ----------------------------------------------------------

test('A1: ACTION_STATUS and mqActions offer only the legal moves', () => {
  assert.deepEqual(ACTION_STATUS, { HOLD: 'blocked', RESUME: 'queued', DROP: 'dropped' });
  assert.deepEqual(mqActions('queued'), ['HOLD', 'DROP']);
  assert.deepEqual(mqActions('blocked'), ['RESUME', 'DROP']);
  assert.deepEqual(mqActions('dropped'), ['RESUME']);
  for (const s of ['landed', 'weird', '', null, undefined]) assert.deepEqual(mqActions(s), [], String(s));
  assert.ok(!mqActions('queued').includes('RESUME'));
  assert.ok(!mqActions('blocked').includes('HOLD'));
});

test('A2: body builders trim, and a blank reason or why is null', () => {
  assert.deepEqual(mqActionBody({ project: 'project-3', pr: 12 }, 'HOLD', ' why '),
    { project: 'project-3', pr: 12, status: 'blocked', reason: 'why' });
  assert.deepEqual(mqActionBody(MQ, 'DROP', 'gone').status, 'dropped');
  assert.deepEqual(mqActionBody(MQ, 'RESUME', 'back').status, 'queued');
  for (const r of ['', '   ', null, undefined]) assert.equal(mqActionBody(MQ, 'HOLD', r), null, String(r));
  assert.equal(mqActionBody(MQ, 'LAND', 'x'), null, 'an unknown action builds nothing');
  assert.deepEqual(heldReleaseBody(HELD, 'x'), { ...RELEASE_BODY, why: 'x' });
  assert.deepEqual(heldReleaseBody(HELD, '  seen it  '), { ...RELEASE_BODY, why: 'seen it' });
  for (const w of ['', '  ', null, undefined]) assert.equal(heldReleaseBody(HELD, w), null, String(w));
  assert.equal(releasable(HELD), true);
  for (const k of ['repo', 'number', 'state', 'head', 'kind']) {
    assert.equal(releasable({ ...HELD, [k]: undefined }), false, `no ${k}`);
  }
  assert.equal(releasable({}), false);
  assert.equal(releasable(null), false);
  assert.equal(mqFormState({ reason: '  ' }).blocked, true);
  assert.equal(typeof mqFormState({ reason: '' }).hint, 'string');
  assert.deepEqual(mqFormState({ reason: 'ok' }), { blocked: false, hint: '' });
});

test('A3: effectText is the truthful sentence for each action and rows-only mode', () => {
  assert.match(effectText('HOLD', 'off'), /already materialised as a file is still merged/);
  assert.match(effectText('HOLD', 'on'), /even one that still has a file/);
  for (const m of ['on', 'off', 'unread']) {
    assert.match(effectText('DROP', m), /does not remove a file on a box/, `DROP ${m}`);
    assert.match(effectText('RESUME', m), /\.blocked/, `RESUME ${m}`);
  }
  for (const m of ['on', 'off', 'unread', undefined]) {
    assert.match(effectText('RELEASE', m), /page it owes is not sent/);
    assert.match(effectText('RELEASE', m), /hold it again/);
  }
  for (const a of ['HOLD', 'DROP', 'RESUME']) {
    const [on, off, unread] = ['on', 'off', 'unread'].map((m) => effectText(a, m));
    assert.notEqual(on, off, a);
    assert.notEqual(unread, on, a);
    assert.notEqual(unread, off, a);
    assert.match(unread, /could not be read/, a);
    // An unknown mode is never read as on or off (D11).
    assert.equal(effectText(a, undefined), unread, a);
    assert.equal(effectText(a, 'maybe'), unread, a);
    for (const s of [on, off, unread]) assert.doesNotMatch(s, /—/);
  }
});

// Drive a factory with a scripted confirm; `reason` is what the modal typed.
function driveMq({ reason = 'flaky ci', confirmed = true, answer, throws } = {}) {
  const sent = []; const msgs = []; const asks = []; let done = 0;
  const act = makeMqAction({
    confirm: async (o) => { asks.push(o); o.form.reason = reason; return confirmed; },
    send: async (b) => { sent.push(b); if (throws) throw throws; return answer; },
    onMsg: (m) => msgs.push(m),
    onDone: () => { done++; }
  });
  return { act, sent, msgs, asks, done: () => done };
}

test('A4: makeMqAction sends nothing on cancel or blank reason, and succeeds only on the target status', async () => {
  const cancel = driveMq({ confirmed: false, answer: { merge: { status: 'blocked' } } });
  await cancel.act(MQ, 'HOLD');
  assert.equal(cancel.sent.length, 0);
  assert.equal(cancel.msgs.length, 0);
  assert.equal(cancel.done(), 0);
  assert.equal(cancel.asks[0].confirmBlocked, true, 'CONFIRM starts disabled');
  assert.equal(cancel.asks[0].confirmLabel, 'HOLD');

  const blank = driveMq({ reason: '   ', answer: { merge: { status: 'blocked' } } });
  await blank.act(MQ, 'HOLD');
  assert.equal(blank.sent.length, 0);
  assert.deepEqual(blank.msgs, [{ ok: false, text: 'HOLD refused — a reason is required' }]);

  const good = driveMq({ reason: ' flaky ci ', answer: { merge: { ...MQ, status: 'blocked', reason: 'flaky ci' } } });
  await good.act(MQ, 'HOLD');
  assert.deepEqual(good.sent, [{ project: 'project-3', pr: 12, status: 'blocked', reason: 'flaky ci' }]);
  assert.equal(good.done(), 1);
  assert.equal(good.msgs[0].ok, true);
  assert.match(good.msgs[0].text, /project-3#12 is now blocked/);

  for (const answer of [{ merge: { status: 'queued' } }, { ok: true }, null, { merge: null }]) {
    const d = driveMq({ answer });
    await d.act(MQ, 'HOLD');
    assert.equal(d.sent.length, 1);
    assert.equal(d.done(), 0, JSON.stringify(answer));
    assert.equal(d.msgs[0].ok, false);
    assert.match(d.msgs[0].text, /^HOLD was not confirmed by the worker/);
  }

  const bad = driveMq({ throws: new Error('http_502') });
  await bad.act(MQ, 'HOLD');
  assert.deepEqual(bad.msgs, [{ ok: false, text: 'HOLD failed — http_502' }]);
  assert.equal(bad.done(), 0);

  // A double click while the first request is in flight sends once.
  let release;
  const sent = [];
  const act = makeMqAction({
    confirm: async (o) => { o.form.reason = 'x'; return true; },
    send: (b) => { sent.push(b); return new Promise((r) => { release = r; }); },
    onMsg: () => {}, onDone: () => {}
  });
  const first = act(MQ, 'DROP');
  await new Promise((r) => setTimeout(r, 0));
  await act(MQ, 'DROP');
  release({ merge: { status: 'dropped' } });
  await first;
  assert.equal(sent.length, 1);
});

test('A5: makeReleaseAction sends the exact key and needs a numeric released', async () => {
  const run = async (answer, why = 'seen it') => {
    const sent = []; const msgs = []; let done = 0;
    const act = makeReleaseAction({
      confirm: async (o) => { o.form.reason = why; return true; },
      send: async (b) => { sent.push(b); return answer; },
      onMsg: (m) => msgs.push(m), onDone: () => { done++; }
    });
    await act(HELD);
    return { sent, msgs, done };
  };
  const one = await run({ released: 1 });
  assert.deepEqual(one.sent, [{ ...RELEASE_BODY, why: 'seen it' }]);
  assert.equal(one.msgs[0].ok, true);
  assert.equal(one.done, 1);
  const zero = await run({ released: 0 });
  assert.equal(zero.msgs[0].text, 'nothing was held under that key (already released)');
  assert.equal(zero.done, 1, 'the held list is stale either way');
  for (const answer of [{ released: '1' }, {}, null, { ok: true }]) {
    const r = await run(answer);
    assert.equal(r.msgs[0].ok, false, JSON.stringify(answer));
    assert.match(r.msgs[0].text, /^RELEASE was not confirmed by the worker/);
    assert.equal(r.done, 0);
  }
  const blank = await run({ released: 1 }, '  ');
  assert.equal(blank.sent.length, 0);
  assert.equal(blank.msgs[0].text, 'RELEASE refused — a reason is required');
  const cancelled = makeReleaseAction({ confirm: async () => false, send: async () => { throw new Error('sent'); },
    onMsg: () => { throw new Error('msg'); }, onDone: () => { throw new Error('done'); } });
  await cancelled(HELD);
});

test('A6: RESUME needs a reason too', async () => {
  const d = driveMq({ reason: '', answer: { merge: { status: 'queued' } } });
  await d.act({ ...MQ, status: 'blocked' }, 'RESUME');
  assert.equal(d.sent.length, 0);
  assert.equal(d.msgs[0].text, 'RESUME refused — a reason is required');
});

// ---- the real exported components ------------------------------------------

test('C1: the cells offer exactly the legal buttons and nothing for a dead row', () => {
  const labels = (html) => [...html.matchAll(/<button[^>]*>([A-Z]+)<\/button>/g)].map((m) => m[1]);
  const cell = (status) => render(h(MqRowActions, { row: { ...MQ, status }, rowsOnly: 'on', onDone() {} }));
  assert.deepEqual(labels(cell('queued')), ['HOLD', 'DROP']);
  assert.deepEqual(labels(cell('blocked')), ['RESUME', 'DROP']);
  assert.deepEqual(labels(cell('dropped')), ['RESUME']);
  for (const s of ['landed', 'weird', '', null, undefined]) {
    assert.equal(MqRowActions({ row: { ...MQ, status: s }, rowsOnly: 'on', onDone() {} }), null, String(s));
  }
  assert.deepEqual(labels(render(h(HeldReleaseButton, { row: HELD, onDone() {} }))), ['RELEASE']);
  assert.equal(HeldReleaseButton({ row: {}, onDone() {} }), null);
  assert.equal(HeldReleaseButton({ row: { ...HELD, head: undefined }, onDone() {} }), null);
  assert.equal(HeldReleaseButton({ row: { ...HELD, kind: '' }, onDone() {} }), null);
});

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
  doc.getElementById = () => null;
  globalThis.document = doc;
  globalThis.window = {
    location: { hash: '' }, dispatchEvent() {}, addEventListener() {}, removeEventListener() {},
    confirm: globalThis.confirm, alert: globalThis.alert, prompt: globalThis.prompt
  };
  return doc;
}

const all = (n, out = []) => { out.push(n); n.childNodes.forEach((c) => all(c, out)); return out; };
const dialogOf = (root) => all(root).find((n) => n.attrs && n.attrs.role === 'dialog');
const scrimOf = (root) => all(root).find((n) => n.attrs && n.attrs.class === 'modal__scrim');
const rowButton = (root, label) => all(root).find((n) => n.localName === 'button' && n.textContent.trim() === label
  && !all(dialogOf(root) || new FakeNode(1, 'x')).includes(n));
const confirmOf = (dialog) => all(dialog).filter((n) => n.localName === 'button').pop();
const inputOf = (dialog) => all(dialog).find((n) => n.localName === 'input');
const fire = (el, type, extra = {}) => el.listeners[type].call(el, { type, target: el, currentTarget: el, preventDefault() {}, stopPropagation() {}, ...extra });
const isDisabled = (n) => n.disabled === true || ('disabled' in n.attrs && n.attrs.disabled !== 'false');
const type = async (input, text) => { input.value = text; fire(input, 'input'); await flush(); };

// Every request is recorded; the answer is chosen by URL + method.
function routed(answers) {
  const calls = [];
  globalThis.fetch = async (url, init = {}) => {
    const u = String(url);
    const method = init.method || 'GET';
    calls.push({ url: u, method, body: init.body });
    const [status, body] = answers[`${method} ${u}`] || [404, { error: 'nope' }];
    return { ok: status >= 200 && status < 300, status, text: async () => JSON.stringify(body) };
  };
  return calls;
}

test('C2: HOLD opens the in-app modal; blank reason keeps CONFIRM off; Escape and the scrim send nothing', async () => {
  const doc = installDom();
  const calls = routed({});
  const root = doc.createElement('div');
  let done = 0;
  mount(h(MqRowActions, { row: MQ, rowsOnly: 'off', onDone: () => { done++; } }), root);
  try {
    await flush();
    fire(rowButton(root, 'HOLD'), 'click');
    await flush();
    const dialog = dialogOf(root);
    assert.ok(dialog, 'the in-app dialog opened');
    assert.match(dialog.textContent, /project-3#12/);
    assert.ok(dialog.textContent.includes(effectText('HOLD', 'off')), 'the effect sentence for the current mode');
    assert.equal(isDisabled(confirmOf(dialog)), true, 'CONFIRM starts disabled');
    await type(inputOf(dialog), '   ');
    assert.equal(isDisabled(confirmOf(dialogOf(root))), true, 'whitespace is not a reason');

    fire(doc, 'keydown', { key: 'Escape' });
    await flush();
    assert.equal(dialogOf(root), undefined, 'Escape closed it');

    fire(rowButton(root, 'HOLD'), 'click');
    await flush();
    await type(inputOf(dialogOf(root)), 'a real reason');
    const scrim = scrimOf(root);
    fire(scrim, 'click', { target: scrim });
    await flush();
    assert.equal(dialogOf(root), undefined, 'the scrim closed it');
    assert.equal(calls.length, 0, 'nothing was sent');
    assert.equal(done, 0);
  } finally {
    mount(null, root);
  }
});

test('C3: focus stays on REASON through the enabling keystroke and a parent rerender (D39)', async () => {
  const doc = installDom();
  const calls = routed({});
  const root = doc.createElement('div');
  mount(h(MqRowActions, { row: { ...MQ, status: 'blocked' }, rowsOnly: 'on', onDone: () => {} }), root);
  try {
    await flush();
    fire(rowButton(root, 'RESUME'), 'click');
    await flush();
    const input = inputOf(dialogOf(root));
    assert.equal(doc.activeElement, input, 'focus starts on REASON');
    await type(input, 'x');
    assert.equal(isDisabled(confirmOf(dialogOf(root))), false, 'a reason enables CONFIRM');
    assert.equal(doc.activeElement, input, 'the enabling keystroke leaves focus on REASON');
    mount(h(MqRowActions, { row: { ...MQ, status: 'blocked' }, rowsOnly: 'on', onDone: () => {} }), root);
    await flush();
    assert.equal(doc.activeElement, input, 'a parent rerender with a fresh onDone leaves focus on REASON');
    fire(doc, 'keydown', { key: ' ' });
    await flush();
    assert.equal(calls.length, 0, 'a following Space sends nothing');
  } finally {
    mount(null, root);
  }
});

test('C4: CONFIRM through the real cell sends one exact PATCH and calls onDone once (D2)', async () => {
  const doc = installDom();
  const calls = routed({ 'PATCH /api/coord/merge-queue': [200, { merge: { ...MQ, status: 'blocked', reason: 'flaky ci' } }] });
  const root = doc.createElement('div');
  let done = 0;
  mount(h(MqRowActions, { row: MQ, rowsOnly: 'on', onDone: () => { done++; } }), root);
  try {
    await flush();
    fire(rowButton(root, 'HOLD'), 'click');
    await flush();
    await type(inputOf(dialogOf(root)), 'flaky ci');
    fire(confirmOf(dialogOf(root)), 'click');
    await flush();
    await flush();
    assert.equal(calls.length, 1);
    assert.equal(calls[0].method, 'PATCH');
    assert.equal(calls[0].url, '/api/coord/merge-queue');
    assert.equal(calls[0].body, '{"project":"project-3","pr":12,"status":"blocked","reason":"flaky ci"}');
    assert.equal(done, 1);
    assert.match(root.textContent, /project-3#12 is now blocked/);
  } finally {
    mount(null, root);
  }
});

test('C5: a 502 through the real cell is a failure and does not reload', async () => {
  const doc = installDom();
  routed({ 'PATCH /api/coord/merge-queue': [502, { error: 'upstream' }] });
  const root = doc.createElement('div');
  let done = 0;
  mount(h(MqRowActions, { row: MQ, rowsOnly: 'unread', onDone: () => { done++; } }), root);
  try {
    await flush();
    fire(rowButton(root, 'HOLD'), 'click');
    await flush();
    assert.ok(dialogOf(root).textContent.includes(effectText('HOLD', 'unread')));
    await type(inputOf(dialogOf(root)), 'flaky ci');
    fire(confirmOf(dialogOf(root)), 'click');
    await flush();
    await flush();
    assert.match(root.textContent, /HOLD failed — upstream/);
    assert.equal(done, 0);
  } finally {
    mount(null, root);
  }
});

test('C6: RELEASE through the real button posts the exact key and says so honestly on released:0', async () => {
  const doc = installDom();
  const calls = routed({ 'POST /api/coord/conductor/held/release': [200, { released: 0 }] });
  const root = doc.createElement('div');
  let done = 0;
  mount(h(HeldReleaseButton, { row: HELD, onDone: () => { done++; } }), root);
  try {
    await flush();
    fire(rowButton(root, 'RELEASE'), 'click');
    await flush();
    const dialog = dialogOf(root);
    assert.match(dialog.textContent, /example-org\/project-3#44 \(aged, stuck\)/);
    assert.ok(dialog.textContent.includes(effectText('RELEASE')));
    assert.equal(doc.activeElement, inputOf(dialog));
    await type(inputOf(dialog), 'seen it');
    fire(confirmOf(dialogOf(root)), 'click');
    await flush();
    await flush();
    assert.equal(calls.length, 1);
    assert.equal(calls[0].method, 'POST');
    assert.equal(calls[0].url, '/api/coord/conductor/held/release');
    assert.deepEqual(JSON.parse(calls[0].body), { ...RELEASE_BODY, why: 'seen it' });
    assert.match(root.textContent, /nothing was held under that key \(already released\)/);
    assert.equal(done, 1);
  } finally {
    mount(null, root);
  }
});
