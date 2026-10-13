import test from 'node:test';
import assert from 'node:assert/strict';
import { render } from 'preact-render-to-string';
import { h } from 'preact';
import { ModelsView, ModelRoleView } from '../src/screens/Models.js';
import { modelRows, spendPlan, coverage, gapRows } from '../src/lib/models.js';

// BH-1563 — the MODELS screen rendered for real, for the three things the
// #1560 round-2 review asked for on screen: the gapped scopes an operator can
// otherwise never see, the repair path on the role page, and the SHARED tag on
// the CALLS column (a summed calls figure is as double-counted as the dollars).
// Fixtures carry model ids; console-ui/tests is lint-exempt.

const prices = {
  per_token: {
    'claude-opus-5': { prompt: 0.000005, completion: 0.000025 },
    'claude-fable-5-1': { prompt: 0.000015, completion: 0.000075 }
  }
};
const runners = ['claude', 'codex', 'openrouter', 'grok', 'fireworks'];
const noop = () => {};
const tabs = [{ id: 'hub', label: 'HUB' }, { id: 'project-4', label: 'project-4' }];

const rung = (model, position = 0, runner = 'claude') => ({ position, model, runner, updated_by: 'op' });

const routes = {
  project: null, runners,
  gaps: [
    { project: null, role: 'triage', positions: [1, 3] },
    { project: 'project-4', role: 'build.qa', positions: [2] }
  ],
  roles: [
    // build.review is a SHARED-stage role (shared with rescue.review).
    { role: 'build.review', source: 'hub', ladder: [rung('claude-fable-5-1')], gapped: false },
    // build.plan is an EXACT role: no tag anywhere in its row.
    { role: 'build.plan', source: 'hub', ladder: [rung('claude-opus-5')], gapped: false },
    // triage's hub scope is the gapped one: no route, and tagged GAPPED.
    { role: 'triage', source: 'none', ladder: [], gapped: true }
  ]
};

const rowsFor = (rts, project) => {
  const plan = spendPlan(rts.roles.map((r) => r.role), project);
  const spend = {};
  for (const q of plan.queries) spend[q.key] = { usd: 12.34, calls: 7 };
  return modelRows({ routes: rts, prices, spend, plan, project });
};

const listView = (over = {}) => {
  const rts = over.routes || routes;
  const rows = rowsFor(rts, over.project || null);
  return render(h(ModelsView, {
    tabs, activeTab: over.project || 'hub', rows, coverage: coverage(rows), gaps: gapRows(rts),
    error: null, loading: false, asOf: '2026-09-23T12:00:00Z', onTab: noop, onReload: noop
  }));
};

// The RESET button itself, not the word: the gapped note under LADDER names
// the action in prose, and an assertion that cannot tell the two apart stays
// green with the button gone.
const RESET_BUTTON = /btn--warn[\s\S]{0,160}?>RESET TO HUB<\/button>/;

// The cell block of one role's row, so "two SHARED tags in this row" is a claim
// about that row and not about the page.
const rowOf = (html, role) => {
  const start = html.indexOf(`>${role}<`);
  assert.ok(start > 0, `${role} is on the page`);
  const end = html.indexOf('</tr>', start);
  assert.ok(end > start, `${role}'s row closes`);
  return html.slice(start, end);
};

// ───────────────────────────────────────────── the banner and the tags

test('the list page banners every gapped scope, with a link to each one\'s role page on the right tab', () => {
  const html = listView();
  assert.match(html, /2 scopes/, 'the count is the length of the gaps list');
  assert.match(html, /no rung 0/i);
  assert.match(html, /ignored by every resolver/i);
  assert.ok(html.includes('href="/models/triage"'), 'the hub gap links to the hub tab');
  assert.ok(html.includes('href="/models/build.qa?project=project-4"'), 'the project gap links to that project\'s tab');
  assert.ok(html.includes('hub / triage (rungs 1, 3)'));
  assert.ok(html.includes('project-4 / build.qa (rungs 2)'));
});

