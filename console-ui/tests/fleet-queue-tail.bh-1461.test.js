import test from 'node:test';
import assert from 'node:assert/strict';
import { render } from 'preact-render-to-string';
import { h } from 'preact';
import { ProjectsTable } from '../src/screens/Fleet.js';

// BH-1461. `queue_depth` used to count held rows and terminal `*.failed.json`
// parks alongside the rows genuinely waiting for a machine, so a pool holding
// three tickets read as a busy queue and the hold was invisible. The hub now
// pushes `held` and `failed` as their own fields — and a number the hub sends
// that the page drops is the same bug with a different shape, so the QUEUE cell
// has to SAY them. The helper being right is not the table rendering: every
// case below renders the REAL ProjectsTable and reads the HTML back.
//
// No clock is read anywhere in this file: every number arrives as data, exactly
// as the fleet snapshot delivers it.

const row = (fleet) => ({
  project: 'project-5', last_run_age_min: 3, last_summary: 'ok', last_rc: 0,
  paused: false, automerge: true, fleet
});

// The rendered cell keeps its markup between the numbers, so the assertions
// read the text with the tags stripped — what an operator's eye gets.
const text = (fleet) =>
  render(h(ProjectsTable, { rows: [row(fleet)], recentRuns: {} }))
    .replace(/<[^>]*>/g, '')
    .replace(/&middot;|&#183;/g, '·');

test('held and failed ride out as their own tail beside the queue number', () => {
  const t = text({ queue_depth: 0, held: 2, failed: 1 });
  assert.match(t, /· 2 held · 1 failed/,
    'the hub pushed 2 held and 1 failed: dropping them is the bug this fixed');
});

test('a queue with nothing waiting still shows the parked work', () => {
  // queue_depth 0 with held rows is the incident shape itself: the page read
  // "nothing queued" while three tickets sat skipped on every tick.
  const t = text({ queue_depth: 0, held: 3, failed: 0 });
  assert.match(t, /3 held/);
  assert.doesNotMatch(t, /failed/, 'a zero must not render as "0 failed" noise');
});

test('a plain queue renders no tail at all', () => {
  const t = text({ queue_depth: 3 });
  assert.match(t, /3/, 'the queue number itself is still there');
  assert.doesNotMatch(t, /held/, 'no held field pushed means nothing to say');
  assert.doesNotMatch(t, /failed/);
  assert.doesNotMatch(t, /·\s*$/, 'and no orphan separator');
});

test('a queue AND parked work render together, not one instead of the other', () => {
  const t = text({ queue_depth: 5, held: 2, failed: 0 });
  assert.match(t, /5/);
  assert.match(t, /2 held/, 'a busy queue does not excuse hiding the held rows');
});

test('an old hub that pushes neither field still renders the row', () => {
  // The console ships ahead of the hub often enough that a missing field has to
  // be silence, never a false zero.
  for (const f of [{}, { queue_depth: 0 }, undefined]) {
    const t = text(f);
    assert.match(t, /project-5/, `${JSON.stringify(f)}: the row still renders`);
    assert.doesNotMatch(t, /held/, `${JSON.stringify(f)}: silence is not "0 held"`);
  }
});
