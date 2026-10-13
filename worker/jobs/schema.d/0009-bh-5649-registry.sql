
-- ── BH-5649 (BH-5633.1): the fleet registry ──
-- The fleet registry in D1: projects, boxes, lane membership and account→box maps. Read by bin/lib/registry.sh when REGISTRY_SOURCE=db (GET /api/registry); written in wave 1 only by bin/registry-seed.sh through POST /api/registry/import. registry_meta holds the ONE version number: every import that changes a row bumps it once.
-- NO RLS STEP: Cloudflare D1 behind the bearer-authed worker, like every table here.
CREATE TABLE IF NOT EXISTS registry_meta (id INTEGER PRIMARY KEY CHECK (id = 1), version INTEGER NOT NULL, updated_at TEXT NOT NULL);
INSERT OR IGNORE INTO registry_meta (id, version, updated_at) VALUES (1, 0, '2026-10-09T00:00:00Z');
CREATE TABLE IF NOT EXISTS registry_projects (project TEXT PRIMARY KEY, repo TEXT NOT NULL, prod TEXT NOT NULL, board_prefix TEXT NOT NULL, cron_offset INTEGER NOT NULL CHECK (cron_offset BETWEEN 0 AND 9), box TEXT, position INTEGER NOT NULL, status TEXT NOT NULL DEFAULT 'active' CHECK (status IN ('active','retired')), updated_at TEXT NOT NULL);
CREATE TABLE IF NOT EXISTS registry_boxes (box TEXT PRIMARY KEY, box_id TEXT NOT NULL, tailnet_ip TEXT, cost_box TEXT, standby_hub_name TEXT, standby_hub_id TEXT, updated_at TEXT NOT NULL);
CREATE TABLE IF NOT EXISTS registry_lane_boxes (lane TEXT NOT NULL, box_id TEXT NOT NULL, updated_at TEXT NOT NULL, PRIMARY KEY (lane, box_id));
CREATE TABLE IF NOT EXISTS registry_box_accounts (account TEXT NOT NULL, kind TEXT NOT NULL CHECK (kind IN ('login','cost_rows','jobs')), box TEXT NOT NULL, updated_at TEXT NOT NULL, PRIMARY KEY (account, kind, box));
CREATE TABLE IF NOT EXISTS registry_audit (id INTEGER PRIMARY KEY AUTOINCREMENT, at TEXT NOT NULL, actor TEXT NOT NULL, entity TEXT NOT NULL CHECK (entity IN ('project','box','lane_box','box_account')), key TEXT NOT NULL, old_value TEXT, new_value TEXT, version INTEGER NOT NULL);
CREATE INDEX IF NOT EXISTS idx_registry_audit_at ON registry_audit(at);
