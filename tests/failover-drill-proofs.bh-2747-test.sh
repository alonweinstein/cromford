#!/bin/bash
# tests/failover-drill-proofs.bh-2747-test.sh — the four proofs of the failover
# drill (BH-2747, parent #402) in bin/lib/failover-drill-proofs.sh.
#
# Sources the REAL bin/lib/failover-drill-common.sh and
# bin/lib/failover-drill-proofs.sh from a scratch harness root, with the REAL
# bin/jobs-client.sh + bin/lib/jobs/*.sh behind fd_api_get and queue_put. Three
# things are stubbed: curl (plays the console and the jobs worker, answering
# $STUB_DIR/<route>.body/.code/.rc), ssh (through the FAILOVER_DRILL_SSH seam,
# answering $STUB_DIR/ssh.out/.rc) and sleep. curl and sleep append to ONE
# sequence log ($T/seq.log), so request and sleep counts are assertions.
#
# Run from anywhere: tests/failover-drill-proofs.bh-2747-test.sh   (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
eq()  { if [ "$2" = "$3" ]; then ok; else bad "$1: got [$2] want [$3]"; fi; }
has() { case "$2" in *"$3"*) ok ;; *) bad "$1: [$2] does not contain [$3]" ;; esac; }
verdict() { local v="PROOF_${1}_VERDICT"; printf '%s' "${!v:-<unset>}"; }
detail()  { local d="PROOF_${1}_DETAIL"; printf '%s' "${!d:-<unset>}"; }
notok()   { if [ "$(verdict "$2")" = OK ]; then bad "$1: proof $2 is OK ($(detail "$2"))"; else ok; fi; }

H="$T/h"
mkdir -p "$H/bin/lib/jobs" "$H/logs" "$H/flags" "$H/env" "$H/state" "$T/fakebin"
for f in "$DIR/bin/lib/failover-drill-common.sh" "$DIR/bin/lib/failover-drill-proofs.sh" \
         "$DIR/bin/lib/env-path.sh"; do
  cp "$f" "$H/bin/lib/" || { echo "FAIL: missing $f"; exit 1; }
done
cp "$DIR/bin/jobs-client.sh" "$H/bin/" || { echo "FAIL: missing bin/jobs-client.sh"; exit 1; }
cp "$DIR"/bin/lib/jobs/*.sh "$H/bin/lib/jobs/" || { echo "FAIL: missing bin/lib/jobs"; exit 1; }
: > "$H/env/global.env"
echo testbox > "$H/state/box-name"

# curl: one line per request, `METHOD URL BODY` (headers are never logged, so
# the bearer cannot leak into an assertion by way of the stub).
cat > "$T/fakebin/curl" <<'EOF'
#!/bin/bash
m=GET url="" data=""
while [ $# -gt 0 ]; do
  case "$1" in
    -X) m="$2"; shift 2 ;;
    --data-binary) data="$2"; shift 2 ;;
    -m|--connect-timeout|-w|-H) shift 2 ;;
    http*) url="$1"; shift ;;
    *) shift ;;
  esac
done
printf '%s %s %s\n' "$m" "$url" "$data" >> "$SEQ"
case "$url" in
  */api/dash/action) case "$data" in *failover_drill_ping*) r=ping ;; *) r=chat ;; esac ;;
  */api/dash/commands*) r=status ;;
  */api/queue) r=queue ;;
  */api/machines*) r=machines ;;
  */api/hub/recovery) r=recovery ;;
  */api/ledger*) r=ledger ;;
  */api/alerts*) r=alerts ;;
  *) r=unknown ;;
esac
[ -f "$STUB_DIR/$r.rc" ] && exit "$(cat "$STUB_DIR/$r.rc")"
code=200; [ -f "$STUB_DIR/$r.code" ] && code=$(cat "$STUB_DIR/$r.code")
printf '%s\n%s' "$(cat "$STUB_DIR/$r.body" 2>/dev/null)" "$code"
EOF
cat > "$T/fakebin/ssh" <<'EOF'
#!/bin/bash
printf 'SSH %s\n' "$*" >> "$SEQ"
cat "$STUB_DIR/ssh.out" 2>/dev/null
exit "$(cat "$STUB_DIR/ssh.rc" 2>/dev/null || echo 0)"
EOF
cat > "$T/fakebin/sleep" <<'EOF'
#!/bin/bash
printf 'SLEEP %s\n' "$*" >> "$SEQ"
EOF
chmod +x "$T/fakebin/curl" "$T/fakebin/ssh" "$T/fakebin/sleep"

