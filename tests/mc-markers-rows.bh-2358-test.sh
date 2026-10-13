#!/bin/bash
# tests/mc-markers-rows.bh-2358-test.sh — BH-2358 (BH-2311.2, tasks 4.1 and
# 4.2): the resolver hand-off markers and the stuck detector's one-page marker
# are ALSO pr_attempts rows, so a box that loses state/merge-conductor/ does not
# un-park a PR the resolver owns or page a stuck PR a second time.
#
# WHAT IT PINS (flag up unless it says otherwise).
#   H1 record a park, wipe MC_HANDOFF_DIR and the ledger file: the row's own
#      head field is `-`, so only the `handoff` row can say the park stands —
#      mc_handoff_sticky is rc 0.
#   H2 release it, wipe MC_HANDOFF_REL_DIR and the ledger file: the
#      `handoff-rel` row still says released — rc 1.
#   H3 a release of head A does NOT release a park on head B.
#   H4 a new park on a head that was released drops the stale `handoff-rel`
#      row (a DELETE), so the new park is sticky again.
#   H5 mc_handoff_gc on a 15-day marker forgets both rows (two DELETEs).
#   S1 two ticks past the TTL with MC_STUCK_DIR and the ledger wiped between:
#      the alert goes out ONCE, and the marker is warmed back.
#   S2 an outage with marker and ledger line gone: the files decide, so the
#      alert goes out again — never "already paged" on a blink.
#   S3 a page for (PR, WAIT_CI, head) does not dedupe (PR, HEAD_MOVED, head).
#   S4 mc_stuck_gc: a marker with a line forgets its row (one DELETE); an
#      EMPTY marker (flag-down, or log.sh's held-page flush) makes no request.
#   F1 flag down: all of the above make NO pr-attempts request, the ledger
#      file gets no new line, and the stuck marker is the empty file it is today.
#
# HOW. The REAL functions through the REAL bin/lib/merge-conductor-lib.sh and
# jobs client, one fresh process per step. The worker is a curl shim with a row
# store and a request sink; the alert is bin/lane-alert.sh stubbed to count.
#
# Run from anywhere: tests/mc-markers-rows.bh-2358-test.sh (exit 0 = all pass)
set -uo pipefail
# shellcheck source=tests/lib/scratch.sh
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }

H="$T/h"
mkdir -p "$H/bin/lib/jobs" "$H/bin/lib/mc" "$H/env" "$H/flags" "$H/logs" \
         "$H/state/merge-conductor" "$T/fakebin"
cp "$DIR/bin/jobs-client.sh" "$H/bin/" || exit 1
cp "$DIR"/bin/lib/jobs/*.sh "$H/bin/lib/jobs/" || exit 1
cp "$DIR/bin/lib/env-path.sh" "$DIR/bin/lib/merge-conductor-lib.sh" "$H/bin/lib/" || exit 1
cp "$DIR"/bin/lib/mc/*.sh "$H/bin/lib/mc/" || exit 1

ATT="$H/state/merge-conductor/attempts.txt"
MCLOG="$H/logs/merge-conductor.log"
REQ="$T/req.log"
ROWS="$T/rows.tsv"
ERR="$T/err.log"

# The worker: a row store in $ROWS_FILE keyed (repo, number, kind, sha).
# /api/flags/* answers 404 so flag_active falls back to the flag FILE.
cat > "$T/fakebin/curl" <<'CURL'
#!/bin/bash
URL=""; METHOD=GET; BODY=""
while [ $# -gt 0 ]; do
  case "$1" in
    -X) METHOD="$2"; shift 2 ;;
    --data-binary) BODY="$2"; shift 2 ;;
    -H|-m|--connect-timeout|-w) shift 2 ;;
    -*) shift ;;
    *) URL="$1"; shift ;;
  esac
done
case "$URL" in */api/flags/*) printf '{"error":"no such flag"}\n404\n'; exit 0 ;; esac
case "$URL" in */api/pr-attempts*) ;; *) printf '{"error":"not found"}\n404\n'; exit 0 ;; esac
dec() { local s="${1//+/ }"; printf '%b' "${s//%/\\x}"; }
repo=""; num=""; kind=""; sha=""
if [ -n "$BODY" ]; then
  repo=$(jq -r .repo <<<"$BODY"); num=$(jq -r .number <<<"$BODY")
  kind=$(jq -r .kind <<<"$BODY"); sha=$(jq -r .sha <<<"$BODY")
else
  q="${URL#*\?}"; [ "$q" = "$URL" ] && q=""
  IFS='&' read -r -a kv <<<"$q"
  for p in "${kv[@]}"; do
    v=$(dec "${p#*=}")
    case "${p%%=*}" in repo) repo="$v" ;; number) num="$v" ;; kind) kind="$v" ;; sha) sha="$v" ;; esac
  done
