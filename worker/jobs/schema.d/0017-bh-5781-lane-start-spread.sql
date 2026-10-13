-- BH-5781: the quarter-hour start spread (bin/lib/lane-gate.sh lane_start_offset).
-- Every D1 overload on 2026-10-09 landed at :00/:15/:30/:45, when every box
-- starts its quarter-hour lanes at once. A box waits cksum(box) mod (spread+1)
-- seconds before its first D1 read at those minutes. The code default is 0
-- (off), so this row is what turns it on; 0 here turns it off fleet-wide.
INSERT OR IGNORE INTO settings (key,value,note,actor,updated_at) VALUES
  ('lane_start_spread_s','120','BH-5781: seconds of per-box start spread at :00/:15/:30/:45 (0..600; 0 = off); the code default is 0','seed','2026-10-10T00:00:00Z');
