import test from 'node:test';
import assert from 'node:assert/strict';
import {
  matchBuildJob, mergeLive, shouldPollLive, liveSpend, gatesPassed,
  liveStep, subStage, logRows, pillClass, LIVE_EVENT_CAP
} from '../src/lib/live.js';

// The mission view is a cursor walk over a stream that can arrive late, out of
// order, twice, or not at all. Every one of these functions exists because the
// honest answer in one of those states is not the obvious one: an absent spend
// is not $0.00, an absent status is not "running", and a build whose job row we
// cannot find must say so rather than borrow the project's newest job.

const build = {
  id: 88,
  project: 'project-1',
  ticket_key: 'TK-7',
  bkey: 'build:project-1:TK-7:project-1-TK-7-1726',
  stage: 'executing',
  merged: 0,
  age_min: 4
};

const jobRow = (over) => ({
  id: 'job-a', kind: 'build', ticket_id: 'TK-7', status: 'running',
  meta: '{"build":"project-1-TK-7-1726","ticket_id":"TK-7"}',
  created_at: '2026-09-17T11:20:00Z', ...over
});

const ev = (id, stage, verdict, detail, at) => ({ id, stage, verdict, detail, at, actor: 'run-build' });

const EVENTS = [
  ev(11, 'plan', null, 'plan: 3 files, 140 lines, tests named', '2026-09-17T11:20:00Z'),
  ev(12, 'size_gate', 'PASS', 'size gate: M, one PR', '2026-09-17T11:21:00Z'),
  ev(13, 'tests_red', 'FAIL', 'tests red as required: 2 failing', '2026-09-17T11:22:00Z'),
  ev(14, 'execute', null, 'execute started', '2026-09-17T11:23:00Z'),
  ev(15, 'tests_green', 'PASS', 'tests green: 248 pass', '2026-09-17T11:25:00Z'),
  ev(16, 'semgrep', null, 'semgrep: 0 findings', '2026-09-17T11:26:00Z')
];

// --- matchBuildJob ----------------------------------------------------------

test('the build finds its job by ticket and build dir, not by being newest', () => {
  const older = jobRow({ id: 'job-right' });
  const newer = jobRow({ id: 'job-wrong', created_at: '2026-09-17T12:00:00Z', meta: '{"build":"project-1-TK-7-9999"}' });
  assert.equal(matchBuildJob(build, [newer, older]).id, 'job-right',
    'the dir in bkey is the exact join; a newer re-run of the same ticket is a different build');
});

test('with no dir match the newest job of the same ticket wins', () => {
  const a = jobRow({ id: 'job-old', meta: null, created_at: '2026-09-17T09:00:00Z' });
  const b = jobRow({ id: 'job-new', meta: null, created_at: '2026-09-17T11:00:00Z' });
  assert.equal(matchBuildJob(build, [a, b]).id, 'job-new');
});

test('a job that is not this build is never matched', () => {
  // Every one of these is a row that sits next to the right one in the same
  // `api.jobs` page. Borrowing any of them would show another ticket's spend.
  assert.equal(matchBuildJob(build, [jobRow({ kind: 'triage' })]), null, 'a triage job of the same ticket');
  assert.equal(matchBuildJob(build, [jobRow({ ticket_id: 'TK-9' })]), null, 'a build of another ticket');
  assert.equal(matchBuildJob(build, [jobRow({ ticket_id: 'TK-9', meta: '{"build":"project-1-TK-7-1726"}' })]), null,
    'a dir match cannot outrank a ticket mismatch');
  assert.equal(matchBuildJob(build, []), null, 'an empty page is not a match');
  assert.equal(matchBuildJob(build, null), null);
  assert.equal(matchBuildJob({ ...build, ticket_key: null }, [jobRow()]), null, 'a row with no ticket key joins to nothing');
});

test('garbage meta does not throw and does not match', () => {
  const broken = jobRow({ id: 'job-broken', meta: 'not json at all' });
  assert.equal(matchBuildJob(build, [broken]).id, 'job-broken', 'it is still the only ticket match');
  const objMeta = jobRow({ id: 'job-obj', meta: { build: 'project-1-TK-7-1726' }, created_at: '2026-09-17T08:00:00Z' });
  assert.equal(matchBuildJob(build, [broken, objMeta]).id, 'job-obj', 'an already-parsed meta object matches too');
});