NOW=1700000000
SECRET=sekret-bh2747
HUB=box-hub SB=box-2
TP=$((NOW-600)) TB=$((NOW-60)) SETTLE=60
iso()  { date -u -d "@$1" +%Y-%m-%dT%H:%M:%SZ; }
isom() { date -u -d "@$1" +%Y-%m-%dT%H:%M:%S.408Z; }
export STUB_DIR="$T/stub" SEQ="$T/seq.log" PATH="$T/fakebin:$PATH" HARNESS="$H" \
  FAILOVER_DRILL_NOW=$NOW FAILOVER_DRILL_SSH="$T/fakebin/ssh" \
  CONSOLE_URL=https://console.test JOBS_URL=https://jobs.test HARNESS_SECRET=$SECRET \
  JOBS_RETRIES=0 JOBS_ALERT=0 FAILOVER_DRILL_POOL_PROJECT=demo
unset FAILOVER_DRILL_PROOF_DEADLINE_S FAILOVER_DRILL_POLL_S \
  FAILOVER_DRILL_CONSOLE_ENQUEUE_PATH FAILOVER_DRILL_CONSOLE_STATUS_PATH

# The recovery page: the watchdog's promote lands BEFORE t_promote (the drill
# observes it one poll later), the promote back lands inside the window.
recovery_rows() { # extra rows (JSON objects, comma-led) are appended
  printf '{"recent_changes":[{"action":"promote","after_holder":"%s","actor":"console","outcome":"ok","at":"%s"},{"action":"promote","after_holder":"%s","actor":"watchdog","outcome":"ok promoted","at":"%s"}%s],"truncated":%s}' \
    "$HUB" "$(isom $((TB-5)))" "$SB" "$(isom $((TP-10)))" "${1:-}" "${2:-false}"
}

reset() {
  scratch_rm "$STUB_DIR" || exit 1; mkdir -p "$STUB_DIR"; : > "$SEQ"
  unset PROOF_1_VERDICT PROOF_1_DETAIL PROOF_2_VERDICT PROOF_2_DETAIL \
    PROOF_3_VERDICT PROOF_3_DETAIL PROOF_4_VERDICT PROOF_4_DETAIL
  echo '{"command_id":"101"}' > "$STUB_DIR/ping.body"
  echo '{"command_id":"102"}' > "$STUB_DIR/chat.body"
  echo '{"commands":[{"id":101,"result":"unknown command type failover_drill_ping"},{"id":102,"result":"handed to orchestrator"}]}' > "$STUB_DIR/status.body"
  echo $((NOW+5)) > "$STUB_DIR/ssh.out"; echo 0 > "$STUB_DIR/ssh.rc"
  echo '{"ok":true}' > "$STUB_DIR/queue.body"
  echo '{"machines":[{"key":"FAILOVER-DRILL-r1","project":"demo","state":"spawned"}]}' > "$STUB_DIR/machines.body"
  recovery_rows > "$STUB_DIR/recovery.body"
  printf '{"ledgers":[{"kind":"merge","key":"pr-9","actor":"%s","updated_at":"%s"},{"kind":"merge","key":"pr-8","actor":"%s","updated_at":"%s"}]}' \
    "$SB" "$(isom $((TP+100)))" "$HUB" "$(iso $((TP-100)))" > "$STUB_DIR/ledger.body"
  echo '{"alerts":[],"truncated":false}' > "$STUB_DIR/alerts.body"
}
p1() { fd_proof_poll_commands r1 10.0.0.2; }
p2() { fd_proof_chat r1 10.0.0.2; }
p3() { fd_proof_pool r1; }
p4() { fd_proof_ledger r1 "$HUB" "$SB" "$TP" "$TB" "$SETTLE"; }
count() { grep -c -- "$1" "$SEQ"; }

# shellcheck source=bin/lib/failover-drill-common.sh
. "$H/bin/lib/failover-drill-common.sh" || exit 1
# shellcheck source=bin/lib/failover-drill-proofs.sh
. "$H/bin/lib/failover-drill-proofs.sh" || exit 1

