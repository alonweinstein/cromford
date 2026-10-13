# shellcheck shell=bash
# tests/lib/wait-for.sh — bounded readiness polls for suites (BH-6049).
#
# A fixed `sleep 0.5` before the step under test is a bet that a background
# lock holder or child process got there first. On a loaded or traced CI shard
# the bet loses, and the suite goes red on timing, not code. These helpers wait
# for the fact itself, up to a bound, and say so on stderr when it never came
# (the assertion after them then fails on the real cause).
#
#   wait_for <timeout_s> <cmd...>          run cmd every 0.1 s until it succeeds
#   wait_holder <pid> [timeout_s]          until a background lock holder holds its
#                                          lock: it (or its child or grandchild) has
#                                          reached the `sleep` it runs after flock
#   wait_file <path> [timeout_s]           until the path exists
#   clear_boundary <period_s> <margin_s>   if a UTC period boundary (60 minute,
#                                          3600 hour, 86400 day) is under margin_s
#                                          away, sleep past it first
#
# Source it with a same-line handler:  . "$(dirname "$0")/lib/wait-for.sh" || exit 1
wait_for() {
  local t="$1" i n
  shift
  n=$(( t * 10 ))
  for (( i = 0; i < n; i++ )); do
    "$@" && return 0
    sleep 0.1
  done
  "$@" && return 0
  echo "wait-for: timed out after ${t}s: $*" >&2
  return 1
}
# Why not probe the lock itself: `flock -n <file> true` takes the lock for an
# instant, so a holder that uses `flock -n` can lose to the probe and never hold
# it; and /proc/locks is empty inside Docker Desktop. A holder runs its `sleep`
# only once flock succeeded (`( …; flock 9; exec sleep N )`, `flock <f> sleep N`,
# `flock <f> -c 'sleep N'`), so the sleep process is the readiness fact. A holder
# must therefore not run `sleep` BEFORE its flock.
_wf_is_sleep() { [ "$(cat "/proc/$1/comm" 2>/dev/null)" = sleep ]; }
_wf_holder_ready() {
  local c g
  [ -r "/proc/$1/comm" ] || return 1
  _wf_is_sleep "$1" && return 0
  for c in $(pgrep -P "$1" 2>/dev/null); do
    _wf_is_sleep "$c" && return 0
    for g in $(pgrep -P "$c" 2>/dev/null); do _wf_is_sleep "$g" && return 0; done
  done
  return 1
}
wait_holder() {
  # No /proc or no pgrep (macOS): the old fixed wait is the only signal left.
  if [ ! -r /proc/self/comm ] || ! command -v pgrep >/dev/null 2>&1; then sleep 0.5; return 0; fi
  wait_for "${2:-10}" _wf_holder_ready "$1"
}
wait_file() { wait_for "${2:-10}" test -e "$1"; }
# A case that reads the clock twice (the code stamps its own hour, the suite
# recomputes it to assert) must not straddle the boundary. The code under test
# has no clock knob, so the suite steps around the boundary instead.
clear_boundary() {
  local p="$1" m="$2" now left
  now=$(date -u +%s)
  left=$(( p - now % p ))
  if [ "$left" -le "$m" ]; then sleep $(( left + 1 )); fi
  return 0
}