// --- mergeLive --------------------------------------------------------------

test('the event stream accumulates without duplicating and stays ascending', () => {
  const first = mergeLive(null, { job: { status: 'running' }, phases: [], events: EVENTS.slice(0, 4), spend_usd: 1, cursor: 14 });
  assert.deepEqual(first.events.map((e) => e.id), [11, 12, 13, 14]);
  assert.equal(first.cursor, 14);

  // A tick that re-sends one it already had plus two new ones.
  const second = mergeLive(first, { job: { status: 'running' }, phases: [], events: [EVENTS[3], EVENTS[5], EVENTS[4]], spend_usd: 3.1, cursor: 16 });
  assert.deepEqual(second.events.map((e) => e.id), [11, 12, 13, 14, 15, 16], 'no duplicate 14, and 15 before 16');
  assert.equal(second.cursor, 16);
  assert.equal(second.spend_usd, 3.1, 'the totals are replaced, not accumulated');
});

test('an empty page keeps everything that was already on screen', () => {
  const first = mergeLive(null, { job: { status: 'running' }, phases: [{ id: 1 }], events: EVENTS, cursor: 16 });
  const second = mergeLive(first, { job: { status: 'running' }, phases: [{ id: 1 }], events: [], cursor: 16 });
  assert.equal(second.events.length, 6, 'nothing new is not nothing');
  assert.equal(second.cursor, 16);
  assert.equal(second.capped, false);
});

test('a payload with no cursor falls back to the highest event id it has seen', () => {
  const first = mergeLive(null, { events: EVENTS });
  assert.equal(first.cursor, 16);
  const second = mergeLive(first, { events: [] });
  assert.equal(second.cursor, 16, 'the walk does not restart at zero');
});

test('a full page declares itself incomplete', () => {
  const many = Array.from({ length: LIVE_EVENT_CAP }, (_, i) => ev(i + 1, 'execute', null, `line ${i}`, '2026-09-17T11:23:00Z'));
  const full = mergeLive(null, { events: many, cursor: LIVE_EVENT_CAP });
  assert.equal(full.capped, true, 'the route caps at 200 and the next tick drains the rest');
  const partial = mergeLive(null, { events: many.slice(0, 199), cursor: 199 });
  assert.equal(partial.capped, false);
});

// --- shouldPollLive ---------------------------------------------------------

test('polling runs only while the job says it is running', () => {
  const running = { job: { status: 'running' } };
  assert.equal(shouldPollLive(running, build), true);
  for (const status of ['done', 'failed', 'parked', 'budget_stopped', 'orphaned', 'queued_for_retry', 'whatever']) {
    assert.equal(shouldPollLive({ job: { status } }, build), false, `${status} is not running`);
  }
  // An absent status is not a running one: the honest read of "we do not know"
  // is to stop, show the last fact and say so.
  assert.equal(shouldPollLive({ job: {} }, build), false, 'a missing status is not running');
  assert.equal(shouldPollLive({ job: null }, build), false, 'a payload with no job row is not running');
});

test('before the first answer, an unmerged build polls and a merged one does not', () => {
  assert.equal(shouldPollLive(null, build), true, 'nothing fetched yet: poll to find out');
  assert.equal(shouldPollLive(null, { ...build, merged: 1 }), false, 'a merged build is final by definition');
  assert.equal(shouldPollLive(null, null), true);
});

// --- liveSpend --------------------------------------------------------------

test('spend prefers the payload total, then the phases, then says nothing', () => {
  assert.equal(liveSpend({ spend_usd: 3.1, phases: [{ spend_usd: 9 }] }), 3.1);
  assert.equal(liveSpend({ phases: [{ spend_usd: 0.4 }, { spend_usd: 2.7 }, { spend_usd: null }] }).toFixed(2), '3.10',
    'a phase that has not been billed yet is skipped, not read as zero');
  // Absent is not zero: a rail that says $0.00 while a model is running is a lie.
  assert.equal(liveSpend({ phases: [{ spend_usd: null }, { spend_usd: undefined }] }), null);
  assert.equal(liveSpend({ phases: [] }), null);
  assert.equal(liveSpend({ spend_usd: null, phases: [] }), null);
  assert.equal(liveSpend({ spend_usd: '' }), null, 'an empty string is not zero dollars');
  assert.equal(liveSpend(null), null);
  assert.equal(liveSpend({ spend_usd: 0, phases: [] }), 0, 'a real zero still renders as a number');
});