# --- Q1: happy stubs, all four OK, four lines --------------------------------
reset
p1; eq "Q1 p1 rc" "$?" 0
p2; eq "Q1 p2 rc" "$?" 0
p3; eq "Q1 p3 rc" "$?" 0
p4; eq "Q1 p4 rc" "$?" 0
lines=$(fd_proof_line 1 poll-commands; fd_proof_line 2 chat; fd_proof_line 3 pool; fd_proof_line 4 ledger)
eq "Q1 four OK lines" "$(printf '%s\n' "$lines" | grep -cE '^PROOF [1-4] [a-z-]+: OK — ')" 4
[ "$(printf '%s\n' "$lines" | grep -c .)" = 4 ] && ok || bad "Q1 line count: [$lines]"
seq=$(cat "$SEQ")
has "Q1 ping body" "$seq" 'POST https://console.test/api/dash/action {"type":"failover_drill_ping","run":"r1"}'
has "Q1 chat body" "$seq" '"type":"chat","project":"orchestrator","text":"failover drill r1: reply with the single word ok"'
has "Q1 queue key" "$seq" '"key":"FAILOVER-DRILL-r1"'
has "Q1 queue target" "$seq" '"target":"fly"'
has "Q1 machines filter" "$seq" 'GET https://jobs.test/api/machines?project=demo&key=FAILOVER-DRILL-r1'
has "Q1 ledger cursor" "$seq" "GET https://jobs.test/api/ledger?kind=merge&limit=1000&before=$(iso $((TB+1)))"
has "Q1 alerts claimed_since_s" "$seq" "GET https://jobs.test/api/alerts?claimed_since_s=$((NOW-TP+1))&limit=500"
eq "Q1 enqueues sent once each" "$(count 'POST https://console.test/api/dash/action')" 2
eq "Q1 no sleep" "$(count '^SLEEP')" 0
has "Q1 ssh reads last-reply" "$seq" "SSH root@10.0.0.2"
has "Q1 ssh file" "$seq" "/root/orchestrator/last-reply.txt"
case "$(detail 1)$(detail 2)$(detail 3)$(detail 4)$seq" in
  *"$SECRET"*|*Bearer*) bad "Q1 the secret reached a detail or the request log" ;; *) ok ;; esac

# --- Q2: pool project unset -> UNPROVEN, nothing enqueued --------------------
reset
FAILOVER_DRILL_POOL_PROJECT='' p3
eq "Q2 verdict" "$(verdict 3)" UNPROVEN
eq "Q2 line" "$(fd_proof_line 3 pool)" "PROOF 3 pool: UNPROVEN — not configured"
eq "Q2 no queue POST" "$(count 'POST .*/api/queue')" 0
(unset FAILOVER_DRILL_POOL_PROJECT; p3; [ "$(verdict 3)" = UNPROVEN ]) && ok || bad "Q2 unset (not empty) is not UNPROVEN"
eq "Q2 no queue POST (unset)" "$(count 'POST .*/api/queue')" 0

# --- Q3: a merge row in the window written by the hub -> FAIL ----------------
reset
printf '{"ledgers":[{"kind":"merge","key":"pr-9","actor":"%s","updated_at":"%s"},{"kind":"merge","key":"pr-7","actor":"%s","updated_at":"%s"}]}' \
  "$SB" "$(isom $((TP+100)))" "$HUB" "$(isom $((TP+200)))" > "$STUB_DIR/ledger.body"
p4
eq "Q3 verdict" "$(verdict 4)" FAIL
has "Q3 detail names hub" "$(detail 4)" "b: merge ledger pr-7 written by $HUB"

# --- Q4: console enqueue 404 -> UNPROVEN, no status read ---------------------
reset
echo 404 > "$STUB_DIR/ping.code"; echo '{"error":"not found"}' > "$STUB_DIR/ping.body"
p1
eq "Q4 verdict" "$(verdict 1)" UNPROVEN
has "Q4 detail" "$(detail 1)" "enqueue http=404"
eq "Q4 no status GET" "$(count 'GET https://console.test/api/dash/commands')" 0

# --- Q5: a second promote to the standby in the window -> FAIL ---------------
reset
recovery_rows "$(printf ',{"action":"promote","after_holder":"%s","actor":"watchdog","outcome":"ok","at":"%s"}' "$SB" "$(iso $((TP+300)))")" \
  > "$STUB_DIR/recovery.body"
