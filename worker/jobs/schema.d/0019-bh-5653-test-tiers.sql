-- ── BH-5653 C1: CI test-tier sets ──
-- One row per stored SET: a whole snapshot of catalog/test-tiers.tsv (rows_json,
-- [{suite,tier,runtime_s,paths,reason}] sorted by suite) plus the git blob sha
-- of the committed file it was based on. Written by `bin/ci-test-tiers.sh put`
-- (PUT /api/ci/test-tiers, src/routes/ci-test-tiers.js, HARNESS_SECRET only)
-- and read back by `bin/ci-test-tiers.sh fetch` for bin/ci-plan.sh, which uses
-- the newest set only while its base_blob is the checkout's file. digest is the
-- sha256 of base_blob and the sorted rows: a PUT equal to the NEWEST set writes
-- nothing. D1 has no RLS; the route's own bearer guards it.
CREATE TABLE IF NOT EXISTS ci_test_tier_sets (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  base_blob TEXT NOT NULL,
  digest TEXT NOT NULL,
  rows_json TEXT NOT NULL,
  row_count INTEGER NOT NULL,
  source TEXT NOT NULL CHECK (source IN ('seed','operator')),
  actor TEXT NOT NULL,
  created_at TEXT NOT NULL
);
