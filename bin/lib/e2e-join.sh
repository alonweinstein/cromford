#!/bin/bash
# bin/lib/e2e-join.sh — the join-cap arithmetic and the bounded wait that goes
# with it, kept in their own file so they can be unit-tested without extracting
# a block out of a long script. Sourced, never executed.
#
#   E2E_JOIN_MAX_DEFAULT   seconds; the cap when E2E_JOIN_MAX_S says nothing usable
#   e2e_join_max           prints the effective cap. unset/blank -> the default;
#                          an all-digit value -> that value (0 means uncapped);
#                          anything else -> the default AND rc 2, so the caller
#                          can write the ALERT line. It never writes a log
#                          itself and it never refuses to answer.
#   e2e_wait_pid_capped    <pid> <max_s>: polls `kill -0` every 2 s. rc 0 once
#                          the pid is gone, rc 1 when it is still alive at the
#                          cap, max_s=0 polls until it is gone. It never kills
#                          the pid and it is NEVER a bare `wait`: the caller's
#                          shell owns a heartbeat child that never exits, so a
#                          bare wait would hang past any cap. Pass a pid the
#                          caller's own shell started — `kill -0` on someone
#                          else's process can fail with EPERM and read as gone.
E2E_JOIN_MAX_DEFAULT=600

e2e_join_max() {
  local v="${E2E_JOIN_MAX_S:-}"
  # Trim: an env file's trailing newline must not turn 600 into garbage.
  v="${v#"${v%%[![:space:]]*}"}"
  v="${v%"${v##*[![:space:]]}"}"
  case "$v" in
    '')       printf '%s\n' "$E2E_JOIN_MAX_DEFAULT"; return 0 ;;
    *[!0-9]*) printf '%s\n' "$E2E_JOIN_MAX_DEFAULT"; return 2 ;;
    *)        printf '%s\n' "$v"; return 0 ;;
  esac
}

e2e_wait_pid_capped() { # e2e_wait_pid_capped <pid> <max_s>
  local pid="${1:?pid}" max="${2:-0}" t0
  t0=$(date +%s)
  while kill -0 "$pid" 2>/dev/null; do
    if [ "$max" -gt 0 ] && [ $(( $(date +%s) - t0 )) -ge "$max" ]; then
      return 1
    fi
    sleep 2
  done
  return 0
}
