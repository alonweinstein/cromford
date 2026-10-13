# The ready queue and the age-out audit as rows (state→DB slice 8)

**What it is:** the two places the fleet kept a DECISION in a file on ONE box,
moved into the coordination database with the files left as the log and the
archive they always were.

- **"This ticket is ready to build"** — `logs/READY-QUEUE.log` lines, now also
  `build_queue` rows with `status='ready'`. `bin/lib/ready-queue.sh` is the ONE
  definition of the ready set: the file's lines UNION the rows, file first, one
  line per key. A row's line is emitted verbatim except for one thing: if it
  carries no `project=` token, the row's own project column is appended as one,
  because that token is what `bin/preplan-candidates.sh` and
  `bin/preplan-tick.sh` bucket on and the only production writer of a line
  (`bin/stale-owed-tickets.sh`) does not emit it. `bin/triage-gate.sh` brakes on it (`rq_any`), fingerprints it
  (`rq_fp`), and scans it for blocking PR numbers (`rq_lines`);
  `bin/preplan-candidates.sh` and `bin/preplan-tick.sh` walk it;
  `bin/stale-owed-tickets.sh` writes a row beside its append (`rq_put`); and
  `bin/queue-line-drop.sh` drops the row with the line (`rq_drop`).
  `bin/lib/rt/scope.sh` — the stage that builds the triage SESSION's prompt —
  reads the same set (`rq_lines`), because a gate that fires on a row and a
  prompt that says "(none)" is a paid tick for nothing.
- **"We already decided this build record is too old to page about"** —
  `state/closeout-aged-out.tsv` rows, now also the `closeout_aged` table.
  `closeout_record_aged` in `bin/lib/closeout-terminal.sh` asks the table first
  and writes the tsv through; the INSERT's `ON CONFLICT DO NOTHING` **is** the
  dedupe. That tsv is the AUDIT set, not the paging gate:
  `bin/pipeline-health.sh` stops alerting from the RESULT's own mtime against
  `CLOSEOUT_AGE_S` and never reads the file to decide, so losing it pages
  nothing — it loses the record of a verdict the fleet already made.
- **"Which branch did this build push"** — a `branch` artifact on the build's own
  job row, written by `bin/run-build.sh` the moment the name is settled.
  `branch_of` in `bin/pr-url-reconcile.sh` reads it before scraping
  `pipeline.log`.

**Why:** a file on one box cannot be read by a lane on another. The stale-owed
sweep had to `ssh` the owning box to append a line, and a push that failed left
the ticket invisible there; the triage brake concluded "no queue" from the same
file, so a box that never received the append triaged nothing and said nothing;
the 45-minute skip fingerprint was that file's bytes, so a ticket that existed
only as a row could not wake a tick. On the other side, the age-out dedupe *was*
the tsv — one box's file — so losing it (a rebuild, a restore, a rotation, an
operator clearing it) erased a verdict the fleet had already reached and made
the next sweep re-append a row for every aged dir still under `builds/`. (It
does NOT re-page: the alert decision is the RESULT's own mtime in
`bin/pipeline-health.sh` and nothing reads the tsv for it. What is lost is the
record of the decision and the dedupe of the write.) And `branch_of`'s scrape,
when it missed, silently returned the stem `ticket/<key>` — which is how a record
gets relinked to a PR that belongs to somebody else.

**How an operator reaches it:** nothing new to run. `cron/<box>.cron` triage
ticks call `bin/triage-gate.sh`; `bin/preplan-tick.sh` runs every 2 minutes;
`bin/stale-owed-tickets.sh` is an hourly hub lane; `bin/pipeline-health.sh` runs
every 10 minutes; `bin/pr-url-reconcile.sh` runs on the hub. The rows are
readable from any box:

