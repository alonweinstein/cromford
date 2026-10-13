import test from 'node:test';
import assert from 'node:assert/strict';
import { LANE, RULE, call, iso, now } from '../lib/harness.js';
import { decorateLane } from '../../src/index.js';

const LANEROW = (over) => ({
  project: 'project-7', box: 'box-project-6-1', cadence_min: 10, offset_min: 1,
  expected_since: iso(30 * 86400e3), retired_at: null,
  last_tick_at: iso(120e3), last_tick_kind: 'skip', alerted_at: null,
  updated_at: iso(120e3), ...over
});

const laneOf = (r, project = 'project-7') => r.body.lanes.find((l) => l.project === project);

test('a lane that ticked a moment ago is live, and carries the threshold it was judged against', async () => {
  const r = await call('/api/lanes', { state: { lanes: [LANEROW()] } });
  assert.equal(r.status, 200);
  const l = laneOf(r);
  assert.equal(l.state, 'live');
  assert.equal(l.stale, false);
  // Ages are computed against the SERVER clock at request time, so they are
  // asserted within a few seconds rather than to the second — a fixture minted
  // at module load and read a second later is not a bug.
  assert.ok(Math.abs(l.tick_age_s - 120) <= 10, `tick age ${l.tick_age_s}`);
  // Three missed ticks on a 10-minute cadence. The number rides on the row so a
  // reader never has to guess which threshold produced the verdict.
  assert.equal(l.stale_after_s, 1800);
});

test('an expected lane silent past its threshold is stale', async () => {
  const r = await call('/api/lanes', { state: { lanes: [LANEROW({ last_tick_at: iso(40 * 60e3) })] } });
  const l = laneOf(r);
  assert.equal(l.state, 'stale');
  assert.equal(l.stale, true);
  assert.ok(Math.abs(l.silence_s - 2400) <= 10, `silence ${l.silence_s}`);
});

test('THE INCIDENT: ten hours of silence on a declared lane is stale, not invisible', async () => {
  const r = await call('/api/lanes', { state: { lanes: [LANEROW({ last_tick_at: iso(10 * 3600e3) })] } });
  assert.equal(laneOf(r).state, 'stale');
});

test('a lane that has NEVER ticked goes stale on the same clock, from expected_since', async () => {
  // The incident's twin: a lane enrolled in fleet.conf whose box never ran
  // bootstrap. There is no last tick to age, so the expectation itself is aged
  // — otherwise a lane that never started would read healthy forever.
  const never = await call('/api/lanes', {
    state: { lanes: [LANEROW({ last_tick_at: null, last_tick_kind: null, expected_since: iso(45 * 60e3) })] }
  });
  const l = laneOf(never);
  assert.equal(l.state, 'stale');
  assert.equal(l.never_ticked, true);
  assert.equal(l.tick_age_s, null, 'a lane that never ticked has no tick age to report');
  assert.ok(Math.abs(l.silence_s - 2700) <= 10, `silence ${l.silence_s}`);
});

test('a freshly declared lane that has not ticked YET is pending, not stale', async () => {
  // Enrolment is not an incident. A lane declared four minutes ago has not had
  // its first tick, and paging on that would teach the reader to ignore this.
  const r = await call('/api/lanes', {
    state: { lanes: [LANEROW({ last_tick_at: null, last_tick_kind: null, expected_since: iso(240e3) })] }
  });
  assert.equal(laneOf(r).state, 'pending');
  assert.equal(laneOf(r).stale, false);
});

test('a retired lane is never stale — it is not supposed to be ticking', async () => {
  const r = await call('/api/lanes', {
    state: { lanes: [LANEROW({ retired_at: iso(3600e3), last_tick_at: iso(20 * 3600e3) })] }
  });
  assert.equal(laneOf(r).state, 'retired');
  assert.equal(laneOf(r).stale, false);
  assert.equal(laneOf(r).expected, false);
});

