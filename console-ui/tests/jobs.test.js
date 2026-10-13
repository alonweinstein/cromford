import test from 'node:test';
import assert from 'node:assert/strict';
import {
  jobState, jobTone, budgetUse, jobRows, jobCounts, jobSpend,
  burnByDay, burnByProject, burnTotal, flagRows, ageLabel, ORPHAN_AFTER_S,
  jobPhase, phaseRows, attemptLabel, retryNote,
  laneRows, laneCounts, laneTone, laneSortKey, LANE_RANK
} from '../src/lib/jobs.js';
import { sortRows } from '../src/lib/sort.js';
import { readFileSync } from 'node:fs';

// The rules under test are the ones a reader will trust on sight: whether a row
// is dead, whether it merely never spoke, and what the money columns mean.

test('a running row whose beats stopped reads as stalled', () => {
  const j = { status: 'running', heartbeating: true, activity_age_s: ORPHAN_AFTER_S + 1 };
  assert.equal(jobState(j), 'stalled');
  assert.equal(jobTone('stalled'), 'dead');
});

test('a running row still beating is just running', () => {
  assert.equal(jobState({ status: 'running', heartbeating: true, activity_age_s: 120 }), 'running');
});

test('a row that NEVER beat is quiet, not stalled - its age is a lower bound', () => {
  // This is the distinction that keeps a claim from being released on a box
  // whose bin/ predates heartbeats, which would let a second builder take the
  // same ticket.
  const j = { status: 'running', heartbeating: false, activity_age_s: 9999 };
  assert.equal(jobState(j), 'quiet');
  assert.equal(jobTone('quiet'), 'warn');
});

test('the watchdog verdict wins over any age arithmetic', () => {
  assert.equal(jobState({ status: 'orphaned', heartbeating: true, activity_age_s: 5 }), 'orphaned');
});

test('a closed row keeps its own status', () => {
  assert.equal(jobState({ status: 'done', activity_age_s: 100000 }), 'done');
  assert.equal(jobState({ status: 'budget_stopped' }), 'budget_stopped');
});

test('budget use is null rather than zero when there is no cap to divide by', () => {
  assert.equal(budgetUse({ spent_usd: 3, budget_usd: 0 }), null);
  assert.equal(budgetUse({ spent_usd: 3 }), null);
  assert.equal(budgetUse({ spent_usd: 'nope', budget_usd: 10 }), null);
  assert.equal(budgetUse({ spent_usd: 5, budget_usd: 10 }), 0.5);
});

test('rows carry a lane, a ticket key and the derived state', () => {
  const rows = jobRows({ jobs: [
    { id: 'a', project: 'project-3', kind: 'build', stage: 'execute', ticket_id: 'TK-1',
      status: 'running', heartbeating: true, activity_age_s: 30, spent_usd: 2, budget_usd: 10 },
    { id: 'b', project: 'project-4', kind: 'triage', stage: 'triage',
      status: 'running', heartbeating: false, activity_age_s: 20000, spent_usd: 1 }
  ] });
  assert.equal(rows[0].lane, 'build/project-3/execute');
  assert.equal(rows[0].key, 'TK-1');
  assert.equal(rows[0].budget_use, 0.2);
  assert.equal(rows[1].key, null);
  assert.equal(rows[1].state, 'quiet');
  assert.equal(rows[1].budget_use, null);
});

test('counts and spend tolerate an empty or malformed payload', () => {
  assert.deepEqual(jobRows(null), []);
  assert.equal(jobCounts([]).total, 0);
  assert.equal(jobSpend([{ spent_usd: 'x' }, { spent_usd: 1.5 }]), 1.5);
});

test('counts keep stalled and orphaned apart', () => {
  const rows = jobRows({ jobs: [
    { id: '1', status: 'running', heartbeating: true, activity_age_s: 5 },
    { id: '2', status: 'running', heartbeating: true, activity_age_s: 4000 },
    { id: '3', status: 'orphaned' },
    { id: '4', status: 'running', heartbeating: false, activity_age_s: 4000 }
  ] });
  const c = jobCounts(rows);
  assert.equal(c.running, 1);
  assert.equal(c.stalled, 1);
  assert.equal(c.orphaned, 1);
  assert.equal(c.quiet, 1);
  assert.equal(c.total, 4);
});

const BURN = { burn: [
  { day: '2026-08-27', project: 'project-3', kind: 'build', jobs: 2, spent_usd: 10, budget_usd: 300, orphaned: 1 },
  { day: '2026-08-27', project: 'project-4', kind: 'triage', jobs: 4, spent_usd: 2.5, budget_usd: 100, orphaned: 0 },
  { day: '2026-08-26', project: 'project-3', kind: 'build', jobs: 1, spent_usd: 4, budget_usd: 150, orphaned: 0 }
] };

