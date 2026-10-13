# One liveness fact (the lanes row), and one death detector for builds

**What it is:** BH-1031, state→DB slice 6. Two questions the fleet used to
answer in three places each now have one answer apiece.

*Is that lane process alive?* The beats a long-lived lane already writes to
`state/heartbeat/<lane>.<pid>.json` are written THROUGH to its `lanes` row
(`bin/lib/heartbeat.sh` → `bin/jobs-client.sh lane_proc_beat` →
`POST /api/lanes/tick` with `event`, `pid`, `interval_s`, `expect_s`, `note`).
The worker computes `proc_state` / `proc_stale` from the rhythm the lane itself
declared, and `bin/heartbeat-reaper.sh` reads that verdict back for every box in
one GET. `bin/fleet-heartbeat.sh` — the 15-minute ssh probe that was the second
answer — is deleted.

*And the passenger that hop was carrying.* Backup freshness (#399) rode
`fleet-heartbeat`'s ssh because that hop was the only thing on the hub already
talking to every box. Deleting the vehicle would have blinded
`bin/fleet-status-push.sh`, `bin/pipeline-health.sh` and the console's Fleet
column in the same commit — silently, because every assertion about the READING
would have stayed green. So that fact moves the same way this slice moves the
others: **the box states it** (`bin/state-backup.sh`, on the way out of the tick
that produced the stamp, via `box_backup_set` → `POST /api/boxes/backup` →
`box_status.backup_*`) and **the hub reads the rows**
(`bin/backup-records-sync.sh`, `*/5`, one GET) and writes the record the fleet
already reads. One collector, and it is the machine that owns the fact. See
[backup-freshness.md](backup-freshness.md).

*Did that build die?* `bin/resume-dead-builds.sh` — the second death detector,
on its own `*/30` cron on every box — is folded into `bin/jobs-watchdog.sh` as
`bin/lib/resume-dead.sh`, and death is now the job ROW instead of twenty quiet
minutes (a window a healthy build whose agent is thinking passes every time).
The per-key **flock stays**, as the local pre-check in front of the ledger: it
answers a different question, and it is the only probe that covers the case the
row gets wrong — a live build whose claim the hub orphaned after a worker blip
(the heartbeat route never restores `running`). Relaunching one of those makes
`run-build.sh` write `BUILD_DEFERRED … already building` into the LIVE build's
dir, which the sweep then reports to the client's board.

**Why it was three answers.** A heartbeat FILE is legible only on the box that
wrote it, so it goes silent exactly when the failure is largest (the box is
gone). The ssh probe answered "can the hub reach this box", which is a different
question — its own comments said so — and it stayed wrong in both directions: a
box off the tailnet still ran its cron, and a reachable box could be running
nothing. The `lanes` row answered a third thing again: did the CRON fire. A box
whose crontab is healthy and whose `merge-conductor` died read perfectly alive
in all three.

## The contract

One row, two clocks, disjoint writers — the same split the cron half already
had between the hub (expectation) and the box (ticks):

| column | written by | means |
|---|---|---|
| `last_tick_at`, `last_tick_kind` | a box's `run-triage.sh` tick | the CRON fired |
| `proc_beat_at`, `proc_pid`, `proc_note`, `proc_interval_s`, `proc_deadline_at`, `proc_started_at`, `proc_ended_at` | a long-lived lane through `bin/lib/heartbeat.sh` | the PROCESS is breathing |

- A process row is keyed `project = 'hb.<lane>'`, because a box runs several
  long-lived lanes at once and the prefix keeps them out of the namespace
  `PUT /api/lanes` declares and retires from `fleet.conf`.
- `GET /api/lanes` **excludes** `hb.*` rows unless asked (`?proc=1`,
  `?proc_stale=1`), so every reader that exists today — the watchdog's lane
  pass, the console's LANES table — sees exactly what it saw before.
- A process beat writes NO cron column, and a cron tick writes no process
  column. A beat landing in `last_tick_at` would hide the 2026-08-30 failure the
  lanes table was built for.
- `proc_stale` = beats stopped (`silent`) or past the expected-by (`overdue`).
  Never "dead": the worker cannot `kill -0` a pid on another machine, and the
  box-local reaper keeps that probe.
- A clean exit (`hb_done`) stamps `proc_ended_at` and never pages; the next
  launch clears it, so the instance that replaced it can die like any other.

## Dark until the flag says otherwise

`flags/lane-liveness-db` — a DB row that `flag_sync` writes down as a file. The
READER (`bin/heartbeat-reaper.sh`) reconciles it once per `*/5` pass through
`flag_active`; the WRITER (`bin/lib/heartbeat.sh`) tests the file only, because
a beat must not pay a network round trip to find out whether to beat. With the
flag off nothing is sent and nothing is read: the file pass behaves byte for
byte as it did.

## Fail-open on the liveness half, fail-CLOSED on the resume

- The beat is detached, best-effort, rc 0 always: a missing client, a hanging
  worker or a broken route costs the lane nothing and never delays its rhythm.
  The file remains the write-ahead and is written whatever the ledger does.
- The reaper's DB pass adds findings; it never removes one. The file pass owns
  this box (only it has the pid), so a lane it already reported is not reported
  twice, and an unreachable worker leaves the file pass untouched.
- `resume_dead_pass` is the one pass in this harness that fails CLOSED. "The
  ledger did not answer" would otherwise mean "every build in the fleet looks
  dead", and that relaunch storm lands precisely during a worker outage. No
  answer = no dir is judged, and the log says so.

## Where it runs

| lane | where | line |
|---|---|---|
| the beat | inside every long-lived lane | `hb_start` / `hb_tick` / `hb_done` |
| the flag, on a worker box | every box, `24,54` | `flag_sync lane-liveness-db` at the head of `jobs-watchdog.sh --resume` (the reaper, the only other reconciler, runs on the hub alone) |
| the reader | hub, `*/5` | `cron/hub.cron`: `*/5 * * * * /root/harness/bin/heartbeat-reaper.sh` |
| the resume pass | every box, `24,54` | `cron/<box>.cron`: `/root/harness/bin/jobs-watchdog.sh --resume` |
| the resume pass (hub) | hub, `*/5` | the tail of the full `bin/jobs-watchdog.sh` sweep — no second line |

## How to drive it

| what | how |
|---|---|
| the liveness fact end to end — write-through, the declared rhythm, the rate limit, flag, reaper, the deleted probe | `HARNESS_TEST_SANDBOX=1 bash tests/lane-liveness-single-fact-test.sh` |
| the box SLO reading the row (and never the dead `state/fleet-heartbeat` files) | `HARNESS_TEST_SANDBOX=1 bash tests/fleet-slo-test.sh` |
| the worker's verdicts on the process clock | `cd worker/jobs && node --test test/lane-proc.test.js` |
| the fold — requeued once, never twice; both watchdog entry points | `HARNESS_TEST_SANDBOX=1 bash tests/resume-via-watchdog-test.sh` |
| everything the resume pass inherited (caps, refunds, shipped-work guard) | `HARNESS_TEST_SANDBOX=1 bash tests/resume-dead-builds-test.sh` |
| the file half, unchanged | `HARNESS_TEST_SANDBOX=1 bash tests/heartbeat-reaper.bh-638-test.sh` |
| the passenger — the box reports, the hub writes the record, both mutated | `HARNESS_TEST_SANDBOX=1 bash tests/backup-freshness-test.sh` |
| one pass by hand on the hub | `/root/harness/bin/jobs-client.sh lane-procs` then `/root/harness/bin/heartbeat-reaper.sh; echo rc=$?` |

## What must never regress

- **A beating process never makes a dead cron read alive**, and a ticking cron
  never makes a dead process read alive. Two clocks, judged apart.
- **One dead lane, one finding.** The file pass and the row pass must not both
  page for the same lane on the same box.
- **It pages once, and again only to say it came back.** The latch is
  `lanes.alerted_at` on the `hb.*` row, set BEFORE the page (dying between them
  loses one alert; the other order pages every five minutes for ever).
- **A clean exit never pages** — with one bounded exception worth recognising
  the first time it happens: `hb_done`'s `done` beat is detached and best-effort,
  so if that single request is lost (a worker blip exactly at lane exit) the row
  keeps `proc_ended_at` null and reads `silent` after its threshold. One page,
  cleared by the lane's next `start`.
- **The ledger is never the reason a lane dies.** No client, no flag, no worker:
  the file pass is exactly what it was.
- **The resume pass fails closed** and asks the row before launching anything:
  `parked` writes the terminal `BUILD_DEAD` the sweep reports, `already` means
  somebody else settled it, `held` means another live row owns this ticket — and
  none of the three launches anything. The row is looked up
  across `running`, `orphaned`, `queued_for_retry` and `parked`, because a build
  the watchdog has judged has already LEFT `running` by the time this pass looks
  — reading only `running` rows meant the lane's retry policy was never asked.
- **The row is found by the ticket KEY.** `bin/run-build.sh` opens its claim
  with `job_open "$PROJECT" "$KEY"`, so the row's `ticket_id` column is the
  ticket key — while the build dir's `job.json` records the BOARD id under a
  field of the same name (a uuid on a product board). Both sides of the lookup
  use `$PROJECT/$KEY`; a fixture that puts one string in both columns cannot see
  the difference, so both suites now carry a different board id in the dir than
  in the row.
- **A held key lock vetoes a resume**, and "cannot tell" (no `python3`) counts
  as held. A live build must never be relaunched on top of itself.
- **A beat never rewrites the launch's numbers.** `hb_tick` sends no
  `interval_s`, and the row's own `proc_interval_s` wins over anything a beat
  carries — a beat at the library default would collapse `blocked-resolver`'s
  declared 1800s threshold to 900s and page for a healthy 40-minute fix round.
- **The write-through is rate-limited at the writer**: one DB beat per half
  rhythm per (lane, pid), always far inside the row's stale threshold. The FILE
  is written on every single tick.
- **Build-proof only.** Nothing here has been driven on the live fleet by the
  build that shipped it: the flag row does not exist yet, so the write-through
  and the DB pass are dark in production until an operator turns them on. Every
  claim above comes from the fixture suites running the real scripts.
