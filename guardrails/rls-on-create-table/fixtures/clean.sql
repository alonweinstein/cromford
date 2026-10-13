-- Clean: the table is created and immediately locked down, deny-by-default.
CREATE TABLE "ProjectionRun" (
  "id"        TEXT PRIMARY KEY,
  "clientId"  TEXT NOT NULL,
  "year"      INTEGER NOT NULL,
  "savings"   NUMERIC(14,2) NOT NULL DEFAULT 0,
  "createdAt" TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX "ProjectionRun_clientId_idx" ON "ProjectionRun" ("clientId");

ALTER TABLE public."ProjectionRun" ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public."ProjectionRun" FROM anon, authenticated;
