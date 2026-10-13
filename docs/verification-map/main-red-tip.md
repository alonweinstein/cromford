# Main-red tip arm (the first red on main's tip fires)

**What it is:** a second arm on `bin/main-red-detector.sh` that declares main red
on the FIRST red completed run of a required workflow on main's tip, once that
run is old enough not to be a re-run still in flight (BH-629.4).

Why it is needed: the existing arm applies `MAIN_RED_STREAK` (default 2) to a
stream whose only producer is a push to main, and in this harness a push to main
is a merge. So the second red run the threshold waits for can only arrive from
the very merge the red is meant to prevent — the detector cannot reach its own
firing condition. On 2026-09-17 that was the 7.5-hour silence while every open PR
sat red (the same incident [pr-dep-gate.md](pr-dep-gate.md) describes from the
merge side). The 2-run streak is deliberate flake tolerance, so this is an
ADDITIONAL arm, never a lower threshold.

**Status as of BH-629.4 (BH-880):** the arm is in `bin/main-red-detector.sh`,
armed by default. The detector, its flag and the conductor's freeze on that flag
have existed since 2026-09-15 and are unchanged; what BH-629.4 added is the arm
itself, the `reason=` line on the flag, and `tests/main-red-tip-red-test.sh`. The
two knobs below are read by the detector: `MAIN_RED_TIP_RED=0` puts it back to
the streak-only decision, byte for byte.

**How an operator reaches it:** no UI. `bin/main-red-detector.sh` runs from
`cron/hub.cron` and the conductor tick runs it too. Two knobs in
`env/global.env`: `MAIN_RED_TIP_RED` (default 1, `0` = only the streak arm
fires, which is byte-for-byte the pre-BH-629 decision) and
`MAIN_RED_TIP_MIN_AGE_MIN` (default 15, the minutes the red run on the tip must
have stood).

**How to drive it:**

| what | how |
|---|---|
| the tip arm: one red run on the tip, aged past the threshold, fires the flag and one alert (BH-629.4) | `bash tests/main-red-tip-red-test.sh` |
| the negatives: too young, not on the tip, a skipped workflow, a cancelled or in-progress newest run, an unreadable runs list, `MAIN_RED_TIP_RED=0` (BH-629.4) | same suite, each its own named case |
| a newer `cancelled` or `skipped` run of the same workflow (a re-run somebody stopped) holds the arm | same suite, case N4 |
| an unparseable `created_at` disarms the arm instead of reading as infinitely old | same suite, case N7 |
| the streak arm, unchanged | `bash tests/main-red-detector-test.sh` (cases 1, 5b and 12 pass `MAIN_RED_TIP_RED=0` so they test the streak path in isolation) |

**Files it writes on a live box:**

- `flags/main-red-<owner>-<repo>` — the same flag the streak arm writes, plus one
  `reason=tip` line (`reason=streak` from the streak arm, `reason=burst` from the
  back-walk, `reason=held-overrun` when a re-test hold ran past its bound) so a
  reader can tell which arm fired.
  `sha=`, `since=`, `workflow=` and `job=` keep their meaning:
  `since=` stays the first detection of the episode, so adding an arm never
  rewrites how long main has been red.
- `ledgers` row `kind=main_red_runs`, `key=<owner>/<repo>` (BH-1927, in the
  coordination DB, not a file) — `status="total=<n> newest=<created_at>"`, the
  newest runs page this detector has accepted for that repo. A page older than
  it decides nothing. Read with `bin/jobs-client.sh ledger-get main_red_runs
  <owner>/<repo>`; `--explain` never writes it.
- `state/main-red/<owner>-<repo>.verdict` (BH-1451) — what this tick decided,
  including that it decided nothing: `decision=red|green|held|none`, `reason=`
  (the arm that fired — `streak` / `tip` / `burst` / `held-overrun` — or
  `re-test` / `invisible` / `no-runs` / `no-required` / `below-streak`, or
  since BH-1927 `stale-page` — GitHub answered a runs page older than the
  newest one this detector has accepted — and `unconfirmed` — a first red call
  the confirming re-read did not repeat),
  `sha=`, `at=`. `held` is the streak arm's re-test hold
  (BH-1281): the detector looked and declined to raise, and its `sha=` names the
  run in flight it is waiting on rather than a run it judged. Written on EVERY
  exit path of the per-repo loop and by no
  `--explain` run. A last-write cell keyed on the slug — nothing dedupes on it.
  Its only reader is `bin/main-red-pr-pair.sh`, which raises a suspected freeze
  ONLY against `decision=none` and reads an absent file as "do not act"; see
  [main-red-pr-pair.md](main-red-pr-pair.md). Driven by section V of
  `tests/main-red-pair-suspected.bh-1451-test.sh`.
- `logs/main-red.log` — the detector's own line per project per tick.
- `logs/ALERTS.log` — through `bin/lane-alert.sh`, one critical alert per
  episode.

**What acts on the flag (BH-3696):** the `main-red-bisect` hub lane. Its
detect function (`mrb_detect_episodes`, `bin/lib/mrb-detect.sh`) turns a red
this detector reports into an episode, and the lane bisects that episode to the
merge that turned main red and hands it to the act functions. This detector
still owns the flag; the lane never writes or clears it. See
[main-red-bisect.md](main-red-bisect.md).

**What must never regress:**

- **The streak arm's flake tolerance stays.** Two reds still mean red; the tip
  arm is additional, and the existing streak cases keep asserting exactly what
  they asserted before.
- **An unreadable or empty runs list decides nothing** and leaves an existing
  flag alone. Absence of data is not green.
- **Flag first, then alert.** An alert that dies costs one flag line, never one
  alert per tick.
- **The alert names the failing JOB, not just the workflow.** "The decisions job
  failed" sends a reader to the test; "Harness CI is red" sends them to a
  four-job run.
- **`MAIN_RED_SKIP_RE` workflows never freeze the fleet.** A perma-red e2e,
  nightly, smoke, publish or deploy workflow is perma-red's business. Since
  BH-3769 the regex matches a workflow's name OR its path (project-3's "Production
  QA" lives in `.github/workflows/e2e-prod.yml`), and it resolves from the
  settings row `lane.main-red-pr-pair.main_red_skip_re` first, then
  `MAIN_RED_SKIP_RE` in env, then the default. A value that does not compile
  falls back to the default with one warn; it never disarms the detector.
- **A `schedule` run is never freeze evidence (BH-3769).** It is out of every
  arm: no streak, no tip, no burst, and an in-flight one holds nothing. A
  scheduled red of a required workflow sends one `--severity warn` per run id
  (ledger `kind=main_red_sched`) and the log gets a `SCHED:` line.

**What usually lies:**

- A scheduled-run warn says nothing about main's code. It tests the
  schedule's target (prod, a vendor API, a report).
- A scheduled GREEN clears nothing and breaks no streak: it is not evidence
  either way. A freeze raised by a scheduled red before BH-3769 is cleared by
  the next green push run or the operator clear, not by the schedule.
