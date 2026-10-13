import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { render } from 'preact-render-to-string';
import { h } from 'preact';
import { shapeAlertRows, alertRowActions, shapeAlertActions, actionOutcomeText } from '../src/lib/alertrows.js';
import { FleetRowsSection, NoteDialogBody } from '../src/screens/Alerts.js';
import { Modal } from '../src/ui/Modal.js';

// BH-2324 (UI half, #2370): row actions and the per-row action history on the
// FLEET ROWS section. Response and error fixtures are the shapes the worker
// answers per the ticket ("Worker response shapes") and the shape api.js
// throws them in: Error(reason) with .status and the parsed .body (D35).

// determinism: ok ages are measured from this literal epoch, never the clock.
const NOW = Date.parse('2026-09-25T12:00:00Z');

// What api.js `request` throws for a non-2xx answer.
function wireError(status, body) {
  const err = new Error(body && body.error ? body.error : `http_${status}`);
  err.status = status;
  err.body = body;
  return err;
}

const SUCCESS = /^(acked|snoozed|resolved|note added)\b/;

test('alertRowActions offers ack only where the worker allows the edge', () => {
  assert.deepEqual(alertRowActions({ state: 'new' }), ['ack', 'snooze', 'resolve', 'note']);
  assert.deepEqual(alertRowActions({ state: 'quarantined' }), ['ack', 'snooze', 'resolve', 'note']);
  assert.deepEqual(alertRowActions({ state: 'triaged' }), ['snooze', 'resolve', 'note']);
  assert.deepEqual(alertRowActions({ state: 'parked' }), ['snooze', 'resolve', 'note']);
  assert.deepEqual(alertRowActions({ state: 'resolved' }), ['note']);
  for (const state of [undefined, 'weird']) {
    const acts = alertRowActions({ state });
    assert.ok(!acts.includes('ack'), `no ack on ${state}`);
    assert.deepEqual(acts, ['snooze', 'resolve', 'note']);
  }
});

test('shapeAlertActions reports truncated honestly and shortens long notes', () => {
  const long = 'x'.repeat(120);
  const s = shapeAlertActions({
    actions: [{ id: 1, alert_id: 'a1', action: 'note', actor: 'console', note: long, outcome: 'ok', at: '2026-09-25T11:00:00Z' }],
    truncated: true, as_of: '2026-09-25T12:00:00Z'
  });
  assert.equal(s.truncated, true);
  assert.equal(s.asOf, '2026-09-25T12:00:00Z');
  assert.equal(s.rows.length, 1);
  assert.ok(s.rows[0].noteShort.endsWith('…'));
  assert.equal(s.rows[0].noteShort.length, 81);
  assert.equal(s.rows[0].note, long, 'the full note stays on the row');
  assert.equal(shapeAlertActions({ actions: [] }).truncated, false, 'a missing field is not truncated');
  assert.deepEqual(shapeAlertActions(null), { rows: [], truncated: false, asOf: null });
  assert.equal(shapeAlertActions({ actions: [{ id: 2, note: 'short' }] }).rows[0].noteShort, 'short');
  assert.equal(shapeAlertActions({ actions: [{ id: 3, note: null }] }).rows[0].noteShort, '');
});

test('actionOutcomeText: success needs a 200 whose action row says ok', () => {
  assert.deepEqual(
    actionOutcomeText('ack', 'a1', { response: { alert: {}, action: { outcome: 'ok' }, as_of: 'x' } }),
    { ok: true, text: 'acked a1' });
  const snooze = actionOutcomeText('snooze', 'a1', {
    response: { alert: {}, action: { outcome: 'ok', until: '2026-09-25T13:30:00Z' } }
  });
  assert.equal(snooze.ok, true);
  assert.equal(snooze.text, 'snoozed a1 until 13:30Z');
  const noUntil = actionOutcomeText('snooze', 'a1', { response: { action: { outcome: 'ok' } } });
  assert.equal(noUntil.ok, true);
  assert.match(noUntil.text, /no end time/);
  assert.deepEqual(actionOutcomeText('resolve', 'a1', { response: { action: { outcome: 'ok' } } }),
    { ok: true, text: 'resolved a1' });
  assert.deepEqual(actionOutcomeText('note', 'a1', { response: { action: { outcome: 'ok' } } }),
    { ok: true, text: 'note added to a1' });
});

