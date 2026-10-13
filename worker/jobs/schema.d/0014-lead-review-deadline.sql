
-- ── BH-5779: the lead review running deadline ───────────────────────────────
-- POST /api/lead-reviews/reclaim-stale takes back a running lead review that
-- went this many seconds without heartbeat_at (else updated_at). The reader
-- floors it at lead_review_claim_stale_s (fragment 0007).
INSERT OR IGNORE INTO settings (key,value,note,actor,updated_at) VALUES ('lead_review_running_deadline_s','3600','BH-5779: seconds a running lead review may go without heartbeat_at (else updated_at) before POST /api/lead-reviews/reclaim-stale takes it back; floored at lead_review_claim_stale_s; code fallback 3600 (LEAD_REVIEW_DEADLINE_S default)','seed','2026-10-09T00:00:00Z');
