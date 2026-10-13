-- harness-jobs — coordination state for the box fleet.
-- Contract: docs/DB-COORDINATION-SPEC.md (phase 1, approved 2026-08-27).
--
-- ADDITIVE ONLY, FOREVER. No DROP, no column rename, no destructive migration:
-- boxes run whatever bin/ they last synced, so an old client must keep working
-- against a newer schema. New shape = new nullable column or a new table, and
-- this file stays re-runnable (every statement IF NOT EXISTS) because it is
-- applied on every deploy, not once.
--
-- NO SECRETS IN ANY ROW, meta included. Tokens live in env files on the boxes.

CREATE TABLE IF NOT EXISTS jobs (
  id TEXT PRIMARY KEY,            -- e.g. build-project-3-TK-109-<ts>
  project TEXT NOT NULL,          -- fleet.conf project name
  ticket_id TEXT,
  kind TEXT NOT NULL,             -- triage | build | fix | qa | migration
  box TEXT NOT NULL,              -- owning box / fly machine id
  stage TEXT NOT NULL,            -- plan | execute | review | merge | apply | done
  status TEXT NOT NULL,           -- running | done | failed | budget_stopped | parked
  budget_usd REAL,                -- cap handed to the claimant
  spent_usd REAL DEFAULT 0,
  created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL,
  meta TEXT,                      -- JSON: pr url, branch, runner, notes
  issue_created_at TEXT,          -- BH-482: GitHub issue createdAt (GitHub-Issues projects only; null on in-app boards)
  first_spawn_at TEXT             -- BH-482: first agent spawn for this job (the worker stamps it)
);
CREATE INDEX IF NOT EXISTS idx_jobs_project_status ON jobs(project, status);

