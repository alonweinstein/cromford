#!/bin/bash
# tests/medic-brake-db.bh-2316-test.sh — the medic's three brakes (6h family
# stamp, parked families, seen ids) survive a dead hub (BH-2316.2 / BH-2345).
#
# Runs the REAL bin/alerts-medic.sh in a scratch tree with the real jobs client,
# the real alert-state gate and the real bin/lib/brake-ledger.sh. What is stubbed
# is what would leave this machine or spend money — curl and agent-call.sh — and
# what they RECEIVE is the assertion: the prompt a session would be handed, and
# every request (with its body) the lane made.
#
# WHAT IS AT STAKE. A rebuilt hub starts with empty state files. The ledger rows
# are the only memory it has of what it already paid for, so a row inside its
# window must brake exactly like the local file would. The other half is fail
# open: flag off, worker down or a 200 that is not a ledger list must leave the
# pass making today's decisions, and a read that failed must never be the reason
# a `cleared` row is written.
#
# Run from anywhere: tests/medic-brake-db.bh-2316-test.sh   (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

NOW=$(date -u +%s)
iso() { date -u -d "@$(( NOW - ${1:-0} ))" '+%Y-%m-%dT%H:%M:%SZ'; }

H="$T/h"
. "$DIR/tests/lib/model-route-stub.sh" || exit 1; model_routes_fixture "$H" || exit 1
mkdir -p "$H/bin/lib" "$H/logs" "$H/state" "$H/locks" "$H/env" "$H/flags" "$T/fakebin" "$T/calls"
printf 'CONSOLE_URL=https://console.invalid\nJOBS_URL=https://jobs.invalid\nHARNESS_SECRET=testsecret\nJOBS_RETRIES=0\n' \
  > "$H/env/global.env"

install_medic() { sed "s|/root/harness|$H|g" "$DIR/bin/alerts-medic.sh" > "$H/bin/alerts-medic.sh"; chmod +x "$H/bin/alerts-medic.sh"; }
install_medic
for s in jobs-client.sh triage-map.sh fleet-conf.sh box-for.sh project-of.sh alert_family.py; do
  ln -sf "$DIR/bin/$s" "$H/bin/$s"
done
mkdir -p "$H/bin/lib/jobs"
cp "$DIR"/bin/lib/jobs/*.sh "$H/bin/lib/jobs/"
for s in alert-state.sh env-path.sh brake-ledger.sh; do ln -sf "$DIR/bin/lib/$s" "$H/bin/lib/$s"; done
# BH-5942: the per-project runner seam, linked like the libs above (a closure
# would bring bin/lib/lane-gate.sh and its worker reads into the request log).
for s in llm-lane-project.sh project-lanes.sh; do ln -sf "$DIR/bin/lib/$s" "$H/bin/lib/$s"; done
export FLEET_CONF="$DIR/fleet.conf"
printf '#!/bin/sh\nexit 0\n' > "$H/bin/alerts-groom.sh"; chmod +x "$H/bin/alerts-groom.sh"
printf '#!/bin/sh\nexit 0\n' > "$H/bin/fleet-projects-or-alert.sh"; chmod +x "$H/bin/fleet-projects-or-alert.sh"

# --- stubs -------------------------------------------------------------------
# curl: records "METHOD URL BODY" and answers per host, in the jobs-client wire
# shape (body, then a status line). GET /api/ledger?kind=brake:medic-<x> answers
# from $FIX/ledger-medic-<x>.json. CURL_MODE=down fails every jobs request with
# curl rc 7; LEDGER_MODE=html answers the ledger route with a 200 HTML page.
{ echo '#!/bin/bash'; echo "FIX=$T"; cat <<'CURLEOF'
URL="${!#}"; BODY=""; METHOD=GET
while [ $# -gt 0 ]; do
  case "$1" in
    -X) METHOD="$2"; shift 2 ;;
    --data-binary|-d) BODY="$2"; shift 2 ;;
    *) shift ;;
  esac
done
case "$BODY" in @*) BODY=$(cat "${BODY#@}") ;; esac
[ -n "${REQ_SINK:-}" ] && printf '%s %s %s\n' "$METHOD" "$URL" "$BODY" >> "$REQ_SINK"
case "$URL" in
  *jobs.invalid*)
    [ "${CURL_MODE:-ok}" = down ] && exit 7
    case "$URL" in */api/ledger*) [ "${LEDGER_MODE:-ok}" = html ] && { printf '<html><body>login</body></html>\n200\n'; exit 0; } ;; esac
    case "$METHOD $URL" in
      "GET "*/api/ledger\?kind=brake%3Amedic-*)
        k=${URL#*kind=brake%3A}; k=${k%%&*}
        if [ -f "$FIX/ledger-$k.json" ]; then printf '%s\n200\n' "$(cat "$FIX/ledger-$k.json")"
        else printf '{"ledgers":[],"as_of":"x"}\n200\n'; fi ;;
      "PUT "*/api/ledger)            printf '{"ledger":{}}\n200\n' ;;
      # The claim hands back every id it was asked for: this suite is about
      # the brakes, and BH-1071's own suite pins what a partial claim does.
      "POST "*/api/alerts/claim)
        printf '%s\n200\n' "$(jq -c '{alerts: [(.ids // [])[] | {id:., family:"f", box:"hub", project:"", state:"claimed", count:1, first_seen:"x", last_seen:"x", claimed_by:"medic@hub", claimed_at:"x", notified_at:"", severity:"warn", line:"x"}]}' <<<"$BODY")" ;;
      "GET "*/api/alerts/families*)  printf '{"families":[]}\n200\n' ;;
      "GET "*/api/alerts*)           printf '{"alerts":[]}\n200\n' ;;
      "PATCH "*/api/alerts/state)    printf '{"alert":{"state":"set"}}\n200\n' ;;
      *)                             printf '{"error":"not found"}\n404\n' ;;
    esac ;;
  *console.invalid/api/alerts/open) cat "$FIX/console.json" ;;
  *) echo '{}' ;;
