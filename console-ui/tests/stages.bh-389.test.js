import { test } from 'node:test';
import assert from 'node:assert/strict';
import { stageProgress, buildLane } from '../src/lib/stages.js';

// BH-389. bin/blocked-resolver.sh closes a PR unmerged when it supersedes it
// with a fresh rebuild or abandons the ticket, and it now beats that build row
// to `superseded` or `abandoned` with merged:false. Before this the console had
// no such stage: an unknown stage is step 0 and not dead, so a closed PR was
// drawn as "still building", and nothing on the row said it had stopped.
for (const stage of ['superseded', 'abandoned']) {
  test(`a build at ${stage} is stopped, and never done`, () => {
    const p = stageProgress(stage, 0);
    assert.equal(p.dead, true, `${stage} must be drawn as stopped`);
    assert.equal(p.done, false, `${stage} is a PR closed unmerged: nothing shipped`);
    assert.equal(p.label, stage);
  });

  test(`the lane of a build at ${stage} is dead, not building`, () => {
    assert.equal(buildLane({ stage, merged: 0 }), 'dead');
  });
}

test('a merged build is still done — the guard the two stages above must not move', () => {
  assert.equal(stageProgress('pr_merged', 0).done, true);
  assert.equal(stageProgress('pr_merged', 0).dead, false);
  assert.equal(buildLane({ stage: 'pr_created', merged: 0, tier: 2 }), 'review');
});
