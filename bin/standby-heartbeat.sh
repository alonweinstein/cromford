#!/bin/bash
# bin/standby-heartbeat.sh <of> <snapshot> <rc> — a standby's second report
# after a state-stream run (BH-2640, part of #2519).
#
# bin/state-restore.sh --standby already tells the WATCHDOG how each stream run
# went (/api/standby/<self>, a KV the hub cannot query). This tells the HUB, so
# the jobs worker's standby_status table carries one row per standby:
#
#   POST $JOBS_URL/api/hub/standby/heartbeat {box, of, snapshot, ok}
#
#   box       this box's fleet name, from bin/box-name.sh (the watchdog report's
#             <self>, resolved the same way)
#   of        the hub prefix the stream pulled ([a-z0-9-]+)
#   snapshot  the YYYYMMDDTHHMMSSZ it pulled; empty when there was none (the
#             worker stores a non-stamp as null)
#   ok        rc == 0
#
# FAIL-OPEN, ALWAYS EXIT 0. It prints exactly one line — `standby heartbeat
# recorded`, `standby heartbeat failed (HTTP <n|none>, fail-open)` or
# `standby heartbeat skipped: <why>` — and is bounded by the jobs client's own
# timeout (JOBS_TIMEOUT, one transport retry). A skip makes no request. A
# failure writes no ALERTS line (JOBS_ALERT=0): it runs every 15 minutes and the
# watchdog's report is the paging path. It never prints the secret or the URL.
#
# HARNESS names the tree whose env/global.env carries HARNESS_SECRET and
# JOBS_URL (default /root/harness); state-restore passes its own.
#
# Run by hand: bin/standby-heartbeat.sh hub 20260915T232000Z 0
set -uo pipefail
trap 'exit 0' EXIT
H="${HARNESS:-/root/harness}"
HERE="$(cd "$(dirname "$0")" && pwd)"
skip() { echo "standby heartbeat skipped: $*"; exit 0; }

[ $# -eq 3 ] || skip "usage: standby-heartbeat.sh <of> <snapshot> <rc>"
OF="$1" SNAP="$2" RC="$3"
[[ "$OF" =~ ^[a-z0-9-]+$ ]] || skip "<of> '$OF' is not [a-z0-9-]+"
[[ "$RC" =~ ^[0-9]+$ ]] || skip "<rc> '$RC' is not a number"
SELF=$(HARNESS="$H" "$HERE/box-name.sh" 2>/dev/null)
[ -n "$SELF" ] || skip "box name not configured"

export HARNESS="$H"
# shellcheck source=bin/jobs-client.sh
. "$HERE/jobs-client.sh" 2>/dev/null
command -v _jobs_req >/dev/null 2>&1 || skip "jobs client did not load"
[ -n "${HARNESS_SECRET:-}" ] || skip "HARNESS_SECRET not configured"
[ -n "${JOBS_URL:-}" ] || skip "JOBS_URL not configured"

BODY=$(jq -nc --arg box "$SELF" --arg of "$OF" --arg s "$SNAP" --argjson rc "$RC" \
  '{box: $box, of: $of, snapshot: $s, ok: ($rc == 0)}')
if JOBS_ALERT=0 _jobs_req POST /api/hub/standby/heartbeat "$BODY" >/dev/null; then
  echo "standby heartbeat recorded"
else
  echo "standby heartbeat failed (HTTP ${JOBS_HTTP:-none}, fail-open)"
fi
