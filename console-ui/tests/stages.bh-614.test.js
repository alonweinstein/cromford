import { test } from 'node:test';
import assert from 'node:assert/strict';
import { stageProgress, buildLane } from '../src/lib/stages.js';

// BH-614. bin/run-build.sh beats `pr_create_failed` when the create ladder comes
// back with no url: the build is approved, its branch is pushed, and there is no
// PR. The console had no such stage, so `known` was false, the step fell back to
// 0 and buildLane answered 'building' — a stopped build drawn as "still
// planning", which is how one sat unnoticed.
test('a build whose PR never opened is drawn at the PR step, and dead', () => {
  const p = stageProgress('pr_create_failed');
  assert.equal(p.known, true, 'the console must know the stage run-build beats');
  assert.equal(p.step, stageProgress('pr_created').step,
    'the build reached the PR step — that is how far the work got');
  assert.equal(p.dead, true, 'nothing moves it on without a rebuild');
  assert.equal(p.done, false, 'no PR means nothing shipped');
});

test('it is not in the set of events that leave the strip where it was', () => {
  // The negative for the test above: an unknown stage is step 0 and NOT dead, so
  // asserting dead=true alone would also pass if the stage stayed unknown.
  const unknown = stageProgress('frobnicate');
  assert.equal(unknown.known, false);
  assert.equal(unknown.dead, false);
  assert.notEqual(stageProgress('pr_create_failed').known, unknown.known);
});

test('the lane is dead, and a merge still wins over it', () => {
  assert.equal(buildLane({ stage: 'pr_create_failed', merged: 0 }), 'dead');
  // A record that later merged is merged, whatever beat it stopped on.
  assert.equal(buildLane({ stage: 'pr_create_failed', merged: 1 }), 'merged');
});