// --- gatesPassed ------------------------------------------------------------

test('gates passed counts passing verdicts and nothing else', () => {
  assert.equal(gatesPassed(EVENTS), 2, 'size_gate PASS and tests_green PASS');
  assert.equal(gatesPassed([...EVENTS, ev(17, 'review', 'APPROVE', 'review: approve', '2026-09-17T11:30:00Z')]), 3);
  assert.equal(gatesPassed([ev(1, 'x', 'pass', 'lower case is the same verdict', '2026-09-17T11:30:00Z')]), 1);
  assert.equal(gatesPassed([ev(1, 'x', 'FAIL', 'no', null), ev(2, 'y', 'BLOCK', 'no', null), ev(3, 'z', null, 'no', null)]), 0);
  assert.equal(gatesPassed(null), 0);
});

// --- liveStep / subStage ----------------------------------------------------

test('the strip advances on events, not only on the beat the hub wrote', () => {
  // The build row still says `executing` (step 1). semgrep has already run.
  assert.equal(liveStep(build, []), 1, 'with no events the beat is the whole story');
  assert.equal(liveStep(build, EVENTS), 2, 'semgrep is a review-step event');
  assert.equal(liveStep(build, [...EVENTS, ev(17, 'done', 'FAIL', 'build failed', null)]), 2,
    'a terminal marker is not a step');
  assert.equal(liveStep(build, [ev(1, 'frobnicate', null, 'a stage from the future', null)]), 1,
    'an unknown stage never moves the strip');
  assert.equal(liveStep({ ...build, merged: 1 }, EVENTS), 5, 'a merged build sits at the end whatever the events say');
});

test('the sub-stage line is the latest event of the step the strip is on', () => {
  assert.equal(subStage(EVENTS, 2).detail, 'semgrep: 0 findings');
  assert.equal(subStage(EVENTS, 1).detail, 'tests green: 248 pass', 'id 15 beats id 13 and 14');
  assert.equal(subStage(EVENTS, 0).detail, 'size gate: M, one PR');
  assert.equal(subStage(EVENTS, 0).verdict, 'PASS');
  assert.equal(subStage(EVENTS, 3), null, 'no e2e event yet');
  assert.equal(subStage([], 1), null);
  assert.equal(subStage(null, 1), null);
});

// --- logRows ----------------------------------------------------------------

test('log rows render oldest first with the clock and the tone', () => {
  const rows = logRows([EVENTS[5], EVENTS[0], EVENTS[2]]);
  assert.deepEqual(rows.map((r) => r.id), [11, 13, 16], 'ascending, so the newest is at the bottom');
  assert.equal(rows[0].when, '11:20Z');
  assert.equal(rows[1].tone, 'red', 'FAIL is red through VERDICT_TONE');
  assert.equal(rows[0].tone, null, 'an event with no verdict is uncoloured');
  assert.equal(rows[2].detail, 'semgrep: 0 findings');
});

test('the log reads the timestamp the route sends and the one the table stores', () => {
  // #520 writes `at`; the stage_events column is `created_at`. Both arrive.
  assert.equal(logRows([{ id: 1, stage: 'plan', created_at: '2026-09-17T09:05:00Z' }])[0].when, '09:05Z');
  assert.equal(logRows([{ id: 1, stage: 'plan', at: '2026-09-17T09:06:00Z' }])[0].when, '09:06Z');
  assert.equal(logRows([{ id: 1, stage: 'plan' }])[0].when, '—', 'an event with no time says so');
});

test('a tone maps onto a pill class that exists in the stylesheet', () => {
  assert.equal(pillClass('green'), 'pill');
  assert.equal(pillClass('red'), 'pill pill--dead');
  assert.equal(pillClass('warn'), 'pill pill--warn');
  assert.equal(pillClass(null), 'pill pill--muted');
});
