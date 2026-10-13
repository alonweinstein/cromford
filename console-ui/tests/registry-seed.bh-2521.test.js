import test from 'node:test';
import assert from 'node:assert/strict';
import {
  planView, planRows, laneHref, confirmCopy, confirmOpts, applyOutcome, submitApply, requestApply,
  runsView, SEED_RUNS_LIMIT
} from '../src/lib/registry-seed.js';

// BH-2677 (BH-2521.2): the SEED REGISTRY panel's pure half. Every payload is a
// shape the BH-2521 wire contract names: GET settings/seed-registry/plan (the
// worker's seedRegistryPlan plus plan_fp), POST settings/seed-registry/apply
// (400 / 409 fleet_gate / 409 plan_moved / 200 {id, actor, ...runSeed}) and
// GET settings/seed-registry/runs.

const FP = 'ab'.repeat(32);
const PLAN = {
  rows: 5, insert: ['lane.a.x'], update: [{ key: 'lane.b.y', from: '1', to: '2' }], prune: ['lib.c.z'],
  operator_owned: 1, unchanged: 1, actor: 'registry-seed', as_of: '2026-09-26T10:00:00Z', plan_fp: FP
};
const httpError = (status, body) => Object.assign(new Error(body && body.error ? body.error : `http_${status}`), { status, body });

test('1: planView refuses a broken plan and counts a good one', () => {
  for (const bad of [null, 'x', { insert: [], prune: [], plan_fp: FP }, { insert: [], update: [], prune: [] },
    { ...PLAN, plan_fp: 'A'.repeat(64) }, { ...PLAN, plan_fp: 'a'.repeat(63) }, { ...PLAN, insert: 'lane.a.x' }]) {
    assert.throws(() => planView(bad), /bad response/, JSON.stringify(bad));
  }
  const v = planView(PLAN);
  assert.equal(v.plan_fp, FP);
  assert.equal(v.pending, 3);
  assert.equal(v.operator_owned, 1);
  assert.equal(v.unchanged, 1);
  assert.equal(planView({ insert: [], update: [], prune: [], plan_fp: FP }).pending, 0);
});

test('2: planRows gives key/action/from/to and invents no value for insert or prune', () => {
  assert.deepEqual(planRows(planView(PLAN)), [
    { key: 'lane.a.x', action: 'insert', from: null, to: null },
    { key: 'lane.b.y', action: 'update', from: '1', to: '2' },
    { key: 'lib.c.z', action: 'prune', from: null, to: null },
  ]);
});

test('3: a 409 fleet_gate names every box and how to exclude a retired one', () => {
  const out = applyOutcome({ error: httpError(409, { error: 'fleet_gate', boxes: [{ box: 'ops-1', reason: 'unreachable' }, { box: 'hub-2', reason: 'stale' }] }) });
  assert.equal(out.tone, 'bad');
  for (const s of ['ops-1', 'unreachable', 'hub-2', 'stale', 'harness-ctl.sh seed-registry --exclude-box', 'from the hub', 'nothing written']) {
    assert.ok(out.text.includes(s), `${s} in ${out.text}`);
  }
  const none = applyOutcome({ error: httpError(409, { error: 'fleet_gate' }) });
  assert.equal(none.tone, 'bad');
  assert.match(none.text, /Refused by the fleet gate/);
});

test('4: a 409 plan_moved says the plan changed', () => {
  const out = applyOutcome({ error: httpError(409, { error: 'plan_moved', plan: { ...PLAN, plan_fp: 'c'.repeat(64) } }) });
  assert.equal(out.tone, 'warn');
  assert.match(out.text, /The plan changed, re-read it\. Nothing was written\./);
});

test('5: a 200 with an id names the run and both counts', () => {
  const out = applyOutcome({ result: { id: 7, actor: 'operator@example.com', rows: 5, changed: 3, pruned: 1, changed_keys: [], pruned_keys: [] } });
  assert.deepEqual(out, { tone: 'ok', text: 'Applied #7: 3 changed, 1 pruned.' });
  assert.equal(applyOutcome({ result: { id: 8 } }).text, 'Applied #8: — changed, — pruned.');
});

