// BH-5839: the ticket page's "Step in" composer and its note echo.
//
// C1-C3 mount the REAL AgentSession on a small fake DOM (the FakeNode from
// ticket-hold-build.bh-2326, inline there too) and click its SEND button, so
// the component's own send path and the real in-app HOLD TICKET dialog
// (ui/Modal.js useConfirm) are what is under test. The api is a fake `apiObj`
// that records each steer body. The note rows are the worker's noteOut shape
// (worker/jobs/src/routes/steer.js).

import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { h, render as mount } from 'preact';
import { flush } from './helpers/settle.js';

globalThis.window = globalThis.window || {
  location: { pathname: '/t/BH-5839', search: '' },
  dispatchEvent() {}, addEventListener() {}, removeEventListener() {},
  history: { pushState() {}, replaceState() {} }, scrollTo() {}
};

// A native dialog anywhere in the flow is a failure, never a prompt.
globalThis.confirm = () => { throw new Error('native confirm called'); };
globalThis.alert = () => { throw new Error('native alert called'); };
globalThis.prompt = () => { throw new Error('native prompt called'); };

const { render } = await import('preact-render-to-string');
const { AgentSession } = await import('../src/ui/AgentSession.js');
const { TicketScreen } = await import('../src/screens/Ticket.js');
const { canSendNow, steerBody, steerState, STEER_TEXT_MAX } = await import('../src/lib/steer.js');
const { HOLD_REASON_MAX } = await import('../src/lib/ticket-hold.js');

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
  querySelectorAll(sel) {
    const tags = sel.split(',').map((p) => p.trim().split(/\s+/).pop());
    return all(this).slice(1).filter((n) => n.nodeType === 1 && tags.includes(n.localName));
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
  return doc;
}

const all = (n, out = []) => { out.push(n); n.childNodes.forEach((c) => all(c, out)); return out; };
const dialogOf = (root) => all(root).find((n) => n.attrs && n.attrs.role === 'dialog');
const outsideDialog = (root) => { const d = dialogOf(root); const inD = d ? all(d) : []; return all(root).filter((n) => !inD.includes(n)); };
const sendButton = (root) => outsideDialog(root).find((n) => n.localName === 'button' && n.textContent.trim() === 'SEND');
const textBox = (root) => all(root).find((n) => n.localName === 'textarea' && (n.attrs.class || '').includes('compose__text'));
const radio = (root, mode) => all(root).find((n) => n.localName === 'input' && n.attrs.type === 'radio' && n.attrs.value === mode);
const confirmOf = (dialog) => all(dialog).filter((n) => n.localName === 'button').pop();
const cancelOf = (dialog) => all(dialog).find((n) => n.localName === 'button' && n.textContent.trim() === 'CANCEL');
const fire = (el, type, extra = {}) => el.listeners[type].call(el, { type, target: el, currentTarget: el, preventDefault() {}, stopPropagation() {}, button: 0, ...extra });
const isDisabled = (n) => n.disabled === true || ('disabled' in n.attrs && n.attrs.disabled !== 'false');
const visible = (s) => s.replace(/<[^>]+>/g, ' ').replace(/&amp;/g, '&').replace(/&quot;/g, '"').replace(/\s+/g, ' ');

const PROJECT = 'cromford';
const TICKET = 'BH-5839';
const RUNNING = { id: 'build-cromford-BH-5839-1', kind: 'build', status: 'running', project: PROJECT, ticket_id: TICKET };
const DONE = { ...RUNNING, status: 'done' };

// The worker's noteOut row (routes/steer.js), as GET /api/steer answers it.
const note = (over) => ({
  id: 1, project: PROJECT, ticket: TICKET, job_id: RUNNING.id, mode: 'now', text: 'Check the helper first',
  actor: 'console', status: 'pending', attempts: 0, detail: null, build_read_at: null, delivered_at: null,
  created_at: '2026-10-12T20:01:00Z', updated_at: '2026-10-12T20:01:00Z', ...over
});

function fakeApi(answer = (b) => ({ note: note({ id: 9, mode: b.mode, text: b.text }) })) {
  const calls = [];
  return {
    calls,
    steer: async (b) => {
      calls.push(b);
      const a = answer(b);
      if (a instanceof Error) throw a;
      return a;
    }
  };
}

async function mounted(props, fn) {
  const doc = installDom();
  const root = doc.createElement('div');
  mount(h(AgentSession, { live: true, stage: 'Execute', feed: [], project: PROJECT, ticket: TICKET, notes: [], ...props }), root);
  try { await flush(); await fn(root, doc); } finally { mount(null, root); }
}

async function type(root, mode, text) {
  fire(radio(root, mode), 'change');
  await flush();
  const ta = textBox(root);
  ta.value = text;
  fire(ta, 'input');
  await flush();
}

