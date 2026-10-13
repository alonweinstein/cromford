#!/bin/bash
# tests/lead-review-chain-doorbell.bh-4057-test.sh — BH-4092 (BH-4057.0): the
# lead-chain doorbell's first producer and its lib.
#   D*  the REAL bin/lead-review-enqueue.sh `tick`, on the fixture of
#       tests/lead-review-enqueue.bh-3545-test.sh plus
#       "$DIR/bin/lib/lead-chain-wake.sh": a FRESH 201 rings exactly one
#       POST /api/wakes/lane for kind lead-review, through the real
#       bin/jobs-client.sh wake_lane_put; existing:true, a 409, a failed POST,
#       the kill switch and a 404 from the route ring nothing that counts.
#   L*  lcw_rerun and lcw_ring from "$DIR/bin/lib/lead-chain-wake.sh", sourced.
# The stub worker gains a "POST /api/wakes/lane" arm: 200 {inserted:1}, or a 404
# while $T/lane404 exists. Every worker request is logged
# "<METHOD> <path> <body> lead=<0|1>".
# Run from anywhere: HARNESS_TEST_SANDBOX=1 bash tests/lead-review-chain-doorbell.bh-4057-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
. "$(dirname "$0")/lib/rendered.sh" || exit 1
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }

H="$T/h"; mkdir -p "$H/bin/lib/jobs" "$H/flags" "$H/state" "$H/logs" "$T/fakebin" "$T/log" "$T/tmp" "$T/cfg"
# The lane and the jobs client with the bin/lib files each sources (BH-4552).
scratch_install_closure bin/lead-review-enqueue.sh "$H" >/dev/null \
  || { echo "FAIL: scratch_install_closure bin/lead-review-enqueue.sh"; exit 1; }
scratch_install_closure bin/jobs-client.sh "$H" >/dev/null \
  || { echo "FAIL: scratch_install_closure bin/jobs-client.sh"; exit 1; }
# The doorbell lib is sourced fail-open, so a closure that stopped finding it
# would turn D1 into a quiet rc 3. Say so here instead.
[ -f "$H/bin/lib/lead-chain-wake.sh" ] \
  || { echo "FAIL: bin/lib/lead-chain-wake.sh is missing from the enqueue closure"; exit 1; }
printf 'lead-test-token\n' > "$T/cfg/token"; chmod 600 "$T/cfg/token"
printf 'demo-os example-org/demo-os https://demo.test /api 3 box-hub\n' > "$H/fleet.conf"

SHA=$(printf 'a%.0s' {1..40}); SHA12=${SHA:0:12}
OLD=$(printf 'c%.0s' {1..40})
S42=$(printf 'd%.0s' {1..40}); S43=$(printf 'e%.0s' {1..40})

cat > "$T/fakebin/curl" <<EOF
#!/bin/bash
m=GET; body=""; url=""; prev=""; hdrs=""
for a in "\$@"; do
  case "\$prev" in
    -X) m="\$a" ;;
    --data-binary|-d|--data) body="\$a" ;;
    -H) case "\$a" in @*) hdrs="\$hdrs\$(cat "\${a#@}")"\$'\n' ;; *) hdrs="\$hdrs\$a"\$'\n' ;; esac ;;
  esac
  case "\$a" in http*) url="\$a" ;; esac
  prev="\$a"