test('6: a 200 with no id, a 400 and any other failure are failures', () => {
  const noId = applyOutcome({ result: { changed: 3 } });
  assert.equal(noId.tone, 'bad');
  assert.doesNotMatch(noId.text, /Applied/);
  assert.equal(applyOutcome({ result: null }).tone, 'bad');
  const bad = applyOutcome({ error: httpError(400, { error: 'bad plan_fp' }) });
  assert.deepEqual(bad, { tone: 'bad', text: 'Apply failed: bad plan_fp' });
  assert.equal(applyOutcome({ error: httpError(409, { error: 'other' }) }).tone, 'bad');
  assert.equal(applyOutcome({ error: new Error('network unreachable') }).text, 'Apply failed: network unreachable');
});

test('7: runsView reads a stale or undated started row as outcome unknown, never applied', () => {
  const now = Date.parse('2026-09-26T12:00:00Z');
  const at = (min) => new Date(now - min * 60000).toISOString();
  const payload = { truncated: true, runs: [
    { id: 1, status: 'applied', started_at: at(30) },
    { id: 2, status: 'failed', started_at: at(30) },
    { id: 3, status: 'started', started_at: at(2) },
    { id: 4, status: 'started', started_at: at(11) },
    { id: 5, status: 'started', started_at: null },
    { id: 6, status: 'weird', started_at: at(1) },
    { id: 7, status: 'started', started_at: Math.floor((now - 60000) / 1000) },
  ] };
  const v = runsView(payload, now);
  assert.deepEqual(v.rows.map((r) => r.display),
    ['applied', 'failed', 'in progress', 'outcome unknown', 'outcome unknown', 'outcome unknown', 'in progress']);
  assert.equal(v.truncated, true);
  assert.equal(runsView({ runs: [], truncated: 'true' }).truncated, false);
  for (const bad of [null, {}, { runs: 'x' }]) assert.throws(() => runsView(bad, now), /bad response/);
  assert.equal(SEED_RUNS_LIMIT, 20);
});

test('8: confirmCopy carries the counts; only an explicit true sends, once, with the plan_fp', async () => {
  const plan = planView(PLAN);
  assert.equal(confirmCopy(plan), 'Applies the registry seed: 1 inserts, 1 updates, 1 prunes. Rows an operator owns are never touched.');
  assert.deepEqual(confirmOpts(plan), { title: 'SEED REGISTRY', body: confirmCopy(plan), confirmLabel: 'APPLY', tone: 'warn' });
  const sent = [];
  const apiObj = { seedApply: async (fp) => { sent.push(fp); return { id: 9, changed: 1, pruned: 0 }; } };
  for (const x of [false, 'true', 1, undefined, null]) {
    assert.equal(await submitApply(apiObj, plan, x, 'why'), null);
  }
  assert.equal(sent.length, 0);
  const out = await submitApply(apiObj, plan, true, 'why');
  assert.deepEqual(sent, [FP]);
  assert.equal(out.tone, 'ok');
  const failing = { seedApply: async () => { throw httpError(409, { error: 'plan_moved' }); } };
  assert.equal((await submitApply(failing, plan, true, 'why')).tone, 'warn');
  // The whole flow: a cancel reloads nothing, a confirm reloads once.
  let reloads = 0;
  assert.equal(await requestApply({ apiObj, plan, confirm: async () => false, reload: () => reloads++ }), null);
  assert.equal(reloads, 0);
  await requestApply({ apiObj, plan, confirm: async (o) => { o.form.reason = 'why'; return true; }, reload: () => reloads++ });
  assert.equal(reloads, 1);
});

test('9: laneHref links a lane key to its settings view and nothing else', () => {
  assert.equal(laneHref('lane.fly-pool.test_impact_gate_cap'), '/settings/fly-pool');
  assert.equal(laneHref('lib.x.y'), null);
  assert.equal(laneHref('garbage'), null);
  assert.equal(laneHref('lane..x'), null);
  assert.equal(laneHref(null), null);
});
