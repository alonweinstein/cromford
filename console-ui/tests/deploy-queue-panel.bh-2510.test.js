import test, { afterEach } from 'node:test';
import assert from 'node:assert/strict';
import { h, render as mount } from 'preact';
import { render } from 'preact-render-to-string';
import { QUEUE_LIMIT, panelState } from '../src/lib/queue-panel.js';
import {
  allowedActions, actionBody, deployCells, rowsNote, mergeDeployReads, deployTableState, releaseOutcome
} from '../src/lib/deploy-queue-panel.js';
import { DeployQueueView } from '../src/screens/DeployQueuePanel.js';
import { flush } from './helpers/settle.js';

// BH-3152 (BH-2510.2): the DEPLOY QUEUE table in the QUEUES section of
// /p/<project>, and its audited RELEASE. The pure half is driven directly, the
// view is rendered from props, and the panel is mounted through the real
// ProjectScreen with a faked fetch, down to the POST a confirmed RELEASE sends.

const SHA_A = 'a'.repeat(40);
const SHA_B = 'b'.repeat(40);
const ok = (data) => ({ data, error: null });
const rows = (n) => Array.from({ length: n }, (_, i) => ({ sha: String(i).padStart(8, '0'), status: 'queued' }));

test('allowedActions: release only on a claimed row that has not departed', () => {
  assert.deepEqual(allowedActions({ status: 'claimed', departed_at: null }), ['release']);
  for (const r of [
    { status: 'queued' }, { status: 'done', departed_at: 't' }, { status: 'failed', departed_at: 't' },
    { status: 'claimed', departed_at: '2026-09-28T00:00:00Z' }, null, {}, 'claimed'
  ]) assert.deepEqual(allowedActions(r), [], JSON.stringify(r));
});

test('actionBody: strings only, reason trimmed, and never an actor key', () => {
  const b = actionBody('p', { sha: SHA_A, actor: 'x', status: 'claimed' }, 'release', '  why ');
  assert.deepEqual(b, { project: 'p', sha: SHA_A, action: 'release', reason: 'why' });
  assert.equal('actor' in b, false);
});

test('rowsNote: true to the box\'s own truth table in every state', () => {
  for (const v of ['1', 'on', 'true', 'yes']) {
    const n = rowsNote(ok({ setting: { key: 'deploy_queue_rows', value: v } }));
    assert.equal(n.on, true, v);
    assert.match(n.text, /deploy_queue_rows is on/);
  }
  for (const v of ['0', 'off', 'ON', 'no']) {
    const n = rowsNote(ok({ setting: { key: 'deploy_queue_rows', value: v } }));
    assert.equal(n.on, false, v);
    assert.match(n.text, /changes nothing a train sees/);
  }
  const unset = rowsNote(ok({ setting: null }));
  assert.equal(unset.on, null);
  assert.match(unset.text, /not set here/);
  const blank = rowsNote(ok({ setting: { key: 'deploy_queue_rows', value: '' } }));
  assert.match(blank.text, /not set here/, 'an empty value falls back to the env, like a missing row');
  for (const k of [{ data: null, error: new Error('x') }, ok({}), ok({ setting: { value: 1 } }), null, { data: null, error: null }]) {
    const n = rowsNote(k);
    assert.equal(n.on, null);
    assert.match(n.text, /could not read deploy_queue_rows/);
  }
});

test('mergeDeployReads + panelState: either read failing is an error, never half a list', () => {
  const good = ok({ deploy_queue: rows(2) });
  const bad = { data: { deploy_queue: rows(1) }, error: new Error('boom') };
  assert.equal(panelState({ deploy: mergeDeployReads(good, bad) }).deploy.kind, 'error');
  assert.equal(panelState({ deploy: mergeDeployReads(bad, good) }).deploy.kind, 'error');
  assert.equal(panelState({ deploy: mergeDeployReads(good, ok({})) }).deploy.kind, 'error', 'a body without its array');
  const both = panelState({ deploy: mergeDeployReads(good, ok({ deploy_queue: rows(3) })) }).deploy;
  assert.equal(both.kind, 'ok');
  assert.equal(both.rows.length, 5);
  assert.equal(both.capped, false);
});