done
case "\$body" in @*) body=\$(cat "\${body#@}") ;; esac
lead=0; grep -q '^x-lead-verdict-token: lead-test-token' <<<"\$hdrs" && lead=1
p="\${url#https://jobs.test}"
printf '%s %s %s lead=%s\n' "\$m" "\$p" "\$body" "\$lead" >> "$T/log/worker"
[ -f "$T/lrrows.json" ] || echo '[]' > "$T/lrrows.json"
qp() { printf '%s' "\${p#*\?}" | tr '&' '\n' | sed -n "s/^\$1=//p" | head -1; }
code=200; out='{}'
case "\$m \$p" in
  "GET /api/verdict?pr="*)
    n="\${p##*%2F}"
    if [ -f "$T/jv/\$n.json" ]; then out=\$(cat "$T/jv/\$n.json"); else code=404; out='{"error":"no job for this pr"}'; fi ;;
  "GET /api/verdicts?"*)
    n=\$(qp pr)
    if [ -f "$T/standing/\$n" ]; then st=\$(cat "$T/standing/\$n"); else st=null; fi
    out=\$(jq -nc --argjson s "\$st" '{standing:\$s, rows:[], truncated:false}') ;;
  "POST /api/lead-reviews")
    if [ "\$lead" != 1 ]; then code=403; out='{"error":"needs the lead token"}'
    else
      r=\$(jq -r .repo <<<"\$body"); pr=\$(jq -r .pr <<<"\$body"); h=\$(jq -r .head_sha <<<"\$body"); nt=\$(jq -r '.scope_notes // ""' <<<"\$body")
      have=\$(jq -c --arg r "\$r" --argjson p "\$pr" --arg h "\$h" '[.[] | select(.repo == \$r and .pr == \$p and .head_sha == \$h)] | first // empty' "$T/lrrows.json")
      if [ -n "\$have" ] && [ ! -e "$T/force201" ]; then
        if [ "\$(jq -r '.scope_notes // ""' <<<"\$have")" = "\$nt" ]; then out=\$(jq -c '{request:., existing:true}' <<<"\$have")
        else code=409; out=\$(jq -c '{error:"a request for this head exists with other notes", request:.}' <<<"\$have"); fi
      else
        n=\$(jq length "$T/lrrows.json")
        row=\$(jq -c --arg id "lr-\$((n + 1))" '. + {id:\$id, status:"requested"}' <<<"\$body")
        jq -c --argjson r "\$row" '. + [\$r]' "$T/lrrows.json" > "$T/lrrows.tmp" && mv "$T/lrrows.tmp" "$T/lrrows.json"
        code=201; out=\$(jq -c '{request:.}' <<<"\$row")
      fi
    fi ;;
  "POST /api/wakes/lane")
    if [ -e "$T/lane404" ]; then code=404; out='{"error":"unknown endpoint","worker":"harness-jobs"}'
    else out='{"inserted":1,"as_of":"2026-10-03T00:00:00Z"}'; fi ;;
  *) code=404; out='{"error":"unknown endpoint","worker":"harness-jobs"}' ;;
esac
printf '%s\n%s' "\$out" "\$code"
EOF
cat > "$T/fakebin/gh" <<EOF
#!/bin/bash
printf '%s\n' "\$*" >> "$T/log/gh"
case "\$*" in
  *"api rate_limit"*)
    echo '{"resources":{"core":{"remaining":5000,"limit":5000,"reset":2000000000},"graphql":{"remaining":5000,"limit":5000,"reset":2000000000}}}' ;;
  *"-X GET repos/example-org/demo-os/pulls?"*)
    printf 'HTTP/2 200\r\n\r\n'; cat "$T/prs.json" ;;
  *"-X GET repos/example-org/demo-os/pulls/"*)
    a="\$*"; n="\${a##*/pulls/}"; n="\${n%% *}"
    if [ -e "$T/head500/\$n" ]; then printf 'HTTP/2 500\r\n\r\n{"message":"boom"}\n'
    else printf 'HTTP/2 200\r\n\r\n'; jq -nc --arg s "\$(cat "$T/head/\$n")" '{head:{sha:\$s},base:{ref:"main"}}'; fi ;;
  *"-X GET repos/example-org/demo-os/compare/"*)
    a="\$*"; h="\${a##*...}"; h="\${h%% *}"
    if [ -e "$T/cmp500" ]; then printf 'HTTP/2 500\r\n\r\n{"message":"boom"}\n'
    elif [ -f "$T/cmp/\$h.json" ]; then printf 'HTTP/2 200\r\n\r\n'; cat "$T/cmp/\$h.json"
    else printf 'HTTP/2 200\r\n\r\n{"total_commits":1,"commits":[{"parents":[{"sha":"p"}],"commit":{"message":"feat: the thing"}}]}\n'; fi ;;
