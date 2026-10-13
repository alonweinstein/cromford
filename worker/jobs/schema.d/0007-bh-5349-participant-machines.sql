-- ── BH-5349 (BH-5348.0): participant machines ──
-- A machine outside the Fly pool asks to take part in tickets (a lane by
-- another name), the lead approves it, and participantAuth
-- (src/routes/participants.js) checks the token it holds. Not the pool's
-- `machines` table: the pool reaper destroys rows there. The worker stores only
-- the sha256 of the token the machine generated; it never sees the secret.
-- name is stored trimmed and lowercased. D1 has no RLS; the bearer guards /api/*.
CREATE TABLE IF NOT EXISTS participant_machines (
  id TEXT PRIMARY KEY,
  name TEXT NOT NULL UNIQUE,
  owner TEXT,
  requested_roles TEXT NOT NULL,   -- JSON array of build | fix | lead-review
  granted_roles TEXT,              -- JSON array, NULL until approved
  token_sha256 TEXT NOT NULL UNIQUE,
  billing_account TEXT,
  status TEXT NOT NULL DEFAULT 'pending' CHECK (status IN ('pending','approved','denied','revoked')),
  requested_at TEXT NOT NULL,
  decided_by TEXT,
  decided_at TEXT,
  revoked_by TEXT,
  revoked_at TEXT,
  last_seen_at TEXT,
  knobs TEXT                       -- JSON object, NULL reads as {}
);
CREATE INDEX IF NOT EXISTS idx_participant_machines_status ON participant_machines(status);
INSERT OR IGNORE INTO settings (key,value,note,actor,updated_at) VALUES
  ('lead_review_claim_stale_s','900','BH-5349: seconds a running lead review claim may go without heartbeat_at before another claimer may take it; no reader yet (a BH-5348 sibling), code fallback 900','seed','2026-10-08T00:00:00Z');

