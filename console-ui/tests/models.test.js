import test from 'node:test';
import assert from 'node:assert/strict';
import {
  ROLE_ATTRIBUTION, attributionFor, spendPlan, spendSince, perMillion, modelRows, coverage,
  pricedModels, validateLadder, ladderChanges, roleHref, changeRows, makeModelActions
} from '../src/lib/models.js';

// BH-1510.3 — the MODELS screen's logic, with the write path driven through
// stubs. The fixtures name real model ids on purpose: console-ui/tests is
// exempt from tests/model-literal-lint.sh (a fixture is not a hardcode), and
// console-ui/src is not — src/lib/models.js carries no model id at all.

// determinism: ok-file clock-now-js every time here is an OFFSET from one
// captured read; no case asserts a calendar date.
const NOW = Date.now();

const prices = {
  per_token: {
    'claude-opus-5': { prompt: 0.000005, completion: 0.000025 },
    'claude-opus-5-5': { prompt: 0.000005, completion: 0.000025 },
    'claude-fable-5-1': { prompt: 0.000015, completion: 0.000075 },
    'gpt-6-astra': { prompt: 0.0000025, completion: 0.00001 }
  }
};

const routes = {
  project: null,
  runners: ['claude', 'codex', 'openrouter', 'grok', 'fireworks'],
  roles: [
    { role: 'build.execute', source: 'hub', ladder: [{ position: 0, model: 'claude-opus-5', runner: 'claude', updated_by: 'seed', updated_at: '2026-09-22T00:00:00Z' }] },
    {
      role: 'orchestrate', source: 'hub', ladder: [
        { position: 0, model: 'claude-fable-5-1', runner: 'claude', updated_by: 'operator', updated_at: '2026-09-22T10:00:00Z' },
        { position: 1, model: 'claude-opus-5-5', runner: 'claude', updated_by: 'operator', updated_at: '2026-09-22T10:00:00Z' }
      ]
    },
    { role: 'auth.fallback', source: 'hub', ladder: [{ position: 0, model: 'claude-opus-5', runner: 'claude', updated_by: 'seed' }] },
    { role: 'codex.default', source: 'hub', ladder: [{ position: 0, model: 'gpt-6-astra', runner: 'codex', updated_by: 'seed' }] },
    { role: 'brand.new.role', source: 'hub', ladder: [{ position: 0, model: 'claude-opus-5-5', runner: 'claude', updated_by: 'op' }] }
  ]
};

// ─────────────────────────────────────────────────────── attribution

test('every role the #1510.0 seed names has an attribution entry — a new role is a visible gap, not a silent $0', () => {
  const seeded = ['build.execute', 'build.execute.fallback', 'build.review', 'build.qa', 'build.plan', 'plan',
    'triage', 'triage.light', 'triage.shard', 'decompose', 'orchestrate', 'alert.triage', 'product', 'greenfield',
    'rescue.review', 'postmerge.qa', 'auth.fallback', 'codex.default', 'grok.default', 'fireworks.default',
    'housekeeping.floor', 'bench'];
  for (const role of seeded) assert.ok(ROLE_ATTRIBUTION[role], `${role} has an entry`);
  const unknown = attributionFor('brand.new.role');
  assert.equal(unknown.kind, 'none');
  assert.match(unknown.note, /no attribution/i);
});

test('attribution kinds: exact, shared (names who it shares with), partial and none', () => {
  assert.equal(attributionFor('build.qa').kind, 'exact');
  assert.deepEqual(attributionFor('build.qa').filters, [{ stage: 'qa' }]);
  const review = attributionFor('build.review');
  assert.equal(review.kind, 'shared');
  assert.ok(review.shared.includes('rescue.review'), 'build.review names the role it shares the review stage with');
  assert.equal(attributionFor('greenfield').kind, 'partial');
  assert.equal(attributionFor('auth.fallback').kind, 'none');
  assert.deepEqual(attributionFor('codex.default').filters, [{ runner: 'codex' }]);
  assert.deepEqual(attributionFor('alert.triage').filters, [{ stage: 'triage', project: 'alert-triage' }]);
});

