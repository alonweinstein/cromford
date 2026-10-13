#!/bin/bash
# tests/triage-brake-db.bh-2316-test.sh — the alert-triage FAMILY BRAKE survives
# a dead hub (BH-2344 / BH-2316.1).
#
# The 6h brake lives in state/alert-families.json. A rebuilt hub starts with an
# empty file and buys a triage session for every family it already paid for.
# With flags/alerts-db the lane now union-reads two DB copies of that brake —
# `alert_families alert-triage 21600 triaged` and `brake_read triage-family` —
# and writes its own run families through with `brake_mark`.
#
# Runs the REAL bin/alert-triage.sh (only the harness root is rewritten). curl
# is a file-backed stub of the jobs worker's /api/ledger and /api/alerts routes;
# agent-call.sh is a stub that records which family it was handed. What they
# RECEIVE is the assertion.
#
#   off  flag absent: not one /api/ledger or /api/alerts/families request, and a
#        DB row that would brake does not.
#   a    empty local file + a brake:triage-family row 1h old -> no session.
#   a2   empty local file + a `triaged` family row 1h old -> no session, and the
#        read asked for state=triaged (a quarantined-but-claimed row must not).
#   b    the same row 7h old -> the family is dispatched.
#   c    5 families, cap 4 -> exactly the 4 run families are marked; the
#        deferred one is not.
#   c2   the mark precedes the session.
#   d    a cliff-refused family goes back in the DB too: `cleared` when it had
#        no prior stamp, `set` at the prior epoch when it had one.
#   e    worker 5xx / HTML 200 -> the same dispatch as the flag off, no clear
#        sent, and a failed mark is logged ONCE for the tick.
#   e2   a `cleared` row does not brake.
#
# Run from anywhere: tests/triage-brake-db.bh-2316-test.sh   (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
. "$(dirname "$0")/lib/triage-tick.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

NOW=$(date -u +%s)
iso() { date -u -d "@$(( NOW - ${1:-0} ))" '+%Y-%m-%dT%H:%M:%SZ'; }

H="$T/h"
. "$DIR/tests/lib/model-route-stub.sh" || exit 1; model_routes_fixture "$H" || exit 1
mkdir -p "$H/bin/lib/jobs" "$H/logs" "$H/state" "$H/locks" "$H/env" "$H/flags" \
         "$T/fakebin" "$T/calls" "$T/remote/state"
printf 'CONSOLE_URL=https://console.invalid\nJOBS_URL=https://jobs.invalid\nHARNESS_SECRET=testsecret\nJOBS_RETRIES=0\nJOBS_ALERT=0\n' \
  > "$H/env/global.env"

sed "s|/root/harness|$H|g" "$DIR/bin/alert-triage.sh" > "$H/bin/alert-triage.sh"; chmod +x "$H/bin/alert-triage.sh"
for s in jobs-client.sh triage-map.sh fleet-conf.sh box-for.sh project-of.sh alert_family.py; do
  ln -sf "$DIR/bin/$s" "$H/bin/$s"
