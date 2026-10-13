import test from 'node:test';
import assert from 'node:assert/strict';
import { pricedModels, makeModelActions, gapRows, modelRows, spendPlan } from '../src/lib/models.js';

// BH-1563 — the console half of the #1560 round-2 follow-ups:
//   #8 a project-tab save made on the INHERITED hub ladder carries the hub's
//      scope_version too, so a hub edit in another tab cannot land underneath
//      it; a project that owns its override sends only its own version,
//      because a hub edit does not affect it.
//   #9 the gapped scopes the worker now lists become rows with links, so an
//      operator can reach and repair a scope the resolver hides.
// Fixtures name model ids on purpose (console-ui/tests is lint-exempt).

const prices = {
  per_token: {
    'claude-opus-5': { prompt: 0.000005, completion: 0.000025 },
    'claude-opus-5-5': { prompt: 0.000005, completion: 0.000025 }
  }
};
const priced = new Set(pricedModels(prices));
const runners = ['claude', 'codex', 'openrouter', 'grok', 'fireworks'];
const hubLadder = [{ position: 0, model: 'claude-opus-5', runner: 'claude' }];
const draft = [{ model: 'claude-opus-5-5', runner: 'claude' }];

function harness({ status = null } = {}) {
  const calls = { write: [], reset: [], refresh: 0, notes: [] };
  const throwing = () => { const e = new Error('nope'); e.status = status.code; e.body = status.body; throw e; };
  const actions = makeModelActions({
    confirm: async () => true,
    writeLadder: async (body) => { calls.write.push(body); if (status) throwing(); },
    resetLadder: async (body) => { calls.reset.push(body); if (status) throwing(); },
    refresh: () => { calls.refresh += 1; },
    onNote: (n) => calls.notes.push(n)
  });
  return { actions, calls };
}

// ───────────────────────────────────────────────── #8: what the save sends

test('a project save made on the INHERITED hub ladder carries both expected_version and expected_hub_version', async () => {
  const { actions, calls } = harness();
  await actions.saveLadder({
    role: 'build.qa', project: 'project-4', before: hubLadder, draft, priced, runners,
    source: 'hub', version: 0, hubVersion: 41
  });
  assert.equal(calls.write.length, 1);
  assert.equal(calls.write[0].expected_version, 0, 'the project owns nothing yet, and 0 is a real version');
  assert.equal(calls.write[0].expected_hub_version, 41, 'the hub ladder this edit was based on');
});

test('a project save on the project\'s OWN override carries expected_version only — a hub edit is irrelevant to it', async () => {
  const { actions, calls } = harness();
  await actions.saveLadder({
    role: 'build.qa', project: 'project-4', before: hubLadder, draft, priced, runners,
    source: 'project', version: 12, hubVersion: 41
  });
  assert.equal(calls.write[0].expected_version, 12);
  assert.ok(!('expected_hub_version' in calls.write[0]), JSON.stringify(calls.write[0]));
});

test('a HUB save never carries expected_hub_version (the hub write\'s own guard is expected_version)', async () => {
  const { actions, calls } = harness();
  await actions.saveLadder({
    role: 'build.qa', project: null, before: hubLadder, draft, priced, runners,
    source: 'hub', version: 9, hubVersion: 9
  });
  assert.equal(calls.write[0].expected_version, 9);
  assert.ok(!('expected_hub_version' in calls.write[0]), JSON.stringify(calls.write[0]));
});

test('a hubVersion the read did not carry is left out rather than sent as a guess', async () => {
  const { actions, calls } = harness();
  await actions.saveLadder({
    role: 'build.qa', project: 'project-4', before: hubLadder, draft, priced, runners,
    source: 'hub', version: 0, hubVersion: undefined
  });
  assert.ok(!('expected_hub_version' in calls.write[0]), JSON.stringify(calls.write[0]));
});

test('a 409 that names the HUB says the hub ladder moved, reloads, and never reads as written', async () => {
  const { actions, calls } = harness({ status: { code: 409, body: { stale: 'hub', hub_scope_version: 42 } } });
  const res = await actions.saveLadder({
    role: 'build.qa', project: 'project-4', before: hubLadder, draft, priced, runners,
    source: 'hub', version: 0, hubVersion: 41
  });
  assert.equal(res.status, 'stale');
  assert.match(res.message, /hub ladder/i);
  assert.match(res.message, /not written/);
  assert.equal(calls.refresh, 1);
  assert.equal(calls.notes.at(-1).ok, false);
});

test('a 409 with no stale field keeps today\'s message — the project\'s own ladder moved', async () => {
  const { actions, calls } = harness({ status: { code: 409, body: null } });
  const res = await actions.saveLadder({
    role: 'build.qa', project: null, before: hubLadder, draft, priced, runners, source: 'hub', version: 3
  });
  assert.equal(res.status, 'stale');
  assert.match(res.message, /this ladder changed since you loaded it/);
  assert.doesNotMatch(res.message, /hub ladder/i);
  assert.equal(calls.refresh, 1);
});

// ─────────────────────────────────────────────── #9: the gapped scopes

test('gapRows turns the worker\'s gaps into linkable rows, one per scope, hub and project', () => {
  const rows = gapRows({
    gaps: [
      { project: null, role: 'triage', positions: [1, 3] },
      { project: 'project-4', role: 'build.qa', positions: [2] }
    ]
  });
  assert.equal(rows.length, 2);
  assert.deepEqual(rows[0], { project: null, role: 'triage', positions: [1, 3], href: '/models/triage', label: 'hub / triage (rungs 1, 3)' });
  assert.equal(rows[1].href, '/models/build.qa?project=project-4');
  assert.equal(rows[1].label, 'project-4 / build.qa (rungs 2)');
});

test('no gaps, or a read that predates the field, is an empty list — never a banner about nothing', () => {
  assert.deepEqual(gapRows({ gaps: [] }), []);
  assert.deepEqual(gapRows({}), []);
  assert.deepEqual(gapRows(null), []);
});

test('modelRows carries the worker\'s per-role gapped flag onto the row', () => {
  const routes = {
    roles: [
      { role: 'build.qa', source: 'hub', ladder: hubLadder, gapped: true },
      { role: 'triage', source: 'hub', ladder: hubLadder, gapped: false },
      { role: 'orchestrate', source: 'hub', ladder: hubLadder }
    ]
  };
  const plan = spendPlan(routes.roles.map((r) => r.role), null);
  const rows = modelRows({ routes, prices, spend: {}, plan, project: null });
  assert.deepEqual(rows.map((r) => r.gapped), [true, false, false]);
});
