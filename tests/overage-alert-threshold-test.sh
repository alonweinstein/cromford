#!/bin/bash
# tests/overage-alert-threshold-test.sh — the day-alert threshold must actually
# REACH the running tracker, and must be tuned above normal burn.
#
# WHY THIS IS A TEST AND NOT A CONFIG EDIT. hub.cron invokes
# bin/extra-usage-track.sh directly: no BASH_ENV, no `. env/global.env`. So
# before this change an EXTRA_USAGE_DAY_ALERT set in an env file reached
# nothing — the value sat in a config file looking authoritative while the
# script used its code default, and no error anywhere said so. Setting a value
# and assuming it arrived is the same failure shape as the inert billing_mode
# column: config that cannot possibly take effect.
#
# So this pins BOTH halves: the value is right, AND it is reachable.
# Run from anywhere: tests/overage-alert-threshold-test.sh   (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
SRC="$DIR/bin/extra-usage-track.sh"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

# --- 1. the default is tuned above normal burn -------------------------------
# Normal orchestrator burn is ~$600-670/day. At the old $100 default the alert
# fired EVERY day; an alarm that always rings is not an alarm, and the real
# anomaly then lands in a channel nobody reads. The number must sit above
# normal, and the assertion says so in those terms rather than pinning a magic
# constant nobody can re-derive.
THRESH_DEFAULT=$(grep -oE 'EXTRA_USAGE_DAY_ALERT:-[0-9]+' "$SRC" | head -1 | sed 's/.*:-//')
[ -n "$THRESH_DEFAULT" ] && ok || bad "could not find the EXTRA_USAGE_DAY_ALERT default"
[ "${THRESH_DEFAULT:-0}" -gt 700 ] \
  && ok || bad "default \$$THRESH_DEFAULT is at or below normal daily burn (~\$600-670) — it will fire every day"
[ "${THRESH_DEFAULT:-0}" -le 2000 ] \
  && ok || bad "default \$$THRESH_DEFAULT is so high a real anomaly would not trip it"

# --- 2. THE DEAD-CONFIG SEAM: an env value must actually reach the script ----
# cron sources nothing, so the script has to source global.env itself. Without
# this line the threshold is unconfigurable in practice while looking
# configurable in the file.
# This asserts a SOURCING CONSTRUCT, not the string "global.env" anywhere.
# Two earlier versions of this assertion were false-greens: the first matched
# the explanatory comment above the line, and the second (comments stripped)
# matched the `_TSRC="env/global.env"` label further down. Deleting the actual
# `. "$H/env/global.env"` left both passing. Both were caught by mutation
# rather than by reading — a grep-based assertion is only as strong as the
# thing that can ALSO match it.
# BH-454 repointed the construct from "$H/env/global.env" to "$HENV/global.env"
# (the env dir now comes from bin/lib/env-path.sh); same assertion, new spelling.
grep -qE '\.[[:space:]]+"\$HENV/global\.env"' <(grep -vE '^[[:space:]]*#' "$SRC") \
  && ok || bad "the script never sources env/global.env — cron sources nothing, so an env value cannot reach it"