done
cp "$DIR"/bin/lib/jobs/*.sh "$H/bin/lib/jobs/"
for s in alert-state.sh env-path.sh brake-ledger.sh; do ln -sf "$DIR/bin/lib/$s" "$H/bin/lib/$s"; done
export FLEET_CONF="$DIR/fleet.conf"
triage_tick_setup "$H" || exit 1   # BH-5942: the triage lane is a dispatch + per-project runs

# --- the jobs worker, file-backed --------------------------------------------
# /api/ledger behaves like worker/jobs/src/routes/ledger.js: PUT upserts on
# (kind,key) keeping the old detail when none is sent, GET lists one kind
# newest-first under an optional `before`.
cat > "$T/ledger.py" <<'PYL'
import json, os, sys, time, urllib.parse
path = os.path.join(os.path.dirname(os.path.abspath(__file__)), "ledger.json")
try:
    d = json.load(open(path))
except Exception:
    d = {}
op = sys.argv[1]
if op == "put":
    b = json.loads(sys.argv[2])
    k = b["kind"][:32] + "|" + b["key"]
    old = d.get(k, {})
    seq = max([r.get("seq", 0) for r in d.values()], default=0) + 1
    d[k] = {"kind": b["kind"][:32], "key": b["key"], "status": b["status"],
            "actor": b.get("actor") or old.get("actor"),
            "detail": str(b["detail"])[:4000] if b.get("detail") else old.get("detail"),
            "updated_at": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()), "seq": seq}
    json.dump(d, open(path, "w"))
    print(json.dumps({"ledger": d[k]}))
elif op == "seed":  # seed <kind> <key> <status> <at>
    seq = max([r.get("seq", 0) for r in d.values()], default=0) + 1
    d[sys.argv[2] + "|" + sys.argv[3]] = {
        "kind": sys.argv[2], "key": sys.argv[3], "status": sys.argv[4],
        "detail": json.dumps({"at": int(sys.argv[5])}),
        "updated_at": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()), "seq": seq}
    json.dump(d, open(path, "w"))
    raise SystemExit(0)
elif op == "row":  # row <kind> <key> -> status<TAB>detail
    r = d.get(sys.argv[2] + "|" + sys.argv[3])
    print("" if r is None else "%s\t%s" % (r["status"], r.get("detail") or ""))
    raise SystemExit(0)
else:
    q = urllib.parse.parse_qs(urllib.parse.urlsplit(sys.argv[2]).query)
    kind, lim = q["kind"][0], int(q.get("limit", ["200"])[0])
    before = q.get("before", [None])[0]
    rows = [r for r in d.values() if r["kind"] == kind and (before is None or r["updated_at"] < before)]
    rows.sort(key=lambda r: (r["updated_at"], r["seq"]), reverse=True)
    print(json.dumps({"ledgers": rows[:lim]}))
print(200)
PYL
{ echo '#!/bin/bash'; echo "FIX=$T"; cat <<'CURLEOF'
URL="${!#}"; BODY=""; METHOD=GET
while [ $# -gt 0 ]; do
  case "$1" in
    -X) METHOD="$2"; shift 2 ;;
    --data-binary|-d) BODY="$2"; shift 2 ;;
    *) shift ;;
  esac
done
[ -n "${REQ_SINK:-}" ] && printf '%s %s %s\n' "$METHOD" "$URL" "$BODY" >> "$REQ_SINK"
case "$URL" in
  *jobs.invalid/api/ledger*|*jobs.invalid/api/alerts/families*)
    case "${CURL_MODE:-ok}" in
      5xx)  printf '{"error":"unavailable"}\n503\n'; exit 0 ;;
      html) printf '<html><body>gateway</body></html>\n200\n'; exit 0 ;;
    esac ;;
esac
case "$METHOD $URL" in
  "PUT "*jobs.invalid/api/ledger)        python3 "$FIX/ledger.py" put "$BODY" ;;
  "GET "*jobs.invalid/api/ledger\?*)     python3 "$FIX/ledger.py" get "$URL" ;;
  "GET "*jobs.invalid/api/alerts/families*) printf '%s\n200\n' "$(cat "$FIX/families.json")" ;;
  "POST "*jobs.invalid/api/alerts/claim) printf '{"alerts":[]}\n200\n' ;;
  *jobs.invalid*)                        printf '{"error":"not found"}\n404\n' ;;
  *) echo '{}' ;;
esac
CURLEOF
} > "$T/fakebin/curl"; chmod +x "$T/fakebin/curl"
printf '#!/bin/sh\nexit 255\n' > "$T/fakebin/ssh"; chmod +x "$T/fakebin/ssh"
printf '#!/bin/sh\necho MERGED\n' > "$T/fakebin/gh"; chmod +x "$T/fakebin/gh"
printf '#!/bin/sh\nshift\nexec "$@"\n' > "$T/fakebin/timeout"; chmod +x "$T/fakebin/timeout"

# agent-call.sh: records the family it was handed and how many requests had
# gone out by then. AGENT_STUB_CLIFF=1 answers agent-call's own cliff refusal.
cat > "$H/bin/agent-call.sh" <<'CALLEOF'
#!/bin/bash
N=$(ls "$CALLDIR"/prompt-*.txt 2>/dev/null | wc -l | tr -d ' ')
printf '%s' "$6" > "$CALLDIR/prompt-$N.txt"
F=$(grep -o 'key [0-9a-f]\{12\})' <<<"$6" | head -1 | cut -c5-16)
printf '%s %s\n' "$F" "$(wc -l < "$REQ_SINK" | tr -d ' ')" >> "$CALLDIR/fams"
if [ "${AGENT_STUB_CLIFF:-0}" = 1 ]; then
  printf 'AGENT_CALL_CLIFF_ROUTED grok projected 1408081 > cliff 200000\n' > "$5"; exit 79
fi
echo "handled=1 escalated=0 noise=0" > "$5"
CALLEOF
chmod +x "$H/bin/agent-call.sh"

# --- harness -----------------------------------------------------------------
reset() {
  triage_tick_reset "$H"
  rm -rf "$T/calls"; mkdir -p "$T/calls"; : > "$T/calls/fams"; : > "$T/req.log"
  : > "$H/logs/alert-triage.log"; : > "$H/logs/ALERTS.log"
  echo '{}' > "$H/state/alert-families.json"; echo '{}' > "$T/ledger.json"
  echo '{"families":[]}' > "$T/families.json"
  rm -f "$H/state/alert-triage-deferred.tsv" "$H/state/alert-triage-cliff.json" \
        "$H/state/alert-triage-cliff-parked.tsv" "$H/flags"/alerted-*
  : > "$H/state/alert-quarantine.jsonl"
}
lane() {
  CALLDIR="$T/calls" REQ_SINK="$T/req.log" PATH="$T/fakebin:$PATH" \
    CURL_MODE="${CURL_MODE:-ok}" triage_tick "$H/bin/alert-triage.sh" >/dev/null 2>&1
}
dispatched() { cut -d' ' -f1 "$T/calls/fams" | sort -u | tr '\n' ' '; }
count() { grep -c -- "$1" "$T/req.log" 2>/dev/null || true; }
flag_on()  { touch "$H/flags/alerts-db"; }
flag_off() { rm -f "$H/flags/alerts-db"; }
seed() { python3 "$T/ledger.py" seed "$@"; }
row()  { python3 "$T/ledger.py" row "$@"; }
famof() { PYTHONPATH="$DIR/bin" python3 -c 'import sys
from alert_family import family
print(family(sys.argv[1]))' "hub	$1"; }

# quarantine line in the on-disk shape (epoch<TAB>beat-json); the family key of
# the collected line (hub<TAB>epoch<TAB>json) is what famkey() computes.
qline() { printf '%s\t{"kind":"fleet_alert","project":"p","akey":"k-%s","line":"%s"}' "$(( NOW - 300 ))" "$1" "$2"; }
q() { qline "$1" "$2" >> "$H/state/alert-quarantine.jsonl"; echo >> "$H/state/alert-quarantine.jsonl"; }
famkey() { famof "$(qline "$1" "$2")"; }

LF="the walrus subsystem is unhappy #bdbF"
F=$(famkey f "$LF")
LG=("the narwhal lane stalled #bdbG1" "the otter queue is jammed #bdbG2" "the heron build is red #bdbG3"
    "the badger sweep timed out #bdbG4" "the lynx cache is cold #bdbG5")
G=(); for i in 0 1 2 3 4; do G+=("$(famkey "g$i" "${LG[$i]}")"); done
[ "$(printf '%s\n' "$F" "${G[@]}" | sort -u | wc -l)" = 6 ] \
  && ok || bad "fixture: six distinct families expected ($F ${G[*]})"

# ============================ off — the flag is absent =======================
reset; flag_off
seed brake:triage-family "$F" set $(( NOW - 3600 ))
q f "$LF"; lane
[ "$(dispatched)" = "$F " ] && ok || bad "off: F must be dispatched with the flag off (got '$(dispatched)')"
[ "$(count 'jobs.invalid/api/ledger')" = 0 ] && ok || bad "off: $(count 'jobs.invalid/api/ledger') /api/ledger request(s) with the flag off"
[ "$(count 'jobs.invalid/api/alerts/families')" = 0 ] && ok || bad "off: /api/alerts/families was read with the flag off"

# ============ a — a DB family brake stops a rebuilt hub's session =============
reset; flag_on
seed brake:triage-family "$F" set $(( NOW - 3600 ))
q f "$LF"; lane
[ "$(dispatched)" = "" ] && ok || bad "a: F braked 1h ago in the DB must not be dispatched (got '$(dispatched)')"
grep -q 'repeats of families triaged <6h ago' "$H/logs/alert-triage.log" \
  && ok || bad "a: the lane log must say the line was a repeat"

# ============ a2 — the `triaged` families read brakes too, and only it ========
reset; flag_on
printf '{"families":[{"family":"%s","last_claimed_at":"%s","n":1}]}\n' "$F" "$(iso 3600)" > "$T/families.json"
q f "$LF"; lane
[ "$(dispatched)" = "" ] && ok || bad "a2: F triaged 1h ago per alert_families must not be dispatched (got '$(dispatched)')"
grep -q 'GET https://jobs.invalid/api/alerts/families?lane=alert-triage&claimed_since_s=21600&state=triaged ' "$T/req.log" \
  && ok || bad "a2: the families read must ask lane=alert-triage, 21600s, state=triaged ($(grep families "$T/req.log"))"

# ============ b — a brake older than 6h does not hold ==========================
reset; flag_on
seed brake:triage-family "$F" set $(( NOW - 25200 ))
q f "$LF"; lane
[ "$(dispatched)" = "$F " ] && ok || bad "b: F braked 7h ago must be dispatched (got '$(dispatched)')"
grep -q 'tier=floor' "$H/logs/alert-triage.log" \
  && ok || bad "b: a family the DB has seen is a re-occurrence and runs on the floor tier"

# ============ c / c2 — run families are marked, the deferred one is not ======
reset; flag_on
for i in 0 1 2 3 4; do q "g$i" "${LG[$i]}"; done
TRIAGE_MAX_FAMILIES=4 lane
MARKED=$(grep '^PUT https://jobs.invalid/api/ledger ' "$T/req.log" | sed 's/^[^{]*//' \
  | jq -r 'select(.kind=="brake:triage-family" and .status=="set") | .key' | sort | tr '\n' ' ')