esac
CURLEOF
} > "$T/fakebin/curl"; chmod +x "$T/fakebin/curl"
printf '#!/bin/sh\nexit 0\n' > "$T/fakebin/flock"; chmod +x "$T/fakebin/flock"

# agent-call.sh: records the prompt, exits $AGENT_RC (75 = refused before billing).
cat > "$H/bin/agent-call.sh" <<'CALLEOF'
#!/bin/bash
N=$(ls "$CALLDIR"/prompt-*.txt 2>/dev/null | wc -l | tr -d ' ')
printf '%s' "$6" > "$CALLDIR/prompt-$N.txt"
echo "handled=1" > "$5"
exit "${AGENT_RC:-0}"
CALLEOF
chmod +x "$H/bin/agent-call.sh"

# --- harness -----------------------------------------------------------------
fresh() { rm -rf "$T/calls"; mkdir -p "$T/calls"; : > "$T/req.log"; }
medic() {
  CALLDIR="$T/calls" REQ_SINK="$T/req.log" PATH="$T/fakebin:$PATH" \
    CURL_MODE="${CURL_MODE:-ok}" LEDGER_MODE="${LEDGER_MODE:-ok}" AGENT_RC="${AGENT_RC:-0}" \
    bash "$H/bin/alerts-medic.sh" cromford >/dev/null 2>&1
}
ncalls() { ls "$T/calls"/prompt-*.txt 2>/dev/null | wc -l | tr -d ' '; }
prompts() { cat "$T/calls"/prompt-*.txt 2>/dev/null; }
# the ids every prompt carried, sorted — the pass's dispatch decision
dispatched() { prompts | grep -oE '^[a-z]+-[0-9a-z-]+'$'\t' | tr -d '\t' | sort -u | tr '\n' ' '; }
count() { grep -c -- "$1" "$T/req.log" 2>/dev/null || true; }
# puts <kind> <key> <status> — how many ledger PUTs had exactly that shape
puts() { grep '^PUT https://jobs.invalid/api/ledger ' "$T/req.log" | cut -d' ' -f3- \
           | jq -c --arg k "brake:$1" --arg v "$2" --arg s "$3" 'select(.kind==$k and .key==$v and .status==$s)' 2>/dev/null \
           | grep -c . || true; }
put_detail() { grep '^PUT https://jobs.invalid/api/ledger ' "$T/req.log" | cut -d' ' -f3- \
           | jq -r --arg k "brake:$1" --arg v "$2" 'select(.kind==$k and .key==$v and .status=="set") | .detail' 2>/dev/null | head -1; }
