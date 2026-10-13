import test from 'node:test';
import assert from 'node:assert/strict';
import { call, worker, iso } from '../lib/harness.js';

// RELATIVE FIXTURES (#360, BH-1261). Nothing here asserts on a particular
// calendar date — `minute` and `at` are the row's own timestamps and `acked_at`
// only has to be non-null — so freezing them bought nothing and cost the
// determinism lint a finding. `iso` is the harness's single anchored clock
// read. Note that `?since=<id>` on this route is a ROW-ID watermark, not a time
// window; it shares a name with one, which is why the lint looked here at all.
const MINUTES = 60e3;
const WAKE = (over) => ({
  id: 5, repo: 'example-org/project-3', kind: 'pr', key: '41', event: 'pull_request',
  minute: iso(21 * MINUTES), at: iso(20 * MINUTES), acked_at: null, ...over
});

test('wakes feed: no bearer, no wakes', async () => {
  const r = await call('/api/wakes', { secret: null });
  assert.equal(r.status, 401);
});

test('wakes feed: bare GET returns the UNACKED backlog', async () => {
  const state = { wakes: [WAKE(), WAKE({ id: 6, acked_at: iso(60 * MINUTES) })] };
  const r = await call('/api/wakes', { state });
  assert.equal(r.status, 200);
  assert.deepEqual(r.body.wakes.map((w) => w.id), [5]);
  const sql = r.db._calls.find((c) => /FROM wakes/.test(c.sql)).sql;
  assert.match(sql, /acked_at IS NULL/);
  assert.match(sql, /ORDER BY id ASC/);
});

test('wakes feed: ?since is a watermark, and it ignores the ack column', async () => {
  // The loop's correctness rests on its OWN watermark: a row it already ran but
  // failed to ack must not come back, or a redelivery storm turns into repeat
  // launches of paid lanes.
  const state = { wakes: [
    WAKE({ id: 5, acked_at: iso(60 * MINUTES) }),
    WAKE({ id: 6 }), WAKE({ id: 7 }),
  ] };
  const r = await call('/api/wakes?since=5&repo=example-org/project-3', { state });
  assert.deepEqual(r.body.wakes.map((w) => w.id), [6, 7]);
  const sql = r.db._calls.find((c) => /FROM wakes/.test(c.sql)).sql;
  assert.ok(!/acked_at IS NULL/.test(sql), 'a watermark query must not also filter on the ack');
  assert.ok(/LIMIT [1-9]\d*$/.test(sql), `limit must stay positive, got: ${sql}`);
});

test('wakes ack: marks only the named rows, and only the unacked ones', async () => {
  const r = await call('/api/wakes/ack', { method: 'POST', body: { ids: [5, 6] },
    state: { wakes: [WAKE(), WAKE({ id: 6 })] } });
  assert.equal(r.status, 200);
  const upd = r.db._calls.find((c) => /UPDATE wakes SET acked_at/.test(c.sql));
  assert.ok(upd, 'the ack must write');
  assert.match(upd.sql, /acked_at IS NULL/);
  assert.match(upd.sql, /id IN \(\?2,\?3\)/);
  const bad = await call('/api/wakes/ack', { method: 'POST', body: { ids: [] } });
  assert.equal(bad.status, 400);
});

test('wakes ack: a big backlog is acked in slices under the D1 bind limit', async () => {
  // D1 allows 100 bound parameters per statement. The loop acks up to 500 ids
  // at once; one IN (...) over all of them threw (worker 1101) on every tick
  // that drained more than 99 wakes, and the unacked backlog never shrank.
  const ids = Array.from({ length: 250 }, (_, i) => 1000 + i);
  const r = await call('/api/wakes/ack', { method: 'POST', body: { ids },
    state: { wakes: ids.map((id) => WAKE({ id })) } });
  assert.equal(r.status, 200);
  const upds = r.db._calls.filter((c) => /UPDATE wakes SET acked_at/.test(c.sql));
  assert.equal(upds.length, 3, 'expected 99 + 99 + 52');
  for (const u of upds) {
    const holes = (u.sql.match(/\?\d+/g) || []).length;
    assert.ok(holes <= 100, `a slice bound ${holes} params: ${u.sql.slice(0, 80)}`);
  }
  assert.equal(r.body.acked, 3, 'one change per slice from the fake db, summed');
});
