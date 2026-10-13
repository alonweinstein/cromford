# BH-2532.0 contract: artifact detail reader and box self-report columns (BH-2622)

**What it is:** the contract slice the other four #2532 slices build on. Three
shell helpers and two nullable `box_status` columns. Nothing calls the helpers
yet, so no lane changes behaviour.

- `job_artifact_detail <kind> [job]` in `bin/lib/jobs/jobs.sh` prints the raw
  `detail` of one artifact kind for a job (`JOB_ID` by default). rc 0 = printed,
  rc 3 = the worker answered and there is no such row or it has no detail (a 404
  reads the same), rc 1 = the worker could not be asked or its answer did not
  parse.
- `box_self_report_set <cli_version> <codex_version> <rules_hash>` in
  `bin/lib/jobs/boxes.sh` posts `{box, cli_version, codex_version, rules_hash, at}`
  to `POST /api/boxes/self-report`. That route is a sibling slice, so today the
  call returns nonzero (404).
- `box_self_reports` in `bin/lib/jobs/boxes.sh` prints TSV
  `box cli_version codex_version cli_checked_at rules_hash rules_reported_at` for
  every box with a non-empty `rules_reported_at` or `cli_checked_at`. rc 1 when the
  worker could not be asked or its answer did not parse; rc 0 with no output when
  no box has reported.
- `box_status.rules_hash` and `box_status.rules_reported_at` (TEXT, nullable,
  never backfilled) are in `worker/jobs/schema.sql` for a fresh database and in
  `ADDED_COLUMNS.box_status` (`worker/jobs/src/lib/core.js`) for the live one.
  `GET /api/boxes` is `SELECT *`, so both reach the hub with no route change.

**How an operator reaches it:** there is no UI. From a box:

```bash
. bin/jobs-client.sh
job_artifact_detail lead_review_report <job_id>; echo "rc=$?"
box_self_reports; echo "rc=$?"
```

**How it is verified:**

- `HARNESS_TEST_SANDBOX=1 bash tests/jobs-contract.bh-2622-test.sh` drives the
  real `bin/jobs-client.sh` against a stubbed curl (cases A1-A5, B1-B2, C1-C3).
- `cd worker/jobs && node --test test/boxes-rules-hash.bh-2622.test.js` runs the
  shipped `schema.sql` twice on node:sqlite (N1), `GET /api/boxes` on a fresh
  database (N2), and `GET /api/boxes` on a legacy `box_status` that gains both
  columns through `ensureColumns` (N3).
