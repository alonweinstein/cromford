import test from 'node:test';
import assert from 'node:assert/strict';
import { render } from 'preact-render-to-string';
import { h } from 'preact';
import { PipelineList, PipelineBoard } from '../src/screens/Kanban.js';
import { filterPipeline, shippedCaveat } from '../src/lib/kanban.js';
import { ticketClaim } from '../src/lib/lanes.js';

// The helpers being right is not the same as the table rendering. This renders
// the real component and reads the HTML back, so "the LIST view works" is a
// thing that was observed rather than a thing that was assumed.

const payload = {
  columns: {
    queued: [{ project: 'project-3', queue_depth: 3, oldest_queued_min: 42, pending_commands: 1 }],
    building: [{ id: 11, project: 'project-1', ticket: 'TK-1', stage: 'executing', tier: 2, pr_url: null, age_min: 4 }],
    merge_queue: [{ id: 12, project: 'project-1', ticket: 'TK-2', stage: 'pr_created', tier: 1, verdict: 'APPROVE', pr_url: 'https://github.com/example-org/project-1/pull/593', age_min: 9 }],
    review: [],
    merged_deployed: [{ id: 14, project: 'project-3', ticket: 'TK-9', stage: 'pr_merged', tier: 1, verdict: 'APPROVE', pr_url: 'https://github.com/example-org/project-3/pull/8', age_min: 1440 }],
    dead_failed: []
  },
  counts: { queued: 4, building: 1, merge_queue: 1, review: 0, merged_deployed: 1, dead_failed: 0, merged_deployed_total: 625 },
  building_stale: 0,
  shipped_window_days: 14
};

const mergedExternal = {
  project: 'project-4', ticket: 'TK-9', title: 'a thing',
  ...ticketClaim({ claim: {
    actor: 'someRandomDev', fleet: false, kind: 'pr', state: 'merged', pr: 1421,
    pr_url: 'https://github.com/example-org/project-4/pull/1421', at: '2026-08-16T09:00:00Z'
  } })
};

const renderList = (view, external = []) =>
  render(h(PipelineList, {
    board: view, external, shipped: shippedCaveat(view),
    emptyNote: 'Nothing is queued, building, waiting on review or recently merged across the fleet.',
    onToggleAudit: () => {}
  }));

test('the LIST view renders one table with every pipeline row in it', () => {
  const html = renderList(filterPipeline(payload, null));
  assert.match(html, /<table/, 'it is a table, not a wall of cards');
  assert.equal((html.match(/<tr/g) || []).length, 5, 'a header row plus one row per card');
  for (const label of ['QUEUED', 'BUILDING', 'MERGE Q', 'SHIPPED']) {
    assert.ok(html.includes(label), `${label} is named on its rows`);
  }
  for (const ticket of ['TK-1', 'TK-2', 'TK-9', 'project-3']) {
    assert.ok(html.includes(ticket), `${ticket} is on screen`);
  }
});