test('actionOutcomeText: every failure is failure copy, never success wording', () => {
  const cases = [
    ['snooze', { error: wireError(409, { error: 'claimed', claimed_by: 'medic@hub' }) }, 'not snoozed: medic@hub holds it'],
    ['resolve', { error: wireError(409, { error: 'refused:already-resolved' }) }, 'not resolved: a1 was already resolved'],
    ['snooze', { error: wireError(409, { error: 'x', outcome: 'refused:resolved' }) }, 'not snoozed: a1 is already resolved'],
    ['ack', { error: wireError(409, { error: 'disallowed edge', from: 'triaged' }) },
      'not acked: a1 is triaged, only new or quarantined rows can be acked'],
    ['resolve', { error: wireError(409, { error: 'contended' }) },
      'not resolved: a1 changed while we were writing; reload and try again'],
    ['ack', { error: wireError(501, { error: 'not implemented' }) },
      'could not ack a1: the worker has not turned row actions on yet (http_501)'],
    ['resolve', { error: wireError(405, null) },
      'could not resolve a1: the console proxy does not allow this write yet (http_405)'],
    ['note', { error: wireError(404, { error: 'no such alert' }) }, 'could not add a note to a1: no such alert'],
    ['snooze', { error: new Error('network unreachable') }, 'could not snooze a1: network unreachable'],
    ['ack', { response: { alert: {}, action: { outcome: 'refused:x' } } }, null],
    ['ack', { response: { alert: {}, as_of: 'x' } }, null],
    ['resolve', { response: null }, null]
  ];
  for (const [action, arg, want] of cases) {
    const got = actionOutcomeText(action, 'a1', arg);
    assert.equal(got.ok, false, `${action} ${JSON.stringify(arg)} is a failure`);
    if (want) assert.equal(got.text, want);
    assert.ok(!SUCCESS.test(got.text), `failure copy "${got.text}" does not read as success`);
    assert.match(got.text, /^(not |could not )/);
  }
});

const rows = shapeAlertRows({
  alerts: [
    { id: 'n1', family: 'f', box: 'hub', project: 'p', line: 'new one', first_seen: '2026-09-25T11:00:00Z', state: 'new', count: 1 },
    { id: 't1', family: 'f', box: 'hub', project: 'p', line: 'triaged one', first_seen: '2026-09-25T10:00:00Z', state: 'triaged', count: 2 },
    { id: 'r1', family: 'f', box: 'hub', project: 'p', line: 'resolved one', first_seen: '2026-09-25T09:00:00Z', state: 'resolved', count: 3 }
  ],
  truncated: false
}, NOW);

const noHistory = { loading: false, error: null, data: null, reload: () => {}, shaped: null };
const draw = (props, actions) => render(h(FleetRowsSection, {
  loading: false, error: null, onRetry: () => {}, shaped: rows, filters: {}, ...props,
  ...(actions ? { actions: { onAction: () => {}, pending: {}, openId: null, onToggleHistory: () => {}, history: noHistory, ...actions } } : {})
}));

// The <tr> for one alert id, from the rendered table body.
function rowHtml(out, id) {
  const body = out.slice(out.indexOf('<tbody'));
  const at = body.indexOf(`>${id}</button>`);
  assert.notEqual(at, -1, `row ${id} rendered`);
  return body.slice(body.lastIndexOf('<tr', at), body.indexOf('</tr>', at));
}