test('a lane that ticks without ever being declared is UNEXPECTED, never stale', async () => {
  // A box beating a lane fleet.conf has never heard of is worth SEEING, but it
  // cannot be judged against an expectation nobody made.
  const r = await call('/api/lanes', {
    state: { lanes: [LANEROW({ expected_since: null, last_tick_at: iso(9 * 3600e3) })] }
  });
  assert.equal(laneOf(r).state, 'unexpected');
  assert.equal(laneOf(r).stale, false);
});

test('a slower cadence gets proportionally more rope, never less than 30 minutes', async () => {
  const slow = await call('/api/lanes', {
    state: { lanes: [LANEROW({ cadence_min: 60, last_tick_at: iso(100 * 60e3) })] }
  });
  assert.equal(laneOf(slow).stale_after_s, 10800, 'three missed ticks at a 60-minute cadence');
  assert.equal(laneOf(slow).state, 'live');
  // A cadence faster than the floor does not shrink the window: a lane is not
  // dead for missing one tick, whatever its cadence says.
  const fast = await call('/api/lanes', { state: { lanes: [LANEROW({ cadence_min: 1 })] } });
  assert.equal(laneOf(fast).stale_after_s, 1800);
});

test('?stale=1 answers only the lanes an alert would be about', async () => {
  const state = { lanes: [
    LANEROW(),
    LANEROW({ project: 'project-3', box: 'box-project-3-2', last_tick_at: iso(2 * 3600e3) }),
    LANEROW({ project: 'dead-os', box: 'box-dead', retired_at: iso(60e3), last_tick_at: iso(5 * 3600e3) })
  ] };
  const r = await call('/api/lanes?stale=1', { state });
  assert.deepEqual(r.body.lanes.map((l) => l.project), ['project-3']);
});

