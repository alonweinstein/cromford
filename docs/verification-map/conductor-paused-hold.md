# The conductor's PAUSED hold (BH-1201.1)

**What it is:** the merge conductor's two AGE pagers — the stuck detector
(`mc_stuck_check`, past the state's TTL) and the budget check's paging arm
(`mc_budget_check`, "Nm in READY/WAIT_CI/a park") — stop sending pages while the
lane is switched off, and send them once when it is switched back on. A held page
is a row in `conductor_held_pages` (the BH-1201.0 contract), not a dropped one:
the marker and the `alerted` mark that would have SPENT the page are deliberately
not written, so the PR still owes exactly one page.

Every other `mc_alert` call site pages in every mode. The hold is about this
lane's own age noise, not about facts from the world.

**UI route (BH-3158):** `/merge-queue`, reached from the Kanban header's MERGE
QUEUE button. Its HELD PAGES section lists the held pages read-only. Beyond
that, an operator reads the conductor log, `logs/ALERTS.log`, and the two settings rows.

**The primary lane:** `bin/merge-conductor.sh` (`cron/hub.cron`, \*/5). Its
`MODE` (line ~218) becomes the exported `MC_MODE`; `mc_hold_tick_begin` runs in
the main process immediately before the project fan-out, and `mc_hold_tick_end`
immediately before `hb_done merge-conductor`. Both calls are `command -v`-guarded
so a box mid-sync with an older `bin/lib/mc/` runs as it did.

## How you reach it

There is no screen. Three surfaces:

1. `logs/merge-conductor.log` on the hub — one line per tick while paused:
   `mode=kill-switch: 3 PRs would have paged (STUCK 2, HEAD_MOVED 0, BLOCKED_HUMAN 0, RED_TWICE 0, WAIT_CI 2, READY 1) — suppressed`,
   plus one `... — HELD (mode=kill-switch), not paged: <url>` per row as it is held.
   This line is about THIS TICK: how many pages the tick itself suppressed. On the
   second and every later tick of a long pause it is `0`, because every aged PR is
   already held.
2. `bin/harness-ctl.sh show merge-conductor` — the two published settings rows,
   `merge-conductor.mode` and `merge-conductor.held_pages` (`<total> <STATE=n ...>`,
   or the word `0`). They are published on EVERY tick, including `merge`, so a
   reader never sits on a row more than one tick stale. `held_pages` and the
   reminder's "is holding N pages" are about the set that IS held — the worker's
   own list read at tick begin, minus what the flush released, plus what this tick
   added — not about the tick's new holds, so a week-old pause reports its whole
   backlog rather than the 0 its counters would say.
3. `logs/ALERTS.log` — what should NOT be there: zero
   `[merge-conductor] conductor: ... STUCK:` or `Nm in <state>` lines while the
   mode is `kill-switch`/`observe`, and at most one
   `conductor PAUSED ...` line per `MC_HOLD_REMINDER_S` (non-critical).

## Preconditions

- `MC_MODE` is set by the conductor from its flags:
  `flags/automerge-disabled` → `kill-switch`; neither
  `flags/merge-conductor-actions` nor `flags/merge-conductor-merge` (or
  `flags/merge-conductor-observe`) → `observe`. Those two words hold; `merge`
  and `actions` do not.
- The jobs worker must answer `/api/conductor/held` for a row to be held at all.
  With the worker down the conductor logs
  `held pages unreadable this tick (rc=1) — nothing flushed, nothing suppressed twice`
  and `... held_page_put rc=1 — NOT counted as held, the page is still owed`; it
  never records a hold it could not write.
- `MC_FLUSH_MAX` (default 10) and `MC_HOLD_REMINDER_S` (default 21600) resolve
  through `lane_knob merge-conductor …`: settings row → env → registry default.

## How it is driven

```bash
HARNESS_TEST_SANDBOX=1 bash tests/conductor-hold.bh-1201-test.sh
```

Ten blocks against a scratch `$HARNESS` with the real `bin/jobs-client.sh`,
`bin/lib/lane-gate.sh` and a rendered lane registry behind a fake `curl`: no
`MC_MODE` still pages (blocks 1, 8), `kill-switch` holds the STUCK and the budget
page without spending either mark (2, 3), `merge` flushes oldest-first capped with
the moved row released rather than paged, and neither the flushed park nor the
flushed STUCK row pages a second time in that same tick (4, 5), the summary line,
the two settings rows and the held count on a tick that holds nothing new (6), the
reminder's four stamp cases including a settings-row `MC_HOLD_REMINDER_S` (7), the
worker being down (9), and a `mark` read back from the API reduced to a leaf name
before it is used as a filename (10).

The one-line reproduction of the defect this closed, against a tree without the
fix (it exits 1 there and 0 with it):

```bash
T=$(mktemp -d) && mkdir -p $T/h/bin $T/h/logs \
  && printf '#!/bin/bash\necho "$*" >> %s/calls\n' "$T" > $T/h/bin/lane-alert.sh \
  && chmod +x $T/h/bin/lane-alert.sh \
  && HARNESS=$T/h MC_MODE=kill-switch bash -c '. bin/lib/merge-conductor-lib.sh; mc_init;
       NOW=$(date +%s); mc_now(){ echo $NOW; };
       mc_stuck_check example-org/x#41 WAIT_CI $((NOW-5400)) aaaaaaaa1111 \
         https://github.com/example-org/x/pull/41 "checks pending"' \
  && test ! -s $T/calls
```

## What the regression suites pin beside it

`tests/mc/classify-test.sh` (the stuck detector with no mode set),
`tests/merge-conductor-state-notes.bh-979-test.sh` (state notes still log and
never hold), `tests/merge-conductor-test.sh` (the whole tick, whose jobs-client
stub lacks the held verbs — which is what proves the `command -v` guards),
`tests/lanes-registry-test.sh` (both knobs registered and read where they say).
