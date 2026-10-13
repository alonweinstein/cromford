-- stage.sentry-triage: the sentry-triage lane's diagnosis route (BH-5620), copied from
-- triage rung 0 on the claude runner, so no model literal enters.
INSERT OR IGNORE INTO model_routes (scope, project, role, position, model, runner, updated_by, updated_at)
  SELECT 'hub', NULL, 'stage.sentry-triage', 0, m.model, m.runner, 'seed', '2026-10-10T00:00:00Z'
  FROM model_routes m
  WHERE m.project IS NULL AND m.role = 'triage' AND m.position = 0 AND m.runner = 'claude'
    AND NOT EXISTS (SELECT 1 FROM model_routes x WHERE x.project IS NULL AND x.role = 'stage.sentry-triage')
    AND NOT EXISTS (SELECT 1 FROM model_route_changes c WHERE c.project IS NULL AND c.role = 'stage.sentry-triage');
