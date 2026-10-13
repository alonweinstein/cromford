import { test } from 'node:test';
import assert from 'node:assert/strict';
import { stageProgress, buildLane, stageLabel } from '../src/lib/stages.js';

// BH-3971. bin/reconcile-prs.sh gives a PR GitHub closed WITHOUT merging its
// own terminal, `pr_closed` (BH-866), and bin/builds-merged-sweep.sh moves the
// rows that were wrongly stamped merged (project-3 TK-166, PR #331) to it. Mission
// Control did not know the word: an unknown stage is step 0 and not dead, so a
// closed PR was drawn as still building. It is stopped, and nothing shipped.
test('a build at pr_closed is stopped, and never done', () => {
  const p = stageProgress('pr_closed', 0);
  assert.equal(p.dead, true);
  assert.equal(p.done, false);
});

test('a build at pr_closed sits in the dead lane', () => {
  assert.equal(buildLane({ stage: 'pr_closed', merged: 0 }), 'dead');
});

test('pr_closed reads "closed without merging"', () => {
  assert.equal(stageLabel('pr_closed'), 'closed without merging');
});

test('control: a merged build is still done', () => {
  assert.equal(stageProgress('pr_merged', 1).done, true);
  assert.equal(stageProgress('pr_merged', 1).dead, false);
});
