import test, { afterEach } from 'node:test';
import assert from 'node:assert/strict';
import { h, render as mount } from 'preact';
import { render } from 'preact-render-to-string';
import { QUEUE_LIMIT } from '../src/lib/queue-panel.js';
import {
  allowedActions, mergeDeployReads, deployTableState, actionOutcome, releaseOutcome
} from '../src/lib/deploy-queue-panel.js';
import { DeployQueueView } from '../src/screens/DeployQueuePanel.js';
import { flush } from './helpers/settle.js';

// BH-3154 (BH-2510.4): HOLD / UNHOLD on the DEPLOY QUEUE table of /p/<project>.
// The pure half is driven directly, the view from props, and the panel through
// the real ProjectScreen with a faked fetch, down to the POST a confirmed HOLD
// and UNHOLD send.

const SHA_Q = 'a'.repeat(40);
const SHA_H = 'b'.repeat(40);
const SHA_C = 'c'.repeat(40);
const ok = (data) => ({ data, error: null });
const rows = (n) => Array.from({ length: n }, (_, i) => ({ sha: String(i).padStart(8, '0'), status: 'queued' }));

test('allowedActions: hold on queued only with the knob on; unhold on held always', () => {
  assert.deepEqual(allowedActions({ status: 'queued' }, true), ['hold']);
  for (const on of [false, undefined, null, 'true', 1]) {
    assert.deepEqual(allowedActions({ status: 'queued' }, on), [], `rowsOn ${JSON.stringify(on)}`);
  }
  for (const on of [true, false, undefined]) {
    assert.deepEqual(allowedActions({ status: 'held' }, on), ['unhold']);
    assert.deepEqual(allowedActions({ status: 'claimed', departed_at: null }, on), ['release']);
    for (const r of [{ status: 'done', departed_at: 't' }, { status: 'failed', departed_at: 't' },
      { status: 'claimed', departed_at: 't' }, null, {}]) {
      assert.deepEqual(allowedActions(r, on), [], JSON.stringify(r));
    }
  }
});

test('mergeDeployReads / deployTableState: three reads, any failure is an error, cap per read', () => {
  const e = { data: null, error: new Error('x') };
  const pending = { data: null, error: null };
  const empty = ok({ deploy_queue: [] });
  assert.equal(mergeDeployReads(empty, empty, e).error.message, 'x');
  assert.equal(deployTableState(empty, empty, e).kind, 'error');
  assert.equal(deployTableState(empty, empty, pending).kind, 'loading');
  assert.equal(deployTableState(e, empty, pending).kind, 'error', 'an error wins over loading');
  const st = deployTableState(ok({ deploy_queue: rows(1) }), ok({ deploy_queue: rows(2) }), ok({ deploy_queue: rows(3) }));
  assert.equal(st.kind, 'ok');
  assert.equal(st.rows.length, 6);
  assert.equal(st.capped, false);
  assert.equal(deployTableState(empty, empty, ok({ deploy_queue: rows(QUEUE_LIMIT) })).capped, true);
});

test('actionOutcome: success only from the matching decision; errors carry the worker message', () => {
  assert.deepEqual(actionOutcome({ decision: 'held', deploy: { sha: SHA_Q } }, 'hold'),
    { ok: true, text: 'Held aaaaaaaa: the train will not depart while it is held.' });
  assert.deepEqual(actionOutcome({ decision: 'unheld', deploy: { sha: SHA_H } }, 'unhold'),
    { ok: true, text: 'Unheld bbbbbbbb: back to queued.' });
  assert.deepEqual(actionOutcome({ decision: 'released', deploy: { sha: SHA_C } }, 'release'),
    { ok: true, text: 'Released cccccccc: back to queued.' });
  assert.deepEqual(releaseOutcome({ decision: 'released', deploy: { sha: SHA_C } }),
    actionOutcome({ decision: 'released', deploy: { sha: SHA_C } }, 'release'));
  const knobOff = Object.assign(new Error('hold refused: deploy_queue_rows is not on, trains read the file dir'), { status: 409 });
  const bad = actionOutcome(knobOff, 'hold');
  assert.equal(bad.ok, false);
  assert.equal(bad.text, 'HOLD failed: hold refused: deploy_queue_rows is not on, trains read the file dir');
  // A decision for a different action is not a success.
  assert.equal(actionOutcome({ decision: 'released', deploy: { sha: SHA_Q } }, 'hold').ok, false);
  assert.match(actionOutcome({}, 'unhold').text, /UNHOLD: unexpected answer/);
});

