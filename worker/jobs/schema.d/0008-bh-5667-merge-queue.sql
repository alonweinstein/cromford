-- ── BH-5667 (BH-5008 child 1): the live merge queue ─────────────────────────
-- Mergify's batch drafts, as the signed GitHub webhook reports them. The one
-- writer is the github receiver (src/routes/webhooks.js through
-- src/lib/merge-queue-intake.js): a `pull_request` or `check_run` delivery on a
-- `mergify/merge-queue/<suffix>` ref, for a repo in `projects` or in the
-- `merge_queue_repos` settings row, upserts in the SAME batch as its
-- webhook_deliveries row. The reader is GET /api/merge-queue/live. Every row
-- comes from a delivery, so the tables are the local copy of the queue: no
-- GitHub or Mergify read fills them. The columns BH-5008's other children
-- write (eta_at, bisect_*, the medians) are declared now and stay NULL here.
-- outcome is 'merged' ONLY on pull_request.merged === true. An unmerged close
-- is 'failed' when a check row failed, else 'closed' (unknown).
CREATE TABLE IF NOT EXISTS merge_queue_batches (
  repo TEXT NOT NULL,
  draft_pr INTEGER NOT NULL,
  members_json TEXT NOT NULL DEFAULT '[]',
  base_sha TEXT,
  started_at TEXT,
  finished_at TEXT,
  outcome TEXT,
  eta_at TEXT,
  bisect_parent INTEGER,
  bisect_step INTEGER,
  bisect_steps INTEGER,
  updated_at TEXT NOT NULL,
  PRIMARY KEY (repo, draft_pr)
);
CREATE TABLE IF NOT EXISTS merge_queue_checks (
  repo TEXT NOT NULL,
  draft_pr INTEGER NOT NULL,
  name TEXT NOT NULL,
  job_class TEXT,
  status TEXT,
  conclusion TEXT,
  url TEXT,
  started_at TEXT,
  finished_at TEXT,
  updated_at TEXT NOT NULL,
  PRIMARY KEY (repo, draft_pr, name)
);
CREATE INDEX IF NOT EXISTS idx_merge_queue_checks_median ON merge_queue_checks(repo, name, conclusion, finished_at);
CREATE TABLE IF NOT EXISTS merge_queue_check_medians (
  repo TEXT NOT NULL,
  name TEXT NOT NULL,
  job_class TEXT,
  median_s INTEGER,
  samples INTEGER,
  updated_at TEXT NOT NULL,
  PRIMARY KEY (repo, name)
);
