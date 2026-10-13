// BH-4488: a build stopped at its hard budget cap reads as stopped on the
// Build page, not as still building.
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { stageProgress, buildLane, stageLabel, verdictLabel } from '../src/lib/stages.js';

test('budget_stop is a dead stage at the execute step', () => {
  const p = stageProgress('budget_stop', 0);
  assert.equal(p.dead, true);
  assert.equal(p.done, false);
});

test('budget_stop lands in the dead lane', () => {
  assert.equal(buildLane({ stage: 'budget_stop' }), 'dead');
});

test('budget_stop has its own label; the verdict keeps its label', () => {
  assert.equal(stageLabel('budget_stop'), 'stopped at its budget cap');
  assert.equal(verdictLabel('BUDGET_STOP'), 'stopped at its budget');
});

test('control: pr_merged is still done', () => {
  assert.equal(stageProgress('pr_merged', 0).done, true);
});