// ---- the view, rendered from props --------------------------------------------
const state3 = () => deployTableState(
  ok({ deploy_queue: [{ sha: SHA_Q, status: 'queued', enqueued_at: '2026-09-28T10:05:00Z' }] }),
  ok({ deploy_queue: [{ sha: SHA_C, status: 'claimed', claimed_by: 'box-a', enqueued_at: '2026-09-28T10:00:00Z' }] }),
  ok({ deploy_queue: [{ sha: SHA_H, status: 'held', reason: 'bad migration', enqueued_at: '2026-09-28T10:10:00Z' }] }));
const view = (note) => render(h(DeployQueueView, {
  state: state3(), note, busy: false, msg: null, onAction() {}, onRetry() {}, onDismiss() {}
}));

test('view: knob on offers HOLD on queued, UNHOLD on held, RELEASE on claimed', () => {
  const out = view({ on: true, text: 'deploy_queue_rows is on' });
  for (const b of ['HOLD', 'UNHOLD', 'RELEASE']) assert.equal(out.split(`>${b}<`).length - 1, 1, b);
  // enqueued asc: claimed 10:00, queued 10:05, held 10:10.
  const at = (s) => out.indexOf(s);
  assert.ok(at('cccccccc') < at('>RELEASE<') && at('>RELEASE<') < at('aaaaaaaa'));
  assert.ok(at('aaaaaaaa') < at('>HOLD<') && at('>HOLD<') < at('bbbbbbbb'));
  assert.ok(at('bbbbbbbb') < at('>UNHOLD<'));
  assert.match(out, />held</);
});

test('view: knob off or unread offers no HOLD, and UNHOLD is still there', () => {
  for (const note of [{ on: false, text: 'deploy_queue_rows is off' }, { on: null, text: 'could not read deploy_queue_rows.' }]) {
    const out = view(note);
    assert.equal(out.split('>HOLD<').length - 1, 0, JSON.stringify(note));
    assert.equal(out.split('>UNHOLD<').length - 1, 1);
    assert.equal(out.split('>RELEASE<').length - 1, 1);
  }
});

