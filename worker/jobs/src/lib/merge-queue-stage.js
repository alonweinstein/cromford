// BH-5667 (BH-5008 child 1): the one way a merge-queue STAGE row is written,
// and the job-class rule the check rows and the medians share. Children 3 and
// 4 of BH-5008 write stage rows only through queueStageStmt.
//
// A stage row is a pr_state_events row with state='queue' and the stage in
// `reason`. It is a fact about the merge queue, not a conductor state, so the
// current-state readers (GET /api/pr-state, the digest) and the sfe tick skip
// state='queue'. Dedupe is idx_pr_state_events_dedupe
// (repo, number, state, since, alerted), so the same stage at the same `since`
// is one row however often it is written.

import { WAKE_REPO_RE } from "./core.js";

// The stage vocabulary (the operator, #5008, 2026-10-06). A stage reason is one of
// these words, optionally with a ` (detail)` suffix. The fixed list is also
// what keeps a stage reason from ever starting with `queue-ejected`, which the
// digest's autonomy count matches (daily-digest/core-sections.js).
export const QUEUE_STAGES = [
  "wait_lead_review", "lead_block", "ci_red", "ci_running", "approved_not_queued", "dequeued",
  "queued", "batched", "checking", "merging", "merged", "deploy_verified",
];

const STAGE_RE = /^([a-z_]{1,32})(?: \(([^()\n]{1,200})\))?$/;

// jobClass(name): a check name minus ONE trailing shard suffix: ` (...)`,
// ` <n>` or `/<n>`. "test (3)" → "test", "shard 2" → "shard", "lint/1" →
// "lint". A name the strip would empty is returned whole.
export function jobClass(name) {
  const s = String(name ?? "").trim();
  const out = s.replace(/(?:\s+\([^()]*\)|\s+\d+|\/\d+)$/, "").trim();
  return out || s;
}

// queueStageStmt(db, {repo, pr, stage, since, at, actor}) → one prepared
// INSERT OR IGNORE, for the caller's batch. Throws on a stage outside
// QUEUE_STAGES, a repo that is not an owner/name slug, or a pr that is not a
// positive integer: a bad stage row is a bug in the caller, never a row.
export function queueStageStmt(db, { repo, pr, stage, since, at, actor } = {}) {
  const m = STAGE_RE.exec(String(stage ?? ""));
  if (!m || !QUEUE_STAGES.includes(m[1])) throw new Error(`queue stage not in QUEUE_STAGES: ${String(stage).slice(0, 64)}`);
  if (!WAKE_REPO_RE.test(String(repo ?? ""))) throw new Error("queue stage repo must be owner/name");
  if (!Number.isInteger(pr) || pr <= 0 || pr >= 1e9) throw new Error("queue stage pr must be a positive integer");
  const s = String(since ?? "").slice(0, 64);
  if (!s) throw new Error("queue stage since is required");
  return db.prepare(
    `INSERT OR IGNORE INTO pr_state_events (repo, number, state, since, reason, alerted, at, actor)
     VALUES (?1, ?2, 'queue', ?3, ?4, '-', ?5, ?6)`
  ).bind(repo, pr, s, String(stage), String(at ?? s).slice(0, 64), actor == null ? null : String(actor).slice(0, 64));
}
