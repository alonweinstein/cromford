#!/bin/bash
# tests/responder-handled-db.bh-2346-test.sh — BH-2346 (BH-2316.3): the
# watchdog responder's 12h per-key cooldown survives a dead hub.
#
# state/responder/handled.json stays the primary copy. With flags/alerts-db
# present the responder also reads `brake:responder-handled` rows back as a
# union (max epoch per key, into a temp copy that is never written back) and
# writes every key it stamps through to the ledger AFTER the local stamp.
#
# Drives the real bin/watchdog-responder.sh (harness root rewritten to a scratch
# tree) with the real bin/jobs-client.sh, bin/lib/jobs/*, bin/lib/alert-state.sh
# and bin/lib/brake-ledger.sh. Only curl (the worker) and bin/agent-call.sh (the
# paid session) are stubbed, and what they RECEIVE is the assertion.
#
#   F   flag off: no ledger request, session called, handled.json stamped
#   A   DB row at now-1h, local {} -> no session, handled.json still {}
#   A2  DB row for another project's same key -> session called
#   B   DB row at now-13h -> session called
#   W   wedged queue job with a DB row at now-1h -> no session (W0: no row -> session)
#   C   every stamped key (persisted + wedged) gets a `set` row; agent rc 75 -> no PUT
#   D   daily cap tripped -> no ledger request, no session
#   E   PUT fails -> exactly one "mark failed" line, local stamp stands
#   G1  worker down / G2 HTML 200 -> same as flag off
#
# Run from anywhere: HARNESS_TEST_SANDBOX=1 bash tests/responder-handled-db.bh-2346-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

H="$T/h"
mkdir -p "$H/bin/lib/jobs" "$H/logs" "$H/locks" "$H/env" "$H/flags" "$H/state/responder" \
         "$T/stub" "$T/tmp"
export TMPDIR="$T/tmp"
. "$DIR/tests/lib/model-route-stub.sh" || exit 1; model_routes_fixture "$H" || exit 1

sed "s|/root/harness|$H|g" "$DIR/bin/watchdog-responder.sh" > "$H/bin/watchdog-responder.sh"
chmod +x "$H/bin/watchdog-responder.sh"
cp "$DIR/bin/jobs-client.sh" "$H/bin/jobs-client.sh"
cp "$DIR"/bin/lib/jobs/*.sh "$H/bin/lib/jobs/"
cp "$DIR/bin/lib/alert-state.sh" "$DIR/bin/lib/brake-ledger.sh" "$H/bin/lib/"
cp "$DIR/bin/lib/lane-switch.sh" "$DIR/bin/lib/lane-gate.sh" "$H/bin/lib/"
# BH-5942: a project run sources the per-project runner seam and its runner.
( cd "$DIR" && scratch_install_closure bin/lib/llm-lane-project.sh "$H" ) >/dev/null || exit 1
printf 'HARNESS_SECRET=test-secret\nJOBS_URL=https://jobs.invalid\nJOBS_BOX=hub\n' > "$H/env/global.env"
# The single-call path: this suite is about the cooldown, not the evidence prefetch.
: > "$H/flags/responder-prefetch-off"

printf '#!/bin/sh\nexit 0\n' > "$H/bin/stale-owed-tickets.sh"; chmod +x "$H/bin/stale-owed-tickets.sh"
cat > "$H/bin/agent-call.sh" <<STUB
#!/bin/bash
echo "call \$1 \$2" >> "$T/calls.log"
: > "\$5"
exit "\${STUB_AC_RC:-0}"
STUB
chmod +x "$H/bin/agent-call.sh"

# The worker. Only /api/ledger is served (from store.jsonl, newest first) and
# logged to req.log; every other path is a 404, which the jobs client reads as
# a real "no row", never as an outage.
cat > "$T/stub/curl" <<STUB
#!/bin/bash
M=GET; BODY=""; URL=""
while [ \$# -gt 0 ]; do
  case "\$1" in
    -X) shift; M="\$1" ;;
    --data-binary) shift; BODY="\$1" ;;
    -m|-w|-H|--connect-timeout|-o|-A) shift ;;
    http*) URL="\$1" ;;
  esac
  shift
done
case "\$URL" in
  */api/ledger*) ;;
  *) printf '\n404'; exit 0 ;;
esac
echo "\$M \${URL#*/api/ledger} \$BODY" >> "$T/req.log"
[ "\${STUB_DOWN:-0}" = 1 ] && exit 7
[ "\${STUB_HTML:-0}" = 1 ] && { printf '<html>oops</html>\n200'; exit 0; }
if [ "\$M" = PUT ]; then
  [ "\${STUB_PUT_FAIL:-0}" = 1 ] && exit 7
  printf '%s' "\$BODY" | jq -c --arg t "\$(date -u +%Y-%m-%dT%H:%M:%SZ)" '. + {updated_at:\$t}' >> "$T/store.jsonl"
  printf '{"ledger":{}}\n200'; exit 0
