import test from 'node:test';
import assert from 'node:assert/strict';
import { render } from 'preact-render-to-string';
import { h } from 'preact';
import { ModelsView, stageRunnerColumns } from '../src/screens/Models.js';
import { modelRows, spendPlan, screenCoverage } from '../src/lib/models.js';
import { sortRows } from '../src/lib/sort.js';

// BH-1766 (BH-1749.4) — the stage.* roles (which runner each build stage uses,
// and its fallback) render on /models as their own STAGE RUNNERS group, a
// sortable list whose rows link to the role page and its #history. Rendered for
// real through ModelsView and read back; fixtures carry model ids
// (console-ui/tests is lint-exempt).

const prices = {
  per_token: {
    'claude-opus-5': { prompt: 0.000005, completion: 0.000025 },
    'claude-fable-5-1': { prompt: 0.000015, completion: 0.000075 },
    'gpt-6-astra': { prompt: 0.0000025, completion: 0.00001 },
    'grok-4.6': { prompt: 0.000003, completion: 0.000015 }
  }
};
const runners = ['claude', 'codex', 'openrouter', 'grok', 'fireworks'];

const routes = {
  project: null, runners,
  roles: [
    { role: 'build.execute', source: 'hub', ladder: [{ position: 0, model: 'claude-opus-5', runner: 'claude', updated_by: 'op' }] },
    {
      role: 'stage.triage', source: 'hub', ladder: [
        { position: 0, model: 'grok-4.6', runner: 'grok', updated_by: 'hub' },
        { position: 1, model: 'gpt-6-astra', runner: 'codex', updated_by: 'hub' }
      ]
    },
    // Role order (execute, plan, triage) differs from runner order (claude,
    // grok, openrouter), so a runner sort that sorted by role would show.
    { role: 'stage.execute', source: 'hub', ladder: [{ position: 0, model: 'claude-opus-5', runner: 'openrouter', updated_by: 'op' }] },
    {
      role: 'stage.plan', source: 'hub', ladder: [
        { position: 0, model: 'claude-fable-5-1', runner: 'claude', updated_by: 'seed' },
        { position: 1, model: 'gpt-6-astra', runner: 'codex', updated_by: 'seed' }
      ]
    }
  ]
};

const rowsFor = (r) => {
  const plan = spendPlan(r.roles.map((x) => x.role), null);
  const spend = {};
  for (const q of plan.queries) spend[q.key] = { usd: 1, calls: 1 };
  return modelRows({ routes: r, prices, spend, plan, project: null });
};

const view = (r = routes) => {
  const rows = rowsFor(r);
  return render(h(ModelsView, {
    tabs: [{ id: 'hub', label: 'HUB' }], activeTab: 'hub', rows, coverage: screenCoverage(rows),
    error: null, loading: false, asOf: '2026-09-24T00:00:00Z', onTab: () => {}, onReload: () => {}
  }));
};

const HEAD = 'STAGE RUNNERS';

test('U1: stage.* roles render in their own STAGE RUNNERS group, not in the main roles table', () => {
  const html = view();
  const at = html.indexOf(HEAD);
  assert.ok(at > 0, 'no STAGE RUNNERS heading');
  const [before, after] = [html.slice(0, at), html.slice(at)];
  assert.ok(before.includes('build.execute'), 'build.execute belongs to the main table');
  assert.ok(!before.includes('stage.triage'), 'stage.triage leaked into the main table');
  assert.ok(after.includes('>stage.triage<'), 'stage.triage missing from the group');
  assert.ok(after.includes('grok'), 'runner grok missing from the group');
  assert.ok(after.includes('codex'), 'fallback runner missing from the group');

  const none = view({ ...routes, roles: routes.roles.filter((x) => !x.role.startsWith('stage.')) });
  assert.ok(!none.includes(HEAD), 'the group renders with no stage rows');
});

test('U2: the group is a sortable table, role asc by default; the runner header sorts both ways', () => {
  const html = view();
  const group = html.slice(html.indexOf(HEAD));
  const ths = group.match(/<th[^>]*>[\s\S]*?<\/th>/g) || [];
  assert.equal(ths.length, stageRunnerColumns.length);
  for (const [i, col] of stageRunnerColumns.entries()) {
    if (col.sort === null) continue;
    assert.match(ths[i], /aria-sort=/, `${col.label} header has no aria-sort`);
    assert.match(ths[i], /<button/, `${col.label} header is not a button`);
  }
  assert.ok(group.indexOf('>stage.execute<') < group.indexOf('>stage.plan<'), 'default sort is not role asc');
  assert.ok(group.indexOf('>stage.plan<') < group.indexOf('>stage.triage<'), 'default sort is not role asc');

  const rows = rowsFor(routes).filter((r) => r.role.startsWith('stage.'));
  const col = stageRunnerColumns.find((c) => c.key === 'runner');
  assert.deepEqual(sortRows(rows, col.sort, 'asc').map((r) => r.runner), ['claude', 'grok', 'openrouter']);
  assert.deepEqual(sortRows(rows, col.sort, 'desc').map((r) => r.runner), ['openrouter', 'grok', 'claude']);
  const fb = stageRunnerColumns.find((c) => c.key === 'fallback');
  assert.equal(fb.sort(rows.find((r) => r.role === 'stage.triage')), 'codex');
  // One rung, no fallback: the cell says none, and the sort sinks it (null).
  assert.equal(fb.sort(rows.find((r) => r.role === 'stage.execute')), null);
  assert.match(group.slice(group.indexOf('>stage.execute<')), /<span class="na">none<\/span>/);
});

test('U3: every stage row links to its role page and its #history — no dead rows', () => {
  const html = view();
  const group = html.slice(html.indexOf(HEAD));
  for (const role of ['stage.triage', 'stage.plan', 'stage.execute']) {
    assert.ok(group.includes(`href="/models/${role}"`), `${role} has no role link`);
    assert.ok(group.includes(`href="/models/${role}#history"`), `${role} has no history link`);
  }
  const trs = group.match(/<tbody>[\s\S]*?<\/tbody>/)[0].match(/<tr[\s\S]*?<\/tr>/g);
  assert.equal(trs.length, 3);
  for (const tr of trs) assert.match(tr, /href="\/models\/stage\./);
});

test('U4: the SPEND ATTRIBUTION note the screen passes leaves the stage roles out', () => {
  const rows = rowsFor(routes);
  const cov = screenCoverage(rows);
  const all = [...cov.exact, ...cov.shared, ...cov.partial, ...cov.none];
  assert.ok(all.includes('build.execute'));
  assert.ok(!all.some((r) => r.startsWith('stage.')), JSON.stringify(cov));
  const html = view();
  const note = html.slice(html.indexOf('SPEND ATTRIBUTION'));
  assert.ok(!note.includes('stage.triage'));
});