test('mergeDeployReads: a read at QUEUE_LIMIT is capped, measured per read', () => {
  const full = ok({ deploy_queue: rows(QUEUE_LIMIT) });
  const one = ok({ deploy_queue: rows(1) });
  assert.equal(panelState({ deploy: mergeDeployReads(full, ok({ deploy_queue: [] })) }).deploy.capped, true);
  assert.equal(panelState({ deploy: mergeDeployReads(one, full) }).deploy.capped, true);
  // 300 + 300 is 600 rows but neither read hit its clamp.
  const half = ok({ deploy_queue: rows(300) });
  assert.equal(mergeDeployReads(half, half).data.capped, false);
  assert.equal(mergeDeployReads(ok({ deploy_queue: rows(QUEUE_LIMIT - 1) }), one).data.capped, false);
  // What the table renders takes the per-read cap, not panelState's combined length.
  assert.equal(deployTableState(half, half).capped, false);
  assert.equal(deployTableState(half, half).rows.length, 600);
  assert.equal(deployTableState(full, one).capped, true);
});

test('deployTableState: loading until both reads answered; an error wins over loading', () => {
  const pending = { data: null, error: null };
  assert.equal(deployTableState(pending, pending).kind, 'loading');
  assert.equal(deployTableState(ok({ deploy_queue: [] }), pending).kind, 'loading');
  assert.equal(deployTableState({ data: null, error: new Error('x') }, pending).kind, 'error');
  assert.equal(deployTableState(ok({ deploy_queue: [] }), ok({ deploy_queue: [] })).kind, 'ok');
});

test('deployCells: sha8, dashes for blanks, and a missing enqueued_at is null, never 0', (t) => {
  // Clock pinned to one anchor so the 5-minute age is exact, not wall-clock dependent.
  const ANCHOR = Date.parse('2026-09-28T12:00:00Z');
  t.mock.timers.enable({ apis: ['Date'], now: ANCHOR });
  const c = deployCells({ sha: SHA_A, status: 'claimed', claimed_by: 'box-a', build_dir: '/b', enqueued_at: new Date(ANCHOR - 5 * 60e3).toISOString() });
  assert.equal(c.sha8, 'aaaaaaaa');
  assert.equal(c.sha, SHA_A);
  assert.equal(c.claimed_by, 'box-a');
  assert.equal(c.age_min, 5);
  const bare = deployCells({ sha: SHA_B, status: 'queued' });
  assert.equal(bare.claimed_by, '—');
  assert.equal(bare.build_dir, '—');
  assert.equal(bare.age_min, null);
});

test('releaseOutcome: success only from decision:released', () => {
  const good = releaseOutcome({ decision: 'released', deploy: { sha: SHA_A } });
  assert.equal(good.ok, true);
  assert.equal(good.text, 'Released aaaaaaaa: back to queued.');
  const err = Object.assign(new Error('release refused: row is done'), { status: 409 });
  const bad = releaseOutcome(err);
  assert.equal(bad.ok, false);
  assert.match(bad.text, /release refused: row is done/);
  const odd = releaseOutcome({});
  assert.equal(odd.ok, false);
  assert.match(odd.text, /unexpected answer/);
});

// ---- the view, rendered from props --------------------------------------------
const NOTE = { on: true, text: 'deploy_queue_rows is on: trains read these rows' };
const view = (state, extra = {}) => render(h(DeployQueueView, { state, note: NOTE, busy: false, msg: null, onAction() {}, onRetry() {}, onDismiss() {}, ...extra }));

test('view: a failed read is an ErrorBox with RETRY, never "nothing queued"', () => {
  const out = view(deployTableState({ data: null, error: new Error('coord down') }, ok({ deploy_queue: [] })));
  assert.match(out, /could not load/);
  assert.match(out, /coord down/);
  assert.match(out, /RETRY/);
  assert.doesNotMatch(out, /nothing queued/);
  assert.match(out, /DEPLOY QUEUE/);
});

test('view: two empty reads render "nothing queued" and the knob note', () => {
  const out = view(deployTableState(ok({ deploy_queue: [] }), ok({ deploy_queue: [] })));
  assert.match(out, /nothing queued/);
  assert.match(out, /deploy_queue_rows is on/);
  assert.doesNotMatch(out, /could not load/);
});

test('view: rows sort by enqueued ascending, six headers, RELEASE only on the claimed row', () => {
  const q = ok({ deploy_queue: [{ sha: SHA_B, status: 'queued', build_dir: '/later', enqueued_at: '2026-09-28T10:05:00Z' }] });
  const c = ok({ deploy_queue: [{ sha: SHA_A, status: 'claimed', claimed_by: 'box-a', build_dir: '/earlier', enqueued_at: '2026-09-28T10:00:00Z' }] });
  const out = view(deployTableState(q, c));
  const heads = ['SHA', 'STATUS', 'CLAIMED BY', 'BUILD DIR', 'ENQUEUED', 'ACTION'];
  let at = -1;
  for (const hd of heads) {
    const i = out.indexOf(`>${hd}`, at + 1);
    assert.ok(i > at, `header ${hd} in order`);
    at = i;
  }
  assert.ok(out.indexOf('aaaaaaaa') < out.indexOf('bbbbbbbb'), 'the older row renders first');
  assert.equal(out.split('>RELEASE<').length - 1, 1, 'one RELEASE, for the claimed row');
  assert.ok(out.indexOf('>RELEASE<') < out.indexOf('bbbbbbbb'), 'and it sits on the claimed row');
  assert.match(out, new RegExp(`title="${SHA_A}"`), 'the full sha rides in the title');
  assert.doesNotMatch(out, /more may exist/);
});