test('spendPlan dedups queries across roles, adds the project on a project tab, and marks pinned-project lanes n/a there', () => {
  const hub = spendPlan(['build.review', 'rescue.review', 'build.qa', 'auth.fallback'], null);
  const keys = hub.queries.map((q) => q.key);
  assert.equal(new Set(keys).size, keys.length, 'no duplicate query');
  assert.equal(hub.queries.filter((q) => q.params.stage === 'review').length, 1, 'two roles on one stage = one read');
  assert.deepEqual(hub.byRole['auth.fallback'].keys, []);

  const proj = spendPlan(['build.qa', 'alert.triage', 'bench'], 'project-4');
  const qa = proj.queries.find((q) => q.params.stage === 'qa');
  assert.equal(qa.params.project, 'project-4');
  assert.equal(proj.byRole['alert.triage'].kind, 'none', 'a hub-only lane has no spend on a project tab');
  assert.match(proj.byRole['alert.triage'].note, /hub/i);
  assert.equal(proj.queries.some((q) => q.params.project === 'alert-triage'), false, 'and is never queried there');
});

test('spendSince is seven days back in the cost ledger\'s own ts format (no milliseconds)', () => {
  const s = spendSince(NOW);
  assert.match(s, /^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z$/);
  const back = (NOW - Date.parse(s)) / 86400000;
  assert.ok(back >= 6.99 && back <= 7.01, `7 days back, got ${back}`);
});

// ───────────────────────────────────────────────────────────── rows

test('modelRows: one row per role, primary + failover ladder, runner, $/1M, spend and scope', () => {
  const plan = spendPlan(routes.roles.map((r) => r.role), null);
  const spend = {};
  for (const q of plan.queries) spend[q.key] = { usd: q.params.stage === 'execute' ? 42.5 : 1, calls: 3 };
  const rows = modelRows({ routes, prices, spend, plan, project: null });
  assert.equal(rows.length, 5);
  const exec = rows.find((r) => r.role === 'build.execute');
  assert.equal(exec.primary, 'claude-opus-5');
  assert.equal(exec.runner, 'claude');
  assert.deepEqual(exec.fallbacks, []);
  assert.equal(exec.price_in, 5);
  assert.equal(exec.price_out, 25);
  assert.equal(exec.usd_7d, 42.5);
  assert.equal(exec.calls_7d, 3);
  assert.equal(exec.source, 'hub');
  assert.equal(exec.seed, true, 'a rung still on its seed value is flagged');
  assert.equal(exec.href, '/models/build.execute');

  const orc = rows.find((r) => r.role === 'orchestrate');
  assert.deepEqual(orc.fallbacks.map((f) => f.model), ['claude-opus-5-5']);
  assert.equal(orc.seed, false);

  const auth = rows.find((r) => r.role === 'auth.fallback');
  assert.equal(auth.usd_7d, null, 'no attribution = unknown, never $0');
  assert.equal(auth.calls_7d, null);
});

test('modelRows: an unpriced model reads as unknown price, and a failed spend read as unknown spend', () => {
  const plan = spendPlan(['build.execute'], null);
  const rows = modelRows({
    routes: { roles: [{ role: 'build.execute', source: 'hub', ladder: [{ position: 0, model: 'mystery-model', runner: 'claude' }] }] },
    prices, plan, project: null,
    spend: { [plan.queries[0].key]: { error: 'http_502' } }
  });
  assert.equal(rows[0].price_in, null);
  assert.equal(rows[0].usd_7d, null);
  assert.equal(rows[0].spend_error, 'http_502');
});

test('coverage groups roles by how honestly their spend is attributed', () => {
  const plan = spendPlan(routes.roles.map((r) => r.role), null);
  const rows = modelRows({ routes, prices, spend: {}, plan, project: null });
  const c = coverage(rows);
  assert.ok(c.exact.includes('build.execute') || c.shared.includes('build.execute'));
  assert.ok(c.none.includes('auth.fallback'));
  assert.ok(c.none.includes('brand.new.role'));
});

