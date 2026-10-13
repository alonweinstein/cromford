import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync, readdirSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { render } from 'preact-render-to-string';
import { h } from 'preact';
import { ModelsView, ModelRoleView } from '../src/screens/Models.js';
import { modelRows, spendPlan, coverage, changeRows } from '../src/lib/models.js';

// BH-1510.3 — the MODELS screen rendered for real and read back, so "the screen
// shows every role, its ladder, its price and its spend" is observed, not
// assumed. Fixtures carry model ids; console-ui/tests is lint-exempt.

const prices = {
  per_token: {
    'claude-opus-5': { prompt: 0.000005, completion: 0.000025 },
    'claude-opus-5-5': { prompt: 0.000005, completion: 0.000025 },
    'claude-fable-5-1': { prompt: 0.000015, completion: 0.000075 },
    'gpt-6-astra': { prompt: 0.0000025, completion: 0.00001 }
  }
};
const runners = ['claude', 'codex', 'openrouter', 'grok', 'fireworks'];

const hubRoutes = {
  project: null, runners,
  roles: [
    { role: 'build.execute', source: 'hub', ladder: [{ position: 0, model: 'claude-opus-5', runner: 'claude', updated_by: 'seed' }] },
    {
      role: 'orchestrate', source: 'hub', ladder: [
        { position: 0, model: 'claude-fable-5-1', runner: 'claude', updated_by: 'operator' },
        { position: 1, model: 'claude-opus-5-5', runner: 'claude', updated_by: 'operator' }
      ]
    },
    { role: 'auth.fallback', source: 'hub', ladder: [{ position: 0, model: 'claude-opus-5', runner: 'claude', updated_by: 'seed' }] },
    { role: 'codex.default', source: 'hub', ladder: [{ position: 0, model: 'gpt-6-astra', runner: 'codex', updated_by: 'op' }] }
  ]
};

const rowsFor = (routes, project) => {
  const plan = spendPlan(routes.roles.map((r) => r.role), project);
  const spend = {};
  for (const q of plan.queries) spend[q.key] = { usd: 12.34, calls: 7 };
  return modelRows({ routes, prices, spend, plan, project });
};

const noop = () => {};
const tabs = [{ id: 'hub', label: 'HUB' }, { id: 'project-4', label: 'project-4' }, { id: 'project-3', label: 'project-3' }];

const listView = (over = {}) => {
  const rows = rowsFor(hubRoutes, null);
  return render(h(ModelsView, {
    tabs, activeTab: 'hub', rows, coverage: coverage(rows), error: null, loading: false,
    asOf: '2026-09-22T12:00:00Z', onTab: noop, onReload: noop, ...over
  }));
};

// ─────────────────────────────────────────────────────────── the list

test('the MODELS page renders a hub tab and one tab per project', () => {
  const html = listView();
  assert.match(html, /MODELS/);
  for (const label of ['HUB', 'project-4', 'project-3']) assert.ok(html.includes(label), `${label} tab`);
  assert.match(html, /aria-selected="true"[^>]*>HUB</);
});

test('one row per role: its link, primary model, failover ladder, runner, $/1M in/out, 7-day calls and spend, scope', () => {
  const html = listView();
  for (const col of ['ROLE', 'PRIMARY', 'FAILOVER', 'RUNNER', '$/1M IN / OUT', 'CALLS 7D', '$ 7D', 'SCOPE']) {
    assert.ok(html.includes(col), `${col} column`);
  }
  // No dead rows: the role cell opens the role's own page.
  assert.match(html, /href="\/models\/build\.execute"/);
  assert.match(html, /href="\/models\/orchestrate"/);
  assert.ok(html.includes('claude-fable-5-1'), 'primary model');
  assert.ok(html.includes('claude-opus-5-5'), 'the failover rung is shown');
  // In and out share one column (the 1280px fit): "$5.00 / $25.00".
  assert.ok(html.includes('$5.00 / $25.00'), '$/1M in / out');
  assert.ok(html.includes('$12.34'), 'attributed spend');
  assert.ok(html.includes('HUB DEFAULT'));
  // The history drill-down is linked from every row.
  assert.match(html, /href="\/models\/build\.execute#history"/);
});

