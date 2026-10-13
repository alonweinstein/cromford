import test from 'node:test';
import assert from 'node:assert/strict';
import { call } from '../lib/harness.js';

test('the review gate needs the same bearer as everything else', async () => {
  const res = await call('/api/review-gate', { secret: null });
  assert.equal(res.status, 401);
});

test('one GET carries the gates AND the thresholds they were judged against', async () => {
  const res = await call('/api/review-gate', {
    state: {
      gates: [{ repo: 'o/a', tightened: 1, rate: 0.3, tighten_rate: 0.2 }],
      thresholds: [{ scope: '*', window_days: 14, tighten_rate: 0.2, clear_rate: 0.1 }]
    }
  });
  assert.equal(res.status, 200);
  // Fetched separately they could arrive from different seconds, and a rate
  // rendered beside a threshold it was never judged against is the one way the
  // console screen could lie.
  assert.equal(res.body.gates[0].repo, 'o/a');
  assert.equal(res.body.thresholds[0].scope, '*');
});

test('a gate PUT needs a repo and an explicit tightened flag', async () => {
  assert.equal((await call('/api/review-gate', { method: 'PUT', body: { tightened: 1 } })).status, 400);
  // Absent is not "off": a detector that forgot the field must not silently
  // release a parked repo.
  assert.equal((await call('/api/review-gate', { method: 'PUT', body: { repo: 'o/a' } })).status, 400);
});

test('tightened_at survives the daily re-measurements that keep a repo parked', async () => {
  const res = await call('/api/review-gate', {
    method: 'PUT',
    body: { repo: 'o/a', tightened: 1, rate: 0.3, bad: 3, merges: 10, decision: 'tighten' },
    state: { gates: [{ repo: 'o/a', tightened: 1, tightened_at: '2026-08-01T00:00:00Z' }] }
  });
  assert.equal(res.status, 200);
  const sql = res.db._calls.map((c) => c.sql).find((q) => /INSERT INTO review_gate /.test(q));
  // Restamping it every run would make every parked repo look like it had just
  // failed, and nobody could tell a week-old park from this morning's.
  assert.match(sql, /WHEN review_gate\.tightened = 1 THEN review_gate\.tightened_at/);
  // ...and a release clears it, so a stale timestamp cannot outlive the park.
  assert.match(sql, /WHEN \?2 = 0 THEN NULL/);
});

test('an inverted threshold pair is REFUSED, not clamped', async () => {
  const res = await call('/api/review-gate/thresholds', {
    method: 'PUT',
    body: { scope: '*', window_days: 14, min_merges: 5, tighten_rate: 0.1, clear_rate: 0.5 }
  });
  assert.equal(res.status, 400);
  assert.match(res.body.error, /clear_rate must be <= tighten_rate/);
});

test('out-of-range thresholds are refused with the range named', async () => {
  const base = { scope: '*', window_days: 14, min_merges: 5, tighten_rate: 0.2, clear_rate: 0.1 };
  const bad = async (over, re) => {
    const res = await call('/api/review-gate/thresholds', { method: 'PUT', body: { ...base, ...over } });
    assert.equal(res.status, 400);
    assert.match(res.body.error, re);
  };
  await bad({ window_days: 0 }, /window_days/);
  await bad({ window_days: 4000 }, /window_days/);
  await bad({ min_merges: 0 }, /min_merges/);
  // A tighten_rate of 0 would park every repo in the fleet on its first run.
  await bad({ tighten_rate: 0 }, /tighten_rate/);
  await bad({ tighten_rate: 1.5 }, /tighten_rate/);
  await bad({ clear_rate: -1 }, /clear_rate/);
  await bad({ scope: '' }, /scope/);
});

test('a legal threshold row is stored under its scope', async () => {
  const res = await call('/api/review-gate/thresholds', {
    method: 'PUT',
    body: { scope: 'o/a', window_days: 21, min_merges: 8, tighten_rate: 0.25, clear_rate: 0.1, note: 'hot repo' }
  });
  assert.equal(res.status, 200);
  const put = res.db._calls.find((c) => /INSERT INTO review_gate_thresholds/.test(c.sql));
  assert.deepEqual(put.binds.slice(0, 5), ['o/a', 21, 8, 0.25, 0.1]);
});
