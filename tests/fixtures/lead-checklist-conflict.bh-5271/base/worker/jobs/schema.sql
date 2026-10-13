-- worker/jobs/schema.sql: the jobs worker's D1 tables.
-- Applied statement by statement by bin/harness-sync.sh.

CREATE TABLE IF NOT EXISTS jobs (
  id TEXT PRIMARY KEY,
  status TEXT NOT NULL
);
