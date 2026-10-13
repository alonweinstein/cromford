import test from 'node:test';
import assert from 'node:assert/strict';
import { changeRows } from '../src/lib/models.js';

// BH-1928: an empty hub remove writes a TOMBSTONE audit row — position 0,
// before AND after NULL — so the seeds skip the role on the next deploy. The
// MODELS history table must call that row what it is, a removal. Before, the
// "before is null" check won and the row read "added".
test('C1: a both-null tombstone row reads "removed"; added / removed / changed keep their labels', () => {
  const rows = changeRows([
    { id: 4, position: 0, before_model: null, before_runner: null, after_model: null, after_runner: null, actor: 'op' },
    { id: 3, position: 0, before_model: 'a', before_runner: 'claude', after_model: null, after_runner: null },
    { id: 2, position: 0, before_model: null, before_runner: null, after_model: 'a', after_runner: 'claude' },
    { id: 1, position: 1, before_model: 'a', before_runner: 'claude', after_model: 'b', after_runner: 'claude' }
  ]);
  assert.deepEqual(rows.map((r) => r.kind), ['removed', 'removed', 'added', 'changed']);
  assert.equal(rows[0].anchor, 'change-4');
});