fi
if [ -s "$T/store.jsonl" ]; then
  jq -sc '{ledgers: (sort_by(.updated_at) | reverse), as_of: "x"}' "$T/store.jsonl"
else
  printf '{"ledgers":[]}'
fi
printf '\n200'
STUB
chmod +x "$T/stub/curl"

NOW=$(date +%s)
# seed_row <key> <epoch> [status] — a ledger row as the worker stores it.
seed_row() {
  jq -nc --arg k "$1" --argjson at "$2" --arg st "${3:-set}" \
    '{kind:"brake:responder-handled", key:$k, status:$st, actor:"oldhub",
      detail:({at:$at}|tojson), updated_at:($at|todate)}' >> "$T/store.jsonl"
}
# reset [persist|wedged|both] — fresh state for one case: p:k stale in two
# snapshots 2h apart (persisted), and/or a 1h-old queue job p/K9 with no machine.
reset() {
  local p
  for p in "$H/state/responder" "$H/state/watchdog-responder" "$H/state/build-queue" "$H/state/stale-owed.json" \
           "$H/flags/alerts-db" "$H/bin/lib/lane-caps.sh" \
           "$T/req.log" "$T/store.jsonl" "$T/calls.log" "$H/logs/responder.log"; do
    scratch_rm "$p" || exit 1
  done
  mkdir -p "$H/state/responder" "$H/state/watchdog-responder/p"
  echo '{}' > "$H/state/responder/handled.json"
  local mode="${1:-persist}" snap
  snap='{"p":{"tickets":[{"key":"k","status":"todo","waitingOn":"team","hours":30,"title":"t"}]}}'
  case "$mode" in
    wedged) echo '{"p":{"tickets":[]}}' > "$H/state/stale-owed.json" ;;
    *) echo "$snap" > "$H/state/stale-owed.json"
       jq -nc --argjson ts "$((NOW - 7200))" --argjson s "$snap" '{ts:$ts, snap:$s}' \
         > "$H/state/watchdog-responder/p/stale-history.json" ;;
  esac
  case "$mode" in
    wedged|both)
      mkdir -p "$H/state/build-queue/p"
      echo '{"key":"K9"}' > "$H/state/build-queue/p/K9.json"
      touch -d '@'"$((NOW - 3600))" "$H/state/build-queue/p/K9.json" ;;
  esac
}
flag_on() { : > "$H/flags/alerts-db"; }
run() { ( export PATH="$T/stub:$PATH" JOBS_RETRY_SLEEP=0; bash "$H/bin/watchdog-responder.sh" p ) >/dev/null 2>&1; }
calls()   { if [ -f "$T/calls.log" ]; then wc -l < "$T/calls.log" | tr -d ' '; else echo 0; fi; }
reqs()    { if [ -f "$T/req.log" ]; then wc -l < "$T/req.log" | tr -d ' '; else echo 0; fi; }
puts()    { cat "$T/req.log" 2>/dev/null | grep -c '^PUT '; }
hkeys()   { jq -c 'keys' "$H/state/responder/handled.json"; }
logcount() { cat "$H/logs/responder.log" 2>/dev/null | grep -c -- "$1"; }
nomerged() { ! ls "$H/state/responder"/handled.merged.* >/dev/null 2>&1; }

# --- F. flag off: today's behaviour, no request --------------------------------
reset persist; seed_row p:k $((NOW - 3600)); run
[ "$(reqs)" = 0 ] && ok || bad "F: flag off made $(reqs) ledger request(s): $(cat "$T/req.log")"
[ "$(calls)" = 1 ] && ok || bad "F: session calls=$(calls), wanted 1"
F_KEYS=$(hkeys)
[ "$F_KEYS" = '["p:k"]' ] && ok || bad "F: handled.json keys $F_KEYS"

# --- A. a DB row inside 12h brakes a rebuilt hub ------------------------------
reset persist; flag_on; seed_row p:k $((NOW - 3600)); run
[ "$(calls)" = 0 ] && ok || bad "A: DB row at now-1h still bought a session (calls=$(calls))"
[ "$(jq -c . "$H/state/responder/handled.json")" = '{}' ] && ok \
  || bad "A: merged copy written back: $(cat "$H/state/responder/handled.json")"
grep -q '^GET ?kind=brake%3Aresponder-handled' "$T/req.log" 2>/dev/null && ok \
  || bad "A: no brake:responder-handled read: $(cat "$T/req.log" 2>/dev/null)"
nomerged && ok || bad "A: merged temp copy left behind: $(ls "$H/state/responder")"
# A2. the same key under a different project is not this key
reset persist; flag_on; seed_row q:k $((NOW - 3600)); run
[ "$(calls)" = 1 ] && ok || bad "A2: q:k row braked p:k (calls=$(calls))"
# A3. a cleared row is not a brake
reset persist; flag_on; seed_row p:k $((NOW - 3600)) cleared; run
[ "$(calls)" = 1 ] && ok || bad "A3: cleared row braked p:k (calls=$(calls))"