test('every header sorts and announces its state, and the table scrolls in its own box', () => {
  const html = renderList(filterPipeline(payload, null));
  // The shared SortableTable is what provides this; asserting it here is the
  // check that the LIST view actually uses it rather than hand-rolling a table.
  assert.match(html, /class="tablewrap/, 'the wrapper is the one with overflow-x:auto');
  assert.match(html, /aria-sort=/, 'the sort state is announced, not only drawn');
  assert.equal((html.match(/<button type="button"/g) || []).length, 8, 'all eight headers are clickable');
  assert.match(html, /↑|↓/, 'the active direction has a visible indicator');
});

test('identity cells link — no dead rows', () => {
  const html = renderList(filterPipeline(payload, null));
  assert.ok(html.includes('href="/pr/project-1/593"'), 'a build with a PR opens the PR drill-down');
  assert.ok(html.includes('href="/builds/11"'), 'a build without one opens its build detail');
  assert.ok(html.includes('href="/p/project-3"'), 'a project cell opens its project');
});

test('the SHIPPED caveat is on screen, not just in the payload', () => {
  const html = renderList(filterPipeline(payload, null));
  assert.ok(html.includes('showing 1 of 625'), 'the denominator is rendered');
});

test('an older worker that sends no total renders the list with no caveat at all', () => {
  const old = { ...payload, counts: { ...payload.counts }, shipped_window_days: undefined };
  delete old.counts.merged_deployed_total;
  const html = renderList(filterPipeline(old, null));
  assert.match(html, /<table/, 'the table still renders');
  assert.ok(!html.includes('SHIPPED ·'), 'and it invents no total');
});

test('a merged external lane renders as merged, not as a stale branch', () => {
  const html = renderList(filterPipeline(payload, null), [mergedExternal]);
  assert.ok(html.includes('PR #1421 merged'), 'the merged PR is named');
  assert.ok(html.includes('ticket not closed'), 'and what is actually left to do is said');
  assert.ok(!html.includes('stale branch'), 'a landed PR is never called an abandoned branch');
});

test('an empty pipeline renders its own empty state rather than a headerless table', () => {
  const empty = { columns: {}, counts: {} };
  const html = renderList(filterPipeline(empty, null));
  assert.ok(html.includes('the pipeline is empty'));
  assert.equal((html.match(/the pipeline is empty/g) || []).length, 1, 'said once');
});

test('each view owns exactly one empty state, so neither can double it', () => {
  // The Section-level Empty used to be rendered by the shared parent, on top of
  // the table's own — the list said "the pipeline is empty" twice. It now
  // belongs to the board (showEmpty), and the list keeps the table's.
  const empty = filterPipeline({ columns: {}, counts: {} }, null);
  const boardHtml = render(h(PipelineBoard, {
    board: empty, external: [], shipped: null,
    showEmpty: true, emptyNote: 'nothing at all', onToggleAudit: () => {}
  }));
  assert.equal((boardHtml.match(/the pipeline is empty/g) || []).length, 1, 'the board says it once');
  assert.ok(boardHtml.includes('nothing at all'), 'and it is the parent\'s note, not a second copy');
  assert.equal((renderList(empty).match(/the pipeline is empty/g) || []).length, 1, 'the list says it once');
});

// ------------------------------- the LIST keeps every disclosure the board makes

// A board with rows held back: 5 abandoned builds, 12 archived dead rows, and
// one archived row visible because the audit view is on.
const withHeldBack = () => ({
  ...payload,
  columns: {
    ...payload.columns,
    dead_failed: [
      { command_id: 4, ckey: 'project-4:TK-1:merge_pr', project: 'project-4', stage: 'dead_letter', age_min: 5000, archived: true },
      { command_id: 5, ckey: 'project-4:TK-2:merge_pr', project: 'project-4', stage: 'dead_letter', age_min: 60 }
    ]
  },
  counts: { ...payload.counts, dead_failed: 2 },
  building_stale: 5,
  dead_archived: 12,
  dead_archive_days: 7,
  dead_archive_include: true
});

test('the LIST states the stale-build count the board states in its column head', () => {
  // 5 abandoned builds exist whichever view is open. A list that shows the rows
  // but drops the count beside them is a quieter version of the same omission
  // the SHIPPED cap was.
  const html = renderList(filterPipeline(withHeldBack(), null));
  assert.ok(html.includes('5 stale'), 'the count is on screen');
  assert.match(html, /BUILDING · 5 stale/);
  assert.match(html, /abandoned attempts/, 'and the tooltip says what stale means');
});

test('the LIST carries the DEAD archive note and its audit toggle', () => {
  // Without this the archived rows are only reachable from the CARDS view —
  // "where did row 6460 go" becomes unanswerable in half the console.
  const html = renderList(filterPipeline(withHeldBack(), null));
  assert.ok(html.includes('12 archived shown'), 'the archive note is rendered');
  assert.ok(html.includes('HIDE OLD'), 'and its toggle is reachable from the list');
});

test('an archived row is tagged in the LIST, never styled like a live one', () => {
  const html = renderList(filterPipeline(withHeldBack(), null));
  assert.ok(html.includes('ARCHIVED'), 'the held-back row says so');
  assert.equal((html.match(/ARCHIVED/g) || []).length, 1, 'and only the archived row does');
});

test('the LIST reports external lanes as a count, like the board does', () => {
  const html = renderList(filterPipeline(payload, null), [mergedExternal]);
  assert.match(html, /BUILDING · 1 external/);
});

test('nothing held back means no footnote noise', () => {
  const html = renderList(filterPipeline(payload, null));
  assert.ok(!html.includes('stale'), 'no stale line when nothing is stale');
  assert.ok(!html.includes('archived'), 'no archive note when nothing is archived');
  assert.ok(html.includes('showing 1 of 625'), 'the caveat that does apply still shows');
});

test('a healthy MERGE Q row is not painted as a warning', () => {
  const html = renderList(filterPipeline(payload, null));
  const row = html.slice(html.indexOf('MERGE Q') - 120, html.indexOf('MERGE Q'));
  assert.ok(!row.includes('tag--warn'), 'the auto-merge queue doing its job is not amber');
});

// ------------------------------------------------------------- the CARDS view

const renderBoard = (view, external = []) =>
  render(h(PipelineBoard, {
    board: view, external, shipped: shippedCaveat(view),
    showEmpty: false, emptyNote: '', onToggleAudit: () => {}
  }));

test('the CARDS view puts the caveat on the SHIPPED column itself', () => {
  // This is the whole point of the change: the column that shows a slice must
  // say so where the slice is, not in a footnote somewhere else on the page.
  const html = renderBoard(filterPipeline(payload, null));
  assert.ok(html.includes('SHIPPED'), 'the column is drawn');
  assert.ok(html.includes('showing 1 of 625'), 'and it states the real denominator');
});

test('the CARDS view without a total renders the SHIPPED column exactly as before', () => {
  const old = { ...payload, counts: { ...payload.counts }, shipped_window_days: undefined };
  delete old.counts.merged_deployed_total;
  const html = renderBoard(filterPipeline(old, null));
  assert.ok(html.includes('SHIPPED'));
  assert.ok(!html.includes('showing'), 'no caveat is invented from a missing total');
});

test('a merged external claim on the board reads as merged, not as a stale branch', () => {
  const html = renderBoard(filterPipeline(payload, null), [mergedExternal]);
  assert.ok(html.includes('PR #1421 merged'));
  assert.ok(html.includes('ticket not closed'));
  assert.ok(!html.includes('stale branch'));
  assert.ok(!html.includes('card--stale'), 'and it is not styled as an abandoned lane');
});
