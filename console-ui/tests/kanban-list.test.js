import { test } from 'node:test';
import assert from 'node:assert/strict';
import {
  PIPELINE_COLUMNS, filterPipeline, pipelineRows, externalRow, shippedCaveat,
  rowAgeMin, rowLabel, rowDetail
} from '../src/lib/kanban.js';
import { sortRows, nextDirection, ariaSort } from '../src/lib/sort.js';
import { ticketClaim } from '../src/lib/lanes.js';

// The LIST view is the board's rows in one table. These are the pure halves:
// the flattening, the ordering the shared sortable table applies to it, and the
// SHIPPED caveat — the whole point of which is that a column showing 50 of 625
// merged builds must say so on screen.

const payload = () => ({
  columns: {
    queued: [{ project: 'project-3', queue_depth: 3, oldest_queued_min: 42, pending_commands: 1 }],
    building: [{ id: 11, project: 'project-1', ticket: 'TK-1', stage: 'executing', tier: 2, verdict: null, pr_url: null, age_min: 4 }],
    merge_queue: [
      { id: 12, project: 'project-1', ticket: 'TK-2', stage: 'pr_created', tier: 1, verdict: 'APPROVE', pr_url: 'https://github.com/example-org/project-1/pull/593', age_min: 9 },
      { command_id: 3, ckey: 'project-1:TK-2:merge_pr', project: 'project-1', status: 'pending', age_min: 1 }
    ],
    review: [{ id: 13, project: 'project-4', ticket: 'TK-7', stage: 'pr_created', tier: 2, verdict: 'REQUEST_CHANGES', pr_url: 'https://github.com/example-org/project-4/pull/40', age_min: 120 }],
    merged_deployed: [{ id: 14, project: 'project-3', ticket: 'TK-9', stage: 'pr_merged', tier: 1, verdict: 'APPROVE', pr_url: 'https://github.com/example-org/project-3/pull/8', age_min: 1440 }],
    dead_failed: [{ command_id: 4, ckey: 'project-4:TK-1:merge_pr', project: 'project-4', stage: 'dead_letter', age_min: 5000 }]
  },
  counts: { queued: 4, building: 1, merge_queue: 2, review: 1, merged_deployed: 1, dead_failed: 1, merged_deployed_total: 625 },
  building_stale: 0,
  shipped_window_days: 14
});

// ------------------------------------------------------------- flattening

test('every card in every column becomes exactly one row', () => {
  const view = filterPipeline(payload(), null);
  const rows = pipelineRows(view);
  const cards = PIPELINE_COLUMNS.reduce((n, c) => n + view.columns[c.key].length, 0);
  assert.equal(rows.length, cards, 'no card is dropped and none is duplicated');
  assert.equal(rows.length, 7);
});

test('rows come out in pipeline flow order, not alphabetical order', () => {
  // Sorting a table by a column NAME would put BUILDING before QUEUED and DEAD
  // before MERGE Q, which is not the order the board draws or the pipeline runs.
  const rows = pipelineRows(filterPipeline(payload(), null));
  assert.deepEqual([...new Set(rows.map((r) => r.column))], [
    'queued', 'building', 'merge_queue', 'review', 'merged_deployed', 'dead_failed'
  ]);
  assert.deepEqual([...new Set(rows.map((r) => r.columnOrder))], [0, 1, 2, 3, 4, 5]);
});

test('a row carries the same route its card carried — the list is not a dead end', () => {
  const rows = pipelineRows(filterPipeline(payload(), null));
  const byLabel = Object.fromEntries(rows.map((r) => [r.label, r]));
  assert.equal(byLabel['TK-2'].route, '/pr/project-1/593', 'a build with a PR opens the PR drill-down');
  assert.equal(byLabel['TK-1'].route, '/builds/11', 'a build without a PR opens its build detail');
  assert.equal(byLabel['project-3'].route, '/p/project-3', 'a queue rollup opens its project');
  assert.equal(byLabel['command #3'].route, '/p/project-1', 'a command opens its project');
});