test('roleHref keeps the project tab in the link', () => {
  assert.equal(roleHref('build.qa', null), '/models/build.qa');
  assert.equal(roleHref('build.qa', 'project-4'), '/models/build.qa?project=project-4');
});

// ───────────────────────────────────────────────────── edit validation

test('pricedModels lists every priced model id, sorted', () => {
  assert.deepEqual(pricedModels(prices), ['claude-fable-5-1', 'claude-opus-5', 'claude-opus-5-5', 'gpt-6-astra']);
  assert.deepEqual(pricedModels(null), []);
});

test('validateLadder refuses an empty ladder, an unpriced model and an unknown runner — before any modal', () => {
  const priced = new Set(pricedModels(prices));
  const runners = routes.runners;
  assert.equal(validateLadder([], priced, runners).ok, false);
  assert.match(validateLadder([{ model: 'nope', runner: 'claude' }], priced, runners).message, /not priced/);
  assert.match(validateLadder([{ model: 'claude-opus-5-5', runner: 'bogus' }], priced, runners).message, /runner/);
  const ok = validateLadder([{ model: ' claude-opus-5-5 ', runner: 'claude' }], priced, runners);
  assert.equal(ok.ok, true);
  assert.deepEqual(ok.ladder, [{ model: 'claude-opus-5-5', runner: 'claude' }]);
});

test('ladderChanges names only the rungs that moved, including added and removed rungs', () => {
  const before = [{ position: 0, model: 'a', runner: 'claude' }, { position: 1, model: 'b', runner: 'claude' }];
  assert.deepEqual(ladderChanges(before, [{ model: 'a', runner: 'claude' }, { model: 'b', runner: 'claude' }]), []);
  const ch = ladderChanges(before, [{ model: 'c', runner: 'codex' }]);
  assert.deepEqual(ch, [
    { position: 0, before: { model: 'a', runner: 'claude' }, after: { model: 'c', runner: 'codex' } },
    { position: 1, before: { model: 'b', runner: 'claude' }, after: null }
  ]);
  assert.deepEqual(ladderChanges([], [{ model: 'x', runner: 'grok' }]),
    [{ position: 0, before: null, after: { model: 'x', runner: 'grok' } }]);
});

test('changeRows labels each audit row added / removed / changed', () => {
  const rows = changeRows([
    { id: 3, position: 0, before_model: 'a', before_runner: 'claude', after_model: null, after_runner: null },
    { id: 2, position: 0, before_model: null, before_runner: null, after_model: 'a', after_runner: 'claude' },
    { id: 1, position: 1, before_model: 'a', before_runner: 'claude', after_model: 'b', after_runner: 'claude' }
  ]);
  assert.deepEqual(rows.map((r) => r.kind), ['removed', 'added', 'changed']);
  assert.equal(rows[0].anchor, 'change-3');
});

// ─────────────────────────────────────────────────────────── actions

function harness({ confirmAnswer = true, writeThrows = null } = {}) {
  const calls = { confirm: [], write: [], reset: [], refresh: 0, notes: [] };
  const actions = makeModelActions({
    confirm: async (opts) => { calls.confirm.push(opts); return confirmAnswer; },
    writeLadder: async (body) => { calls.write.push(body); if (writeThrows) throw new Error(writeThrows); },
    resetLadder: async (body) => { calls.reset.push(body); if (writeThrows) throw new Error(writeThrows); },
    refresh: () => { calls.refresh += 1; },
    onNote: (n) => calls.notes.push(n)
  });
  return { actions, calls };
}

const priced = new Set(pricedModels(prices));
const runners = routes.runners;
const seedLadder = [{ position: 0, model: 'claude-opus-5', runner: 'claude' }];

