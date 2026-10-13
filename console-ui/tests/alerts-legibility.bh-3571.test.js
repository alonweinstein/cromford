import test from 'node:test';
import assert from 'node:assert/strict';
import { render } from 'preact-render-to-string';
import { h } from 'preact';
import { SortableTable } from '../src/ui/SortableTable.js';
import { shapeAlertRows, shapeAlertActions } from '../src/lib/alertrows.js';
// A namespace import, so a missing export fails its own test rather than the whole file.
import * as Alerts from '../src/screens/Alerts.js';
import { assertNoRawHeaders, assertUsdLabelled } from './legibility.bh-3558.js';

// BH-3571 (#3558 slice 4): /alerts says what its columns mean, dates every
// stamp, and leads each row with the alert's line instead of its id.

// determinism: ok every stamp in this file is measured from this literal epoch.
const NOW = Date.parse('2026-09-29T14:05:00Z');

// The wire rows from alerts-rows.bh-1072.test.js, re-dated so rowA was
// notified 2 days before NOW and rowC 55 minutes before it.
const rowA = {
  id: 'lane-medic-dead', family: 'a1b2c3d4e5f6', box: 'hub', project: 'project-3',
  line: 'medic lane has not ticked in 40m', severity: 'warn',
  first_seen: '2026-09-27T10:30:00Z', last_seen: '2026-09-29T13:55:00Z',
  count: 3, state: 'new', claimed_by: 'medic@hub', claimed_at: '2026-09-27T11:00:00Z',
  notified_at: '2026-09-27T14:05:00Z'
};
const rowB = {
  id: 'disk-85pct', family: '', box: 'orgo-3', project: '', line: 'disk at 85%', severity: 'info',
  first_seen: '2026-09-29T09:00:00Z', last_seen: '2026-09-29T11:00:00Z',
  count: 12, state: 'parked', claimed_by: null, claimed_at: null, notified_at: null
};
const rowC = { ...rowB, id: 'ping-late', line: 'orgo-3 ping late', notified_at: '2026-09-29T13:10:00Z' };
const rowD = { ...rowB, id: 'no-line-row', line: '', notified_at: 'not a date' };

const shaped = shapeAlertRows({ alerts: [rowA, rowB, rowC, rowD], truncated: false }, NOW);
const noHistory = { loading: false, error: null, data: null, reload: () => {}, shaped: null };
const draw = (props, actions) => render(h(Alerts.FleetRowsSection, {
  loading: false, error: null, onRetry: () => {}, shaped, filters: {}, nowMs: NOW, ...props,
  ...(actions ? { actions: { onAction: () => {}, pending: {}, openId: null, onToggleHistory: () => {}, history: noHistory, ...actions } } : {})
}));

// The <td>s of the first body row whose markup holds `marker`.
function cellsOf(out, marker) {
  const body = out.slice(out.indexOf('<tbody'));
  const at = body.indexOf(marker);
  assert.notEqual(at, -1, `row with ${marker} rendered`);
  const tr = body.slice(body.lastIndexOf('<tr', at), body.indexOf('</tr>', at));
  return tr.match(/<td\b[^>]*>[\s\S]*?<\/td>/g) || [];
}
const text = (m) => m.replace(/<[^>]+>/g, ' ').replace(/\s+/g, ' ').trim();
const headOf = (out) => out.slice(out.indexOf('<thead'), out.indexOf('</thead>'));
const SECONDARY = '<span style="display:block;font-size:var(--fs-2xs);color:var(--faint)">';

// The legend's visible text, attributes stripped first so a term that lives
// only in a title="..." can never satisfy it.
function legendOf(out) {
  const m = out.match(/<dl class="legend">[\s\S]*?<\/dl>/);
  return m ? m[0] : null;
}

test('A1: NOTIFIED is an age under a day, a dated stamp past it, and never when null', () => {
  for (const withActions of [false, true]) {
    const out = draw({}, withActions ? {} : null);
    const notified = (marker) => {
      const cells = cellsOf(out, marker);
      return text(cells[withActions ? cells.length - 2 : cells.length - 1]);
    };
    assert.equal(notified('lane-medic-dead'), 'Sep 27 14:05Z', 'two days back reads as a date, not a bare 14:05Z');
    assert.equal(notified('ping-late'), '55m ago');
    assert.equal(notified('disk-85pct'), 'never');
    assert.equal(notified('no-line-row'), 'unreadable');
  }
  assert.match(draw({}), /title="2026-09-27T14:05:00Z"/, 'the ISO stamp stays on hover');
});

test('A2: a legend says what FAMILY, COUNT, CLAIMED BY, STATE and NOTIFIED mean, only with the table', () => {
  for (const withActions of [false, true]) {
    const out = draw({}, withActions ? {} : null);
    const dl = legendOf(out);
    assert.ok(dl, 'the legend rendered');
    assert.ok(out.indexOf('<table') < out.indexOf('<dl class="legend">'), 'under the table it explains');
    const terms = (dl.match(/<dt>[\s\S]*?<\/dt>/g) || []).map(text);
    assert.deepEqual(terms, ['FAMILY', 'COUNT', 'CLAIMED BY', 'STATE', 'NOTIFIED']);
    const visible = text(dl.replace(/<([a-z]+)\b[^>]*>/g, '<$1>'));
    for (const s of ['new', 'quarantined', 'triaged', 'parked', 'resolved']) {
      assert.match(visible, new RegExp(`\\b${s}:`), `STATE names ${s}`);
    }
    assert.ok(!out.includes('RESOLVE') || withActions, 'the read-only copy never says RESOLVE');
    assert.ok(!visible.includes('RESOLVE'), 'nor does the legend');
    assert.ok(!/—/.test(visible), 'no em dashes in the new copy');
  }

  const failed = draw({ error: new Error('http_404'), shaped: null });
  assert.ok(!failed.includes('<table'), 'a failed read draws no table');
  assert.equal(legendOf(failed), null, 'and no legend for a table that is not there');
  const empty = draw({ shaped: { rows: [], truncated: false, asOf: null } });
  assert.equal(legendOf(empty), null, 'nor over the empty state');
  assert.ok(empty.includes('no fleet rows yet'));
});

