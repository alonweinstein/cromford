-- ── BH-4587 (BH-4574.5): Archie's self-improvement loop ─────────────────────
-- bin/archie-fm-improve.sh reads these. A cause that recurs recur_n times in a
-- rolling window_days gets ONE ai-build issue; at most tickets_per_day new
-- issues and archie.cap.improve GitHub writes per UTC day. A fix is verified
-- after verify_days of silence; occurrences inside verify_grace_s after the
-- close do not reopen it. INSERT OR IGNORE, so an operator's edit survives.
INSERT OR IGNORE INTO settings (key,value,note,actor,updated_at) VALUES
  ('archie.cap.improve','10','BH-4587: archie-fm-improve GitHub writes per UTC day (issues filed, comments, reopens, verify comments); 0 = the playbook is off','seed','2026-10-11T00:00:00Z'),
  ('archie.improve.recur_n','3','BH-4587: occurrences of one cause fingerprint inside archie.improve.window_days that file ONE ai-build issue','seed','2026-10-11T00:00:00Z'),
  ('archie.improve.window_days','7','BH-4587: the rolling window, in days, the recurrence count reads (1..30)','seed','2026-10-11T00:00:00Z'),
  ('archie.improve.tickets_per_day','3','BH-4587: new archie-fm-improve issues per UTC day; the rest wait for the next day','seed','2026-10-11T00:00:00Z'),
  ('archie.improve.verify_days','7','BH-4587: days of no recurrence after a fix closed before Archie records it verified (1..14)','seed','2026-10-11T00:00:00Z'),
  ('archie.improve.verify_grace_s','3600','BH-4587: seconds after the close in which a recurrence is deploy lag and does not reopen the issue','seed','2026-10-11T00:00:00Z');
