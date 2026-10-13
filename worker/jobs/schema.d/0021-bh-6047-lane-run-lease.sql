-- BH-6125 (BH-6047 part 2 of 5): the lease heartbeat and the death count of
-- the lane-run queue (routes/lane-runs-lease.js, bin/lib/lane-run-heartbeat.sh).
INSERT OR IGNORE INTO settings (key,value,note,actor,updated_at) VALUES
  ('lane_run.heartbeat_s','30','BH-6125: seconds between the heartbeats bin/lane-run-worker.sh sends for a claimed lane run (1..300); the code default is 30','seed','2026-10-12T00:00:00Z'),
  ('lane_run.max_attempts','3','BH-6125: claims a lane run may take before an expired lease marks it died, rc 137 (1..20); the code default is 3','seed','2026-10-12T00:00:00Z');
