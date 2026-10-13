-- BH-5267 (BH-5248.1): every project's conflict hotspots, measured weekly on the
-- box that owns it by bin/conflict-hotspots-fleet.sh (which runs
-- bin/conflict-hotspots.sh against /root/repos/<project>) and stored through
-- PUT /api/conflict-hotspots (routes/conflict-hotspots.js). One window per
-- project: a PUT with status ok replaces the project's rows in one batch.
-- conflict_hotspot_runs is one row per project, so "measured, nothing
-- collided" (status ok, no rows), "never measured" (no row) and "the latest
-- run failed" (status not ok, the last good window kept, last_ok_at) differ.
-- NO RLS STEP: Cloudflare D1 behind the bearer-authed worker, like every table here.
CREATE TABLE IF NOT EXISTS conflict_hotspots (
  project TEXT NOT NULL,
  file TEXT NOT NULL,
  conflicts INTEGER NOT NULL,
  rebases INTEGER NOT NULL,
  prs TEXT,
  window_days INTEGER NOT NULL,
  since TEXT NOT NULL,
  until TEXT NOT NULL,
  ref_sha TEXT,
  run_at TEXT NOT NULL,
  PRIMARY KEY (project, file)
);
CREATE INDEX IF NOT EXISTS idx_conflict_hotspots_rank ON conflict_hotspots(project, conflicts DESC, rebases DESC, file);
CREATE TABLE IF NOT EXISTS conflict_hotspot_runs (
  project TEXT PRIMARY KEY,
  repo TEXT,
  box TEXT,
  status TEXT NOT NULL,
  detail TEXT,
  window_days INTEGER,
  since TEXT,
  until TEXT,
  ref_sha TEXT,
  pr_merges INTEGER,
  sync_merges INTEGER,
  merge_tree_errors INTEGER,
  files_total INTEGER,
  rows_stored INTEGER,
  run_at TEXT NOT NULL,
  last_ok_at TEXT
);

