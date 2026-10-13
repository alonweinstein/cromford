# A rebuild enqueue that FAILED is really retried

**What it is:** the retry rung inside `bin/blocked-resolver.sh` — the source
`br_from_rebuilds` that re-offers a park whose enqueue did not land, the action
`br_rebuild_retry` that re-tries the enqueue and nothing else, and
`br_rebuild_settle`, the one place either rung reads what an enqueue answered.

**Why it exists:** BH-488. REBUILD FRESH (rung 3) closes the stale PR, marks the
build record `.blocked-resolver-superseded` and releases the conductor's
hand-off — and only THEN enqueues. When `br_enqueue_fresh` answered rc 1 (no
ticket id, a jobs client that took no row, a box that would not answer) the lane
wrote `rebuild-fresh-failed` and logged *"retried next tick, no counter spent"*.
Nothing retried it. The state it landed in was invisible to every source:
`br_from_conductor` skips a row that is no longer `BLOCKED_HUMAN`/`RED_TWICE`
and its hand-off fallback needs the PR OPEN (it is closed); `br_from_builds`
skips a superseded record; `br_from_queue` never had a row; and
`br_from_rebuilds` only re-offered a last attempt of `rebuild-fresh`. project-5
#1315/#1383 sat seven hours with no owner and nothing said so.

**How an operator reaches it:** `bin/blocked-resolver.sh` on the hub,
`cron/hub.cron`, every 10 minutes (offset from the merge conductor). There is no
separate lane — the retry is a rung of the same drain:

| Step | Where | What it does |
|---|---|---|
| the re-offer | `br_from_rebuilds` (first source in `br_candidates`) | a state file whose last non-hold attempt is `rebuild-fresh-failed`, outcome `""` or `HELD`, cap key `<project>-<KEY>` → row `rebuild <TAB> p <TAB> ck <TAB> rebuild-enqueue-failed <TAB> parked_url <TAB> parked_rec <TAB> KEY`, inside the same `BR_PER_TICK` budget |
| the classifier | `br_reason_of` → `br_action` | `rebuild-enqueue-failed` → `rebuild-retry` |
| the rung | `br_rebuild_retry` | MERGED guard → `br_hold_gate` → `BR_MAX_REBUILDS` cap (→ `br_abandon`) → OBSERVE → `br_enqueue_fresh` → `br_rebuild_settle`. It never calls `br_close_pr` and never re-marks the record |
| the settle | `br_rebuild_settle` | rc 0: spend `rebuilds`, reset `enqueue_failures` and `enqueue_why`. rc 2: the nokey refusal, counted and capped (BH-530). rc 1: no counter, one attempt per episode, `enqueue_failures + 1` for a failure carrying the SAME `enqueue_why` (a new reason restarts at 1), and at `BR_ENQUEUE_FAIL_MAX` the park STALLS — see [resolver-saturation.md](resolver-saturation.md) (BH-1122) |
| the tick dedupe | `br_one` | one action per `<project>/<cap-key>` per tick (`TICK_DONE`), so a retry row and a still-`BLOCKED_HUMAN` conductor row for the same ticket cannot both enqueue. The key is recorded AFTER the dispatch and only when a rung really ran — never in observe mode — and the check sits after the `-> <action>` candidate line, so a muted row has already said what it was a candidate for |

**How to drive it:**

