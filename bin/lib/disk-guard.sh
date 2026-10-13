# bin/lib/disk-guard.sh — the root disk reading and the two thresholds behind
# BH-1123: alert at DISK_ALERT_PCT (default 85), refuse to START a build at
# DISK_BUILD_REFUSE_PCT (default 92). Both are knobs on the `disk-guard` lane
# (catalog/lanes.d/disk-guard.json), resolved through lane_knob: a settings row,
# else the env, else the registry default, else the literal here.
#
# Readers: bin/disk-guard.sh (the */10 lane that alerts) and the
# `# >>> disk gate` block in bin/run-build.sh (the build refusal).
#
# UNREADABLE IS UNKNOWN, NEVER 0% AND NEVER FULL. A df that fails, prints `-`
# or prints no data row gives no reading: the lane logs it and alerts nothing,
# and the build gate FAILS OPEN. A broken probe must not stop the fleet.
#
# Sourcing has no side effects beyond defining functions.
# shellcheck shell=bash

_DG_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)

# disk_used_pct [path] — Use% of the filesystem holding path (default /), as a
# whole number. Prints nothing when there is no reading. Same `df -P /` shape
# bin/fleet-status-push.sh reports as the hub's disk, so the numbers agree.
disk_used_pct() {
  local out v
  out=$(df -P "${1:-/}" 2>/dev/null) || return 0
  v=$(printf '%s\n' "$out" | awk 'NR==2{gsub(/%/,"",$5); print $5; exit}')
  case "$v" in ''|*[!0-9]*) return 0 ;; esac
  v=$((10#$v))
  [ "$v" -le 100 ] || return 0
  printf '%s' "$v"
}

# disk_free_mb [path] — Available on that filesystem in MB, or nothing.
disk_free_mb() {
  local out v
  out=$(df -Pk "${1:-/}" 2>/dev/null) || return 0
  v=$(printf '%s\n' "$out" | awk 'NR==2{print $4; exit}')
  case "$v" in ''|*[!0-9]*) return 0 ;; esac
  printf '%s' "$(( v / 1024 ))"
}

# disk_guard_knob <ENV> <fallback> — a threshold in percent, 1..100. Anything
# else the resolver answers (abc, 0, 150) is ignored and the fallback used: a
# threshold of 0% would refuse every build on the box.
disk_guard_knob() {
  local v="" _lg
  if ! command -v lane_knob >/dev/null 2>&1; then
    for _lg in "${HARNESS:-/root/harness}/bin/lib/lane-gate.sh" "$_DG_DIR/lane-gate.sh"; do
      # shellcheck source=/dev/null
      [ -r "$_lg" ] && . "$_lg" 2>/dev/null && break
    done
  fi
  command -v lane_knob >/dev/null 2>&1 && v=$(lane_knob disk-guard "$1" 2>/dev/null)
  [ -n "$v" ] || v="${!1:-}"
  case "$v" in ''|*[!0-9]*) v="$2" ;; esac
  v=$((10#$v))
  { [ "$v" -ge 1 ] && [ "$v" -le 100 ]; } || v="$2"
  printf '%s' "$v"
}

# disk_build_refuse_reason — rc 0 and the reason on stdout when / is at or
# over DISK_BUILD_REFUSE_PCT; rc 1 and nothing when it is under, or when there
# is no reading.
disk_build_refuse_reason() {
  local pct refuse free
  pct=$(disk_used_pct /)
  [ -n "$pct" ] || return 1
  refuse=$(disk_guard_knob DISK_BUILD_REFUSE_PCT 92)
  [ "$pct" -ge "$refuse" ] || return 1
  free=$(disk_free_mb /)
  printf 'disk / at %s%% on %s (builds refused at %s%%, knob disk-guard DISK_BUILD_REFUSE_PCT); %s MB free' \
    "$pct" "$(hostname)" "$refuse" "${free:-?}"
  return 0
}