flag_on()  { touch "$H/flags/alerts-db"; }
flag_off() { rm -f "$H/flags/alerts-db"; }
# BH-5942: the medic runs per project. These rows carry no project, so they are
# the cromford run's, with its state in state/alerts-medic/cromford/.
MS="$H/state/alerts-medic/cromford"
reset_medic() { : > "$H/logs/medic.log"; : > "$H/logs/ALERTS.log"; scratch_rm "$MS"; mkdir -p "$MS"
                echo '{}' > "$MS/medic-families.json"; echo '{}' > "$MS/medic-parked.json"
                : > "$MS/medic-seen.txt"; rm -f "$T"/ledger-*.json; }

# ledger <name> <row-json>... — the worker's list for kind brake:<name>
ledger() { local n="$1"; shift
  printf '%s\n' "$@" | jq -sc '{ledgers: (sort_by(.updated_at) | reverse), as_of: "x"}' > "$T/ledger-$n.json"; }
# lrow <key> <status> <age_s> [detail-object] — one row as the worker stores it:
# detail is a JSON STRING carrying at (what brake_mark writes)
lrow() { local at=$(( NOW - $3 )) d="${4:-}"; [ -n "$d" ] || d='{}'
  jq -nc --arg k "$1" --arg s "$2" --arg u "$(iso "$3")" --argjson at "$at" --argjson d "$d" \
    '{kind:"x", key:$k, status:$s, updated_at:$u, detail:($d + {at:$at} | tojson)}'; }

# --- fixtures ----------------------------------------------------------------
LA="the alpha widget pipeline is jammed: 3 builds stuck"
LB="the bravo gizmo sync lost its cursor"
LC="the charlie sprocket feed went quiet"
fam() { PYTHONPATH="$DIR/bin" python3 -c 'import sys
from alert_family import family
print(family(sys.argv[1]))' "$1"; }
FA=$(fam "$LA"); FB=$(fam "$LB"); FC=$(fam "$LC")
[ -n "$FA" ] && [ -n "$FB" ] && [ "$FA" != "$FB" ] && [ -n "$FC" ] && [ "$FC" != "$FA" ] && [ "$FC" != "$FB" ] && [ "$(fam "the alpha widget pipeline is jammed: 9 builds stuck")" = "$FA" ] \
  && ok || bad "fixture: LA and LB must be two families, and LA's digits must not change its family (FA=$FA FB=$FB)"

console() { # console <id:line-var>... plus optional raw extra rows in $EXTRA
  { echo '{"alerts":['; local i=0 a
    for a in "$@"; do
      [ "$i" -gt 0 ] && echo ','
      jq -nc --arg id "${a%%=*}" --arg l "${a#*=}" --arg c "$(iso 3600)" '{id:$id, createdAt:$c, akey:("beat:"+$id), line:$l}'
      i=$((i+1))
    done
    [ -n "${EXTRA:-}" ] && printf ',%s' "$EXTRA"
    echo ']}'; } > "$T/console.json"
}
EXTRA=""
console "a-1=$LA" "b-1=$LB"

# ================= 1 — flag off: not one ledger request ======================
flag_off; reset_medic
ledger medic-seen "$(lrow a-1 set 3600)"
ledger medic-family "$(lrow "$FB" set 3600)"
fresh; medic
BASE=$(dispatched)
[ "$BASE" = "a-1 b-1 " ] && ok || bad "c1: flag off must dispatch both ids (got '$BASE')"
[ "$(count '/api/ledger')" = 0 ] && ok || bad "c1: flag off made $(count '/api/ledger') ledger request(s)"
# (the lane's model_routes read is its own contract, BH-1510.2, and not gated here)
[ "$(grep 'jobs.invalid' "$T/req.log" | grep -vc '/api/model-routes/')" = 0 ] && ok || bad "c1: flag off must not touch the alerts or ledger routes at all"
grep -qx 'a-1' "$MS/medic-seen.txt" && ok || bad "c1: the local seen file must still be written"

# ================= 0 — flag on, empty ledger: today's decisions ==============
flag_on; reset_medic
fresh; medic
[ "$(dispatched)" = "a-1 b-1 " ] && ok || bad "c0: an empty ledger brakes nothing (got '$(dispatched)')"
[ "$(count 'GET https://jobs.invalid/api/ledger?kind=brake%3Amedic-seen&limit=1000')" = 1 ] \
  && [ "$(count 'GET https://jobs.invalid/api/ledger?kind=brake%3Amedic-family&limit=1000')" = 1 ] \
  && [ "$(count 'GET https://jobs.invalid/api/ledger?kind=brake%3Amedic-parked&limit=1000')" = 1 ] \
  && ok || bad "c0: each brake must be read exactly once per pass ($(grep -o 'GET [^ ]*api/ledger[^ ]*' "$T/req.log" | tr '\n' ' '))"

# ================= 2 — a seen row keeps its id out of every prompt ===========
flag_on; reset_medic
ledger medic-seen "$(lrow a-1 set 3600)"
fresh; medic
[ "$(dispatched)" = "b-1 " ] && ok || bad "c2: a-1 has a seen row and must not be re-listed (got '$(dispatched)')"
! grep -qF "$LA" <<<"$(prompts)" && ok || bad "c2: a-1's line reached a prompt"
# a cleared seen row, or one older than 7 days, does not count
reset_medic; ledger medic-seen "$(lrow a-1 cleared 3600)" "$(lrow b-1 set $((8*86400)))"
fresh; medic
[ "$(dispatched)" = "a-1 b-1 " ] && ok || bad "c2b: a cleared or 8-day-old seen row must not brake (got '$(dispatched)')"

# ================= 3 — a DB park inside PARK_TTL holds its family ============
flag_on; reset_medic
ledger medic-parked "$(lrow "$FA" set 86400 "$(jq -nc --argjson s $((NOW-86400)) '{since:$s, ids:["a-1"], line:"MEDIC: alpha needs a human"}')")"
fresh; MEDIC_PARK_TTL=604800 medic
[ "$(dispatched)" = "b-1 " ] && ok || bad "c3: a family parked 1d ago (TTL 7d) must not be dispatched (got '$(dispatched)')"
grep -q 'medic held alert a-1 in a parked family' "$H/logs/medic.log" && ok || bad "c3: the held alert must be logged"
grep -q "medic parked family $FA " "$H/logs/medic.log" && ok || bad "c3: the PARKED line must name the family"
python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); p=d[sys.argv[2]]; sys.exit(0 if p["ids"]==["a-1"] and abs(p["since"]-int(sys.argv[3]))<2 else 1)' \
  "$MS/medic-parked.json" "$FA" "$((NOW-86400))" \
  && ok || bad "c3: the restored park must be written back locally with its original since ($(cat "$MS/medic-parked.json"))"
