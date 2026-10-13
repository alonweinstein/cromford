import test from 'node:test';
import assert from 'node:assert/strict';
import { laneRows, flagName, flagBody } from '../src/lib/settings.js';

// A HUB LANE ON A PROJECT TAB (BH-1466, the console half of BH-1419).
//
// #1463 gave five hub lanes a per-project hold: one `lane-off-<id>-<project>`
// row stops that lane for that project alone. The switch existed and the page
// had nowhere to draw it, so the only way to hold the conductor off project-3 was a
// curl. These rows are that switch, on the tab the operator is already on.
//
// The assertions below are on the ROW VALUES laneRows() returns — the object
// both SettingsScreen and LaneDetailScreen render from — never on the source
// of the module (D3).

// determinism: ok-file clock-now-js every age here is an OFFSET from one
// captured read, and no case asserts a calendar date.
const NOW = Date.now();
const iso = (minutesAgo) => new Date(NOW - minutesAgo * 60000).toISOString();

const P = 'project-3';

// catalog/lanes.json as the worker bakes it: one hub lane that takes the hold,
// one plain hub lane, one project lane.
const registry = {
  lanes: [
    {
      id: 'merge-conductor', name: 'Merge conductor', scope: 'hub', per_project_hold: true,
      script: 'bin/merge-conductor.sh', cadence: '*/5 * * * *',
      switch: { kind: 'flag', name: 'lane-off-merge-conductor' },
      knobs: [
        { env: 'MC_MERGE_BUDGET', type: 'int', default: 5, min: 0, max: 50, zero_means: 'off' },
        { env: 'MC_PR_PARALLEL', type: 'int', default: 4, min: 1, max: 20, zero_means: null }
      ],
      stats: { cost_stage: 'review', log: 'logs/merge-conductor.log' }
    },
    {
      id: 'alert-triage', name: 'Alert triage (LLM)', scope: 'hub',
      script: 'bin/alert-triage.sh', cadence: '*/20 * * * *',
      switch: { kind: 'flag', name: 'lane-off-alert-triage' },
      knobs: [{ env: 'TRIAGE_MAX_FAMILIES', type: 'int', default: 3, min: 0, max: 20, zero_means: 'off' }],
      stats: { cost_stage: 'triage' }
    },
    {
      id: 'review-prs', name: 'Review PRs', scope: 'project',
      script: 'bin/review-prs.sh', cadence: '7,37 * * * *',
      switch: { kind: 'flag', name: 'lane-off-review-prs' },
      knobs: [{ env: 'RP_MAX_HEADS', type: 'int', default: 20, min: 1, max: 100 }],
      stats: { cost_stage: 'review' }
    }
  ]
};

// D4: the status payloads below carry EVERY lane, because that is the only
// thing GET /api/lanes/status can answer — `?project=` resolves which switch
// names and settings keys are read, it never filters which lanes exist
// (worker/jobs/src/routes/lanes.js). A project fixture holding only the
// project lanes is a payload the route cannot produce.
const projectStatus = {
  as_of: iso(1), project: P, projects: [P, 'project-4'], all_off: false,
  lanes: [
    {
      id: 'merge-conductor', name: 'Merge conductor', scope: 'hub', project: null,
      cadence: '*/5 * * * *', per_project_hold: true,
      off: true, off_source: 'db', paused_since: iso(30), paused_by: 'operator',
      paused_reason: 'pause project-3 fix rounds',
      held_by: ['lane-off-merge-conductor-project-3'], flag_boxes: [],
      switch: { kind: 'flag', name: 'lane-off-merge-conductor', aliases: [] },
      enables: [], modifiers: [],
      last_tick_at: iso(4), last_outcome: 'ok',
      runs_today: 41, cost_today: 12.5, cost_7d: 88.25,
      knobs: { MC_MERGE_BUDGET: { value: 8, source: 'settings', key: 'lane.merge-conductor.mc_merge_budget' } },
      cost_attribution: 'shared', cost_shared_with: ['review-autopilot'], cost_rows: []
    },
    {
      id: 'alert-triage', name: 'Alert triage (LLM)', scope: 'hub', project: null,
      cadence: '*/20 * * * *', per_project_hold: false,
      off: false, off_source: null, held_by: [], flag_boxes: [],
      enables: [], modifiers: [],
      last_tick_at: iso(9), last_outcome: 'ok', runs_today: 2, cost_today: 1.25, cost_7d: 9,
      knobs: {}, cost_attribution: 'lane', cost_shared_with: [], cost_rows: []
    },
    {
      id: 'review-prs', name: 'Review PRs', scope: 'project', project: P,
      cadence: '7,37 * * * *', per_project_hold: false,
      off: false, off_source: null, held_by: [], flag_boxes: [],
      enables: [], modifiers: [],
      last_tick_at: iso(11), last_outcome: 'ok', runs_today: 3, cost_today: 1.5, cost_7d: 9,
      knobs: {}, cost_attribution: 'lane', cost_shared_with: [], cost_rows: []
    }
  ]
};

