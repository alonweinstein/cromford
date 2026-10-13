import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { render } from 'preact-render-to-string';
import { h } from 'preact';
import { SettingsView, LaneDetailView } from '../src/screens/Settings.js';
import { laneRows, tabsFrom, makeLaneActions } from '../src/lib/settings.js';

// A BOX LANE'S PER-PROJECT KNOBS ON THE PROJECT TAB (BH-1985).
//
// lane-reaper is a box lane whose LANE_REAP_DEADLINE_SECS is `project_scoped`:
// the reaper reads `lane.lane-reaper.<project>.lane_reap_deadline_secs` for a
// build of that project (BH-1770). Until now only `harness-ctl set` could see
// or write that row. The project tab draws it as a KNOB-ONLY row: the box
// lane's switch is fleet-wide, and nothing reads `lane-off-lane-reaper-<p>`, so
// the row must offer no per-project switch.
//
// Assertions are on the rows laneRows() returns, the writes makeLaneActions()
// makes and the HTML the real components render — never on module source (D3).

// determinism: ok-file clock-now-js every timestamp is an OFFSET from one
// captured read; no case asserts a calendar date.
const NOW = Date.now();
const iso = (minutesAgo) => new Date(NOW - minutesAgo * 60000).toISOString();

const P = 'project-4';

// The lane-reaper declaration is the committed one (D4): the fixture is what
// the worker bakes, not a shape this file invented.
const REAPER = JSON.parse(readFileSync(
  fileURLToPath(new URL('../../catalog/lanes.d/lane-reaper.json', import.meta.url)), 'utf8'));
const REAPER_NAME = `${REAPER.name} (box lane)`;

