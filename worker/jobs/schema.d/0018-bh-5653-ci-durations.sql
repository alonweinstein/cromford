-- ── BH-5653: CI suite durations ──
-- Per-suite wall seconds from each green Mergify batch CI run, posted by
-- `bin/ci-durations.sh post` (POST /api/ci/suite-durations, src/routes/ci-durations.js)
-- and read back by `bin/ci-durations.sh fetch` for the shard balancer.
-- ci_duration_runs is the idempotency key: one row per accepted post, bound to
-- the sha256 of its sorted rows. ci_suite_duration_samples holds the newest
-- `ci_suite_durations.window` samples per suite; ci_suite_durations is their
-- median, keyed on the suite path. D1 has no RLS; the route's own bearer guards it.
CREATE TABLE IF NOT EXISTS ci_duration_runs (
  run_id INTEGER PRIMARY KEY,
  digest TEXT NOT NULL,
  suites INTEGER NOT NULL,
  source TEXT NOT NULL CHECK (source IN ('ci','seed')),
  posted_at TEXT NOT NULL
);
CREATE TABLE IF NOT EXISTS ci_suite_duration_samples (
  suite TEXT NOT NULL,
  run_id INTEGER NOT NULL,
  seconds REAL NOT NULL,
  PRIMARY KEY (suite, run_id)
);
CREATE TABLE IF NOT EXISTS ci_suite_durations (
  suite TEXT PRIMARY KEY,
  seconds REAL NOT NULL,
  source_run INTEGER NOT NULL,
  samples INTEGER NOT NULL,
  updated_at TEXT NOT NULL
);
INSERT OR IGNORE INTO settings (key,value,note,actor,updated_at) VALUES ('ci_suite_durations.window','3','BH-5653: samples in the rolling median per suite (1..15); code fallback 3','seed','2026-10-09T00:00:00Z');
