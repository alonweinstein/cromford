-- BH-5354.0 (BH-5366) — the suite ledger: one row per (repo, ctx, class, suite,
-- input fingerprint), so a green suite whose inputs did not move need not run
-- again. `fail` is sticky (the upsert in routes/suite-results.js merges it in
-- SQL), and `class` comes from the credential (ci = x-suite-ledger-token,
-- builder = bearer), never from the body. suite_reuse_runs is one row per
-- runner invocation (ran vs reused, seconds saved). Self-created by
-- CREATED_TABLES too. D1 has no RLS; the route's credentialClass() is the
-- deny-by-default (an unset secret refuses).
CREATE TABLE IF NOT EXISTS suite_results (
  repo TEXT NOT NULL,
  ctx TEXT NOT NULL,
  class TEXT NOT NULL,
  suite TEXT NOT NULL,
  fingerprint TEXT NOT NULL,
  status TEXT NOT NULL,
  duration_s INTEGER,
  run_id TEXT NOT NULL,
  head_sha TEXT,
  ok_at TEXT,
  last_run_id TEXT NOT NULL,
  runs INTEGER NOT NULL DEFAULT 1,
  fails INTEGER NOT NULL DEFAULT 0,
  first_at TEXT NOT NULL,
  updated_at TEXT NOT NULL,
  PRIMARY KEY (repo, ctx, class, suite, fingerprint)
);
CREATE INDEX IF NOT EXISTS idx_suite_results_updated ON suite_results(updated_at);
-- The lookup's seek: the PK puts class before suite, so it cannot seek on
-- (suite, fingerprint) for a (repo, ctx) without this.
CREATE INDEX IF NOT EXISTS idx_suite_results_key ON suite_results(repo, ctx, suite, fingerprint);
CREATE TABLE IF NOT EXISTS suite_reuse_runs (
  repo TEXT NOT NULL,
  run_key TEXT NOT NULL,
  ctx TEXT NOT NULL,
  class TEXT NOT NULL,
  head_sha TEXT,
  ran INTEGER NOT NULL,
  reused INTEGER NOT NULL,
  total INTEGER NOT NULL,
  saved_s INTEGER NOT NULL DEFAULT 0,
  created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL,
  PRIMARY KEY (repo, run_key)
);
CREATE INDEX IF NOT EXISTS idx_suite_reuse_runs_created ON suite_reuse_runs(created_at);
