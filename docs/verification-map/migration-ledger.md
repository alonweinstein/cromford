# Migration ledger three answers (present / absent / unknown)

**What it is:** the two migration lanes on the hub dedupe on
`ledgers(kind=migration)` in harness-jobs, and both now tell an ANSWER apart from
a FAILED READ.

`bin/migration-autopilot.sh` asks the ledger before it does anything with a
merged migration file. Until BH-1040 its `ledger_has` collapsed the client's two
non-zero answers — rc 2 "worker reachable, no such row" and rc 1 "the API is
unusable" — into one "absent". With harness-jobs down, a file already ledgered as `failed-alerted`, `flagged` or
`applied` went back through the classifier, the deploy gate and the apply POST as
if it had never been seen. The ledger exists to stop exactly that (the pb67 alert
storm) and it failed open on the one condition it was built for.

Now: **present** skips, **absent** proceeds exactly as before, and
**unknown** HOLDs the whole per-project run — one alert, nothing classified,
nothing posted, exit 0, and the next cron tick re-asks.

`bin/check-migration-prs.sh` moved onto the same kind in the same change. It used
to dedupe on its own `state/migration-prs-alerted.txt`, so an autopilot apply and
this lane's human ping could not see each other.

**How an operator reaches it:** no UI. `cron/hub.cron` runs
`check-migration-prs.sh` at `7,27,47` and `migration-autopilot.sh` (three
projects in one `for`) at `9,24,39,54`. The four surfaces are:

- `logs/<project>.log` — the autopilot's `holding this run, nothing applied` line.
- `logs/ALERTS.log` and the `fleet_alert` beat — `MIGRATION AUTOPILOT HOLD: …`,
  sent through `bin/lane-alert.sh --id migration-autopilot-hold:<project>`, and
  `MIGRATION-PR LANE BLIND: …` under `--id migration-prs-ledger-unknown`.
- `logs/<project>.log` — also the autopilot's `migration ledger write failed`
  line, one per `job_ledger_put` that did not record (BH-2623).
- `logs/migrations.log` — the PR lane's `ledger unreachable — not pinging this
  tick` line and its `already applied by migration-autopilot` line.

**Primary lane / scripts:**
- `bin/migration-autopilot.sh` — `ledger_has` (the three rcs, from
  `job_ledger_get` alone), `ledger_put` (the DB row only; a failed write logs one
  line),
  `ledger_db_reachable` (the once-per-run `--resolve`), `HOLD`, and the
  `ledger_has "$FN"; case $?` at the top of the per-file loop.
- `bin/check-migration-prs.sh` — `mig_ledger_on`, `mig_seen`, `mig_record`,
  `mig_autopilot_applied_all`, `mig_unknown_alert` (one per run, on the first
  unknown) and the end-of-run `--resolve`, plus the per-PR loop that reads them.
- `alert_dedupes_by_id` in BOTH scripts — whether `lane-alert.sh` will honour
  `--id` at all on this box.
- `bin/jobs-client.sh` — `job_ledger_get` / `job_ledger_put`, whose rc contract
  (0 / 2 / 1) both lanes read; it also carries `HARNESS_SECRET` in from
  `env/global.env`, which is how a lane learns a worker is configured at all.
- `bin/lane-alert.sh migration-autopilot` / `migration-prs` — how the two alerts
  leave the box, with the direct `ALERTS.log` + `bin/beat.sh` fallback (akey =
  the condition id) when the script is absent OR its state machine is off.

**State and knobs:**
- ledger of record: `ledgers(kind=migration)`. Two key shapes, deliberately:
  `<project> <file>` (autopilot) and `<owner/repo>#<n>` (the PR lane). Same kind,
  so each lane reads what the other decided; different shapes, so they never
  collide.
- the autopilot keeps no file copy (BH-2623). Every tick asks the DB for each
  candidate file, and a row lost to a failed write costs a re-check: the next
  tick's `is_applied` reads the app's own applied list before any apply POST. An
  old autopilot done-file left in `state/` on a box is neither read, written
  nor deleted.
- `state/migration-prs-alerted.txt` — legacy. READ on a real miss for one release
  (a key found there is back-filled as status `legacy-file`), and written only
  when no worker is configured. Never removed.
- `MIGRATION_AUTOPILOT_REPO_DIR` — overrides `/root/repos/<project>` so the
  fixture suite can drive the real script. `HARNESS` is overridable for the same
  reason. Both defaults are the old literals.
- alert ids: `migration-autopilot-hold:<project>`, derived from the project name,
  and `migration-prs-ledger-unknown` for the PR lane (fleet-wide — one blind lane,
  not one per repo). `lane-alert.sh` dedupes repeats on them across ticks and
  `--resolve` closes each on the first clean read of a later run.
