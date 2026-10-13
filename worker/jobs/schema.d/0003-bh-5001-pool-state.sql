-- ── BH-5001 (BH-4951.2): the Fly pool's money-deciding state ─────────────────
-- WHY TABLES. bin/fly-pool.sh decided three spends from files that exist only
-- on the hub, under state/pool/<p>/: the per-key spawn ledger (<KEY>.spawns),
-- the push-rejected terminal verdict (<KEY>.terminal) and the lane-failure
-- spawn hold (_spawn-hold), plus the held marker (<KEY>.held) the fleet page
-- counts. A rebuilt or failed-over hub lost all of them, and each loss buys
-- performance-8x machines: every capped key got POOL_SPAWN_CAP_PER_KEY fresh
-- spawns, every terminal key respawned, and a held lane was forgotten.
-- The rows are read FIRST and the files second while `pool_state_rows` is on;
-- the files are still written in every case. The shell seam is
-- bin/lib/pool-state-rows.sh, the routes worker/jobs/src/routes/pool-state.js,
-- and bin/pool-state.sh backfills them from a hub's files.
-- pool_spawns: one row per .spawns line. ts is epoch seconds; box is the hub
-- that recorded it, and a backfill keys the k-th repeat of one ts in one file
-- as <box>#k, so a re-run collides on the key instead of counting twice.
-- pool_terminals: a re-arm sets cleared_at instead of deleting, so the verdict
-- and why it was lifted stay on record; a new verdict resets it to NULL.
-- pool_holds: kind 'spawn' is the project hold (ticket_key '', until_at epoch);
-- kind 'ticket' is a <KEY>.held marker (until_at NULL). Holds are transient: a
-- clear deletes the row, as the file is deleted.
-- D1 has no RLS. The worker bearer auth guards /api/*.
CREATE TABLE IF NOT EXISTS pool_spawns (
  project TEXT NOT NULL,
  ticket_key TEXT NOT NULL,
  ts INTEGER NOT NULL,
  box TEXT NOT NULL,
  machine TEXT,
  created_at TEXT NOT NULL,
  PRIMARY KEY (project, ticket_key, ts, box)
);
CREATE INDEX IF NOT EXISTS idx_pool_spawns_ts ON pool_spawns(project, ts);
CREATE TABLE IF NOT EXISTS pool_terminals (
  project TEXT NOT NULL,
  ticket_key TEXT NOT NULL,
  branch TEXT,
  head_sha TEXT,
  reason TEXT,
  created_at TEXT NOT NULL,
  box TEXT,
  cleared_at TEXT,
  cleared_why TEXT,
  updated_at TEXT NOT NULL,
  PRIMARY KEY (project, ticket_key)
);
CREATE TABLE IF NOT EXISTS pool_holds (
  project TEXT NOT NULL,
  kind TEXT NOT NULL,
  ticket_key TEXT NOT NULL,
  ticket_id TEXT,
  until_at INTEGER,
  why TEXT,
  first_seen TEXT,
  last_seen TEXT,
  box TEXT,
  updated_at TEXT NOT NULL,
  PRIMARY KEY (project, kind, ticket_key)
);
INSERT OR IGNORE INTO settings (key,value,note,actor,updated_at) VALUES
  ('pool_state_rows','0','BH-5001: Fly pool spawn caps, terminals and holds are pool_* ROWS first, state/pool/<p>/ second','seed','2026-10-07T00:00:00Z');
