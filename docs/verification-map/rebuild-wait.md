# Rebuild ledger and the wait fields

**What it is:** the blocked-resolver's state row
(`state/blocked-resolver/<project>/<project>-<KEY>.json`) has always counted
rebuilds as a number — `rebuilds: 2` — which answers "how many" and nothing
else. The ledger replaces the number as the source of truth for *what is
outstanding*:

| field | what it holds |
|---|---|
| `rebuild_jobs[]` | one `{id, enqueued_at, at}` per rebuild the lane enqueued, deduped on `id` |
| `wait` | `REBUILD_WAIT` while a rebuild is outstanding, `-` when nothing is |
| `wait_job` | the `id` of the job the row is waiting on, `-` when cleared |

**A rebuild is held while it is live.** Before the rebuild rung closes the stale
PR, emits its event or spends a counter, `br_rebuild_inflight` reads `queue_row`
for the ticket key. A `queued` or `claimed` row holds the park: `br_rebuild_wait`
logs the wait, writes `wait`/`wait_job`, and sets `BR_REBUILD_WAITING=1`.
`br_one` reads that flag after the dispatch and returns rc 3, so the conductor's
hand-off park stays and the drain counts no rung slot. The flag is what carries
the hold rather than the rung's exit code, because `br_regen_rung` dispatches the
displaced rebuild rung itself and returns its own status.

A `duplicate` answer from the worker is treated the same way — a build is
already in flight and this tick does not pay for it. `br_enqueue_fresh` maps it
to rc 3 and the rung hands it to `br_enqueue_dup_race`, which RE-PROBES the
queue: a live row read back names that job in `wait_job` and, when the ledger
has never seen its `enqueued_at`, records the one external `rebuild-fresh`
attempt on the SAME tick — without it the racing build's RESULT would never be
consumed and the next tick would enqueue on top of it. Only when the re-probe
cannot read a live row does the hold fall back to the id-less
`<KEY>@duplicate-race` — and even then the one external `rebuild-fresh` attempt
is recorded under that placeholder, because a row whose last non-hold attempt is
not `rebuild-fresh` is not polled by `br_from_rebuilds` at all and the raced
build's RESULT would never be consumed. The event and the PR close have already
gone out on that tick: that is the documented cost of the race, and the rung is
still not counted. Only a `queued` answer writes a new `rebuild_jobs[]` entry
and bumps the counter. If the pre-check keeps answering "unreadable" and the
worker keeps answering `duplicate`, that `resolver_rung` event fires once per
tick — the close does not repeat (`br_close_pr` reads the PR state first), and
the hub's own client has `queue_row`, so this needs a worker outage that fails
the GET while the POST succeeds.

`br_enqueue_dup_race` keeps its own `inflight_rc`, zeroed on entry. `|| rc=$?`
assigns only when a command FAILS, so re-using the caller's variable — which by
definition holds the pre-check's non-zero — made every successful re-probe read
as a failure and the real job id was never written.

**A build this lane did not start is still consumed.** A live row whose
`enqueued_at` no `rebuild_jobs[]` entry matches is an EXTERNAL job — a triage
relaunch, a watchdog requeue. It is never added to the ledger (the cap counts
the rebuilds this lane bought), but on first sighting the rung records exactly
one `rebuild-fresh` attempt naming it, so `br_from_rebuilds` — which polls rows
whose last non-hold attempt is `rebuild-fresh` — reads that build's RESULT when
it ends instead of ignoring it. Jobs this lane enqueued already have their
attempt and get nothing new.

**An external build is always older than our attempt, and the fallback knows
it.** `br_from_rebuilds` prefers a `builds/` record and falls back to the
worker's `done` row for a remote build whose record never reached this box. That
fallback accepts a row whose `enqueued_at` is at or after the rebuild attempt —
the right question for a build THIS LANE enqueued, and one an external job can
never pass, because its attempt is written at FIRST SIGHTING, after the worker
had already queued it. So the fallback also accepts the row the park is holding
for: `wait_job` equal to `<KEY>@<the row's enqueued_at>`, or the
`<KEY>@duplicate-race` placeholder. A job this lane enqueued carries a ledger id
(`~rN`) in `wait_job`, so neither shape can match one of our own rows. Without
this the next tick read the row as `done`, found the cap unspent, closed the
stale PR and bought a second build on top of one that had already produced a PR
— the double build this slice exists to stop.

**The cap counts distinct job ids, not ticks — and never forgets the old
counter.** `rebuild_jobs[]` is deduped on `id`, so a live row read on ten
consecutive ticks stays one entry. The cap is `max(length(rebuild_jobs),
rebuilds)`: `rebuilds` is bumped only beside the ledger write, so for a row born
after this landed the two agree and the max changes nothing — but a row parked
BEFORE it carries `rebuilds: 2` and no ledger, and reading the fresh one-entry
ledger alone would forget the two builds it had already bought (three more
builds on a ladder of three, `rebuild 4 of 3` in the log, and an ABANDONED alert
saying "3 times" against a counter of 5). When the cap is reached and no build
is live, the ladder ends with one ABANDONED alert that lists every job id that
was tried. If the cap is reached but `queue_row` is
unreadable, the park is held rather than abandoned. How LONG the ladder is is a
separate question with its own answer (BH-579): `br_rebuild_fresh` compares the
count against `br_rebuild_cap` — three rebuilds for a large conflict, one for a
small one — while `br_rebuild_retry` still compares against `MAX_REBUILDS`.