| what | how |
|---|---|
| a failed enqueue, then a retry that lands (state at tick 1, re-entry at tick 2, nothing closed twice) | section C of `bash tests/blocked-resolver.bh-488-test.sh` |
| three IDENTICAL failures stall the park, page once, and add nothing on the ticks after (BH-1122 replaced BH-488's "page at six, retry for ever") | section D of the same suite |
| one enqueue per ticket per tick, with the conductor row still `BLOCKED_HUMAN` | section E |
| the mute is claimed only for a rung that ran: observe mode mutes nothing, and a muted row still names its candidate rung first | section E2 |
| a HOLD on the ticket stops the retry, and the row is still there when the hold lifts | section F (drives the real `bin/lib/hold.sh`) |
| the negatives: a keyless PR-number cap key, a build in flight, an ABANDONED ticket, a spent cap | section G |
| the one key resolver and the source word it logs | sections A and B |
| the existing ladder, unchanged | `bash tests/blocked-resolver-test.sh` (309 cases, including §9a's nokey cap and §9b's branch-carries-the-key) |
| observe mode takes no rung and writes nothing | section H |
| red-before-green | `bin/repro-gate.sh <merge-base>` — 32 of the suite's 63 cases fail at the base tree, where tick 2 enqueues nothing and no log line names the key's source |
| the suite reads no clock and no network | `bin/test-determinism-lint.sh tests/blocked-resolver.bh-488-test.sh` |

**Files it names on a live box:**

- `state/blocked-resolver/<project>/<cap-key>.json` — `parked_url` and
  `parked_rec` (both written BEFORE the enqueue, so a failed one can still be
  found), `enqueue_failures` (a number; 0 after any enqueue that lands), and the
  attempt actions `rebuild-fresh-failed` / `rebuild-fresh`.
- `enqueue_why` on the same record — the reason the streak is counting. BH-1122's
  stall fires only on consecutive failures carrying the SAME string.
- `logs/blocked-resolver.log` — `rebuild enqueue FAILED <n>x (<why>) — retried
  next tick, no counter spent`, and the `REBUILD FRESH <n> of 3 (enqueue retry
  <k>)` line when it finally lands.
- `logs/ALERTS.log` — the `[blocked-resolver] STALLED …` line at
  `BR_ENQUEUE_FAIL_MAX`, through `bin/lane-alert.sh`. A stall stops the SPENDING;
  an enqueue that cannot be made is still never a ticket terminal.

**Knobs:** `BR_ENQUEUE_FAIL_MAX` (default 3 = half an hour of `*/10` ticks) —
how many identical failures before the park stalls and pages once. It replaced
BH-488's `BR_ENQUEUE_ALERT_AFTER` (6), which is **removed**: with a stall at
three that page was unreachable. `BR_MAX_REBUILDS` (3) and `BR_PER_TICK` (4)
bound the retry exactly as they bound rung 3.

**What must never regress:**

- **`parked_url` / `parked_rec` are written before the enqueue, never after.**
  Everything above that line is irreversible — the PR is closed, the record is
  marked, the hand-off is released — so those two fields are the only route back
  to the ticket. Written after a successful enqueue (as `parked_url` was), they
  are exactly what the failing path never got.
- **The retry never closes a PR and never re-marks a record.** Rung 3 did both,
  once. Doing them again turns one park into two closed PRs and a second
  supersede marker on a record somebody is reading as evidence.
- **A failed enqueue spends no `rebuilds`.** `rebuilds` is bumped only from the
  rc-0 arm, after `queue_put` printed a row id — a build is never stamped
  started without one.
- **One attempt per episode, one page per episode.** The lane re-offers every
  ten minutes; an attempt per tick would put 144 copies of "the enqueue did not
  land" into the list the ABANDONED alert prints, and displace what the ladder
  actually tried. `enqueue_failures` is the per-tick counter instead.
- **It is never capped into ABANDONED on its own.** An enqueue that cannot be
  made is a machine problem (#511: no rung transition on a clock or a machine
  problem), so nothing about it closes a PR or ends a ticket. Since BH-1122 it
  is not retried for ever either: three identical failures STALL the park — one
  alert, and no rung until its row changes — which is a terminal for the
  spending, not for the ticket. `BR_MAX_REBUILDS` still ends the ladder if a
  retry LANDS a build too many times.
- **A keyless park is never retried.** A PR-number cap key (`o-tproj-77`) means
  no key was ever derivable; that refusal is `br_enqueue_fresh` rc 2, which is
  deterministic, counted and capped. Retrying it would be the same refusal every
  ten minutes, which is the bug BH-530 fixed.
- **A held retry keeps its row.** `HELD` is the one outcome `br_from_rebuilds`
  still offers for this shape, so `br_hold_recheck` sees the lift; the row costs
  no `PER_TICK` slot while it is held.
- **One enqueue per ticket per tick.** A retry row keys on the cap key and a
  conductor row on the PR number, so the drain's rkey dedupe cannot see that
  they are the same ticket. `TICK_DONE` is what does.
