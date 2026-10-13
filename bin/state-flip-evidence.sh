#!/bin/bash
# bin/state-flip-evidence.sh — BH-5000 (BH-4951.1): the evidence an operator
# posts after flipping one dark DB path on the hub. One module per path under
# bin/lib/sfe/<path>.sh, found by FILENAME: a later path adds a file and never
# edits a list here.
#
# A module defines four functions, <p> being the path with '-' as '_':
#   sfe_flag_<p>            the flag or knob reads on
#   sfe_tick_<p> <epoch>    the lane's next tick since the flip read or wrote rows
#   sfe_parity_<p> <epoch>  the file and the rows agree for every open item
#                           that changed since the flip
#   sfe_rollback_<p>        prints the command that flips it back
# The runner calls the first three in that order under `== flag ==`,
# `== tick ==` and `== parity ==`, prints `rollback: <cmd>`, then
# `RESULT: GREEN <path>` or `RESULT: NOT GREEN <path> (<n> check(s) failed)`.
#
# Helpers for modules: sfe_pass <msg>, sfe_fail <check> <msg>, sfe_info <msg>,
# sfe_get <route> <outfile> (sets SFE_HTTP, returns _jobs_req's rc; never call
# it inside $(...), or SFE_HTTP dies with the subshell). SFE_H, SFE_SINCE (the
# --since text) and SFE_TMP (a scratch file) are exported to them.
#
# READ-ONLY, with one exception a module may take: `bin/jobs-client.sh
# flag-active <name>` runs flag_sync, which may create or remove flags/<name>.
# That is the same reconcile every lane tick does. Everything else is GETs.
# JOBS_ALERT=0 keeps a failed probe off flags/, and the client's log line goes
# to stderr. An empty JOBS_URL stops before any request.
#
# Usage: HARNESS=/root/harness bin/state-flip-evidence.sh <path> --since <YYYY-MM-DDTHH:MM[:SS]Z>
# Exit:  0 GREEN, 1 NOT GREEN, 2 usage error, unknown path, no jobs client or
#        no coordination DB configured.
set -uo pipefail
H="${HARNESS:-/root/harness}"
SFE_H="$H"
export SFE_H JOBS_ALERT=0

usage() {
  echo "usage: HARNESS=/root/harness bin/state-flip-evidence.sh <path> --since <YYYY-MM-DDTHH:MM[:SS]Z>" >&2
  echo "paths: $(cd "$H/bin/lib/sfe" 2>/dev/null && ls -- *.sh 2>/dev/null | sed 's/\.sh$//' | tr '\n' ' ')" >&2
  exit 2
}

# Arguments first: a bad word costs no request.
P="${1:-}"; shift || true
SFE_SINCE=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    --since) SFE_SINCE="${2:-}"; shift 2 || usage ;;
    *) usage ;;
  esac
done
[[ "$P" =~ ^[a-z0-9_-]+$ ]] || usage
MOD="$H/bin/lib/sfe/$P.sh"
[ -r "$MOD" ] || { echo "state-flip-evidence: no module bin/lib/sfe/$P.sh" >&2; usage; }
# The worker's ISO shape only: GNU date also takes "yesterday" and "".
[ -n "$SFE_SINCE" ] || { echo "state-flip-evidence: --since '$SFE_SINCE' is not YYYY-MM-DDTHH:MM[:SS]Z" >&2; usage; }
[[ "$SFE_SINCE" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}(:[0-9]{2}(\.[0-9]+)?)?Z$ ]] \
  || { echo "state-flip-evidence: --since '$SFE_SINCE' is not YYYY-MM-DDTHH:MM[:SS]Z" >&2; usage; }
SINCE_EPOCH=$(date -u -d "$SFE_SINCE" +%s 2>/dev/null) || SINCE_EPOCH=""
[ -n "$SINCE_EPOCH" ] || { echo "state-flip-evidence: --since '$SFE_SINCE' is not a real time" >&2; usage; }
export SFE_SINCE
F="${P//-/_}"
# shellcheck source=/dev/null
. "$MOD" || { echo "state-flip-evidence: bin/lib/sfe/$P.sh did not load" >&2; exit 2; }
for fn in "sfe_flag_$F" "sfe_tick_$F" "sfe_parity_$F" "sfe_rollback_$F"; do
  declare -F "$fn" >/dev/null || { echo "state-flip-evidence: bin/lib/sfe/$P.sh defines no $fn" >&2; exit 2; }
done

# shellcheck source=/dev/null
{ [ -r "$H/bin/jobs-client.sh" ] && [ -d "$H/bin/lib/jobs" ] && . "$H/bin/jobs-client.sh"; } \
  || { echo "state-flip-evidence: no jobs client under $H/bin — cannot probe" >&2; exit 2; }
command -v _jobs_req >/dev/null 2>&1 || { echo "state-flip-evidence: the client has no _jobs_req" >&2; exit 2; }
jobs_configured || { echo "state-flip-evidence: coordination DB not configured (JOBS_URL empty) — cannot probe" >&2; exit 2; }
_jobs_log() { printf 'state-flip-evidence: jobs-client: %s\n' "$*" >&2; }

SFE_TMP=$(mktemp "${TMPDIR:-/tmp}/sfe.XXXXXX") || { echo "state-flip-evidence: mktemp failed" >&2; exit 2; }
trap 'rm -f -- "$SFE_TMP"' EXIT
export SFE_TMP

SFE_FAILS=0
sfe_pass() { echo "[PASS] $*"; }
sfe_fail() { local c="$1"; shift; echo "[FAIL] $c: $*"; SFE_FAILS=$((SFE_FAILS + 1)); }
sfe_info() { echo "  $*"; }
sfe_get() { # sfe_get <route> <outfile>
  local rc
  _jobs_req GET "$1" > "$2"; rc=$?
  SFE_HTTP="${JOBS_HTTP:-none}"
  return "$rc"
}

echo "state-flip-evidence $P since $SFE_SINCE (host $(hostname 2>/dev/null || echo ?))"
echo "== flag =="
"sfe_flag_$F"
echo "== tick =="
"sfe_tick_$F" "$SINCE_EPOCH"
echo "== parity =="
"sfe_parity_$F" "$SINCE_EPOCH"
echo "rollback: $("sfe_rollback_$F")"
if [ "$SFE_FAILS" = 0 ]; then echo "RESULT: GREEN $P"; exit 0; fi
echo "RESULT: NOT GREEN $P ($SFE_FAILS check(s) failed)"
exit 1