p4
eq "Q5 verdict" "$(verdict 4)" FAIL
has "Q5 detail" "$(detail 4)" "a: 2 promotes to $SB / 1 back to $HUB in window"

# --- Q6: the ack never arrives: D=90, P=30 -> 3 status GETs, 2 sleeps --------
reset
echo '{"commands":[]}' > "$STUB_DIR/status.body"
FAILOVER_DRILL_PROOF_DEADLINE_S=90 FAILOVER_DRILL_POLL_S=30 p1
eq "Q6 status GETs" "$(count 'GET https://console.test/api/dash/commands')" 3
eq "Q6 sleeps" "$(count '^SLEEP 30$')" 2
eq "Q6 all sleeps" "$(count '^SLEEP')" 2
eq "Q6 verdict" "$(verdict 1)" UNPROVEN
has "Q6 detail" "$(detail 1)" "command 101 not acked within 90s"

# --- Q7: a garbage deadline falls back to 600/30 -> 20 GETs -------------------
reset
echo '{"commands":[]}' > "$STUB_DIR/status.body"
FAILOVER_DRILL_PROOF_DEADLINE_S=abc p1
eq "Q7 status GETs" "$(count 'GET https://console.test/api/dash/commands')" 20
eq "Q7 sleeps" "$(count '^SLEEP 30$')" 19
reset
echo '{"commands":[]}' > "$STUB_DIR/status.body"
FAILOVER_DRILL_PROOF_DEADLINE_S=60 FAILOVER_DRILL_POLL_S=-5 p1
eq "Q7 garbage poll -> 30s" "$(count '^SLEEP 30$')" 1

# --- N1: console 200 with an empty body -> UNPROVEN ---------------------------
reset
: > "$STUB_DIR/ping.body"
p1
eq "N1 verdict" "$(verdict 1)" UNPROVEN
has "N1 detail" "$(detail 1)" "enqueue answered with no command id"
eq "N1 no status GET" "$(count 'GET https://console.test/api/dash/commands')" 0
eq "N1 sent once" "$(count 'POST https://console.test/api/dash/action')" 1
reset
echo '{"ok":true}' > "$STUB_DIR/ping.body"
p1; eq "N1b 2xx without an id" "$(verdict 1)" UNPROVEN
reset
echo '{"command_id":"1; rm -rf /"}' > "$STUB_DIR/ping.body"
p1; eq "N1c malformed id" "$(verdict 1)" UNPROVEN

# --- N2: an ok:true / matching ack for ANOTHER id -> not OK -------------------
reset
echo '{"commands":[{"id":999,"ok":true,"result":"unknown command type failover_drill_ping"},{"id":1010,"ok":true,"result":"unknown command type failover_drill_ping"}]}' > "$STUB_DIR/status.body"
FAILOVER_DRILL_PROOF_DEADLINE_S=30 p1
notok "N2" 1
eq "N2 verdict" "$(verdict 1)" UNPROVEN

# --- N3: last-reply.txt older than the enqueue -> FAIL ------------------------
reset
echo $((NOW-100)) > "$STUB_DIR/ssh.out"
FAILOVER_DRILL_PROOF_DEADLINE_S=60 p2
eq "N3 verdict" "$(verdict 2)" FAIL
has "N3 detail" "$(detail 2)" "no orchestrator reply since enqueue"
eq "N3 polled ssh twice" "$(count '^SSH')" 2
reset
echo none > "$STUB_DIR/ssh.out"
FAILOVER_DRILL_PROOF_DEADLINE_S=30 p2
eq "N3b empty/missing reply -> FAIL" "$(verdict 2)" FAIL
reset
echo $NOW > "$STUB_DIR/ssh.out"
FAILOVER_DRILL_PROOF_DEADLINE_S=30 p2
eq "N3c mtime == enqueue is not later" "$(verdict 2)" FAIL