const hubStatus = {
  ...projectStatus,
  project: null,
  lanes: projectStatus.lanes.map((l) => (l.id === 'merge-conductor'
    ? { ...l, off: false, off_source: null, paused_since: null, paused_by: null, paused_reason: null, held_by: [] }
    : l))
};

const rowsById = (rows, id) => rows.filter((r) => r.id === id);

// 1 ──────────────────────────────────────────────────────────────────────────
test('a per_project_hold hub lane gets a project-tab row with the project switch', () => {
  const rows = laneRows(registry, projectStatus, P);
  const mine = rowsById(rows, 'merge-conductor');
  assert.equal(mine.length, 1, 'exactly one row — not a hold row AND an unregistered duplicate');

  const [mc] = mine;
  assert.equal(mc.name, 'Merge conductor (hub lane)');
  assert.equal(mc.scope, 'hub');
  assert.equal(mc.project, P);
  assert.equal(mc.per_project_hold, true);
  assert.equal(mc.switchName, 'lane-off-merge-conductor-project-3');
  assert.equal(mc.knobs.length, 0, 'a hub lane never reads a per-project knob row');
  assert.equal(mc.off, true);
  assert.equal(mc.off_source, 'db');
  assert.deepEqual(mc.held_by, ['lane-off-merge-conductor-project-3']);
  assert.equal(mc.paused_reason, 'pause project-3 fix rounds');
  assert.equal(mc.unregistered, false);
  assert.equal(mc.unknown, false);
  assert.equal(mc.href, '/settings/merge-conductor?project=project-3', 'the detail link keeps the project');

  // The project lane is untouched, knobs and all.
  const [rp] = rowsById(rows, 'review-prs');
  assert.equal(rp.knobs.length, 1);
  assert.equal(rp.switchName, 'lane-off-review-prs-project-3');

  // A plain hub lane gains nothing from this change: it is still exactly the
  // one row the live payload already gave it on this tab.
  const triage = rowsById(rows, 'alert-triage');
  assert.equal(triage.length, 1);
  assert.equal(triage[0].unregistered, true, 'unchanged: a hub lane with no hold is still a live-only row');
  assert.equal(triage[0].per_project_hold, undefined);
  assert.equal(triage[0].name, 'Alert triage (LLM)', 'no (hub lane) label on a lane that takes no hold');
  assert.equal(rows.length, 3);
});

// 2 ──────────────────────────────────────────────────────────────────────────
test('the hub tab is exactly what it was before the field existed', () => {
  const without = { lanes: registry.lanes.map(({ per_project_hold, ...l }) => l) };
  assert.deepEqual(laneRows(registry, hubStatus, 'hub'), laneRows(without, hubStatus, 'hub'));

  const rows = laneRows(registry, hubStatus, 'hub');
  const [mc] = rowsById(rows, 'merge-conductor');
  assert.equal(mc.name, 'Merge conductor', 'no (hub lane) suffix on the hub tab');
  assert.equal(mc.knobs.length, 2, 'the hub tab keeps the knobs');
  assert.equal(mc.switchName, 'lane-off-merge-conductor');
  assert.equal(rows.every((r) => r.per_project_hold !== true), true, 'no hold rows on the hub tab');
});

// 3 ──────────────────────────────────────────────────────────────────────────
test('the existing toggle already writes the per-project row, unchanged', () => {
  // Settings.js calls flagBody(row.id, row.project, …) and the row above
  // carries project = project-3, so the OFF click writes the exact name #1463's
  // gate reads. This is why that screen needed no edit.
  assert.deepEqual(flagBody('merge-conductor', P, true, 'r'), {
    name: 'lane-off-merge-conductor-project-3', active: 1, actor: 'console', reason: 'r'
  });
  assert.equal(flagBody('merge-conductor', P, false, 'r').active, 0);
  assert.equal(flagName('merge-conductor', 'hub'), 'lane-off-merge-conductor');
});

// 4 ──────────────────────────────────────────────────────────────────────────
test('a hold row the status never named is UNKNOWN, and a null off stays null', () => {
  const omitted = { ...projectStatus, lanes: projectStatus.lanes.filter((l) => l.id !== 'merge-conductor') };
  const [gone] = rowsById(laneRows(registry, omitted, P), 'merge-conductor');
  assert.equal(gone.unknown, true);
  assert.equal(gone.off, null, 'a switch nobody read is not a switch that is on');
  assert.equal(gone.runs_today, null, 'unknown is not zero');
  assert.equal(gone.switchName, 'lane-off-merge-conductor-project-3', 'still switchable');

  const nulled = {
    ...projectStatus,
    lanes: projectStatus.lanes.map((l) => (l.id === 'merge-conductor' ? { ...l, off: null } : l))
  };
  const [unread] = rowsById(laneRows(registry, nulled, P), 'merge-conductor');
  assert.equal(unread.off, null);
  assert.equal(unread.unknown, false);
});