test('no gapped scope renders no banner at all', () => {
  const clean = { ...routes, gaps: [], roles: routes.roles.map((r) => ({ ...r, gapped: false })) };
  const html = listView({ routes: clean });
  assert.doesNotMatch(html, /no rung 0/i);
  assert.doesNotMatch(html, /GAPPED/);
});

test('a gapped row carries GAPPED beside its scope tag; a healthy row carries neither', () => {
  const html = listView();
  const gapped = rowOf(html, 'triage');
  assert.match(gapped, /GAPPED/);
  assert.match(gapped, /NO ROUTE/, 'a gapped hub scope resolves to nothing');
  assert.doesNotMatch(rowOf(html, 'build.plan'), /GAPPED/);
});

test('a gapped PROJECT scope is tagged GAPPED beside HUB DEFAULT: it exists, and nothing reads it', () => {
  const projectRoutes = {
    project: 'project-4', runners, gaps: [{ project: 'project-4', role: 'build.qa', positions: [2] }],
    roles: [{ role: 'build.qa', source: 'hub', ladder: [rung('claude-opus-5')], gapped: true }]
  };
  const html = listView({ routes: projectRoutes, project: 'project-4' });
  const row = rowOf(html, 'build.qa');
  assert.match(row, /GAPPED/);
  assert.match(row, /HUB DEFAULT/);
});

test('the CALLS 7D cell of a shared-stage role carries SHARED, exactly as the $ 7D cell does; an exact role\'s row carries none', () => {
  const html = listView();
  const shared = rowOf(html, 'build.review');
  assert.equal((shared.match(/>SHARED</g) || []).length, 2, 'one on CALLS 7D, one on $ 7D');
  assert.equal((rowOf(html, 'build.plan').match(/>SHARED</g) || []).length, 0);
});

// ───────────────────────────────────────────────── the repair path

const roleView = (over = {}) => render(h(ModelRoleView, {
  role: 'build.qa', project: 'project-4',
  route: {
    ladder: [rung('claude-opus-5')], source: 'hub', scope_version: 12, hub_scope_version: 41, provenance: [],
    gapped: { rows: [{ position: 2, model: 'claude-fable-5-1', runner: 'grok' }] }
  },
  hub: [rung('claude-opus-5')], row: null, prices, runners, changes: [], truncated: false,
  error: null, dialog: null, busy: null, note: null, onDismissNote: noop,
  actions: { saveLadder: noop, resetOverride: noop, keepSeed: noop }, ...over
}));

test('the role page of a gapped project scope lists the orphan rows and offers RESET TO HUB to drop them', () => {
  const html = roleView();
  assert.match(html, /rung 2/);
  assert.ok(html.includes('claude-fable-5-1'), 'the orphan row names its model');
  assert.ok(html.includes('grok'), 'and its runner');
  assert.match(html, /no rung 0/i);
  assert.match(html, RESET_BUTTON, 'the repair an operator can make on a project scope');
});

test('a gapped HUB scope has no RESET TO HUB — there is nothing above the hub — but SAVE LADDER still repairs it', () => {
  const html = roleView({
    project: null, hub: null,
    route: {
      ladder: [], source: 'none', scope_version: 8, hub_scope_version: 8, provenance: [],
      gapped: { rows: [{ position: 1, model: 'claude-opus-5', runner: 'claude' }] }
    }
  });
  assert.doesNotMatch(html, RESET_BUTTON);
  assert.doesNotMatch(html, /RESET TO HUB/, 'and the note does not offer a reset the hub cannot do');
  assert.match(html, /SAVE LADDER/);
  assert.match(html, /rung 1/);
});

test('a healthy role page says nothing about gaps', () => {
  const html = roleView({
    route: { ladder: [rung('claude-opus-5')], source: 'project', scope_version: 12, hub_scope_version: 41, provenance: [], gapped: null }
  });
  assert.doesNotMatch(html, /no rung 0/i);
  assert.match(html, RESET_BUTTON, 'a real project override still resets');
});
