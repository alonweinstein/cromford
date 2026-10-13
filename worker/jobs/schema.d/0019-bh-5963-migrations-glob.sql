-- ── BH-5963: where a project keeps its migration SQL ─────────────────────────
-- bin/lib/migrations-glob.sh reads migrations_glob.<project>; no row means
-- scripts/migrations/*.sql. example-org/project-6 keeps its SQL in prisma/sql/.
-- INSERT OR IGNORE, so an operator's edit survives every re-apply.
INSERT OR IGNORE INTO settings (key,value,note,actor,updated_at) VALUES
  ('migrations_glob.project-6-os','prisma/sql/*.sql','BH-5963: project-6 keeps its migration SQL in prisma/sql/; read by hotfix-migrate, scope-gate and the merge-sweep MIGRATION GATE alert','seed','2026-10-10T00:00:00Z');
