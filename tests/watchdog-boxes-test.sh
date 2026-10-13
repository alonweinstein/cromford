#!/bin/bash
# tests/watchdog-boxes-test.sh — the committed cron ping lines and the watchdog
# worker's BOXES array must describe the SAME fleet.
#
# This is the test that would have caught the bug it was written for. Four boxes
# (project-1, project-5, project-6, small) were running fine and pinging — or in
# three cases not pinging at all — while the worker had never heard of them, so
# Mission Control showed 5 machine tiles for a 9-box fleet. Nothing errored.
# A box missing from BOXES is not "unmonitored but fine": it is a box whose death
# nobody would notice, which is the exact failure the watchdog exists to prevent.
#
# Both directions matter and they fail differently:
#   cron without BOXES  -> the box pings into the void, invisible, never alerts
#   BOXES without cron  -> the worker pages for a box that was never wired up
# Run from anywhere: tests/watchdog-boxes-test.sh   (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
# BH-1247: catalog/lanes.json and cron/<box>.cron are GENERATED and not
# committed. rendered_registry / rendered_cron render this repo's own into $T.
. "$(dirname "$0")/lib/rendered.sh" || exit 1
WORKER="$DIR/worker/watchdog/src/index.js"
BOXES_JSON="$DIR/worker/watchdog/src/boxes.json"   # TEST-CHANGE (BH-1957): the list is config now

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

# ---------- gather ----------
# Ping names as the crons actually spell them. The name is NOT derivable from the
# filename — hub pings as box-hub and project-3 as box-project-3-2 — so
# it is read from the line rather than reconstructed.
CRON_BOXES=$(grep -ho 'watchdog-ping\.sh [A-Za-z0-9._-]*' "$(rendered_cron_dir)"/*.cron 2>/dev/null \
  | awk '{print $2}' | sort -u)
# TEST-CHANGE (BH-1957): read the config the worker imports, not a code array.
WORKER_BOXES=$(jq -r '.[]' "$BOXES_JSON" 2>/dev/null | sort -u)

[ -n "$CRON_BOXES" ]   && ok || bad "no ping lines found in cron/*.cron — is this test looking at the right thing?"
[ -n "$WORKER_BOXES" ] && ok || bad "could not read the box list out of $BOXES_JSON"  # TEST-CHANGE (BH-1957)

# ---------- 1. every cron pings, exactly once ----------
# A cron file with no ping line is a box the watchdog can never miss, because it
# never hears from it in the first place.
# A stopped box is the one sanctioned exception: it pings nothing and the worker
# watches nothing, so both planes stay in step. It must SAY so in the file, so a
# missing ping line can never pass as an oversight.
for F in "$(rendered_cron_dir)"/*.cron; do
  N=$(grep -c 'watchdog-ping\.sh' "$F" 2>/dev/null || true)
  if [ "${N:-0}" -eq 0 ] && grep -q '^# watchdog ping removed .* box stopped' "$F"; then
    continue
  fi
  [ "${N:-0}" -eq 1 ] || bad "$(basename "$F") has $N ping lines, expected exactly 1"
done
ok

# ---------- 2. same schedule and command shape everywhere ----------
# Drift here is silent: a box pinging every 30 minutes against a 15-minute
# staleness threshold would alert forever.
ODD=$(grep -h 'watchdog-ping\.sh' "$(rendered_cron_dir)"/*.cron \
  | grep -vE '^\*/5 \* \* \* \* /root/harness/bin/watchdog-ping\.sh [A-Za-z0-9._-]+$' || true)
[ -z "$ODD" ] && ok || bad "ping line does not match the fleet-standard shape:
$ODD"

# ---------- 3. the two sets are equal ----------
MISSING_FROM_WORKER=$(comm -23 <(echo "$CRON_BOXES") <(echo "$WORKER_BOXES"))
[ -z "$MISSING_FROM_WORKER" ] && ok || bad "these boxes ping but the worker does not watch them (invisible; their death would go unnoticed):
$MISSING_FROM_WORKER"

MISSING_FROM_CRON=$(comm -13 <(echo "$CRON_BOXES") <(echo "$WORKER_BOXES"))
[ -z "$MISSING_FROM_CRON" ] && ok || bad "the worker watches these boxes but no committed cron pings them (it will page for a box that was never wired up):
$MISSING_FROM_CRON"

# ---------- 4. the hub is in the set ----------
# HUB drives dead-hub detection and the fleet-status staleness check; if it ever
# fell out of BOXES those would key off a box that is never evaluated.
HUB=$(grep -o 'const HUB = "[^"]*"' "$WORKER" | grep -o '"[^"]*"' | tr -d '"')
grep -qxF "$HUB" <<<"$WORKER_BOXES" && ok || bad "HUB ($HUB) is not in BOXES"
grep -qxF "$HUB" <<<"$CRON_BOXES"   && ok || bad "HUB ($HUB) has no cron ping line"

# ---------- 5. no duplicates ----------
# A duplicate would double-alert on one box.
DUP=$(jq -r '.[]' "$BOXES_JSON" 2>/dev/null | sort | uniq -d)  # TEST-CHANGE (BH-1957)
[ -z "$DUP" ] && ok || bad "duplicate entries in BOXES: $DUP"

# ---------- 6. the fleet is fully covered ----------
# Every box that owns a project in fleet.conf must be watched. This is the check
# that scales: enrol a project on a new box, and the fleet grows without anyone
# remembering the watchdog.
UNWATCHED=""
while read -r B; do
  [ -n "$B" ] || continue
  grep -qxF "$B" <<<"$WORKER_BOXES" || UNWATCHED="$UNWATCHED $B"
done < <(awk '!/^[[:space:]]*(#|$)/ {print $6}' "$DIR/fleet.conf" | grep -v '^local$' | sort -u)
[ -z "$UNWATCHED" ] && ok || bad "fleet.conf assigns projects to boxes the watchdog does not watch:$UNWATCHED"

# ---------- 7. the list cannot creep back into code (BH-1957) ----------
# The worker must take its list from boxes.json, and the only box name left as
# a literal in index.js is HUB. A second copy in code is two lists that drift.
# TEST-CHANGE (BH-1957): new case.
grep -qE '^import BOXES from "\./boxes\.json"' "$WORKER" \
  && ok || bad "index.js must import BOXES from ./boxes.json"
[ -n "$HUB" ] && ok || bad "could not read const HUB out of $WORKER"
STRAY=$(grep -v '^const HUB = ' "$WORKER" | grep -o '"box-[^"]*"' || true)
[ -z "$STRAY" ] && ok || bad "box names hardcoded in index.js besides HUB (they belong in boxes.json): $STRAY"

echo "watchdog-boxes-test: $PASS pass, $FAIL fail"
[ "$FAIL" -eq 0 ]