// ---- the production entry point: the real Project page, mounted -------------
class FakeNode {
  constructor(nodeType, name, data) {
    Object.assign(this, { nodeType, localName: name, nodeName: name ? name.toUpperCase() : '#text', data,
      childNodes: [], parentNode: null, attrs: {}, style: {}, listeners: {} });
  }
  get onclick() { return null; }
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
  removeChild(n) { this.childNodes.splice(this.childNodes.indexOf(n), 1); n.parentNode = null; return n; }
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
const all = (n, out = []) => { out.push(n); n.childNodes.forEach((c) => all(c, out)); return out; };
const buttons = (root, label) => all(root).filter((n) => n.localName === 'button' && n.textContent.trim() === label);
const dialog = (root) => all(root).find((n) => n.attrs && n.attrs.role === 'dialog');
const isDisabled = (n) => n.disabled === true || ('disabled' in n.attrs && n.attrs.disabled !== 'false');
const click = (el) => el.listeners.click.call(el, { type: 'click', target: el, currentTarget: el, preventDefault() {}, stopPropagation() {} });
const type = (el, value) => { el.value = value; el.listeners.input.call(el, { type: 'input', target: el, currentTarget: el }); };
const mounted = [];
afterEach(() => { while (mounted.length) mount(null, mounted.pop()); });

test('ProjectScreen: reads status=held, and HOLD / UNHOLD confirm with a required reason and post it', async () => {
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
    let body = {};
    if (u.startsWith('/api/dash/p/')) body = { board: {}, runs: [], builds: [], alerts: [], events: [] };
    else if (u.startsWith('/api/coord/deploy-queue?') && u.includes('status=queued')) {
      body = { deploy_queue: [{ project: 'project-3', sha: SHA_Q, status: 'queued', enqueued_at: '2026-09-28T10:05:00Z' }] };
    } else if (u.startsWith('/api/coord/deploy-queue?') && u.includes('status=claimed')) {
      body = { deploy_queue: [] };
    } else if (u.startsWith('/api/coord/deploy-queue?') && u.includes('status=held')) {
      body = { deploy_queue: [{ project: 'project-3', sha: SHA_H, status: 'held', enqueued_at: '2026-09-28T10:10:00Z' }] };
    } else if (u === '/api/coord/settings/deploy_queue_rows') body = { setting: { key: 'deploy_queue_rows', value: '1' } };
    else if (u === '/api/coord/deploy-queue/action') {
      const a = JSON.parse(init.body).action;
      body = { decision: a === 'hold' ? 'held' : 'unheld', deploy: { sha: JSON.parse(init.body).sha } };
    }
    return { ok: true, status: 200, text: async () => JSON.stringify(body) };
  };
  const { ProjectScreen } = await import('../src/screens/Project.js');
  const root = doc.createElement('div');
  mount(h(ProjectScreen, { project: 'project-3' }), root);
  mounted.push(root);
  await flush();
  await flush();
  const gets = calls.filter((c) => c.url.startsWith('/api/coord/deploy-queue?')).map((c) => c.url).sort();
  assert.deepEqual(gets, [
    '/api/coord/deploy-queue?project=project-3&status=claimed&limit=500',
    '/api/coord/deploy-queue?project=project-3&status=held&limit=500',
    '/api/coord/deploy-queue?project=project-3&status=queued&limit=500',
  ]);
  assert.match(root.textContent, /bbbbbbbb/, 'the held row renders');
  const actionPosts = () => calls.filter((c) => c.method === 'POST' && c.url === '/api/coord/deploy-queue/action');

  // HOLD on the queued row.
  const hold = buttons(root, 'HOLD');
  assert.equal(hold.length, 1);
  click(hold[0]);
  await flush();
  let dlg = dialog(root);
  assert.ok(dlg, 'the in-app modal opened');
  assert.match(dlg.textContent, /The train will not depart and will not self-source while this is held\./);
  assert.match(dlg.textContent, /aaaaaaaa/);
  let confirmBtn = buttons(dlg, 'HOLD').pop();
  assert.ok(isDisabled(confirmBtn), 'confirm is blocked until a reason is typed');
  type(all(dlg).find((n) => n.localName === 'input'), '  bad migration  ');
  await flush();
  assert.equal(isDisabled(confirmBtn), false);
  assert.equal(actionPosts().length, 0, 'nothing sent before confirm');
  click(confirmBtn);
  await flush();
  await flush();
  assert.equal(actionPosts().length, 1);
  assert.deepEqual(JSON.parse(actionPosts()[0].body), { project: 'project-3', sha: SHA_Q, action: 'hold', reason: 'bad migration' });
  assert.match(root.textContent, /Held aaaaaaaa/);
  assert.equal(dialog(root), undefined);

  // UNHOLD on the held row.
  const unhold = buttons(root, 'UNHOLD');
  assert.equal(unhold.length, 1);
  click(unhold[0]);
  await flush();
  dlg = dialog(root);
  assert.ok(dlg);
  assert.match(dlg.textContent, /Unhold bbbbbbbb\? It goes back to queued and the next train departs with it\./);
  confirmBtn = buttons(dlg, 'UNHOLD').pop();
  assert.ok(isDisabled(confirmBtn));
  type(all(dlg).find((n) => n.localName === 'input'), 'fixed');
  await flush();
  click(confirmBtn);
  await flush();
  await flush();
  assert.equal(actionPosts().length, 2);
  assert.deepEqual(JSON.parse(actionPosts()[1].body), { project: 'project-3', sha: SHA_H, action: 'unhold', reason: 'fixed' });
  assert.match(root.textContent, /Unheld bbbbbbbb: back to queued\./);
});
