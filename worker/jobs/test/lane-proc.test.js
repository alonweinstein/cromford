import test from 'node:test';
import assert from 'node:assert/strict';
import { decorateLane } from '../src/index.js';

// ── The PROCESS half of one liveness fact (BH-1031, state→DB slice 6) ────────
//
// THE CASE THIS EXISTS FOR, stated once: a long-lived lane process dies on a
// box whose CRON is perfectly healthy. Before this slice the fleet had three
// different answers to "is that lane alive", and none of them could be read by
// the machine that needed the answer:
//
//   state/heartbeat/<lane>.<pid>.json  — only readable on the box that wrote
//     it, so it goes blind at exactly the moment that matters (the box is gone).
//   bin/fleet-heartbeat.sh             — ssh'd every box to stat a log file,
//     which answered "can the hub reach it", not "is the lane alive". Its own
//     comments said so, and it is deleted in this slice.
//   the `lanes` row                    — answered a third thing again: did the
//     CRON fire.
//
// So the process fact lands on the lanes row too, on its own clock, and the
// assertions below are about the one thing that makes it a fix rather than a
// fourth answer: a fresh cron tick must NEVER make a dead process read healthy.
//
// A pid is evidence, not a test — the worker cannot probe a process on another
// machine — so the vocabulary here is SILENCE and the expected-by, and the
// box-local reaper keeps the `kill -0`.

const T = '2026-09-19T12:00:00Z';
const ago = (s) => new Date(Date.parse(T) - s * 1000).toISOString().replace(/\.\d{3}Z$/, 'Z');

// A row as the tick route writes one: the cron half ticking normally.
const cronAlive = {
  project: 'hb.merge-conductor', box: 'box-hub', cadence_min: 10,
  last_tick_at: ago(60), expected_since: '2026-09-01T00:00:00Z',
  retired_at: null, alerted_at: null, updated_at: T,
};

test('a dead PROCESS on a box whose cron still ticks is stale — the two clocks are judged apart', () => {
  const row = decorateLane({
    ...cronAlive,
    proc_pid: 4242, proc_started_at: ago(7200), proc_interval_s: 300,
    proc_beat_at: ago(1800),          // six missed beats
    proc_deadline_at: null, proc_ended_at: null, proc_note: 'waiting on CI',
  }, T);
  // The cron half is untouched and still says the box is fine — which it is.
  assert.equal(row.state, 'live', 'the crontab is firing; nothing about that changed');
  assert.equal(row.stale, false);
  // ...and the process half is the fact that used to have nowhere to live.
  assert.equal(row.proc_state, 'silent');
  assert.equal(row.proc_stale, true, 'a lane process that stopped beating must read stale');
  assert.equal(row.proc_age_s, 1800);
  assert.equal(row.proc_stale_after_s, 900, 'three missed beats of the rhythm it declared');
  assert.equal(row.proc_pid, 4242, 'the pid rides along so the page names what to go look for');
});

test('a beating process is fresh, and the threshold comes from the rhythm IT declared', () => {
  const beating = decorateLane({
    ...cronAlive, proc_pid: 7, proc_interval_s: 300, proc_beat_at: ago(120),
    proc_started_at: ago(3600), proc_ended_at: null,
  }, T);
  assert.equal(beating.proc_state, 'fresh');
  assert.equal(beating.proc_stale, false);

  // A slow lane is not judged on a fast lane's clock: 20 minutes of silence is
  // dead for a 5-minute rhythm and perfectly healthy for a 30-minute one.
  const slow = decorateLane({
    ...cronAlive, proc_pid: 7, proc_interval_s: 1800, proc_beat_at: ago(1200),
    proc_started_at: ago(7200), proc_ended_at: null,
  }, T);
  assert.equal(slow.proc_state, 'fresh');
  assert.equal(slow.proc_stale_after_s, 5400);

  // ...and a lane that declares a 1-second rhythm (WAKE_LOOP_INTERVAL_S=0 reads
  // as 1) is not called dead for one slow pass: the floor holds.
  const fast = decorateLane({
    ...cronAlive, proc_pid: 7, proc_interval_s: 1, proc_beat_at: ago(300),
    proc_started_at: ago(600), proc_ended_at: null,
  }, T);
  assert.equal(fast.proc_stale_after_s, 600, 'the floor, not three seconds');
  assert.equal(fast.proc_stale, false);
});

test('a clean exit is not a death, and a relaunch after one is alive again', () => {
  // hb_done stamps proc_ended_at. Without this rule every completed run would
  // page the moment its beats aged out, which is the fastest way to teach an
  // operator to ignore the channel.
  const finished = decorateLane({
    ...cronAlive, proc_pid: 9, proc_interval_s: 300,
    proc_beat_at: ago(7200), proc_ended_at: ago(7200), proc_started_at: ago(10800),
  }, T);
  assert.equal(finished.proc_state, 'ended');
  assert.equal(finished.proc_stale, false, 'finishing on purpose must never page');

  // The next launch beats AFTER the recorded exit, so the row is live again
  // with nobody clearing anything by hand.
  const relaunched = decorateLane({
    ...cronAlive, proc_pid: 11, proc_interval_s: 300,
    proc_started_at: ago(120), proc_beat_at: ago(60), proc_ended_at: ago(7200),
  }, T);
  assert.equal(relaunched.proc_state, 'fresh');

  // ...and the instance that replaced it can die like any other.
  const diedAfterRelaunch = decorateLane({
    ...cronAlive, proc_pid: 11, proc_interval_s: 300,
    proc_started_at: ago(7200), proc_beat_at: ago(3600), proc_ended_at: ago(10800),
  }, T);
  assert.equal(diedAfterRelaunch.proc_state, 'silent');
  assert.equal(diedAfterRelaunch.proc_stale, true);
});

test('past its expected-by is stale even while it beats; no expected-by never is', () => {
  // A lane can tick on rhythm for ever and still be wedged — the deadline is
  // the half of the file contract that catches that, and it survives the move.
  const overdue = decorateLane({
    ...cronAlive, proc_pid: 3, proc_interval_s: 300, proc_beat_at: ago(60),
    proc_started_at: ago(7200), proc_deadline_at: ago(600), proc_ended_at: null,
  }, T);
  assert.equal(overdue.proc_state, 'overdue');
  assert.equal(overdue.proc_stale, true);

  // A loop that runs for ever on purpose declares expect_s 0 -> no deadline,
  // and must never read overdue.
  const forever = decorateLane({
    ...cronAlive, proc_pid: 3, proc_interval_s: 300, proc_beat_at: ago(60),
    proc_started_at: ago(864000), proc_deadline_at: null, proc_ended_at: null,
  }, T);
  assert.equal(forever.proc_state, 'fresh');
  assert.equal(forever.proc_stale, false);
});

test('a lane with no process half at all is untouched — this is additive', () => {
  // Every row in the live table today. The proc columns are NULL, so the fact
  // is `none` and nothing about the cron verdict moves.
  const cronOnly = decorateLane(cronAlive, T);
  assert.equal(cronOnly.proc_state, 'none');
  assert.equal(cronOnly.proc_stale, false);
  assert.equal(cronOnly.proc_age_s, null);
  assert.equal(cronOnly.state, 'live', 'the cron verdict is exactly what it was');
});
