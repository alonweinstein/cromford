-- ── BH-5024 (BH-4973.3): the Jev second-opinion spend ledger ────────────────
-- One row per (repo, pr, head_sha, question_version), claimed BEFORE any call
-- to TypeSafe jev-latest and settled after it (src/routes/jev-risk.js). The
-- only writer is bin/jev-risk.sh: the shadow hook in bin/lead-review-enqueue.sh
-- and the replay pilot (docs/jev-pilot/replay.py) share it, so a head already
-- asked is never paid twice. ok and empty are terminal (empty is a billed
-- answer with no usable choice); failed is retried up to jev_risk.max_attempts.
-- rule_tier is the tier Jev was shown, jev_tier/jev_prob its answer on ok, raw
-- the vendor payload snapshot (at most 8000 chars). Never pruned: one row per
-- head ever asked. D1, not Supabase: no RLS, the worker bearer is the access
-- boundary. Self-create copy: CREATED_TABLES.jev_risk_calls in src/lib/core.js.
CREATE TABLE IF NOT EXISTS jev_risk_calls (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  repo TEXT NOT NULL,              -- owner/name
  pr INTEGER NOT NULL,
  head_sha TEXT NOT NULL,          -- 40 lower hex
  question_version TEXT NOT NULL,  -- v1, bumped when the question text changes
  status TEXT NOT NULL CHECK (status IN ('claimed','ok','empty','failed')),
  attempts INTEGER NOT NULL DEFAULT 0,
  rule_tier TEXT,                  -- low | medium | high
  jev_tier TEXT,                   -- low | medium | high on ok, NULL otherwise
  jev_prob REAL,                   -- 0..1 on ok
  model TEXT,                      -- jev-latest
  caller TEXT,                     -- shadow:<box> | pilot
  error TEXT,
  raw TEXT,
  claimed_at TEXT,
  created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL,
  UNIQUE(repo, pr, head_sha, question_version)
);
CREATE INDEX IF NOT EXISTS idx_jev_risk_repo_pr ON jev_risk_calls(repo, pr);
-- The knobs. jev_risk.mode ships off: only exact `shadow` turns the hook on,
-- and the replay pilot has to pass before anyone sets it. jev_risk.api_url is
-- NOT seeded: there is no vendor URL in this repo, and with no row the client
-- answers not-configured and calls nothing. None of these decides a merge, so
-- jev_risk.* is not a signed family. INSERT OR IGNORE, one seed per statement.
INSERT OR IGNORE INTO settings (key,value,note,actor,updated_at) VALUES
  ('jev_risk.mode','off','BH-5024: off | shadow. shadow = bin/lead-review-enqueue.sh asks Jev about each newly classified head and logs the answer next to the rule tier; it never decides','seed','2026-10-07T00:00:00Z');
INSERT OR IGNORE INTO settings (key,value,note,actor,updated_at) VALUES
  ('jev_risk.model','jev-latest','BH-5024: the TypeSafe model bin/jev-risk.sh asks','seed','2026-10-07T00:00:00Z');
INSERT OR IGNORE INTO settings (key,value,note,actor,updated_at) VALUES
  ('jev_risk.max_per_tick','3','BH-5024: Jev shadow asks per lead-review-enqueue tick, across every repo; a head over it is not asked','seed','2026-10-07T00:00:00Z');
INSERT OR IGNORE INTO settings (key,value,note,actor,updated_at) VALUES
  ('jev_risk.timeout_s','30','BH-5024: seconds one Jev call may take; a claim older than twice this is a crashed caller and may be reclaimed','seed','2026-10-07T00:00:00Z');
INSERT OR IGNORE INTO settings (key,value,note,actor,updated_at) VALUES
  ('jev_risk.max_attempts','2','BH-5024: paid tries per head before the ledger refuses with attempt_cap','seed','2026-10-07T00:00:00Z');
INSERT OR IGNORE INTO settings (key,value,note,actor,updated_at) VALUES
  ('jev_risk.max_diff_chars','60000','BH-5024: the diff Jev is shown is cut here, with a [truncated] marker','seed','2026-10-07T00:00:00Z');
-- The replay pilot's Haiku baseline (docs/jev-pilot/replay.py, through
-- lane_model JEV_BASELINE_MODEL jev-pilot.baseline). It copies the model and
-- runner of the hub review.trivial route seeded above (the cheap tier), so no
-- model id is written here a second time. No review.trivial row = no seed, and
-- the pilot stops with "no baseline model route". Same tombstone guard.
INSERT OR IGNORE INTO model_routes (scope, project, role, position, model, runner, updated_by, updated_at)
  SELECT 'hub', NULL, 'jev-pilot.baseline', 0, r.model, r.runner, 'seed', '2026-10-07T00:00:00Z'
  FROM model_routes r
  WHERE r.project IS NULL AND r.role = 'review.trivial' AND r.position = 0
    AND NOT EXISTS (SELECT 1 FROM model_route_changes c WHERE c.project IS NULL AND c.role = 'jev-pilot.baseline');

