#!/bin/bash
# tests/triage-spool-db.bh-2316-test.sh — the alert-triage DEFERRED and
# CLIFF-PARKED spools survive a dead hub (BH-2344 / BH-2316.1).
#
# state/alert-triage-deferred.tsv holds every family the session cap pushed to
# the next tick; state/alert-triage-cliff-parked.tsv holds what the cliff
# refused for good. Both lived only on the hub's disk. With flags/alerts-db the
# lane mirrors every non-`"dbrow":true` spool line to the ledger (kind
# brake:triage-deferred / brake:triage-cliff, key = sha256 of the line bytes,
# detail {"line":...}) and, when the local deferred spool is ABSENT, puts the
# ledger's lines back into the tick.
#
# Runs the REAL bin/alert-triage.sh against the same file-backed worker stub as
# tests/triage-brake-db.bh-2316-test.sh.
#
#   s1  a deferred line whose local spool was deleted comes back exactly once.
#   s2  a dbrow line is never mirrored.
#   s3  a drained line is cleared and not read again; a failed read clears
#       nothing, a good one clears what the local spool no longer holds.
#   s4  a line over 3800 bytes is not mirrored and the lane log says so.
#   s5  a line deferred on two ticks is marked once (the mirror is a diff).
#   s6  a cliff-parked line is mirrored as brake:triage-cliff, the page names
#       the kind, and nothing re-queues it.
#   s7  a failed read (5xx, HTML-200) over a 500-line spool marks nothing: a
#       worker outage is no PUT storm (lead review, PR #2445).
#   s8  a #truncated read over a 500-line spool marks nothing either.
#   s9  the steady state is two ledger PUTs a tick for a 30-family spool.
#   s10 the next complete read mirrors every line the outage skipped.
#
# Run from anywhere: tests/triage-spool-db.bh-2316-test.sh   (exit 0 = all pass)
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
# BH-5942: project "p" is not in fleet.conf, so its lines belong to the home
# project's run, and that run's spool is the deferral spool under test.
HP="$H/state/alert-triage/cromford"
LEGACY="$H/state/alert-triage-deferred.tsv"   # the dispatch's shared spool

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
  triage_tick_reset "$H"; mkdir -p "$HP"
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
# BH-5942: in production the dispatch starts a run for EVERY fleet project each
# tick, and an empty run still reconciles its spool with the ledger.
# triage_tick runs only the projects with queued work, so a case whose home
# spool is empty runs the home project's run itself after the tick.
lane_home() {
  lane
  CALLDIR="$T/calls" REQ_SINK="$T/req.log" PATH="$T/fakebin:$PATH" \
    CURL_MODE="${CURL_MODE:-ok}" bash "$H/bin/alert-triage.sh" cromford >/dev/null 2>&1
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

SPOOL="$HP/deferred.tsv"
full() { printf 'hub\t%s' "$(qline "$1" "$2")"; }   # the line as the spool holds it
sha() { printf '%s' "$1" | sha256sum | cut -c1-64; }
ncalls() { ls "$T/calls"/prompt-*.txt 2>/dev/null | wc -l | tr -d ' '; }
calls_reset() { rm -rf "$T/calls"; mkdir -p "$T/calls"; : > "$T/calls/fams"; }
puts() { grep "^PUT https://jobs.invalid/api/ledger " "$T/req.log" | sed 's/^[^{]*//'; }
nput() { puts | jq -r --arg k "$1" --arg s "$2" 'select(.key==$k and .status==$s) | .key' | grep -c . || true; }

LA="the walrus subsystem is unhappy #spA"; LB="the narwhal lane stalled #spB"; LC="the otter queue is jammed #spC"
FA=$(full a "$LA"); FB=$(full b "$LB"); FC=$(full c "$LC")

# ============ s1 — a deleted local spool is restored exactly once ============
reset; flag_on
q a "$LA"; q b "$LB"
TRIAGE_MAX_FAMILIES=1 lane
[ "$(cat "$SPOOL")" = "$FB" ] && ok || bad "s1: tick 1 must defer exactly B's line (spool '$(cat "$SPOOL")')"
D=$(row brake:triage-deferred "$(sha "$FB")")
[ "$(cut -f1 <<<"$D")" = set ] && [ "$(cut -f2- <<<"$D" | jq -r '.line')" = "$FB" ] \
  && ok || bad "s1: B's deferred line must be mirrored under sha256(line) with detail.line (row '$D')"
rm -f "$SPOOL" "$LEGACY"; calls_reset; : > "$H/logs/alert-triage.log"
lane
[ "$(cat "$T/calls"/prompt-*.txt 2>/dev/null | grep -c '#spB')" = 1 ] \
  && ok || bad "s1: the restored line must reach the session exactly once (got $(cat "$T/calls"/prompt-*.txt 2>/dev/null | grep -c '#spB'))"
grep -q 'restored 1 deferred line(s) from brake:triage-deferred' "$H/logs/alert-triage.log" \
  && ok || bad "s1: the lane log must name the restore"

# ============ s3 — the drained line is cleared, and not read again ============
[ "$(row brake:triage-deferred "$(sha "$FB")" | cut -f1)" = cleared ] \
  && ok || bad "s3: B's line was triaged and not re-spooled, so its row must be cleared ($(row brake:triage-deferred "$(sha "$FB")"))"
rm -f "$SPOOL" "$LEGACY"; calls_reset
lane
[ "$(ncalls)" = 0 ] && ok || bad "s3: a cleared line must not be restored again (calls=$(ncalls))"

# A failed read clears nothing; a complete one clears what the spool dropped.
reset; flag_on
seed brake:triage-deferred "$(sha "hub	orphan")" set $(( NOW - 600 ))
: > "$SPOOL"
CURL_MODE=5xx lane_home
[ "$(grep -c '"status":"cleared"' "$T/req.log")" = 0 ] && ok || bad "s3: a 5xx read must never lead to a clear"
: > "$T/req.log"; : > "$SPOOL"
lane_home
[ "$(nput "$(sha "hub	orphan")" cleared)" = 1 ] && ok || bad "s3: a complete read must clear the row the local spool no longer holds"

# ============ s2 — a dbrow line is never mirrored =============================
reset; flag_on
FDB=$(printf 'hub\t%s\t{"kind":"fleet_alert","project":"p","akey":"orclane:r1","alertid":"r1","line":"%s","dbrow":true}' "$(( NOW - 300 ))" "$LB")
printf '%s\n%s\n%s\n' "$FA" "$FDB" "$FC" > "$SPOOL"
TRIAGE_MAX_FAMILIES=1 lane
grep -qxF "$FDB" "$SPOOL" && grep -qxF "$FC" "$SPOOL" && ok || bad "s2: the dbrow and C lines must stay deferred locally"
[ "$(nput "$(sha "$FC")" set)" = 1 ] && ok || bad "s2: the non-dbrow deferred line C must be mirrored"
[ "$(nput "$(sha "$FDB")" set)" = 0 ] && ok || bad "s2: the dbrow line was mirrored"
[ "$(puts | jq -r 'select(.kind=="brake:triage-deferred") | .detail // ""' | grep -c dbrow)" = 0 ] \
  && ok || bad "s2: a triage-deferred PUT carried a dbrow line"

# ============ s4 — an oversize line stays local and is named ==================
reset; flag_on
BIG="the heron build is red #spZ $(head -c 3800 /dev/zero | tr '\0' x)"
FZ=$(full z "$BIG")
printf '%s\n%s\n' "$FA" "$FZ" > "$SPOOL"
TRIAGE_MAX_FAMILIES=1 lane
[ "${#FZ}" -gt 3800 ] && grep -qxF "$FZ" "$SPOOL" && ok || bad "s4: the oversize line must stay deferred in the local spool"
[ "$(puts | jq -r 'select(.kind=="brake:triage-deferred") | .key' | grep -c "$(sha "$FZ")")" = 0 ] \
  && ok || bad "s4: a line over 3800 bytes was mirrored"
grep -q '1 deferred line(s) over 3800 bytes not mirrored to brake:triage-deferred' "$H/logs/alert-triage.log" \
  && ok || bad "s4: the lane log must name the skip ($(grep -i mirror "$H/logs/alert-triage.log"))"

# ============ s5 — deferred on two ticks, marked once ========================
reset; flag_on
q a "$LA"; q b "$LB"; q c "$LC"
TRIAGE_MAX_FAMILIES=1 lane
calls_reset
TRIAGE_MAX_FAMILIES=1 lane
grep -qxF "$FC" "$SPOOL" && ok || bad "s5: C must still be deferred after tick 2"
[ "$(nput "$(sha "$FC")" set)" = 1 ] && ok || bad "s5: C must be marked exactly once across two ticks (got $(nput "$(sha "$FC")" set))"
[ "$(nput "$(sha "$FB")" cleared)" = 1 ] && ok || bad "s5: B, drained on tick 2, must be cleared once"

# ============ s6 — a cliff-parked line is mirrored and never re-queued ========
reset; flag_on
q a "$LA"
AGENT_STUB_CLIFF=1 TRIAGE_CLIFF_MAX_REFUSALS=0 lane
grep -qxF "$FA" "$H/state/alert-triage-cliff-parked.tsv" && ok || bad "s6: the line must be parked locally"
[ "$(puts | jq -r --arg k "$(sha "$FA")" 'select(.kind=="brake:triage-cliff" and .key==$k) | .detail | fromjson | .line')" = "$FA" ] \
  && ok || bad "s6: the parked line must be mirrored as brake:triage-cliff with detail.line"
grep -q 'kind=brake:triage-cliff' "$H/logs/ALERTS.log" && grep -q 'alert-triage-cliff-parked.tsv' "$H/logs/ALERTS.log" \
  && ok || bad "s6: the page must name the file and kind=brake:triage-cliff ($(cat "$H/logs/ALERTS.log"))"
calls_reset; rm -f "$SPOOL" "$LEGACY"
lane
[ "$(ncalls)" = 0 ] && ok || bad "s6: nothing may re-queue a parked line (calls=$(ncalls))"

# ============ s7-s10 — a failed or truncated read is no PUT storm =============
# The mirror is a diff against the ledger read. When that read failed or was cut
# at the page cap, the diff has nothing to subtract, and marking "every line not
# in the read" re-PUTs the whole spool every tick — about 2,000 requests per
# */10 tick at the hub's size, each 7-17 s on a partition, under the lane lock.
# letters g-z only: alert_family folds digits and 8+ hex runs into one family.
names() { python3 -c 'import sys
L="ghijklmnopqrstuvwxyz"
for i in range(int(sys.argv[1])): print(L[i//400%20]+L[i//20%20]+L[i%20])' "$1"; }
bulk_spool() { local n; while read -r n; do full "$n" "the $n subsystem is unhappy #bulk"; echo; done < <(names "$1") > "$SPOOL"; }
ndefset() { puts | jq -r 'select(.kind=="brake:triage-deferred" and .status=="set") | .key' | grep -c . || true; }
nledput() { grep -c "^PUT https://jobs.invalid/api/ledger " "$T/req.log" || true; }
# every mirrorable line of the local spool is a set row in the ledger
unmirrored() { python3 - "$SPOOL" "$T/ledger.json" <<'PYU'
import hashlib, json, sys
d = json.load(open(sys.argv[2]))
n = 0
for b in open(sys.argv[1], "rb").read().split(b"\n"):
    if b.strip():
        r = d.get("brake:triage-deferred|" + hashlib.sha256(b).hexdigest())
        n += (r is None or r["status"] != "set")
print(n)
PYU
}

for MODE in 5xx html; do
  reset; flag_on; bulk_spool 500
  CURL_MODE=$MODE TRIAGE_MAX_FAMILIES=1 lane
  [ "$(wc -l < "$SPOOL" | tr -d ' ')" -ge 499 ] && ok || bad "s7[$MODE]: the spool must still hold the deferred lines ($(wc -l < "$SPOOL"))"
  [ "$(ndefset)" = 0 ] && ok || bad "s7[$MODE]: a failed read must mark nothing, got $(ndefset) brake:triage-deferred PUT(s) over a 500-line spool"
  grep -q 'brake:triage-deferred read failed' "$H/logs/alert-triage.log" \
    && ok || bad "s7[$MODE]: the lane log must say the mirror was skipped ($(grep -i deferred "$H/logs/alert-triage.log"))"
  # s10 — the outage lost nothing: the next complete read mirrors every line.
  : > "$T/req.log"; calls_reset
  TRIAGE_MAX_FAMILIES=1 lane
  [ "$(unmirrored)" = 0 ] && ok || bad "s10[$MODE]: after a good read every spooled line must be a set row ($(unmirrored) missing)"
  [ "$(ndefset)" -ge 497 ] && ok || bad "s10[$MODE]: the good read must mark what the outage skipped (got $(ndefset))"
done

# s8 — a read cut at the page cap: the spool's own rows are older than 5000
# newer ones, so the read that stops at five pages never reaches them.
reset; flag_on; bulk_spool 500
python3 - "$SPOOL" "$T/ledger.json" "$NOW" <<'PYT'
import hashlib, json, sys, time
spool, path, now = sys.argv[1], sys.argv[2], int(sys.argv[3])
iso = lambda e: time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(e))
d, seq = {}, 0
for b in open(spool, "rb").read().split(b"\n"):
    if b.strip():
        seq += 1; k = hashlib.sha256(b).hexdigest()
        d["brake:triage-deferred|" + k] = {"kind": "brake:triage-deferred", "key": k, "status": "set",
            "detail": json.dumps({"line": b.decode(), "at": now - 7200}), "updated_at": iso(now - 7200), "seq": seq}
for i in range(5200):
    seq += 1; k = "junk%05d" % i
    d["brake:triage-deferred|" + k] = {"kind": "brake:triage-deferred", "key": k, "status": "set",
        "detail": json.dumps({"at": now - 60}), "updated_at": iso(now - 60 - i), "seq": seq}
json.dump(d, open(path, "w"))
PYT
TRIAGE_MAX_FAMILIES=1 lane
grep -q 'brake:triage-deferred read is truncated' "$H/logs/alert-triage.log" \
  && ok || bad "s8: the read must actually be truncated for this to test anything"
[ "$(ndefset)" = 0 ] && ok || bad "s8: a truncated read must mark nothing, got $(ndefset) brake:triage-deferred PUT(s) over a 500-line spool"
[ "$(grep -c '"status":"cleared"' "$T/req.log")" = 0 ] && ok || bad "s8: a truncated read must clear nothing"

# s9 — steady state is unchanged: a 30-family spool already mirrored costs one
# family-brake mark and one clear for the family the tick drained.
reset; flag_on; bulk_spool 30
TRIAGE_MAX_FAMILIES=1 lane
: > "$T/req.log"; calls_reset
TRIAGE_MAX_FAMILIES=1 lane
[ "$(nledput)" = 2 ] && ok || bad "s9: a steady-state tick over 30 families must cost 2 ledger PUTs, got $(nledput)"

echo "triage-spool-db.bh-2316: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
