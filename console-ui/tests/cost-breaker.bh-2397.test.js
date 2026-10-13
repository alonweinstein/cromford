import test from 'node:test';
import assert from 'node:assert/strict';
import { render } from 'preact-render-to-string';
import { h } from 'preact';
import {
  autohaltState, callGuardRows, AUTOHALT_EFFECTIVE_KEY, AUTOHALT_KEY
} from '../src/lib/cost-breaker.js';
import { CostBreakerView } from '../src/screens/CostBreaker.js';

// BH-2397, the COST BREAKER card's follow-ups:
//   item 1 — CAP HIT follows the refusals SINCE the last reset (the worker's
//            refused_since_reset), and the row says "reset <when>";
//   item 3 — AUTOHALT reads the hub-published cost.autohalt.effective row
//            (`on|off <flag-file|settings|env|default>`, written by
//            bin/pipeline-health.sh on the hub) instead of a code copy of the
//            registry default.

const RESET_AT = '2026-09-25T10:00:00Z';
const guardRow = (extra) => ({
  project: 'project-5', stage: 'review', fp: 'hot', paid: 0, refused: 3, last_at: '2026-09-25T11:00:00Z', ...extra
});

// ------------------------------------------------------------ item 1

test('callGuardRows: a reset with nothing refused since clears CAP HIT and carries resetAt', () => {
  const [r] = callGuardRows({ rows: [guardRow({ refused_since_reset: 0, reset_at: RESET_AT })] }).rows;
  assert.equal(r.capHit, false);
  assert.equal(r.refused, 3, 'the REFUSED cell still shows the window total');
  assert.equal(r.refusedSinceReset, 0);
  assert.equal(r.resetAt, RESET_AT);
});

test('callGuardRows: a refusal after the reset lights CAP HIT again', () => {
  const [r] = callGuardRows({ rows: [guardRow({ refused_since_reset: '1', reset_at: RESET_AT })] }).rows;
  assert.equal(r.capHit, true);
  assert.equal(r.refusedSinceReset, 1);
});

test('callGuardRows: a worker without the field (not deployed yet) keeps today\'s rule', () => {
  const [r] = callGuardRows({ rows: [guardRow({})] }).rows;
  assert.equal(r.capHit, true);
  assert.equal(r.refusedSinceReset, null);
  assert.equal(r.resetAt, null);
  const [z] = callGuardRows({ rows: [guardRow({ refused: 0 })] }).rows;
  assert.equal(z.capHit, false);
});

const loaded = (data) => ({ data, error: null, loading: false, reload: () => {} });
const settingsRows = (...rows) => loaded({ settings: rows });
const hubRow = (value) => ({ key: AUTOHALT_EFFECTIVE_KEY, value, updated_at: '2026-09-25T10:50:00Z' });
const knobRow = (value) => ({ key: AUTOHALT_KEY, value });

const view = (props) => render(h(CostBreakerView, {
  settings: settingsRows(),
  flags: loaded({ flags: [] }),
  guard: loaded({ rows: [] }),
  onReset: () => {}, pending: null, msg: null, ...props
}));

test('CostBreakerView: a reset row shows no CAP HIT and does show "reset"', () => {
  const out = view({ guard: loaded({ rows: [guardRow({ refused_since_reset: 0, reset_at: RESET_AT })] }) });
  assert.ok(!out.includes('CAP HIT'), 'CAP HIT after a successful reset');
  assert.match(out, /reset <span title="2026-09-25T10:00:00Z">/);
  const hot = view({ guard: loaded({ rows: [guardRow({ refused_since_reset: 1, reset_at: RESET_AT })] }) });
  assert.ok(hot.includes('CAP HIT'));
});

// ------------------------------------------------------------ item 3

test('autohaltState: the hub row beats the settings row and the code default', () => {
  const s = autohaltState({ settings: [knobRow('1'), hubRow('off flag-file')] });
  assert.equal(s.on, false);
  assert.equal(s.source, 'hub');
  assert.equal(s.why, 'flag-file');
  assert.equal(s.asOf, '2026-09-25T10:50:00Z');
  const on = autohaltState({ settings: [hubRow(' on default ')] });
  assert.equal(on.on, true);
  assert.equal(on.source, 'hub');
  assert.equal(on.why, 'default');
  for (const why of ['settings', 'env']) {
    assert.equal(autohaltState({ settings: [hubRow(`off ${why}`)] }).why, why);
  }
});

test('autohaltState: a malformed hub row is UNKNOWN, never ON', () => {
  for (const bad of ['sideways', 'on', 'on sometimes', 'ON default', '1', '']) {
    const s = autohaltState({ settings: [knobRow('1'), hubRow(bad)] });
    assert.equal(s.on, null, JSON.stringify(bad));
    assert.equal(s.source, 'hub');
    assert.match(s.note, /hub/);
  }
});

test('autohaltState: no hub row keeps the old reading, marked unpublished; a failed read is null', () => {
  const none = autohaltState({ settings: [] });
  assert.equal(none.on, true);
  assert.equal(none.source, 'default');
  assert.notEqual(none.source, 'hub');
  const off = autohaltState({ settings: [knobRow('0')] });
  assert.equal(off.on, false);
  assert.equal(off.source, 'settings');
  assert.equal(autohaltState(null).on, null);
});

test('CostBreakerView: the hub row renders OFF, its source and its age, and drops the "not visible" footnote', () => {
  const out = view({ settings: settingsRows(knobRow('1'), hubRow('off flag-file')) });
  assert.match(out, />OFF</);
  assert.doesNotMatch(out, />ON</);
  assert.ok(out.includes('flag-file'));
  assert.ok(out.includes('as of'));
  assert.ok(out.includes('title="2026-09-25T10:50:00Z"'));
  assert.ok(!out.includes('not visible from here'), 'the hub row does account for the flag file');
});

test('CostBreakerView: a malformed hub row renders UNKNOWN and quotes it', () => {
  const out = view({ settings: settingsRows(knobRow('1'), hubRow('sideways')) });
  assert.match(out, />UNKNOWN</);
  assert.doesNotMatch(out, />ON</);
  assert.ok(out.includes('sideways'));
});

test('CostBreakerView: before the hub publishes, the fallback says it is unconfirmed and keeps the footnote', () => {
  const out = view({ settings: settingsRows() });
  assert.match(out, />ON</);
  assert.ok(out.includes('the hub has not published its effective value'));
  assert.ok(out.includes('not visible from here'));
});
