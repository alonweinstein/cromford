import test from 'node:test';
import assert from 'node:assert/strict';
import { render } from 'preact-render-to-string';
import { h } from 'preact';
import { ModelsView, ModelRoleView } from '../src/screens/Models.js';
import { modelRows, spendPlan, coverage } from '../src/lib/models.js';

// BH-1613 — a model priced at the vendor's direct rate (model_prices
// price_source = 'vendor-direct') is marked DIRECT on /models and on the role
// page's ladder. Only the exact stored value marks it; the worker's PUT
// normalises to lowercase, so any other spelling in a body is not direct.

const prices = {
  per_token: {
    'grok-4.7': { prompt: 0.000002, completion: 0.000006, price_source: 'vendor-direct' },
    'claude-opus-5': { prompt: 0.000005, completion: 0.000025 },
    'claude-opus-5-5': { prompt: 0.000005, completion: 0.000025, price_source: 'openrouter' },
    'gpt-6-astra': { prompt: 0.0000025, completion: 0.00001, price_source: 'Vendor-Direct' }
  }
};
const runners = ['claude', 'codex', 'grok'];
const routes = {
  project: null, runners,
  roles: [
    { role: 'grok.default', source: 'hub', ladder: [{ position: 0, model: 'grok-4.7', runner: 'grok' }] },
    { role: 'build.execute', source: 'hub', ladder: [
      { position: 0, model: 'claude-opus-5', runner: 'claude' },
      { position: 1, model: 'grok-4.7', runner: 'grok' }] },
    { role: 'orchestrate', source: 'hub', ladder: [{ position: 0, model: 'claude-opus-5-5', runner: 'claude' }] },
    { role: 'codex.default', source: 'hub', ladder: [{ position: 0, model: 'gpt-6-astra', runner: 'codex' }] }
  ]
};
const rows = () => {
  const plan = spendPlan(routes.roles.map((r) => r.role), null);
  return modelRows({ routes, prices, spend: {}, plan, project: null });
};
const noop = () => {};
const count = (s, needle) => s.split(needle).length - 1;

test('C1: modelRows marks direct only for a primary whose price row is exactly vendor-direct', () => {
  const by = Object.fromEntries(rows().map((r) => [r.role, r.direct]));
  assert.deepEqual(by, { 'grok.default': true, 'build.execute': false, orchestrate: false, 'codex.default': false });
});

test('C2: the MODELS list shows DIRECT once, on the vendor-direct role', () => {
  const r = rows();
  const html = render(h(ModelsView, {
    tabs: [{ id: 'hub', label: 'HUB' }], activeTab: 'hub', rows: r, coverage: coverage(r), error: null,
    loading: false, asOf: '2026-09-23T00:00:00Z', onTab: noop, onReload: noop
  }));
  assert.equal(count(html, '>DIRECT<'), 1, 'exactly one DIRECT tag');
  const grokRow = html.slice(html.indexOf('/models/grok.default'));
  assert.ok(grokRow.indexOf('>DIRECT<') < grokRow.indexOf('/models/build.execute') || grokRow.indexOf('/models/build.execute') === -1,
    'the tag sits in the grok.default row');
});

test('C3: the role page ladder shows DIRECT on the vendor-direct rung only', () => {
  const route = routes.roles.find((x) => x.role === 'build.execute');
  const html = render(h(ModelRoleView, {
    role: 'build.execute', project: null,
    route: { ladder: route.ladder, source: 'hub', scope_version: 1, provenance: [] },
    hub: null, row: rows().find((x) => x.role === 'build.execute'), prices, runners, changes: [], truncated: false,
    error: null, dialog: null, busy: null, note: null, onDismissNote: noop,
    actions: { saveLadder: noop, resetOverride: noop }
  }));
  assert.equal(count(html, '>DIRECT<'), 1, 'exactly one DIRECT tag');
  const at = html.indexOf('>DIRECT<');
  assert.ok(html.lastIndexOf('grok-4.7', at) > html.lastIndexOf('claude-opus-5', at), 'the tag follows the grok-4.7 rung, not the opus one');
});