test('A3: the ID cell leads with the line and carries the id small underneath', () => {
  const ro = draw({});
  assert.ok(headOf(ro).includes('sort by id'), 'the header is still ID and still sorts');
  const idCell = cellsOf(ro, 'lane-medic-dead')[0];
  const line = idCell.indexOf('medic lane has not ticked in 40m</span>');
  const sec = idCell.indexOf(SECONDARY);
  assert.notEqual(line, -1, 'the line is the primary text');
  assert.notEqual(sec, -1, 'the id sits in the small faint span');
  assert.ok(line < sec, 'line first, id under it');
  assert.ok(idCell.slice(sec).includes('>lane-medic-dead</span>'), 'and the id is inside that span');
  assert.ok(!idCell.slice(0, sec).includes('lane-medic-dead<'), 'the id is not primary text as well');

  const act = draw({}, { openId: 'lane-medic-dead' });
  const actCell = cellsOf(act, 'lane-medic-dead')[0];
  const aSec = actCell.indexOf(SECONDARY);
  assert.ok(actCell.indexOf('medic lane has not ticked in 40m</span>') < aSec && aSec !== -1);
  assert.match(actCell.slice(aSec), /<button type="button" class="cell-name"[^>]*aria-expanded="true"[^>]*aria-controls="alert-history"[^>]*>lane-medic-dead<\/button>/,
    'the id is still the history toggle');

  const bare = cellsOf(ro, 'no-line-row')[0];
  assert.ok(!bare.includes('cell-wrap'), 'an empty line leaves no empty clipped span');
  assert.ok(!bare.includes(SECONDARY), 'the id is then the primary text');
  assert.equal(text(bare), 'no-line-row');
});

test('A4: no raw headers and no unlabelled dollars, with and without actions', () => {
  for (const out of [draw({}), draw({}, {}), draw({}, { openId: 'lane-medic-dead' })]) {
    assertNoRawHeaders(out);
    assertUsdLabelled(out);
  }
});

test('HISTORY AT is dated once the action is more than a day old', () => {
  const history = {
    ...noHistory,
    data: {},
    shaped: shapeAlertActions({
      actions: [
        { id: 1, alert_id: 'lane-medic-dead', action: 'ack', actor: 'console', outcome: 'ok', at: '2026-09-25T09:30:00Z' },
        { id: 2, alert_id: 'lane-medic-dead', action: 'note', actor: 'console', outcome: 'ok', at: '2026-09-29T11:05:00Z' }
      ]
    })
  };
  const out = draw({}, { openId: 'lane-medic-dead', history });
  const panel = out.slice(out.indexOf('id="alert-history"'));
  assert.ok(panel.includes('>Sep 25 09:30Z<'), 'the old action says which day');
  assert.ok(panel.includes('>3h ago<'), 'the recent one reads as an age');
});

test('OPEN ALERTS drops the KEY column and shows the key under the line', () => {
  const rows = [{ project: 'project-3', id: 7, akey: 'medic-dead', ts: '2026-09-29T13:00:00Z', line: 'medic lane has not ticked' }];
  const out = render(h(SortableTable, { columns: Alerts.openAlertColumns({}, () => {}), rows, rowKey: (r) => r.id }));
  const head = headOf(out);
  assert.ok(!head.includes('sort by key') && !/>\s*KEY\s*</.test(head), 'no KEY header');
  assert.equal((head.match(/<th\b/g) || []).length, 4, 'project, age, line, action');
  const cells = cellsOf(out, 'medic lane has not ticked');
  const lineCell = cells.find((c) => c.includes('medic lane has not ticked'));
  assert.ok(lineCell.indexOf('medic lane has not ticked</span>') < lineCell.indexOf(`${SECONDARY}medic-dead</span>`),
    'the key is the faint secondary line under the alert text');
  assert.notEqual(lineCell.indexOf(`${SECONDARY}medic-dead</span>`), -1);
  assertNoRawHeaders(out);
  assertUsdLabelled(out);
});

test('RESOLVED RAISED is dated past a day and an age under it', () => {
  const rows = [
    { project: 'project-3', id: 1, ts: '2026-09-26T08:00:00Z', line: 'old', resolved: true },
    { project: 'project-3', id: 2, ts: '2026-09-29T12:05:00Z', line: 'recent', resolved: true }
  ];
  const out = render(h(SortableTable, { columns: Alerts.resolvedColumns(NOW), rows, rowKey: (r) => r.id }));
  assert.equal(text(cellsOf(out, '>old<')[1]), 'Sep 26 08:00Z');
  assert.equal(text(cellsOf(out, '>recent<')[1]), '2h ago');
  assertNoRawHeaders(out);
});