```
bin/jobs-client.sh ready-list [project]            # the ready rows, as TSV
bin/jobs-client.sh ready-put <project> <key> [id] [line]
bin/jobs-client.sh ready-drop <project> <key> [reason]
bin/jobs-client.sh closeout-aged-has <build-dir>   # rc 0 = already decided
```

**How to drive it:**

| what | how |
|---|---|
| the ready set, both flags, and every call site | `HARNESS_TEST_SANDBOX=1 bash tests/ready-queue-rows-test.sh` |
| the age-out table and its dedupe | `HARNESS_TEST_SANDBOX=1 bash tests/closeout-aged-table-test.sh` |
| the shipped SQL and both routes, applied into node:sqlite | `cd worker/jobs && npm test` (`test/state-slice8.bh-1033.test.js`) |
| the router table still answers what the chain did, with both new routes in it | `cd worker/jobs && npm test` (`test/route-table.test.js`) |
| the lanes this slice must not have changed | `bash tests/triage-gate-argmax-test.sh`, `-capped-union-`, `tests/preplan-speculative-test.sh`, `tests/preplan-stale-cap-test.sh`, `tests/overlap-schedule-test.sh`, `tests/queue-producers-test.sh`, `tests/harden-state-writers-test.sh`, `tests/pr-url-reconcile-test.sh`, `tests/pipeline-health-closeout-ageout-test.sh`, `tests/closeout-record-aged-dedupe.bh-1044-test.sh` |

**Where the worker code lives (rebase onto BH-1195):** `#1204` split
`worker/jobs/src/index.js` into per-family modules after this branch was cut, so
this slice's three worker changes are re-placed rather than merged.
`QUEUE_TRANSITIONS` is `src/lib/core.js`; the `POST /api/queue` `ready` branch is
`src/routes/queue.js`; the two `/api/closeout-aged` routes are a NEW family,
`src/routes/closeout-aged.js`, imported by `src/index.js` and registered in
`ROUTES` between `queue` and `mergeQueue` — the position the pre-split chain had
them. `test/route-table.test.js` carries the same two entries in the same
position, per that fixture's own rule ("a route added later is added to BOTH
lists, deliberately").

**The table self-creates, it does not wait for a deploy (fix round 6):**
`closeout_aged` carries the BH-658 belt every table added since BH-1043 carries
— a `CREATED_TABLES.closeout_aged` entry in `src/lib/core.js` with column parity
to `schema.sql`, and `await ensureTable(env, "closeout_aged")` as the first line
of both handlers. Two mechanisms, one rule: a route never runs ahead of its
table in silence. Mechanism one is `bin/harness-sync.sh` applying `schema.sql`
statement by statement before `wrangler deploy` and refusing the deploy when a
statement fails (BH-1000); mechanism two is this. Without it, a D1 the apply
never reached — the documented reset-by-hand step — answered this family with a
THROWN `no such table: closeout_aged`, a Cloudflare 1101 rather than a status a
caller can read, where `settings` answers 503 and `alerts` self-creates. That
would not have been loud: the shell side fails open (`closeout_aged_put`
returns 1, `closeout_record_aged` keeps writing the tsv, `closeout_aged_has`
reads the tsv back), so the only symptom would be one false-cause
"harness-jobs unreachable" ALERT a day while no row ever landed. Driven in
`test/state-slice8.bh-1033.test.js` against a `node:sqlite` database that never
runs `schema.sql`: both routes answer, the dedupe still dedupes, and the mirror
is compared column by column — name, type and `at`'s NOT NULL — against
`schema.sql`, plus `idx_closeout_aged_project`.

**Knobs:** both are settings ROWS, both seeded `0`, and the row is the whole
rollback:

```
bin/jobs-client.sh setting-set ready_queue_rows 1
bin/jobs-client.sh setting-set closeout_aged_table 1
```

`READY_QUEUE_ROWS` / `CLOSEOUT_AGED_TABLE` in `env/global.env` are the documented
fallbacks, used only when the settings row cannot be read. See
`env-templates/global.env.example`.

