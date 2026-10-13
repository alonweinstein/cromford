
-- ── BH-5559 (BH-5556.2): the staff charter and autonomy tables ───────────────
-- One row per staff agent (staff_agents) and per lane it runs (staff_lanes),
-- read and set through src/routes/staff.js and validated there with the
-- agent-core charter schema. Levels are agent-core LEVELS: automation (observe),
-- augmentation (ask first), autonomy (act). The last CHECK keeps autonomy at or
-- below cap, so no write path can raise an agent past its cap.
-- Archie's archie_classes and archie_decisions do not change: an ALTER is not
-- additive (a second apply fails on the duplicate column) and their key is
-- class alone. Staff classes and decisions get their own tables with an agent
-- column, and the views agent_classes and agent_decisions read both, with
-- agent = 'archie' on every Archie row. Seeds are INSERT OR IGNORE, so a
-- redeploy never resets an operator's level. D1, not Supabase: no RLS.
CREATE TABLE IF NOT EXISTS staff_agents (
  name TEXT PRIMARY KEY CHECK (name = lower(trim(name)) AND length(name) BETWEEN 2 AND 40),
  role TEXT NOT NULL,
  accountable TEXT NOT NULL,
  autonomy TEXT NOT NULL DEFAULT 'automation' CHECK (autonomy IN ('automation','augmentation','autonomy')),
  cap TEXT NOT NULL DEFAULT 'augmentation' CHECK (cap IN ('automation','augmentation','autonomy')),
  status TEXT NOT NULL DEFAULT 'active' CHECK (status IN ('active','paused','retired')),
  soul_path TEXT NOT NULL,
  updated_at TEXT NOT NULL,
  note TEXT,
  CHECK (CASE autonomy WHEN 'automation' THEN 0 WHEN 'augmentation' THEN 1 ELSE 2 END
         <= CASE cap WHEN 'automation' THEN 0 WHEN 'augmentation' THEN 1 ELSE 2 END)
);
CREATE TABLE IF NOT EXISTS staff_lanes (
  agent TEXT NOT NULL,
  lane TEXT NOT NULL,
  created_at TEXT NOT NULL,
  PRIMARY KEY (agent, lane)
);
CREATE INDEX IF NOT EXISTS idx_staff_lanes_lane ON staff_lanes(lane);
CREATE TABLE IF NOT EXISTS staff_classes (
  agent TEXT NOT NULL,
  class TEXT NOT NULL,
  cap TEXT NOT NULL DEFAULT 'augmentation' CHECK (cap IN ('automation','augmentation','autonomy')),
  never_delegable INTEGER NOT NULL DEFAULT 0 CHECK (never_delegable IN (0,1)),
  state TEXT NOT NULL DEFAULT 'ask_first' CHECK (state IN ('ask_first','delegated')),
  streak INTEGER NOT NULL DEFAULT 0,
  delegated_at TEXT,
  reverted_at TEXT,
  updated_at TEXT NOT NULL,
  note TEXT,
  PRIMARY KEY (agent, class),
  CHECK (class NOT IN ('client-board','spend','production','merge','deploy','unclassified') OR never_delegable = 1),
  CHECK (never_delegable = 0 OR state = 'ask_first')
);
CREATE TABLE IF NOT EXISTS staff_decisions (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  agent TEXT NOT NULL,
  escalation_key TEXT NOT NULL UNIQUE,
  initiative_id INTEGER,
  class TEXT NOT NULL,
  sensitive INTEGER NOT NULL DEFAULT 0 CHECK (sensitive IN (0,1)),
  recommendation TEXT NOT NULL,
  mode TEXT NOT NULL CHECK (mode IN ('ask','auto')),
  auto_choice TEXT,
  choice TEXT,
  choice_key TEXT,
  counted INTEGER NOT NULL DEFAULT 0 CHECK (counted IN (0,1)),
  created_at TEXT NOT NULL,
  chosen_at TEXT
);
CREATE INDEX IF NOT EXISTS idx_staff_decisions_agent ON staff_decisions(agent, id);
CREATE VIEW IF NOT EXISTS agent_classes AS
  SELECT 'archie' AS agent, class, NULL AS cap, never_delegable, state, streak, delegated_at,
         reverted_at, updated_at, note FROM archie_classes
  UNION ALL
  SELECT agent, class, cap, never_delegable, state, streak, delegated_at,
         reverted_at, updated_at, note FROM staff_classes;
CREATE VIEW IF NOT EXISTS agent_decisions AS
  SELECT 'archie' AS agent, id, escalation_key, initiative_id, class, sensitive, recommendation, mode,
         auto_choice, choice, choice_key, counted, created_at, chosen_at FROM archie_decisions
  UNION ALL
  SELECT agent, id, escalation_key, initiative_id, class, sensitive, recommendation, mode,
         auto_choice, choice, choice_key, counted, created_at, chosen_at FROM staff_decisions;
INSERT OR IGNORE INTO staff_agents (name, role, accountable, autonomy, cap, status, soul_path, updated_at, note) VALUES
  ('quartermaster','cost','operator@example.com','automation','augmentation','active','prompts/staff/quartermaster-soul.md','2026-10-09T00:00:00Z','BH-5559 seed: observe mode'),
  ('watchman','security','operator@example.com','automation','augmentation','active','prompts/staff/watchman-soul.md','2026-10-09T00:00:00Z','BH-5559 seed: observe mode'),
  ('dispatcher','health','operator@example.com','automation','augmentation','active','prompts/staff/dispatcher-soul.md','2026-10-09T00:00:00Z','BH-5559 seed: observe mode'),
  ('inspector','quality','operator@example.com','automation','augmentation','active','prompts/staff/inspector-soul.md','2026-10-09T00:00:00Z','BH-5559 seed: observe mode'),
  ('millwright','maintenance','operator@example.com','automation','augmentation','active','prompts/staff/millwright-soul.md','2026-10-09T00:00:00Z','BH-5559 seed: observe mode'),
  ('clerk','records','operator@example.com','automation','augmentation','active','prompts/staff/clerk-soul.md','2026-10-09T00:00:00Z','BH-5559 seed: observe mode'),
  ('archivist','memory','operator@example.com','automation','augmentation','active','prompts/staff/archivist-soul.md','2026-10-09T00:00:00Z','BH-5559 seed: observe mode');
INSERT OR IGNORE INTO settings (key,value,note,actor,updated_at) VALUES
  ('staff.delegate_after','5','BH-5559: agreements in a row before a staff class can be delegated','seed','2026-10-09T00:00:00Z');
