
-- ── BH-5560 (BH-5556.3): the staff findings ledger and suppressions ──────────
-- staff_findings: one row per claimed finding. fingerprint is agent-core
-- fingerprint() of the item, computed by POST /api/staff/findings/claim, and it
-- is UNIQUE across all agents: a second claim of the same item is refused.
-- The claim is written BEFORE any filing or model call. source_url is agent-core
-- canonicalUrl() (no query, fragment or userinfo), so a token never lands here.
-- status/ticket_url have no writer yet. Wave 4 records the filing on the row.
-- staff_suppressions: a human-approved, expiring mute for one fingerprint. It
-- matches a claim only when status = 'active' AND expires_at > now (strict).
-- 'pending' is for wave 6 (an agent proposes, a human approves).
-- D1 is SQLite, not Supabase: RLS does not apply. Only IF NOT EXISTS
-- statements, so a re-apply through bin/harness-sync.sh is a no-op.
CREATE TABLE IF NOT EXISTS staff_findings (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  fingerprint TEXT NOT NULL UNIQUE CHECK (length(fingerprint) = 64),
  agent TEXT NOT NULL,
  title TEXT NOT NULL,
  source_kind TEXT NOT NULL,
  source_url TEXT NOT NULL,
  source_labels TEXT NOT NULL,
  source_filed_by TEXT,
  observed_at TEXT NOT NULL,
  status TEXT NOT NULL DEFAULT 'claimed',
  ticket_url TEXT,
  claimed_at TEXT NOT NULL,
  updated_at TEXT NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_staff_findings_agent ON staff_findings(agent, id);
CREATE TABLE IF NOT EXISTS staff_suppressions (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  fingerprint TEXT NOT NULL CHECK (length(fingerprint) = 64),
  reason TEXT NOT NULL CHECK (length(trim(reason)) > 0),
  approver TEXT,
  expires_at TEXT NOT NULL,
  status TEXT NOT NULL DEFAULT 'active' CHECK (status IN ('pending','active','revoked')),
  created_at TEXT NOT NULL,
  UNIQUE (fingerprint, approver, expires_at),
  CHECK (status <> 'active' OR (approver IS NOT NULL AND length(trim(approver)) > 0))
);
CREATE INDEX IF NOT EXISTS idx_staff_suppressions_fp ON staff_suppressions(fingerprint, status, expires_at);
