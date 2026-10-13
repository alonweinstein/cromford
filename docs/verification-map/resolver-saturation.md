# The resolver stops spending on a park it cannot move, and says when it is saturated

**What it is:** the three bounds BH-1122 put on `bin/blocked-resolver.sh` — a
park that answers identically N times STALLS (`br_stall`, `br_stall_fp`), the
oldest hand-off in a project goes first (`br_from_conductor`), and a lane whose
ticks keep ending on their budget pages once (`br_saturated_alert`, the
`.saturated` marker `bin/merge-conductor.sh` reads).

**Why it exists:** every one of the three was visible in the log and none of them
was actionable from it. `br_rebuild_settle`'s rc-1 arm said *"retried next tick,
no counter spent"* for ever — project-4 TK-1674, 79 lines, 25 in a row, each one a
rung of a ten-minute tick. `br_adjudicate`'s no-verdict arm did the same with a
billable review call behind it. `pr-state.tsv` was read in file order, so the
longest-waiting park was whichever one was written first. And 40 consecutive hub
ticks ended `rungs=4/4 reason=budget`, which is the line a merely busy lane
writes, while #679 sat 434 minutes past its TTL and was never reached.

**How an operator reaches it:** `bin/blocked-resolver.sh` on the hub,
`cron/hub.cron`, every 10 minutes (offset from the merge conductor). There is no
UI and no route — the surfaces are the log, the alerts and the state tree:

| Surface | Where | What it says |
|---|---|---|
| the tick line | `logs/blocked-resolver.log` | `tick: candidates=N projects=N visited=[…] skipped=[…] rungs=n/k reason=budget\|drained oldest_untouched=<Nm\|->` — the last field is the age of the oldest candidate this tick never dispatched, `-` when there was none or none carried an age |
| the stall page | `logs/ALERTS.log` via `bin/lane-alert.sh` | `[blocked-resolver] STALLED <p>/<ticket>: <n> identical <what> outcomes in a row — <why>` plus the state file to clear |
| the saturation page | same | `[blocked-resolver] SATURATED: <n> consecutive ticks ended on reason=budget` plus candidates, `BR_PER_TICK`, oldest untouched, top rung consumers and the hours-to-first-touch division |
| the park's record | `state/blocked-resolver/<p>/<cap-key>.json` | `.outcome = "STALLED"`, `.stalled_fp` (`reason\|url\|record\|head`), `.enqueue_failures`, `.enqueue_why`, and the `stalled` / `stall-cleared` attempts |
| the streak | `state/blocked-resolver/.saturation.tsv` | `streak <n> alerted <0\|1>` and one `rungs <project> <n>` row per project over the streak |
| the marker | `state/blocked-resolver/.saturated` | present only while the SATURATED alert stands; `bin/merge-conductor.sh` reads it with `-e`, in two places |
| the conductor's per-PR STUCK page | `logs/ALERTS.log` via `bin/lane-alert.sh` (and the same line in `logs/merge-conductor.log`) | `STUCK: <n>m in one state … waiting on bin/blocked-resolver.sh to drain the park (<why>) — bin/blocked-resolver.sh is SATURATED: see the [blocked-resolver] SATURATED line in logs/ALERTS.log …` — the page a person receives names the lane alert, so nobody is sent to wait on a lane that is out of rungs (`mc_stuck_check`) |
| the conductor's re-kick line | `logs/merge-conductor.log` | `… still parked past its TTL on <head> — bin/blocked-resolver.sh is SATURATED …; not re-handed off, its hand-off record stands` |

**How to drive it:**

