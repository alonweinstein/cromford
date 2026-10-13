#!/bin/bash
# bin/lib/scheduler-conf.sh — the knobs the file-overlap scheduler turns.
# Sourced, never executed. Safe under `set -u`.
#
# WHY A FILE AND NOT CONSTANTS (the operator's iron law: every threshold is a config
# value). The lanes that read these numbers — bin/overlap-guard.sh at launch
# time, bin/overlap-schedule.sh at plan time (BH-475), and
# bin/rebase-train-ahead.sh at merge time — have to agree on them, and
# an operator whose repo is starving at 3am must be able to widen the threshold
# without editing a script the fleet render would overwrite five minutes later.
# flags/ is machine-local and gitignored, which is exactly right for a number a
# box tunes for itself; the DEFAULTS live here and are documented in
# docs/SCHEDULER.md, so a box with no flags/scheduler.conf behaves the way the
# doc says.
#
# Resolution order, the same one bin/lib/preplan-lib.sh:_preplan_env uses, with
# the settings row (BH-2411, bin/lib/conf-row.sh) directly above the file:
#   environment  ->  settings conf.scheduler.<var lowercased>[.<box>]
#                ->  flags/scheduler.conf  ->  the documented default
# A row the knob's own validator refuses (a non-number for sched_num, a value
# above 1 for sched_frac) is logged and read as no row, so the file answers.
# The file is READ, never sourced: it is edited by hand from a console and a
# stray backtick in it must not execute inside a lane that holds a token.
#
# Format — one KEY=VALUE per line, `#` comments, quotes optional:
#   OVERLAP_THRESHOLD=0
#   OVERLAP_IGNORE=package.json *.md package-lock.json
#   REBASE_TRAIN_MAX=3

# shellcheck source=conf-row.sh
. "$(dirname "${BASH_SOURCE[0]}")/conf-row.sh" 2>/dev/null || true

# sched_conf <VAR> <default> [harness] -> the value, one line
sched_conf() { _sched_pick "${1:-}" "${2:-}" "${3:-}" _sched_any; }

# _sched_pick <VAR> <default> <harness> <validator> — the resolution order above.
#   A settings row the knob's validator refuses is NO row (BH-2478): it is
#   logged and flags/scheduler.conf answers, the way cost-caps and lane-caps
#   treat a row they cannot parse. The environment is taken as it stands.
_sched_pick() {
  local var="${1:-}" def="${2:-}" h="${3:-${HARNESS:-/root/harness}}" valid="${4:-_sched_any}" v="" k
  [ -n "$var" ] || return 1
  eval "v=\${$var:-}"
  if [ -z "$v" ] && command -v conf_row >/dev/null 2>&1; then
    k="${var,,}"
    if v=$(conf_row scheduler "$k" "$h") && [ -n "$v" ]; then
      if "$valid" "$v"; then
        conf_row_note_file scheduler "$h/flags/scheduler.conf" "$k"
      else
        conf_row_refused scheduler "$k" "$v" "$h/flags/scheduler.conf" "$h"
        v=""
      fi
    else
      v=""
    fi
  fi
  if [ -z "$v" ] && [ -r "$h/flags/scheduler.conf" ]; then
    v=$(sed -n "s/^[[:space:]]*\(export[[:space:]]\{1,\}\)\{0,1\}$var=//p" "$h/flags/scheduler.conf" \
        | sed 's/[[:space:]]*#.*$//; s/^["'"'"']//; s/["'"'"']$//; s/[[:space:]]*$//' | tail -1)
  fi
  [ -n "$v" ] || v="$def"
  printf '%s\n' "$v"
}

_sched_any() { [ -n "${1:-}" ]; }
_sched_is_num() { case "${1:-}" in ''|*[!0-9]*) return 1 ;; esac; return 0; }
_sched_is_frac() {
  case "${1:-}" in ''|*[!0-9.]*|*.*.*) return 1 ;; esac
  awk -v x="$1" 'BEGIN{ exit !(x+0 <= 1) }'
}

# sched_num <VAR> <default> [harness] -> a NON-NEGATIVE INTEGER, always
#   A knob nobody can parse falls back to its documented default rather than to
#   "unlimited" or to 0 — an unreadable ceiling that reads as "no ceiling" is
#   how a cap silently stops capping.
sched_num() {
  local v; v=$(_sched_pick "$1" "$2" "${3:-}" _sched_is_num)
  _sched_is_num "$v" || v="$2"
  printf '%s\n' "$v"
}

# sched_frac <VAR> <default> [harness] -> a decimal in [0,1], always
#   Used for the Jaccard threshold. Anything that is not a plain decimal — and
#   anything above 1, which could never fire — falls back to the default.
sched_frac() {
  local v; v=$(_sched_pick "$1" "$2" "${3:-}" _sched_is_frac)
  case "$v" in ''|*[!0-9.]*|*.*.*) v="$2" ;; esac
  awk -v x="$v" -v d="$2" 'BEGIN{ if (x=="" || x+0>1) x=d; printf "%.4f\n", x+0 }'
}