fi
printf '%s\t%s\t%s\t%s\t%s\n' "$METHOD" "$repo" "$num" "$kind" "$sha" >> "$REQ_LOG"
[ -f "$ROWS_DOWN" ] && exit 7
touch "$ROWS_FILE"
row=$(printf '%s\t%s\t%s\t%s' "$repo" "$num" "$kind" "$sha")
case "$METHOD" in
  PUT) grep -qxF "$row" "$ROWS_FILE" || printf '%s\n' "$row" >> "$ROWS_FILE"
       printf '{"ok":true}\n200\n' ;;
  DELETE) if grep -qxF "$row" "$ROWS_FILE"; then
            grep -vxF "$row" "$ROWS_FILE" > "$ROWS_FILE.t"; mv -f "$ROWS_FILE.t" "$ROWS_FILE"
            printf '{"ok":true}\n200\n'
          else printf '{"error":"no row"}\n404\n'; fi ;;
  GET) if [ -n "$sha" ]; then
         if grep -qxF "$row" "$ROWS_FILE"; then printf '{"ok":true}\n200\n'; else printf '{"error":"no row"}\n404\n'; fi
       else
         awk -F'\t' -v r="$repo" -v n="$num" -v k="$kind" '$1==r && $2==n && $3==k {print $4}' "$ROWS_FILE" \
           | jq -Rsc 'split("\n") | map(select(. != "")) | {attempts: map({sha: .}), count: length}'
         printf '200\n'
       fi ;;
esac
CURL
chmod +x "$T/fakebin/curl"
# Nothing here may reach GitHub; a gh call answers nothing, rc 1.
printf '#!/bin/bash\nexit 1\n' > "$T/fakebin/gh"; chmod +x "$T/fakebin/gh"

cat > "$T/drive.sh" <<'DRV'
#!/bin/bash
set -uo pipefail
# shellcheck source=/dev/null
. "$HARNESS/bin/jobs-client.sh" >/dev/null 2>&1 || exit 90
# shellcheck source=/dev/null
. "$HARNESS/bin/lib/merge-conductor-lib.sh" >/dev/null 2>&1 || exit 91
mc_init
eval "$DRIVE_CODE"
DRV
# drv <tick-id|""> <snippet> — one fresh process, MC_TICK_ID exported as the
# conductor exports it.
drv() {
  local tick="$1"
  env ${tick:+MC_TICK_ID="$tick"} DRIVE_CODE="$2" PATH="$T/fakebin:$PATH" HARNESS="$H" \
    HARNESS_SECRET=x JOBS_BOX=testbox JOBS_RETRIES=0 JOBS_ALERT=0 JOBS_URL=http://jobs.test \
    REQ_LOG="$REQ" ROWS_FILE="$ROWS" ROWS_DOWN="$T/rows-down" MC_REHYDRATE=0 \
    bash "$T/drive.sh" 2>>"$ERR"
}
printf '#!/bin/bash\nprintf "%%s\\n" "$*" >> "%s"\nexit 0\n' "$T/alerts.txt" > "$H/bin/lane-alert.sh"
chmod +x "$H/bin/lane-alert.sh"
SD="$H/state/merge-conductor"
ROWSF="$SD/pr-state.tsv"
flag() { if [ "$1" = up ]; then : > "$H/flags/pr-state-rows"; else rm -f "$H/flags/pr-state-rows"; fi; }
wipe() { local d; for d in "$@"; do find "$SD/$d" -mindepth 1 -delete 2>/dev/null; done; }
reset() { : > "$REQ"; : > "$ERR"; : > "$ATT"; : > "$MCLOG"; : > "$ROWS"; : > "$T/alerts.txt"; : > "$ROWSF"
          rm -f "$T/rows-down"; wipe handoff handoff-released stuck; }
nreq()   { local n; n=$(grep -c "^$1	" "$REQ" 2>/dev/null) || n=0; printf '%s' "${n:-0}"; }
nattreq() { local n; n=$(grep -cE "^(GET|PUT|DELETE)	o/r	" "$REQ" 2>/dev/null) || n=0; printf '%s' "${n:-0}"; }
seen()   { grep -qxF "$(printf '%s\t%s\t%s\t%s\t%s' "$1" o/r 5 "$2" "$3")" "$REQ"; }
nalerts() { local n; n=$(grep -c . "$T/alerts.txt" 2>/dev/null) || n=0; printf '%s' "${n:-0}"; }
K='o/r#5'
U='https://github.com/o/r/pull/5'
HA=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
HB=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
# park_row <head-field> — the conductor's own row for a hand-off park.
park_row() { printf '%s\tBLOCKED_HUMAN\t%s\t%s\t-\t-\tconflict-unresolvable\t%s\n' "$K" 1000 "$1" "$U" > "$ROWSF"; }
sticky() { drv "" "mc_handoff_sticky '$K' $1; echo rc=\$?"; }