# --- N4: a spawned row for another key, a destroyed row for ours -> not OK ----
reset
echo '{"machines":[{"key":"FAILOVER-DRILL-other","state":"spawned"},{"key":"FAILOVER-DRILL-r1","state":"destroyed"}]}' > "$STUB_DIR/machines.body"
FAILOVER_DRILL_PROOF_DEADLINE_S=60 p3
notok "N4" 3
eq "N4 verdict" "$(verdict 3)" UNPROVEN
has "N4 detail" "$(detail 3)" "no spawned machine for FAILOVER-DRILL-r1 within 60s"
eq "N4 one enqueue" "$(count 'POST https://jobs.test/api/queue')" 1
eq "N4 two machine reads" "$(count 'GET https://jobs.test/api/machines')" 2

# --- N5: a truncated:true ledger read -> UNPROVEN -----------------------------
reset
printf '{"ledgers":[{"kind":"merge","key":"pr-9","actor":"%s","updated_at":"%s"}],"truncated":true}' \
  "$SB" "$(isom $((TP+100)))" > "$STUB_DIR/ledger.body"
p4
notok "N5" 4
eq "N5 verdict" "$(verdict 4)" UNPROVEN
has "N5 detail" "$(detail 4)" "b: ledger truncated"

# --- N6: queue_put answers duplicate -> FAIL, never polled --------------------
reset
echo '{"duplicate":true}' > "$STUB_DIR/queue.body"
p3
eq "N6 verdict" "$(verdict 3)" FAIL
has "N6 detail" "$(detail 3)" "FAILOVER-DRILL-r1 already queued or claimed"
eq "N6 no machine read" "$(count '/api/machines')" 0
reset
echo 1 > "$STUB_DIR/queue.rc"
p3; eq "N6b queue unreachable" "$(verdict 3)" UNPROVEN
reset
p=$(fd_proof_pool 'a b/c'; verdict 3); eq "N6c bad run id" "$p" UNPROVEN
eq "N6c nothing sent" "$(count '/api/queue')" 0

# --- N7: proof 1 acked with another result -> FAIL ----------------------------
reset
echo '{"commands":[{"id":101,"result":"handed to orchestrator"}]}' > "$STUB_DIR/status.body"
p1
eq "N7 verdict" "$(verdict 1)" FAIL
has "N7 detail" "$(detail 1)" "command 101 acked with: handed to orchestrator"
echo '{"commands":[{"id":101,"result":"unknown command type failover_drill_ping"}]}' > "$STUB_DIR/status.body"
FAILOVER_DRILL_CONSOLE_STATUS_PATH='/api/dash/commands/{id}' p1
has "N7b {id} substituted" "$(cat "$SEQ")" "GET https://console.test/api/dash/commands/101"
eq "N7b verdict" "$(verdict 1)" OK

# --- N8: ssh fails at every poll -> UNPROVEN ----------------------------------
reset
: > "$STUB_DIR/ssh.out"; echo 255 > "$STUB_DIR/ssh.rc"
FAILOVER_DRILL_PROOF_DEADLINE_S=60 p2
eq "N8 verdict" "$(verdict 2)" UNPROVEN
has "N8 detail" "$(detail 2)" "ssh to 10.0.0.2 failed (rc 255)"
reset
fd_proof_chat r1 ""
eq "N8b empty ip" "$(verdict 2)" UNPROVEN
eq "N8b nothing enqueued" "$(count 'POST')" 0

# --- N9: a media-handed ack -> FAIL -------------------------------------------
reset
echo '{"commands":[{"id":102,"result":"media message handed to orchestrator"}]}' > "$STUB_DIR/status.body"
p2
eq "N9 verdict" "$(verdict 2)" FAIL
has "N9 detail" "$(detail 2)" "acked with: media message handed to orchestrator"
eq "N9 no ssh" "$(count '^SSH')" 0

# --- N10: an empty recovery body -> UNPROVEN ----------------------------------
reset
: > "$STUB_DIR/recovery.body"
p4
eq "N10 verdict" "$(verdict 4)" UNPROVEN
has "N10 detail" "$(detail 4)" "a: recovery unreadable"
reset
echo '{"lease":null}' > "$STUB_DIR/recovery.body"
p4; eq "N10b no recent_changes" "$(verdict 4)" UNPROVEN
reset
echo 7 > "$STUB_DIR/alerts.rc"
p4; eq "N10c alerts unreachable" "$(verdict 4)" UNPROVEN
has "N10c detail" "$(detail 4)" "c: alerts unreadable"