test('every row has a name, a stable key and a readable detail', () => {
  const rows = pipelineRows(filterPipeline(payload(), null));
  assert.ok(rows.every((r) => r.label && r.label !== 'unknown'), 'no blank name in a sortable table');
  assert.equal(new Set(rows.map((r) => r.key)).size, rows.length, 'keys are unique');
  assert.equal(rowLabel({ id: 5, project: 'p' }), 'build #5', 'a ticketless build is named by its id');
  assert.equal(rowDetail({ project: 'project-3', queue_depth: 1 }), '1 ticket waiting');
  assert.equal(rowDetail({ project: 'project-3', queue_depth: 3 }), '3 tickets waiting');
  // The queued CARD shows its pending commands; the row must not be quieter.
  assert.equal(
    rowDetail({ project: 'project-3', queue_depth: 3, pending_commands: 1 }),
    '3 tickets waiting · 1 pending command');
  assert.equal(
    rowDetail({ project: 'project-3', queue_depth: 3, pending_commands: 2 }),
    '3 tickets waiting · 2 pending commands');
  assert.equal(rowDetail({ id: 1, project: 'p' }), '—', 'a build with no stage says so rather than rendering blank');
});

test('the PR number is parsed once, and a malformed url yields null rather than #NaN', () => {
  const rows = pipelineRows(filterPipeline(payload(), null));
  const pb2 = rows.find((r) => r.label === 'TK-2');
  assert.equal(pb2.prNumber, 593);
  const bad = pipelineRows({ columns: { building: [{ id: 1, project: 'p', ticket: 'T', pr_url: 'https://example.com/nope' }] } });
  assert.equal(bad[0].prNumber, null);
});

test('an age we never received is null, so it sinks in a sort instead of reading as 0', () => {
  assert.equal(rowAgeMin({ age_min: 12 }), 12);
  assert.equal(rowAgeMin({ oldest_queued_min: 42 }), 42, 'a queue rollup ages by its oldest ticket');
  assert.equal(rowAgeMin({}), null);
  assert.equal(rowAgeMin(null), null);
  assert.equal(rowAgeMin({ updated_at: 'nonsense' }), null);
});

test('a missing or malformed payload yields no rows rather than throwing', () => {
  assert.deepEqual(pipelineRows(null), []);
  assert.deepEqual(pipelineRows({}), []);
  assert.deepEqual(pipelineRows({ columns: { building: 'not an array' } }), []);
});

// ------------------------------------------------------------- sorting

test('the shared comparator orders the rows, missing values last in both directions', () => {
  const rows = pipelineRows(filterPipeline(payload(), null));
  const byAge = sortRows(rows, (r) => r.ageMin, 'desc').map((r) => r.ageMin);
  assert.deepEqual(byAge, [5000, 1440, 120, 42, 9, 4, 1]);
  const asc = sortRows(rows, (r) => r.ageMin, 'asc').map((r) => r.ageMin);
  assert.deepEqual(asc, [1, 4, 9, 42, 120, 1440, 5000]);

  // A row with no tier must not sort as tier 0 at the top — unknown is not
  // smallest, it is unknown, and it sinks whichever way the arrow points.
  const byTier = sortRows(rows, (r) => r.tier, 'asc');
  assert.equal(byTier[byTier.length - 1].tier, null);
  const byTierDesc = sortRows(rows, (r) => r.tier, 'desc');
  assert.equal(byTierDesc[byTierDesc.length - 1].tier, null);
});

test('sorting by column keeps flow order, and the header cycles asc then desc', () => {
  const rows = pipelineRows(filterPipeline(payload(), null));
  assert.deepEqual(
    [...new Set(sortRows(rows, (r) => r.columnOrder, 'asc').map((r) => r.columnLabel))],
    ['QUEUED', 'BUILDING', 'MERGE Q', 'REVIEW', 'SHIPPED', 'DEAD']
  );
  assert.equal(nextDirection('ageMin', 'columnOrder', 'asc'), 'asc', 'a new column starts ascending');
  assert.equal(nextDirection('ageMin', 'ageMin', 'asc'), 'desc', 'clicking the same column flips it');
  assert.equal(ariaSort('ageMin', 'ageMin', 'desc'), 'descending', 'the direction is announced, not just drawn');
  assert.equal(ariaSort('tier', 'ageMin', 'desc'), 'none');
});

// ------------------------------------------------------------- SHIPPED caveat

