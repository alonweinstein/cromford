import test from 'node:test';
import assert from 'node:assert/strict';
import { render } from 'preact-render-to-string';
import { h } from 'preact';
import { SettingsView, LaneDetailView } from '../src/screens/Settings.js';
import { laneRows, tabsFrom } from '../src/lib/settings.js';

// BH-3557: a lane the status API reports as cost_attribution "none" (no
// cost_stage, no cost_project_filter) renders "—" plus "no model cost of its
// own" instead of a dollar figure, and the lane section points at /costs for
// the fleet number. A lane without the field (older worker) renders as before.

const NOTE = 'no model cost of its own';

const registry = {
  lanes: [
    { id: 'cost-rollup', name: 'Cost rollup', scope: 'hub', stats: { cost_stage: null } },
    { id: 'alert-triage', name: 'Alert triage', scope: 'hub', stats: { cost_stage: 'triage' } },
    { id: 'pipeline-health', name: 'Pipeline health', scope: 'hub', stats: {} }
  ]
};

const status = {
  scope: 'hub', as_of: '2026-09-25T12:00:00Z', projects: ['project-4'],
  lanes: [
    { id: 'cost-rollup', off: false, runs_today: null, cost_today: null, cost_7d: null,
      cost_attribution: 'none', cost_rows: [] },
    { id: 'alert-triage', off: false, runs_today: 3, cost_today: 12.5, cost_7d: 40,
      cost_attribution: 'lane' },
    // an older worker: no cost_attribution at all
    { id: 'pipeline-health', off: false, runs_today: null, cost_today: null, cost_7d: null }
  ]
};

const noop = () => {};
const actions = { toggleLane: noop, setKnob: noop, allOff: noop, allOn: noop };
const view = () => render(h(SettingsView, {
  tabs: tabsFrom(status), activeTab: 'hub', rows: laneRows(registry, status, 'hub'),
  status, error: null, loading: false, busy: null, note: null,
  actions, dialog: null, onTab: noop, onReload: noop
}));

// The <tr> for one lane, found by its detail link.
function rowHtml(html, id) {
  const at = html.indexOf(`href="/settings/${id}"`);
  assert.ok(at >= 0, `no row for ${id}`);
  const start = html.lastIndexOf('<tr', at);
  const end = html.indexOf('</tr>', at);
  return html.slice(start, end);
}

test('C1: laneRows carries cost_attribution from the status, null when absent', () => {
  const rows = laneRows(registry, status, 'hub');
  const by = (id) => rows.find((r) => r.id === id);
  assert.equal(by('cost-rollup').cost_attribution, 'none');
  assert.equal(by('alert-triage').cost_attribution, 'lane');
  assert.equal(by('pipeline-health').cost_attribution, null);
  // the unregistered (live-only) builder carries it too
  const extra = laneRows({ lanes: [] }, status, 'hub').find((r) => r.id === 'cost-rollup');
  assert.equal(extra.unregistered, true);
  assert.equal(extra.cost_attribution, 'none');
});

test('C2: a "none" lane renders — and the note, and no $ figure', () => {
  const tr = rowHtml(view(), 'cost-rollup');
  assert.ok(tr.includes(`>${NOTE}<`), `the $ TODAY cell carries no visible note: ${tr}`);
  assert.ok(tr.includes('—'));
  assert.ok(!/\$\d/.test(tr), 'a dollar figure rendered on a lane with no cost of its own');
  assert.ok(tr.includes(`title="${NOTE}"`), '$ 7D / RUNS TODAY carry the note as a title');
});

test('C3: a "lane" lane still shows dollars; a lane with no field is a plain — as before', () => {
  const html = view();
  const at = rowHtml(html, 'alert-triage');
  assert.ok(at.includes('$12.50'), at);
  assert.ok(!at.includes(NOTE));
  const ph = rowHtml(html, 'pipeline-health');
  assert.ok(ph.includes('—'));
  assert.ok(!ph.includes(NOTE), 'an older worker\'s null got the "none" note it never reported');
});

test('C4: LaneDetailView shows the note on $ today and $ 7 days for a "none" lane', () => {
  const lane = laneRows(registry, status, 'hub').find((r) => r.id === 'cost-rollup');
  const html = render(h(LaneDetailView, { lane, project: null, error: null, loading: false, costRows: [] }));
  const today = html.slice(html.indexOf('<dt>$ today</dt>'), html.indexOf('<dt>$ 7 days</dt>'));
  const week = html.slice(html.indexOf('<dt>$ 7 days</dt>'), html.indexOf('<dt>log</dt>'));
  assert.ok(today.includes(NOTE), today);
  assert.ok(week.includes(NOTE), week);

  const staged = laneRows(registry, status, 'hub').find((r) => r.id === 'alert-triage');
  const h2 = render(h(LaneDetailView, { lane: staged, project: null, error: null, loading: false, costRows: [] }));
  assert.ok(!h2.includes(NOTE));
  assert.ok(h2.includes('$12.50'));
});

test('C5: the lane section links to /costs for the fleet spend', () => {
  const html = view();
  assert.match(html, /<a[^>]*href="\/costs"[^>]*>[^<]*COSTS/, 'no link to /costs on the Settings lane section');
});