test('C1 "Add to the ticket" + SEND is exactly one api.steer call with {project, ticket, mode, text}; the box clears and the notes reload', async () => {
  const apiObj = fakeApi();
  let sent = 0;
  await mounted({ job: RUNNING, apiObj, onSent: () => { sent += 1; } }, async (root) => {
    await type(root, 'ticket', '  Use the helper ');
    assert.equal(apiObj.calls.length, 0, 'typing sends nothing');
    fire(sendButton(root), 'click');
    await flush();
    assert.deepEqual(apiObj.calls, [{ project: PROJECT, ticket: TICKET, mode: 'ticket', text: 'Use the helper' }]);
    assert.equal(dialogOf(root), undefined, 'no dialog for a ticket note');
    assert.equal(sent, 1, 'onSent reloads the notes');
    assert.equal(textBox(root).value, '', 'the box clears after a send');
  });
});

test('C1b "Tell the agent now" with a running build sends one api.steer with the build\'s job_id', async () => {
  const apiObj = fakeApi();
  await mounted({ job: RUNNING, apiObj }, async (root) => {
    await type(root, 'now', 'Skip the docs pass');
    fire(sendButton(root), 'click');
    await flush();
    assert.equal(apiObj.calls.length, 1);
    assert.equal(apiObj.calls[0].mode, 'now');
    assert.equal(apiObj.calls[0].job_id, RUNNING.id);
    assert.equal(apiObj.calls[0].text, 'Skip the docs pass');
  });
});

test('C1c a refused send shows the worker\'s error as a bad tag and keeps the text', async () => {
  const apiObj = fakeApi(() => new Error('job x is a done build job; only a running build reads a note now'));
  let sent = 0;
  await mounted({ job: RUNNING, apiObj, onSent: () => { sent += 1; } }, async (root) => {
    await type(root, 'now', 'Too late');
    fire(sendButton(root), 'click');
    await flush();
    assert.equal(apiObj.calls.length, 1);
    const bad = all(root).find((n) => n.attrs && n.attrs.class === 'tag tag--bad');
    assert.ok(bad, 'a tag tag--bad line');
    assert.match(bad.textContent, /only a running build reads a note now/);
    assert.equal(sent, 0, 'a failed send never reloads as if it worked');
    assert.equal(textBox(root).value, 'Too late');
  });
});

test('C1d a 2xx answer with no stored note is not a send: it shows "bad response" and does not reload', async () => {
  const apiObj = fakeApi(() => ({}));
  let sent = 0;
  await mounted({ job: RUNNING, apiObj, onSent: () => { sent += 1; } }, async (root) => {
    await type(root, 'ticket', 'Hello');
    fire(sendButton(root), 'click');
    await flush();
    assert.equal(apiObj.calls.length, 1);
    const bad = all(root).find((n) => n.attrs && n.attrs.class === 'tag tag--bad');
    assert.ok(bad);
    assert.match(bad.textContent, /bad response/);
    assert.equal(sent, 0);
    assert.equal(textBox(root).value, 'Hello');
  });
});

test('C2 "Hold, then tell it" asks in the in-app HOLD TICKET dialog first; HOLD sends one api.steer with mode hold and the job_id', async () => {
  const apiObj = fakeApi();
  await mounted({ job: RUNNING, apiObj }, async (root) => {
    await type(root, 'hold', 'Wait for the schema review');
    fire(sendButton(root), 'click');
    await flush();
    const dialog = dialogOf(root);
    assert.ok(dialog, 'the in-app dialog opened');
    assert.equal(dialog.attrs['aria-label'], 'HOLD TICKET');
    assert.match(dialog.textContent, /Wait for the schema review/, 'the note is shown');
    assert.equal(confirmOf(dialog).textContent.trim(), 'HOLD');
    assert.match(confirmOf(dialog).attrs.class, /\bbtn--warn\b/, 'tone warn');
    assert.equal(apiObj.calls.length, 0, 'nothing is sent before the confirm');
    fire(confirmOf(dialog), 'click');
    await flush();
    assert.equal(apiObj.calls.length, 1);
    assert.deepEqual(apiObj.calls[0], { project: PROJECT, ticket: TICKET, mode: 'hold', text: 'Wait for the schema review', job_id: RUNNING.id });
    assert.equal(dialogOf(root), undefined);
  });
});

test('C3 CANCEL in the HOLD TICKET dialog sends nothing and keeps the text', async () => {
  const apiObj = fakeApi();
  let sent = 0;
  await mounted({ job: RUNNING, apiObj, onSent: () => { sent += 1; } }, async (root) => {
    await type(root, 'hold', 'Stop here');
    fire(sendButton(root), 'click');
    await flush();
    fire(cancelOf(dialogOf(root)), 'click');
    await flush();
    assert.equal(apiObj.calls.length, 0);
    assert.equal(sent, 0);
    assert.equal(dialogOf(root), undefined);
    assert.equal(textBox(root).value, 'Stop here');
  });
});

