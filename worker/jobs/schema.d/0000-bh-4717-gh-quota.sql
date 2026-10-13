-- BH-4717.2: the gh-quota line's dedupe, one seed per statement as above.
INSERT OR IGNORE INTO settings (key,value,note,actor,updated_at) VALUES
  ('gh_quota_alert_dedupe_s','7200','BH-4717: seconds before one credential''s gh-quota line repeats, unless it fell by gh_quota_alert_band_pct','seed','2026-10-05T00:00:00Z');

INSERT OR IGNORE INTO settings (key,value,note,actor,updated_at) VALUES
  ('gh_quota_alert_band_pct','10','BH-4717: a fall of this many percent points re-fires the gh-quota line inside the dedupe window','seed','2026-10-05T00:00:00Z');

