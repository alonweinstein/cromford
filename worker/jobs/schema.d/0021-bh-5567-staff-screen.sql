-- ── BH-5567 (BH-5556.10): Archie's row on the staff screen roster ───────────
-- GET /api/staff/roster (src/routes/staff-screen.js) shows Archie above the
-- seven staff_agents rows. Archie is not a staff_agents row, so its role and
-- accountable person are these two settings rows, not code constants. An
-- absent row reads as null ("n/a" on the screen), never a fallback value.
-- One seed per statement, INSERT OR IGNORE: a re-apply never resets an edit.
INSERT OR IGNORE INTO settings (key,value,note,actor,updated_at) VALUES
  ('staff.archie.role','overlooker','BH-5567: Archie''s role on the /staff roster','seed','2026-10-10T00:00:00Z');
INSERT OR IGNORE INTO settings (key,value,note,actor,updated_at) VALUES
  ('staff.archie.accountable','operator@example.com','BH-5567: the human accountable for Archie on the /staff roster','seed','2026-10-10T00:00:00Z');