WANT=$(printf '%s\n' "${G[0]}" "${G[1]}" "${G[2]}" "${G[3]}" | sort | tr '\n' ' ')
[ "$MARKED" = "$WANT" ] && ok || bad "c: marked families '$MARKED', expected exactly the four run families '$WANT'"
[ "$(row brake:triage-family "${G[4]}")" = "" ] && ok || bad "c: the deferred family G must have NO ledger row"
for i in 0 1 2 3; do
  D=$(row brake:triage-family "${G[$i]}")
  [ "$(cut -f1 <<<"$D")" = set ] && [ "$(cut -f2 <<<"$D" | jq -r '.at')" -ge "$NOW" ] \
    && ok || bad "c: run family ${G[$i]} must be set at the tick's clock (row '$D')"
done
FIRSTPUT=$(grep -n "^PUT https://jobs.invalid/api/ledger .*\"key\":\"${G[0]}\"" "$T/req.log" | head -1 | cut -d: -f1)
ATCALL=$(awk -v f="${G[0]}" '$1==f {print $2; exit}' "$T/calls/fams")
[ -n "$FIRSTPUT" ] && [ -n "$ATCALL" ] && [ "$FIRSTPUT" -le "$ATCALL" ] \
  && ok || bad "c2: the mark for ${G[0]} (req #${FIRSTPUT:-none}) must precede its session (req count ${ATCALL:-none})"

