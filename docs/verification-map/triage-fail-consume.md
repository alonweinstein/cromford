# A triage session that fails every time (the attempt cap)

**What it is:** the brake on a lane whose triage session dies on every attempt.
A tick only ever consumed the pending board fingerprint on rc=0, so a failing
session left `state/<project>.gate.pending` in place, the next gate diffed the
same board against the same old `gate.json`, answered `RUN board-changed` again,
and bought the identical failure ten minutes later. project-5 billed **1,168
rc≠0 triage rows in one day on ONE fingerprint** (2026-09-17 `logs/cost.csv`).

Now consecutive rc≠0 exits are counted per fingerprint, and at the cap the tick
consumes the fingerprint anyway, drops the counter and alerts once. The next
tick's gate answers `SKIP no-change` and spends nothing.

**How an operator reaches it:** not a screen. It is the cron line
`run-triage.sh <project>` (`cron/<box>.cron`, per-project offsets from
`fleet.conf`) taking its single-session path — the shard dispatcher consumes at
dispatch and re-arms per key, and never reaches this code.

| thing | where |
|---|---|
| the cap | `TRIAGE_FAIL_CONSUME_AFTER` in `env/global.env` — default **3**, `1` = consume on the first failure, `0` = never consume on failure (the behaviour this replaced). Blank or non-numeric reads as 3 |
| the counter | `state/<project>.gate.fail` — two lines: the 16-char sha256 of `state/<project>.gate.pending` (or `none` when the tick wrote no pending file), then the consecutive-failure count |
| the code | `rt_gate_fail_consume` in `bin/lib/rt/gate.sh`, called from the `else` arm in `bin/lib/rt/launch.sh` |
| below the cap | `logs/<project>.log`: `triage rc=N: fingerprint <sha> NOT consumed, failed attempt n/cap` |
| at the cap | `logs/<project>.log`: `triage rc=N: fingerprint <sha> consumed after n failed attempts — …` |
| the alert | `bin/lane-alert.sh --id triage-fail-consume:<project> --severity warn` (batched digest, deduped while the condition is open) |
| the fallback | `logs/ALERTS.log`: `… consumed after n failed attempts and bin/lane-alert.sh did not run` |

**How to drive it:**

| what | how |
|---|---|
| the whole lane, end to end | `HARNESS_TEST_SANDBOX=1 bash tests/triage-fail-consume.bh-1021-test.sh` (drives the real `bin/run-triage.sh` in a scratch harness with an agent stub that exits nonzero) |
| A — three failures consume the fingerprint, the fourth tick buys nothing | section A of that suite |
| B — rc=0 still consumes, a success clears the counter, a new fingerprint restarts it | section B |
| C — the knob: `0` never consumes, garbage falls back to 3 | section C |
| D — the no-pending shape (`daily-sweep`/`forced`) stamps the sweep clock at the cap | section D |
| E — an unrunnable `lane-alert.sh` still leaves the consume and one raw ALERTS line | section E |

**On a live box:**

- `grep 'failed attempt' logs/<project>.log` — the attempts that were counted;
  the `consumed after N failed attempts` line that follows is the brake firing,
  and the next tick then logs `rc=skip :: gate no-change`.
- `cat state/<project>.gate.fail` — present only between the first failure and
  the cap. Absent afterwards, and absent on a healthy lane.
- turn it off on one box: `TRIAGE_FAIL_CONSUME_AFTER=0` in `env/global.env`.

**What must never regress:**

- **A failure is never recorded as a success.** The consume is borrowed from the
  success path; the log line and the alert both carry the real `rc`, and no
  success counter is bumped.
- **The consume is written before the record.** Order at the cap: consume →
  drop the counter → log → alert. An alert that cannot be sent still leaves the
  consume plus one `logs/ALERTS.log` line, so "consumed with nothing recorded"
  cannot happen.
- **A new board state gets fresh attempts.** The count is keyed on the pending
  fingerprint's sha; a different sha restarts at 1 rather than inheriting an
  older board's failures.
- **An unreadable knob never keeps paying.** Blank/garbage reads as 3; only an
  explicit `0` disables the cap.
- **The shard path is untouched.** `bin/lib/rt/shards.sh` consumes at dispatch
  and re-arms per key; it exits the tick before `rt_launch` and never reads
  `gate.fail`.
- **The consumed fingerprint is not a lost ticket.** The tickets it carried are
  re-offered as soon as the board changes again, or on the daily sweep
  (`FULL_SWEEP_SECS`).
