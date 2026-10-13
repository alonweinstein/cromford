# Pre-plan relay (box → coordination DB → hub → Fly builder)

**What it is:** the hop that makes a speculative pre-plan usable by a build that
runs somewhere else. `bin/run-preplan.sh` pays Fable to plan a queued ticket and
leaves the record in `plans/<project>-<KEY>/` **on the box that planned it**;
`bin/fly-pool.sh:push_preplan` then relays that record to the Fly machine that
will build the ticket. Until BH-658 the relay read that directory **on the hub**,
and the hub is forbidden to pre-plan ([hub-no-build.md](hub-no-build.md)), so it
was always empty there: every Fly build re-planned from scratch (7-10 minutes of
a 60-75 minute ticket) and no log line said so — 0 of 1052 build records on
box-project-4-1 carried a `PREPLAN_` line while that box's own `plans/` held
58 plan dirs. The record now also goes to the coordination DB as a `preplans`
row, which is the copy the hub can read.

**How an operator reaches it:** two cron lanes: `bin/preplan-tick.sh` every 2 minutes on a box, `bin/fly-pool-tick.sh` every 10 on the hub (BH-4059; an armed `queue` wake launches it sooner).

| Where | Lane | What it does here |
|---|---|---|
| a watcher box | `bin/preplan-tick.sh` (`cron/box.cron`) → `bin/run-preplan.sh` | writes `plans/<project>-<KEY>/` and, for a **Fly-routed** project (`flags/builder-fly-<project>`), publishes it: `POST /api/preplans` |
| the hub | `bin/fly-pool-tick.sh` (`cron/hub.cron`) → `bin/fly-pool.sh:push_preplan` | local `plans/` dir first, else `preplan_fetch` → `GET /api/preplans?project=&key=` → pushes the five files to `/run/harness/preplan/` on the machine, **`key` last** |
| the builder (any box) | `bin/run-build.sh` `# >>> preplan adopt` | `preplan_find` → thread-fingerprint check (`STALE` only when both fingerprints are present and differ; absence on either side fails **open**) → `preplan_check` → exactly one of `PREPLAN_HIT` (`bin/run-build.sh:1448`) / `PREPLAN_STALE` (`:1451`) / `PREPLAN_OFF` (`:1457`) / `PREPLAN_MISS` (`:1459`) in `pipeline.log`, plus `$BUILD/preplan-outcome` (`:1462`) which `bin/evidence-summary.sh` renders as the `\| pre-plan \|` row of the PR-body evidence block. A resumed dir keeps the earlier attempt's answer, and that branch is tested first so neither the kill flag nor a missing library re-labels it (`:1417`) |
| the hub, at dispatch | bin/overlap-guard.sh:files_of (from bin/fly-dispatch.sh) | local plans/ dir, else the row's planned_files — so the guard judges the same list the builder will be handed. One index GET per lookup that misses the local dir (the candidate, plus any building sibling whose list is not on this box): a handful per tick on the hub, none at all on a watcher box |
| the worker | `worker/jobs` `/api/preplans` routes (validation, upsert, 413, index projection, retention) | **ships in #774**. Until it deploys, every path here is the honest miss: the box logs `publish REFUSED (http 404)` and the hub says `no pre-plan for <KEY> (db: miss)` |

**How to drive it:**

| what | how |
|---|---|
| the relay itself: `preplan_fetch`, the publish gate, `push_preplan`, the producer | `bash tests/preplan-relay-test.sh` |
| the builder half: the four adopt outcomes, `preplan-outcome`, the evidence row | `bash tests/preplan-adopt.bh-776-test.sh` |
| the client verbs it calls (`preplan_put`/`get`/`index`) | `bash tests/jobs-client-test.sh` |
| the guard's third source | bash tests/overlap-guard-preplan-source-test.sh |
| the neighbours this must not disturb | `bash tests/preplan-speculative-test.sh`, `bash tests/pool-account-routing-test.sh`, `bash tests/hotfix-cap-exempt-test.sh`, `bash tests/hub-no-build-lanes-test.sh` |

