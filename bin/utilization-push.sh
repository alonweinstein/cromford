#!/bin/bash
# bin/utilization-push.sh — BH-4008 (BH-3988 tracer): the hourly utilization
# collector. Hub only, at :07 (cron/lanes/724-utilization-push.cron). For every
# fleet.conf project it builds one snapshot from the bin/lib/utilization/
# section-*.sh readers, classifies it with util_verdict (bin/lib/utilization.sh)
# and writes it with utilization_put to PUT /api/utilization, keyed by
# (project, the hour this run STARTED in), so a re-run in the same hour is an
# upsert and a run that crosses the hour still writes its start hour.
#
# One tick, under `flock -n locks/utilization-push.lock` (dedupe, never a wait):
#   1. the project list from bin/fleet-projects-or-alert.sh; an unreadable
#      fleet.conf is that helper's ALERTS line and rc 1, never zero rows.
#   2. per project, until the deadline (600 s after the start): every
#      util_section_* function. A section whose rc is not 0 or whose stdout is
#      not a JSON object is dropped and recorded as basis.<name>:"unmeasured";
#      the rest deep-merge into the payload. Projects past the deadline are
#      `deferred` and get NO row, not a partial or zero one (D12).
#   3. util_verdict, then utilization_put. rc 0 is written; anything else is
#      failed plus one `put failed project=<p>` line. The next hour retries.
# The lane exits 0 whatever the PUTs answered: a worker outage is in the log
# and in jobs-client's own alert, not in the cron exit.
#
# Summary line (logs/utilization-push.log): <ts> off | <ts> disabled |
#   <ts> busy | <ts> projects=N written=N failed=N deferred=N
#
# Knobs (settings rows through lane_env_apply; the literals are the documented
# fallbacks): UTIL_PUSH_ENABLED (${UTIL_PUSH_ENABLED:-1}, 0 = disabled) and
# UTIL_RETENTION_DAYS (${UTIL_RETENTION_DAYS:-35}, sent to the PUT, which
# clamps it to 7..90 and prunes the project's older rows).
# Test seam, honoured only under HARNESS_TEST_SANDBOX=1: UTIL_PUSH_DEADLINE_S
# (all digits) replaces the 600 s deadline.
#
# OFF: flags/lane-off-utilization-push (bin/harness-ctl.sh off utilization-push,
# read by lane_gate_or_exit), the utilization-push-off switch (settings row or
# flags/utilization-push-off, read by lane_switch, so it still stops the lane
# under LANE_GATE_DISABLE=1), or UTIL_PUSH_ENABLED=0.
# Registry: catalog/lanes.d/utilization-push.json.
# Doc: docs/notes/2026-10-03-BH-3988-utilization-tracer.md.
set -uo pipefail
H="${HARNESS:-/root/harness}"
SELF="$(cd "$(dirname "$0")" && pwd)"
. "$H/bin/lib/env-path.sh" 2>/dev/null || . "$SELF/lib/env-path.sh" 2>/dev/null \
  || harness_env_dir() { printf '%s\n' "${1:-$H}/env"; }
HENV=$(harness_env_dir "$H")
# shellcheck disable=SC1091
[ -r "$HENV/global.env" ] && { set -a; . "$HENV/global.env" 2>/dev/null; set +a; }

# shellcheck disable=SC1091
{
  . "$H/bin/lib/lane-gate.sh" 2>/dev/null || . "$SELF/lib/lane-gate.sh" 2>/dev/null || true
  . "$SELF/lib/lane-switch.sh" 2>/dev/null || true
  . "$SELF/jobs-client.sh" 2>/dev/null || true
}

command -v lane_gate_or_exit >/dev/null 2>&1 && lane_gate_or_exit utilization-push
command -v lane_env_apply >/dev/null 2>&1 && lane_env_apply utilization-push
command -v lane_switch >/dev/null 2>&1 || lane_switch() { [ -f "$H/flags/$1" ]; }

mkdir -p "$H/logs" 2>/dev/null
LOG="$H/logs/utilization-push.log"
summary() { printf '%s%s\n' "$(date -u +%FT%TZ)" "${1:+ $1}" >> "$LOG"; }

if lane_switch utilization-push-off file; then summary off; exit 0; fi
[ "${UTIL_PUSH_ENABLED:-1}" = 0 ] && { summary disabled; exit 0; }
mkdir -p "$H/locks" 2>/dev/null
exec 9>"$H/locks/utilization-push.lock"
flock -n 9 || { summary busy; exit 0; }

HOUR=$(date -u +%Y-%m-%dT%H:00:00Z)
DEADLINE_S=600
[ "${HARNESS_TEST_SANDBOX:-}" = 1 ] && [[ "${UTIL_PUSH_DEADLINE_S:-}" =~ ^[0-9]+$ ]] && DEADLINE_S=$UTIL_PUSH_DEADLINE_S
DEADLINE=$(( $(date +%s) + DEADLINE_S ))
RETENTION="${UTIL_RETENTION_DAYS:-35}"

PROJECTS=$("$H/bin/fleet-projects-or-alert.sh" utilization-push) || exit 1

# shellcheck disable=SC1090,SC1091
{
  . "$SELF/lib/utilization.sh" 2>/dev/null || true
  while IFS= read -r _f; do . "$_f" 2>/dev/null || true; done \
    < <(LC_ALL=C ls -1 "$SELF"/lib/utilization/section-*.sh 2>/dev/null | LC_ALL=C sort)
  unset _f
}
command -v util_verdict >/dev/null 2>&1 || util_verdict() { printf 'unknown\tverdict lib did not load\n'; }
SECTIONS=$(declare -F | awk '{print $3}' | grep '^util_section_' | LC_ALL=C sort)

n=0 written=0 failed=0 deferred=0
for p in $PROJECTS; do
  n=$((n+1))
  if [ "$(date +%s)" -ge "$DEADLINE" ]; then deferred=$((deferred+1)); continue; fi
  frags=()
  for fn in $SECTIONS; do
    out=$("$fn" "$p" 2>/dev/null); rc=$?
    if [ "$rc" = 0 ] && printf '%s' "$out" | jq -e 'type == "object"' >/dev/null 2>&1; then
      frags+=("$out")
    else
      frags+=("$(jq -nc --arg s "${fn#util_section_}" '{basis:{($s):"unmeasured"}}')")
    fi
  done
  payload=$(printf '%s\n' "${frags[@]+"${frags[@]}"}" | jq -cs 'reduce .[] as $x ({}; . * $x)' 2>/dev/null)
  [ -n "$payload" ] || payload='{}'
  IFS=$'\t' read -r verdict _why <<< "$(util_verdict "$payload")"
  if utilization_put "$p" "$HOUR" "${verdict:-unknown}" "$payload" "$RETENTION" 2>/dev/null; then
    written=$((written+1))
  else
    failed=$((failed+1))
    summary "put failed project=$p"
  fi
done

summary "projects=$n written=$written failed=$failed deferred=$deferred"
exit 0