# --- B. a row older than 12h does not brake ------------------------------------
reset persist; flag_on; seed_row p:k $((NOW - 46800)); run
[ "$(calls)" = 1 ] && ok || bad "B: 13h-old row braked p:k (calls=$(calls))"

# --- W. the wedged-queue cooldown reads the union too -------------------------
reset wedged; flag_on; run
[ "$(calls)" = 1 ] && ok || bad "W0: wedged job with no row made calls=$(calls), wanted 1"
reset wedged; flag_on; seed_row p:K9 $((NOW - 3600)); run
[ "$(calls)" = 0 ] && ok || bad "W: DB row for p:K9 at now-1h still bought a session (calls=$(calls))"
nomerged && ok || bad "W: merged temp copy left behind"

# --- C. write-through: exactly the keys stamped locally ------------------------
reset both; flag_on; T0=$(date +%s); run; T1=$(date +%s)
[ "$(calls)" = 1 ] && ok || bad "C: calls=$(calls), wanted 1"
[ "$(hkeys)" = '["p:K9","p:k"]' ] && ok || bad "C: handled.json keys $(hkeys)"
ROWS=$(jq -sc --argjson t0 "$T0" --argjson t1 "$T1" '[.[] | select(.kind=="brake:responder-handled" and .status=="set")
  | select((.detail|fromjson|.at) as $a | ($a|type)=="number" and $a >= $t0 and $a <= $t1) | .key] | sort' "$T/store.jsonl" 2>/dev/null)
[ "$ROWS" = '["p:K9","p:k"]' ] && ok || bad "C: ledger set rows $ROWS, wanted [\"p:K9\",\"p:k\"] (store: $(cat "$T/store.jsonl" 2>/dev/null))"
[ "$(logcount 'mark failed')" = 0 ] && ok || bad "C: a mark failed line on a healthy worker"
# C2. a pass that called nothing (rc 75) marks nothing, local or DB
reset both; flag_on; STUB_AC_RC=75 run
[ "$(puts)" = 0 ] && ok || bad "C2: rc-75 pass sent $(puts) PUT(s)"
[ "$(jq -c . "$H/state/responder/handled.json")" = '{}' ] && ok || bad "C2: rc-75 pass stamped handled.json"

# --- D. a cap-stopped pass reads and marks nothing ----------------------------
reset both; flag_on
printf 'lane_day_cap_tripped() { return 0; }\nlane_cap_bytes() { echo 60000; }\n' > "$H/bin/lib/lane-caps.sh"
run
[ "$(reqs)" = 0 ] && ok || bad "D: cap-stopped pass made $(reqs) ledger request(s)"
[ "$(calls)" = 0 ] && ok || bad "D: cap-stopped pass called a session"
rm -f "$H/bin/lib/lane-caps.sh"

# --- E. a failed mark is one log line and the local stamp stands ---------------
reset both; flag_on; STUB_PUT_FAIL=1 run
[ "$(logcount 'brake ledger mark failed')" = 1 ] && ok \
  || bad "E: mark failed lines=$(logcount 'brake ledger mark failed'), wanted 1"
grep -q 'mark failed for 2 of 2 key(s)' "$H/logs/responder.log" 2>/dev/null && ok \
  || bad "E: mark failed line does not count 2 of 2: $(grep 'mark failed' "$H/logs/responder.log" 2>/dev/null)"
[ "$(hkeys)" = '["p:K9","p:k"]' ] && ok || bad "E: local stamp lost: $(hkeys)"
# the jobs client retries a transport failure once, so count keys, not attempts
EK=$(sed -n 's/^PUT  //p' "$T/req.log" 2>/dev/null | jq -sc '[.[].key] | unique')
[ "$EK" = '["p:K9","p:k"]' ] && ok || bad "E: PUT attempted for keys $EK, wanted both"

# --- G. an unreachable or HTML worker is the flag-off pass ---------------------
reset persist; flag_on; seed_row p:k $((NOW - 3600)); STUB_DOWN=1 run
[ "$(calls)" = 1 ] && ok || bad "G1: worker down suppressed the session (calls=$(calls))"
[ "$(hkeys)" = "$F_KEYS" ] && ok || bad "G1: handled keys $(hkeys) != flag-off $F_KEYS"
[ "$(logcount 'brake ledger read failed')" = 1 ] && ok || bad "G1: no read-failed line"
nomerged && ok || bad "G1: merged temp copy left behind"
reset persist; flag_on; seed_row p:k $((NOW - 3600)); STUB_HTML=1 run
[ "$(calls)" = 1 ] && ok || bad "G2: HTML 200 suppressed the session (calls=$(calls))"
[ "$(hkeys)" = "$F_KEYS" ] && ok || bad "G2: handled keys $(hkeys) != flag-off $F_KEYS"
[ "$(logcount 'brake ledger read failed')" = 1 ] && ok || bad "G2: no read-failed line"

echo "responder-handled-db: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