CREATE TABLE IF NOT EXISTS stage_events (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  job_id TEXT NOT NULL,
  stage TEXT NOT NULL,
  verdict TEXT,                   -- APPROVE | REJECT | BUDGET_STOP | ...
  actor TEXT NOT NULL,            -- box name / lane / "orchestrator"
  detail TEXT,                    -- JSON or free text
  created_at TEXT NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_events_job ON stage_events(job_id);

-- Mirror of catalog/context-budgets.json, keyed <stage>/<project|*>/<runner|*>
-- and valued in the SAME dollars bin/agent-call.sh `_budget_for` derives from a
-- lane's declared ceiling. The file stays the source of truth in git; this table
-- is the copy every box can reach, including fly builders that never receive
-- catalog/ (the TK-109 lesson this whole layer exists for).
CREATE TABLE IF NOT EXISTS budget_catalog (
  lane TEXT PRIMARY KEY,          -- e.g. execute/project-3/claude
  budget_usd REAL NOT NULL,
  updated_at TEXT NOT NULL
);

-- Phase 2: merge-sweep + migration-autopilot coordination ledger.
-- File ledgers (state/merge-sweep-done.txt, state/migration-autopilot-done.txt)
-- stay as write-through fallback so a worker outage cannot cause a double
-- merge or a double apply. Reads prefer this table; when the worker is
-- unreachable the caller falls back to the file — never "not in the DB, so
-- not done". Additive, re-runnable, no DROP.
CREATE TABLE IF NOT EXISTS ledgers (
  kind TEXT NOT NULL,             -- merge | migration | pr_state | deploy
  key TEXT NOT NULL,              -- PR url, "<project> <filename>", or "<owner/repo>@<sha>"
  status TEXT NOT NULL,           -- merged | parked | applied | flagged | failed-alerted | skipped | verified | failed | ...
  job_id TEXT,
  actor TEXT,
  detail TEXT,
  created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL,
  PRIMARY KEY (kind, key)
);
CREATE INDEX IF NOT EXISTS idx_ledgers_kind ON ledgers(kind);

-- Phase 3: HEARTBEATS + ORPHAN DETECTION.
-- rc=137 cannot be prevented — a SIGKILL is the OS ending the process, and no
-- retry loop in a killed process runs. What CAN be fixed is that a killed run
-- currently leaves NOTHING: on 2026-08-27 17:48Z two detached sessions died
-- blank (a phase-2 build and a project-2 fix) and the only evidence was
-- absence. A claimant that touches its row every couple of minutes turns that
-- silence into a row whose last beat is old — detection, not prevention.
--
-- Its own table rather than a column on jobs, for two reasons: D1/SQLite has no
-- ADD COLUMN IF NOT EXISTS, so a column could not live in this re-runnable
-- file; and a beat every ~150s must never contend with the spend deltas
-- agent-call.sh writes onto the job row.
CREATE TABLE IF NOT EXISTS job_heartbeats (
  job_id TEXT PRIMARY KEY,        -- jobs.id
  beat_at TEXT NOT NULL,          -- ISO, server clock (box clocks drift)
  box TEXT,                       -- who beat last; a resumed job can change box
  note TEXT                       -- optional stage/pid breadcrumb, never a secret
);
CREATE INDEX IF NOT EXISTS idx_heartbeats_beat ON job_heartbeats(beat_at);

-- Phase 3: PAUSE FLAGS as rows, so a pause can be set from the console instead
-- of by touching flags/ on a box over ssh.
--
-- The FILE stays what every existing reader tests, and the DB drives the file:
-- bin/jobs-client.sh `flag_active` reconciles the file from this table when the
-- row is NEWER than the file's mtime, then answers from the file. So a worker
-- outage changes nothing at all — the box keeps behaving exactly as it does
-- today — and a local `touch flags/paused-x` is never undone by a stale row.
-- Two-state and reversible, unlike the phase-2 ledgers, which is why this one
-- reconciles on recency instead of "file first, DB back-fills".
-- Tie-break (BH-1369 contract): when the row's updated_at equals the file's
-- mtime, the ROW wins. An ABSENT file is not newer than anything, so a row is
-- applied. bin/lib/jobs/flags.sh still reconciles APPLY-ONCE until the #1027
-- child that rewrites it lands; this comment is the contract it moves to.
CREATE TABLE IF NOT EXISTS pause_flags (
  name TEXT PRIMARY KEY,          -- flags/ filename, e.g. paused-project-3
  active INTEGER NOT NULL,        -- 1 = flag file should exist, 0 = should not
  actor TEXT,                     -- console | box name | orchestrator
  reason TEXT,                    -- why, for the human who finds it later
  updated_at TEXT NOT NULL,
  value TEXT                      -- BH-5635: the flag file's content (e.g. a WIP limit), NULL = empty file; ADDED_COLUMNS widens a live table
);

-- BH-4153 (BH-4141.1): FLAGS IN THE DB. For the ported families (paused-*,
-- automerge-disabled, automerge-disabled-*, lanedown-*; FLAG_PORTED_RE in
-- src/lib/harness-flags.js, the same list as bin/lib/jobs/flags.sh) THE ROW IS
-- THE TRUTH once the shell lanes switch over (#4332): the box reads it first and
-- falls back to a last-good cache, and the flags/ file is no longer written. `scope` is 'fleet' or a box name
-- (lanedown-* is box-scoped). ON iff cleared_at IS NULL; a clear is soft, so
-- the row stays as history, and a re-set writes set_at=now, cleared_at=NULL.
--
-- MIRROR CONTRACT: every write of a FLEET-scoped ported name (PUT/DELETE
-- /api/flags, src/routes/flags.js) upserts pause_flags (active, actor, reason,
-- updated_at) in the SAME batch, so checkPause and the other worker readers of
-- pause_flags keep working unchanged. Nothing else writes those mirror rows.
-- Box-scoped rows are not mirrored. Wave 2 ports the worker readers and
-- retires the mirror. The INSERT below backfills existing pause_flags rows of
-- the ported names once. INSERT OR IGNORE (the form
-- tests/schema-additive.bh-1000-test.sh requires) makes a rerun a no-op and
-- never overwrites a row this table already holds.
-- NO RLS STEP: Cloudflare D1 behind the bearer-authed worker, like every table here.
CREATE TABLE IF NOT EXISTS harness_flags (
  scope TEXT NOT NULL DEFAULT 'fleet', name TEXT NOT NULL, value TEXT,
  set_by TEXT, reason TEXT, set_at TEXT NOT NULL, cleared_at TEXT,
  PRIMARY KEY (scope, name));
CREATE INDEX IF NOT EXISTS harness_flags_name ON harness_flags(name);
INSERT OR IGNORE INTO harness_flags (scope, name, value, set_by, reason, set_at, cleared_at)
  SELECT 'fleet', name, NULL, actor, reason, updated_at, CASE WHEN active=1 THEN NULL ELSE updated_at END
    FROM pause_flags WHERE name LIKE 'paused-%' OR name = 'automerge-disabled' OR name LIKE 'automerge-disabled-%' OR name LIKE 'lanedown-%';

-- BH-1369 (BH-1027.0): BUILDER ROUTING as rows. One row per project says where
-- its builds run (local | fly1 | pool), which Fly app the pool uses, and
-- whether the pool is halted. The flags/ files (builder-fly-<p>, fly-pool-<p>,
-- fly-pool-app-<p>, pool-halt-<p>) stay what every reader tests; this row
-- drives them through bin/lib/jobs/routing.sh, and only once the `routing_rows`
-- setting is on. Pool SIZE is deliberately not here: it stays the content of
-- flags/fly-pool-<p> and fly/pool-caps.conf, read by bin/pool-cap.sh.
CREATE TABLE IF NOT EXISTS routing (
  project TEXT PRIMARY KEY,       -- [A-Za-z0-9._-], becomes part of a flags/ filename
  builder TEXT NOT NULL,          -- local | fly1 | pool
  pool_app TEXT,                  -- Fly app for builder=pool; NULL = no app file
  halted INTEGER NOT NULL DEFAULT 0, -- 1 = flags/pool-halt-<p> should exist
  updated_at TEXT NOT NULL
);

-- BH-2010: THE AUDIT TRAIL of routing, the same shape as model_route_changes.
-- APPEND-ONLY, never updated or deleted: one row per PUT /api/routing that
-- CHANGED a row (an unchanged write is not a decision), written in the SAME
-- batch as the upsert. before_* are NULL when the write created the row. The
-- actor/reason are what the caller sent (the seed script: routing-seed;
-- harness-sync's deploy halt-clear: harness-sync); no actor is "api".
-- NO RLS STEP: Cloudflare D1 behind the bearer-authed worker, like every table here.
CREATE TABLE IF NOT EXISTS routing_changes (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  project TEXT NOT NULL,
  before_builder TEXT,
  before_pool_app TEXT,
  before_halted INTEGER,
  after_builder TEXT NOT NULL,
  after_pool_app TEXT,
  after_halted INTEGER NOT NULL,
  actor TEXT NOT NULL,
  reason TEXT,
  at TEXT NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_routing_changes_project ON routing_changes(project, at);

-- BH-2563 (BH-2511.0): THE AUDIT TRAIL of cost/lane cap rows (conf.cost-caps.*,
-- conf.lane-caps.*). APPEND-ONLY by design. NOTHING WRITES IT YET: the BH-2511
-- siblings' PUT and seed will append one row per write that changes a cap row,
-- before_value NULL when the write creates the row, actor and reason as sent.
-- NO RLS STEP: Cloudflare D1 behind the bearer-authed worker, like every table here.
CREATE TABLE IF NOT EXISTS cost_cap_changes (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  key TEXT NOT NULL,
  before_value TEXT,
  after_value TEXT NOT NULL,
  actor TEXT NOT NULL,
  reason TEXT,
  at TEXT NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_cost_cap_changes_key ON cost_cap_changes(key, at);

-- BH-2513: THE AUDIT TRAIL of the console controls (review-gate thresholds,
-- concurrency rules, retry policies, phase contracts). APPEND-ONLY, never
-- updated or deleted: one row per write that CHANGED one of the audited
-- fields, batched with that write (src/lib/config-changes.js builds the
-- statement). `kind` comes from CONFIG_KINDS, `name` is the row the write
-- touched; before_json is NULL when the write created it. A write with no
-- actor records "api".
-- NO RLS STEP: Cloudflare D1 behind the bearer-authed worker, like every table here.
CREATE TABLE IF NOT EXISTS config_changes (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  kind TEXT NOT NULL,
  name TEXT NOT NULL,
  before_json TEXT,
  after_json TEXT NOT NULL,
  actor TEXT NOT NULL,
  reason TEXT,
  at TEXT NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_config_changes_kind_name ON config_changes(kind, name, id);

-- Phase 5: PER-PHASE TRACKING.
-- Through phase 4 coordination was per JOB: one claim covered plan -> execute ->
-- review, and the only per-stage trace was a heartbeat note plus a spend delta,
-- both of which land on the JOB row and overwrite each other. So a build that
-- died left "this job failed" and nothing that said WHICH stage died, on which
-- runner, having spent what — the first question every recovery asks.
--
-- A PHASE IS A CHILD RECORD, NEVER A SECOND CLAIM. The job stays the unit of
-- coordination: one job, one claim, one double-build guard. Phases only
-- describe what happened inside that claim, and nothing here re-asks permission
-- between stages — that is the design, not an omission.
--
-- One row per ATTEMPT rather than one per phase NAME: review runs twice around
-- a fix round and fix can run three times, so a table keyed (job_id, phase)
-- would overwrite the first attempt's rc with the second's and lose the failure
-- being attributed. The autoincrement id is both the attempt's identity and its
-- order, which is why "current phase" is simply the highest id.
CREATE TABLE IF NOT EXISTS job_phases (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  job_id TEXT NOT NULL,           -- jobs.id; the claim this phase ran inside
  phase TEXT NOT NULL,            -- plan | execute | review | fix | qa | triage | ...
  runner TEXT,                    -- the lane that actually served it (claude | codex | grok | ...)
  model TEXT,                     -- the model id the runner resolved to, recorded not chosen
  status TEXT NOT NULL,           -- running | done | failed | orphaned | budget_stopped
  started_at TEXT NOT NULL,
  finished_at TEXT,
  rc INTEGER,                     -- the stage's REAL exit code, never a laundered one
  spend_usd REAL,                 -- this phase's dollars, summed across its retries
  note TEXT                       -- KILL_STOP/BUDGET_STOP marker or a breadcrumb. Never a secret.
);
CREATE INDEX IF NOT EXISTS idx_phases_job ON job_phases(job_id, id);
CREATE INDEX IF NOT EXISTS idx_phases_open ON job_phases(status, job_id);

-- Phase 6: CONCURRENCY RULES — the DB decides what may run.
-- Through phase 5 the only thing that could refuse a claim was one hardcoded
-- guard: same project + ticket + kind, open, on another box. Everything else
-- was lockfiles and discipline, which is exactly where TK-66/67 slipped through
-- (two boxes, one ticket, two builds). A rule that lives in code cannot be
-- changed without a deploy, and a rule that lives on one box cannot see the
-- fleet — so the rules become ROWS, checked inside the claim itself.
--
-- FAIL-OPEN BY CONSTRUCTION: a scope with no matching row is UNLIMITED. Deleting
-- every row in this table returns the fleet to phase-5 behaviour, and an
-- unreachable worker is already fail-open on the client side (bin/jobs-client.sh),
-- so rules bind only when the DB is answerable. Availability never gates work.
--
--   scope     what the peers are counted over
--   -----     -------------------------------
--   ticket    the same project + ticket_id, fleet-wide  (kills the double build)
--   repo      the same project
--   box       the same box / fly machine
--   lane      the same <stage>/<project>/<runner> claim lane
--
-- `selector` is '*' (every value of that scope) or one exact value, and `kind`
-- is '*' or one job kind. Most specific wins, selector outranking kind — the
-- same specificity ladder budget_catalog lanes already resolve on, because two
-- ladders that disagree is how a rule comes to bind somewhere nobody meant.
CREATE TABLE IF NOT EXISTS concurrency_rules (
  scope TEXT NOT NULL,            -- ticket | repo | box | lane
  selector TEXT NOT NULL,         -- '*' or an exact project / box / lane
  kind TEXT NOT NULL,             -- '*' or one job kind (build | triage | fix | ...)
  max_concurrent INTEGER NOT NULL,-- how many may run at once; 0 = none may start
  note TEXT,                      -- why this rule exists, for whoever finds it
  updated_at TEXT NOT NULL,
  PRIMARY KEY (scope, selector, kind)
);

-- Seeds are INSERT OR IGNORE, never an overwrite: these rows are meant to be
-- EDITED (that is the whole point of putting them in a table), and a re-applied
-- schema that reset a hand-raised cap would be a config change nobody made.
--
-- BH-1279: there is NO repo/*/build or box/*/build seed row here anymore, and
-- there must never be one again. On 2026-09-14 the operator ordered the fleet
-- uncapped ("all projects unlimited parallel") and PR #343 DELETED those two
-- rows from the live D1 — the fleet default of "no row = unlimited" (see the
-- FAIL-OPEN comment above) is exactly what that order asked for. BH-1000 then
-- started re-applying this file on every deploy, and INSERT OR IGNORE
-- protects a RAISED row but resurrects a DELETED one: the first deploy after
-- BH-1000 silently restored both rows and the whole fleet dropped to one
-- build per repo/box, twice (2026-09-20, then again 2026-09-21 20:40Z).
-- `docs/BUILD-CONCURRENCY.md` predicted this exact failure — "the seed is the
-- copy a reader finds; the row is the one that binds" — and it was still
-- wrong to seed a cap an operator had deliberately removed. A cap is now set
-- the same way it is raised or lowered: `bin/jobs-client.sh rule-set`, never
-- this file. worker/jobs/test/concurrency-rules-seed.bh-1279.test.js pins this.
INSERT OR IGNORE INTO concurrency_rules (scope, selector, kind, max_concurrent, note, updated_at) VALUES
  ('ticket', '*', '*',     1, 'one ticket, one claim, fleet-wide; the TK-66/67 double-build class (a cap is a rule-set, never this seed)', '2026-08-29T00:00:00Z');

-- Phase 6: RETRY POLICY, per lane.
-- Phase 3 could see a death and refused to act on it, deliberately: a blind
-- relaunch races the double-build guard. With the guard now enforced INSIDE the
-- claim, a bounded retry is safe to express — but only as policy, and only per
-- lane, so "how many times may this kind of work be re-attempted" is a row an
-- operator edits rather than a constant in the watchdog.
--
-- NO ROW FOR A LANE = TODAY'S BEHAVIOUR: detection only, zero retries. This
-- table ships EMPTY on purpose. Nothing in the fleet retries until somebody
-- inserts a row, so phase 6's retry half lands dark and is switched on one lane
-- at a time.
--
-- `escalate_allowed` is RECORDED, not acted on here: it rides onto the retry
-- row and the console so a lane can say "a retry may use a different runner",
-- and the runner-side escalation belongs to whoever picks the row up. A flag
-- this layer wrote and also obeyed would be two decisions wearing one name.
CREATE TABLE IF NOT EXISTS retry_policies (
  lane TEXT PRIMARY KEY,          -- <stage>/<project|*>/<runner|*>, the budget_catalog key shape
  max_attempts INTEGER NOT NULL,  -- total attempts INCLUDING the first
  backoff_seconds INTEGER NOT NULL DEFAULT 300,
  escalate_allowed INTEGER NOT NULL DEFAULT 0,
  note TEXT,
  updated_at TEXT NOT NULL
);

-- BH-283: OPERATOR KNOBS, one row per number somebody may need to change at
-- 3am without a deploy. The GitHub budget floor is the first of them and will
-- not be the last, so it gets a generic key/value table rather than a column of
-- its own — a knob per table is a migration per knob.
--
-- The value is TEXT on purpose: every consumer reads it through
-- `setting_get` and parses what it needs, and one storage type means a knob
-- that turns out to be a list of repos does not need a second table.
--
-- There is NO second hard-coded copy of a value that lives here
-- (console-ui/src/screens/Outcomes.js:35, the RATE_WARN rule). A consumer
-- carries a documented FALLBACK for the case where the row is absent — which
-- is also what it uses while this file is still unapplied — and that fallback
-- is the only literal in code.
CREATE TABLE IF NOT EXISTS settings (
  key TEXT PRIMARY KEY,           -- ^[a-z0-9_.-]{1,64}$, enforced by the API
  value TEXT NOT NULL,            -- always text; the consumer parses it
  note TEXT,                      -- why this knob exists, for whoever finds it
  actor TEXT,                     -- who last wrote it (a box name, or 'seed')
  updated_at TEXT NOT NULL
);

-- Seeded, not empty: a knob nobody has touched must still answer with the
-- number the fleet was designed around. INSERT OR IGNORE, so re-applying this
-- file never resets a threshold an operator raised (same rule as the
-- concurrency_rules seeds above).
INSERT OR IGNORE INTO settings (key,value,note,actor,updated_at) VALUES
  ('gh_budget_min_remaining','800','BH-283: below this core/graphql remaining, ticks skip non-essential GitHub reads','seed','2026-09-15T00:00:00Z');

-- Its own statement, not another row on the VALUES list above: bin/harness-sync.sh
-- applies this file statement by statement (BH-1000), so one seed per statement
-- means a new knob can never take an older one's apply down with it.
INSERT OR IGNORE INTO settings (key,value,note,actor,updated_at) VALUES
  ('gh_quota_alert_pct','20','BH-426: below this percent remaining on REST or GraphQL for any token, one ALERTS line per token per reset window','seed','2026-09-22T00:00:00Z');