**Files it owns on a live box:**

- `logs/READY-QUEUE.log` — unchanged, still appended by every writer, still the
  fallback and still the format every consumer parses.
- `state/closeout-aged-out.tsv` — unchanged as the archive, and still bounded by
  `bin/disk-clean.sh`. See [closeout-health.md](closeout-health.md).
- `logs/ready-queue.log` — NEW, and only written on a fail-open: one line saying
  the row read was unreachable and the file's lines were the whole set for that
  tick. A ready set that silently shrinks is the failure this file exists to make
  visible.

**Coverage boundaries, said out loud:**

- `branch_of` resolves a record to its job through `job_for_record`, which reads
  the `result` artifact feed (newest `JOB_FOR_RECORD_LIMIT`, default 500). A
  build that died before `result-put`, or one older than that window, has no
  mapping and falls through to today's `pipeline.log` scrape. Never worse than
  before; not covered either.
- With either flag OFF the readers make **one settings GET per call**, and the
  three `bin/triage-gate.sh` readers (`rq_any`, `rq_fp`, the PR-number
  `rq_lines`) each run inside a command substitution, so the per-process memo
  cannot be shared: three settings GETs per project per tick, to the
  coordination worker, not to GitHub. No `/api/queue` request is made while the
  flag is off (asserted).
- The ticket-id column a consumer reads out of a line is the line's SECOND
  FIELD, and the stale-owed shape puts `OWED-STALE` there. Pre-existing and
  unchanged — the identical line has always gone into `logs/READY-QUEUE.log`
  and been parsed the same way — but it is now asserted so nobody rediscovers
  it as a surprise.
- **Two readers of `logs/READY-QUEUE.log` are NOT converted**, deliberately:
  `bin/lib/preplan-lib.sh` (`preplan_replan_fp`, the 24h re-plan fingerprint)
  and `bin/quiesce-for-resize.sh` (the pending count before a resize). Flag on,
  for a row-only key: the first fingerprints `no-queue-line/<key>` instead of
  the line, so the re-plan marker is keyed on the name and does not re-arm on a
  re-offered line of a different age — more conservative, never a lost plan,
  because `bin/preplan-tick.sh` still launches the pre-plan off `rq_lines`; the
  second counts that key as 0 pending, which is exactly today's behaviour for a
  line that never landed. Neither changes a decision this slice owns. Both are
  `rq_lines`-shaped one-liners for the next cycle, so §11's "every call site
  reads the lib" means every call site this slice converts, not every reader in
  the tree.
- **The fleet-wide ready read takes the route's DEFAULT PAGE.**
  `queue_ready_list` passes no `limit`, so `GET /api/queue` answers
  `ORDER BY enqueued_at ASC LIMIT 200` (max 500). `bin/preplan-tick.sh`'s
  `rq_lines "$HARNESS" ""` therefore sees the 200 OLDEST `ready` rows; a 201st
  row would be invisible to pre-planning until older rows are dropped or
  promoted. The file has no such cap. Unreachable at today's ready-set size
  (the rows mirror consumed file lines), and a `limit=500` on that one call is
  the fix if the set ever grows.
- **A build enqueue that promotes a fresh `ready` row lands at `attempt=1`**
  when the caller passes no `attempt` (`worker/jobs/src/routes/queue.js`: a
  `ready`→`queued` hop is still a re-offer and takes the `+1`), where the same
  enqueue with no row at all lands at 0. `bin/run-build.sh` passes `$ATTEMPT`,
  so the launch path is unaffected; `orphan-reconcile`/`blocked-resolver` omit
  it and get the off-by-one. Ledger noise only — no consumer caps or brakes on
  `attempt` (`fly-pool.sh`, `fly-dispatch.sh`, `run-build.sh` re-checked).