test('burn by day sums across projects, newest first', () => {
  const days = burnByDay(BURN);
  assert.equal(days.length, 2);
  assert.equal(days[0].day, '2026-08-27');
  assert.equal(days[0].spent_usd, 12.5);
  assert.equal(days[0].jobs, 6);
  assert.equal(days[0].projects, 2);
  assert.equal(days[0].orphaned, 1);
});

test('burn by project keeps the lane split and prices per job', () => {
  const rows = burnByProject(BURN);
  assert.equal(rows[0].project, 'project-3');
  assert.equal(rows[0].kind, 'build');
  assert.equal(rows[0].spent_usd, 14);
  assert.equal(rows[0].jobs, 3);
  assert.equal(rows[0].days, 2);
  assert.equal(Number(rows[0].per_job.toFixed(2)), 4.67);
  assert.equal(rows[1].project, 'project-4');
});

test('burn helpers answer honestly on an empty payload', () => {
  assert.deepEqual(burnByDay({ burn: [] }), []);
  assert.deepEqual(burnByProject(undefined), []);
  assert.equal(burnTotal(null), 0);
});

test('flag rows are booleans with a scope, whatever D1 hands back', () => {
  const rows = flagRows({ flags: [
    { name: 'paused-project-3', active: 1 },
    { name: 'automerge-disabled', active: 0 },
    { name: 'product-paused-project-4', active: '1' }
  ] });
  assert.equal(rows[0].active, true);
  assert.equal(rows[0].scope, 'project-3');
  assert.equal(rows[1].active, false);
  assert.equal(rows[1].scope, 'fleet');
  // D1 hands integers back as strings often enough that "1" must not read false.
  assert.equal(rows[2].active, true);
  assert.equal(rows[2].scope, 'project-4');
});

test('an age with no value reads as unknown, never as zero', () => {
  assert.equal(ageLabel(null), '-');
  assert.equal(ageLabel(undefined), '-');
  assert.equal(ageLabel('nope'), '-');
  assert.equal(ageLabel(45), '45s');
  assert.equal(ageLabel(600), '10m');
  assert.equal(ageLabel(7200), '2h');
  assert.equal(ageLabel(200000), '2d');
});

// --- phases (phase 5) --------------------------------------------------------
// The claim this screen makes about a red job is "it died HERE". These pin the
// two ways that claim could go wrong: naming a culprit on a job that is still
// working, and inventing a phase for a row that never reported one.

test('a failed job names the phase that failed', () => {
  const p = jobPhase({
    status: 'failed', phase: 'execute', phase_status: 'failed', phase_rc: 137, failed_phase: 'execute'
  });
  assert.equal(p.failed, 'execute');
  assert.equal(p.rc, 137);
});

test('a running job shows its current phase and blames nothing', () => {
  // A build that failed review once, got fixed, and is now back in review must
  // not be rendered as a corpse: the earlier failure is history, not a verdict.
  const p = jobPhase({
    status: 'running', phase: 'review', phase_status: 'running', phase_rc: null, failed_phase: 'review'
  });
  assert.equal(p.name, 'review');
  assert.equal(p.running, true);
  assert.equal(p.failed, null, 'a job still running has a current phase, not a culprit');
});

test('a job with no phase rows reads as no phase, never as a guess', () => {
  assert.equal(jobPhase({ status: 'running', phase: null, failed_phase: null }), null);
  assert.equal(jobRows({ jobs: [{ id: 'x', status: 'running' }] })[0].phase, null);
});

test('an orphaned phase is dead-toned and carries no invented duration', () => {
  const rows = phaseRows({ phases: [
    { id: 1, phase: 'plan', status: 'done', started_at: '2026-08-28T10:00:00Z', finished_at: '2026-08-28T10:04:00Z', rc: 0, spend_usd: 1.5 },
    { id: 2, phase: 'execute', status: 'orphaned', started_at: '2026-08-28T10:05:00Z', finished_at: null, rc: null }
  ] });
  assert.equal(rows[0].duration_s, 240);
  assert.equal(rows[0].tone, 'ok');
  assert.equal(rows[1].tone, 'dead');
  assert.equal(rows[1].duration_s, null, 'a phase that never closed has no honest duration');
});

test('the phase column sorts on a name that is always a string', () => {
  // SortableTable sorts on the accessor's value, and a null name on one row
  // among strings is how a sort silently stops being a sort.
  const rows = jobRows({ jobs: [
    { id: 'a', status: 'running' },
    { id: 'b', status: 'failed', phase: 'plan', phase_status: 'failed', failed_phase: 'plan' }
  ] });
  const names = rows.map((r) => (r.phase ? r.phase.name : ''));
  assert.deepEqual(names, ['', 'plan']);
});

