#!/bin/bash
# bin/clock-sync.sh — keep this box's clock within 30s of real time. Cron */30.
#
# WHY A HARNESS SCRIPT AND NOT NTP (2026-09-14). These are Orgo containers:
# init is init.sh, there is no systemd, no ntpd, no chrony, and nothing has ever
# disciplined the clock. Measured that afternoon, every fleet box was SLOW by
# 66-464 seconds and the hub by ~7. A slow clock is not cosmetic here:
#
#   - bin/gh-token.sh hands out a cached App token while it still has 300s of
#     life BY THIS BOX'S CLOCK. A box 444s slow hands out tokens GitHub has
#     already expired, and the lane sees "Invalid username or token" mid-push.
#   - the App JWT's iat/exp are computed from the same clock (iat is backdated
#     60s exactly because the two clocks disagree — 444s eats that margin whole).
#   - every `deferred_at` / stale-age comparison in the harness drifts with it,
#     so "has waited 12h" means something different on each box.
#
# WHAT IT DOES. If a real NTP daemon IS running, it does nothing at all — the
# daemon owns the clock and two writers is how a clock oscillates. Otherwise it
# reads the Date header of https://api.github.com (the host whose opinion of the
# time actually decides whether our tokens work; www.cloudflare.com is the
# fallback), and when the offset exceeds 30s it sets the clock with `date -s`.
# Inside the tolerance it writes a line and changes nothing, so a second run a
# second later is a no-op — the whole thing is idempotent by construction.
#
# WHEN IT CANNOT. `date -s` works in these containers (verified 2026-09-14), but
# a box without CAP_SYS_TIME answers "Operation not permitted". That is ONE
# ALERTS.log line naming what is needed and from whom, once a day — a clock this
# box cannot fix is exactly the thing that must not be whispered into its own
# log (the 2026-08-13 lesson).
#
# Off with CLOCK_SYNC=0 in env/global.env, or the settings row
# switch.clock-sync-off[.<box>] (flags/clock-sync-off when no row).
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
H="${HARNESS:-$(cd "$HERE/.." && pwd)}"
. "${HARNESS:-/root/harness}/bin/lib/env-path.sh" 2>/dev/null || . "$(dirname "${BASH_SOURCE[0]}")/lib/env-path.sh" 2>/dev/null || harness_env_dir() { printf '%s\n' "${1:-${HARNESS:-/root/harness}}/env"; }; HENV=$(harness_env_dir "$H")

# >>> lane gate (BH-1165) — one off-switch and one source of numbers for this
# lane. lane_gate_or_exit exits 0 when flags/all-off, flags/lane-off-clock-sync
# (or a pause_flags row driving either) is set; lane_env_apply then puts this
# lane's settings rows into the environment its own ${KNOB:-default} reads use.
# Both fail OPEN: an unreachable worker leaves the lane exactly as it is today.
# Registry: catalog/lanes.json. Operator: bin/harness-ctl.sh off clock-sync.
# shellcheck disable=SC1091
. "${HARNESS:-/root/harness}/bin/lib/lane-gate.sh" 2>/dev/null || true
# shellcheck source=lib/lane-switch.sh
. "${HARNESS:-/root/harness}/bin/lib/lane-switch.sh" 2>/dev/null || true
command -v lane_switch >/dev/null 2>&1 || lane_switch() { [ -f "$H/flags/$1" ]; }   # no lib: the file, as before
command -v lane_gate_or_exit >/dev/null 2>&1 && lane_gate_or_exit clock-sync
command -v lane_env_apply    >/dev/null 2>&1 && lane_env_apply    clock-sync
if [ -f "$HENV/global.env" ]; then set -a; # shellcheck disable=SC1090,SC1091
  . "$HENV/global.env"; set +a; fi
# AND AGAIN, BELOW THE ENV LOAD (BH-1165 review). `set -a; . env/global.env`
# re-assigns every name it carries, so the call above lost each knob the box's
# env file also sets — the settings row was gone, the page went on reporting
# `source: settings`, and nothing errored: the exact shape this ticket exists to
# end. The call above still earns its place: the knobs this lane reads BEFORE
# this line have no other way to see a row. Applying twice is idempotent (the
# settings cache is already warm) and section 16 of tests/lanes-registry-test.sh
# is the ordering.
command -v lane_env_apply    >/dev/null 2>&1 && lane_env_apply    clock-sync
[ "${CLOCK_SYNC:-1}" = 0 ] && exit 0
lane_switch clock-sync-off file && exit 0