**A finished build clears the wait.** `br_from_rebuilds` watches the build
record and the worker's `done` list. When a result arrives for the waited-on
job — `PR_CREATED`, `BUILD_DEAD`, `PLAN_BLOCKED`, `REVIEW_BLOCKED` or
`DECOMPOSE_FAILED` — `wait`/`wait_job` are cleared beside the attempt that
records it, on the landed branch and on every consumed failure alike.

**One landed path, in one place.** Both rungs route EVERY enqueue answer
through `br_rebuild_settle`; its rc-0 arm is the only code that adds the ledger
row, bumps `rebuilds`, resets `enqueue_failures`, CLEARS `enqueue_why` and
clears the wait. Clearing `enqueue_why` is
load-bearing: BH-1122's per-episode attempt record compares the stored why
against the new one, so an enqueue that lands between two failures with the same
reason has to end that episode or the second failure is read as a continuation
and never recorded.

**Absent is not zero.** `br_jobs_count` prints `null` for a row that has no
`rebuild_jobs` key at all (a row written before this landed — count on
`rebuilds`) and `0` for a row whose ledger is present and empty. Collapsing
those two is how an already-capped ticket gets one more rebuild; taking the
ledger over a larger `rebuilds` is how a pre-ledger row gets three.

**Old clients keep legacy behaviour.** A pool project whose `bin/jobs-client.sh`
does not expose `queue_row` cannot read live rows or mint ledger ids, so the
rebuild rung falls back to the legacy `rebuilds` counter and does not create a
`rebuild_jobs[]` ledger. `br_rebuild_inflight` answers rc 3 there — "nothing to
ask" — which is also the answer for a park with no ticket key, so a box whose
`bin/` has not synced never hangs on a reader it does not have. A box lane (no
`flags/fly-pool-<project>`) has no queue row by design and answers rc 1.

**The job id.** `<KEY>@<enqueued_at>~r<n+1>` where `<enqueued_at>` is read back
from the worker's own row after the enqueue. When that read-back fails the stamp
is this box's clock and the id carries a `~local` suffix, because such an id can
never match a live row's stamp and should be readable as such. The consequence
is deliberate and worth knowing: the NEXT tick reads the worker's real stamp,
`br_job_for_enq` finds no ledger entry for it, and the lane holds its own build
as an EXTERNAL one — a second `rebuild-fresh` attempt with reason
`external-rebuild-wait`. It costs nothing on the cap (the ledger entry is
already there and the attempt is deduped per job id) and the build's RESULT is
consumed the same way. The ledger is
matched on `enqueued_at`, not on the whole id — the `~rN` suffix is this lane's,
and the worker has never seen it.

**Contract on this slice.** BH-487.0 ships the ledger functions and wait-field
writers; BH-947 wires them into the rebuild rung with the live-build pre-check,
the `duplicate` hold, the distinct-id cap and the result clearing. The
`.tkey` cache file BH-487.2 adds must not be a `*.json`: `br_from_rebuilds`
globs `"$ST"/*/*.json` and would read a cache file as a state row.

**How an operator reaches it:** no new lane and no new cron line.
`bin/lib/rebuild-ledger.sh` is sourced — hard, like the conductor's lib — by
`bin/blocked-resolver.sh`, which runs from `cron/hub.cron` at `4,14,24,34,44,54`.
A box whose `bin/lib/` has not synced makes the resolver print one stderr line
naming the missing lib and exit 1 rather than run a ladder with the ledger
functions undefined.

```sh
# the whole row for one queued build, one TSV line:
# status, enqueued_at, claimed_by, requested_by, reason
/root/harness/bin/jobs-client.sh queue-row <project> <KEY>
# rc 0 = the row; rc 2 = worker answered, never enqueued; rc 1 = outage
```

**How to drive it:**

| what | how |
|---|---|
| the ledger contract — dedupe, wait fields, `queue_row` | `HARNESS_TEST_SANDBOX=1 bash tests/rebuild-ledger.bh-946-test.sh` |
| the rebuild rung holds on live rows, refuses `duplicate`, counts distinct ids and clears wait on results | `HARNESS_TEST_SANDBOX=1 bash tests/blocked-resolver.bh-947-test.sh` |
| the resolver's own regression corpus | `HARNESS_TEST_SANDBOX=1 bash tests/blocked-resolver-test.sh` |

**What shows it on a live box:** `state/blocked-resolver/<project>/*.json` now
carries `rebuild_jobs[]`, `wait` and `wait_job`. `logs/blocked-resolver.log`
shows `rebuild already in flight (job <id>, claimed on <machine>) — waiting`
while a build is live, `cannot read the queue to tell whether job <id> finished
— holding, NOT abandoned` during an outage at the cap, and `the fresh rebuild
landed (...)` when its result is consumed. A rehearsal without writes:
`BR_OBSERVE=1 bin/blocked-resolver.sh` prints `WOULD wait` for a park whose key
has a live queue row.

**Manual-only / not automatable:** nothing here. cromford has no
user-facing app; the CLI verb above and a resolver tick are the whole surface.
