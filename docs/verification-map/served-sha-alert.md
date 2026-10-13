# Served-behind alert (served-sha watch hook)

**What it is:** `bin/lib/served-sha-watch.d/10-alert.sh`, a hook of the hub lane
`bin/served-sha-watch.sh` ([served-sha-watch.md](served-sha-watch.md)). The lane
judges each Vercel project every 5 minutes. This hook turns the `alert` verdict
into a page and the `in-sync` verdict into a resolve (BH-4937, #4916). The `wait`
and `unreadable` verdicts do nothing.

- `alert`: the id `served-behind:<project>:<head12>` is added to `open_ids` in
  the lane's state file first, then the hook runs
  `bin/lane-alert.sh --severity critical --id served-behind:<project>:<head12> served-sha-watch "<text>"`,
  with text like
  `demo-os: prod serves 9f8e7d6c, main is 2b2272a4 (merged 25m ago, 3 commits behind, deployment for 2b2272a4: none)`.
  The deployment word is `none`, `building`, `ready-not-promoted`, `failed:ERROR` or `unread`.
  It calls lane-alert on every alert tick. lane-alert's per-id state machine
  sends the first one, counts the repeats and owns the reminders.
- `in-sync`: one `lane-alert.sh --resolve --id <id>` per `served-behind:*` id in
  `open_ids`. The lane then deletes the state file.

## How to reach it

- It runs inside the lane, so the lane's cron line, flag and knobs apply
  (`SERVED_SHA_LAG_MIN` is the threshold). The hook adds no knob.
- On a live hub: `jq .open_ids /root/harness/state/served-sha-watch/<project>.json`,
  `ls /root/harness/state/alerts/ | grep served-behind`, and
  `grep 'orchestrator/served-sha-watch' /root/harness/logs/ALERTS.log`.
- The open alert shows as a `served-behind_<project>_<head12>` row on the
  Mission Control Alerts screen. The resolve closes it.

## How to drive it in a test

`tests/served-sha-alert.bh-4937-test.sh` builds the lane's scratch harness with
`tests/lib/served-sha-fixture.sh`, copies `10-alert.sh` into
`$T/h/bin/lib/served-sha-watch.d/`, and runs real ticks. The fixture's recorder
`lane-alert.sh` writes each call's argv to `$T/alerts.txt`. Case S3r swaps in the
real `bin/lane-alert.sh` and reads `$T/h/logs/ALERTS.log` and `state/alerts/`.

## What usually lies

- The ALERTS.log line does not carry the id. lane-alert writes
  `[orchestrator/served-sha-watch] <text>` and stores the id sanitized, so the
  state row is `served-behind_<project>_<head12>.json`, not the colon form.
- `failed:ERROR` is the only failed word. The tracer reads a canceled
  deployment as `none`.
- `? commits behind` means the hook's own compare read failed. A compare the
  LANE could not read makes the verdict `unreadable`, and then nothing pages.
- `merged ?m ago` means the hook got no age. It is never shown as `0m`.
- When main moves while still behind, the new head pages under its own id and
  the old id stays open until the next `in-sync` resolves both. If the state
  file was corrupt at an alert tick, the ids opened before it are lost and only
  lane-alert's auto-stale closes those rows.
