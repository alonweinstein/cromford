import test from 'node:test';
import assert from 'node:assert/strict';
import { h } from 'preact';

// BH-3569 (BH-3558.2): Now, History, command history and Needs read as words.
// Every render goes through the #3558 helpers; every "visible" check strips the
// tags (and so their title="..." attributes) first, because the raw value is
// allowed to stay in a tooltip for grep.

globalThis.window = globalThis.window || {
  location: { pathname: '/now', search: '' },
  dispatchEvent() {}, addEventListener() {}, removeEventListener() {},
  history: { pushState() {}, replaceState() {} }, scrollTo() {},
  localStorage: { getItem() { return null; }, setItem() {} }
};

const { render } = await import('preact-render-to-string');
const { stageLabel, verdictLabel } = await import('../src/lib/stages.js');
const { NowView, buildingColumns } = await import('../src/screens/Now.js');
const { NeedsView } = await import('../src/screens/Needs.js');
const { runColumns, buildColumns } = await import('../src/screens/History.js');
const { CommandsTable } = await import('../src/screens/CommandHistory.js');
const { commandRows } = await import('../src/lib/commands.js');
const { SortableTable } = await import('../src/ui/SortableTable.js');
const { assertNoRawHeaders, assertUsdLabelled } = await import('./legibility.bh-3558.js');

const NOW = Date.UTC(2026, 8, 29, 22, 4);
const ago = (s) => new Date(NOW - s * 1000).toISOString();
const ok = (data) => ({ data, error: null, loading: false, reload() {} });
const visible = (markup) => markup.replace(/<[^>]*>/g, ' ').replace(/\s+/g, ' ');
const helpers = (out) => { assertNoRawHeaders(out); assertUsdLabelled(out); };

const job = (id, over = {}) => ({
  id, project: 'cromford', ticket_id: `BH-${id}`, kind: 'build', status: 'running', stage: 'reviewing',
  box: 'hub', heartbeating: true, activity_age_s: 30, beat_age_s: 30, last_beat_at: ago(30), created_at: ago(1800), ...over
});
const jobsOk = (jobs) => ok({ jobs, as_of: new Date(NOW).toISOString() });
const RUNS = [
  { id: 11, project: 'project-3', kind: 'lead_review', rc: 1, summary: 'tickets=1', started_at: ago(3 * 3600), finished_at: ago(3 * 3600 - 60) },
  { id: 10, project: 'project-3', kind: 'triage', rc: 0, summary: 'tickets=1', started_at: ago(4 * 86400), finished_at: ago(4 * 86400 - 60) }
];
const nowData = (over = {}) => ok({
  boards: [{ project: 'project-3', paused: 0, automerge: 1, last_run_at: ago(600), last_rc: 1,
    last_summary: 'tickets=1 built=0 [gate=board_changed]', disk: '50% used' }],
  active_builds: [{ id: 5, bkey: 'k5', project: 'cromford', ticket_key: 'BH-7', stage: 'tier2_sweep_merged',
    tier: '2', verdict: 'APPROVE', pr_url: null, merged: 0, updated_at: ago(60) }],
  active_builds_truncated: false,
  recent_runs: RUNS,
  events: [{ id: 1, ts: ago(90000), project: 'project-3', type: 'pr_review', detail: 'PR #4 reviewed' }],
  needs: { total: 0 }, generated_at: new Date(NOW).toISOString(), ...over
});
const renderNow = (jobs = jobsOk([job(7, { stage: 'tier2_sweep_merged' })])) =>
  render(h(NowView, { data: nowData(), jobs, nowMs: NOW }));

test('L1 stage and verdict words', () => {
  assert.equal(stageLabel('tier2_sweep_merged'), 'merged by the reviewed-merge sweep');
  assert.equal(stageLabel('brand_new_stage'), 'brand new stage');
  assert.equal(stageLabel('3 tickets waiting'), '3 tickets waiting');
  assert.equal(verdictLabel('APPROVE'), 'approved');
  assert.equal(verdictLabel('BUDGET_STOP'), 'stopped at its budget');
  assert.equal(verdictLabel('SOMETHING_NEW'), 'something new');
});

test('L2 Now TIER reads as words and still sorts as a number', () => {
  const tbl = (m) => m.slice(m.indexOf('section__title">BUILDING NOW<'));
  const out = renderNow();
  assert.match(visible(tbl(out)), /reviewed merge/);
  assert.doesNotMatch(tbl(out).split('</tbody>')[0], />\s*2\s*</);
  // sort by tier, ascending: tier 1 before tier 2 even though the cells are words
  const cols = buildingColumns(NOW);
  const tier = cols.find((c) => c.key === 'tier');
  assert.equal(tier.sort({ tier: '2' }), 2);
  const sorted = render(h(SortableTable, { columns: cols, defaultSort: 'tier', rows: [
    { key: 'a', id: 'a', ticket: 'BH-7', project: 'cromford', stage: 'executing', tier: '2', created_at: ago(60) },
    { key: 'b', id: 'b', ticket: 'BH-8', project: 'cromford', stage: 'executing', tier: 1, created_at: ago(60) }
  ] }));
  assert.ok(sorted.indexOf('auto-merge') < sorted.indexOf('reviewed merge'), 'tier 1 sorts before tier 2');
});