# And prove it end-to-end rather than by grep: run the real sourcing logic
# against a fixture global.env and check the value that lands.
mkdir -p "$T/env"
printf 'EXTRA_USAGE_DAY_ALERT=4242\n' > "$T/env/global.env"
LANDED=$(H="$T" bash -c '
  set -uo pipefail
  set -a; . "$H/env/global.env" 2>/dev/null; set +a
  echo "${EXTRA_USAGE_DAY_ALERT:-1300}"')
[ "$LANDED" = "4242" ] \
  && ok || bad "a value in env/global.env does not reach the script (got '$LANDED')"

# With no env file present the code default must apply — a missing file is the
# normal case on most boxes and must not blank the threshold.
LANDED2=$(H="$T/nonexistent" bash -c '
  set -uo pipefail
  set -a; . "$H/env/global.env" 2>/dev/null; set +a
  echo "${EXTRA_USAGE_DAY_ALERT:-1300}"')
[ "$LANDED2" = "1300" ] \
  && ok || bad "a missing env file must fall back to the code default (got '$LANDED2')"

# --- 2b. THE SOURCE MUST NOT KILL THE TRACKER SILENTLY -----------------------
# Under `set -u` an unbound reference inside global.env is FATAL regardless of
# -e, and the 2>/dev/null swallows the message. The old form therefore died
# with NO csv row, NO log line and NO alert: the hourly meter simply stops and
# the headline overage number goes quietly stale. A silent death in the one
# script whose whole job is noticing money -- and it would look exactly like a
# quiet week.
#
# The fixture is a global.env that references an unset variable, which is the
# realistic shape (a box env file referring to something not exported yet).
mkdir -p "$T/broken"
printf 'BAD=$UNSET_VAR\nEXTRA_USAGE_DAY_ALERT=777\n' > "$T/broken/global.env"
SURVIVED=$(bash -c '
  set -uo pipefail
  H="'"$T"'/broken-parent"
  set -a +u; . "'"$T"'/broken/global.env" 2>/dev/null; set +a -u
  echo "THRESH=${EXTRA_USAGE_DAY_ALERT:-1300}"' 2>/dev/null; echo "rc=$?")
grep -q 'THRESH=777' <<<"$SURVIVED" \
  && ok || bad "an unbound var in global.env kills the tracker silently (got: $SURVIVED)"
grep -q 'rc=0' <<<"$SURVIVED" \
  && ok || bad "the tracker must survive a global.env with an unbound reference (got: $SURVIVED)"

# And the shipped line must actually carry the guard, not just this test.
# BH-454: same line, env dir now resolved into $HENV.
grep -q 'set -a +u; \. "\$HENV/global.env" 2>/dev/null; set +a -u' <(grep -vE '^[[:space:]]*#' "$SRC") \
  && ok || bad "the shipped source line does not disable -u around the source"

# --- 2c. the script must stay executable ------------------------------------
# It is invoked directly by cron. harness-sync's chmod +x self-heals the
# deployed copy, which is exactly why a lost exec bit in git can sit unnoticed.
[ -x "$SRC" ] \
  && ok || bad "extra-usage-track.sh is not executable — cron invokes it directly"

# --- 3. the effective threshold is LOGGED, so it is checkable from the box ---
# Without this, "we set it to 1300" is an assumption. With it, one grep on the
# box settles both the value and where it came from.
grep -q 'day-alert threshold' "$SRC" \
  && ok || bad "the effective threshold is never logged — there is no way to confirm it landed"
grep -q '_TSRC' "$SRC" \
  && ok || bad "the log line must name the SOURCE (env vs code default), or a dead env file stays invisible"

# --- 4. the daily INFO line is INFO, not an alert ---------------------------
# Raising the threshold removes daily noise but would also make a normal $600
# day silent, and "no alert" is not "someone looked". The visibility half must
# go to hub.log; putting it in ALERTS.log would rebuild the noise it replaced.
INFO_LINE=$(grep -n 'billed so far today' "$SRC" | grep -v 'EXTRA-USAGE:' | head -1)
[ -n "$INFO_LINE" ] && ok || bad "no daily INFO line for the day's burn"
# agent-rules.log, not hub.log: the tracker now runs on all 9 boxes and
# hub.log is the wrong file on 8 of them. Still NOT ALERTS.log — raising the
# threshold removed the daily noise, and routing the visibility line into the
# alert channel would rebuild exactly what it replaced.
grep -q 'billed so far today (meter .* alert at .*)" >> "$H/logs/agent-rules.log"' "$SRC" \
  && ok || bad "the daily INFO line must go to agent-rules.log, not ALERTS.log"

# It must be once-per-day, like the alert — an hourly cron writing this every
# run is the same noise problem one log file over.
grep -q 'info:\$TODAY' "$SRC" \
  && ok || bad "the INFO line must be marked once-per-day, or the hourly cron repeats it 24x"

echo "overage-alert-threshold-test: $PASS pass, $FAIL fail"
echo "NOTE: env/ is gitignored and lives only on the boxes, so the CODE DEFAULT is"
echo "      what takes effect today. Setting EXTRA_USAGE_DAY_ALERT in a box's"
echo "      global.env is now possible but is not required by this change."
[ "$FAIL" -eq 0 ]