[ "$(puts medic-parked "$FA" set)" = 0 ] && ok || bad "c3: a restored park is not a new park and must not be re-marked"
# c3c: a park whose line carries `"` and `\` survives brake_read's @tsv escaping
flag_on; reset_medic
QLINE='MEDIC: alpha "stuck" at C:\tmp\x needs a human'
ledger medic-parked "$(lrow "$FA" set 86400 "$(jq -nc --argjson s $((NOW-86400)) --arg l "$QLINE" '{since:$s, ids:["a-1"], line:$l}')")"
fresh; MEDIC_PARK_TTL=604800 medic
[ "$(dispatched)" = "b-1 " ] && ok || bad "c3c: a park with a quote and a backslash in its line must still hold its family (got '$(dispatched)')"
python3 -c 'import json,sys; p=json.load(open(sys.argv[1]))[sys.argv[2]]; sys.exit(0 if p["ids"]==["a-1"] and p["line"]==sys.argv[3] else 1)' \
  "$MS/medic-parked.json" "$FA" "$QLINE" \
  && ok || bad "c3c: the restored park must keep its ids and exact line ($(cat "$MS/medic-parked.json"))"
[ "$(puts medic-parked "$FA" cleared)" = 0 ] && ok || bad "c3c: a park that fails to decode must never be cleared"

# ================= 4 — a park older than PARK_TTL is ignored =================
reset_medic
ledger medic-parked "$(lrow "$FA" set $((8*86400)) "$(jq -nc --argjson s $((NOW-8*86400)) '{since:$s, ids:["a-1"], line:"x"}')")"
fresh; MEDIC_PARK_TTL=604800 medic
[ "$(dispatched)" = "a-1 b-1 " ] && ok || bad "c4: an 8-day-old park must not hold (got '$(dispatched)')"

# ================= 5 — a cleared park does not brake =========================
reset_medic
ledger medic-parked "$(lrow "$FA" cleared 3600 "$(jq -nc --argjson s $((NOW-3600)) '{since:$s, ids:["a-1"], line:"x"}')")"
fresh; medic
[ "$(dispatched)" = "a-1 b-1 " ] && ok || bad "c5: a cleared park must not hold (got '$(dispatched)')"