# --- N11: the alert claim boundary --------------------------------------------
reset
printf '{"alerts":[{"id":"a1","claimed_by":"medic@%s","claimed_at":"%s"}],"truncated":false}' \
  "$HUB" "$(isom $((TP+SETTLE+1)))" > "$STUB_DIR/alerts.body"
p4
eq "N11 inside -> FAIL" "$(verdict 4)" FAIL
has "N11 detail" "$(detail 4)" "c: alert a1 claimed by medic@$HUB at"
reset
printf '{"alerts":[{"id":"a1","claimed_by":"medic@%s","claimed_at":"%s"},{"id":"a2","claimed_by":"medic@%s","claimed_at":"%s"},{"id":"a3","claimed_by":"medic@x%s","claimed_at":"%s"}],"truncated":false}' \
  "$HUB" "$(iso $((TP+SETTLE)))" "$HUB" "$(iso "$TB")" "$HUB" "$(iso $((TP+300)))" > "$STUB_DIR/alerts.body"
p4
eq "N11 boundaries and a lookalike box -> OK" "$(verdict 4)" OK
reset
echo '{"alerts":[],"truncated":true}' > "$STUB_DIR/alerts.body"
p4; eq "N11b alerts truncated" "$(verdict 4)" UNPROVEN

# --- N12: merge rows whose actor is only null -> UNPROVEN ---------------------
reset
printf '{"ledgers":[{"kind":"merge","key":"pr-9","actor":null,"updated_at":"%s"},{"kind":"merge","key":"pr-6","actor":"%s0","updated_at":"%s"}]}' \
  "$(isom $((TP+100)))" "$HUB" "$(isom $((TP+120)))" > "$STUB_DIR/ledger.body"
p4
eq "N12 verdict" "$(verdict 4)" UNPROVEN
has "N12 detail" "$(detail 4)" "merge ledger rows carry no writer box"
reset
echo '{"ledgers":[]}' > "$STUB_DIR/ledger.body"
p4; eq "N12b empty window" "$(verdict 4)" UNPROVEN
reset
jq -nc --arg a "$SB" --arg u "$(iso $((TP+5)))" '{ledgers:[range(1000)|{kind:"merge",key:"k\(.)",actor:$a,updated_at:$u}]}' > "$STUB_DIR/ledger.body"
p4; eq "N12c a full page inside the window" "$(verdict 4)" UNPROVEN
has "N12c detail" "$(detail 4)" "b: window not covered by one page"

# --- N13: recovery truncated, page reaching before the window -> judged -------
reset
recovery_rows "$(printf ',{"action":"release","after_holder":"%s","actor":"x","outcome":"ok","at":"%s"}' "$HUB" "$(iso $((TP-5000)))")" true \
  > "$STUB_DIR/recovery.body"
p4
eq "N13 verdict" "$(verdict 4)" OK
reset
recovery_rows "" true > "$STUB_DIR/recovery.body"
p4
eq "N13b truncated inside the window" "$(verdict 4)" UNPROVEN
has "N13b detail" "$(detail 4)" "a: recent_changes truncated inside the window"

# --- N14: refused promote does not count; a bad window is refused -------------
reset
recovery_rows "$(printf ',{"action":"promote","after_holder":"%s","actor":"watchdog","outcome":"refused: live","at":"%s"}' "$SB" "$(iso $((TP+300)))")" \
  > "$STUB_DIR/recovery.body"
p4; eq "N14 refused promote ignored" "$(verdict 4)" OK
reset
fd_proof_ledger r1 "$HUB" "$HUB" "$TP" "$TB" 60; eq "N14b hub == standby" "$(verdict 4)" UNPROVEN
fd_proof_ledger r1 "$HUB" "$SB" "$TB" "$TP" 60; eq "N14c t_promote > t_back" "$(verdict 4)" UNPROVEN
has "N14c detail" "$(detail 4)" "bad window"
eq "N14 no reads" "$(count 'GET')" 0

# --- N15: an unset console is UNPROVEN and sends nothing ----------------------
reset
CONSOLE_URL='' p1; eq "N15 p1" "$(verdict 1)" UNPROVEN
has "N15 detail" "$(detail 1)" "console not configured"
CONSOLE_URL='' p2; eq "N15 p2" "$(verdict 2)" UNPROVEN
eq "N15 nothing sent" "$(count 'console.test')" 0

echo "failover-drill-proofs.bh-2747: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