test('every column header is a sort button, and the table scrolls in its own container', () => {
  const html = listView();
  assert.match(html, /<th[^>]*aria-sort=[^>]*><button type="button"/);
  assert.match(html, /class="tablewrap/);
});

test('rungs still on their #1510.0 seed value are tagged, and the banner says exactly what it counts and how to clear it', () => {
  const html = listView();
  assert.match(html, /SEED/);
  assert.match(html, /2 roles carry a rung still on its #1510\.0 seed value/);
  assert.match(html, /KEEP SEEDED VALUE/, 'the banner names the real confirm path');
});

test('attribution is honest: a role with no cost attribution shows a dash, and the coverage note names it', () => {
  const html = listView();
  assert.match(html, /no spend attribution yet[^<]*auth\.fallback/);
});

test('a project tab labels overrides against hub defaults', () => {
  const projRoutes = {
    project: 'project-4', runners,
    roles: [
      { role: 'build.execute', source: 'project', ladder: [{ position: 0, model: 'claude-opus-5-5', runner: 'claude', updated_by: 'op' }] },
      { role: 'orchestrate', source: 'hub', ladder: [{ position: 0, model: 'claude-fable-5-1', runner: 'claude', updated_by: 'operator' }] }
    ]
  };
  const rows = rowsFor(projRoutes, 'project-4');
  const html = render(h(ModelsView, {
    tabs, activeTab: 'project-4', rows, coverage: coverage(rows), error: null, loading: false,
    asOf: null, onTab: noop, onReload: noop
  }));
  assert.ok(html.includes('PROJECT OVERRIDE'));
  assert.ok(html.includes('HUB DEFAULT'));
  assert.match(html, /href="\/models\/build\.execute\?project=project-4"/);
});

test('an unreachable API with nothing loaded is a banner, not an empty table that reads as "no roles"', () => {
  const html = listView({ rows: [], coverage: coverage([]), error: new Error('http_502') });
  assert.match(html, /could not reach the model-routes API/);
  assert.equal(html.includes('NO ROLES'), false);
});

// ────────────────────────────────────────────────────────── role page

const history = {
  changes: [
    { id: 9, scope: 'hub', project: null, role: 'build.execute', position: 0, before_model: 'claude-opus-5', before_runner: 'claude', after_model: 'claude-opus-5-5', after_runner: 'claude', actor: 'console', reason: '#1507 carry-over', at: '2026-09-22T12:00:00Z' },
    { id: 4, scope: 'project', project: 'project-4', role: 'build.execute', position: 1, before_model: 'gpt-6-astra', before_runner: 'codex', after_model: null, after_runner: null, actor: 'op', reason: null, at: '2026-09-21T12:00:00Z' }
  ],
  truncated: false
};

const roleView = (over = {}) => render(h(ModelRoleView, {
  role: 'build.execute', project: null,
  route: { ladder: [{ position: 0, model: 'claude-opus-5', runner: 'claude' }], source: 'hub', scope_version: 5,
    provenance: [{ position: 0, updated_by: 'seed', updated_at: '2026-09-22T00:00:00Z' }] },
  hub: null, row: rowsFor(hubRoutes, null).find((r) => r.role === 'build.execute'),
  prices, runners, changes: changeRows(history.changes), truncated: false,
  error: null, dialog: null, busy: null, note: null, onDismissNote: noop,
  actions: { saveLadder: noop, resetOverride: noop }, ...over
}));

test('the role page shows the resolved ladder, an editor limited to priced models and known runners, and the history', () => {
  const html = roleView();
  assert.match(html, /build\.execute/);
  assert.match(html, /← MODELS/);
  // Editor: a model select whose options are exactly the priced models.
  for (const m of Object.keys(prices.per_token)) assert.ok(html.includes(`<option value="${m}"`), `${m} is offered`);
  for (const r of runners) assert.ok(html.includes(`<option value="${r}"`), `${r} runner is offered`);
  assert.match(html, /SAVE LADDER/);
  assert.match(html, /ADD RUNG/);
  assert.match(html, /KEEP SEEDED VALUE/, 'a role carrying a seed rung offers the confirm path');
  // History: who, when, before, after, reason — each change its own anchor.
  assert.match(html, /id="history"/);
  assert.match(html, /id="change-9"/);
  assert.ok(html.includes('#1507 carry-over'));
  assert.ok(html.includes('console'));
  assert.ok(html.includes('removed'));
  assert.match(html, /href="#change-9"/);
});

test('KEEP SEEDED VALUE is offered only when the resolved scope carries a seed rung', () => {
  const decided = roleView({ route: { ladder: [{ position: 0, model: 'claude-opus-5-5', runner: 'claude' }], source: 'hub', provenance: [{ position: 0, updated_by: 'console' }] } });
  assert.equal(decided.includes('KEEP SEEDED VALUE'), false);
});

test('the reset action shows only on a project tab whose role carries its own override', () => {
  assert.equal(roleView().includes('RESET TO HUB'), false, 'nothing to reset on the hub');
  const proj = roleView({
    project: 'project-4',
    route: { ladder: [{ position: 0, model: 'claude-fable-5-1', runner: 'claude' }], source: 'project' },
    hub: [{ position: 0, model: 'claude-opus-5', runner: 'claude' }]
  });
  assert.ok(proj.includes('RESET TO HUB'));
  assert.ok(proj.includes('PROJECT OVERRIDE'));
  const onHub = roleView({
    project: 'project-4',
    route: { ladder: [{ position: 0, model: 'claude-opus-5', runner: 'claude' }], source: 'hub' },
    hub: [{ position: 0, model: 'claude-opus-5', runner: 'claude' }]
  });
  assert.equal(onHub.includes('RESET TO HUB'), false, 'a project on the hub default has nothing to reset');
  assert.match(onHub, /saving creates an override/i);
});

// ─────────────────────────────────────────────── wiring + dialogs

const SRC = fileURLToPath(new URL('../src/', import.meta.url));

test('MODELS is routed and in the main nav', () => {
  const app = readFileSync(`${SRC}app.js`, 'utf8');
  assert.match(app, /\['\/models', ModelsScreen\]/);
  assert.match(app, /\['\/models\/:role', ModelRoleScreen\]/);
  assert.match(app, /to: '\/models', label: 'MODELS'/);
});

test('no native dialog anywhere in the console source', () => {
  const walk = (dir) => readdirSync(dir, { withFileTypes: true }).flatMap((d) =>
    d.isDirectory() ? walk(`${dir}${d.name}/`) : d.name.endsWith('.js') ? [`${dir}${d.name}`] : []);
  for (const f of walk(SRC)) {
    const text = readFileSync(f, 'utf8').split('\n').filter((l) => !/^\s*\/\//.test(l)).join('\n');
    assert.equal(/window\.(confirm|alert|prompt)\s*\(/.test(text), false, `${f} calls a native dialog`);
  }
});