esac
exit 0
EOF
cat > "$H/bin/lane-alert.sh" <<EOF
#!/bin/bash
printf '%s\n' "\$*" >> "$T/log/alerts"
exit 0
EOF
cat > "$H/bin/agent-call.sh" <<EOF
#!/bin/bash
printf '%s\n' "\$*" >> "$T/log/agent"
exit 0
EOF
chmod +x "$T/fakebin/curl" "$T/fakebin/gh" "$H/bin/lane-alert.sh" "$H/bin/agent-call.sh"

export PATH="$T/fakebin:$PATH" HARNESS="$H" HARNESS_SECRET=test-secret JOBS_URL=https://jobs.test \
  JOBS_RETRIES=0 TMPDIR="$T/tmp" LANE_GATE_DISABLE=1 LEAD_VERDICT_TOKEN_FILE="$T/cfg/token" \
  FLEET_CONF="$H/fleet.conf" GH_ETAG=0 LEAD_REVIEW_AUTO_REPOS=example-org/demo-os \
  LEAD_REVIEW_ENQUEUE_MAX_PER_TICK=5 LEAD_REVIEW_MAX_PER_PR_DAY=4
unset BOX_NAME JOBS_BOX HUB_BOX_NAME

# pr <n> <head> [draft] — an open harness PR on example-org/demo-os at <head>
pr() {
  jq -c --argjson n "$1" --arg h "$2" --argjson d "${3:-false}" '. + [{number:$n, html_url:("https://github.com/example-org/demo-os/pull/"+($n|tostring)),
    title:"t", draft:$d, state:"open", user:{login:"operator",type:"User"}, head:{sha:$h,ref:("ticket/bh-"+($n|tostring))}, base:{ref:"main"}}]' \
    "$T/prs.json" > "$T/prs.tmp" && mv "$T/prs.tmp" "$T/prs.json"
  echo "$2" > "$T/head/$1"
}
# approve <n> <reviewed_sha> [headbound] — the builder's ledger verdict row
approve() {
  jq -nc --arg s "$2" --arg hb "${3:-n/a}" '{verdict:"APPROVE", tier:"2", provenance:"-", merge_sha:null, job_id:"job-1", reviewed_sha:$s,
    artifacts:[{artifact_kind:"verdict", detail:({tier:"2", headbound:$hb, reviewed_sha:$s, settled:true}|tojson)}]}' > "$T/jv/$1.json"
}
# commits <head> <json array of [parents, message]> — the compare answer for that head
commits() {
  jq -nc --argjson c "$2" '{total_commits:($c|length), commits:[$c[] | {parents:[range(.[0]) | {sha:"p"}], commit:{message:.[1]}}]}' > "$T/cmp/$1.json"
}
reset() {
  rm -f "$T/log"/* "$T"/{cmp500,force201,lrrows.json,lane404} "$H/logs"/* "$H/flags"/*
  scratch_rm "$H/state"; mkdir -p "$H/state"
  for d in jv standing head head500 cmp; do scratch_rm "$T/$d"; mkdir -p "$T/$d"; done
  echo box-hub > "$H/state/box-name"
  echo '[]' > "$T/prs.json"
}
happy() { reset; pr 41 "$SHA"; approve 41 "$SHA"; }
tick() { ( cd "$T" && bash "$H/bin/lead-review-enqueue.sh" tick ) > "$T/out" 2>&1; RC=$?; }
wlog() { cat "$T/log/worker" 2>/dev/null; }
posts() { wlog | grep -c '^POST /api/lead-reviews ' ; }
summ() { grep ' tick repos=' "$H/logs/lead-review-enqueue.log" 2>/dev/null | tail -1; }
has() { summ | grep -qw -- "$1"; }
alines() { cat "$T/log/alerts" 2>/dev/null; }
acount() { alines | grep -c -- "$1"; }
LEDGER="$H/state/lead-review-enqueue/requested.tsv"
lrows() { jq length "$T/lrrows.json" 2>/dev/null || echo 0; }
lines() { [ -f "$1" ] && wc -l < "$1" | tr -d ' ' || echo 0; }

lanes() { wlog | grep -c '^POST /api/wakes/lane ' ; }
lanebody() { wlog | sed -n 's#^POST /api/wakes/lane \(.*\) lead=.$#\1#p' | sed -n "${1:-1}p"; }
LOGF="$H/logs/lead-review-enqueue.log"
endsrung() { summ | grep -q " rung=$1\$"; }

# ── D1: one fresh APPROVE'd PR -> one 201, exactly one lead-review ring ──
happy; tick
[ "$RC" -eq 0 ] && ok || bad "D1 rc=$RC out=$(cat "$T/out")"
[ "$(posts)" = 1 ] && ok || bad "D1 want one POST /api/lead-reviews, got $(posts): $(wlog)"
[ "$(lanes)" = 1 ] && ok || bad "D1 want one POST /api/wakes/lane, got $(lanes): $(wlog)"
[ "$(lanebody)" = "{\"repo\":\"example-org/demo-os\",\"kind\":\"lead-review\",\"key\":41,\"dedupe\":\"lead-review:41@$SHA12\"}" ] \
  && ok || bad "D1 lane body: $(lanebody)"
grep -q "example-org/demo-os#41 @$SHA12: lead-review doorbell rung" "$LOGF" 2>/dev/null && ok || bad "D1 no 'doorbell rung' line: $(cat "$LOGF" 2>/dev/null)"
endsrung 1 && ok || bad "D1 summary does not end rung=1: $(summ)"
has requested=1 && ok || bad "D1 summary: $(summ)"
# the ring comes AFTER the 201, never before it
L1=$(wlog | grep -n -m1 '^POST /api/lead-reviews ' | cut -d: -f1); L2=$(wlog | grep -n -m1 '^POST /api/wakes/lane ' | cut -d: -f1)
[ -n "$L1" ] && [ -n "$L2" ] && [ "$L1" -lt "$L2" ] && ok || bad "D1 the ring is not after the request: $(wlog)"

# ── D2: existing:true, a 409, a failed POST ring nothing; a new head rings once ──
rm -f "$T/log/worker"; tick
[ "$(posts)" = 1 ] && has existing=1 && ok || bad "D2 tick 2 want one re-confirm: $(summ)"
[ "$(lanes)" = 0 ] && ok || bad "D2 existing:true rang: $(wlog)"
endsrung 0 && ok || bad "D2 existing summary: $(summ)"
# 409: a row for this head with other notes
happy; jq -nc --arg h "$SHA" '[{repo:"example-org/demo-os", pr:41, head_sha:$h, scope_notes:"by hand", id:"lr-9", status:"requested"}]' > "$T/lrrows.json"; tick
grep -q 'a request with other notes already exists (lr-9)' "$LOGF" 2>/dev/null && ok || bad "D2 the 409 path was not taken: $(cat "$LOGF")"
[ "$(lanes)" = 0 ] && endsrung 0 && ok || bad "D2 a 409 rang: $(wlog) / $(summ)"
# a failed POST: the worker refuses the token
happy; printf 'wrong-token\n' > "$T/cfg/bad"; chmod 600 "$T/cfg/bad"; LEAD_VERDICT_TOKEN_FILE="$T/cfg/bad" tick
[ "$(posts)" = 1 ] && has unreadable=1 && ok || bad "D2 the failed POST path was not taken: $(summ)"
[ "$(lanes)" = 0 ] && endsrung 0 && ok || bad "D2 a failed POST rang: $(wlog) / $(summ)"
# a new head on the same PR is a new ring with the new sha12
happy; tick; NEW=$(printf 'b%.0s' {1..40}); echo "$NEW" > "$T/head/41"; approve 41 "$NEW"; rm -f "$T/log/worker"; tick
[ "$(lanes)" = 1 ] && ok || bad "D2 a new head want one more ring, got $(lanes): $(wlog)"
[ "$(jq -r .dedupe <<<"$(lanebody)" 2>/dev/null)" = "lead-review:41@${NEW:0:12}" ] && ok || bad "D2 new head dedupe: $(lanebody)"

# ── D5: the kill switch: the 201 is still made, nothing rings ──
happy; touch "$H/flags/lead-chain-wake-off"; tick
[ "$(posts)" = 1 ] && has requested=1 && ok || bad "D5 the request itself must still go: $(summ)"
[ "$(lanes)" = 0 ] && ok || bad "D5 rang under the kill switch: $(wlog)"
grep -q "example-org/demo-os#41 @$SHA12: doorbell not rung (rc 1)" "$LOGF" && ok || bad "D5 log: $(cat "$LOGF")"
endsrung 0 && ok || bad "D5 summary: $(summ)"

# ── D6: the route is not deployed (404): rc 0, rung=0, the cron covers it ──
happy; : > "$T/lane404"; tick
[ "$RC" -eq 0 ] && ok || bad "D6 rc=$RC"
[ "$(lanes)" = 1 ] && ok || bad "D6 want the one attempt, got $(lanes)"
grep -qF "example-org/demo-os#41 @$SHA12: doorbell not rung (rc 2); the */15 cron covers it" "$LOGF" && ok || bad "D6 log: $(cat "$LOGF")"
endsrung 0 && has requested=1 && ok || bad "D6 summary: $(summ)"
# ...and a box without the lib (rc 3) behaves as before
happy; rm -f "$H/bin/lib/lead-chain-wake.sh"; tick
[ "$(posts)" = 1 ] && [ "$(lanes)" = 0 ] && endsrung 0 && ok || bad "D6 no lib: $(wlog) / $(summ)"
grep -qF "doorbell not rung (rc 3)" "$LOGF" && ok || bad "D6 no-lib log: $(cat "$LOGF")"
scratch_install_closure bin/lead-review-enqueue.sh "$H" >/dev/null || exit 1

# ── L: the lib, sourced into a clean shell ──
LIB="$DIR/bin/lib/lead-chain-wake.sh"
SD="$T/lst"; STUB="$T/rerun-stub.sh"
cat > "$STUB" <<EOF
#!/bin/bash
echo "\${LEAD_CHAIN_RERUN_DEPTH:-unset} \$*" >> "$T/rerun.log"
for f in /proc/\$\$/fd/*; do readlink "\$f"; done >> "$T/rerun.fds"
sleep "\${STUB_SLEEP:-0}"
EOF
chmod +x "$STUB"
lreset() { scratch_rm "$SD"; rm -f "$T/rerun.log" "$T/rerun.fds"; mkdir -p "$SD"; }
waitlog() { local i; for i in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do [ -s "$T/rerun.log" ] && return 0; sleep 0.1; done; return 1; }
rlines() { [ -f "$T/rerun.log" ] && wc -l < "$T/rerun.log" | tr -d ' ' || echo 0; }

# L1: a marker, depth 0, knob 3 -> one launch at depth 1, marker gone, one line
lreset; : > "$SD/rerun-owed"
OUT=$(unset LEAD_CHAIN_RERUN_DEPTH; . "$LIB" && lcw_rerun "$STUB" "$SD" 3 0 tick); LRC=$?
waitlog; sleep 0.3
[ "$LRC" = 0 ] && ok || bad "L1 rc=$LRC out=$OUT"
[ "$OUT" = "rerun owed (depth 1/3)" ] && ok || bad "L1 printed: '$OUT'"
[ "$(rlines)" = 1 ] && [ "$(cat "$T/rerun.log")" = "1 tick" ] && ok || bad "L1 the stub ran: '$(cat "$T/rerun.log" 2>/dev/null)'"
[ ! -e "$SD/rerun-owed" ] && ok || bad "L1 the marker survived"
# force=1 with no marker launches too; no marker and no force is silent
lreset; OUT=$(unset LEAD_CHAIN_RERUN_DEPTH; . "$LIB" && lcw_rerun "$STUB" "$SD" 3 1 tick); LRC=$?; waitlog
[ "$LRC" = 0 ] && [ "$(rlines)" = 1 ] && ok || bad "L1 force=1 rc=$LRC runs=$(rlines)"
lreset; OUT=$(unset LEAD_CHAIN_RERUN_DEPTH; . "$LIB" && lcw_rerun "$STUB" "$SD" 3 0 tick); LRC=$?; sleep 0.5
[ "$LRC" = 1 ] && [ -z "$OUT" ] && [ "$(rlines)" = 0 ] && ok || bad "L1 no trigger: rc=$LRC out='$OUT' runs=$(rlines)"
# with no force argument the extra args start at position 4
lreset; : > "$SD/rerun-owed"; OUT=$(unset LEAD_CHAIN_RERUN_DEPTH; . "$LIB" && lcw_rerun "$STUB" "$SD" 3 tick x); waitlog
[ "$(cat "$T/rerun.log" 2>/dev/null)" = "1 tick x" ] && ok || bad "L1 no-force args: '$(cat "$T/rerun.log" 2>/dev/null)'"

# L2: depth reached -> no launch, rc 1, the marker cleared
lreset; : > "$SD/rerun-owed"
OUT=$(export LEAD_CHAIN_RERUN_DEPTH=3; . "$LIB" && lcw_rerun "$STUB" "$SD" 3 0 tick); LRC=$?; sleep 0.5
[ "$LRC" = 1 ] && [ "$(rlines)" = 0 ] && ok || bad "L2 rc=$LRC runs=$(rlines)"
[ "$OUT" = "rerun owed but depth 3/3 reached; cron covers it" ] && ok || bad "L2 printed: '$OUT'"
[ ! -e "$SD/rerun-owed" ] && ok || bad "L2 the marker survived the depth bound"

# L3: an off knob (0, empty, abc) -> no launch, an off line, the marker kept
for k in 0 '' abc; do
  lreset; : > "$SD/rerun-owed"
  OUT=$(unset LEAD_CHAIN_RERUN_DEPTH; . "$LIB" && lcw_rerun "$STUB" "$SD" "$k" 0 tick); LRC=$?; sleep 0.3
  [ "$LRC" = 1 ] && [ "$(rlines)" = 0 ] && ok || bad "L3 knob '$k' rc=$LRC runs=$(rlines)"
  [ "$OUT" = "rerun owed but off (max='$k')" ] && ok || bad "L3 knob '$k' printed: '$OUT'"
  [ -e "$SD/rerun-owed" ] && ok || bad "L3 knob '$k' dropped the marker"
done

# L4: the caller's fd 9 lock is never inherited by the rerun
lreset; : > "$SD/rerun-owed"
( exec 9>"$T/held.lock"; flock -n 9 || exit 9
  unset LEAD_CHAIN_RERUN_DEPTH; export STUB_SLEEP=3
  . "$LIB" && lcw_rerun "$STUB" "$SD" 3 0 tick >/dev/null )
waitlog
if flock -n "$T/held.lock" true; then ok; else bad "L4 the rerun child holds the caller's fd 9 lock"; fi
! grep -q 'held.lock' "$T/rerun.fds" 2>/dev/null && ok || bad "L4 fds: $(cat "$T/rerun.fds")"

# L5: lcw_ring refuses bad input before any call (rc 1, no lane POST)
rm -f "$T/log/worker"
ring() { ( . "$H/bin/jobs-client.sh" && . "$LIB" && lcw_ring "$@" ) >/dev/null 2>&1; }
ring lead-review example-org/demo-os 41 "${SHA:0:39}"; [ "$?" = 1 ] && ok || bad "L5 a 39-hex head was not rc 1"
ring lead-review example-org/demo-os 12a "$SHA";      [ "$?" = 1 ] && ok || bad "L5 a 12a pr was not rc 1"
ring lead-review noslash 41 "$SHA";                 [ "$?" = 1 ] && ok || bad "L5 a noslash slug was not rc 1"
ring '' example-org/demo-os 41 "$SHA";                [ "$?" = 1 ] && ok || bad "L5 an empty kind was not rc 1"
[ "$(lanes)" = 0 ] && ok || bad "L5 a refused ring still POSTed: $(wlog)"
# an upper-case head is lowercased; no wake_lane_put in the shell is rc 2
ring lead-land example-org/demo-os 41 "$(tr a-f A-F <<<"$SHA")"; [ "$?" = 0 ] && ok || bad "L5 an upper-case head was refused"
[ "$(jq -r .dedupe <<<"$(lanebody)" 2>/dev/null)" = "lead-land:41@$SHA12" ] && ok || bad "L5 dedupe: $(lanebody)"
( . "$LIB" && lcw_ring lead-review example-org/demo-os 41 "$SHA" ) >/dev/null 2>&1; [ "$?" = 2 ] && ok || bad "L5 no wake_lane_put was not rc 2"

echo "lead-review-chain-doorbell.bh-4057: PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