Run every suite with `HARNESS_TEST_SANDBOX=1`. The producer section drives the
**real** `bin/run-preplan.sh` against a scratch `$HARNESS` with a fake
`agent-call.sh`/`git`/`curl`; `push_preplan` is extracted VERBATIM
(`sed -n '/^push_preplan() {/,/^}/p'`), per the driving conventions in
[README.md](README.md).

**Files it owns on a live box:**

- `logs/preplan.log` — `pre-plan published (N bytes)`, `pre-plan publish REFUSED
  (http 413)` (a **4xx**: the worker judged this plan) or `pre-plan publish
  unreachable (500|no answer) — the hub will record PREPLAN_MISS` (**5xx** or no
  answer: the worker broke, and we do not know whether the row landed), one per
  pre-plan, on the publishing box.
- `logs/fly-pool.log` — `relayed pre-plan for <KEY> to <machine> (source: db|local)`,
  or `no pre-plan for <KEY> (db: miss|outage|no client on this host) — builder
  will PREPLAN_MISS`, or `no pre-plan for <KEY> (relay: mktemp failed) — builder
  will PREPLAN_MISS`.
- `/run/harness/preplan/` **on the Fly machine** — `plan.md`, `base-sha`,
  `planned-files.txt`, `ticket-fp`, and `key` written LAST.
- `builds/<record>/pipeline.log` — the one `PREPLAN_HIT` / `PREPLAN_STALE` /
  `PREPLAN_MISS` / `PREPLAN_OFF` line the adopt writes on every branch, whether
  it used what was relayed, discarded it, found none, or was switched off.
- `builds/<record>/preplan-outcome` — the same answer as a one-line file
  (`HIT|STALE|MISS|OFF <why>`), which `bin/evidence-summary.sh` reads for the
  `| pre-plan |` row and the `preplan:{outcome,why}` object in its `--json`. A
  record written before BH-776 has no such file and renders neither.

**Preconditions / seed needs:** none on this branch. No new environment
variable; `HARNESS_SECRET` and `JOBS_URL` are the ones every box already holds.
The `preplans` table and its routes are #774's, and they self-apply on deploy —
ordering is safe either way: a box on these scripts against a worker that has not
redeployed yet gets a `404` (logged `REFUSED`, build plans fresh).

**Knobs:** `PREPLAN_SPECULATIVE=0` or `flags/preplan-speculative-off` switches
the whole thing off (publish, relay and adopt); `flags/builder-fly-<project>` —
the same file `bin/free-slots.sh` and `bin/lib/build-caps.sh` read — is what
makes a project publish at all.

**What must never regress:**

- **`key` is written LAST, in both directions.** `preplan_find` refuses a
  directory whose `key` does not match the job, so a half-written fetch or a
  half-finished push reads as "no pre-plan" instead of as a plan missing its
  staleness data — and a REUSED pool machine never gets the previous ticket's
  plan (the TK-493 shape). A row whose `ticket_key` is not the one asked for is
  refused before a single file is written.
- **The relayed plan is byte-identical to the published one.** `preplan_put`
  sends the file with `--rawfile`; `preplan_fetch` writes it back with `jq -j`,
  never through a `$(…)` capture, which would eat a trailing blank line and hand
  the builder a document the box never wrote.
- **Absence is not emptiness.** A row with no `planned_files` leaves no
  `planned-files.txt` (an empty one makes `preplan_check` answer UNVERIFIABLE);
  a row with no `ticket_fp` leaves no `ticket-fp` (an empty fingerprint compares
  unequal to every real one).
- **A miss is not an outage.** A 404 is `rc 1` (the plan is genuinely not there);
  a transport failure or an unparseable row is `rc 2`. The hub's line says which,
  because they send an operator to different places.
- **No branch is silent.** Every relay path writes one `fly-pool.log` line —
  including a failed `mktemp` — and every publish path writes one `preplan.log`
  line. The failure this lane exists to end was invisible, not loud.
- **Fail-open everywhere.** A refused or unreachable worker never changes
  `run-preplan.sh`'s exit code and never stops a relay: `push_preplan` returns 0
  on every path, and its temp dir is removed on every exit under a
  `/tmp/preplan-relay.*` guard.
- **Local projects are byte-identical.** No `flags/builder-fly-<project>`, no
  publish; a populated local `plans/` dir wins in `push_preplan` and costs no
  request.
