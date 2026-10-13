import test from 'node:test';
import assert from 'node:assert/strict';
import { render } from 'preact-render-to-string';
import { h } from 'preact';
import { Modal } from '../src/ui/Modal.js';
import { ROUTES } from '../src/app.js';
import { HubScreen, HubView, PromoteForm, runPromote, BACKUP_COLUMNS } from '../src/screens/Hub.js';
import { backupRows } from '../src/lib/hub.js';
import { sortRows } from '../src/lib/sort.js';
import { RestoreLabPanel } from '../src/screens/hub/RestoreLab.js';

// BH-1945 (BH-1909.3): the HUB screen, rendered. preact-render-to-string runs
// no effects or handlers, so HubView is driven with each load state directly,
// HubScreen through the real /hub route, and the confirm path through
// runPromote — the one function the modal's confirm calls — against the real
// api.promoteHub with fetch captured.

const NOW = Date.parse('2026-09-24T15:00:00Z');
const noop = () => {};

const RECOVERY = {
  lease: { holder: 'hub-1', epoch: 7, expires_at: '2026-09-24T15:01:30Z', updated_at: '2026-09-24T14:59:30Z', live: true },
  role: { active: 'hub-1', standby: [] },
  backups: [
    { box: 'hub-1', backup_ts: '2026-09-24T14:48:00Z', backup_off: null, backup_unconfigured: null, backup_reported_at: '2026-09-24T14:50:00Z' },
    { box: 'hub-2', backup_ts: '', backup_off: null, backup_unconfigured: null, backup_reported_at: '2026-09-24T14:50:00Z' },
  ]
};

const loaded = (data) => ({ data, error: null, loading: false, fetchedAt: NOW });
const view = (state, extra = {}) => render(h(HubView, { state, now: NOW, onReload: noop, onPromote: noop, promoteMsg: null, ...extra }));

test('C3-T3 a 501 renders as a load error with RELOAD, never as the empty state', () => {
  const err = Object.assign(new Error('not_implemented'), { status: 501, body: { error: 'not_implemented' } });
  const out = view({ data: null, error: err, loading: false, fetchedAt: NOW });
  assert.match(out, /The hub recovery API is not deployed yet \(501\)\./);
  assert.match(out, /RELOAD/);
  assert.doesNotMatch(out, /No box has reported/);
  assert.doesNotMatch(out, /No hub lease recorded/);
});

test('C3-T3 no backups renders the empty copy and no error box', () => {
  const out = view(loaded({ ...RECOVERY, backups: [] }));
  assert.match(out, /No box has reported a backup stamp yet\./);
  assert.doesNotMatch(out, /class="banner"/);
  assert.doesNotMatch(out, /not deployed/);
});

test('loading renders the skeleton and neither the error nor the empty copy', () => {
  const out = view({ data: null, error: null, loading: true, fetchedAt: null });
  assert.match(out, /class="skel"/);
  assert.doesNotMatch(out, /No box has reported|class="banner"/);
});

test('the lease header: holder, epoch, time left, as-of; EXPIRED only when the lease is not live', () => {
  const out = view(loaded(RECOVERY));
  assert.match(out, /hub-1/);
  assert.match(out, /epoch <b>7<\/b>/);
  assert.match(out, /1m left/);
  assert.match(out, /as of 15:00:00Z/);
  assert.doesNotMatch(out, /EXPIRED/);
  const dead = view(loaded({ ...RECOVERY, lease: { ...RECOVERY.lease, live: false }, role: { active: null, standby: [] } }));
  assert.match(dead, />EXPIRED</);
  assert.match(dead, /expired holder: <b>hub-1<\/b>/);
});

