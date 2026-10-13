# Alert-triage STEP 0 — retire what a clock and a REST read can settle

**What it is:** the deterministic pass `bin/alert-triage.sh` runs over the
tick's collected alert lines BEFORE the family brake, the session cap and any
`agent-call.sh`. It retires three classes of line for $0 — lines past an age
ceiling, `[orchestrator/merge-conductor]` per-PR state notes past a shorter one,
and lines whose every referenced pull request reads MERGED or CLOSED on a fresh
REST lookup — and archives every one of them with the reason it went. Alongside
it, the merge conductor stopped emitting transient per-PR state transitions as
`fleet_alert` beats at all, and the family key those alerts are grouped by now
folds the two tokens that made every PR its own family.

**Rule 3 is an ALLOWLIST, not a denylist (round 3).** "Every PR this line names
is MERGED/CLOSED" only means "the condition is moot" for an alert whose condition
presumes an OPEN pr. For an alert raised *because* the PR merged, the same
reading CONFIRMS it — and rule 3 was archiving the fleet's post-merge criticals
at age 0, for $0, before any human saw them. Round 2 fixed the four
conductor/resolver shapes then known; measured on the hub's live 1010-line spool
(2026-09-20) with every read answering MERGED, the class was still open through
three other lanes: `PROD QA FAILED after merge …` (`bin/postmerge-qa.sh`), `PR #N
shipped migration SQL — confirm it is applied to prod` (`bin/check-migration-prs.sh`,
matched only through the beat's `akey`), the conductor's own READY "mergify queue
not answering … merged directly (degraded)" (`mc_queue_inactive_alert`, a
NON-terminal state word) and `hb-alert` relays of a merged-PR line.

So the default is now KEEP, and rule 3 judges only these five shapes, each
verified in the live spool:

| # | shape | source |
|---|-------|--------|
| 1 | `conductor: <key> <STATE> — …` with a NON-terminal state word | `mc_alert` |
| 2 | `[pipeline-health] <url> … OPEN and CLEAN … has not landed it` | `bin/pipeline-health.sh` |
| 3 | `Merge queue: #N …` | mq-conflict / mq-headbound / mq-hb-lander |
| 4 | `RESPONDER: …` carrying the `OPEN/<STATUS>` pair it read off a PR | the responder |
| 5 | `[pr-url-reconcile] <url> owes a verdict and nothing can produce one` | `bin/pr-url-reconcile.sh:342` |

**An entry is a SHAPE, never a lane tag or a word (round 4).** Two of the five
were wider than the sentence above them. Entry 5 was the `[pr-url-reconcile]`
TAG, and that lane raises three shapes: `:492` pages *because* the only PR on the
branch **is CLOSED without merging** ("reopen it, or open a new one") and `:527`
pages because a RECORD ON DISK is mislinked — a condition no PR state can moot.
Both read terminal and were archived `NOISE-STALE` at age 0, which is the exact
class this allowlist exists to stop. Entry 4 was the bare word `OPEN` anywhere in
a line `bin/watchdog-responder.sh:191` has the MODEL write as free prose, so
"PR … was CLOSED without merging and the ticket is still OPEN on the board"
matched on the ticket's status and retired. Both are now the shape: the one
reconcile sentence that waits on a verdict, and the `OPEN/CLEAN` · `OPEN/BLOCKED`
status pair the responder copies out of a PR read. `post_terminal()` gained
`CLOSED without merging` as the second lock, because one responder line can
carry an `OPEN/CLEAN` pair and a closed-PR premise at once.

Everything else keeps its line and buys a session: a miss costs one session, and
what it would otherwise cost is a post-merge critical nobody reads. `post_terminal()`
stays as the second lock for a line that IS allowlisted and still says the merge
has happened (`after merge`, `merged at/directly`, `MERGED PR`, `shipped migration`,
plus the four round-2 shapes). And the beat's `akey` is cut out of the text before
references are read — a routing key is not something the alert says.

**Measured cost of the ROUND-3 narrowing** (real `bin/triage-spool-retire.sh`, hub's live
1010-line spool, both age rules disabled, every read MERGED): 530 → 522 retired.
Round 4's further narrowing (entry 5 to the one reconcile sentence, entry 4 to the
`OPEN/<STATUS>` pair, `CLOSED without merging` in `post_terminal()`) was **not**
re-measured against a live spool — the lane is paused, so there is no current one to
measure. It can only move that number DOWN, bounded by the reconcile and responder
lines in the spool, and every line it stops retiring leaves on the 24h clock as
`EXPIRED-AGE` instead of at age 0 as noise.
The 8 that now survive are exactly the class — 1 `prodqa`, 2 `migration`, 1
`hb-alert` merged-PR relay, and 4 `[orchestrator/blocked-resolver]` lines that were
being judged on an ISSUE number the resolver quotes (`example-org/cromford#788`).