- **A half-synced `bin/` costs the ROW half of a queue-line drop, never the
  file half.** `bin/queue-line-drop.sh` sources the lib inside `rq_drop_keys`,
  after the durable rewrite, and the client's BH-1194 shim `exit 1`s when
  `bin/lib/jobs/` is missing — so the source sits in a SUBSHELL and the caller
  still gets rc 0 and its `dropped N line(s)` line. Asserted (§9).

**Two new status words, and what they are NOT (fix round 2):** `ready` and
`dropped` join the `build_queue` status vocabulary with this slice, so every
reader that asked "is this row *not* `queued`?" got a new answer without being
touched. The one that mattered is `bin/fly-dispatch.sh`'s ssh drain, which reads
"not queued" as "the DB has custody of this key, so the box file is a leftover"
and `rm -f`s it. Neither new word is custody: `ready` is "triage says buildable,
nobody launched it" and `dropped` is "a queue line was consumed". The box file
it deletes is written in exactly ONE place — `bin/run-build.sh`'s outage
fallback, when `queue_put` failed — under an alert that says verbatim *"The
build is NOT lost"*. So the drain now names its custody words as a closed list
(`queued|ready|dropped` fall through to the pull, exactly as rc 2 does) and
`queue_status`'s contract comment says what it can print. **The rule for the
next slice that adds a status: a caller must name the words it acts on, never
test `!= queued`.**

**What must never regress:**

- **An outage is never cached, and never turns a lane on by itself.** Both flags
  resolve settings → env → 0; a worker that cannot answer is not memoised, so a
  blinking database cannot pin one answer for a whole process, and it can never
  make a lane read ON from a settings value nobody could fetch. It does not force
  OFF either: the resolution continues to the documented env fallback, which is
  how a lane deliberately switched on in `env/global.env` survives an outage
  (driven as `env down`).
- **A terminal row is never rewritten by a re-offer (fix round 4).** `POST
  /api/queue status=ready` is refused over every status but `dropped`, and
  `done`/`failed` no longer PATCH back to `ready`. The hourly stale-owed sweep
  re-offers every stale key, including the `failed` row `bin/fly-pool.sh` parks
  with `died N times …` that `bin/blocked-resolver.sh` intakes BY THAT REASON
  and the `done` row whose RESULT line the same lane reads out of the reason
  column — an upsert there would blank `reason`, `finished_at` and `target`,
  bump `attempt`, and take a parked ticket out of the resolver's two queue
  readers without a sound. The READY-QUEUE.log line still carries the re-offer,
  exactly as it does today. Offering is not attempting either: a `ready` put
  leaves `attempt` alone, so a consumed-and-re-offered line does not walk a
  ticket that never failed toward its retry cap.
- **A degraded read is the FILE, never nothing.** Every reader falls back to the
  grep it replaced and says so in `logs/ready-queue.log`. "No queue" and "we
  could not ask" are not the same answer, and the first one stops a fleet.
- **The fingerprint contribution is EMPTY while the flag is off.** A new input
  appearing in that hash reads as new-world on every project at once and buys a
  paid session per project for nothing (the 2026-08-22 $90/day project-1 loop).
- **A `ready` row is not claimable and a live build is not droppable.** Every
  claim path selects `status='queued'`, and the worker refuses `claimed →
  dropped`, so `bin/queue-line-drop.sh` running beside parallel triagers cannot
  abandon a build in flight.
- **The files keep being written.** This slice moves the first READER, not the
  writer. Deleting the file writes is the next cycle's work, not this one's.
- **A new status word never becomes custody by default.** `bin/fly-dispatch.sh`
  drops a leftover box file only on `claimed`/`done`/`failed`; every other rc-0
  answer falls through to the pull. Asserted per word (§13).
- **The session prompt sees what the gate braked on.** `bin/lib/rt/scope.sh`'s
  `queue-pending` arm reads `rq_lines`, so a row-only ticket reaches the paid
  session instead of collapsing the scope to "(none)". Asserted (§14).