echo "== H1. a wiped hand-off marker: the row keeps the park =="
reset; flag up
drv "" "mc_handoff_record '$K' $HA conflict-unresolvable '$U'"
seen PUT handoff "$HA" && ok || bad "H1: mc_handoff_record must PUT a handoff row: $(cat "$REQ")"
wipe handoff; : > "$ATT"; park_row -
[ "$(sticky "$HA")" = rc=0 ] && ok || bad "H1: with the marker and ledger line gone the handoff row must keep the park sticky"
seen GET handoff "$HA" && ok || bad "H1: the answer must have come from the row: $(cat "$REQ")"
[ "$(sticky "$HB")" = rc=1 ] && ok || bad "H1: a park on $HA must not hold head $HB"

echo "== H2. a wiped release marker: the row keeps the release =="
drv "" "mc_handoff_record '$K' $HA conflict-unresolvable '$U'; mc_handoff_release '$K' test-resolver"
seen PUT handoff-rel "$HA" && ok || bad "H2: mc_handoff_release must PUT a handoff-rel row: $(cat "$REQ")"
wipe handoff-released; : > "$ATT"; park_row "$HA"
[ "$(sticky "$HA")" = rc=1 ] && ok || bad "H2: with the release marker gone the handoff-rel row must still release the park"
# Release with NO recorded head anywhere: no row write, file as today.
reset; flag up; park_row -
drv "" "mc_handoff_release '$K' test-resolver"
[ "$(nattreq)" = 0 ] && ok || bad "H2: a release with no parked head must write no row: $(cat "$REQ")"
[ -e "$SD/handoff-released/o_r_5" ] && ok || bad "H2: the release marker file must still be written"

echo "== H3. a release of head A does not release a park on head B =="
reset; flag up
drv "" "mc_handoff_record '$K' $HA conflict-unresolvable '$U'; mc_handoff_release '$K' r"
drv "" "mc_handoff_record '$K' $HB conflict-unresolvable '$U'"
wipe handoff-released; park_row "$HB"
[ "$(sticky "$HB")" = rc=0 ] && ok || bad "H3: handoff-rel on $HA must not release the park on $HB"

echo "== H4. a new park on a released head drops the stale release row =="
reset; flag up
drv "" "mc_handoff_record '$K' $HA conflict-unresolvable '$U'; mc_handoff_release '$K' r"
drv "" "mc_handoff_record '$K' $HA conflict-unresolvable '$U'"
seen DELETE handoff-rel "$HA" && ok || bad "H4: the re-park must DELETE the stale handoff-rel row: $(cat "$REQ")"
park_row "$HA"
[ "$(sticky "$HA")" = rc=0 ] && ok || bad "H4: the new park must be sticky again, not released by the old row"

echo "== H5. gc forgets both rows of a 15-day marker =="
reset; flag up
drv "" "mc_handoff_record '$K' $HA conflict-unresolvable '$U'"
touch -d '15 days ago' "$SD/handoff/o_r_5"
: > "$REQ"
drv "" "mc_handoff_gc"
seen DELETE handoff "$HA" && ok || bad "H5: gc must DELETE the handoff row: $(cat "$REQ")"
seen DELETE handoff-rel "$HA" && ok || bad "H5: gc must DELETE the handoff-rel row: $(cat "$REQ")"
[ ! -e "$SD/handoff/o_r_5" ] && ok || bad "H5: the marker file must still be deleted"
# A fresh marker is not collected and not forgotten.
drv "" "mc_handoff_record '$K' $HA conflict-unresolvable '$U'"; : > "$REQ"
drv "" "mc_handoff_gc"
[ "$(nreq DELETE)" = 0 ] && ok || bad "H5: a fresh marker must not be forgotten: $(cat "$REQ")"

SINCE=$(( $(date -u +%s) - 20000 ))
stuck() { drv "$1" "mc_stuck_check '$K' $2 $SINCE $3 '$U' 'checks pending'; echo rc=\$?"; }