test('L3 tier2_sweep_merged is never visible text on History, Now or Needs', () => {
  const hist = render(h(SortableTable, { columns: buildColumns(NOW), rows: [
    { id: 1, bkey: 'k', project: 'project-3', ticket_key: 'TK-1', stage: 'tier2_sweep_merged', tier: 2, verdict: 'APPROVE', merged: 1, updated_at: ago(60) }
  ] }));
  assert.doesNotMatch(visible(hist), /tier2_sweep_merged/);
  assert.match(visible(hist), /merged by the reviewed-merge sweep/);

  const now = renderNow();
  assert.doesNotMatch(visible(now), /tier2_sweep_merged/);

  const needs = render(h(NeedsView, {
    needs: ok({ alerts: [], commands: [], proposals: [], unfinished_builds: [],
      builds: [{ id: 3, project: 'project-3', ticket_key: 'TK-3', stage: 'tier2_sweep_merged', tier: 2, verdict: null, merged: 0, updated_at: ago(60) }],
      counts: { total: 1, builds: 1 }, truncated: {} }),
    jobs: jobsOk([]), project: null, kindFilter: null, nowMs: NOW, setParam() {}
  }));
  assert.doesNotMatch(visible(needs), /tier2_sweep_merged/);
});

test('L4 stamps: a day or older is dated, newer is relative', () => {
  const runs = visible(render(h(SortableTable, { columns: runColumns(NOW), rows: RUNS })));
  assert.match(runs, /Sep 25 22:04Z/);
  assert.match(runs, /3h ago/);
  const cmds = commandRows([
    { id: 1, type: 'chat', status: 'done', created_at: ago(3 * 3600) },
    { id: 2, type: 'chat', status: 'done', created_at: ago(4 * 86400) }
  ]).rows;
  const t = visible(render(h(CommandsTable, { rows: cmds, nowMs: NOW })));
  assert.match(t, /3h ago/);
  assert.match(t, /Sep 25 22:04Z/);
});

test('L5 codes and kinds read as words', () => {
  const now = renderNow();
  assert.match(visible(now), /exit code 1 · failed/);
  assert.match(now, new RegExp(`stat__label">FAILED OF LAST ${RUNS.length} TICKS<`));
  assert.doesNotMatch(now, /BAD TICKS IN VIEW/);

  const cmds = commandRows([{ id: 1, type: 'chat', status: 'dead_letter', created_at: ago(60) }]).rows;
  const t = visible(render(h(CommandsTable, { rows: cmds, nowMs: NOW })));
  assert.match(t, /gave up after retries/);
  assert.doesNotMatch(t, /dead_letter/);

  const runs = visible(render(h(SortableTable, { columns: runColumns(NOW), rows: RUNS })));
  assert.match(runs, /lead review/);
  assert.doesNotMatch(runs, /lead_review/);
});

test('L6 Needs explains BLOCKING, WAITING and DECIDE in a visible Legend', () => {
  const out = render(h(NeedsView, {
    needs: ok({ alerts: [], commands: [], builds: [], proposals: [], unfinished_builds: [], counts: { total: 0 }, truncated: {} }),
    jobs: jobsOk([]), project: null, kindFilter: null, nowMs: NOW, setParam() {}
  }));
  for (const term of ['blocking', 'waiting', 'decide']) {
    assert.match(out, new RegExp(`<dt>${term}</dt>`), `${term} is a visible legend term`);
  }
});

test('L7 the helpers pass on every Now/History/CommandHistory/Needs render', () => {
  helpers(renderNow());
  helpers(render(h(SortableTable, { columns: runColumns(NOW), rows: RUNS })));
  helpers(render(h(SortableTable, { columns: buildColumns(NOW), rows: [
    { id: 1, project: 'project-3', ticket_key: 'TK-1', stage: 'plan_blocked', tier: 1, verdict: 'BLOCK', merged: 0, updated_at: ago(60) }
  ] })));
  helpers(render(h(CommandsTable, { rows: commandRows([{ id: 1, type: 'chat', status: 'failed', created_at: ago(60) }]).rows, nowMs: NOW })));
  helpers(render(h(NeedsView, {
    needs: ok({ alerts: [], commands: [], builds: [], proposals: [], unfinished_builds: [], counts: { total: 0 }, truncated: {} }),
    jobs: jobsOk([]), project: null, kindFilter: null, nowMs: NOW, setParam() {}
  })));
});