test('saving a ladder asks the in-app modal with before/after, then PUTs the whole ladder', async () => {
  const { actions, calls } = harness();
  const res = await actions.saveLadder({
    role: 'build.execute', project: null, before: seedLadder,
    draft: [{ model: 'claude-opus-5-5', runner: 'claude' }], priced, runners, reason: '#1507 carry-over'
  });
  assert.equal(res.status, 'written');
  assert.equal(calls.confirm.length, 1);
  assert.deepEqual(calls.confirm[0].changes, [
    { position: 0, before: { model: 'claude-opus-5', runner: 'claude' }, after: { model: 'claude-opus-5-5', runner: 'claude' } }
  ]);
  assert.match(calls.confirm[0].title, /BUILD\.EXECUTE/);
  assert.deepEqual(calls.write, [{
    role: 'build.execute', project: null, ladder: [{ model: 'claude-opus-5-5', runner: 'claude' }],
    actor: 'console', reason: '#1507 carry-over'
  }]);
  assert.equal(calls.refresh, 1);
  assert.equal(calls.notes.at(-1).ok, true);
});

test('a project save is an override: the modal says the hub is untouched, and the body carries the project', async () => {
  const { actions, calls } = harness();
  await actions.saveLadder({
    role: 'build.qa', project: 'project-4', before: seedLadder,
    draft: [{ model: 'claude-opus-5-5', runner: 'claude' }], priced, runners, source: 'hub'
  });
  assert.match(calls.confirm[0].note, /override/i);
  assert.equal(calls.write[0].project, 'project-4');
  assert.match(calls.write[0].reason, /Mission Control/, 'a default reason is always recorded');
});

test('cancel writes nothing; an invalid ladder never opens the modal; an unchanged ladder never writes', async () => {
  const c = harness({ confirmAnswer: false });
  const r1 = await c.actions.saveLadder({ role: 'build.qa', project: null, before: seedLadder, draft: [{ model: 'claude-opus-5-5', runner: 'claude' }], priced, runners });
  assert.equal(r1.status, 'cancelled');
  assert.equal(c.calls.write.length, 0);

  const i = harness();
  const r2 = await i.actions.saveLadder({ role: 'build.qa', project: null, before: seedLadder, draft: [{ model: 'nope', runner: 'claude' }], priced, runners });
  assert.equal(r2.status, 'invalid');
  assert.equal(i.calls.confirm.length, 0, 'asking a human to confirm what cannot be written is the wrong order');
  assert.equal(i.calls.write.length, 0);

  const u = harness();
  const r3 = await u.actions.saveLadder({ role: 'build.qa', project: null, before: seedLadder, draft: [{ model: 'claude-opus-5', runner: 'claude' }], priced, runners });
  assert.equal(r3.status, 'unchanged');
  assert.equal(u.calls.confirm.length, 0);
});

test('a refused write is reported as failed, never as written', async () => {
  const { actions, calls } = harness({ writeThrows: 'unknown model(s), not in model_prices: x' });
  const res = await actions.saveLadder({ role: 'build.qa', project: null, before: seedLadder, draft: [{ model: 'claude-opus-5-5', runner: 'claude' }], priced, runners });
  assert.equal(res.status, 'failed');
  assert.equal(calls.refresh, 0);
  assert.equal(calls.notes.at(-1).ok, false);
  assert.match(calls.notes.at(-1).text, /not in model_prices/);
});

test('reset to hub confirms with the project ladder going and the hub ladder coming, then POSTs the reset', async () => {
  const { actions, calls } = harness();
  const res = await actions.resetOverride({
    role: 'build.qa', project: 'project-4',
    current: [{ position: 0, model: 'claude-fable-5-1', runner: 'claude' }],
    hub: seedLadder
  });
  assert.equal(res.status, 'written');
  assert.deepEqual(calls.confirm[0].changes, [
    { position: 0, before: { model: 'claude-fable-5-1', runner: 'claude' }, after: { model: 'claude-opus-5', runner: 'claude' } }
  ]);
  assert.equal(calls.confirm[0].tone, 'warn');
  assert.deepEqual(calls.reset, [{ role: 'build.qa', project: 'project-4', actor: 'console', reason: 'reset to hub default from Mission Control' }]);
});

