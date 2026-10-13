# A build whose PR never opened is owned end to end

**What it is:** the four lanes that between them stop a reviewed, pushed branch
with no pull request from sitting until a person notices. A build can end with
its diff committed, its review APPROVE, its branch on origin — and no PR, because
`gh pr create` returned no url. Two words describe that state and this entry is
about both of them.

BH-614. The 2026-09-17 project-5 shape: a stacked child's create 422'd on a
parent branch that had been deleted mid-build. Before this ticket the record's
queue row closed `done` (the ledger saying finished work about a build with no
PR), `bin/run-build.sh`'s `_job_finish` reached `failed` only through its `*)`
default, nothing listed such builds by branch, `bin/blocked-resolver.sh` had no
arm for the word so nothing ever re-entered it, and the console drew the stopped
build at step 0 as "still planning". the operator's 2026-09-13 rule is that nothing in
this harness waits on a human; a ladder that runs out records ABANDONED.

**The two words, and why there are two.** `bin/run-build.sh`'s RESULT ratchet
(#749/BH-574) writes `PR_CREATE_FAILED: <gh words>` when a create claim carries
no `https://`. `bin/fly-pool.sh`'s url-shape gate (BH-765) writes
`RESULT_MALFORMED PR_CREATED …` when it reaps a record an OLDER pool image wrote,
whose line 1 claims a PR and whose field 2 is not a PR url. Same state, two
spellers, and BH-765's suite pins its byte for byte — so nothing here re-spells
it. Every lane that owns the park reads BOTH shapes instead. See
[pr-verify-gate.md](pr-verify-gate.md) for the gate that writes the second one.

`RESULT_UNVERIFIED PR_CREATED …` is deliberately NOT this park. That is a PR
that could not be READ (BH-709), the alert medic owns it, and rebuilding it would
open a second PR for a ticket whose first one is probably fine.

**How an operator reaches it:** no UI on the hub side; the surfaces are files and
one console screen.

**Primary lanes / scripts:**
- `bin/run-build.sh` `# >>> pr create failed` — inside the build. One ALERTS line
  naming the branch and the fix command, one `pipeline.log` line, and a
  `pr_create_failed` ledger artifact (`ref` = the branch, `detail` = JSON with
  `record` / `branch` / `base` / `error`, gh's own words cut at 900 chars). The
  put is fail-open: no `JOB_ID` or no jobs worker, nothing recorded, build ends
  the same way.
- `bin/run-build.sh` `_job_finish` — `PR_CREATE_FAILED*) st=failed` by name, above
  the catch-all. The `D` in FAILED is what keeps it out of the `PR_CREATED*` arm.
- `bin/fly-pool.sh` `# >>> reap row close (BH-614)` — the reap (`cron/hub.cron`,
  `*/10` through `fly-pool-tick.sh`). Both failed-create words close the queue row
  `failed`; everything else still closes `done`.
- `bin/pr-url-reconcile.sh` — hub cron, `3,13,23,33,43,53`. Walks both shapes, and
  skips any record carrying `.blocked-resolver-superseded`.
- `bin/blocked-resolver.sh` — hub cron, `*/10`. `pr-create-failed` is a park it
  owns and answers `rebuild-fresh`.
- `console-ui/src/lib/stages.js` — `pr_create_failed` is a known stage at the PR
  step (4) and a member of `DEAD_STAGES`.

**The handshake, which is the whole design.** The resolver's intake for this park
is the BUILD RECORD ONLY, never the FAILED queue row. `bin/fly-pool.sh` closes
that row the moment it reaps, seconds after the build ended, and
`bin/pr-url-reconcile.sh` runs every ten minutes to find out whether the PR did
open after all on a later rung of the create ladder. A rebuild inside that window
is two PRs for one ticket. `br_from_builds`' existing 90-minute record floor IS
the reconciler's window, by construction — and a record the reconciler re-linked
reads `PR_CREATED …` at line 1, so it is never offered here at all. The other
direction is the `.blocked-resolver-superseded` marker: once the resolver has
replaced a record with a fresh build, the reconciler never re-links the retired
one, so a hand-opened PR on the old branch cannot reach the merge sweep beside
the rebuild's own.

**Bounds.** `BR_MAX_REBUILDS` (default 3) counts on the TICKET key in
`state/blocked-resolver/<project>/<project>-<KEY>.json`, so one PR-open failure
buys one rebuild and the third park ends ABANDONED with one ALERTS line. A
rebuild that itself ends `PR_CREATE_FAILED` is not read as a rebuild outcome
(`br_rebuild_outcome` answers ""); it re-enters through `br_from_builds` after the
floor, on that same counter.

**How to drive it (the suites that run the real code):**

```sh
HARNESS_TEST_SANDBOX=1 bash tests/pr-create-failed-owned.bh-614-test.sh
HARNESS_TEST_SANDBOX=1 bash tests/blocked-resolver.bh-614-test.sh
cd console-ui && node --test tests/stages.bh-614.test.js
```

`tests/pr-create-failed-owned.bh-614-test.sh` lifts the reap row close, `QROW`,
`_job_finish` and the whole `# >>> pr create call` block out of the production
scripts by their markers and runs them with `queue_done`, `job_update`,
`job_artifact_put` and `gh_pr_create_ladder` recorded.
`tests/blocked-resolver.bh-614-test.sh` runs the REAL `bin/blocked-resolver.sh`
and the REAL `bin/pr-url-reconcile.sh` end to end against a scratch `$HARNESS`.

**Preconditions / seed needs:** `jq`, a scratch `fleet.conf`, and nothing else —
no network, no live harness, no new env var. The only tunables are ones that
already existed: `BR_MAX_REBUILDS` and the `PR_URL_RECONCILE*` twins
([settings-knobs.md](settings-knobs.md)).

**What must never regress:**
- **`RESULT_UNVERIFIED` never joins this park.** Not in the reap's failed arm, not
  in `br_from_builds`, not in the reconciler's walk. It is an unread PR.
- **The FAILED queue row is never an intake.** `br_from_queue` reads `failed` rows
  only for "died N times" / "deferred N times". A `PR_CREATE_FAILED` row there
  would rebuild inside the reconciler's window.
- **The 90-minute floor stays.** It is not a tuning knob here; it is the
  reconciler's window expressed as a number.
- **A superseded record is never re-linked, and a re-linked record is never
  rebuilt.** Both halves, or the sweep gets two PRs for one ticket.
- **The reap's row close stays OUTSIDE `# >>> pr verify gate`.** BH-765's and
  BH-709's suites extract that block; a row close inside it would be lifted into
  their fixtures and the two tickets would fight over the same lines.
- **The ledger put stays fail-open and guarded on `JOB_ID`.** A box with no jobs
  worker must record nothing and fail nothing.

**On a live hub (the files that show it working):**

```sh
grep 'PR CREATE FAILED on ' /root/harness/logs/ALERTS.log | tail -5
grep 'pr-create-failed' /root/harness/logs/blocked-resolver.log | tail -5
grep -oE 'skipped=[0-9]+' /root/harness/logs/pr-url-reconcile.log | tail -5
head -1 /root/harness/builds/pool-*/RESULT | sort | uniq -c
ls /root/harness/builds/*/.blocked-resolver-superseded 2>/dev/null | wc -l
```

**Manual-only / not automatable:** repairing RESULT files an older version
already mislabelled (`builds/` is machine state, not repo code), and watching a
real reap close a row `failed` on the hub. Accepted residual race, named on
purpose: the reconciler walks at most `PR_URL_RECONCILE_MAX` records per tick
under a deadline and reports the rest as `unwalked=`. A record it never reached
inside 90 minutes could be rebuilt while a hand-opened PR exists. The superseded
marker then keeps the OLD record from ever being re-linked, so the worst case is
one extra PR, visible on the board, not a silent mislink. A resumed build
(`RESUME_BUILD`) clears EVERY `.pr-url-reconcile*` marker at the top — the two
first written plus `.pr-url-reconcile-mislinked` and its page's own memory — and
does NOT clear `.blocked-resolver-superseded`: a superseded record stays
superseded.