- **No pipe into `grep -q` over the ready set.** `bin/preplan-tick.sh` is
  `set -u` only, but sourcing this lib pulls in `bin/jobs-client.sh`'s
  `-o pipefail`; `printf | grep -q` above the pipe buffer is SIGPIPE → rc 141 →
  the `||` deletes a live pre-plan. Both housekeeping sweeps read `$RQL` with a
  here-string, driven at ~180KB (§15). Same shape as BH-1044.

**Declared, not done:** the ticket's *one-time backfill* of `closeout_aged` from
`state/closeout-aged-out.tsv` is NOT in this slice. It is not load-bearing: the
10-minute sweep re-decides every dir still under `builds/`, so the table fills
itself within one tick of the flag going on, and a dir that is already gone can
never be recorded again by anyone. A backfill would only copy rows for dirs
nothing will ever ask about. If an operator wants the historical rows anyway,
`awk -F'\t' '{print $2, $1, $3, $4}' state/closeout-aged-out.tsv` feeds
`bin/jobs-client.sh closeout-aged-put` one line at a time.

**Not in this slice (declared, for the next one):** `bin/pipeline-health.sh`'s
`fly-pool.log` greps wait on the `machines` table (slice 9), its
`merge-sweep.log` grep on `pr_state_events`, and `bin/metrics-collect.sh` becoming
a query over `stage_events`. Those are reads of a LOG, not of a state file, and
each needs a table this slice does not add.

**Project scoping (BH-4120):** a box's `logs/READY-QUEUE.log` is shared by every
project on that box, so `rq_lines` / `rq_any` (and through them the triage
gate's queue brake) filter the FILE lines to the project they are asked about,
not only the rows. The rules, in order:
1. a line with a `project=<name>` token belongs to that project only (exact
   name, so `project=cromford` is never `harness-console`'s);
2. otherwise a GitHub-Issues project (fleet.conf board_prefix `-`) owns the lines
   whose key prefix is its own. The prefix comes from the launch line in
   `prompts/<project>.md`, the same read as `preplan_key_prefix`. The
   board_prefix column cannot answer this: it is the board API path;
3. an in-app project owns the untagged lines whose prefix is no GitHub-Issues
   project's (in-app boards share `PB`).

No title mention-matching. A PB line whose title names harness-console is still
project-8's. `bin/stale-owed-tickets.sh` now appends
`project=<name>` to every line it writes, so new lines are attributed by rule 1.

Fail-open to the whole file, exactly as before, when the answer cannot be read:
no project argument (fleet-wide callers like `bin/preplan-tick.sh`), no
`bin/fleet-conf.sh`, a project fleet.conf does not know, or a GitHub-Issues
project whose prompt has no launch line. That last one is what usually lies: a
project that still sees other boards' lines has a prompt with no
`run-build.sh <project> <issue-number> <PREFIX>-<issue-number>` line.

The gate's queue fingerprint hashes `rq_fp_file`. It is the whole file, byte for
byte, when nothing in it is foreign (every single-project box hashes what it did),
and only this project's key lines otherwise. On a multi-project box each project
with queue work re-runs one `queue-pending` tick once after the deploy, because
its hash input changed.

A call-guard repeat refusal on a single-session triage tick (rc 74, first line
`AGENT_CALL_REFUSED call-guard repeat ...`) is logged as
`rc=skip :: call-guard repeat (no new input)`, writes no ALERTS line, and beats
rc 0, so the Fleet screen's LAST RESULT is not FAILED. The BH-1021 failed-attempt
counter still counts it. Any other rc 74 stays a failure.

Probe on a live box:
`HARNESS=/root/harness bash -c '. /root/harness/bin/lib/ready-queue.sh; rq_lines /root/harness harness-console'`
prints nothing on box-small; the same call for project-8
prints its PB lines. Driven by `tests/ready-queue-scope.bh-4120-test.sh` and
`tests/run-triage-callguard-skip.bh-4120-test.sh`.