| what | how |
|---|---|
| three identical enqueue failures stall, page once and leave the candidate list | section 1 of `HARNESS_TEST_SANDBOX=1 bash tests/blocked-resolver.bh-1122-test.sh` |
| a failure with a DIFFERENT reason restarts the streak; `BR_ENQUEUE_FAIL_MAX` moves the bound; two failures then a success is untouched | sections 1b, 1c, 1d |
| three silent adjudications stall, buy no more model calls, and a verdict in between does not | section 2 |
| TTL-breached hand-offs first, then oldest; an unreadable park age sorts last; `MC_TTL_BLOCKED_HUMAN` moves the line | section 3 |
| `oldest_untouched=` on a budget tick, a drained tick (`-`) and a share-capped row | section 4 |
| K consecutive budget ticks page once, ticks after that are silent, a drained or idle tick resets, the next streak pages again, and the page names where the rungs went | section 5 |
| a STALLED and an ABANDONED record each cost no rung; a stalled park whose head moved comes straight back | section 7 |
| the conductor's per-PR STUCK page carries the pointer to the lane alert while the marker stands, and carries nothing extra without it | section 6 (drives `mc_stuck_check` and reads the recorded `bin/lane-alert.sh` arguments) |
| the conductor references the alert instead of re-handing off, and is byte-for-byte unchanged with the marker absent | section 6 (extracts `stuck_rekick` verbatim from `bin/merge-conductor.sh`) |
| the contract this reversed, and the one it replaced it with | section D of `tests/blocked-resolver.bh-488-test.sh` |
| the tick line's other fields, unchanged | section 2 of `tests/blocked-resolver.bh-980-test.sh` |
| the ladder, unchanged | `tests/blocked-resolver-test.sh` (309 cases), `tests/resolver-per-project-budget.bh-870-test.sh`, `tests/resolver-hold-test.sh` |
| the suite reads no clock it has not pinned | `bin/test-determinism-lint.sh tests/blocked-resolver.bh-1122-test.sh` |

**Preconditions / seed needs:** none on a live box — the lane writes all of this
itself. To see a STALLED park on purpose, stop the jobs client and let a rebuild
rung run three ticks. To see SATURATED without waiting two hours, set
`BR_SATURATED_TICKS` lower in `env/global.env`.

**Knobs:** `BR_ENQUEUE_FAIL_MAX` (3), `BR_ADJ_NOVERDICT_MAX` (3),
`BR_SATURATED_TICKS` (12), `BR_PER_TICK` (4) and `BR_PER_TICK_<PROJECT>`. All in
`env-templates/global.env.example`, with the hours-to-first-touch arithmetic. A
0 or a typo on the first three falls back to the default with one `say` line.

**What must never regress:**

- **The outcome is written before the alert is sent.** A page that does not
  deliver must still stop the spending. Reversed, a failed send leaves a park
  that is "paged but still spending" — which is the state this ticket is about.
- **A stall is not a ticket terminal.** Nothing is closed, nothing is ABANDONED,
  no rebuild counter moves. An enqueue that cannot be made is still a machine
  problem (BH-488); it just stops being a free one.
- **`stalled` and `stall-cleared` are read past as non-ladder attempts.** If a
  stall displaces `rebuild-fresh-failed` as the last attempt, clearing
  `.outcome` puts back a row `br_from_rebuilds` no longer recognises — and the
  alert's own instruction becomes false.
- **The fingerprint is local reads only.** `br_stall_fp` takes the head from
  `pr-state.tsv`, never from `gh`. A fingerprint that costs an API call per
  candidate goes stale the first time the bucket runs out.
- **A conductor re-hand-off on the same head does not re-arm a stall.** That is
  exactly the loop the ticket describes.
- **An unreadable `since` sorts LAST.** Unknown park age is not oldest (D11), and
  the sort is `-s` so equal ages keep file order.
- **`oldest_untouched` counts only candidates that were never dispatched.** A
  row that answered rc 3 was looked at. `-`, never `0m`, when it is unknown.
- **The streak resets on ANY non-budget end, including an idle tick.** An empty
  stream never ends on `budget`, so a lane with nothing to do is not a saturated
  one.
- **The `.saturated` marker has one writer and two readers.** The resolver writes
  and removes it; the conductor only tests for it, in `mc_stuck_check` (the page)
  and in `stuck_rekick` (the hand-off). Removing it restores the pre-BH-1122 page
  and re-kick exactly.
- **The pointer rides the PAGE, not only the log.** The ask was that the per-PR
  STUCK page reference the saturation alert; a line in `logs/merge-conductor.log`
  is not what the reader of a CRITICAL page sees.

**Manual-only / not automatable:** the live hub numbers in the SATURATED example
(710 candidates, `oldest_untouched=434m`) come from the ticket's own reading of
`logs/blocked-resolver.log` on 2026-09-20; they are not reproduced by the suite
and are not re-probed from a build box.