test('view: a capped read says so; the banner shows the outcome with DISMISS', () => {
  const capped = deployTableState(ok({ deploy_queue: rows(QUEUE_LIMIT) }), ok({ deploy_queue: [] }));
  assert.match(view(capped), /first 500 per status shown; more may exist/);
  const out = view(capped, { msg: { ok: true, text: 'Released aaaaaaaa: back to queued.' } });
  assert.match(out, /Released aaaaaaaa: back to queued\./);
  assert.match(out, /DISMISS/);
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

test('ProjectScreen: the DEPLOY QUEUE table reads queued+claimed+knob, and a confirmed RELEASE posts the reason, no actor', async () => {
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
      body = { deploy_queue: [{ project: 'project-3', sha: SHA_B, status: 'queued', enqueued_at: '2026-09-28T10:05:00Z' }] };
    } else if (u.startsWith('/api/coord/deploy-queue?') && u.includes('status=claimed')) {
      body = { deploy_queue: [{ project: 'project-3', sha: SHA_A, status: 'claimed', claimed_by: 'box-a', enqueued_at: '2026-09-28T10:00:00Z' }] };
    } else if (u.startsWith('/api/coord/deploy-queue?') && u.includes('status=held')) {
      body = { deploy_queue: [] }; // TEST-CHANGE: BH-3154 — the panel's third read
    } else if (u === '/api/coord/settings/deploy_queue_rows') body = { setting: { key: 'deploy_queue_rows', value: '0' } };
    else if (u === '/api/coord/deploy-queue/action') body = { decision: 'released', deploy: { sha: SHA_A, status: 'queued' } };
    return { ok: true, status: 200, text: async () => JSON.stringify(body) };
  };
  const { ProjectScreen } = await import('../src/screens/Project.js');
  const root = doc.createElement('div');
  mount(h(ProjectScreen, { project: 'project-3' }), root);
  mounted.push(root);
  await flush();
  await flush();
  const gets = calls.filter((c) => /\/api\/coord\/(deploy-queue|settings\/deploy_queue_rows)/.test(c.url)).map((c) => c.url).sort();
  assert.deepEqual(gets, [
    '/api/coord/deploy-queue?project=project-3&status=claimed&limit=500',
    '/api/coord/deploy-queue?project=project-3&status=held&limit=500', // TEST-CHANGE: BH-3154
    '/api/coord/deploy-queue?project=project-3&status=queued&limit=500',
    '/api/coord/settings/deploy_queue_rows',
  ]);
  const text = root.textContent;
  assert.match(text, /DEPLOY QUEUE/);
  assert.match(text, /deploy_queue_rows is off/);
  assert.ok(text.indexOf('aaaaaaaa') < text.indexOf('bbbbbbbb'), 'older row first');
  const rel = buttons(root, 'RELEASE');
  assert.equal(rel.length, 1, 'RELEASE only on the claimed row');

  click(rel[0]);
  await flush();
  const dlg = dialog(root);
  assert.ok(dlg, 'the in-app modal opened');
  assert.match(dlg.textContent, /changes nothing a train sees/, 'the dialog is honest about the knob being off');
  const confirmBtn = buttons(dlg, 'RELEASE').pop();
  assert.ok(isDisabled(confirmBtn), 'confirm is blocked until a reason is typed');
  assert.ok(isDisabled(buttons(root, 'RELEASE')[0]), 'the row button is disabled while the dialog is open');
  const input = all(dlg).find((n) => n.localName === 'input');
  type(input, '  train died  ');
  await flush();
  assert.equal(isDisabled(confirmBtn), false);
  const actionPosts = () => calls.filter((c) => c.method === 'POST' && c.url === '/api/coord/deploy-queue/action');
  assert.equal(actionPosts().length, 0, 'nothing sent before confirm');
  click(confirmBtn);
  await flush();
  await flush();
  const posts = actionPosts();
  assert.equal(posts.length, 1);
  assert.deepEqual(JSON.parse(posts[0].body), { project: 'project-3', sha: SHA_A, action: 'release', reason: 'train died' });
  assert.match(root.textContent, /Released aaaaaaaa: back to queued\./);
  assert.equal(dialog(root), undefined, 'the dialog closed');
});
