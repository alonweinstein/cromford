// The build stage vocabulary is whatever `bin/run-build.sh` actually beats,
// plus the Fly lane and merge-sweep's own stage. Mapping it onto a progress
// bar means deciding, for each one, how far through the pipeline it really is —
// and which ones are not progress at all but a dead end.

import { plainLabel } from './labels.js';

export const STEPS = ['plan', 'execute', 'review', 'qa', 'pr', 'merge'];

// Two vocabularies land here. The hub BEATS a coarse stage per build row
// (planning / executing / reviewing / ...). A running build also EMITS stage
// events from the gates it passes through, and those are finer: a build that
// has beaten `executing` for twelve minutes may already have passed the size
// gate, gone red, gone green and run semgrep. Both map onto the same six
// steps, so the strip can advance from whichever arrived last.
const STAGE_STEP = {
  planning: 0,
  // event stages, from the gates in bin/run-build.sh
  plan: 0,
  size_gate: 0,
  tests_red: 1,
  execute: 1,
  tests_green: 1,
  review: 2,
  semgrep: 2,
  fix_round: 2,
  e2e: 3,
  // The tier decision is the last gate before the PR is opened, not a QA step.
  tier: 4,
  pr_opened: 4,
  plan_deferred: 0,
  plan_blocked: 0,
  plan_stale: 0,
  plan_malformed: 0,
  // The Fly lane is a machine being handed the ticket: the build is at execute.
  pool_spawned: 1,
  pool_reused: 1,
  fly_dispatched: 1,
  executing: 1,
  // A deferral is a machine that stood down before it built anything — step 0,
  // not a dead end: bin/fly-pool.sh requeues the ticket for another machine.
  pool_deferred: 0,
  pool_result: 2,
  fly_ingested: 2,
  reviewing: 2,
  qa: 3,
  pr_created: 4,
  // The build reached the PR step and stopped there: approved, branch pushed,
  // no PR. Same step as pr_created because that is how far the work got; dead
  // below, because nothing moves it on without a rebuild.
  pr_create_failed: 4,
  // BH-4488: the build hit its hard budget cap at execute and was stopped there.
  budget_stop: 1,
  pr_merged: 5,
  tier2_sweep_merged: 5
};

// A blocked, stale or untraced plan is not "20% done" — it is stopped, and the
// card has to say so rather than showing a bar that will never move again.
// `superseded` and `abandoned` are a PR the blocked-resolver closed unmerged
// (BH-389): stopped for good, and never done.
// `pr_closed` is reconcile's terminal for a PR GitHub closed without merging
// (BH-866), and where bin/builds-merged-sweep.sh moves a row wrongly stamped
// merged (BH-3971).
const DEAD_STAGES = new Set(['plan_blocked', 'plan_stale', 'plan_deferred', 'plan_malformed', 'pr_create_failed', 'superseded', 'abandoned', 'pr_closed', 'budget_stop']);

export function stageProgress(stage, merged) {
  const key = String(stage || '').toLowerCase();
  const dead = DEAD_STAGES.has(key);
  const known = Object.prototype.hasOwnProperty.call(STAGE_STEP, key);
  const step = merged ? STEPS.length - 1 : known ? STAGE_STEP[key] : 0;
  return {
    step,
    total: STEPS.length,
    dead,
    known,
    done: Boolean(merged) || key === 'pr_merged' || key === 'tier2_sweep_merged',
    // The step is where work is happening, so it is "current", not "finished".
    percent: Math.round(((merged ? STEPS.length : step) / STEPS.length) * 100),
    label: key || 'unknown'
  };
}

// Who acts next is decided by tier, not by having a PR: a tier-1 APPROVE goes
// to the auto-merge lane, everything else is waiting on a human.
export function buildLane(build) {
  if (!build) return 'unknown';
  if (build.merged) return 'merged';
  const stage = String(build.stage || '').toLowerCase();
  if (DEAD_STAGES.has(stage)) return 'dead';
  if (stage !== 'pr_created') return 'building';
  return Number(build.tier) === 1 && build.verdict === 'APPROVE' ? 'merge_queue' : 'review';
}

// The review verdicts, plus the three a gate event carries. `done` is
// deliberately absent from STAGE_STEP above: it is a terminal marker whose
// meaning is the job's STATUS, and mapping it to the merge step would paint a
// failed build as shipped.
export const VERDICT_TONE = {
  APPROVE: 'green',
  BLOCK: 'red',
  REVISE: 'warn',
  PASS: 'green',
  FAIL: 'red',
  BUDGET_STOP: 'warn'
};

// What each stage means, in words (BH-3569). Covers every STAGE_STEP key plus
// the dead and terminal ones; stageProgress().label stays the raw key.
export const STAGE_LABEL = {
  planning: 'planning',
  plan: 'planning',
  plan_blocked: 'plan blocked, waiting on a question',
  plan_deferred: 'plan deferred',
  plan_stale: 'plan out of date',
  plan_malformed: 'plan had untraced tasks',
  size_gate: 'size check',
  tests_red: 'tests written, failing first',
  execute: 'building',
  executing: 'building',
  tests_green: 'tests passing',
  review: 'in review',
  reviewing: 'in review',
  semgrep: 'security scan',
  fix_round: 'fixing review notes',
  e2e: 'end-to-end tests',
  qa: 'in QA',
  tier: 'choosing merge tier',
  pr_opened: 'PR open',
  pr_created: 'PR open',
  pr_create_failed: 'PR failed to open',
  pool_spawned: 'handed to a pool machine',
  pool_reused: 'handed to a pool machine',
  fly_dispatched: 'handed to a pool machine',
  pool_deferred: 'pool machine stood down',
  pool_result: 'pool result in',
  fly_ingested: 'pool result in',
  pr_merged: 'merged',
  tier2_sweep_merged: 'merged by the reviewed-merge sweep',
  stale: 'stale',
  superseded: 'replaced by a newer PR',
  abandoned: 'abandoned',
  pr_closed: 'closed without merging',
  budget_stop: 'stopped at its budget cap',
  done: 'finished'
};

// A key-shaped value nobody mapped still reads as words; free text (a Kanban
// queue row's "3 tickets waiting") passes through untouched.
export function stageLabel(s) {
  if (s === null || s === undefined || s === '') return '';
  const raw = String(s);
  const hit = STAGE_LABEL[raw.toLowerCase()];
  if (hit) return hit;
  return /^[a-z0-9_]+$/i.test(raw) ? plainLabel(raw) : raw;
}

export const VERDICT_LABEL = {
  APPROVE: 'approved',
  BLOCK: 'blocked',
  REVISE: 'changes asked',
  PASS: 'passed',
  FAIL: 'failed',
  BUDGET_STOP: 'stopped at its budget'
};

export function verdictLabel(v) {
  if (v === null || v === undefined || v === '') return '';
  return VERDICT_LABEL[String(v).toUpperCase()] || plainLabel(v);
}