# ================= 6 — a family stamped 1h ago is braked =====================
console "a-1=$LA"
reset_medic
ledger medic-family "$(lrow "$FA" set 3600)"
fresh; medic
[ "$(ncalls)" = 0 ] && ok || bad "c6: a family row at now-1h must brake the family (calls=$(ncalls))"
grep -q 'medic skip: all unseen alerts in recently-examined families' "$H/logs/medic.log" \
  && ok || bad "c6: the skip must be declared (got: $(tail -2 "$H/logs/medic.log"))"

# ---- 12 — mutation: without the union line the same case dispatches --------
grep -q 'medic-family 21600 >> "$DBFAMS"' "$H/bin/alerts-medic.sh" \
  && ok || bad "c12: the family union line is not where this mutation expects it"
sed -i '/medic-family 21600 >> "$DBFAMS"/d' "$H/bin/alerts-medic.sh"
reset_medic; ledger medic-family "$(lrow "$FA" set 3600)"
fresh; medic
[ "$(ncalls)" = 1 ] && ok || bad "c12: removing the family union must turn c6 red (calls=$(ncalls))"
install_medic

# ================= 7 — a family stamped 7h ago is not ========================
reset_medic
ledger medic-family "$(lrow "$FA" set $((7*3600)))"
fresh; medic
[ "$(dispatched)" = "a-1 " ] && ok || bad "c7: a family row at now-7h must not brake (got '$(dispatched)')"

# ================= 8 — marks follow the session, and only the session ========
console "a-1=$LA" "b-1=$LB"
reset_medic
fresh; medic
[ "$(puts medic-family "$FA" set)" = 1 ] && [ "$(puts medic-family "$FB" set)" = 1 ] \
  && ok || bad "c8: each family that got a session must be PUT once as brake:medic-family set"
[ "$(puts medic-seen a-1 set)" = 1 ] && [ "$(puts medic-seen b-1 set)" = 1 ] \
  && ok || bad "c8: each dispatched id must be PUT once as brake:medic-seen set"
AT=$(put_detail medic-seen a-1 | jq -r '.at' 2>/dev/null)
[ -n "$AT" ] && [ $(( AT - NOW )) -ge -5 ] && [ $(( AT - NOW )) -le 300 ] \
  && ok || bad "c8: the seen mark must carry the pass's clock (at=$AT)"
# refused before billing: nothing is consumed, so nothing is marked
reset_medic
fresh; AGENT_RC=75 medic
[ "$(ncalls)" = 2 ] && ok || bad "c8b: the refused calls were still attempted (calls=$(ncalls))"
[ "$(count '"kind":"brake:medic-family"')" = 0 ] && [ "$(count '"kind":"brake:medic-seen"')" = 0 ] \
  && ok || bad "c8b: rc 75 must not PUT a family or seen mark"
# over the cap: the deferred family is not marked
reset_medic
fresh; MEDIC_MAX_FAMILIES=1 medic
[ "$(ncalls)" = 1 ] && [ "$(count '"kind":"brake:medic-family"')" = 1 ] && [ "$(count '"kind":"brake:medic-seen"')" = 1 ] \
  && ok || bad "c8c: only the one family that got a session is marked (calls=$(ncalls) fam=$(count '"kind":"brake:medic-family"') seen=$(count '"kind":"brake:medic-seen"'))"

# ================= 9 — a new park is written through =========================
EXTRA=$(jq -nc --arg c "$(iso 3600)" --arg a "medic:$FA" '{id:"esc-1", createdAt:$c, akey:$a, line:"MEDIC: alpha needs a human"}')
console "a-1=$LA" "b-1=$LB"
reset_medic
fresh; medic
[ "$(dispatched)" = "b-1 " ] && ok || bad "c9: the escalated family is parked, not dispatched (got '$(dispatched)')"
D=$(put_detail medic-parked "$FA")
[ "$(jq -c '[.ids, .line, (.since|type), (.at == .since)]' <<<"$D" 2>/dev/null)" = '[["a-1"],"MEDIC: alpha needs a human","number",true]' ] \
  && ok || bad "c9: the park PUT must carry since/ids/line, at == since (detail=$D)"