test('the SHIPPED caveat states the real denominator', () => {
  const view = filterPipeline(payload(), null);
  const caveat = shippedCaveat(view);
  assert.equal(caveat.shown, 1);
  assert.equal(caveat.total, 625);
  assert.equal(caveat.label, 'showing 1 of 625');
  assert.equal(caveat.fleetWide, false);
  assert.equal(caveat.windowDays, 14);
  assert.match(caveat.title, /14 days/, 'the tooltip says what the window is');
});

test('the caveat is null when the API sends no total — an invented number is worse than none', () => {
  // An older console worker sends no counts.merged_deployed_total. The column
  // then renders exactly what it renders today, with no caveat at all.
  const old = payload();
  delete old.counts.merged_deployed_total;
  delete old.shipped_window_days;
  assert.equal(shippedCaveat(filterPipeline(old, null)), null);
  assert.equal(shippedCaveat(null), null);
  assert.equal(shippedCaveat(filterPipeline({ columns: {}, counts: {} }, null)), null);
});

test('a zero total is a real answer and still renders', () => {
  const empty = payload();
  empty.columns.merged_deployed = [];
  empty.counts.merged_deployed_total = 0;
  const caveat = shippedCaveat(filterPipeline(empty, null));
  assert.equal(caveat.total, 0);
  assert.equal(caveat.label, 'showing 0 of 0');
});

test('under a project filter the total is flagged fleet-wide, never phrased as this project\'s', () => {
  // The screen fetches the pipeline unfiltered and filters client-side, so the
  // worker's total is a FLEET number. "showing 1 of 625" beside one project
  // would claim that project has 624 more merges hidden.
  const view = filterPipeline(payload(), 'project-3');
  const caveat = shippedCaveat(view);
  assert.equal(caveat.fleetWide, true);
  assert.equal(caveat.label, '1 shown · 625 merged (fleet)');
  assert.match(caveat.title, /cannot be attributed to one project/);
  assert.ok(!caveat.label.includes('of 625'), 'no per-project numerator over a fleet denominator');
});

// ------------------------------------------------------- external lanes

const mergedClaim = () => ({
  project: 'project-4', ticket: 'TK-9', title: 'a thing', status: 'in_progress',
  ...ticketClaim({ claim: {
    actor: 'someRandomDev', fleet: false, kind: 'pr', state: 'merged', pr: 1421,
    pr_url: 'https://github.com/example-org/project-4/pull/1421', at: '2026-08-16T09:00:00Z'
  } })
});

test('a merged external claim reads as merged, not as a stale branch', () => {
  // The bug: eight project-4 tickets showed "stale branch — no PR, tip is 8d old"
  // while every one of those PRs had landed days earlier.
  const row = externalRow(mergedClaim());
  assert.equal(row.merged, true);
  assert.equal(row.stale, false);
  assert.equal(row.detail, 'PR #1421 merged · ticket not closed');
  assert.equal(row.prNumber, 1421);
  assert.equal(row.route, '/p/project-4');
});

test('a genuinely abandoned branch still reads as one', () => {
  const claim = {
    project: 'project-4', ticket: 'TK-3', title: null,
    ...ticketClaim({ claim: { actor: 'dev', fleet: false, kind: 'branch', ref: 'wip/TK-3', at: '2020-01-01T00:00:00Z' } })
  };
  const row = externalRow(claim);
  assert.equal(row.merged, false);
  assert.equal(row.stale, true);
  assert.equal(row.detail, 'stale branch — no PR opened');
});

test('external claims join the list beside BUILDING, so the two views agree on what exists', () => {
  const view = filterPipeline(payload(), null);
  const rows = pipelineRows(view, [mergedClaim()]);
  const ext = rows.find((r) => r.external);
  assert.ok(ext, 'the external lane is in the table');
  assert.equal(ext.column, 'building');
  assert.equal(ext.label, 'TK-9');
  assert.equal(ext.externalLabel, 'someRandomDev', 'the cell names who owns the lane');
  // The board rows are untouched by it.
  assert.equal(rows.filter((r) => !r.external).length, 7);
  assert.equal(pipelineRows(view, null).length, 7, 'no externals is not an error');
});
