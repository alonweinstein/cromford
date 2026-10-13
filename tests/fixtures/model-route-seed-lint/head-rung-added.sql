-- A reduced schema.sql: the three model_routes seed shapes plus a settings seed
-- in the same tuple syntax (BH-1928 lint fixtures).
INSERT OR IGNORE INTO model_routes (scope, project, role, position, model, runner, updated_by, updated_at)
  SELECT v.column1, v.column2, v.column3, v.column4, v.column5, v.column6, v.column7, v.column8
  FROM (VALUES
  -- build.qa: the QA lane
  ('hub', NULL, 'build.qa', 0, 'model-a', 'claude', 'seed', '2026-09-22T00:00:00Z'),
  ('hub', NULL, 'build.plan', 0, 'model-b', 'claude', 'seed', '2026-09-22T00:00:00Z')
  ) AS v
  WHERE NOT EXISTS (SELECT 1 FROM model_route_changes c WHERE c.project IS NULL AND c.role = v.column3);

INSERT OR IGNORE INTO model_routes (scope, project, role, position, model, runner, updated_by, updated_at)
  SELECT 'hub', NULL, v.column1, v.column2, v.column3, v.column4, 'seed', '2026-09-23T00:00:00Z'
  FROM (VALUES
    ('fireworks.floor', 0, 'model-f', 'fireworks'),
    ('claude.ladder', 0, 'model-b', 'claude'),
    ('claude.ladder', 1, 'model-a', 'claude'),
    ('claude.ladder', 2, 'model-c', 'claude')
  ) AS v
  WHERE NOT EXISTS (SELECT 1 FROM model_route_changes c WHERE c.project IS NULL AND c.role = v.column1);

INSERT OR IGNORE INTO model_routes (scope, project, role, position, model, runner, updated_by, updated_at)
  SELECT 'hub', NULL, 'housekeeping.floor', 1, 'model-c', 'claude', 'seed', '2026-09-22T00:00:00Z'
  WHERE NOT EXISTS (SELECT 1 FROM model_route_changes WHERE role = 'housekeeping.floor' AND project IS NULL);

INSERT OR IGNORE INTO settings (key,value,note,actor,updated_at) VALUES
  ('hub', NULL, 'build.qa', 0, 'model-z', 'claude', 'seed', '2026-09-22T00:00:00Z');