[ "$(puts medic-parked "$FA" set)" = 1 ] && ok || bad "c9: one park PUT for one new park"
grep -q '"state":"parked"' "$T/req.log" && ok || bad "c9: the alerts-row parked mirror must still be sent"
# a second pass: the park already exists, nothing is re-marked
fresh; medic
[ "$(puts medic-parked "$FA" set)" = 0 ] && ok || bad "c9: a park recorded on an earlier pass must not be re-marked"
# 300 ids: the detail stays under the worker's 4000-char slice and parses
ARGS=()
for i in $(seq 1 300); do ARGS+=("a-$(printf '%04d' "$i")-padpadpadpad=the alpha widget pipeline is jammed: $i builds stuck"); done
console "${ARGS[@]}"
reset_medic
fresh; medic
D=$(put_detail medic-parked "$FA")
DL=$(grep '^PUT https://jobs.invalid/api/ledger ' "$T/req.log" | cut -d' ' -f3- | jq -r --arg k "$FA" 'select(.kind=="brake:medic-parked" and .key==$k) | .detail | length' | head -1)
[ -n "$DL" ] && [ "$DL" -le 4000 ] && [ "$(jq -r '(.ids|length) > 100 and (.ids|length) < 300 and (.since|type)=="number"' <<<"$D" 2>/dev/null)" = true ] \
  && ok || bad "c9b: a 300-id park must be bounded to <=4000 chars and still parse (len=$DL ids=$(jq '.ids|length' <<<"$D" 2>/dev/null))"
python3 -c 'import json,sys; sys.exit(0 if len(json.load(open(sys.argv[1]))[sys.argv[2]]["ids"])==300 else 1)' "$MS/medic-parked.json" "$FA" \
  && ok || bad "c9b: the LOCAL park keeps every id; only the row is bounded"
EXTRA=""

# ================= 10 — an unpark writes cleared =============================
console "a-1=$LA" "c-1=the alpha widget pipeline is jammed: 5 builds stuck" "b-1=$LB"
reset_medic
jq -nc --arg f "$FA" --argjson s $((NOW-3600)) '{($f): {since:$s, ids:["a-1"], line:"x"}}' > "$MS/medic-parked.json"
fresh; medic
[ "$(puts medic-parked "$FA" cleared)" = 1 ] && ok || bad "c10: a new id releasing the park must PUT cleared"
[ "$(dispatched)" = "b-1 c-1 " ] && ok || bad "c10: the new id is dispatched, the covered one still held (got '$(dispatched)')"
# expiry: a local park past the TTL is cleared too
console "a-1=$LA" "b-1=$LB"
reset_medic
jq -nc --arg f "$FB" --argjson s $((NOW-8*86400)) '{($f): {since:$s, ids:["b-1"], line:"x"}}' > "$MS/medic-parked.json"
fresh; medic
[ "$(puts medic-parked "$FB" cleared)" = 1 ] && ok || bad "c10b: an expired local park must PUT cleared"
[ "$(dispatched)" = "a-1 b-1 " ] && ok || bad "c10b: the expired park's family is dispatched (got '$(dispatched)')"

# ================= 11 — worker down / HTML 200 = flag off ====================
for MODE in down html; do
  reset_medic
  ledger medic-seen "$(lrow a-1 set 3600)"
  ledger medic-family "$(lrow "$FB" set 3600)"
  # a live local park, in a third family, that a read failure must not clear
  jq -nc --arg f "$FC" --argjson s $((NOW-3600)) '{($f): {since:$s, ids:["zz-9"], line:"x"}}' > "$MS/medic-parked.json"
  console "a-1=$LA" "b-1=$LB" "zz-9=$LC"
  fresh
  if [ "$MODE" = down ]; then CURL_MODE=down medic; else LEDGER_MODE=html medic; fi
  GOT=$(dispatched)
  [ "$GOT" = "$BASE" ] && ok || bad "c11/$MODE: must make flag-off's decisions ('$BASE'), got '$GOT'"
  [ "$(count '"status":"cleared"')" = 0 ] && ok || bad "c11/$MODE: a read failure must never PUT cleared"
  grep -q 'medic db: medic-seen ledger read rc=' "$H/logs/medic.log" \
    && ok || bad "c11/$MODE: the failed read must be declared (got: $(grep 'medic db' "$H/logs/medic.log"))"
  grep -qx 'a-1' "$MS/medic-seen.txt" && ok || bad "c11/$MODE: local seen must still be written"
  grep -q 'medic held alert zz-9' "$H/logs/medic.log" && ok || bad "c11/$MODE: the local park must still hold"
done

echo "medic-brake-db-bh-2316: pass=$PASS fail=$FAIL"
[ "$FAIL" -eq 0 ]