test('C4 a "now" note with no running build is never built, and the now radio is disabled with the reason', async () => {
  const base = { project: PROJECT, ticket: TICKET, mode: 'now', text: 'x' };
  assert.equal(canSendNow(RUNNING), true);
  assert.equal(steerBody({ ...base, job: DONE }), null);
  assert.equal(steerBody({ ...base, job: null }), null);
  assert.equal(steerBody({ ...base, job: { ...RUNNING, kind: 'triage' } }), null);
  assert.deepEqual(steerBody({ ...base, job: RUNNING }), { ...base, job_id: RUNNING.id });
  // A ticket note never carries a job; a hold to a finished build carries none either.
  assert.equal('job_id' in steerBody({ ...base, mode: 'ticket', job: RUNNING }), false);
  assert.equal('job_id' in steerBody({ ...base, mode: 'hold', job: DONE }), false);

  const apiObj = fakeApi();
  await mounted({ job: DONE, apiObj }, async (root) => {
    assert.equal(isDisabled(radio(root, 'now')), true);
    assert.equal(isDisabled(radio(root, 'ticket')), false);
    assert.equal(isDisabled(radio(root, 'hold')), false);
    assert.match(root.textContent, /No build is running/);
  });
  const off = render(h(AgentSession, { live: false, stage: 'Done', feed: [], project: PROJECT, ticket: TICKET, job: null, notes: [] }));
  assert.match(off, /<input[^>]*value="now"[^>]*disabled|<input[^>]*disabled[^>]*value="now"/);
  const on = render(h(AgentSession, { live: true, stage: 'Execute', feed: [], project: PROJECT, ticket: TICKET, job: RUNNING, notes: [] }));
  assert.doesNotMatch(on, /<input[^>]*value="now"[^>]*disabled|<input[^>]*disabled[^>]*value="now"/);
  assert.doesNotMatch(visible(on), /No build is running/);
});

test('C5 steerBody is null for blank text, a hold over the 500-char hold reason, text over 4000, an unknown mode', async () => {
  const base = { project: PROJECT, ticket: TICKET, job: RUNNING };
  assert.equal(HOLD_REASON_MAX, 500);
  assert.equal(STEER_TEXT_MAX, 4000);
  assert.equal(steerBody({ ...base, mode: 'ticket', text: '   ' }), null);
  assert.equal(steerBody({ ...base, mode: 'ticket', text: null }), null);
  assert.equal(steerBody({ ...base, mode: 'hold', text: 'x'.repeat(501) }), null);
  assert.ok(steerBody({ ...base, mode: 'hold', text: 'x'.repeat(500) }));
  assert.equal(steerBody({ ...base, mode: 'ticket', text: 'x'.repeat(4001) }), null);
  assert.ok(steerBody({ ...base, mode: 'ticket', text: 'x'.repeat(4000) }));
  assert.equal(steerBody({ ...base, mode: 'shout', text: 'x' }), null);
  assert.equal(steerBody({ ...base, project: null, mode: 'ticket', text: 'x' }), null);

  // The component holds SEND off for the same inputs.
  const apiObj = fakeApi();
  await mounted({ job: RUNNING, apiObj }, async (root) => {
    assert.equal(isDisabled(sendButton(root)), true, 'an empty box cannot send');
    await type(root, 'hold', 'y'.repeat(501));
    assert.equal(isDisabled(sendButton(root)), true, 'a hold over 500 cannot send');
    fire(sendButton(root), 'click');
    await flush();
    assert.equal(apiObj.calls.length, 0);
    assert.equal(dialogOf(root), undefined);
  });
});