const registry = {
  lanes: [
    REAPER,
    // A plain box lane with no project-scoped knob: it stays off project tabs.
    {
      id: 'disk-sweep', name: 'Disk sweep', scope: 'box',
      script: 'bin/disk-sweep.sh', cadence: '0 * * * *',
      switch: { kind: 'flag', name: 'lane-off-disk-sweep' },
      knobs: [{ env: 'DISK_SWEEP_PCT', type: 'int', default: 85, min: 50, max: 99 }],
      stats: { cost_stage: null, log: 'logs/disk-sweep.log' }
    },
    // A hub lane that takes a per-project hold (BH-1466).
    {
      id: 'merge-conductor', name: 'Merge conductor', scope: 'hub', per_project_hold: true,
      script: 'bin/merge-conductor.sh', cadence: '*/5 * * * *',
      switch: { kind: 'flag', name: 'lane-off-merge-conductor' },
      knobs: [{ env: 'MC_MERGE_BUDGET', type: 'int', default: 5, min: 0, max: 50, zero_means: 'off' }],
      stats: { cost_stage: 'review', log: 'logs/merge-conductor.log' }
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

// D4: GET /api/lanes/status answers EVERY lane on every tab; ?project= only
// picks which keys and switch names are read (worker/jobs/src/routes/lanes.js).
const projectStatus = (reaperKnobs) => ({
  as_of: iso(1), project: P, projects: [P, 'project-3'], all_off: false,
  lanes: [
    {
      id: 'lane-reaper', scope: 'box', project: null, off: false, cadence: '*/10 * * * *',
      last_tick_at: iso(3), last_outcome: 'ok', runs_today: 30, cost_today: null, cost_7d: null,
      switch: { kind: 'flag', name: 'lane-off-lane-reaper' },
      knobs: reaperKnobs
    },
    { id: 'disk-sweep', scope: 'box', project: null, off: false, knobs: {} },
    { id: 'merge-conductor', scope: 'hub', per_project_hold: true, project: null, off: false, knobs: {} },
    { id: 'review-prs', scope: 'project', project: P, off: false, knobs: {} }
  ]
});
const PROJECT_ROW = {
  LANE_REAP_DEADLINE_SECS: {
    value: 43200, source: 'settings', key: 'lane.lane-reaper.project-4.lane_reap_deadline_secs',
    min: 1800, max: 172800, type: 'int'
  }
};
const hubStatus = { ...projectStatus({}), project: null };

const reaperRow = (status = projectStatus(PROJECT_ROW), tab = P) =>
  laneRows(registry, status, tab).find((r) => r.id === 'lane-reaper');

// ── C1 ──────────────────────────────────────────────────────────────────────
test('C1: the project tab has a knob-only lane-reaper row carrying only its project-scoped knob', () => {
  const row = reaperRow();
  assert.ok(row, 'the project tab has no lane-reaper row');
  assert.equal(row.name, REAPER_NAME);
  assert.equal(row.knobsOnly, true);
  assert.equal(row.scope, 'box');
  assert.equal(row.project, P);
  assert.deepEqual(row.knobs.map((k) => k.env), ['LANE_REAP_DEADLINE_SECS'],
    'a knob the reaper reads lane-wide was offered per project');
  // Exactly one row for it: not also an "unregistered" duplicate from status.
  assert.equal(laneRows(registry, projectStatus(PROJECT_ROW), P).filter((r) => r.id === 'lane-reaper').length, 1);
  // A box lane with no project-scoped knob gets no knob-only row: it keeps the
  // live-only row the status payload already gave it on every tab.
  const sweep = laneRows(registry, projectStatus(PROJECT_ROW), P).filter((r) => r.id === 'disk-sweep');
  assert.equal(sweep.length, 1);
  assert.equal(sweep[0].knobsOnly, undefined);
  assert.equal(sweep[0].unregistered, true);
});

// ── C2 ──────────────────────────────────────────────────────────────────────
test('C2: the value is the status payload\'s, and the registry default when the status has none', () => {
  const k = reaperRow().knobs[0];
  assert.equal(k.value, 43200);
  assert.equal(k.source, 'settings');

  const d = reaperRow(projectStatus({})).knobs[0];
  assert.equal(d.value, REAPER.knobs.find((x) => x.env === 'LANE_REAP_DEADLINE_SECS').default);
  assert.equal(d.source, 'default');
});

// ── C3 ──────────────────────────────────────────────────────────────────────
test('C3: setting the knob writes the per-project key the reaper reads', async () => {
  const writes = [];
  const actions = makeLaneActions({
    confirm: async () => true,
    writeSetting: async (body) => { writes.push(body); },
    writeFlag: async () => { throw new Error('no flag write expected'); }
  });
  const row = reaperRow();
  const res = await actions.setKnob(row, row.knobs[0], '43200');
  assert.equal(res.status, 'written');
  assert.equal(writes.length, 1);
  assert.equal(writes[0].key, 'lane.lane-reaper.project-4.lane_reap_deadline_secs');
  assert.equal(writes[0].value, 43200);
});

// ── C4 ──────────────────────────────────────────────────────────────────────
test('C4: the row links to its detail page, and the detail screen finds it', () => {
  const row = reaperRow();
  assert.equal(row.href, `/settings/lane-reaper?project=${P}`);
  // LaneDetailScreen does exactly this lookup with the ?project= it was given.
  const again = laneRows(registry, projectStatus(PROJECT_ROW), P).find((r) => r.id === 'lane-reaper');
  assert.ok(again, 'the detail page would say NO SUCH LANE');
  const html = render(h(LaneDetailView, {
    lane: again, laneId: 'lane-reaper', project: P, error: null, loading: false, costRows: []
  }));
  assert.ok(!html.includes('NO SUCH LANE'));
  assert.ok(html.includes('LANE_REAP_DEADLINE_SECS'), 'the detail knobs table does not list the knob');
});

// ── C5 ──────────────────────────────────────────────────────────────────────
test('C5: the hub tab is unchanged, and a registry with no project_scoped knob leaves the project tab as it was', () => {
  // The registry with every `project_scoped` stripped: the page as it was
  // before this ticket, for any registry that declares none.
  const flat = { lanes: registry.lanes.map((l) => ({ ...l, knobs: (l.knobs || []).map(({ project_scoped, ...k }) => k) })) };

  // HUB: no knob-only row, and exactly the rows the flat registry gives.
  const hub = laneRows(registry, hubStatus, 'hub');
  assert.ok(hub.every((r) => !r.knobsOnly), 'the hub tab grew a knob-only row');
  assert.deepEqual(hub, laneRows(flat, hubStatus, 'hub'));

  // PROJECT, flat registry: no knob-only row; lane-reaper is the live-only row
  // it always was, with no knob inputs.
  const rows = laneRows(flat, projectStatus(PROJECT_ROW), P);
  assert.ok(rows.every((r) => !r.knobsOnly));
  const reaper = rows.filter((r) => r.id === 'lane-reaper');
  assert.equal(reaper.length, 1);
  assert.equal(reaper[0].unregistered, true);
  assert.deepEqual(reaper[0].knobs, []);
});

// ── C6 ──────────────────────────────────────────────────────────────────────
test('C6: toggling a knob-only row is refused before any confirm or write', async () => {
  let confirms = 0;
  let flags = 0;
  const actions = makeLaneActions({
    confirm: async () => { confirms += 1; return true; },
    writeFlag: async () => { flags += 1; },
    writeSetting: async () => {}
  });
  const res = await actions.toggleLane(reaperRow());
  assert.equal(res.status, 'invalid');
  assert.match(res.message, /fleet-wide/);
  assert.equal(confirms, 0, 'the operator was asked to confirm a switch that does not exist');
  assert.equal(flags, 0, 'a lane-off-lane-reaper-<project> flag nothing reads was written');
});

// ── C7 ──────────────────────────────────────────────────────────────────────
test('C7: the row draws no toggle, and the detail switch line never prints flags/null', () => {
  const noop = () => {};
  const status = projectStatus(PROJECT_ROW);
  const rows = laneRows(registry, status, P);
  const html = render(h(SettingsView, {
    tabs: tabsFrom(status), activeTab: P, rows, status, error: null, loading: false,
    busy: null, note: null, actions: { toggleLane: noop, setKnob: noop, allOff: noop, allOn: noop },
    dialog: null, onTab: noop, onReload: noop
  }));
  // The reaper's <tr>: from its name link to the end of that row.
  const at = html.indexOf(REAPER_NAME);
  assert.ok(at > -1, 'the lane-reaper row is not on the page');
  const tr = html.slice(at, html.indexOf('</tr>', at));
  assert.ok(!/class="toggle/.test(tr), 'the knob-only row draws an ON/OFF toggle');
  assert.ok(tr.includes('fleet-wide switch'), 'the STATE cell does not say the switch is fleet-wide');
  assert.ok(tr.includes('LANE_REAP_DEADLINE_SECS'), 'the knob input is missing from the row');
  // The review-prs row (a real per-project switch) still has its toggle.
  const rp = html.indexOf('Review PRs');
  assert.ok(/class="toggle/.test(html.slice(rp, html.indexOf('</tr>', rp))));

  const detail = render(h(LaneDetailView, {
    lane: rows.find((r) => r.id === 'lane-reaper'), laneId: 'lane-reaper', project: P,
    error: null, loading: false, costRows: []
  }));
  assert.ok(!detail.includes('flags/null'), 'the detail page names a flag file that does not exist');
  assert.match(detail, /fleet-wide, not per project/);
});

// ── C1b ─────────────────────────────────────────────────────────────────────
test('C1b: a hold lane with a project_scoped knob keeps one row, its hold switch, and gains the knob', () => {
  const reg = { lanes: registry.lanes.map((l) => (l.id !== 'merge-conductor' ? l : {
    ...l, knobs: l.knobs.concat([{ env: 'MC_PROJECT_CAP', type: 'int', default: 2, min: 0, max: 9, project_scoped: true }])
  })) };
  const mc = laneRows(reg, projectStatus({}), P).filter((r) => r.id === 'merge-conductor');
  assert.equal(mc.length, 1, 'the hold lane got a second, knob-only row');
  assert.equal(mc[0].knobsOnly, undefined, 'the hold row lost its per-project switch');
  assert.equal(mc[0].switchName, `lane-off-merge-conductor-${P}`);
  assert.deepEqual(mc[0].knobs.map((k) => k.env), ['MC_PROJECT_CAP']);
});
