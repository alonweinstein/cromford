# shellcheck shell=bash
# tests/lib/lane-switch-fixture.sh — a scratch harness and a stub worker for
# proving a kill-switch reader answers through bin/lib/lane-switch.sh
# (BH-2410). Sourced, never executed; tests/*.sh does not glob tests/lib/.
#
# The caller has sourced tests/lib/scratch.sh (so $T and scratch_rm exist) and
# set DIR to the repo root, then sources this file:
#   . "$(dirname "$0")/lib/lane-switch-fixture.sh" || exit 1
#
#   lsf_setup <reader...>   H=$T/lsf/h with bin/lib, flags, state, logs and
#                           catalog/switches.d; copies lane-gate.sh,
#                           lane-switch.sh, every named repo-relative reader
#                           (kept at its own path, so its `$(dirname "$0")/lib`
#                           sources resolve) and the switch registry; writes the
#                           stub bin/jobs-client.sh. rc 1 when a reader is not
#                           in $DIR.
#   lsf_row <name> <value> [box]  adds the settings row switch.<name>[.<box>]
#   lsf_flag <name>               touches $H/flags/<name>
#   lsf_reset                     no rows, no calls, no flags, no settings
#                                 cache, no state/lane-gate/, no lane-gate.log
#   lsf_cases <name> <probe-fn> <on> <off>
#       the three standard cases, each from lsf_reset; the probe's stdout is
#       compared with the expected answer:
#         (i)   row 1, no file       -> <on>
#         (ii)  row 0 plus the file  -> <off>, and logs/lane-gate.log names
#                                       `flags/<name> ignored`
#         (iii) no row plus the file -> <on>
#       One `FAIL: lsf <name> (<case>): ...` line per failed case. rc 0 only
#       when all three pass, else the number of failed cases.
#
# The stub: `_jobs_req GET /api/settings` sets JOBS_HTTP=200 and prints
# {"settings":<$ROWS_FILE or []>}; UNREACHABLE=1 makes it return 1, and so
# does any other request. Every request is appended to $CALLS.

lsf_setup() {
  local r
  H="$T/lsf/h"
  ROWS_FILE="$T/lsf/rows.json"
  CALLS="$T/lsf/calls"
  mkdir -p "$H/bin/lib" "$H/flags" "$H/state" "$H/logs" "$H/catalog/switches.d" || return 1
  cp "$DIR/bin/lib/lane-gate.sh" "$DIR/bin/lib/lane-switch.sh" "$H/bin/lib/" || return 1
  for r in "$@"; do
    [ -f "$DIR/$r" ] || { echo "lsf_setup: no reader $r in $DIR" >&2; return 1; }
    mkdir -p "$H/$(dirname "$r")" && cp "$DIR/$r" "$H/$r" || return 1
  done
  cp "$DIR"/catalog/switches.d/*.json "$H/catalog/switches.d/" 2>/dev/null
  cat > "$H/bin/jobs-client.sh" <<'SH'
_jobs_req() {
  echo "$1 $2" >> "$CALLS"
  JOBS_HTTP=""
  [ "${UNREACHABLE:-}" = 1 ] && return 1
  case "$1 $2" in
    "GET /api/settings")
      JOBS_HTTP=200
      printf '{"settings":%s}' "$(cat "$ROWS_FILE" 2>/dev/null || echo '[]')" ;;
    *) return 1 ;;
  esac
}
SH
  lsf_reset
}

lsf_row() {
  local key="switch.$1"
  [ -n "${3:-}" ] && key="$key.$3"
  jq -c --arg k "$key" --arg v "$2" '. + [{key:$k,value:$v,actor:"api"}]' "$ROWS_FILE" > "$ROWS_FILE.new" \
    && mv "$ROWS_FILE.new" "$ROWS_FILE"
}

lsf_flag() { touch "$H/flags/$1"; }

lsf_reset() {
  local f
  printf '[]' > "$ROWS_FILE"
  : > "$CALLS"
  for f in "$H"/flags/* "$H/state/settings-cache.json" "$H/state/lane-gate" "$H/logs/lane-gate.log"; do
    [ -e "$f" ] && scratch_rm "$f"
  done
  return 0
}

# _lsf_probe <probe-fn> — the probe in a subshell, so HARNESS never lands in
# the caller's shell.
_lsf_probe() {
  (
    export HARNESS="$H" H ROWS_FILE CALLS UNREACHABLE="${UNREACHABLE:-}" \
           JOBS_BOX="${LSF_BOX:-hub-1}" LANE_GATE_NOW="${LANE_GATE_NOW:-}"
    "$1"
  ) 2>/dev/null
}

lsf_cases() {
  local name="$1" probe="$2" on="$3" off="$4" got fails=0
  lsf_reset; lsf_row "$name" 1
  got=$(_lsf_probe "$probe")
  [ "$got" = "$on" ] || { echo "FAIL: lsf $name (i): expected '$on', got '$got'"; fails=$((fails+1)); }

  lsf_reset; lsf_row "$name" 0; lsf_flag "$name"
  got=$(_lsf_probe "$probe")
  if [ "$got" != "$off" ]; then
    echo "FAIL: lsf $name (ii): expected '$off', got '$got'"; fails=$((fails+1))
  elif ! grep -qF "flags/$name ignored" "$H/logs/lane-gate.log" 2>/dev/null; then
    echo "FAIL: lsf $name (ii): expected 'flags/$name ignored' in logs/lane-gate.log, got none"; fails=$((fails+1))
  fi

  lsf_reset; lsf_flag "$name"
  got=$(_lsf_probe "$probe")
  [ "$got" = "$on" ] || { echo "FAIL: lsf $name (iii): expected '$on', got '$got'"; fails=$((fails+1)); }
  lsf_reset
  return "$fails"
}