test('the expected set upserts one row per lane and keeps the original expected_since', async () => {
  const r = await call('/api/lanes', {
    method: 'PUT',
    state: { lanes: [LANEROW()] },
    body: { lanes: [
      { project: 'project-7', box: 'box-project-6-1', cadence_min: 10, offset_min: 1 },
      { project: 'project-3', box: 'box-project-3-2', cadence_min: 10, offset_min: 6 }
    ], actor: 'box-hub' }
  });
  assert.equal(r.status, 200);
  assert.equal(r.body.expected, 2);
  const ups = r.db._calls.filter((c) => /INSERT INTO lanes/.test(c.sql));
  assert.equal(ups.length, 2, 'one upsert per declared lane');
  assert.deepEqual(ups[0].binds.slice(0, 4), ['project-7', 'box-project-6-1', 10, 1]);
  // A re-declared lane must not have its expected_since bumped: the clock the
  // never-ticked rule ages is exactly this column, and resetting it on every
  // 10-minute push would make a lane that never started look permanently fresh.
  assert.match(ups[0].sql, /COALESCE\(lanes\.expected_since/);
});

test('a lane dropped from fleet.conf is RETIRED, never deleted', async () => {
  const r = await call('/api/lanes', {
    method: 'PUT',
    state: { lanes: [LANEROW(), LANEROW({ project: 'gone-os', box: 'box-gone' })] },
    body: { lanes: [{ project: 'project-7', box: 'box-project-6-1', cadence_min: 10, offset_min: 1 }] }
  });
  assert.equal(r.status, 200);
  const retire = r.db._calls.find((c) => /UPDATE lanes SET retired_at/.test(c.sql));
  assert.ok(retire, 'the sync must retire what it no longer declares');
  assert.match(retire.sql, /NOT IN/);
  assert.ok(retire.binds.includes('project-7|box-project-6-1'),
    'the surviving lane is excluded from the retirement sweep');
  // An UNDECLARED row was never expected, so "retired" says nothing true about
  // it — the sweep must leave it alone.
  assert.match(retire.sql, /expected_since IS NOT NULL/);
});

test('an EMPTY expected set retires nothing — a mid-rsync fleet.conf must not un-watch the fleet', async () => {
  // The same judgement bin/fleet-status-push.sh already makes about pushing an
  // empty fleet: silence is the signal, and an empty push that looked healthy
  // is the most reassuring possible shape for a total outage.
  const r = await call('/api/lanes', { method: 'PUT', body: { lanes: [] }, state: { lanes: [LANEROW()] } });
  assert.equal(r.status, 400);
  assert.match(r.body.error, /empty/i);
  assert.equal(r.db._calls.filter((c) => /UPDATE lanes SET retired_at/.test(c.sql)).length, 0);
});

test('a lane name that would not survive a round trip is refused', async () => {
  for (const bad of [{ project: '', box: 'b' }, { project: 'p', box: '' },
    { project: 'p/../x', box: 'b' }, { project: 'p', box: 'b b' }]) {
    const r = await call('/api/lanes', { method: 'PUT', body: { lanes: [bad] } });
    assert.equal(r.status, 400, `${JSON.stringify(bad)} must be refused`);
  }
});

test('A SKIP TICK IS A HEARTBEAT: the lane is alive even when it does no LLM work', async () => {
  // The gate skipping an unchanged board is the NORMAL shape of a quiet lane —
  // most ticks on most boards are skips. If only the expensive ticks counted,
  // every healthy quiet lane would page.
  const r = await call('/api/lanes/tick', {
    method: 'POST',
    state: { lanes: [LANEROW({ last_tick_at: iso(9 * 60e3), last_tick_kind: 'run' })] },
    body: { project: 'project-7', box: 'box-project-6-1', kind: 'skip' }
  });
  assert.equal(r.status, 200);
  const w = r.db._calls.find((c) => /INSERT INTO lanes/.test(c.sql));
  assert.deepEqual(w.binds.slice(0, 3), ['project-7', 'box-project-6-1', 'skip']);
  // A tick declares NOTHING about expectation: a box cannot enrol itself, and a
  // retired lane that is still ticking must not quietly un-retire.
  assert.doesNotMatch(w.sql, /expected_since=/);
  assert.doesNotMatch(w.sql, /retired_at=/);
  // ...and it must not clear an alert either, or the recovery notice the
  // watchdog owes the operator would never be emitted.
  assert.doesNotMatch(w.sql, /alerted_at=/);
});

test('a tick from a box nobody declared still lands, and reads unexpected', async () => {
  const r = await call('/api/lanes/tick', {
    method: 'POST', state: { lanes: [] },
    body: { project: 'brand-new', box: 'box-x', kind: 'start' }
  });
  assert.equal(r.status, 200);
  assert.ok(r.db._calls.some((c) => /INSERT INTO lanes/.test(c.sql)));
});

test('a tick without a project or a box is refused, not written under a blank key', async () => {
  for (const bad of [{ box: 'b' }, { project: 'p' }, { project: 'p', box: 'b/c' }]) {
    const r = await call('/api/lanes/tick', { method: 'POST', body: bad });
    assert.equal(r.status, 400, `${JSON.stringify(bad)} must be refused`);
  }
});

test('a process beat writes the proc columns and NEVER the cron ones', async () => {
  const r = await call('/api/lanes/tick', {
    method: 'POST', state: { lanes: [] },
    body: { project: 'hb.merge-conductor', box: 'box-hub', event: 'beat',
            pid: 4242, interval_s: 300, note: 'waiting on CI' }
  });
  assert.equal(r.status, 200);
  const w = r.db._calls.find((c) => /INSERT INTO lanes/.test(c.sql));
  assert.match(w.sql, /proc_beat_at=/, 'the beat must land on the process clock');
  assert.doesNotMatch(w.sql, /last_tick_at=/, 'a beating process must not make a dead CRON read alive');
  assert.doesNotMatch(w.sql, /expected_since=/);
  assert.doesNotMatch(w.sql, /retired_at=/);
  assert.doesNotMatch(w.sql, /alerted_at=/, 'a beat must not swallow the reaper\'s recovery notice');
  assert.ok(w.binds.includes(4242), 'the pid rides along as evidence');
  // THE DECLARED RHYTHM IS THE LAUNCH'S, NOT THE BEAT'S. The stale threshold is
  // derived from this column, so a beat that overwrote it would move the
  // threshold of every lane that declares one (blocked-resolver declares 1800)
  // down to whatever the beat happened to carry — a healthy 40-minute fix round
  // reading `silent` while the file on the box says fresh.
  assert.match(w.sql, /proc_interval_s=COALESCE\(lanes\.proc_interval_s, ?\?6\)/,
    'the row\'s declared rhythm wins over anything a beat carries');
});

test('a launch clears the previous instance\'s exit; a clean exit stamps one', async () => {
  const start = await call('/api/lanes/tick', {
    method: 'POST', state: { lanes: [] },
    body: { project: 'hb.wake-loop', box: 'box-hub', event: 'start',
            pid: 7, interval_s: 60, expect_s: 3600 }
  });
  const s = start.db._calls.find((c) => /INSERT INTO lanes/.test(c.sql));
  assert.match(s.sql, /proc_ended_at=NULL/,
    'a relaunch after a clean exit must not keep reading ended, or its next death never pages');
  assert.match(s.sql, /proc_deadline_at=/);

  const done = await call('/api/lanes/tick', {
    method: 'POST', state: { lanes: [] },
    body: { project: 'hb.wake-loop', box: 'box-hub', event: 'done', pid: 7 }
  });
  const d = done.db._calls.find((c) => /INSERT INTO lanes/.test(c.sql));
  assert.match(d.sql, /proc_ended_at=/);
  assert.doesNotMatch(d.sql, /last_tick_at=/);
});

test('a bare tick with no event is byte-for-byte what it always was', async () => {
  // The whole slice is additive or it is a regression: a box running an older
  // bin/ sends no event, and must write exactly the row it wrote yesterday.
  const r = await call('/api/lanes/tick', {
    method: 'POST', state: { lanes: [] },
    body: { project: 'project-7', box: 'box-project-6-1', kind: 'skip' }
  });
  const w = r.db._calls.find((c) => /INSERT INTO lanes/.test(c.sql));
  assert.match(w.sql, /last_tick_at=/);
  assert.doesNotMatch(w.sql, /proc_/, 'a cron tick touches no process column');
});

test('the default lanes list excludes process rows; the proc filters ask for them', async () => {
  // Every reader that exists today asks "what does fleet.conf say should be
  // ticking", and a process row is not an answer to that: letting hb.* rows
  // into the default list would have bin/jobs-watchdog.sh resolve a latch it
  // never set, and show the console lanes fleet.conf never declared.
  const state = { lanes: [
    LANEROW(),
    LANEROW({ project: 'hb.merge-conductor', box: 'box-hub', expected_since: null,
              proc_pid: 9, proc_interval_s: 300, proc_beat_at: iso(3600e3) })
  ] };
  const plain = await call('/api/lanes', { state });
  assert.deepEqual(plain.body.lanes.map((l) => l.project), ['project-7']);

  const procs = await call('/api/lanes?proc=1', { state });
  assert.deepEqual(procs.body.lanes.map((l) => l.project), ['hb.merge-conductor']);

  const stale = await call('/api/lanes?proc_stale=1', { state });
  assert.deepEqual(stale.body.lanes.map((l) => l.project), ['hb.merge-conductor']);
  assert.equal(stale.body.lanes[0].proc_state, 'silent');
  // ...and a CRON-stale filter is unchanged by any of this.
  const cron = await call('/api/lanes?stale=1', { state });
  assert.deepEqual(cron.body.lanes.map((l) => l.project), []);
});

test('the alert latch is set and cleared on the lane it names', async () => {
  const on = await call('/api/lanes/alert', {
    method: 'PATCH', state: { lanes: [LANEROW()] },
    body: { project: 'project-7', box: 'box-project-6-1', alerted: true }
  });
  assert.equal(on.status, 200);
  const set = on.db._calls.find((c) => /UPDATE lanes SET alerted_at/.test(c.sql));
  assert.match(set.sql, /alerted_at=\?1/);
  assert.equal(typeof set.binds[0], 'string', 'setting the latch stamps a time');
  assert.ok(set.binds.includes('project-7') && set.binds.includes('box-project-6-1'),
    'the write must name the lane it latches, never every lane');

  const off = await call('/api/lanes/alert', {
    method: 'PATCH', state: { lanes: [LANEROW({ alerted_at: iso(60e3) })] },
    body: { project: 'project-7', box: 'box-project-6-1', alerted: false }
  });
  assert.equal(off.status, 200);
  const clr = off.db._calls.find((c) => /UPDATE lanes SET alerted_at/.test(c.sql));
  assert.equal(clr.binds[0], null, 'clearing the latch writes NULL, so recovery can fire again later');
});

test('the latch cannot be set on a lane that does not exist', async () => {
  const r = await call('/api/lanes/alert', {
    method: 'PATCH', state: { lanes: [] },
    body: { project: 'ghost', box: 'box-nowhere', alerted: true }
  });
  assert.equal(r.status, 404);
});

test('A REVIVED LANE GETS A FULL THRESHOLD, not an instant page with the wrong diagnosis', () => {
  // Retire/revive PRESERVES last_tick_at — the row is kept, that is the point —
  // so a project dropped from fleet.conf months ago and added back today comes
  // back carrying an ancient tick. Aging that tick would make the lane `stale`
  // on the very first read: a page within five minutes, blaming a lost crontab,
  // on the exact event an operator is standing there watching. The revive
  // restarts expected_since (the PUT's CASE ... WHEN retired_at IS NOT NULL),
  // and that newer clock is the one that counts.
  //
  // Driven through decorateLane rather than the API so the assertion is about
  // the RULE and cannot be satisfied by a fixture that happens to omit a field.
  const t = '2026-08-30T12:00:00Z';
  const revived = decorateLane({
    project: 'project-7', box: 'box-project-6-1', cadence_min: 10,
    last_tick_at: '2026-05-01T09:00:00Z',   // four months old, from its first life
    expected_since: '2026-08-30T11:58:00Z', // re-declared two minutes ago
    retired_at: null, alerted_at: null, updated_at: t
  }, t);
  assert.equal(revived.state, 'pending',
    'a revived lane has not ticked under the expectation now in force');
  assert.equal(revived.stale, false, 'reviving a lane must not page instantly');
  assert.equal(revived.silence_s, 120, 'silence runs from the re-declaration, not the old tick');
  assert.equal(revived.ticked_since_declared, false);
  // The old tick is still REPORTED — it is a true fact about the lane, and the
  // console shows it. It is just not what the threshold is measured against.
  assert.ok(revived.tick_age_s > 10e6, 'the ancient tick is still visible');
  assert.equal(revived.never_ticked, false, 'it HAS ticked, once, in a previous life');

  // ...and it still goes stale on its own merits if it never comes back.
  const stillDead = decorateLane({
    project: 'project-7', box: 'box-project-6-1', cadence_min: 10,
    last_tick_at: '2026-05-01T09:00:00Z',
    expected_since: '2026-08-30T11:00:00Z', // re-declared an hour ago, no tick since
    retired_at: null, alerted_at: null, updated_at: t
  }, t);
  assert.equal(stillDead.state, 'stale');
  assert.equal(stillDead.ticked_since_declared, false,
    'the alert must be able to say "not since it was re-declared", not "never"');
});

test('the later clock wins on every OTHER path too — this is not a special case', () => {
  const t = '2026-08-30T12:00:00Z';
  // A normally ticking lane: the tick is the later one, so nothing changes.
  const live = decorateLane({
    project: 'a', box: 'b', cadence_min: 10, last_tick_at: '2026-08-30T11:58:00Z',
    expected_since: '2026-07-01T00:00:00Z', retired_at: null, updated_at: t
  }, t);
  assert.equal(live.state, 'live');
  assert.equal(live.silence_s, 120);
  assert.equal(live.ticked_since_declared, true);
  // Never ticked at all: the declaration is the only clock there is.
  const never = decorateLane({
    project: 'a', box: 'b', cadence_min: 10, last_tick_at: null,
    expected_since: '2026-08-30T11:00:00Z', retired_at: null, updated_at: t
  }, t);
  assert.equal(never.state, 'stale');
  assert.equal(never.never_ticked, true);
  assert.equal(never.silence_s, 3600);
});
