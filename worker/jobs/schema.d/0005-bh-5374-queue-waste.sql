
-- ── BH-5374 (BH-5356.2): the queue waste ledger ──────────────────────────────
-- queue_batch_minutes holds the CI minutes of every finished Mergify batch
-- draft, one row per (repo, draft_pr, run_id), upserted so a re-sent row never
-- counts twice. outcome is merged | reset | red | bisect | closed; everything
-- but merged is minutes the queue threw away. minutes is measured, never
-- estimated: source billable is GitHub's run timing, source jobs is the summed
-- job time of a self-hosted run (whose billable is empty). reused_min is what
-- #5368's fingerprint reuse skipped for the draft, and reused_known says
-- whether that record existed at all. day is the UTC date of closed_at.
-- Writer: bmin_tick in bin/lib/mc-batch-minutes.sh through PUT
-- /api/queue-batch-minutes; reader: GET /api/queue-batch-minutes/daily (the
-- QUEUE WASTE section on the console's /ci).
-- Applied by bin/harness-sync.sh statement by statement before the deploy.
-- NO RLS STEP: Cloudflare D1 behind the bearer-authed worker, like every table here.
CREATE TABLE IF NOT EXISTS queue_batch_minutes (repo TEXT NOT NULL, draft_pr INTEGER NOT NULL, run_id INTEGER NOT NULL, outcome TEXT NOT NULL CHECK (outcome IN ('merged','reset','red','bisect','closed')), minutes INTEGER NOT NULL, source TEXT NOT NULL CHECK (source IN ('billable','jobs')), reused_min INTEGER NOT NULL, reused_known INTEGER NOT NULL, workflow TEXT, head_sha TEXT, closed_at TEXT NOT NULL, day TEXT NOT NULL, box TEXT, updated_at TEXT NOT NULL, PRIMARY KEY (repo, draft_pr, run_id));
CREATE INDEX IF NOT EXISTS idx_queue_batch_minutes_day ON queue_batch_minutes(day);