# Timezone check (BH-445). healthcheck.sh runs only for projects with a prod URL
# and the hub has no project block, so the box that was CDT is covered here.
# Guarded on lib presence: tests/clock-sync-test.sh copies only this file.
# shellcheck disable=SC1090,SC1091
[ -r "$HERE/lib/tz-check.sh" ] && { . "$HERE/lib/tz-check.sh"; tz_check "$H" || true; }

LOG="$H/logs/clock-sync.log"
ALERTS="$H/logs/ALERTS.log"
TOL="${CLOCK_SYNC_TOLERANCE:-30}"
SOURCES="${CLOCK_SYNC_SOURCES:-https://api.github.com https://www.cloudflare.com}"
STAMP() { date -u '+%Y-%m-%d %H:%M:%SZ'; }
say() { mkdir -p "$H/logs" 2>/dev/null; echo "$(STAMP) $*" >> "$LOG"; }

# An NTP daemon running means the clock already has an owner. Checked by
# process, not by config file: a package that is installed and not running
# disciplines nothing, and that is the box this script exists for.
ntp_running() {
  if command -v timedatectl >/dev/null 2>&1; then
    case "$(timedatectl show -p NTPSynchronized --value 2>/dev/null)" in yes) return 0 ;; esac
  fi
  pgrep -x chronyd  >/dev/null 2>&1 && return 0
  pgrep -x ntpd     >/dev/null 2>&1 && return 0
  pgrep -x ntpdate  >/dev/null 2>&1 && return 0
  pgrep -x systemd-timesyncd >/dev/null 2>&1 && return 0
  return 1
}
if ntp_running; then
  say "clock-sync: an NTP daemon owns this clock — nothing to do"
  exit 0
fi

# The remote instant, from an HTTP Date header. HEAD only: we want one header,
# not a body, and a 401/404 still carries a Date we can trust.
remote_epoch() { # remote_epoch <url> -> unix seconds on stdout
  local hdr
  hdr=$(curl -sS -I -m "${CLOCK_SYNC_TIMEOUT:-10}" "$1" 2>/dev/null \
        | tr -d '\r' | grep -i '^date:' | head -n 1 | sed 's/^[Dd][Aa][Tt][Ee]:[[:space:]]*//')
  [ -n "$hdr" ] || return 1
  date -u -d "$hdr" +%s 2>/dev/null
}

REMOTE=""; SRC=""
for U in $SOURCES; do
  REMOTE=$(remote_epoch "$U") || REMOTE=""
  case "$REMOTE" in ''|*[!0-9]*) REMOTE="" ;; *) SRC="$U"; break ;; esac
done
if [ -z "$REMOTE" ]; then
  # No source answered. That is a network fact, not a clock fact, and the next
  # tick is 30 minutes away — a log line, never an alert.
  say "clock-sync: no time source answered ($SOURCES) — clock left alone"
  exit 0
fi

NOW=$(date -u +%s)
OFF=$((REMOTE - NOW))
ABS=${OFF#-}
if [ "$ABS" -le "$TOL" ]; then
  say "clock-sync: offset=${OFF}s within ${TOL}s (source=$SRC) — no change"
  exit 0
fi

if date -u -s "@$REMOTE" >/dev/null 2>&1; then
  say "clock-sync: offset=$OFF set (source=$SRC)"
  exit 0
fi

# Denied. One line, once a day, naming what is needed and from whom.
MARK="$H/state/clock-sync-denied-$(date -u +%Y%m%d)"
say "clock-sync: offset=${OFF}s but 'date -s' was DENIED (no CAP_SYS_TIME) — clock unchanged"
if [ ! -f "$MARK" ]; then
  mkdir -p "$H/state" "$H/logs" 2>/dev/null; touch "$MARK" 2>/dev/null
  echo "$(STAMP) [clock-sync] this box's clock is ${OFF}s off real time (source=$SRC) and 'date -s' is DENIED — it has no CAP_SYS_TIME. NEEDED FROM OPERATOR/OPS: run the container with SYS_TIME, or install an NTP daemon on it. Until then this box hands out already-expired GitHub App tokens and every age/stale comparison it makes is wrong by ${OFF}s." >> "$ALERTS"
fi
exit 0