test('C3-T1 the role section says "Standby: none recorded (#401)" for [] and for null', () => {
  assert.match(view(loaded(RECOVERY)), /Standby: none recorded \(#401\)/);
  assert.match(view(loaded({ ...RECOVERY, role: { active: 'hub-1', standby: null } })), /Standby: none recorded \(#401\)/);
  const listed = view(loaded({ ...RECOVERY, role: { active: 'hub-1', standby: ['hub-2'] } }));
  assert.doesNotMatch(listed, /none recorded/);
  assert.match(listed, /standby: <b>hub-2<\/b>/);
});

test('no lease: says so and PROMOTE is disabled', () => {
  const out = view(loaded({ ...RECOVERY, lease: null }));
  assert.match(out, /No hub lease recorded\./);
  assert.match(out, /<button[^>]*disabled[^>]*>PROMOTE<\/button>/);
});

test('with a lease and another box, PROMOTE is live', () => {
  const out = view(loaded(RECOVERY));
  const m = out.match(/<button[^>]*>PROMOTE<\/button>/);
  assert.ok(m, 'no PROMOTE button');
  assert.doesNotMatch(m[0], /disabled/);
});

test('the backups table: four sortable headers, one ascending, every BOX cell a link', () => {
  const out = view(loaded(RECOVERY));
  const ths = out.match(/<th[^>]*aria-sort="[a-z]+"[^>]*>\s*<button/g) || [];
  assert.equal(ths.length, 4);
  assert.equal((out.match(/aria-sort="ascending"/g) || []).length, 1);
  assert.match(out, /class="tablewrap"/);
  for (const box of ['hub-1', 'hub-2']) {
    assert.match(out, new RegExp(`<td[^>]*><a[^>]*href="/machines"[^>]*>${box}</a></td>`), box);
  }
  assert.match(out, /NO BACKUP/);
  assert.match(out, /backup 12m/);
});

test('AGE and LAST REPORTED sort on the minutes they show: ascending reads smallest first, and unknowns sink', () => {
  const rows = backupRows({ backups: [
    { box: 'old', backup_ts: '2026-09-24T14:00:00Z', backup_reported_at: '2026-09-24T14:30:00Z' },
    { box: 'silent', backup_ts: null, backup_reported_at: null },
    { box: 'new', backup_ts: '2026-09-24T14:55:00Z', backup_reported_at: '2026-09-24T14:58:00Z' },
  ] }, NOW);
  const col = (k) => BACKUP_COLUMNS.find((c) => c.key === k);
  for (const k of ['age', 'reported']) {
    assert.deepEqual(sortRows(rows, col(k).sort, 'asc').map((r) => r.box), ['new', 'old', 'silent'], k);
    assert.deepEqual(sortRows(rows, col(k).sort, 'desc').map((r) => r.box), ['old', 'new', 'silent'], k);
  }
});

test('a promote message renders, a failure in the bad tone', () => {
  const out = view(loaded(RECOVERY), { promoteMsg: { ok: false, text: 'Promote is not deployed yet (501). Nothing was changed.' } });
  assert.match(out, /knob__note--bad[^>]*>Promote is not deployed yet \(501\)\. Nothing was changed\./);
});

test('the promote Modal opens with PROMOTE disabled; the form offers every box but the holder and a typed-confirm input', () => {
  const out = render(h(Modal, {
    title: 'PROMOTE', confirmLabel: 'PROMOTE', tone: 'danger', confirmBlocked: true,
    body: ({ setBlocked }) => h(PromoteForm, { holder: 'hub-1', epoch: 7, targets: ['hub-2', 'hub-3'], value: { target: '', typed: '', reason: '' }, onBlocked: setBlocked }),
    onConfirm: noop, onCancel: noop
  }));
  const confirm = out.match(/<button[^>]*>PROMOTE<\/button>/);
  assert.ok(confirm);
  assert.match(confirm[0], /disabled/);
  assert.match(out, /<select/);
  assert.match(out, /<option[^>]*value="hub-2"/);
  assert.match(out, /<option[^>]*value="hub-3"/);
  assert.doesNotMatch(out, /<option[^>]*value="hub-1"/);
  assert.match(out, /Type the box name to confirm/);
  assert.match(out, /epoch <b>7<\/b>/);
});

// RestoreLabPanel renders nothing until #1946, so the string cannot show it.
// HubView calls no hooks, so its vnode tree is walked instead.
function findVnodes(node, type, out = []) {
  if (Array.isArray(node)) { node.forEach((n) => findVnodes(n, type, out)); return out; }
  if (!node || typeof node !== 'object') return out;
  if (node.type === type) out.push(node);
  findVnodes(node.props && node.props.children, type, out);
  return out;
}

test('HubView hands RestoreLabPanel the reported boxes, and none while loading', () => {
  const props = { now: NOW, onReload: noop, onPromote: noop, promoteMsg: null };
  const panels = findVnodes(HubView({ ...props, state: loaded(RECOVERY) }), RestoreLabPanel);
  assert.equal(panels.length, 1);
  assert.deepEqual(panels[0].props.boxes, ['hub-1', 'hub-2']);
  const empty = findVnodes(HubView({ ...props, state: { data: null, error: null, loading: true, fetchedAt: null } }), RestoreLabPanel);
  assert.deepEqual(empty.map((v) => v.props.boxes), [[]]);
});

function captureFetch(status, body) {
  const calls = [];
  globalThis.fetch = async (url, init = {}) => {
    calls.push({ url: String(url), method: init.method || 'GET', body: init.body });
    return { ok: status >= 200 && status < 300, status, text: async () => JSON.stringify(body) };
  };
  return calls;
}

test('runPromote sends one POST with the epoch the modal opened on and renders a 409 stale_epoch verbatim, no retry', async () => {
  const calls = captureFetch(409, { error: 'stale_epoch', lease: { holder: 'hub-2', epoch: 8 } });
  const msg = await runPromote({ target: 'hub-2', typed: 'hub-2', reason: ' drill ' }, ['hub-2'], 7);
  assert.equal(calls.length, 1);
  assert.deepEqual([calls[0].method, calls[0].url], ['POST', '/api/coord/hub/promote']);
  assert.deepEqual(JSON.parse(calls[0].body), { target: 'hub-2', expected_epoch: 7, actor: 'console', reason: 'drill', confirm: true });
  assert.deepEqual(msg, { ok: false, text: 'The lease moved since you loaded this page (now epoch 8 held by hub-2). Reload and check before promoting.' });
});

test('runPromote on success names before and after', async () => {
  captureFetch(200, { ok: true, before: { holder: 'hub-1', epoch: 7 }, after: { holder: 'hub-2', epoch: 8 } });
  assert.deepEqual(await runPromote({ target: 'hub-2', typed: 'hub-2', reason: 'drill' }, ['hub-2'], 7),
    { ok: true, text: 'Promoted: hub-1@7 → hub-2@8' });
});

test('runPromote refuses a blocked form without a fetch', async () => {
  const calls = captureFetch(200, { ok: true });
  const msg = await runPromote({ target: 'hub-2', typed: 'hub-2 ', reason: 'drill' }, ['hub-2'], 7);
  assert.equal(calls.length, 0);
  assert.equal(msg.ok, false);
});

test('D2 HubScreen through the real /hub route renders the heading and the loading state', () => {
  const route = ROUTES.find(([p]) => p === '/hub');
  assert.equal(route[1], HubScreen);
  const out = render(h(route[1]));
  // TEST-CHANGE (BH-4993, wave 4 of BH-4947): the page's h1 is now the line
  // headline, a sentence about the hub's state; HUB is its chip. Still exact.
  assert.match(out, /<span class="line-chip"><span class="line-chip__dot"><\/span>HUB<\/span>/);
  assert.match(out, /<h1 class="line-headline">Reading the hub\.<br\/>/);
  assert.match(out, /RELOAD/);
  assert.match(out, /class="skel"/);
  assert.doesNotMatch(out, /not built yet/);
});