# ============ d — a cliff refusal restores the DB stamp too ==================
reset; flag_on
P=$(( NOW - 30000 ))
printf '{"%s": %s}\n' "${G[1]}" "$P" > "$H/state/alert-families.json"
q f "$LF"; q g1 "${LG[1]}"
AGENT_STUB_CLIFF=1 lane
[ "$(dispatched | wc -w)" -ge 2 ] && ok || bad "d: both families must reach agent-call (got '$(dispatched)')"
[ "$(row brake:triage-family "$F" | cut -f1)" = cleared ] \
  && ok || bad "d: never-seen F refused on the cliff must be cleared in the DB (row '$(row brake:triage-family "$F")')"
D=$(row brake:triage-family "${G[1]}")
[ "$(cut -f1 <<<"$D")" = set ] && [ "$(cut -f2 <<<"$D" | jq -r '.at')" = "$P" ] \
  && ok || bad "d: G1 refused on the cliff must go back to its prior epoch $P (row '$D')"

# ============ e — an outage reads exactly like the flag being off =============
efix() {
  reset
  printf '{"%s": %s}\n' "${G[2]}" $(( NOW - 600 )) > "$H/state/alert-families.json"
  seed brake:triage-family "${G[3]}" set $(( NOW - 3600 ))
  q f "$LF"; q g2 "${LG[2]}"; q g4 "${LG[4]}"
}
efix; flag_off; lane; S0=$(dispatched)
efix; flag_on; CURL_MODE=5xx lane; S1=$(dispatched)
[ "$(count '"status":"cleared"')" = 0 ] && ok || bad "e: a clear was sent while every read failed (5xx)"
[ "$(grep -c 'family-mark' "$H/logs/alert-triage.log")" = 1 ] \
  && ok || bad "e: a failing mark must be logged exactly once per tick (got $(grep -c 'family-mark' "$H/logs/alert-triage.log"))"
efix; flag_on; CURL_MODE=html lane; S2=$(dispatched)
[ "$(count '"status":"cleared"')" = 0 ] && ok || bad "e: a clear was sent while every read failed (html)"
[ -n "$S0" ] && [ "$S0" = "$S1" ] && [ "$S0" = "$S2" ] \
  && ok || bad "e: dispatch must be identical off / 5xx / html (off='$S0' 5xx='$S1' html='$S2')"

# ============ e2 — a cleared row does not brake ==============================
reset; flag_on
seed brake:triage-family "$F" cleared $(( NOW - 3600 ))
q f "$LF"; lane
[ "$(dispatched)" = "$F " ] && ok || bad "e2: a cleared DB row must not brake F (got '$(dispatched)')"

echo "triage-brake-db.bh-2316: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