test('C6 steerState echoes each note with its state, and the echo list renders newest first with a job link', async () => {
  assert.equal(steerState(note({}), RUNNING), 'waiting');
  assert.equal(steerState(note({ status: 'read', build_read_at: '2026-10-12T20:05:30Z' }), RUNNING), 'read by the build at 20:05Z');
  assert.equal(steerState(note({ mode: 'ticket', job_id: null, status: 'delivered' }), RUNNING), 'posted');
  assert.equal(steerState(note({ status: 'taken' }), RUNNING), 'in the prompt of the step running now');
  assert.equal(steerState(note({ status: 'taken' }), DONE), 'taken by a step that did not report');
  assert.equal(steerState(note({ status: 'pending' }), DONE), 'not read: the build ended before its next step');
  assert.equal(steerState(note({ mode: 'ticket', job_id: null, status: 'delivering' }), RUNNING), 'posting');
  assert.equal(steerState(note({ mode: 'hold', status: 'delivered' }), RUNNING), 'held');
  assert.equal(steerState(note({ mode: 'ticket', job_id: null, status: 'failed', detail: 'gh 502' }), RUNNING), 'not delivered: gh 502');
  assert.equal(steerState(note({}), DONE), 'not read: the build ended before its next step');
  assert.equal(steerState(note({ mode: 'ticket', job_id: null }), DONE), 'waiting', 'a ticket note waits on the hub, not the build');

  const notes = [
    note({ id: 3, mode: 'ticket', job_id: null, status: 'delivered', text: 'third', created_at: '2026-10-12T20:03:00Z' }),
    note({ id: 2, status: 'read', build_read_at: '2026-10-12T20:05:30Z', text: 'second', created_at: '2026-10-12T20:02:00Z' }),
    note({ id: 1, text: 'first' })
  ];
  const out = render(h(AgentSession, { live: true, stage: 'Execute', feed: [], project: PROJECT, ticket: TICKET, job: RUNNING, notes: [...notes].reverse() }));
  const v = visible(out);
  assert.ok(v.indexOf('third') < v.indexOf('second') && v.indexOf('second') < v.indexOf('first'), 'newest first');
  assert.match(v, /posted/);
  assert.match(v, /read by the build at 20:05Z/);
  assert.match(v, /waiting/);
  assert.ok(out.includes(`href="/jobs/${RUNNING.id}"`), 'a note sent to a job links that job');
  assert.match(out, /class="steer-notes"/);
});

test('C8 the real ticket page loads the notes through the coord proxy, echoes them, and a SEND posts through api.steer and reloads them', async () => {
  const calls = [];
  const stored = [note({ id: 4, mode: 'ticket', job_id: null, status: 'delivered', text: 'earlier note' })];
  globalThis.fetch = async (url, init = {}) => {
    const u = String(url);
    const method = init.method || 'GET';
    calls.push({ url: u, method, body: init.body ? JSON.parse(init.body) : undefined });
    let a = [404, { error: 'nope' }];
    if (u.startsWith('/api/coord/jobs?')) a = [200, { as_of: '2026-10-12T20:10:00Z', jobs: [{ ...RUNNING, stage: 'execute', created_at: '2026-10-12T19:00:00Z' }] }];
    else if (u === `/api/coord/jobs/${RUNNING.id}`) a = [200, { job: RUNNING, phases: [], events: [], transcripts: [] }];
    else if (u.startsWith('/api/coord/steer?') && method === 'GET') a = [200, { notes: [...stored].reverse(), as_of: 'x' }];
    else if (u === '/api/coord/steer' && method === 'POST') {
      const b = JSON.parse(init.body);
      stored.push(note({ id: 5, mode: b.mode, job_id: null, text: b.text }));
      a = [201, { note: stored[stored.length - 1] }];
    }
    const [status, body] = a;
    return { ok: status >= 200 && status < 300, status, text: async () => JSON.stringify(body) };
  };
  const doc = installDom();
  const root = doc.createElement('div');
  mount(h(TicketScreen, { ticket: TICKET }), root);
  try {
    await flush();
    const reads = () => calls.filter((c) => c.url.startsWith('/api/coord/steer?') && c.method === 'GET');
    assert.deepEqual(reads().map((c) => c.url), [`/api/coord/steer?project=${PROJECT}&ticket=${TICKET}`]);
    assert.match(root.textContent, /earlier note/);
    assert.match(root.textContent, /posted/);
    assert.equal(isDisabled(radio(root, 'now')), false, 'the page hands its running build to the composer');
    assert.ok(all(root).some((n) => n.localName === 'button' && n.textContent.trim() === 'STEP IN'));
    await type(root, 'ticket', 'Use the helper');
    fire(sendButton(root), 'click');
    await flush();
    const sends = calls.filter((c) => c.url === '/api/coord/steer' && c.method === 'POST');
    assert.deepEqual(sends.map((c) => c.body), [{ project: PROJECT, ticket: TICKET, mode: 'ticket', text: 'Use the helper' }]);
    assert.equal(reads().length, 2, 'a send reloads the notes');
    assert.match(root.textContent, /Use the helper/);
  } finally { mount(null, root); }
});

test('C7 no native dialog in the composer, the ticket page or the steer lib', () => {
  for (const f of ['../src/ui/AgentSession.js', '../src/screens/Ticket.js', '../src/lib/steer.js']) {
    const src = readFileSync(new URL(f, import.meta.url), 'utf8');
    assert.ok(src.length > 0, `${f} is empty`);
    assert.doesNotMatch(src, /\b(window|globalThis|self)\.(alert|confirm|prompt)\b/, `${f} calls a native dialog`);
    assert.doesNotMatch(src, /(^|[^.\w])(alert|prompt|confirm)\s*\(/m, `${f} calls a native dialog`);
  }
});
