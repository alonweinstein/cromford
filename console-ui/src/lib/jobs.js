// Derivations for the JOBS screen. Everything here is pure so the rules that
// decide what a row MEANS - orphaned, stalled, quiet, over budget - are tested
// in tests/jobs.test.js rather than inspected by eye in a browser.
//
// The rule this file keeps: the coordination DB is COORDINATION truth, not
// build truth. A number here is what the fleet's claimants reported about
// themselves; PRs, board comments and ALERTS.log remain the record. Where that
// makes a figure partial, the screen says so instead of rounding it off.

// A claimant beats every ~150s (bin/jobs-client.sh job_beat_start), so four
// missed beats is the same 10 minutes bin/jobs-watchdog.sh calls dead. One
// policy, stated twice; if the watchdog's threshold moves, this moves with it.
export const ORPHAN_AFTER_S = 600;

export function jobState(job) {
  if (!job) return 'unknown';
  const s = String(job.status || '').toLowerCase();
  if (s === 'orphaned') return 'orphaned';
  if (s !== 'running') return s || 'unknown';
  const age = job.activity_age_s;
  const old = age !== null && age !== undefined && age >= ORPHAN_AFTER_S;
  // A row that never beat is QUIET, not dead: its box may simply be running
  // bin/ from before heartbeats existed, and calling that dead in the UI would
  // teach the reader to distrust the label that matters.
  if (!job.heartbeating) return old ? 'quiet' : 'running';
  return old ? 'stalled' : 'running';
}

const TONE = {
  running: 'ok', done: 'ok', stalled: 'dead', orphaned: 'dead',
  failed: 'dead', quiet: 'warn', budget_stopped: 'warn', parked: 'warn',
  // A queued row is WAITING, not working and not dead: the watchdog judged it
  // retryable and the lane's own next tick will pick it up. Toning it 'dead'
  // would page a reader about a state the system is handling on purpose.
  queued_for_retry: 'warn'
};
export const jobTone = (state) => TONE[state] || 'unknown';

// Spend against the cap it was handed. The cap is a MAX-COST FUSE, never a
// target, so a job at 80% of budget is not a job misbehaving - the figure only
// matters as it approaches the fuse. Nothing here treats under-spend as good.
export function budgetUse(job) {
  const b = Number(job && job.budget_usd);
  const s = Number(job && job.spent_usd);
  if (!Number.isFinite(b) || b <= 0 || !Number.isFinite(s)) return null;
  return s / b;
}

// --- phases (phase 5) --------------------------------------------------------
// A job is the claim; a phase is what happened inside it. The row carries the
// CURRENT (or last) phase, and — when one failed — the phase that failed, which
// is the whole point: through phase 4 a red job said "failed" and left the
// reader to work out which stage that was from a build dir on another box.
//
// A null here is not a failure, it is a job whose box has not opened a phase:
// an older bin/, an unclaimed lane, or a claim that has not reached its first
// stage. The screen says "-" for that rather than inventing a phase name.
export function jobPhase(job) {
  if (!job) return null;
  const name = job.phase ? String(job.phase) : null;
  const failed = job.failed_phase ? String(job.failed_phase) : null;
  if (!name && !failed) return null;
  const status = String(job.phase_status || '').toLowerCase();
  const rc = Number.isFinite(Number(job.phase_rc)) && job.phase_rc !== null ? Number(job.phase_rc) : null;
  return {
    name: name || failed,
    status: status || 'unknown',
    rc,
    // The phase to BLAME, and only when there is one. A job still running has a
    // current phase, not a culprit, and labelling it a culprit mid-build is how
    // a screen teaches its reader to discount the label that matters.
    failed: failed && String(job.status || '').toLowerCase() !== 'running' ? failed : null,
    running: status === 'running'
  };
}

// One phase row for the job's own page: how long it took, what it cost, what
// closed it. Duration is only claimed when BOTH ends are on the row - a phase
// that never closed has no honest duration, and showing "now minus started" for
// one would make an abandoned row look like it is still working.
export function phaseRows(payload) {
  const phases = (payload && payload.phases) || [];
  return phases.map((p) => {
    const st = String(p.status || '').toLowerCase();
    const a = Date.parse(p.started_at || '');
    const b = Date.parse(p.finished_at || '');
    return {
      ...p,
      state: st,
      tone: st === 'done' ? 'ok' : st === 'running' ? 'ok' : st === 'failed' || st === 'orphaned' ? 'dead' : 'warn',
      duration_s: Number.isFinite(a) && Number.isFinite(b) && b >= a ? Math.round((b - a) / 1000) : null
    };
  });
}

