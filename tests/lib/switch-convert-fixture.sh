# tests/lib/switch-convert-fixture.sh — the scratch harness every BH-2408 slice
# drives a converted kill switch in (BH-2440). Sourced, never executed; not a
# suite. Lifted from the setup block of tests/lane-switch.bh-2320-test.sh.
#
#   sc_harness <root>             build <root>/{bin/lib,flags,state,logs,
#                                 catalog/switches.d}, copy bin/lib/lane-gate.sh,
#                                 bin/lib/lane-switch.sh and the rendered
#                                 catalog/lanes.json, install the stub
#                                 bin/jobs-client.sh; sets SC_ROOT=<root>
#   sc_rows k=v ...               write the settings table to $ROWS_FILE
#                                 (no args = no rows; an arg with no `=` is rc 2)
#   sc_seed_cache k=v ...         write $SC_ROOT/state/settings-cache.json, the
#                                 shape _lg_settings_refresh writes, stamped
#                                 ${SC_CACHE_AT:-0} so it is stale and answers
#                                 only when the worker does not (outage cases)
#   sc_ignored_lines <root> <n>   print how many `flags/<n> ignored` lines
#                                 <root>/logs/lane-gate.log holds (0 with no log)
#   sc_trace <trace> <script> [args]  run <script> under bash -x with
#                                 PS4='+${LINENO}: ', trace to <trace>; returns
#                                 the script's rc. Use this, not an inline
#                                 `PS4=... bash -x`: bash ignores an inherited PS4
#                                 when it runs as root, so on the hub that trace
#                                 has no line numbers at all
#   sc_trace_past <trace> <line>  rc 0 if a `+<LINENO>:` line of that trace is
#                                 past <line>, rc 1 if none is, rc 2 when the
#                                 trace is missing/empty or <line> is not an
#                                 integer — compare the rc against 1, never test
#                                 it as a bool
#   sc_stub_path <dir>            put record-and-fail gh, curl and claude on PATH;
#                                 each appends `<name> <args>` to <dir>/calls.log
#
# The stub worker serves $ROWS_FILE on GET /api/settings, appends every request
# to $CALLS, returns 1 when UNREACHABLE is set, and defines flag_active only
# when STUB_FLAG_ACTIVE=1. Defaults, exported so the scripts a suite runs see
# them: JOBS_BOX=hub-1, HARNESS_TEST_SANDBOX=1, ROWS_FILE=$T/rows.json,
# CALLS=$T/calls. scratch.sh is sourced only when this shell has no scratch
# tree yet: re-sourcing it deletes the caller's $T.
# shellcheck shell=bash

_SC_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd) || return 1
: "${DIR:=$_SC_DIR}"
: "${HARNESS_TEST_SANDBOX:=1}"; export HARNESS_TEST_SANDBOX
if [ -z "${SCRATCH:-}" ]; then . "$(dirname "${BASH_SOURCE[0]}")/scratch.sh" || return 1; fi
. "$(dirname "${BASH_SOURCE[0]}")/rendered.sh" || return 1
export JOBS_BOX="${JOBS_BOX:-hub-1}"
export ROWS_FILE="${ROWS_FILE:-$T/rows.json}"
export CALLS="${CALLS:-$T/calls}"
: > "$CALLS"

