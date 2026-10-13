import test from 'node:test';
import assert from 'node:assert/strict';
import { autohaltTrips } from '../src/lib/cost-breaker.js';

// BH-5526: the breaker now writes spend-hold-<project>, not the human pause
// paused-<project>. The COST BREAKER card lists both: hold rows, and older
// paused-<project> rows the breaker wrote before this change.

const row = (name, reason, active = 1, extra = {}) => ({ name, active, reason, ...extra });

test('a spend-hold-<project> row with a breaker reason is a HOLD trip', () => {
  const t = autohaltTrips({ flags: [
    row('spend-hold-project-9', '$154/PR over 7d (cost autohalt)', 1,
      { updated_at: '2026-10-08T12:00:00Z', actor: 'pipeline-health' })
  ] });
  assert.equal(t.unreadable, false);
  assert.deepEqual(t.trips, [{
    project: 'project-9', kind: 'hold', reason: '$154/PR over 7d (cost autohalt)',
    since: '2026-10-08T12:00:00Z', actor: 'pipeline-health'
  }]);
});

test('a zero-merge hold row is a trip too', () => {
  const t = autohaltTrips({ flags: [row('spend-hold-zm', '$700 spend with 0 merged PR(s) over 7d (zero-merge breaker)', '1')] });
  assert.deepEqual(t.trips.map((r) => [r.project, r.kind]), [['zm', 'hold']]);
});

test('hold rows that are not a project, inactive, or not the breaker are not trips', () => {
  const t = autohaltTrips({ flags: [
    row('spend-hold-all', 'q (cost autohalt)'),
    row('spend-hold-box-x', 'q (cost autohalt)'),
    row('spend-hold-lane-y', 'q (cost autohalt)'),
    row('spend-hold-gamma', 'z (cost autohalt)', 0),
    row('spend-hold-delta', 'held by hand for a vendor bill'),
  ] });
  assert.deepEqual(t.trips, []);
});

test('a legacy paused-<project> breaker row is still listed, as a PAUSE', () => {
  const t = autohaltTrips({ flags: [
    row('paused-x', '$80/PR over 24h (cost autohalt)'),
    row('paused-project-1', 'a human pause'),
    row('spend-hold-x', '$80/PR over 24h (cost autohalt)'),
  ] });
  assert.deepEqual(t.trips.map((r) => [r.project, r.kind]), [['x', 'pause'], ['x', 'hold']]);
});
