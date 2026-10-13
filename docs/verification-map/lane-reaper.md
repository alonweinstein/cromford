# Stale-lane reaper ("this build has been running since yesterday")

**What it is:** `bin/lane-reaper.sh`, an every-box cron lane (`*/10`) that kills
a `run-build.sh` lane which is still ALIVE but is long past the deadline its
`job.json` recorded, or whose checkout has been deleted under it. It writes the
verdict, releases the claim, closes the ledger row and says so once.

**Why it exists:** two BH-42 lanes ran for 21 hours out of a `/tmp` checkout that
no longer existed (#643). Nothing on the box had the job.
`bin/resume-dead-builds.sh` only looks at builds whose process is GONE (a free
key lock on a quiet dir) and `bin/jobs-watchdog.sh` judges ledger rows and
executes nothing, so a lane that is alive and useless sits between the two
holding its claim, its key lock and its build slot until a human notices.

**The contract it reads** (`bin/run-build.sh`, marker block `# >>> job json`,
plus `# >>> job json id`): `pid`, `pgid`, `script`, `started_at`, `expected_by`
(= `started_at + LANE_EXPECTED_SECS`) and, once the row is claimed, `job_id`.
On a resume that file is rewritten, so it always describes the process alive NOW.

**The order, which is the contract:**

| # | step | why in this place |
|---|---|---|
| 1 | `RESULT` ← `ABANDONED_TIMEOUT <why>`, only if absent | `run-build.sh`'s EXIT trap runs on SIGTERM and closes the ledger row against whatever RESULT says. A verdict written after the kill is a row closed against nothing. |
| 2 | SIGTERM the process group, wait `LANE_REAP_KILL_WAIT_S`, then SIGKILL | bounded both times. A pid that survives SIGKILL is logged and left: not marked, not announced, retried next tick. |
| 3 | `rm -f state/claims/<project>/<KEY>` | idempotent |
| 4 | `job_update <job_id> status=failed` | fail-open: a refusal (the lane's own trap got there first) is logged as a failure, never as "closed" |
| 5 | `touch REAPED` | "the kill landed and the claim is gone" |
| 6 | one `bin/lane-alert.sh --id lane-reaper:<project>:<KEY>` line, LAST | quotes the RESULT actually on disk, so a lane that concluded on its own inside the TERM grace keeps its own verdict and the alert says so |

A dir with OUR verdict and no `REAPED` is a kill we started and never confirmed:
the SIGKILL landed after step 2's poll gave up, or the tick itself died (reboot)
before step 5. The next tick re-enters that dir, and if the process it named is
gone or its pid has been reused, the kill HAS landed, so it runs steps 3-6 and
the dir closes out. That is the only way the "retried next tick" in step 2 can
ever finish: SIGKILL runs no EXIT trap and a reboot runs nothing, so without it
the claim stays held and nobody is told. If the lane is still breathing, the
kill is simply sent again, with the reason read back out of the verdict on disk
rather than judged afresh.

**How an operator reaches it:** the `*/10` line in every `cron/*.cron`, beside
the `resume-dead-builds.sh` line. Output goes to `logs/lane-reaper.log`, which is
empty on a healthy box. The sweep prompts (`prompts/*.md`, the results-sweep
bullet) close an `ABANDONED_TIMEOUT` dir out to the board once `REAPED` exists,
and do not relaunch it: `bin/blocked-resolver.sh` does (BH-1770).

**How to drive it:**

| what | how |
|---|---|
| the whole script, against a scratch `$HARNESS` with real backgrounded lanes | `HARNESS_TEST_SANDBOX=1 bash tests/lane-reaper-test.sh` |
| the cron line is on every box | `for f in cron/*.cron; do grep -c 'bin/lane-reaper.sh' "$f"; done` (ten `1`s) |
| the sweep knows the verdict | `grep -c ABANDONED_TIMEOUT prompts/cromford.md prompts/TEMPLATE.md prompts/TEMPLATE-GH.md` |
| on a live box | `crontab -l \| grep lane-reaper`, `tail /root/harness/logs/lane-reaper.log`, and after a reap: `<dir>/RESULT`, `<dir>/REAPED`, `logs/ALERTS.log`, `state/alerts/lane-reaper:<project>:<KEY>.json` |

**Knobs** (environment → `flags/scheduler.conf` → the default, through
`bin/lib/scheduler-conf.sh`, documented in `docs/SCHEDULER.md`):

| knob | default | what it does |
|---|---|---|
| `LANE_REAP_GRACE_SECS` | 1800 | how long past `expected_by` before we act, for a legacy dir with no `started_at` |

**The deadline is per build lane (BH-1770).** A dir whose `job.json` carries a
real `started_at` is late once it has lived `LANE_REAP_DEADLINE_SECS`, a registry
knob on this lane (`catalog/lanes.d/lane-reaper.json`, default 16200 = the old
4h30m, clamped to 1800..172800) resolved through `lane_knob` with the build's
project: `lane.lane-reaper.<project>.lane_reap_deadline_secs`, then
`lane.lane-reaper.lane_reap_deadline_secs`, then the env, then the default. Set
one project's with `bin/harness-ctl.sh set lane-reaper LANE_REAP_DEADLINE_SECS
<secs> <project>`. A box that had tuned `LANE_EXPECTED_SECS` /
`LANE_REAP_GRACE_SECS` keeps their sum as the env tier. The RESULT and the
alert name the deadline that applied.

**Who relaunches a reaped run: `bin/blocked-resolver.sh`, and only it**
(the operator, 2026-09-24). `br_from_builds` offers a REAPED `ABANDONED_TIMEOUT` record
as `abandoned-timeout` (at once when the sweep has COMMENTED it, else after the
90-minute floor), which rebuilds fresh on the capped ladder and ends ABANDONED
with one alert when the ladder is spent; a relaunch that is itself reaped spends
the next rebuild. The sweep SOPs close the dir out and are told not to relaunch.

| what | how |
|---|---|
| the per-lane deadline, the legacy carry-over and the CLI row | `HARNESS_TEST_SANDBOX=1 bash tests/lane-reaper.bh-1770-test.sh` |
| the resolver's relaunch and its cap | `HARNESS_TEST_SANDBOX=1 bash tests/blocked-resolver.bh-1770-test.sh` |
| the sweep does not relaunch | `HARNESS_TEST_SANDBOX=1 bash tests/prompt-reap-relaunch.bh-1770-test.sh` |
| `LANE_REAP_MAX` | 20 | reaps per tick; over the cap a dir is DEFERRED (no marker, re-offered next tick), never dropped |
| `LANE_REAP_KILL_WAIT_S` | 30 | TERM→KILL wait. A signal-delivery seam, environment only, lowered by the suite. |

Kill switch: `flags/lane-reaper-off`, answered before the lock and before any
write. Self-overlap: `flock -n` on `locks/lane-reaper.lock`; a tick that finds it
held exits 0 and waits for nobody.

**What must never regress:**

- **A dead pid is not ours.** That is `bin/resume-dead-builds.sh`'s lane, and the
  skip is silent: every finished build on a box has a dead pid, and a line each
  per ten minutes would bury the findings that matter.
- **Nothing is signalled on a guess.** The live process must have a
  `run-build.sh` command line carrying THIS key as a whole argument (`BH-64` is
  not `BH-648`), and its live process group must equal the recorded `pgid`.
  Group 0/1 and the reaper's own group are never signalled.
- **Absent is not zero.** A missing or null `pid`/`expected_by` is unknown, gets
  one log line, and is never treated as "due in 1970".
- **We never overwrite somebody else's verdict.** A dir with a RESULT that is not
  `ABANDONED_TIMEOUT` is the sweep's, not ours. Our own unfinished reap (verdict
  written, kill unconfirmed) is the one case we re-enter.
- **No reap is left half-done.** Re-entering our own verdict finishes the job
  whether the process is dead, reused, or still up. A dir that can never leave
  "verdict, no REAPED" is a claim held for nothing and a sweep waiting on a tick
  that will not come, which is exactly the silence this lane exists to end.
  The one exception is a pid that is still a live `run-build.sh` of the SAME
  key in a different process group than the one recorded (BH-1142): that lane
  is running, so it is unsignalable, and the dir stays "verdict, no REAPED"
  with its claim held and one `process group ... not reaped` log line per tick
  until the pid is gone.
- **Exactly one alert per reap, written last.** "Announced" implies "reaped";
  `REAPED` implies the pid and the claim are gone.
- **`pool-*` and `fly-*` dirs are skipped outright**, and the hub is a no-op by
  construction: its build dirs were ingested from other boxes, so their pids are
  dead here or belong to something unrelated, and both checks refuse them.
