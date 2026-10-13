# Timezone check ("this box is not on UTC")

**What it is:** `bin/lib/tz-check.sh`, one sourced function `tz_check <root>`,
hung off two cron lanes. It compares this box's `date +%Z` to `UTC` and raises
one critical, deduped alert when they differ, then resolves that same alert when
the box comes back.

**Why it exists:** on 2026-09-15 the hub was running on CDT. Every log line,
alert and forensic timestamp it wrote was five hours off, and the first pass
over the wipe (#388) burned those five hours reconciling stamps that did not
agree. Nothing downstream can tell a skewed timestamp from an honest one, so
the box has to say so itself. Setting UTC on a fresh box is the installer's job
(`bin/bootstrap-machine.sh`); this is the detector for the boxes already out
there.

**How an operator reaches it** — two lanes, on purpose:

| lane | cron line | which boxes |
|---|---|---|
| `bin/healthcheck.sh <project>` | `43 6,18 * * *` | only projects with a real prod URL — `bin/lib/cron-lines.sh:84` emits the line, and `fleet.conf`'s `-` suppresses it |
| `bin/clock-sync.sh` | `*/30 * * * *` | every cron file, `cron/hub.cron` included |

The hub has no project block at all, so a check living only in `healthcheck.sh`
would never have run on the one box that was actually wrong. That is what the
`clock-sync.sh` hook is for, and it is why removing it is not a simplification.

**How to drive it:**

| what | how |
|---|---|
| the lib through both callers, on a scratch tree | `bash tests/tz-check.bh-445-test.sh` |
| the clock-sync lane is unchanged by the hook | `bash tests/clock-sync-test.sh` (its scratch bin has no `lib/`, so the presence guard skips) |
| on a live box, what it sees right now | `date +%Z` (anything but `UTC` alerts) |
| on a live box, force one pass | `TZ_OVERRIDE=CDT /root/harness/bin/clock-sync.sh` — writes a real alert, so only on purpose |

**Files on a live box:**

| file | what it holds |
|---|---|
| `state/alerts/tz_<box-id>.json` | the alert lifecycle row. The id is `tz:<box-id>`; `as_sanitize_id` in `bin/lib/alert-state.sh` folds `:` to `_` before it becomes a filename, so the `:` never appears on disk. `ALERT_STATE_DIR` moves the directory, and the lib honours it |
| `logs/ALERTS.log` | the `[orchestrator/tz-check]` line, and the `RESOLVED` line when the box returns to UTC |
| `logs/alerts-state.log` | the `fire` / `suppress` / `remind` / `resolve` decisions per tick |
| `state/box-id` | the id the alert is keyed on. Absent or empty falls back to `hostname` |

**Knobs:**

- `TZ_CHECK=0` turns it off on BOTH lanes. It is read from the environment
  first and otherwise from the single `TZ_CHECK=` line of `global.env` in the
  harness env directory, which is where `CLOCK_SYNC=0` lives. The directory is
  resolved through `harness_env_dir` (`bin/lib/env-path.sh`), never a hardcoded
  path, so a box whose env lives in `/etc/harness/env` gets the same switch.
  `healthcheck.sh` does not source `global.env` and should not — it would widen
  the environment of every child it spawns — so the lib reads the one key
  itself. Anything other than exactly `0`, including a `global.env` that is
  missing or unreadable, leaves the check on.
- `TZ_OVERRIDE` supplies the zone instead of `date +%Z`. Test and dry-run input
  only; nothing in production sets it.

**What must never regress:**

- **The verdict never changes a caller's exit code.** Both call sites are
  `tz_check ... || true`, behind a `[ -r ]` presence guard so a fixture that
  copies the caller alone stays quiet. A healthcheck that started failing
  because of a timezone would take the prod-liveness alert down with it.
- **Fail-open.** A `date +%Z` that prints nothing is reported as `unknown` and
  alerts. A missing `global.env` leaves the check on. A missing file must never
  silence a pager.
- **The UTC path is silent unless something is open.** It calls
  `lane-alert.sh --resolve` only while `state/alerts/tz_<box-id>.json` exists
  with `resolved_at` unset or `0`. `alert_state_resolve` keeps the row and just
  stamps `resolved_at`, so a guard on mere file existence would go back to
  writing a `resolve-silent` line into `logs/alerts-state.log` on every tick —
  48 a day per box, into an append-only ledger with no rotation. An unreadable
  or unparseable row falls towards calling, which costs at most that one line.
- **One page, not 48 a day.** `clock-sync.sh` calls this every 30 minutes;
  `bin/lib/alert-state.sh` suppresses the repeats while the id is open and
  sends at most one reminder per `ALERT_REMINDER_S`. On a box where the state
  library is missing or switched off, `lane-alert.sh` takes its legacy path and
  every call writes an ALERTS line — that is lane-alert's documented
  fail-towards-paging behaviour, not a bug in this lane.
- **The fix in the alert must be runnable here.** These are systemd-less Orgo
  containers, so the text leads with
  `ln -sf /usr/share/zoneinfo/Etc/UTC /etc/localtime && echo Etc/UTC > /etc/timezone`
  and mentions `timedatectl` second, for the boxes where it works.
- **The clock is never touched here.** This reads a zone; `bin/clock-sync.sh`
  owns `date -s`, and the two are independent (a box can be perfectly synced
  and still be on CDT — that is exactly what the hub was).
