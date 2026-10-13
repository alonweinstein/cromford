-- ── BH-5839 (Mission Control step-in): steer_notes ──
-- One row per message an operator sends from a ticket page's "Step in"
-- composer (BH-4991 first cut). mode now: the build takes it at its next step
-- boundary (bin/lib/steer.sh, POST /api/steer/take, status taken), and the
-- call's exit settles it: read when the call ran, pending again when it did not.
-- mode ticket: the hub claims it (status delivering), then posts it as one
-- issue comment (bin/lib/steer-deliver.sh).
-- mode hold: the hub holds the ticket with it as the reason, and the job it was
-- sent to stops at its next step boundary (build_read_at). Self-creates
-- (core.js CREATED_TABLES); a test compares the two DDLs. D1 has no RLS; the
-- worker's bearer guards every route, and a browser reaches only POST steer and
-- the GETs through the coord proxy's session check.
-- steer.attempts_max: failed hub deliveries before a note is failed.
-- steer.outbox_limit: notes the hub delivers per poll-commands tick.
-- steer.take_lease_s: seconds before a taken, unsettled "now" note is taken again.
-- steer.deliver_lease_s: seconds before a claimed, unreported note is offered again.
CREATE TABLE IF NOT EXISTS steer_notes (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  project TEXT NOT NULL,
  ticket TEXT NOT NULL,
  job_id TEXT,
  mode TEXT NOT NULL CHECK (mode IN ('now','ticket','hold')),
  text TEXT NOT NULL,
  actor TEXT NOT NULL,
  status TEXT NOT NULL CHECK (status IN ('pending','taken','read','delivering','delivered','failed')),
  attempts INTEGER NOT NULL DEFAULT 0,
  detail TEXT,
  build_read_at TEXT,
  delivered_at TEXT,
  created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_steer_notes_ticket ON steer_notes(project, ticket, id);
CREATE INDEX IF NOT EXISTS idx_steer_notes_job ON steer_notes(job_id, mode, status);
CREATE INDEX IF NOT EXISTS idx_steer_notes_outbox ON steer_notes(status, mode, id);
INSERT OR IGNORE INTO settings (key,value,note,actor,updated_at) VALUES ('steer.attempts_max','3','BH-5839: failed hub deliveries before a steer note is failed (1..10); code fallback 3','seed','2026-10-11T00:00:00Z');
INSERT OR IGNORE INTO settings (key,value,note,actor,updated_at) VALUES ('steer.outbox_limit','10','BH-5839: steer notes the hub delivers per poll-commands tick (1..100); code fallback 10','seed','2026-10-11T00:00:00Z');
INSERT OR IGNORE INTO settings (key,value,note,actor,updated_at) VALUES ('steer.take_lease_s','7200','BH-5839: seconds before a taken, unsettled steer now note is taken again (60..86400); code fallback 7200','seed','2026-10-12T00:00:00Z');
INSERT OR IGNORE INTO settings (key,value,note,actor,updated_at) VALUES ('steer.deliver_lease_s','300','BH-5839: seconds before a claimed, unreported steer note is offered to the hub again (60..3600); code fallback 300','seed','2026-10-12T00:00:00Z');
