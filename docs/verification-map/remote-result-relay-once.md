# One remote build, one relay, one close-out

**What it is:** the hand-off that carries a build finished on ANOTHER machine —
a Fly builder or a pool machine — back to the box that owns the project, so its
sweep posts exactly one close-out comment on the client's ticket. Two doors lead
into that box: the jobs ledger's `result` row (the box PULLS it) and a relay
json pushed by the hub (`state/remote-results/<project>/<KEY>.json`). Both are
live on purpose; the lane's whole job is making sure one build never comes
through both.

**How an operator reaches it:** `cron/hub.cron` runs `bin/fly-pool.sh` (via
`fly-pool-tick.sh`, every 10 minutes since BH-4059) and `bin/fly-results-ingest.sh sweep` (every
2 minutes); `bin/fly-dispatch.sh` also calls the ingest the moment it sees a
RESULT. On the owning box, `bin/run-triage.sh` sources `bin/lib/rt/staging.sh`
on every tick. `bin/lib/builder-direct.sh` is the shared vocabulary all three
read.

**The three hub outcomes.** `bd_result_in_ledger <project> <key> <line>
[machine-build-dir]` answers each build's "has this already arrived by row?" and
its rc is the whole decision. Pass the machine build dir and the question is
about THAT BUILD (the row's `detail.build_dir`); leave it off and the only
identity left is the ticket key, which a rebuild of the same ticket shares:

| rc | means | ingest does | pool reap does |
|---|---|---|---|
| 0 | the row is there | bookkeeping: `RELAYED`, no json, no ssh | `RELAYED`, hub json kept, no ssh |
| 1 | the ledger answered, no row | relays: json + artifacts over ssh | `pool_push_full` — json + artifacts over ssh |
| 2 | the ledger could not be asked | HOLDS, for at most `RELAY_HOLD_MAX_S` (240s): nothing pulled, nothing cleared, the builder keeps its RESULT | PARKS: `RELAY_DEFERRED` marker, nothing pushed |

rc 2 is the one that matters. Before BH-1041 it was folded into rc 1 and both
sites relayed on it, so a blink of the coordination DB pushed a copy of a result
whose row already existed and the client's ticket got a second comment. A hub
with **no** jobs client at all is not an outage — it can never ask, so it relays
exactly as it always has.

**The ingest's hold is bounded by the BUILDER's clock, not by the outage.**
`fly/builder-runner.sh` exits 0 after `IDLE_TIMEOUT=600` seconds with no new job,
which stops the machine and takes the tmpfs the held RESULT lives in — and
`bin/fly-dispatch.sh` then reads `stopped` + an active-job row as "died
mid-build", requeues, and marks the key `.failed` on attempt 2. So the ingest
gives up at `RELAY_HOLD_MAX_S` (240s, measured from the epoch on line 1 of the
flag) and relays exactly as an rc-1 read would, saying `HOLD EXPIRED` once in
`logs/ALERTS.log`. 240 plus the two `*/2` sweeps that bracket it is 480s, inside
the builder's 600. Relaying on expiry is safe because the box drops a relay
whose build it already staged (`BUILT_AS:`). The POOL's `RELAY_DEFERRED` needs
no such bound: its RESULT is already on the hub, so nothing can walk off with
it.

**The dedupe identity is the MACHINE's build dir**, not the result line. The
line diverges routinely (`bin/fly-pool.sh` parks the hub json with `head -c 200`,
the reap's pr-verify gate rewrites word 1 to `RESULT_UNVERIFIED`/
`RESULT_MALFORMED`, a builder that posts its own close-out appends
`| CLOSED-OUT: …` after its row was written). The build dir does not: it is
`basename $BUILD` on the builder, and it reaches the box twice —

- ledger row → `detail.build_dir` (`bin/run-build.sh`'s `result` artifact)
- relay json → `machine_build_dir` (`bin/fly-results-ingest.sh`,
  `bin/fly-pool.sh`, both read from the RESULT's `BUILD_DIR:` line)

Whichever path stages first writes it into the staged RESULT as its own
`BUILT_AS:` line, and the other path's guard looks for exactly that.

**How to drive it:**

| what | how |
|---|---|
| the whole lane, all six parts (incl. the bounded hold, §3e, and the dispatch requeue, §6) | `HARNESS_TEST_SANDBOX=1 bash tests/remote-result-relay-once.bh-1041-test.sh` |
| the hub ingest, including the kill flag | `HARNESS_TEST_SANDBOX=1 bash tests/builder-direct-test.sh` (§7) |
| the pool reap's row-vs-ssh decision | `HARNESS_TEST_SANDBOX=1 bash tests/pool-relay-rowfirst-test.sh` |
| the box's two staging loops | `HARNESS_TEST_SANDBOX=1 bash tests/ledger-blocked-artifact.bh-531-test.sh`, `HARNESS_TEST_SANDBOX=1 bash tests/fly-lane-db-test.sh` |

**Files it owns on a live box:**

- hub: `builds/pool-<project>-<KEY>-<ts>/RELAY_DEFERRED` — a pool result parked
  because the ledger could not be asked. Removed by the tick that resolves it
  (`pool_relay_retry`, top of every `bin/fly-pool.sh` run).
- hub: `state/fly/<project>-<KEY>.relay-deferred` — the ingest's equivalent, and
  its once-per-key alert flag. Line 1 is the epoch the hold bound is measured
  from; line 2 is the human stamp. Removed by any non-deferred completion
  (delivered, relayed, or the hold expiring) and by `bin/fly-dispatch.sh`'s
  died-mid-build requeue, which is the other way a key leaves the active row.
- hub: `builds/*/RELAYED` — custody moved, unchanged by this lane.
- box: `builds/<project>-<KEY>-remote<ts>/RESULT` — the staged copy. Carries
  `BUILD_DIR:` (the sender's own name), `BUILT_AS:` (the machine's), `JOB_ID:`
  on the ledger path and `ORIGINAL_RESULT:` when a blocked line was rewritten.
- box: `state/remote-results/<project>/.handled/` — consumed jsons and one
  `<job>.job` marker per staged ledger row; `.since` is the feed watermark.

**What to look at when it misbehaves:** `logs/fly-dispatch.log` and
`logs/fly-pool.log` on the hub for the per-key sentence, `logs/ALERTS.log` for
the one `LEDGER UNREADABLE` line per key (ingest) or per project per day (pool),
`ls builds/pool-*/RELAY_DEFERRED` for anything still parked, and on the box
`ls -d builds/<project>-<KEY>-remote*` — more than one dir for one build is the
failure this lane exists to prevent.

**What must never regress:** rc 2 is never read as "delivered" and never as
"absent". A deferral always leaves something that re-asks (the builder's own
RESULT for the ingest, the `RELAY_DEFERRED` marker for the pool), and the
ingest's hold always ENDS — in a relay if nothing else — before the builder's
600s autostop can take the result it is holding. `bin/pipeline-health.sh` reads
the pool's parked dirs (a `pool-*` build record with no `RELAYED`); it reads
neither `state/fly/*.relay-deferred` nor `state/fly/<p>-active.json`, so the
ingest's bound is the ingest's own backstop and not a page. Two genuinely
different builds of one ticket stage two dirs even when they end in the same
sentence — that is the identity working, not a duplicate; and a SECOND build of
one ticket is never satisfied by the FIRST build's row, because the question is
the build dir.

**When NEITHER path carries the cross-path name (BH-1284).** `machine_build_dir`
on the json and `detail.build_dir` on the row are written by code newer than
BH-1041, so every build from an older builder or sender carries neither and the
build-keyed guard above cannot fire at all. Two things then hold the lane
together:

- A staged dir's name cannot collide. It is `<project>-<key>-remote<ts>` at
  SECOND resolution and the two paths stage seconds apart, so two stagings in one
  second used to `mkdir -p` into the SAME dir and the second RESULT overwrote the
  first — a lost close-out when they were different builds, and the reason
  `tests/fly-lane-db-test.sh` §4b passed for a year without ever exercising its
  own guard. `RR_DEST` appends `-2`, `-3` … instead.
- Each path stamps its own marker — `BUILD_DIR:` from the relay loop, `JOB_ID:`
  from the ledger loop — so "has the OTHER path staged something for this ticket"
  is still answerable. If a dir for the ticket carries the OTHER path's marker
  and none carries this path's, this result is the duplicate of one of them and
  is consumed (json) or skipped (row) rather than posting a second close-out. If
  THIS path has staged the ticket before under a different name, the result is a
  build nothing has staged and is staged — project-3 TK-139.

It is a choice between two bad outcomes and the asymmetry decides it: a duplicate
close-out on a client's ticket has no undo. The one case it gets wrong — an old
sender or builder carrying a genuinely NEW build — writes a line to the project
log every time and pages once a day under the `relay-consume` flag, so a stranded
close-out is visible rather than silent. The hub's `builds/` carried about twenty
of these pairs from a single drain on 2026-09-17: same ticket, same PR, four
seconds apart, one dir with `BUILD_DIR:` and one with `JOB_ID:`.

**Consuming needs POSITIVE proof, and the undecidable case says so (BH-1301).**
The marker test above was originally written as "this ticket has SOME staged dir
and none of them carries my marker", which is also true when no dir carries
EITHER marker — and the hub makes those: `bin/review-rescue.sh` used to rewrite a
rescued RESULT down to `PR_CREATED` / `TIER:` / `RESCUED:` and dropped every
provenance line the build had. Two consequences, both fixed here:

- The consume branch now requires a dir carrying the OTHER path's marker.
  A ticket whose dirs carry neither marker proves nothing, so the result is
  STAGED (the reversible outcome — a duplicate dir is visible on disk, a
  consumed result is not) and the project log says no staged dir for the ticket
  carried either path's marker. Before this, a rescued dir was enough to consume
  the next result for that ticket and nothing ever retries a `.handled` one.
- A ticket staged by BOTH paths before, with an identity-less result arriving
  now, is genuinely undecidable: a third build and the other path's copy of one
  of the two look identical. It stages, as it always did, but no longer in
  silence — the project log gets a `staged by BOTH paths` line every tick and
  `logs/ALERTS.log` gets one a day under its own `relay-bypass` flag tag, which
  is separate from `relay-consume` so neither silences the other.

`bin/review-rescue.sh` is the other half: its APPROVE branch now rewrites RESULT
ADDITIVELY — the new header (`PR_CREATED`, the tier, `RESCUED:`) followed by
every other line of the old file — so `BUILT_AS:`, `BUILD_DIR:`, `JOB_ID:`,
`SOURCE:` and `TICKET_ID:` survive a rescue and the identity guards above keep
working on a rescued dir. Suites: `tests/staging-identity.bh-1301-test.sh` (the
four wrong cases, the two consume regressions, the identity short-circuit) and
`tests/review-rescue.bh-1301-test.sh` (provenance through a real rescue).

**Manual-only / not automatable:** nothing here has a UI. The end-to-end
confirmation is an operator reading one close-out comment on a real client
ticket after a real pool build; the suites cover every decision that leads to it.