- `flags/alert-state-off` / `ALERT_STATE_ENABLED=0` — the alert state machine's
  kill switch, and the reason `alert_dedupes_by_id` exists. With the machine off,
  `bin/lane-alert.sh:72-77` ignores `--id` and beats
  `orclane:<lane>:$(date -u +%Y%m%d%H%M)`, a fresh akey every tick; both lanes
  therefore route around it and beat their own condition id instead.
- the HOLD's severity is `critical` only when prod is already serving the merge
  commit. When it is not, the deploy gate (a local `git merge-base`, answerable
  during the outage) would have held the file this tick anyway, so the hold pages
  `warn`. The PR lane's blind alert is always `warn` — its ping is one tick late,
  nothing is blocked.
- the PR lane's run markers are two `mktemp` files removed on exit, not state:
  the per-PR loop is a pipeline subshell, so a shell variable would not survive
  to the next repo and four repos would raise four alerts for one condition.

**Preconditions / seed needs:** a box with no `HARNESS_SECRET` and/or no
`bin/jobs-client.sh` has no worker configured. The autopilot then has no ledger
at all: every file reads absent (never a HOLD), and `is_applied` still guards
re-apply. The PR lane behaves exactly as it did before BH-1040 (its legacy file,
never a HOLD). That is deliberate — under the other reading every box without the
secret would hold forever.

**How to drive it:**
- `HARNESS_TEST_SANDBOX=1 bash tests/migration-ledger-three-answers-test.sh` —
  runs both scripts as scripts against a scratch `$T` with fixture `gh`, `curl`,
  `beat.sh`, `lane-alert.sh` and a `jobs-client.sh` stub whose answers are driven
  by `$T/ledger-mode` (`outage` / `absent` / `present:<status>` / `rows`). Cases:
  1–3 the autopilot's three answers, 1b the same hold on a box without
  `bin/lane-alert.sh`, 1c the same hold with the alert state machine OFF, 1d the
  hold's severity while prod is not serving the merge yet, 4–10 the PR lane's
  (4/4b its blind alert, 4c the resolve), plus a live-file tripwire.
- `HARNESS_TEST_SANDBOX=1 bash tests/migration-autopilot-ledger.bh-2623-test.sh` —
  the same fixture shape for the autopilot alone, with `$T/put-mode` (`ok` /
  `fail`) driving `job_ledger_put`. A1–A6 and N1: a DB hit skips, a done-file row
  no longer shadows the DB, an outage HOLDs, no done-file is ever written or
  removed, a failed put logs exactly one line, and a lost row never re-applies.
- On a live box: `grep 'migration ledger write failed' logs/<project>.log`
  shows any lost write; `grep 'holding this run' logs/<project>.log` shows any
  hold; `grep 'ledger unreachable' logs/migrations.log` shows a PR-lane skip;
  `state/alerts/migration-autopilot-hold:*.json` is the open/closed condition.

**Verify it works:** `tests/migration-ledger-three-answers-test.sh` reports
`70 passed, 0 failed` and `tests/migration-autopilot-ledger.bh-2623-test.sh`
reports `34 passed, 0 failed`. On the hub, a tick with harness-jobs reachable leaves no
new `holding this run` line and no new `ledger unreachable` line; a tick during a
worker outage leaves exactly one of each per project and zero apply POSTs.

**What must never regress:**
- rc 1 is never "absent". The apply POST must be unreachable from a tick that
  could not read the ledger.
- A HOLD stops the whole per-project run, not one file: migrations within a
  project can be order-dependent, so applying the next one is the wrong half to
  keep.
- A HOLD exits 0 and writes nothing — no ledger row, no job row.
- The autopilot never reads or writes its old `state/` done-file. A
  failed `job_ledger_put` is one log line, never silent.
- No worker configured = the PR lane's old behaviour, byte for byte
  (`tests/remediator-agent-test.sh` runs `check-migration-prs.sh` in exactly that
  shape).
- Only an autopilot status starting `applied` suppresses the human ping.
  `flagged`, `failed-alerted`, `skipped`, `legacy-file` all still page.
- The PR lane's beat text and akey (`migration:<owner/repo>#<n>`) are unchanged,
  and the `alerted` row is written AFTER `beat.sh` returns.
- An unreadable ledger never leaves the PR lane silent. `logs/migrations.log` is
  tailed by nothing, so the skipped tick must also raise
  `migration-prs-ledger-unknown` — once per run, never once per PR.
- Neither lane passes `--id` to `lane-alert.sh` on a box where it would be
  ignored. One condition = one alert has to hold with the state machine off too.

**Manual-only / not automatable:** watching a real harness-jobs outage on the hub
and confirming the hold clears on its own when the worker answers again (the
fixture pins both halves, but not the wall-clock recovery).
