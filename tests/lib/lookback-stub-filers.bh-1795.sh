#!/bin/bash
# tests/lib/lookback-stub-filers.bh-1795.sh — stand-ins for the functions the
# BH-1795 sibling slices define (lookback_cluster_run, lookback_file_harness,
# lookback_file_board). Sourced, never executed. tests/lookback-lane.bh-1795-test.sh
# copies this file into a scratch $HARNESS as bin/lib/lookback-file.sh, the path
# bin/lookback.sh really sources, so the driver finds these with `declare -F`
# exactly as it will find the real ones.
#
# Every call appends one line to $LOOKBACK_STUB_CALLS:
#   cluster <bundle> <out>
#   harness <fingerprint> <run_dir>
#   board <fingerprint> <run_dir>
# STUB_CLUSTER_RC   rc of lookback_cluster_run (0 writes `[]` to <out>).
# STUB_FILE_RCS     space-separated rcs, one per filer call in order; past the
#                   end of the list a filer returns 0.

lookback_cluster_run() {
  printf 'cluster %s %s\n' "$1" "$2" >> "$LOOKBACK_STUB_CALLS"
  local rc="${STUB_CLUSTER_RC:-0}"
  [ "$rc" = 0 ] && printf '[]\n' > "$2"
  return "$rc"
}

_lookback_stub_file() { # _lookback_stub_file <kind> <cluster_json> <run_dir>
  local n rc fp
  n=$(grep -cE '^(harness|board) ' "$LOOKBACK_STUB_CALLS" 2>/dev/null) || n=0
  fp=$(printf '%s' "$2" | jq -r '.fingerprint')
  printf '%s %s %s\n' "$1" "$fp" "$3" >> "$LOOKBACK_STUB_CALLS"
  # shellcheck disable=SC2086
  set -- ${STUB_FILE_RCS:-}
  if [ "$n" -lt "$#" ]; then shift "$n"; else set --; fi
  rc="${1:-0}"
  printf 'stub %s rc=%s\n' "$fp" "$rc"
  return "$rc"
}
lookback_file_harness() { _lookback_stub_file harness "$@"; }
lookback_file_board()   { _lookback_stub_file board "$@"; }
