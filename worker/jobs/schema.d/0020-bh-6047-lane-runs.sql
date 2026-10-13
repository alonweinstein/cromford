-- BH-6124 (BH-6047 part 1 of 5): the lane-run queue. A lane placed `fly`
-- (settings row lane_placement.<lane>, else lane_placement.default) is
-- enqueued by pl_dispatch as one row here; a machine running
-- bin/lane-run-worker.sh claims it (routes/lane-runs.js, one statement), runs
-- it and reports its rc. Timestamps are ISO YYYY-MM-DDTHH:MM:SSZ, so a string
-- compare on lease_until is a time compare.
CREATE TABLE IF NOT EXISTS lane_runs (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  lane TEXT NOT NULL,
  project TEXT NOT NULL,
  args_json TEXT NOT NULL,
  enqueued_at TEXT NOT NULL,
  enqueued_by TEXT,
  claimed_at TEXT,
  claimed_by TEXT,
  lease_until TEXT,
  heartbeat_at TEXT,
  attempts INTEGER NOT NULL DEFAULT 0,
  status TEXT NOT NULL DEFAULT 'queued' CHECK (status IN ('queued','claimed','done','died')),
  rc INTEGER,
  prof_line TEXT,
  finished_at TEXT
);
-- The fleet-wide dedupe: at most one live run of a (lane, project).
CREATE UNIQUE INDEX IF NOT EXISTS lane_runs_live ON lane_runs(lane, project) WHERE status IN ('queued','claimed');
CREATE INDEX IF NOT EXISTS idx_lane_runs_claim ON lane_runs(status, enqueued_at, id);
CREATE INDEX IF NOT EXISTS idx_lane_runs_lane ON lane_runs(lane, status);
-- Every lane stays on the hub until an operator sets lane_placement.<lane>=fly.
INSERT OR IGNORE INTO settings (key,value,note,actor,updated_at) VALUES
  ('lane_placement.default','hub','BH-6124: where a lane runs when it has no lane_placement.<lane> row (fly|hub; anything but fly is hub); the code default is hub','seed','2026-10-12T00:00:00Z'),
  ('lane_run.lease_s','120','BH-6124: seconds a claimed lane run is held before another machine may re-claim it (30..3600); the code default is 120','seed','2026-10-12T00:00:00Z'),
  ('lane_run.poll_s','15','BH-6124: seconds bin/lane-run-worker.sh sleeps after an empty claim (1..300); the code default is 15','seed','2026-10-12T00:00:00Z');