test('with actions, FLEET ROWS gets an unsortable ACTIONS column and per-state buttons', () => {
  const out = draw({}, { pending: { t1: true } });
  const head = out.slice(out.indexOf('<thead'), out.indexOf('</thead>'));
  assert.ok(head.includes('ACTIONS'), 'ACTIONS header');
  assert.ok(!head.includes('sort by actions'), 'ACTIONS is not sortable');
  assert.equal((out.match(/>ACK</g) || []).length, 1, 'ACK only on the new row');

  const n1 = rowHtml(out, 'n1');
  for (const l of ['ACK', 'SNOOZE', 'RESOLVE', 'NOTE']) assert.ok(n1.includes(`>${l}<`), `n1 has ${l}`);
  const r1 = rowHtml(out, 'r1');
  assert.ok(r1.includes('>NOTE<'));
  for (const l of ['ACK', 'SNOOZE', 'RESOLVE']) assert.ok(!r1.includes(`>${l}<`), `resolved row has no ${l}`);

  const t1 = rowHtml(out, 't1');
  const t1Buttons = t1.match(/<button type="button" class="btn btn--sm"[^>]*>/g) || [];
  assert.equal(t1Buttons.length, 3, 'snooze, resolve, note on triaged');
  assert.ok(t1Buttons.every((b) => b.includes('disabled')), 'the pending row is disabled');
  assert.ok(!n1.match(/<button type="button" class="btn btn--sm"[^>]*disabled/), 'other rows stay live');

  assert.match(out, /<button type="button" class="cell-name"[^>]*aria-expanded="false"[^>]*>n1<\/button>/);
  assert.ok(out.includes('flex-wrap:wrap'), 'the buttons wrap at 375px');
  assert.ok(!out.includes('id="alert-history"'), 'no history until an id is opened');
});

test('without actions, the section is the read-only table it always was', () => {
  const out = draw({});
  assert.ok(!out.includes('ACTIONS'));
  assert.ok(!out.includes('aria-expanded'));
  assert.ok(!out.includes('>NOTE<'));
  assert.match(out, /<span class="cell-name" title="new one">n1<\/span>/);
});

const history = (over) => ({ ...noHistory, ...over });

test('an open id shows its action log as a sortable table, newest first', () => {
  const shaped = shapeAlertActions({
    actions: [
      { id: 1, alert_id: 'n1', action: 'ack', actor: 'console', note: null, outcome: 'ok', at: '2026-09-25T10:00:00Z' },
      { id: 2, alert_id: 'n1', action: 'note', actor: 'console', note: 'y'.repeat(100), outcome: 'ok', at: '2026-09-25T11:00:00Z' }
    ],
    truncated: false
  });
  const out = draw({}, { openId: 'n1', history: history({ data: {}, shaped }) });
  assert.match(out, /aria-expanded="true"[^>]*>n1<\/button>/);
  const panel = out.slice(out.indexOf('id="alert-history"'));
  assert.notEqual(out.indexOf('id="alert-history"'), -1, 'the history panel rendered');
  const head = panel.slice(panel.indexOf('<thead'), panel.indexOf('</thead>'));
  for (const l of ['at', 'action', 'actor', 'outcome', 'note']) assert.ok(head.includes(`sort by ${l}`), `${l} sorts`);
  assert.match(head, /aria-sort="descending"[^>]*>\s*<button[^>]*title="sort by at"/);
  const body = panel.slice(panel.indexOf('<tbody'));
  assert.ok(body.indexOf('>note<') < body.indexOf('>ack<'), 'the newest action is on top');
  assert.ok(body.includes('y'.repeat(80) + '…'), 'the long note is cut');
  assert.ok(body.includes(`title="${'y'.repeat(100)}"`), 'with the full note on hover');
  assert.ok(panel.includes('CLOSE'));
});