// --- attempts and retry state (phase 6) --------------------------------------
// The screen has to tell three things apart that all look like "a job that did
// not finish": one waiting for its lane's next tick, one that ran out of
// attempts, and one nobody ever wrote a policy for.

test('a queued row is WARN, not dead - the system is handling it on purpose', () => {
  assert.equal(jobState({ status: 'queued_for_retry' }), 'queued_for_retry');
  assert.equal(jobTone('queued_for_retry'), 'warn');
  assert.equal(jobTone('parked'), 'warn');
});

test('attempts read "2/3" only when the lane actually has a policy', () => {
  assert.equal(attemptLabel({ attempts: 2, max_attempts: 3 }), '2/3');
  // No policy: the honest label is the bare count. A "/1" would read as a limit
  // somebody set, when nobody has.
  assert.equal(attemptLabel({ attempts: 1, max_attempts: null }), '1');
  assert.equal(attemptLabel({ attempts: 1 }), '1');
  // A row with no counter at all (an older bin/) gets no label, not a zero.
  assert.equal(attemptLabel({}), null);
  assert.equal(attemptLabel(null), null);
});

test('the retry note is the DB reason, and only on the states that have one', () => {
  const queued = retryNote({
    status: 'queued_for_retry', retry_reason: 'attempt 1 of 3 ended (no heartbeat for 35m)',
    next_attempt_at: '2026-08-29T00:05:00Z', escalate_allowed: 1
  });
  assert.equal(queued.reason, 'attempt 1 of 3 ended (no heartbeat for 35m)');
  assert.equal(queued.next_attempt_at, '2026-08-29T00:05:00Z');
  assert.equal(queued.escalate_allowed, true);
  assert.equal(retryNote({ status: 'parked', retry_reason: 'retries exhausted (3 of 3)' }).reason,
    'retries exhausted (3 of 3)');
  assert.equal(retryNote({ status: 'running' }), null);
  assert.equal(retryNote({ status: 'done' }), null);
});

test('rows carry the attempt label and the counts keep the new states apart', () => {
  const rows = jobRows({ jobs: [
    { id: 'a', status: 'queued_for_retry', attempts: 2, max_attempts: 3,
      retry_reason: 'attempt 2 of 3', next_attempt_at: '2026-08-29T00:05:00Z' },
    { id: 'b', status: 'parked', attempts: 3, max_attempts: 3, retry_reason: 'retries exhausted (3 of 3)' },
    { id: 'c', status: 'running', heartbeating: true, activity_age_s: 10, attempts: 1 }
  ] });
  assert.deepEqual(rows.map((r) => r.attempt_label), ['2/3', '3/3', '1']);
  assert.equal(rows[0].retry.next_attempt_at, '2026-08-29T00:05:00Z');
  assert.equal(rows[2].retry, null);
  const c = jobCounts(rows);
  assert.equal(c.queued_for_retry, 1);
  assert.equal(c.parked, 1);
  assert.equal(c.running, 1);
  assert.equal(c.orphaned, 0, 'a queued row is not an orphaned one, and the tiles must not merge them');
});

// --- lane liveness (2026-08-30) ---------------------------------------------
// The screen's job here is narrow and worth pinning: it must never invent a
// verdict. The worker computes `state` from the lane's own cadence, so the pager
// and this table agree by construction; the console decides tone, ordering and
// what a reader is told when a lane has never ticked at all.

test('a lane keeps the state the worker computed - the console never re-decides it', () => {
  // One threshold, one definition. If this file re-derived staleness from a
  // constant of its own, the console would eventually disagree with the alert
  // that woke someone up, and the screen is what they check first.
  const rows = laneRows({ lanes: [
    { project: 'project-7', box: 'box-project-6-1', state: 'stale', stale: true,
      silence_s: 36000, tick_age_s: 36000, stale_after_s: 1800, last_tick_kind: 'skip' }
  ] });
  assert.equal(rows[0].state, 'stale');
  assert.equal(rows[0].tone, 'dead');
  assert.equal(rows[0].lane, 'project-7@box-project-6-1');
});

test('the tones separate an incident from a lane nobody is watching', () => {
  assert.equal(laneTone('live'), 'ok');
  assert.equal(laneTone('stale'), 'dead');
  // Pending and unexpected are NOT problems: one is a lane whose first tick is
  // not due yet, the other a lane nobody declared. Toning either 'dead' would
  // teach the reader to discount the colour that matters.
  assert.equal(laneTone('pending'), 'warn');
  assert.equal(laneTone('unexpected'), 'warn');
  assert.equal(laneTone('retired'), 'unknown');
});