// --- attempts and retry state (phase 6) --------------------------------------
// "2/3" is the whole story on a retried row: this is the second attempt and the
// lane's policy allows three. A lane with NO policy has no denominator, and the
// honest label for that is the bare attempt count — inventing a "/1" would read
// as a limit somebody set, when in fact nobody has.
export function attemptLabel(job) {
  const n = Number(job && job.attempts);
  const max = Number(job && job.max_attempts);
  if (!Number.isFinite(n) || n < 1) return null;
  if (Number.isFinite(max) && max > 0) return `${n}/${max}`;
  return String(n);
}

// Why a row is queued or parked, in the DB's own words. Shown rather than
// paraphrased: the reason names the rule or the count that produced it, and a
// screen that summarises it away sends the reader back to the logs.
export function retryNote(job) {
  if (!job) return null;
  const state = String(job.status || '').toLowerCase();
  if (state !== 'queued_for_retry' && state !== 'parked') return null;
  return {
    reason: job.retry_reason ? String(job.retry_reason) : null,
    next_attempt_at: job.next_attempt_at || null,
    escalate_allowed: Number(job.escalate_allowed) === 1
  };
}

export function jobRows(payload) {
  const jobs = (payload && payload.jobs) || [];
  return jobs.map((j) => {
    const state = jobState(j);
    return {
      ...j,
      state,
      tone: jobTone(state),
      lane: `${j.kind || '?'}/${j.project || '?'}/${j.stage || '?'}`,
      key: j.ticket_id || null,
      phase: jobPhase(j),
      attempts: Number.isFinite(Number(j.attempts)) ? Number(j.attempts) : null,
      attempt_label: attemptLabel(j),
      retry: retryNote(j),
      beat_age_s: j.beat_age_s === undefined ? null : j.beat_age_s,
      activity_age_s: j.activity_age_s === undefined ? null : j.activity_age_s,
      budget_use: budgetUse(j)
    };
  });
}

// Counts for the tiles. `stalled` and `orphaned` stay apart on purpose: the
// first is a row whose beats stopped, the second is one the watchdog has
// already judged and released.
export function jobCounts(rows) {
  const c = {
    total: rows.length, running: 0, stalled: 0, orphaned: 0, quiet: 0, failed: 0, done: 0,
    queued_for_retry: 0, parked: 0
  };
  for (const r of rows) {
    if (c[r.state] !== undefined) c[r.state] += 1;
  }
  return c;
}

export const jobSpend = (rows) =>
  rows.reduce((n, r) => n + (Number.isFinite(Number(r.spent_usd)) ? Number(r.spent_usd) : 0), 0);

// --- burn rollup -------------------------------------------------------------
// Rows are (day, project, kind) sums straight from the jobs table. The pivot is
// done here, not in SQL, so one payload drives both the by-day and the
// by-project view without a second round trip.
export function burnByDay(payload) {
  const rows = (payload && payload.burn) || [];
  const days = new Map();
  for (const r of rows) {
    const d = days.get(r.day) || { day: r.day, spent_usd: 0, jobs: 0, orphaned: 0, projects: new Set() };
    d.spent_usd += Number(r.spent_usd) || 0;
    d.jobs += Number(r.jobs) || 0;
    d.orphaned += Number(r.orphaned) || 0;
    if (r.project) d.projects.add(r.project);
    days.set(r.day, d);
  }
  return [...days.values()]
    .map((d) => ({ ...d, projects: d.projects.size }))
    .sort((a, b) => (a.day < b.day ? 1 : a.day > b.day ? -1 : 0));
}

export function burnByProject(payload) {
  const rows = (payload && payload.burn) || [];
  const by = new Map();
  for (const r of rows) {
    const k = `${r.project} ${r.kind}`;
    const p = by.get(k) || { project: r.project, kind: r.kind, spent_usd: 0, jobs: 0, orphaned: 0, days: new Set() };
    p.spent_usd += Number(r.spent_usd) || 0;
    p.jobs += Number(r.jobs) || 0;
    p.orphaned += Number(r.orphaned) || 0;
    if (r.day) p.days.add(r.day);
    by.set(k, p);
  }
  return [...by.values()]
    .map((p) => ({ ...p, days: p.days.size, per_job: p.jobs ? p.spent_usd / p.jobs : null }))
    .sort((a, b) => b.spent_usd - a.spent_usd);
}

export const burnTotal = (payload) =>
  ((payload && payload.burn) || []).reduce((n, r) => n + (Number(r.spent_usd) || 0), 0);

