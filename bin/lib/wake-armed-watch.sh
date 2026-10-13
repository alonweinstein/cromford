#!/bin/bash
# bin/lib/wake-armed-watch.sh — BH-4060: is an armed wake class actually being
# driven? Sourced by bin/pipeline-health.sh, never run; no side effects on source.
#
# bin/wake-loop.sh writes `<stamp> wake classes armed: <class>...` to
# logs/wake-loop.log on every invocation where flag_active says at least one
# `wake-lanes-<class>` flag is on (and flags/wake-lanes-off is absent). A class
# flag that is on while that line has gone quiet means the operator armed a
# class and nothing is driving it. This file only DECIDES; the alert, its key
# and its retraction live in pipeline-health's `wake classes armed` block.
#
# wake_armed_watch_eval <window_s> [now_epoch] — prints exactly one line:
#   SKIP off                       window is 0
#   SKIP killswitch                switch wake-lanes-off (row, else the file): the
#                                  line is absent on purpose
#   SKIP loop-off                  switch wake-loop-off, or lane_paused wake-loop
#                                  (all-off, lane-off-wake-loop):
#                                  the loop is stopped on purpose
#   SKIP unknown                   flag_active or lane_switch unavailable: unclear
#                                  is not clear
#   NONE                           no class flag is active
#   OK <age_s> <classes>           a class is active and the newest armed line is
#                                  younger than the window
#   FIRE <age_s|never> <classes>   a class is active and the armed line is missing,
#                                  older than the window, or carries a stamp that
#                                  will not parse (never "fresh" on a garbled stamp)
# The class list is the wake-class-*.sh files under bin/lib, the loader
# bin/wake-loop.sh uses, so a class added later is watched with no list to keep.
# rc 1, nothing printed, when the root is unset or the window is not a number.

wake_armed_watch_eval() {
  local win="${1:-}" now="${2:-}" root="${HARNESS:-${H:-}}"
  local f c classes="" line stamp ts age
  [ -n "$root" ] || return 1
  case "$win" in ''|*[!0-9]*) return 1 ;; esac
  [ -n "$now" ] || now=$(date +%s)
  case "$now" in *[!0-9]*) return 1 ;; esac
  [ "$win" -eq 0 ] && { echo "SKIP off"; return 0; }
  # The two kill switches are read by lane_switch in file mode, as
  # bin/lib/wake-lanes.sh reads wake-lanes-off: a settings row answers first and
  # the file only when there is no row. ls_isolated keeps a half-synced
  # jobs-client from taking this shell down. No lane_switch at all is UNKNOWN.
  if ! command -v lane_switch >/dev/null 2>&1; then
    # shellcheck source=bin/lib/lane-switch.sh
    [ -r "$root/bin/lib/lane-switch.sh" ] && . "$root/bin/lib/lane-switch.sh" >/dev/null 2>&1
  fi
  command -v ls_isolated >/dev/null 2>&1 || { echo "SKIP unknown"; return 0; }
  HARNESS="$root" ls_isolated lane_switch wake-lanes-off file && { echo "SKIP killswitch"; return 0; }
  # lane_paused is the read lane_gate_or_exit makes at the top of
  # bin/wake-loop.sh (all-off, lane-off-wake-loop), in a subshell for the same
  # reason as ls_isolated.
  { HARNESS="$root" ls_isolated lane_switch wake-loop-off file \
    || ( HARNESS="$root" lane_paused wake-loop >/dev/null 2>&1 ); } \
    && { echo "SKIP loop-off"; return 0; }
  command -v flag_active >/dev/null 2>&1 || { echo "SKIP unknown"; return 0; }
  for f in "$root"/bin/lib/wake-class-*.sh; do
    [ -r "$f" ] || continue
    c=${f##*/wake-class-}; c=${c%.sh}
    flag_active "wake-lanes-$c" >/dev/null 2>&1 && classes="${classes:+$classes,}$c"
  done
  [ -n "$classes" ] || { echo "NONE"; return 0; }
  # Anchored on the stamp say() writes, so a line that merely quotes the phrase
  # (a logged grep result, say) is not taken for the loop's own.
  line=$(grep -aE '^[0-9]{4}-[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2}:[0-9]{2}Z wake classes armed:' \
    "$root/logs/wake-loop.log" 2>/dev/null | tail -n 1)
  stamp=${line:0:20}
  ts=""
  case "$stamp" in
    [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]\ [0-9][0-9]:[0-9][0-9]:[0-9][0-9]Z)
      ts=$(date -u -d "${stamp% *}T${stamp#* }" +%s 2>/dev/null) || ts="" ;; # determinism: ok the case above admits only YYYY-MM-DD HH:MM:SSZ
  esac
  [ -n "$ts" ] || { echo "FIRE never $classes"; return 0; }
  age=$(( now - ts ))
  [ "$age" -lt 0 ] && age=0
  if [ "$age" -ge "$win" ]; then echo "FIRE $age $classes"; else echo "OK $age $classes"; fi
  return 0
}