test('reset refuses on the hub tab rather than sending a write the worker would 400', async () => {
  const { actions, calls } = harness();
  const res = await actions.resetOverride({ role: 'build.qa', project: null, current: seedLadder, hub: seedLadder });
  assert.equal(res.status, 'invalid');
  assert.equal(calls.confirm.length, 0);
  assert.equal(calls.reset.length, 0);
});

test('perMillion turns a per-token rate into $/1M, and unknown stays unknown', () => {
  assert.equal(perMillion(0.000005), 5);
  assert.equal(perMillion(null), null);
  assert.equal(perMillion(undefined), null);
});

// ───────────────────────────── fix round 1: versions, stale writes, seed confirm

test('a save carries the scope_version it edited, so a second tab cannot silently overwrite it', async () => {
  const { actions, calls } = harness();
  await actions.saveLadder({ role: 'build.qa', project: null, before: seedLadder, version: 41,
    draft: [{ model: 'claude-opus-5-5', runner: 'claude' }], priced, runners });
  assert.equal(calls.write[0].expected_version, 41);
});

test('a 409 from the worker is "stale": the page reloads and says so, never "written"', async () => {
  const calls = { refresh: 0, notes: [] };
  const actions = makeModelActions({
    confirm: async () => true,
    writeLadder: async () => { const e = new Error('this ladder changed since you loaded it'); e.status = 409; throw e; },
    resetLadder: async () => {},
    refresh: () => { calls.refresh += 1; },
    onNote: (n) => calls.notes.push(n)
  });
  const res = await actions.saveLadder({ role: 'build.qa', project: null, before: seedLadder, version: 3,
    draft: [{ model: 'claude-opus-5-5', runner: 'claude' }], priced, runners });
  assert.equal(res.status, 'stale');
  assert.equal(calls.refresh, 1, 'the page reloads the ladder someone else wrote');
  assert.equal(calls.notes.at(-1).ok, false);
  assert.match(calls.notes.at(-1).text, /changed since you loaded it/);
});

test('an unchanged save says nothing was written (no silent dead click)', async () => {
  const { actions, calls } = harness();
  const res = await actions.saveLadder({ role: 'build.qa', project: null, before: seedLadder,
    draft: [{ model: 'claude-opus-5', runner: 'claude' }], priced, runners });
  assert.equal(res.status, 'unchanged');
  assert.match(calls.notes.at(-1).text, /nothing changed/i);
  assert.match(calls.notes.at(-1).text, /KEEP SEEDED VALUE/, 'and points at the real way to confirm a seed');
});

test('keep seeded value: confirm modal, then an audited PUT of the SAME ladder with confirm:true', async () => {
  const { actions, calls } = harness();
  const res = await actions.keepSeed({ role: 'auth.fallback', project: null, current: seedLadder, version: 7 });
  assert.equal(res.status, 'written');
  assert.match(calls.confirm[0].title, /KEEP/);
  assert.deepEqual(calls.confirm[0].changes, [
    { position: 0, before: { model: 'claude-opus-5', runner: 'claude' }, after: { model: 'claude-opus-5', runner: 'claude' } }
  ]);
  assert.deepEqual(calls.write, [{
    role: 'auth.fallback', project: null, ladder: [{ model: 'claude-opus-5', runner: 'claude' }],
    actor: 'console', reason: 'seed value reviewed and kept from Mission Control', confirm: true, expected_version: 7
  }]);
});

test('a reset carries the version of the override it is removing', async () => {
  const { actions, calls } = harness();
  await actions.resetOverride({ role: 'build.qa', project: 'project-4', current: seedLadder, hub: seedLadder, version: 12 });
  assert.equal(calls.reset[0].expected_version, 12);
});