**Why:** measured on the hub 2026-09-19 15:50Z, `state/alert-triage-deferred.tsv`
held 2019 lines / 1136 families and had grown for 2.5 days (median spooled age
24.5h, max 55h, 1038 over 24h) because arrivals beat the
`TRIAGE_MAX_FAMILIES=4` per-tick cap. 1033 of those lines were merge-conductor
per-PR state notes, each its own family — so each one bought the STRONG
investigator. Of what a session then looked at, 93% was noise it confirmed in
its own step 0, at 60K-900K input tokens a time (one session read 900,174 input
tokens for one alert line).

**What actually made every PR its own family, measured** (the real
`bin/alert_family.py` over the hub's 434 conductor spool lines, 2026-09-19): not
the branch slug — folding branches alone moved families per state 59→59
(HEAD_MOVED), 29→29 (BLOCKED_HUMAN), 12→12 (RED_TWICE), 30→28 (STACKED_WAIT).
It is the status parenthetical `(verdict=APPROVE ci=red mergeState=BLOCKED
mode=merge)`, a fresh combination per PR. `alert_family.fold_volatile()` folds
BOTH, on the family INPUT and never on the text a human reads: 59→14, 29→13,
12→8, 30→5, NEEDS_REBASE 10→3, WAIT_CI 17→14, READY 4→2 — 171 conductor
families to 69, and 602 to 500 across the whole spool. `identifiers()` gained
the branch token in the same change, so `row_key` (which decides whether an
alert gets its own ROW) still separates two incidents on two branches.

**How an operator reaches it:** no UI.
- `logs/alert-triage.log` — one `triage pass: STEP 0 aged=N condstate=N stale=N
  kept=N lookups=N unchecked=N archive=<path>` line per tick (`unchecked=` is
  how many distinct PRs the lookup cap never reached), STEP 0's stderr, and
  `in_toks=` beside every session's `handled=/escalated=/noise=` summary.
  `in_toks=` counts only rows whose project/stage columns are `alert-triage` /
  `triage`: `logs/cost.csv` is one ledger for the whole box and the hub
  interleaves medic, responder and review rows into any session's window.
- `logs/ALERTS.log` — one `[alert-triage] SPOOL RETIREMENT: …` line per UTC day,
  the first time that day retires anything. Deduped by
  `flags/alerted-spoolretire-<YYYYMMDD>`.
- `state/alert-triage-expired-<YYYYMMDD>.tsv` — the archive, append-only:
  `<retired-at ISO>` · `<reason>` · `<age-seconds>` · the original collector line.
  Reason is column 2 and is one of `EXPIRED-AGE`, `EXPIRED-CONDSTATE`,
  `NOISE-STALE`. (The one hand-written predecessor of this file, the
  orchestrator's `state/alert-triage-expired-20260919.tsv`, has the reason in
  column **1** and no timestamp column — read that one with `cut -f1`.)
- `state/triage-prstate.json` — `{"owner/repo#n": {"state", "at"}}`, the PR
  readings this lane has already paid for, reused for `TRIAGE_PRSTATE_TTL_H`
  counted from `at`, which is when that reading was BOUGHT and never re-stamped
  by a later tick's write. Deleting it costs lookups, never correctness.
- `logs/merge-conductor.log` — `<key> state note (not an alert): <STATE> — …`
  for every transition that used to be a beat.

**Rule 1 is the machinery wait, never a park (round 4).** `mc_budget` is 0 for
`BLOCKED_HUMAN` and `RED_TWICE`, so a park the resolver does not own pages
`conductor: <key> BLOCKED_HUMAN — 0m in BLOCKED_HUMAN: <why>` **with
`--critical`** on its first tick — the budget-note shape, raised by the arm of
`mc_budget_check` that exists to page a person. Those two states are excluded by
name from rule 1 and age out on the 24h ceiling like any other alert.

**Why the 6h conductor-note ceiling is safe** (and it is NOT "the note re-pages"):
`mc_budget_check` marks `<STATE>@<since>` and pages once per (state, entry) for
non-parks, once per UTC day for parks — a WAIT_CI or READY note is not re-sent
while the condition holds. What re-raises the CONDITION is `mc_stuck_check`, once
per (PR, state, head) on a 90m/20m TTL, re-armed on every new head. A STUCK line
is deliberately excluded from rule 1 and lives out the full 24h ceiling, so the
backstop survives the note.

**Primary lanes / scripts:**
- `bin/triage-spool-retire.sh` — the whole rule, and the only thing that decides
  a retirement. Rewrites the tick's workfile in place, prints one summary line.
- `bin/alert-triage.sh` — calls it under the lane's own flock, logs the counts,
  makes the daily declaration, and exports `CONTEXT_KILL_TOKENS` when
  `TRIAGE_CONTEXT_KILL_TOKENS` is set.
- `bin/gh-pr-state.sh` — the PR read: App installation token, REST, never
  GraphQL. rc 0 OPEN/MERGED/CLOSED, rc 44 absent, rc 75 unverifiable.
- `bin/lib/mc/log.sh` (behind the `bin/lib/merge-conductor-lib.sh` shim) —
  `mc_alert`'s `statenote` argument and
  `mc_budget_check`'s park-vs-transient routing. It does NOT touch the alert
  text: the branch and the status a person acts on are sent verbatim.
- `bin/alert_family.py` — `fold_volatile()`, called by `family()` (so every lane
  that keys on it groups the same way) and paired in `identifiers()`.

**Knobs (env; the file is the cache, the knob is the value):**
| knob | default | what it does |
| --- | --- | --- |
| `TRIAGE_SPOOL_MAX_AGE_H` | 24 | hours before any line is retired |
| `TRIAGE_CONDSTATE_MAX_AGE_H` | 6 | hours for a merge-conductor state note |
| `TRIAGE_PRSTATE_MAX_LOOKUPS` | 40 | REST reads per tick; past it, lines are kept and counted in `unchecked=` |
| `TRIAGE_PRSTATE_TTL_H` | 6 | hours a persisted PR reading is reused, counted from when it was read (a cached PR costs no lookup, so the next tick's budget reaches the PRs the cap starved) |
| `TRIAGE_PRSTATE_TIMEOUT_S` | 15 | seconds one `gh-pr-state.sh` read may take before it is UNKNOWN |
| `TRIAGE_PRSTATE_DEADLINE_S` | 120 | seconds the whole lookup pass may take; past it every remaining reference is `unchecked=` and its lines are kept |
| `TRIAGE_CONTEXT_KILL_TOKENS` | unset | per-session ceiling override; unset means `catalog/context-budgets.json` decides |
| `MC_STATE_NOTES_ALERT` | 0 | `1` restores per-PR state transitions as alerts |
| `flags/triage-spool-age-off` | absent | kill switch: keep every line, spend no lookups |

**Every doubt keeps the line.** A line with no readable epoch, one OPEN
reference among several, a read that answers 75 or 44, a read that outlasts
`TRIAGE_PRSTATE_TIMEOUT_S`, the lookup budget or the per-tick deadline
running out, an archive that could not be written, the kill switch — all of
them leave the line in the tick exactly as it arrived. A retirement may only
follow a positive reading of every reference it rests on, because the cost of
being wrong here is an alert nobody ever sees.

**Non-destructive only:** `bin/triage-spool-retire.sh` writes its own workfile
and the dated archive and nothing else. It makes GitHub reads and no writes.

**Where this overlaps #1039:** #1039 ("Volume caps for the three unpriced hub
LLM lanes") **landed first** (PR #1149) and did **not** take `context_kill_tokens`
— it shipped the per-day lane caps and `cliff_refuse` and left this field at
2,000,000 — so the 400,000 here is this ticket's only change to the number and
there is nothing to reconcile. #1039 is still why the hub currently runs
`TRIAGE_MAX_FAMILIES=0`; un-pausing the lane stays that ticket's call, and
neither number is a deploy. This page's 400,000 is the number measured for the
workload that remains AFTER STEP 0.

**Drive it:** `tests/alert-triage-spool-age.bh-979-test.sh` runs the real lane
end to end with `agent-call.sh`, `gh-pr-state.sh`, ssh, flock and timeout
stubbed; `tests/merge-conductor-state-notes.bh-979-test.sh` drives the real
`mc_alert`/`mc_budget_check` and the real `bin/alert_family.py`.
