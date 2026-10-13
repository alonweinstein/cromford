# Disk guard (alert at 85%, refuse to start a build at 92%)

**What it is:** two readers of one number, the root filesystem's Use% from
`df -P /` (the same shape `bin/fleet-status-push.sh` reports for the hub):

- `bin/disk-guard.sh`, the `*/10` cron lane on every board box and the hub.
  At or over `DISK_ALERT_PCT` (85) it raises `disk-high-<host>` (warn) through
  `bin/lane-alert.sh`; at or over `DISK_BUILD_REFUSE_PCT` (92) it also raises
  `disk-refuse-<host>` (critical). Each is resolved when the disk drops back
  under its line.
- The `# >>> disk gate` block in `bin/run-build.sh`, right after
  `# <<< hub-no-build` and before `# >>> overlap not-before`. At or over
  `DISK_BUILD_REFUSE_PCT` it answers `BUILD_DEFERRED disk / at <pct>% on <host>
  (builds refused at <n>%, knob disk-guard DISK_BUILD_REFUSE_PCT); <free> MB free`
  and exits 3, before any plan session or claim, and raises the same
  `disk-refuse-<host>` id. Pool machines (`BUILDER_EXEC=1`) are not gated.

**Why it exists:** BH-1123. Builds used to discover a full disk themselves,
halfway through, as ENOSPC.

**How an operator reaches it:** `bin/render-cron.sh <box>` carries
`*/10 * * * * /root/harness/bin/disk-guard.sh >/dev/null 2>&1` for project-4, hub,
project-6, project-1, project-3, project-9, small, project-2 and project-5. The output
is `logs/disk-guard.log` (quiet under the alert line), `logs/ALERTS.log` and the
alert state in `state/alerts/disk-{high,refuse}-<host>.json`. A refused build
shows its reason in `builds/<id>/RESULT` and `builds/<id>/pipeline.log`.

**How to drive it:**

| what | how |
|---|---|
| the whole suite (reading, thresholds, the lane, the run-build block, the knobs) | `HARNESS_TEST_SANDBOX=1 bash tests/disk-guard.bh-1123-test.sh` |
| on a live box, once | `/root/harness/bin/disk-guard.sh; tail -3 /root/harness/logs/disk-guard.log` |
| the knobs a box resolves | `bin/harness-ctl.sh show disk-guard` |

The suite puts a fake `df` first on `PATH` and stubs `lane-alert.sh` in a
scratch `$HARNESS`; it never reads the real disk.

**Knobs:** on the `disk-guard` lane (`catalog/lanes.d/disk-guard.json`),
settings row > env > registry default: `DISK_ALERT_PCT` (85, 50..99) and
`DISK_BUILD_REFUSE_PCT` (92, 50..100). They show on the console's
`/settings/disk-guard` page. Off: `flags/lane-off-disk-guard` stops the lane,
not the build gate; `DISK_BUILD_REFUSE_PCT=100` stops refusing.

**What must never regress:**

- **Unreadable is unknown.** A df that fails or prints no Use% alerts nothing,
  resolves nothing and refuses no build. A broken probe must not stop the fleet.
- **At means at.** 85% alerts and 92% refuses; 84% and 91% do not.
- **Before the spend.** The gate sits above the overlap check, every claim and
  the plan, so a refused build costs one `df` and no model session.
- **One condition, two writers.** The lane and the gate raise the same
  `disk-refuse-<host>` id, so a full box pages once.
