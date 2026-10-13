-- BH-5227: the watermark bin/port-to-cromford.sh keeps per public target. The
-- last upstream sha ported to <target> (owner/name) and the PR that carried it.
-- Moved only by compare-and-set (PUT /api/port/cursor), so two ports of one
-- target cannot both land. D1 has no RLS; the bearer on /api/* guards it.
-- Additive only: it removes nothing. bin/harness-sync.sh applies it before deploy.
CREATE TABLE IF NOT EXISTS port_cursor (
  target TEXT PRIMARY KEY,
  upstream_sha TEXT NOT NULL,
  pr_url TEXT,
  updated_at TEXT NOT NULL
);
INSERT OR IGNORE INTO settings (key,value,note,actor,updated_at) VALUES
  ('qa.personas_per_area','1','BH-5204 (the operator 2026-10-07): personas driven per changed app area in preview and post-merge QA; E2E_MAX_PERSONAS stays the ceiling','seed','2026-10-07T00:00:00Z');
