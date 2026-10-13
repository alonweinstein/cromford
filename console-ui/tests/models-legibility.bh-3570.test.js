import test from 'node:test';
import assert from 'node:assert/strict';
import { render } from 'preact-render-to-string';
import { h } from 'preact';
import { ModelsView, ModelRoleView, unroutedColumns } from '../src/screens/Models.js';
import { modelRows, spendPlan, screenCoverage, changeRows, unroutedRows, priceRows } from '../src/lib/models.js';
import { assertNoRawHeaders, assertUsdLabelled } from './legibility.bh-3558.js';

// BH-3570 (#3558.3): /models and /models/:role read without hovering. A legend
// says what PRIMARY, FAILOVER, RUNG and RC 75 mean, the STAGE RUNNERS note says
// only what the route read can back up, and every dollar says its basis.
// Fixtures are the shapes GET /api/model-routes and its history read return
// (worker/jobs/src/routes/model-routes.js). console-ui/tests is lint-exempt
// for model ids.

const NOW = Date.UTC(2026, 8, 29, 14, 5);
const ago = (ms) => new Date(NOW - ms).toISOString();
const H = 3600e3;
const D = 24 * H;

const prices = {
  per_token: {
    'claude-opus-5': { prompt: 0.000005, completion: 0.000025 },
    'claude-fable-5-1': { prompt: 0.000015, completion: 0.000075 },
    'gpt-6-astra': { prompt: 0.0000025, completion: 0.00001 }
  }
};
const runners = ['claude', 'codex', 'openrouter', 'grok', 'fireworks'];
const noop = () => {};
const tabs = [{ id: 'hub', label: 'HUB' }, { id: 'project-4', label: 'project-4' }];
const rung = (model, position = 0, runner = 'claude') => ({ position, model, runner, updated_by: 'op', updated_at: ago(5 * D) });

const routes = {
  project: null, runners, gaps: [], as_of: ago(2 * 60e3),
  roles: [
    { role: 'build.execute', source: 'hub', gapped: false, ladder: [rung('claude-opus-5'), rung('gpt-6-astra', 1, 'codex')] },
    { role: 'orchestrate', source: 'hub', gapped: false, ladder: [rung('claude-fable-5-1')] },
    { role: 'stage.plan', source: 'hub', gapped: false, ladder: [rung('claude-opus-5'), rung('gpt-6-astra', 1, 'codex')] },
    { role: 'stage.execute', source: 'hub', gapped: false, ladder: [rung('gpt-6-astra', 0, 'codex')] }
  ],
  unrouted_stages: [{ stage: 'foo', role: 'stage.foo', projects: ['p1'], calls: 3, last_seen: ago(2 * D), runners: ['claude'] }]
};

const rowsFor = (rts, project = null) => {
  const plan = spendPlan(rts.roles.map((r) => r.role), project);
  const spend = {};
  for (const q of plan.queries) spend[q.key] = { usd: 12.34, calls: 7 };
  return modelRows({ routes: rts, prices, spend, plan, project });
};

const listView = (rows = rowsFor(routes)) => render(h(ModelsView, {
  tabs, activeTab: 'hub', rows, coverage: screenCoverage(rows), gaps: [],
  unrouted: unroutedRows(routes, null), prices: priceRows(prices),
  error: null, loading: false, asOf: routes.as_of, onTab: noop, onReload: noop
}));

const withLive = (rows, live) => rows.map((r) => (r.role.startsWith('stage.') ? { ...r, live: live(r) } : r));

// A term counts as explained only when it is a <dt> inside the visible legend.
const legendTerm = (html, term) => {
  const dl = html.match(/<dl class="legend">[\s\S]*?<\/dl>/);
  assert.ok(dl, 'a legend is rendered');
  const esc = term.replace(/[.*+?^${}()|[\]\\/]/g, '\\$&');
  assert.match(dl[0], new RegExp(`<dt>${esc}</dt>`), `${term} is a legend term`);
  return dl[0];
};

test('M1: /models carries a legend, an honest STAGE RUNNERS sentence and labelled dollars', () => {
  const html = listView();
  assert.equal(html.includes('Inert until'), false, 'the old unbacked claim is gone');
  assert.match(html, /Not confirmed live/);
  for (const t of ['PRIMARY', 'FAILOVER', 'RUNNER', 'SCOPE', 'RUNG', 'RC 75', '$/1M IN / OUT']) legendTerm(html, t);
  const dl = legendTerm(html, 'RC 75');
  assert.match(dl, /rate limited, the failover took the call/);
  assert.match(dl, /RUNG 0 is the primary/);
  assert.match(html, /data-usd-basis="api"[^>]*>\$12\.34/, '$ 7D figure carries its basis');
  assert.match(html, /data-usd-basis="api"[^>]*>\$5\.00 \/ \$25\.00/, '$/1M span carries its basis');
  assertNoRawHeaders(html);
  assertUsdLabelled(html);
});

test('M2: the STAGE RUNNERS sentence follows the rows\' own live field', () => {
  const live = listView(withLive(rowsFor(routes), () => true));
  assert.match(live, /Live: agent-call picks each build stage&#39;s runner from these rows\.|Live: agent-call picks each build stage's runner from these rows\./);
  assert.equal(live.includes('Not confirmed live'), false);
  const notLive = listView(withLive(rowsFor(routes), (r) => r.role !== 'stage.plan'));
  assert.match(notLive, /Not live: agent-call does not read these rows yet\./);
  const partial = listView(withLive(rowsFor(routes), (r) => (r.role === 'stage.plan' ? true : undefined)));
  assert.match(partial, /Not confirmed live/);
});

test('M3: /models/:role has the legend, a dated history and a labelled spend line', () => {
  const row = { ...rowsFor({ roles: [routes.roles[0]] }).find((r) => r.role === 'build.execute'), usd_7d: 12.5, calls_7d: 9 };
  const changes = changeRows([
    { id: 7, scope: 'hub', project: null, role: 'build.execute', position: 1, before_model: null, before_runner: null, after_model: 'gpt-6-astra', after_runner: 'codex', actor: 'console', reason: 'add failover', at: ago(4 * D) }
  ]);
  const html = render(h(ModelRoleView, {
    role: 'build.execute', project: null,
    route: { ladder: routes.roles[0].ladder, source: 'hub', scope_version: 3, provenance: [] },
    hub: null, row, prices, runners, changes, truncated: false, nowMs: NOW,
    error: null, dialog: null, busy: null, note: null, onDismissNote: noop,
    actions: { saveLadder: noop, resetOverride: noop }
  }));
  legendTerm(html, 'RUNG');
  legendTerm(html, 'RC 75');
  assert.match(html, /href="#change-7"[^>]*>Sep 25 14:05Z</, 'the WHEN cell is dated, not a bare HH:MMZ');
  assert.match(html, /data-usd-basis="api"[^>]*>\$12\.50/, 'spend line carries its basis');
  assert.match(html, /over 9 calls/);
  assert.match(html, /data-usd-basis="api"[^>]*>\$5\.00</, 'the $/1M IN cell carries its basis');
  assertNoRawHeaders(html);
  assertUsdLabelled(html);
});

test('M4: UNROUTED STAGES LAST SEEN two days back shows its date', () => {
  const col = unroutedColumns.find((c) => c.key === 'last_seen');
  const [r] = unroutedRows(routes, null);
  const html = render(h('div', null, col.cell(r, NOW)));
  assert.match(html, />Sep 27 14:05Z</);
  assert.match(html, new RegExp(`title="${r.last_seen}"`), 'the raw stamp stays in the title');
});