echo "== S1. a wiped stuck marker: the row keeps the one page =="
reset; flag up
[ "$(stuck t1 WAIT_CI "$HA")" = rc=0 ] && ok || bad "S1: past its TTL the first tick must page"
[ "$(nalerts)" = 1 ] && ok || bad "S1: want 1 alert after the first tick, got $(nalerts)"
seen PUT stuck "WAIT_CI $HA" && ok || bad "S1: the page must PUT a stuck row keyed on (PR, state, head): $(cat "$REQ")"
wipe stuck; : > "$ATT"
[ "$(stuck t2 WAIT_CI "$HA")" = rc=1 ] && ok || bad "S1: the second tick must see the row and not page"
[ "$(nalerts)" = 1 ] && ok || bad "S1: the alert must go out ONCE across a wiped marker, got $(nalerts)"
M=$(ls "$SD/stuck/" 2>/dev/null | head -1)
[ -n "$M" ] && [ "$(cat "$SD/stuck/$M")" = "stuck $K WAIT_CI $HA" ] && ok \
  || bad "S1: a row hit must warm the marker back: '$M' $(cat "$SD/stuck/$M" 2>/dev/null)"

echo "== S2. an outage: the files decide =="
reset; flag up
stuck t3 WAIT_CI "$HA" >/dev/null
wipe stuck; : > "$ATT"; touch "$T/rows-down"
[ "$(stuck t4 WAIT_CI "$HA")" = rc=0 ] && ok || bad "S2: an outage with no marker must page — never 'already paged' on a blink"
[ "$(nalerts)" = 2 ] && ok || bad "S2: want the second alert under the outage, got $(nalerts)"
[ -n "$(ls "$SD/stuck/")" ] && ok || bad "S2: the marker must still be written before the send"
grep -q 'latched off for tick t4' "$MCLOG" && ok || bad "S2: the outage must latch the tick off: $(cat "$MCLOG")"

echo "== S3. a page for one state does not dedupe another =="
reset; flag up
stuck t5 WAIT_CI "$HA" >/dev/null
wipe stuck; : > "$ATT"
[ "$(stuck t6 HEAD_MOVED "$HA")" = rc=0 ] && ok || bad "S3: (PR, WAIT_CI, head) must not dedupe (PR, HEAD_MOVED, head)"
[ "$(nalerts)" = 2 ] && ok || bad "S3: want 2 alerts, got $(nalerts)"

echo "== S4. gc: a marker with a line forgets its row, an empty one asks nothing =="
reset; flag up
stuck t7 WAIT_CI "$HA" >/dev/null
M=$(ls "$SD/stuck/" | head -1)
touch -d '15 days ago' "$SD/stuck/$M"
: > "$SD/stuck/empty-held-flush"; touch -d '15 days ago' "$SD/stuck/empty-held-flush"
: > "$REQ"
drv "" "mc_stuck_gc"
seen DELETE stuck "WAIT_CI $HA" && ok || bad "S4: gc must DELETE the stuck row: $(cat "$REQ")"
[ "$(nattreq)" = 1 ] && ok || bad "S4: exactly one row request (the empty marker makes none): $(cat "$REQ")"
[ -z "$(ls -A "$SD/stuck/")" ] && ok || bad "S4: both markers must be deleted: $(ls "$SD/stuck/")"

echo "== F1. flag down: no row traffic, today's files =="
reset; flag down
drv "" "mc_handoff_record '$K' $HA conflict-unresolvable '$U'; mc_handoff_release '$K' r"
park_row "$HA"
[ "$(sticky "$HA")" = rc=1 ] && ok || bad "F1: the release marker must still release the park"
wipe handoff handoff-released; park_row -
[ "$(sticky "$HA")" = rc=1 ] && ok || bad "F1: with the flag down a wiped marker is today's rc 1"
[ "$(stuck t8 WAIT_CI "$HA")" = rc=0 ] && ok || bad "F1: the stuck page must go out as today"
M=$(ls "$SD/stuck/" | head -1)
[ -n "$M" ] && [ ! -s "$SD/stuck/$M" ] && ok || bad "F1: the stuck marker must be today's EMPTY file"
[ "$(stuck t9 WAIT_CI "$HA")" = rc=1 ] && ok || bad "F1: the marker must still dedupe the page"
touch -d '15 days ago' "$SD/stuck/$M"; : > "$SD/handoff/o_r_5"; touch -d '15 days ago' "$SD/handoff/o_r_5"
drv "" "mc_stuck_gc; mc_handoff_gc"
[ "$(nattreq)" = 0 ] && ok || bad "F1: flag down must make no pr-attempts request: $(cat "$REQ")"
[ ! -s "$ATT" ] && ok || bad "F1: flag down must add no ledger line: $(cat "$ATT")"
[ "$(nalerts)" = 1 ] && ok || bad "F1: want exactly 1 alert, got $(nalerts)"

[ -s "$ERR" ] && grep -qE 'command not found|unbound variable' "$ERR" && bad "driver errors: $(cat "$ERR")"
echo "mc-markers-rows.bh-2358: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
