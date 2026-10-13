#!/bin/bash
# bin/queue-rows-flip-preflight.sh — BH-2338 (BH-2313.0): the preflight each
# queue-row knob waits on before an operator sets it to 1. One block per gate:
#
#   gate      knob
#   build     build_queue_rows_only
#   merge     merge_queue_rows_only
#   deploy    deploy_queue_rows
#   ready     ready_queue_rows
#   closeout  closeout_aged_table
#
# For each gate it (1) reads the knob row with a raw GET /api/settings/<knob>
# (a 404 is a FAIL, never "0"), (2) sources bin/lib/qrf/<gate>.sh and runs
# qrf_gate_<gate>, the gate's own checks, (3) prints the rollback command and
# (4) prints `RESULT: READY <gate>` or `RESULT: NOT READY <gate> (...)`.
#
# The gate modules use these helpers: qrf_pass <msg>, qrf_fail <gate> <msg>,
# qrf_info <msg>, qrf_get <route> <outfile> (sets QRF_HTTP, returns _jobs_req's
# rc) and qrf_list <gate> <route> <jq-array-path> <limit> <outfile> (FAIL on a
# non-2xx, a non-array or rows = limit). QRF_H, QRF_STATE and QRF_TMP (the
# scratch outfile) are exported to them.
#
# STRICTLY READ-ONLY. GETs only, never a PUT or POST, and nothing under
# $HARNESS is written. The knob readers (build_queue_rows_only_on and kin) are
# never called; the rows are read raw. JOBS_ALERT=0 keeps a failed probe off
# flags/, and the client's log line goes to stderr instead of
# logs/jobs-client.log. An empty JOBS_URL stops before any request, because the
# client's not-configured path writes flags/ and logs/. The only file it
# creates is its own mktemp under $TMPDIR, removed on exit.
#
# Usage: HARNESS=/root/harness bin/queue-rows-flip-preflight.sh [build|merge|deploy|ready|closeout ...]
#        (no gate = all five, in that order; a gate named twice runs once)
# Exit:  0 every requested gate READY, 1 any gate NOT READY,
#        2 usage error, no jobs client, or no coordination DB configured.
set -uo pipefail
H="${HARNESS:-/root/harness}"
QRF_H="$H"; QRF_STATE="$H/state"
export QRF_H QRF_STATE
export JOBS_ALERT=0 BUILD_QUEUE_ROWS_ONLY=0 MERGE_QUEUE_ROWS_ONLY=0 DEPLOY_QUEUE_ROWS=0 READY_QUEUE_ROWS=0 CLOSEOUT_AGED_TABLE=0

usage() { echo "usage: HARNESS=/root/harness bin/queue-rows-flip-preflight.sh [build|merge|deploy|ready|closeout ...]" >&2; exit 2; }
knob_of() {
  case "$1" in
    build)    echo build_queue_rows_only ;;
    merge)    echo merge_queue_rows_only ;;
    deploy)   echo deploy_queue_rows ;;
    ready)    echo ready_queue_rows ;;
    closeout) echo closeout_aged_table ;;
    *) return 1 ;;
  esac
}

# Arguments first: a bad word costs no request.
GATES=()
[ "$#" -gt 0 ] || set -- build merge deploy ready closeout
for a in "$@"; do
  knob_of "$a" >/dev/null || usage
  case " ${GATES[*]} " in *" $a "*) ;; *) GATES+=("$a") ;; esac
done

# shellcheck source=/dev/null
{ [ -r "$H/bin/jobs-client.sh" ] && [ -d "$H/bin/lib/jobs" ] && . "$H/bin/jobs-client.sh"; } \
  || { echo "queue-rows-flip-preflight: no jobs client under $H/bin — cannot probe" >&2; exit 2; }
command -v _jobs_req >/dev/null 2>&1 || { echo "queue-rows-flip-preflight: the client has no _jobs_req" >&2; exit 2; }
jobs_configured || { echo "queue-rows-flip-preflight: coordination DB not configured (JOBS_URL empty) — cannot probe" >&2; exit 2; }
# The client's own log line goes to stderr, not to logs/jobs-client.log.
_jobs_log() { printf 'queue-rows-flip-preflight: jobs-client: %s\n' "$*" >&2; }

QF=$(mktemp "${TMPDIR:-/tmp}/qrf.XXXXXX") || { echo "queue-rows-flip-preflight: mktemp failed" >&2; exit 2; }
trap 'rm -f -- "$QF"' EXIT
export QRF_TMP="$QF"

declare -A QRF_FAILS=()
qrf_pass() { echo "[PASS] $*"; }
qrf_fail() { local g="$1"; shift; echo "[FAIL] $g: $*"; QRF_FAILS[$g]=$(( ${QRF_FAILS[$g]:-0} + 1 )); }
qrf_info() { echo "  $*"; }
# Never inside $(...): JOBS_HTTP must survive into this shell.
qrf_get() { # qrf_get <route> <outfile>
  local rc
  _jobs_req GET "$1" > "$2"; rc=$?
  QRF_HTTP="${JOBS_HTTP:-none}"
  return "$rc"
}
qrf_list() { # qrf_list <gate> <route> <jq-array-path> <limit> <outfile>
  local g="$1" route="$2" path="$3" limit="$4" out="$5" n
  case "$limit" in ''|*[!0-9]*) qrf_fail "$g" "live probe $route: limit '$limit' is not a number"; return 1 ;; esac
  if ! qrf_get "$route" "$out" || ! jq -e "$path | type == \"array\"" "$out" >/dev/null 2>&1; then
    qrf_fail "$g" "live probe $route http=$QRF_HTTP"; return 1
  fi
  n=$(jq "$path | length" "$out")
  if [ "$n" -ge "$limit" ]; then
    qrf_fail "$g" "live probe $route incomplete: rows=$n = limit $limit"; return 1
  fi
  qrf_pass "live probe $route http=$QRF_HTTP rows=$n"
}

ALL_READY=1
for g in "${GATES[@]}"; do
  k=$(knob_of "$g")
  QRF_FAILS[$g]=0
  echo "== $g ($k) =="
  # 1. the knob row
  qrf_get "/api/settings/$k" "$QF"; rc=$?
  if [ "$rc" = 0 ]; then
    v=$(jq -r '.setting.value // empty' "$QF" 2>/dev/null)
    if [ -n "$v" ]; then qrf_info "knob: $k=$v"
    else qrf_fail "$g" "knob $k: row has no value"; fi
  elif [ "$rc" = 2 ]; then qrf_fail "$g" "knob $k: no settings row (schema/seed never applied)"
  else qrf_fail "$g" "knob $k: unreadable http=$QRF_HTTP"; fi
  # 2. the gate's own checks
  unset -f "qrf_gate_$g"
  mod="$H/bin/lib/qrf/$g.sh"
  # shellcheck source=/dev/null
  if [ -r "$mod" ] && . "$mod" && declare -F "qrf_gate_$g" >/dev/null; then "qrf_gate_$g"
  else qrf_fail "$g" "gate module bin/lib/qrf/$g.sh missing"; fi
  # 3. rollback, 4. result
  echo "rollback: bin/jobs-client.sh setting-set $k 0"
  n=${QRF_FAILS[$g]}
  if [ "$n" = 0 ]; then echo "RESULT: READY $g"
  else echo "RESULT: NOT READY $g ($n check(s) failed)"; ALL_READY=0; fi
done
[ "$ALL_READY" = 1 ]
