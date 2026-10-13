# The triage tick lock (and who is holding it)

**What it is:** the per-project flock every triage tick takes before it spends
anything — `locks/<project>.lock`, opened on **fd 9** at `bin/run-triage.sh`
(`# >>> tick lock holder`). One level down, `bin/triage-shard.sh` holds the
per-ticket key lock `locks/triage-key-<project>-<KEY>.lock` on **fd 8**. Both are
DEDUPE, never a queue: held means somebody else owns this work right now, so the
tick says so and exits 0.

An flock lives on the open file description, so **every child that inherits the
descriptor keeps the lock alive.** That is BH-651: the session the tick launches
is told by the SOP to run `setsid run-build.sh ... &`, and that build inherited
fd 9. On 2026-09-17 pid 8911 (`run-build.sh cromford 421 BH-421`) was the
only holder of `locks/cromford.lock` 43 minutes after its tick had exited,
and every tick from 16:13Z to 16:48Z answered "previous run still active,
skipping" while nothing was running. `bin/lib/lock-hygiene.sh` is the fix:
`lock_run_unheld` runs a child with fds 8 and 9 closed, and every spawn site in
both scripts goes through it.

**How an operator reaches it:** it is not a screen. It is the cron line
`run-triage.sh <project>` (`cron/<box>.cron`, per-project offsets from
`fleet.conf`), plus the same script run by `bin/wake-loop.sh` on an event wake.

| thing | where |
|---|---|
| tick lock | `locks/<project>.lock`, fd 9, `bin/run-triage.sh` |
| shard key lock | `locks/triage-key-<project>-<KEY>.lock`, fd 8, `bin/triage-shard.sh` |
| the helper both use | `bin/lib/lock-hygiene.sh` — `lock_run_unheld`, `lock_holders` |
| skip line | `logs/<project>.log`: `previous run still active (holder pid=N age=Ns cmd=...), skipping` — `(holder unknown)` when the scan found nothing |
| leak alert | `bin/lane-alert.sh --id triage-lock-leak-<project> --severity warn` (batched digest, deduped while the condition is open) |
| resolve marker | `state/triage-lock-leak-<project>` — written when the alert fires, removed by the next tick that acquires the lock, which is also the only tick that sends the `--resolve` |

**How to drive it:**

| what | how |
|---|---|
| the whole lane, end to end | `bash tests/triage-lock-inherit-test.sh` |
| §1 the ticket itself: a single session detaches a long-lived build, the tick exits, the NEXT tick still runs | section 1 of that suite |
| §2 the same for a shard (fd 8 as well as fd 9) | section 2 |
| §3/§4 the classifier: a foreign holder alerts, a `run-triage.sh` holder does not | sections 3 and 4 |
| §5 the resolve on the next acquire | section 5 |
| the shard fork's own lock behaviour | `bash tests/triage-shards-test.sh` (case 1 asserts a running shard does not hold the tick lock) |
| the helper on its own | `bash -c '. bin/lib/lock-hygiene.sh; exec 9>/tmp/l.lock; flock -n 9; lock_run_unheld bash -c "readlink /proc/self/fd/9 \|\| echo closed"'` prints `closed` |

**On a live box:**

- `grep 'previous run still active' logs/<project>.log` — a run of these with the
  same `pid=` across ticks is a leak, and the pid is the thing to kill.
- force the condition: `( exec 9>locks/<project>.lock; flock 9; sleep 120 ) &`
  then wait for the next tick. The skip line names that sleep, `logs/ALERTS.log`
  gains one `triage-lock-leak-<project>` line, and the tick after the sleeper
  exits sends the resolve and removes `state/triage-lock-leak-<project>`.

**What must never regress:**

- **No child of a tick holds the tick's lock.** Every spawn site reachable
  after the `exec 9>` goes through `lock_run_unheld` or `lock_spawn_unheld`:
  the shard fork in `bin/lib/rt/shards.sh` and the single-session agent call in
  `bin/lib/rt/launch.sh` (both stages of the tick `bin/run-triage.sh` drives), the
  agent call in `bin/triage-shard.sh`, and the two detached children of
  `bin/orphan-reconcile.sh` (the reconcile-enqueued `run-build.sh` and
  `pr-owner-sweep.sh`), which runs inside the tick and also holds its own fd 8.
  A new fork added to any of these is added to the helper's argument list, not
  given its own `9>&-`. Two things sit outside the helper on purpose:
  `bin/run-build.sh` closes fds 7, 8 and 9 at its own startup (#474), which is
  the belt-and-braces for any launcher this list has not caught up with; and
  the `bin/jobs-client.sh` heartbeat subshell inherits fd 9 for at most
  `JOBS_BEAT_SECS` past tick exit, which the holder scan reads as routine
  because its argv is the tick's own `run-triage.sh`.
- **The caller's own fd survives.** The closing happens in a subshell, so the
  tick keeps its lock and the shard keeps its key while the child runs without
  either — otherwise the dedupe itself is gone.
- **`RC=$?` still reads the agent's exit code.** `lock_run_unheld` execs the
  command, so the wrapper is invisible to the caller's rc handling.
- **A missing lib fails safe.** Both scripts define a fallback
  `lock_run_unheld` when `bin/lib/lock-hygiene.sh` has not propagated yet, so a
  box mid-sync still closes the fds. Only holder NAMING degrades there, to
  `(holder unknown)` — never to a fabricated pid.
- **The scan runs only on the skip path**, and the tick drops its own fd 9
  before scanning: a scanner that still held the descriptor would find its own
  `cut`/`head` and report a leak on a healthy box.
- **A routine overlap is not an alert.** A holder whose argv contains
  `run-triage.sh` is a tick genuinely still running: it is named in the log and
  raises nothing. Everything else (a build, a `claude`, a bare `sleep`) is a
  leaked descriptor and rings once under a stable id.
- **The prefix `previous run still active` is unchanged**, so anything grepping
  the old wording still matches.
