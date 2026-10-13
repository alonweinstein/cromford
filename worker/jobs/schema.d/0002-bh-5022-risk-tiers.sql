-- ── BH-5022 (BH-4973.1): the rule-based risk tier ────────────────────────────
-- One row per classified PR head, written by bin/lead-review-enqueue.sh through
-- POST /api/risk-tiers for every mode except off; read by Mission Control (the
-- PR screen and the Merge Queue's RISK TIERS section). The first classification
-- of a head is kept: ON CONFLICT(repo, pr, head_sha) DO NOTHING in the route.
-- tier: low | medium | high. mode: off | shadow | enforce. action: what the lane
-- did with it (sign-off | would-sign-off | request | request-first). Enum values sit
-- in comments, not CHECKs (D1 cannot ALTER a CHECK). D1, not Supabase: no RLS,
-- the worker bearer is the access boundary. Self-create copy:
-- CREATED_TABLES.risk_tiers in src/lib/core.js.
CREATE TABLE IF NOT EXISTS risk_tiers (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  repo TEXT NOT NULL,              -- owner/name
  pr INTEGER NOT NULL,
  head_sha TEXT NOT NULL,          -- the full 40-hex sha that was classified
  project TEXT,
  tier TEXT NOT NULL,              -- low | medium | high
  mode TEXT NOT NULL,              -- off | shadow | enforce
  action TEXT,                     -- sign-off | would-sign-off | request | request-first
  reasons TEXT,
  lines INTEGER,                   -- additions + deletions
  files INTEGER,
  created_at TEXT NOT NULL,
  UNIQUE(repo, pr, head_sha)
);
CREATE INDEX IF NOT EXISTS idx_risk_tiers_repo_pr ON risk_tiers(repo, pr);
CREATE INDEX IF NOT EXISTS idx_risk_tiers_tier ON risk_tiers(tier, id);
-- The per-repo mode (risk_tier.mode.<owner>.<name>, lowercase; it wins over the
-- global risk_tier.mode). cromford signs off its own low-risk PRs from the
-- first tick after deploy. INSERT OR IGNORE, so an operator's shadow or off is
-- never reset by a later deploy. risk_tier.* is a signed family (PROTECTED_PREFIXES).
INSERT OR IGNORE INTO settings (key,value,note,actor,updated_at) VALUES
  ('risk_tier.mode.example-org.cromford','enforce','BH-5022: off | shadow | enforce. enforce = a low-risk builder-approved head is signed off (source=risk-tier MERGE) with no lead review','seed','2026-10-07T00:00:00Z');
-- BH-5289: the fleet default for every repo without its own row is OFF. The mode rows are
-- read only for repos in RT_MODE_REPOS (bin/lib/risk-tier.sh); any other repo is off whatever
-- its rows say. INSERT OR IGNORE: an operator's global row survives.
INSERT OR IGNORE INTO settings (key,value,note,actor,updated_at) VALUES
  ('risk_tier.mode','off','BH-5289: off | shadow | enforce. Fleet default for repos with no risk_tier.mode.<owner>.<name> row; read only for repos in RT_MODE_REPOS (bin/lib/risk-tier.sh)','seed','2026-10-07T00:00:00Z');
