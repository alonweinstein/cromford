import { test } from 'node:test';
import assert from 'node:assert/strict';
import { stageProgress, buildLane, STEPS, VERDICT_TONE } from '../src/lib/stages.js';

// The stages a BUILD EVENT carries (#520) are a finer vocabulary than the beats
// the hub writes, and the strip has to read both: a build sitting on the
// `executing` beat for twelve minutes has in fact passed the size gate, gone
// red, gone green and run semgrep, and the strip that only knows beats says
// "execute" the whole time.
test('event stages land on the step the pipeline is really at', () => {
  assert.equal(stageProgress('tests_red').step, stageProgress('executing').step);
  assert.equal(stageProgress('tests_green').step, stageProgress('executing').step);
  assert.equal(stageProgress('semgrep').step, stageProgress('reviewing').step);
  assert.equal(stageProgress('fix_round').step, stageProgress('reviewing').step);
  assert.equal(stageProgress('e2e').step, stageProgress('qa').step);
  assert.equal(stageProgress('pr_opened').step, stageProgress('pr_created').step);
  // The tier decision is the last gate before the PR is opened, not a QA step.
  assert.equal(stageProgress('tier').step, 4);
  // The size gate rules on the PLAN: nothing has been built when it runs.
  assert.equal(stageProgress('size_gate').step, 0);

  for (const s of ['plan', 'size_gate', 'tests_red', 'execute', 'tests_green',
    'semgrep', 'review', 'fix_round', 'e2e', 'tier', 'pr_opened']) {
    assert.equal(stageProgress(s).known, true, `${s} is a stage the build emits`);
    assert.equal(stageProgress(s).dead, false, `${s} is progress, not a stopped build`);
  }
});

test('an event the strip does not know leaves it where it was', () => {
  // `done` is the terminal marker: its verdict is the job's status, and mapping
  // it to a step would paint a FAILED build as merged.
  for (const s of ['done', 'frobnicate']) {
    const p = stageProgress(s);
    assert.equal(p.known, false, `${s} must not move the strip`);
    assert.equal(p.step, 0, `${s} must not claim progress`);
  }
});

test('the verdicts the live log colours all have a tone', () => {
  assert.equal(VERDICT_TONE.PASS, 'green');
  assert.equal(VERDICT_TONE.FAIL, 'red');
  assert.equal(VERDICT_TONE.BUDGET_STOP, 'warn');
  assert.equal(VERDICT_TONE.APPROVE, 'green', 'the review verdicts stay as they were');
  assert.equal(VERDICT_TONE.BLOCK, 'red');
});

test('the Fly lane stages map onto real pipeline steps, not onto zero', () => {
  // pool_spawned / fly_dispatched mean a machine has the ticket and is
  // executing; showing them at "plan" would make every Fly build look stuck.
  assert.equal(stageProgress('pool_spawned').step, stageProgress('executing').step);
  assert.equal(stageProgress('fly_dispatched').step, stageProgress('executing').step);
  assert.equal(stageProgress('pool_result').step, stageProgress('reviewing').step);
});

test('a pool deferral is known, at zero, and not a dead end', () => {
  // bin/fly-pool.sh beats pool_deferred when a machine stood down before it
  // built anything (2026-09-11) and re-queues the ticket. An unknown stage
  // renders as "unknown"; a dead one says the card will never move again.
  // Neither is true here — the work is going back on the queue.
  const d = stageProgress('pool_deferred');
  assert.equal(d.known, true, 'a stage the fleet beats must be in the vocabulary');
  assert.equal(d.step, 0, 'nothing was built, so nothing progressed');
  assert.equal(d.dead, false, 'the ticket is re-queued, not stopped');
});

test('a blocked, stale or untraced plan is a dead end, not 20% progress', () => {
  for (const s of ['plan_blocked', 'plan_stale', 'plan_deferred', 'plan_malformed']) {
    assert.equal(stageProgress(s).dead, true, `${s} must read as stopped`);
  }
  assert.equal(stageProgress('planning').dead, false);
});

test('merged is complete however it got there', () => {
  assert.equal(stageProgress('pr_created', 1).percent, 100);
  assert.equal(stageProgress('pr_merged', 0).done, true);
  assert.equal(stageProgress('tier2_sweep_merged', 0).done, true);
});

test('an unknown stage renders at the start and says it is unknown', () => {
  const p = stageProgress('some_new_stage_we_have_not_seen');
  assert.equal(p.known, false);
  assert.equal(p.step, 0);
  assert.equal(p.total, STEPS.length);
});

test('tier decides the lane, not the presence of a PR', () => {
  const base = { stage: 'pr_created', merged: 0 };
  assert.equal(buildLane({ ...base, tier: 1, verdict: 'APPROVE' }), 'merge_queue');
  assert.equal(buildLane({ ...base, tier: 2, verdict: 'APPROVE' }), 'review', 'tier 2 waits on a human');
  assert.equal(buildLane({ ...base, tier: 1, verdict: null }), 'review', 'tier 1 without a verdict waits too');
});

test('lanes for the non-PR states', () => {
  assert.equal(buildLane({ stage: 'executing', merged: 0 }), 'building');
  assert.equal(buildLane({ stage: 'plan_blocked', merged: 0 }), 'dead');
  assert.equal(buildLane({ stage: 'pr_created', merged: 1 }), 'merged');
});