test('a lane that has never ticked says so, and never shows a fabricated age', () => {
  const [r] = laneRows({ lanes: [
    { project: 'brand-new', box: 'box-small', state: 'stale', stale: true,
      silence_s: 2700, tick_age_s: null, never_ticked: true, stale_after_s: 1800 }
  ] });
  assert.equal(r.never_ticked, true);
  assert.equal(r.tick_age_s, null, 'a null age must stay null, not become 0 or "just now"');
  assert.equal(r.age_label, 'never');
});

test('stale lanes sort to the top, because that is the only row anyone is looking for', () => {
  const rows = laneRows({ lanes: [
    { project: 'a-os', box: 'b1', state: 'live', silence_s: 60 },
    { project: 'z-os', box: 'b2', state: 'stale', stale: true, silence_s: 36000 },
    { project: 'm-os', box: 'b3', state: 'retired', silence_s: 90000 }
  ] });
  assert.equal(rows[0].project, 'z-os');
  // ...and a retired lane sinks below a live one: it is not news either way.
  assert.deepEqual(rows.map((r) => r.project), ['z-os', 'a-os', 'm-os']);
});

test('THE TABLE sorts by severity too - laneRows order alone does not survive the render', () => {
  // The helper returning the right order proves nothing about the screen:
  // SortableTable re-sorts by its active column's accessor from the FIRST
  // render, so a STATE column keyed on the raw string would order these
  // alphabetically - live, pending, retired, stale, unexpected - and bury the
  // silent lane in fourth place. This drives the real comparator with the real
  // accessor the column is given, which is the only version of this assertion
  // that can fail when the screen regresses.
  const rows = laneRows({ lanes: [
    { project: 'live-os', box: 'b1', state: 'live', silence_s: 60 },
    { project: 'pending-os', box: 'b2', state: 'pending', silence_s: 120 },
    { project: 'retired-os', box: 'b3', state: 'retired', silence_s: 90000 },
    { project: 'stale-os', box: 'b4', state: 'stale', stale: true, silence_s: 36000 },
    { project: 'rogue-os', box: 'b5', state: 'unexpected', silence_s: 50000 }
  ] });
  const asIfRendered = sortRows(rows, laneSortKey, 'asc');
  assert.equal(asIfRendered[0].state, 'stale',
    'the silent lane must be the first row the table draws');
  assert.deepEqual(asIfRendered.map((r) => r.state),
    ['stale', 'pending', 'unexpected', 'live', 'retired']);
  // Alphabetical order is what this replaces - if the two ever coincide the
  // assertion above would pass on the bug it was written for.
  const alphabetical = sortRows(rows, (r) => r.state, 'asc').map((r) => r.state);
  assert.notDeepEqual(alphabetical, asIfRendered.map((r) => r.state));
  assert.equal(alphabetical[0], 'live', 'sorting the WORD is what put stale fourth');
});

test('the LANES table is actually WIRED to the severity accessor', () => {
  // The test above proves the ordering; this proves the screen asks for it.
  // Read from the source because the columns are defined inline inside the
  // section component, and the two assertions fail on different mistakes: a
  // wrong ranking, and a right ranking nothing is using. Reverting the column
  // to `sort: (r) => r.state` - the bug this pair exists for - fails here.
  const src = readFileSync(new URL('../src/screens/Jobs.js', import.meta.url), 'utf8');
  // Matched on `cell: laneStateCell`, not on the label: the JOBS table above
  // has its own STATE column, and matching that one instead would assert
  // nothing about lanes while looking like it did.
  const stateCol = /\{[^{}]*cell: laneStateCell[^{}]*\}/.exec(src);
  assert.ok(stateCol, 'could not find the LANES state column in Jobs.js');
  assert.match(stateCol[0], /sort: laneSortKey/,
    'the STATE column must sort by severity, not by the word');
});

test('a state the console has never heard of sinks, and never claims to be worst', () => {
  // A worker that grows a new state must not have it land at the top of the
  // table as though it were an incident.
  assert.equal(laneSortKey({ state: 'something-new' }), 5);
  assert.ok(laneSortKey({ state: 'something-new' }) > LANE_RANK.retired);
});

test('the counts are what the tiles show, and retired lanes are not "expected"', () => {
  const c = laneCounts(laneRows({ lanes: [
    { project: 'a', box: 'b1', state: 'live', expected: true },
    { project: 'b', box: 'b2', state: 'stale', stale: true, expected: true },
    { project: 'c', box: 'b3', state: 'pending', expected: true },
    { project: 'd', box: 'b4', state: 'retired', expected: false },
    { project: 'e', box: 'b5', state: 'unexpected', expected: false }
  ] }));
  assert.equal(c.total, 5);
  assert.equal(c.expected, 3, 'expected counts what SHOULD be ticking, retired and rogue lanes excluded');
  assert.equal(c.stale, 1);
  assert.equal(c.live, 1);
  assert.equal(c.pending, 1);
});