test('history empty, failed and truncated read differently', () => {
  const empty = draw({}, { openId: 'n1', history: history({ data: {}, shaped: shapeAlertActions({ actions: [] }) }) });
  assert.ok(empty.includes('no actions recorded'));

  const failed = draw({}, { openId: 'n1', history: history({ error: new Error('http_501') }) });
  const panel = failed.slice(failed.indexOf('id="alert-history"'));
  assert.notEqual(failed.indexOf('id="alert-history"'), -1);
  assert.ok(panel.includes('could not load'));
  assert.ok(panel.includes('http_501'));
  assert.ok(panel.includes('RETRY'));
  assert.ok(!panel.includes('no actions recorded'), 'a failed read is not an empty log');

  const loading = draw({}, { openId: 'n1', history: history({ loading: true }) });
  assert.ok(!loading.includes('no actions recorded'), 'still loading is not empty either');
  // The render right after an id opens: useApi still holds the null it
  // answered for "nothing open" and has not flipped to loading yet.
  const justOpened = draw({}, { openId: 'n1', history: history({ loading: false, data: null }) });
  assert.ok(!justOpened.includes('no actions recorded'), 'no data yet is not an empty log');

  const truncated = draw({}, {
    openId: 'n1',
    history: history({ data: {}, shaped: shapeAlertActions({ actions: [{ id: 1, action: 'ack', at: 'x' }], truncated: true }) })
  });
  assert.ok(truncated.slice(truncated.indexOf('id="alert-history"')).includes('showing 1 of more'));
});

test('the NOTE modal holds confirm until there is text', () => {
  const out = render(h(Modal, {
    title: 'NOTE', confirmBlocked: true, onConfirm() {}, onCancel() {},
    body: ({ setBlocked }) => h(NoteDialogBody, { setBlocked, onText() {} })
  }));
  assert.ok(out.includes('<textarea'));
  assert.ok(out.includes('maxlength="1000"'));
  assert.match(out, /<button[^>]*disabled[^>]*>CONFIRM<\/button>/);
});

test('NoteDialogBody unblocks confirm only on non-blank text', () => {
  let blocked = null;
  let text = null;
  const vnode = NoteDialogBody({ setBlocked: (b) => { blocked = b; }, onText: (t) => { text = t; } });
  // The rendered textarea's input handler, called with what a browser hands it.
  const ta = vnode.type === 'textarea' ? vnode : null;
  assert.ok(ta, 'the body is the textarea itself');
  ta.props.onInput({ target: { value: '   ' } });
  assert.equal(blocked, true);
  ta.props.onInput({ target: { value: ' hi ' } });
  assert.equal(blocked, false);
  assert.equal(text, ' hi ');
});

test('AlertsScreen passes actions to FleetRowsSection and uses no native dialog', () => {
  const src = readFileSync(new URL('../src/screens/Alerts.js', import.meta.url), 'utf8');
  const start = src.indexOf('export function AlertsScreen');
  assert.notEqual(start, -1, 'AlertsScreen exists');
  const screen = src.slice(start);
  const mount = screen.indexOf('<${FleetRowsSection}');
  assert.notEqual(mount, -1, 'AlertsScreen mounts FleetRowsSection');
  const tagEnd = screen.indexOf('/>', mount);
  assert.match(screen.slice(mount, tagEnd), /\sactions=\$\{\{/, 'and hands it actions');
  assert.ok(!/window\.confirm|\balert\(|\bprompt\(|\bconfirm\(\s*['"`]/.test(src.replace(/await confirm\(\{/g, '')),
    'no native dialogs');
  assert.ok(!src.includes('Read-only on purpose'), 'the stale comment is gone');
  assert.match(src, /import \{[^}]*useConfirm[^}]*\} from '\.\.\/ui\/Modal\.js'/);
  assert.ok(screen.includes('cannot undo'), 'the confirm says it cannot be undone');
  assert.ok(screen.includes("api.action({ type: 'resolve_alert'"), 'OPEN ALERTS keeps its own resolve');
});
