#!/bin/bash
# tests/pause-lib.bh-1672-test.sh — the box-side refresh and env-shape halves of
# the BH-1672 pause mechanism: pause_refresh and pause_env_shapes in the REAL
# bin/lib/pause.sh (BH-1683).
#
# The worker is a fake _jobs_req defined here, answering canned bodies and rcs
# per path from files under $T/fake, and logging every call to $T/calls, so a
# case can prove both what the lib asked and what it did with the answer. The
# clock is PAUSE_NOW and file ages come from `touch -d @<epoch>`, so nothing here
# depends on when the suite runs.
# Run from anywhere: tests/pause-lib.bh-1672-test.sh   (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
. "$(dirname "$0")/../bin/lib/pause.sh" || exit 1
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }

export JOBS_HARNESS="$T/h"
export JOBS_URL="http://fake.invalid"
H="$JOBS_HARNESS"
mkdir -p "$H/state" "$T/fake"
CACHE="$H/state/pauses.json"
LOG="$H/logs/pauses.log"
CALLS="$T/calls"

NOW=1790000000
export PAUSE_NOW=$NOW
iso() { date -u -d "@$1" +%Y-%m-%dT%H:%M:%SZ; }

_jobs_req() {
  echo "$1 $2" >> "$CALLS"
  local k rc
  case "$1 $2" in
    "POST /api/pauses/expire") k=expire ;;
    "GET /api/pauses?active=1") k=get ;;
    *) k=other ;;
  esac
  rc=$(cat "$T/fake/$k.rc" 2>/dev/null || echo 0)
  JOBS_BODY=$(cat "$T/fake/$k.body" 2>/dev/null)
  if [ "$rc" = 0 ]; then JOBS_HTTP=200; printf '%s' "$JOBS_BODY"; else JOBS_HTTP=503; fi
  return "$rc"
}
answer() { printf '%s' "$3" > "$T/fake/$1.body"; echo "$2" > "$T/fake/$1.rc"; }
reset() { rm -f "$CALLS" "$LOG" "$CACHE" "$T/fake"/*; }

rowx='{"id":7,"scope":"projA","what":"reviews","reason":"flaky tests","actor":"hub","created_at":"2026-09-20T00:00:00Z","expires_at":"2026-09-21T00:00:00Z","ended_at":"2026-09-21T00:00:00Z","end_reason":"expired"}'
live_merges="{\"pauses\":[{\"id\":3,\"scope\":\"projA\",\"what\":\"merges\",\"reason\":\"r\",\"actor\":\"a\",\"created_at\":\"$(iso $((NOW-60)))\",\"expires_at\":\"$(iso $((NOW+3600)))\",\"ended_at\":null,\"end_reason\":null}],\"truncated\":false}"

# R1: expire returns one row, GET returns B → cache is B byte for byte, one log line.
# The expire answer is the worker's real envelope (worker/jobs/src/routes/pauses.js,
# BH-1682): {expired:[row...], as_of}.
reset
answer expire 0 "{\"expired\":[$rowx],\"as_of\":\"$(iso $NOW)\"}"
answer get 0 "$live_merges"
pause_refresh; rc=$?
[ "$rc" = 0 ] && ok || bad "R1 pause_refresh rc 0 (got $rc)"
printf '%s' "$live_merges" > "$T/B"
cmp -s "$T/B" "$CACHE" && ok || bad "R1 cache equals the GET body byte for byte"
[ "$(grep -c 'PAUSE_EXPIRED' "$LOG" 2>/dev/null)" = 1 ] && ok || bad "R1 exactly one PAUSE_EXPIRED line"
grep -Eq '^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9:]{8}Z PAUSE_EXPIRED scope=projA what=reviews reason=flaky tests actor=hub$' "$LOG" 2>/dev/null \
  && ok || bad "R1 log line shape (got: $(cat "$LOG" 2>/dev/null))"
[ "$(cat "$CALLS" 2>/dev/null)" = "$(printf 'POST /api/pauses/expire\nGET /api/pauses?active=1')" ] \
  && ok || bad "R1 exactly two requests through _jobs_req, expire then GET (got: $(cat "$CALLS" 2>/dev/null))"
[ "$(pause_active projA merges; echo $?)" = 0 ] && ok || bad "R1 refreshed cache answers pause_active"
# A bare-array expire answer is accepted too.
rm -f "$LOG"; answer expire 0 "[$rowx]"
pause_refresh >/dev/null 2>&1
[ "$(grep -c 'PAUSE_EXPIRED' "$LOG" 2>/dev/null)" = 1 ] && ok || bad "R1 bare-array expire answer logs its row"
# So is a {pauses:[...]} envelope.
rm -f "$LOG"; answer expire 0 "{\"pauses\":[$rowx]}"
pause_refresh >/dev/null 2>&1
[ "$(grep -c 'PAUSE_EXPIRED' "$LOG" 2>/dev/null)" = 1 ] && ok || bad "R1 {pauses} expire answer logs its row"

# R2: outage on GET keeps the old cache, rc nonzero, pause_active still answers from it.
reset
printf '%s' "$live_merges" > "$CACHE"; cp "$CACHE" "$T/before"
answer expire 0 '{"pauses":[]}'
answer get 1 ''
pause_refresh 2>/dev/null; rc=$?
[ "$rc" != 0 ] && ok || bad "R2 outage → rc nonzero"
cmp -s "$T/before" "$CACHE" && ok || bad "R2 outage keeps the cache unchanged"
[ "$(pause_active projA merges; echo $?)" = 0 ] && ok || bad "R2 pause_active answers from the kept cache"
# An expire outage alone: GET still refreshes, rc still nonzero, no log line.
reset
answer expire 1 ''
answer get 0 "$live_merges"
pause_refresh 2>/dev/null; rc=$?
[ "$rc" != 0 ] && ok || bad "R2 expire outage → rc nonzero"
cmp -s "$T/B" "$CACHE" && ok || bad "R2 expire outage still refreshes the cache"
[ ! -s "$LOG" ] && ok || bad "R2 expire outage writes no log line"

# R3: a 200 whose body is not the envelope keeps the cache.
reset
printf '%s' "$live_merges" > "$CACHE"
answer expire 0 '[]'
answer get 0 '<html>'
pause_refresh 2>/dev/null; rc=$?
[ "$rc" != 0 ] && ok || bad "R3 garbage 200 → rc nonzero"
cmp -s "$T/before" "$CACHE" && ok || bad "R3 garbage 200 keeps the cache"
answer get 0 '{"ok":true}'
pause_refresh 2>/dev/null; rc=$?
[ "$rc" != 0 ] && cmp -s "$T/before" "$CACHE" && ok || bad "R3 200 without .pauses keeps the cache, rc nonzero"

# R4: expire returns the row once; two refreshes → exactly one line.
reset
answer get 0 '{"pauses":[],"truncated":false}'
answer expire 0 "{\"expired\":[$rowx],\"as_of\":\"$(iso $NOW)\"}"
pause_refresh
answer expire 0 "{\"expired\":[],\"as_of\":\"$(iso $NOW)\"}"
pause_refresh
[ "$(grep -c 'PAUSE_EXPIRED' "$LOG" 2>/dev/null)" = 1 ] && ok || bad "R4 two refreshes, row returned once → one line (got $(grep -c PAUSE_EXPIRED "$LOG" 2>/dev/null))"

# R5: ended/expired rows in the GET body never produce a log line.
reset
answer expire 0 '{"pauses":[]}'
answer get 0 "{\"pauses\":[$rowx],\"truncated\":false}"
pause_refresh
[ ! -s "$LOG" ] && ok || bad "R5 GET rows write no pauses.log line"

# A reason with a newline stays on one line.
reset
answer expire 0 "$(jq -nc '{expired:[{scope:"fleet",what:"merges",reason:"a\nb",actor:"x"}],as_of:"2026-09-21T00:00:00Z"}')"
answer get 0 '{"pauses":[]}'
pause_refresh
[ "$(wc -l < "$LOG")" = 1 ] && grep -q 'reason=a b actor=x$' "$LOG" && ok || bad "R5 multi-line reason logged on one line"

# R6: JOBS_URL empty → one stderr line, rc 0, cache untouched, no request.
reset
printf '%s' "$live_merges" > "$CACHE"
err=$(JOBS_URL="" pause_refresh 2>&1 >/dev/null); rc=$?
[ "$rc" = 0 ] && ok || bad "R6 not configured → rc 0 (got $rc)"
[ "$(printf '%s\n' "$err" | grep -c '^pause: jobs not configured$')" = 1 ] && [ "$(printf '%s\n' "$err" | wc -l)" = 1 ] \
  && ok || bad "R6 exactly one 'pause: jobs not configured' line (got: $err)"
cmp -s "$T/before" "$CACHE" && ok || bad "R6 cache untouched"
[ ! -e "$CALLS" ] && ok || bad "R6 no _jobs_req call"

# R6b: loading the jobs client does not change the caller's shell options. The
# real bin/jobs-client.sh runs `set -uo pipefail`; a lane that sources this lib
# without them must still be without them after pause_refresh.
reset
cat > "$T/opt-client.sh" <<'EOF2'
set -uo pipefail
_jobs_req() { case "$1 $2" in "GET /api/pauses?active=1") printf '{"pauses":[]}' ;; *) printf '{"expired":[]}' ;; esac; }
EOF2
opts=$( unset -f _jobs_req; set +u; set +o pipefail
  PAUSE_JOBS_CLIENT="$T/opt-client.sh" pause_refresh >/dev/null 2>&1; rc=$?
  printf '%s %s %s' "$rc" "$(case $- in *u*) echo u ;; *) echo nou ;; esac)" "$(set -o | awk '$1=="pipefail"{print $2}')" )
[ "$opts" = "0 nou off" ] && ok || bad "R6b pause_refresh keeps the caller's set -u / pipefail off (got: $opts)"

# R7: local expiry with no refresh.
reset
jq -nc --arg c "$(iso $((NOW-60)))" --arg e "$(iso $((NOW+60)))" \
  '{pauses:[{id:1,scope:"projA",what:"builds",reason:"r",actor:"a",created_at:$c,expires_at:$e,ended_at:null,end_reason:null}],truncated:false}' > "$CACHE"
[ "$(pause_active projA builds; echo $?)" = 0 ] && ok || bad "R7 live at NOW"
[ "$(PAUSE_NOW=$((NOW+61)) pause_active projA builds; echo $?)" = 1 ] && ok || bad "R7 over at NOW+61 with no refresh"

# ---- env shapes ----
reset
mkdir -p "$H/flags"
shapes() { pause_env_shapes; }
cap() { ( if [ "$1" = UNSET ]; then unset REVIEW_AUTOPILOT_DAILY_CAP; else export REVIEW_AUTOPILOT_DAILY_CAP="$1"; fi; pause_env_shapes ) | grep '^env:review-cap' ; }

# E1-E6
[ "$(cap 1)" = "env:review-cap=1" ] && ok || bad "E1 cap 1 is a pause (got '$(cap 1)')"
[ "$(cap 4)" = "env:review-cap=4" ] && ok || bad "E2 cap 4 is a pause"
[ -z "$(cap 5)" ] && ok || bad "E3 cap 5 (== below) is not a pause"
[ -z "$(cap 0)" ] && ok || bad "E4 cap 0 (unlimited) is not a pause"
[ -z "$(cap UNSET)" ] && ok || bad "E5 unset cap is not a pause"
[ -z "$(cap '')" ] && ok || bad "E5 empty cap is not a pause"
[ -z "$(cap 50)" ] && ok || bad "E6 cap 50 is not a pause"
[ -z "$(cap abc)" ] && ok || bad "E6 cap abc is not a pause"
for v in -1 3.5 ' 3'; do [ -z "$(cap "$v")" ] && ok || bad "E6 cap '$v' is not a pause"; done
[ "$(cap 04)" = "env:review-cap=4" ] && ok || bad "E6 cap 04 normalizes to 4"
# E7: the threshold is the settings row.
echo '{"fetched_at":1,"values":{"pause_env_review_cap_below":"10"}}' > "$H/state/settings-cache.json"
[ "$(cap 7)" = "env:review-cap=7" ] && ok || bad "E7 below=10 → cap 7 is a pause"
echo '{"fetched_at":1,"values":{"pause_env_review_cap_below":"junk"}}' > "$H/state/settings-cache.json"
[ -z "$(cap 7)" ] && [ "$(cap 4)" = "env:review-cap=4" ] && ok || bad "E7 garbage knob falls back to 5"
rm -f "$H/state/settings-cache.json"

# E8/E9
touch "$H/flags/automerge-disabled-foo" "$H/flags/automerge-disabledX"
[ -z "$(shapes | grep automerge)" ] && ok || bad "E9 automerge-disabled-foo / -disabledX are not a pause"
touch "$H/flags/automerge-disabled"
[ "$(shapes | grep automerge)" = "env:automerge-disabled" ] && ok || bad "E8 flags/automerge-disabled is a pause"
rm -f "$H/flags"/automerge-*
# E8b (BH-4153): with a worker configured the switch is a harness_flags row and
# no flags/ file exists; the box's last good answer is the cache entry.
mkdir -p "$H/state/flags-cache/fleet"
printf '%s\n' '{"on":true,"value":null,"set_at":"2026-09-19T01:00:00Z","cleared_at":null,"src":"db","stamp":1789779600}' \
  > "$H/state/flags-cache/fleet/automerge-disabled"
[ "$(shapes | grep automerge)" = "env:automerge-disabled" ] && ok || bad "E8b a cached ON automerge-disabled row is a pause (no file)"
printf '%s\n' '{"on":false,"value":null,"set_at":"2026-09-19T01:00:00Z","cleared_at":"2026-09-19T02:00:00Z","src":"db","stamp":1789783200}' \
  > "$H/state/flags-cache/fleet/automerge-disabled"
[ -z "$(shapes | grep automerge)" ] && ok || bad "E8b a cached cleared row is not a pause"
scratch_rm "$H/state/flags-cache"

# E10/E11/E12
[ -z "$(shapes | grep lane-off)" ] && ok || bad "E11 no lane-off flags → no token (no literal glob)"
touch -d "@$((NOW-86401))" "$H/flags/lane-off-merge"
touch -d "@$((NOW-86340))" "$H/flags/lane-off-triage"
touch -d "@$((NOW-86400))" "$H/flags/lane-off-edge"
touch -d "@$((NOW-99999))" "$H/flags/lane-off-"
[ "$(shapes | grep lane-off)" = "env:lane-off-merge" ] && ok || bad "E10/E11 only the >24h flag fires (got: $(shapes | grep lane-off | tr '\n' ' '))"
rm -f "$H/flags"/lane-off-*
touch -d "@$((NOW-120))" "$H/flags/lane-off-builds"
[ -z "$(shapes | grep lane-off)" ] && ok || bad "E12 age 120 < default 86400 → no token"
echo '{"fetched_at":1,"values":{"pause_env_laneoff_age_s":"60"}}' > "$H/state/settings-cache.json"
[ "$(shapes | grep lane-off)" = "env:lane-off-builds" ] && ok || bad "E12 knob 60 → age 120 fires"
rm -f "$H/state/settings-cache.json" "$H/flags"/lane-off-*
# A missing flags dir is quiet and rc 0.
scratch_rm "$H/flags"
out=$(REVIEW_AUTOPILOT_DAILY_CAP=0 pause_env_shapes); rc=$?
[ "$rc" = 0 ] && [ -z "$out" ] && ok || bad "E12 no flags dir → no output, rc 0"

# E13: env shapes never talk to the worker and never write the cache.
[ ! -e "$CALLS" ] && ok || bad "E13 pause_env_shapes made a _jobs_req call"
[ ! -e "$CACHE" ] && ok || bad "E13 pause_env_shapes wrote state/pauses.json"

echo "pause-lib: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
