-- Seeded violation: a new public table with no RLS. Anyone with the project
-- URL and the anon key can read, write, and delete every row.
CREATE TABLE "ProjectionRun" (
  "id"        TEXT PRIMARY KEY,
  "clientId"  TEXT NOT NULL,
  "year"      INTEGER NOT NULL,
  "savings"   NUMERIC(14,2) NOT NULL DEFAULT 0,
  "createdAt" TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX "ProjectionRun_clientId_idx" ON "ProjectionRun" ("clientId");