// --- pause flags -------------------------------------------------------------
// A flag row drives a FILE on every box (bin/jobs-client.sh flag_active), and
// the file is what the pipeline tests. So the UI never claims a box is paused -
// it shows what the row says and when it changed, because a box applying it is
// a separate event that can be a minute behind.
export function flagRows(payload) {
  const flags = (payload && payload.flags) || [];
  return flags.map((f) => ({
    ...f,
    active: Number(f.active) === 1,
    scope: /^paused-/.test(f.name) ? f.name.replace(/^paused-/, '')
      : /^product-paused-/.test(f.name) ? f.name.replace(/^product-paused-/, '')
        : 'fleet'
  }));
}

export const flagName = (project) => `paused-${project}`;

export function ageLabel(seconds) {
  if (seconds === null || seconds === undefined || !Number.isFinite(Number(seconds))) return '-';
  const s = Math.max(0, Math.round(Number(seconds)));
  if (s < 90) return `${s}s`;
  if (s < 5400) return `${Math.round(s / 60)}m`;
  if (s < 172800) return `${Math.round(s / 3600)}h`;
  return `${Math.round(s / 86400)}d`;
}

// --- lane liveness (2026-08-30) ----------------------------------------------
// A LANE IS NOT A JOB. Every row above is work that HAPPENED; a lane is work
// that is SUPPOSED to happen — one (project, box) pair fleet.conf declares and a
// crontab can silently lose. On 2026-08-30 project-7's crons vanished from
// box-project-6-1 and the lane sat silent for ten hours: the box pinged,
// the fleet status flowed, and no row on this screen could have shown it,
// because a lane that never ticks never claims a job.
//
// THE VERDICT IS THE WORKER'S, NOT THIS FILE'S. `state` and `stale` are computed
// in worker/jobs from the lane's own cadence, and bin/jobs-watchdog.sh pages off
// the same fields. Re-deriving them here from a constant would eventually make
// the screen disagree with the alert that woke someone up — and the screen is
// what they check first. What this file decides is presentation: tone, order,
// and what to say about a lane that has never ticked at all.

// Stale first, because it is the only row anyone opens this table looking for.
// Retired sinks below live: a lane nobody watches any more is not news.
//
// EXPORTED BECAUSE THE TABLE MUST SORT ON IT, NOT ON THE WORD. laneRows returns
// rows in this order, but SortableTable re-sorts by its active column's
// accessor from the first render — so a STATE column keyed on the raw string
// would order them alphabetically (live, pending, retired, stale, unexpected)
// and bury the silent lane in fourth place, which is the one row anyone opened
// this table to find. `laneSortKey` is that accessor, shared by the column and
// its test so there is one ordering rather than two that agree by luck.
export const LANE_RANK = { stale: 0, pending: 1, unexpected: 2, live: 3, retired: 4 };
export const laneSortKey = (r) => LANE_RANK[r && r.state] ?? 5;

const LANE_TONE = {
  live: 'ok',
  stale: 'dead',
  // Neither of these is a problem. `pending` is a lane whose first tick is not
  // due yet (enrolment is not an incident); `unexpected` is a lane ticking that
  // fleet.conf never declared — worth SEEING, never alertable, because it would
  // be judged against an expectation nobody made. Colouring either 'dead' would
  // teach the reader to discount the colour that matters.
  pending: 'warn',
  unexpected: 'warn',
  retired: 'unknown'
};
export const laneTone = (state) => LANE_TONE[state] || 'unknown';

export function laneRows(payload) {
  const lanes = (payload && payload.lanes) || [];
  return lanes
    .map((l) => {
      const state = String(l.state || 'unknown');
      const tick = l.tick_age_s === undefined ? null : l.tick_age_s;
      return {
        ...l,
        state,
        tone: laneTone(state),
        lane: `${l.project || '?'}@${l.box || '?'}`,
        tick_age_s: tick,
        // A lane that has never ticked has no age to show. "never" is the
        // honest word for it; 0 or "just now" would read as the healthiest
        // possible lane, which is exactly backwards.
        age_label: tick === null ? 'never' : ageLabel(tick),
        never_ticked: tick === null || Boolean(l.never_ticked)
      };
    })
    .sort((a, b) => {
      const ra = laneSortKey(a), rb = laneSortKey(b);
      if (ra !== rb) return ra - rb;
      return (Number(b.silence_s) || 0) - (Number(a.silence_s) || 0);
    });
}

// `expected` is what SHOULD be ticking right now — the denominator a reader
// actually wants. A retired lane and a lane nobody declared are both outside it,
// and lumping them in would make the fleet look larger than the set anything is
// watching.
export function laneCounts(rows) {
  const c = { total: rows.length, expected: 0, live: 0, stale: 0, pending: 0, unexpected: 0, retired: 0 };
  for (const r of rows) {
    if (r.expected) c.expected += 1;
    if (c[r.state] !== undefined) c[r.state] += 1;
  }
  return c;
}