sc_harness() {
  local r="${1:?sc_harness <root>}" f
  mkdir -p "$r/bin/lib" "$r/flags" "$r/state" "$r/logs" "$r/catalog/switches.d" || return 1
  for f in lane-gate.sh lane-switch.sh; do
    cp "$_SC_DIR/bin/lib/$f" "$r/bin/lib/" \
      || { echo "sc_harness: cannot copy bin/lib/$f" >&2; return 1; }
  done
  cp "$(rendered_registry)" "$r/catalog/lanes.json" || return 1
  cat > "$r/bin/jobs-client.sh" <<'SH' || return 1
_jobs_req() {
  echo "$1 $2" >> "$CALLS"
  [ -n "${UNREACHABLE:-}" ] && return 1
  case "$2" in
    /api/settings) printf '{"settings":%s}' "$(cat "$ROWS_FILE" 2>/dev/null || echo '[]')" ;;
    *) return 1 ;;
  esac
}
if [ "${STUB_FLAG_ACTIVE:-}" = 1 ]; then
  flag_active() { echo "FLAG_ACTIVE $1" >> "$CALLS"; [ -f "$HARNESS/flags/$1" ]; }
  # BH-2412: lane_switch's no-row flag step no longer calls flag_active; it reads
  # the pause_flags row itself (GET /api/flags/<name>, logged by _jobs_req) and
  # needs _flag_epoch, which the real client defines beside flag_active.
  _flag_epoch() { date -u -d "$1" +%s 2>/dev/null; }
fi
SH
  export SC_ROOT="$r"
}

# _sc_kv_json rows|obj k=v ... — the settings rows array, or the cache's
# {k: v} object; rc 2 on an argument with no `=`.
_sc_kv_json() {
  local shape="$1" out='[]' kv; shift
  [ "$shape" = obj ] && out='{}'
  for kv in "$@"; do
    case "$kv" in *=*) ;; *) echo "switch-convert-fixture: '$kv' is not k=v" >&2; return 2 ;; esac
    if [ "$shape" = obj ]; then
      out=$(jq -c --arg k "${kv%%=*}" --arg v "${kv#*=}" '.[$k] = $v' <<<"$out") || return 1
    else
      out=$(jq -c --arg k "${kv%%=*}" --arg v "${kv#*=}" '. + [{key:$k,value:$v,actor:"api"}]' <<<"$out") || return 1
    fi
  done
  printf '%s' "$out"
}

sc_rows() {
  local out
  out=$(_sc_kv_json rows "$@") || return $?
  printf '%s' "$out" > "$ROWS_FILE"
}

sc_seed_cache() {
  [ -n "${SC_ROOT:-}" ] || { echo "sc_seed_cache: no SC_ROOT (call sc_harness first)" >&2; return 1; }
  local vals
  vals=$(_sc_kv_json obj "$@") || return $?
  mkdir -p "$SC_ROOT/state" || return 1
  jq -cn --argjson fa "${SC_CACHE_AT:-0}" --argjson v "$vals" \
    '{fetched_at:$fa, values:$v, seeded:{}}' > "$SC_ROOT/state/settings-cache.json"
}

sc_ignored_lines() {
  local log="$1/logs/lane-gate.log" n
  [ -f "$log" ] || { echo 0; return 0; }
  n=$(grep -cF "flags/$2 ignored" "$log") || n=0
  echo "$n"
}

sc_trace() {
  local trace="${1:?sc_trace <trace> <script> [args]}"; shift
  printf '%s\n' "PS4='+\${LINENO}: '" > "$T/.sc-ps4" || return 1
  BASH_ENV="$T/.sc-ps4" bash -x "$@" 2> "$trace"
}

sc_trace_past() {
  local trace="$1" line="$2"
  case "$line" in ''|*[!0-9]*) echo "sc_trace_past: line '$line' is not an integer" >&2; return 2 ;; esac
  [ -s "$trace" ] || { echo "sc_trace_past: no trace at $trace" >&2; return 2; }
  grep -oE '^\++[0-9]+:' "$trace" | tr -d '+:' \
    | awk -v l="$line" '$1 + 0 > l + 0 { f = 1 } END { exit f ? 0 : 1 }'
}

sc_stub_path() {
  local d="${1:?sc_stub_path <dir>}" n
  mkdir -p "$d" || return 1
  for n in gh curl claude; do
    printf '#!/bin/bash\necho "%s $*" >> "%s/calls.log"\nexit 1\n' "$n" "$d" > "$d/$n" || return 1
    chmod +x "$d/$n" || return 1
  done
  export PATH="$d:$PATH"
}
