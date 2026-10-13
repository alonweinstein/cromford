#!/bin/bash
# tests/alerts-claims.bh-1327-test.sh — the BH-1071 follow-ups on the triage
# lane's alerts-table write-throughs (BH-1327):
#
#   1. A CLIFF-PARKED family LEAVES THE CLAIM QUEUE. bin/alert-triage.sh parks a
#      family's lines in state/alert-triage-cliff-parked.tsv after the fourth
#      refusal and stops re-spooling them — but the ROW stayed `quarantined` and
#      claimed, so the worker's 900s lease re-offered it, the lane refused it
#      again, and the same lines were appended to the park file again, forever,
#      at no cost to anyone but the operator reading the file. The park is now
#      mirrored to the table as `parked`, which the claim query filters out.
#   2. THE MISS LINE IS TRUE FOR THE ID IT NAMES. The triaged write-through
#      PATCHes every `alertid` in the family, and bin/lane-alert.sh /
#      bin/claude-auth-check.sh emit `alertid` beats that only have a table row
#      when THAT box's writer side is on. A 404 for such an id used to log "the
#      row is re-offered when its lease lapses" — there is no row and no lease.
#
# Ordering is the third property: the park FILE is the primary record and the
# PATCH only mirrors it, so the PATCH must happen after the append. The fake
# curl proves it by stamping PARKFILE=<1|0> next to every `parked` request.
#
# Runs the REAL bin/alert-triage.sh end to end, exactly as its two siblings do
# (tests/alerts-claims.bh-1071-test.sh, tests/triage-volume-caps.bh-1039-test.sh):
# only the harness ROOT is rewritten, and only what would leave this machine or
# spend money is stubbed. What the stubs RECEIVE is the assertion.
#
# Run from anywhere: tests/alerts-claims.bh-1327-test.sh   (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
. "$(dirname "$0")/lib/triage-tick.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

# ONE clock read for the whole file; every fixture age is derived from it.
NOW=$(date -u +%s)
iso() { date -u -d "@$(( NOW - ${1:-0} ))" '+%Y-%m-%dT%H:%M:%SZ'; }

H="$T/h"
. "$DIR/tests/lib/model-route-stub.sh" || exit 1; model_routes_fixture "$H" || exit 1  # BH-1510.2: lanes read models from model_routes
mkdir -p "$H/bin/lib/jobs" "$H/logs" "$H/state" "$H/locks" "$H/env" "$H/flags" \
         "$T/fakebin" "$T/calls" "$T/remote/state"

printf 'CONSOLE_URL=https://console.invalid\nJOBS_URL=https://jobs.invalid\nHARNESS_SECRET=testsecret\nJOBS_RETRIES=0\n' \
  > "$H/env/global.env"

# --- the script under test, with only its harness root repointed -------------
sed "s|/root/harness|$H|g" "$DIR/bin/alert-triage.sh" > "$H/bin/alert-triage.sh"
chmod +x "$H/bin/alert-triage.sh"

# The real libraries: alerts_db_on sources $HARNESS/bin/jobs-client.sh, and the
# BH-1194 shim resolves its modules off BASH_SOURCE — for a sourced symlink that
# is the symlink's own dir ($H/bin), not the checkout's, so the modules are
# copied next to it (the same pattern the BH-1071 suite uses); without them the
# client refuses to half-load and alert_claim/alert_state_set never fire.
for s in jobs-client.sh triage-map.sh fleet-conf.sh box-for.sh project-of.sh \
         triage-spool-retire.sh alert_family.py; do
  ln -sf "$DIR/bin/$s" "$H/bin/$s"
done
cp "$DIR"/bin/lib/jobs/*.sh "$H/bin/lib/jobs/"
ln -sf "$DIR/bin/lib/alert-state.sh" "$H/bin/lib/alert-state.sh"
ln -sf "$DIR/bin/lib/env-path.sh" "$H/bin/lib/env-path.sh"
export FLEET_CONF="$DIR/fleet.conf"
triage_tick_setup "$H" || exit 1   # BH-5942: the triage lane is a dispatch + per-project runs
printf '#!/usr/bin/env python3\n' > "$H/bin/alerts-supersede.py"

# --- stubs -------------------------------------------------------------------
# curl: records "METHOD URL BODY" and answers the jobs wire shape (body, then a
# status line). Two behaviours this suite needs beyond the sibling's stub:
#   * an id listed in norow.txt has NO ROW — 404, which _jobs_req maps to rc 2.
#     That is the production shape of a beat alertid from a box whose writer
#     side is off, and of a row that has since been closed. Which ids miss is
#     kept in a FIXTURE rather than in the id text, because family() hashes the
#     whole rendered line: ids that must share a family key have to fold to the
#     same token, so they cannot also carry a "this one 404s" marker.
#   * every `parked` PATCH is followed by PARKFILE=<1|0>, whether the park file
#     was already non-empty when the request arrived. That is the write-after-
#     record proof: the file is the primary, the table only mirrors it.
{ echo '#!/bin/bash'; echo "FIX=$T"; echo "PARKF=$H/state/alert-triage-cliff-parked.tsv"; cat <<'CURLEOF'
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
  *jobs.invalid*)
    case "$METHOD $URL" in
      "POST "*/api/alerts/claim) printf '%s\n200\n' "$(cat "$FIX/claim.json")" ;;
      "PATCH "*/api/alerts/state)
        case "$BODY" in
          *'"state":"parked"'*)
            if [ -s "$PARKF" ]; then echo 'PARKFILE=1' >> "$REQ_SINK"; else echo 'PARKFILE=0' >> "$REQ_SINK"; fi ;;
        esac
        PID=$(printf '%s' "$BODY" | sed -n 's/.*"id":"\([^"]*\)".*/\1/p')
        if [ -n "$PID" ] && grep -qxF "$PID" "$FIX/norow.txt" 2>/dev/null; then
          printf '{"error":"no such alert"}\n404\n'
        elif [ -n "$PID" ] && grep -qxF "$PID" "$FIX/err.txt" 2>/dev/null; then
          printf '{"error":"boom"}\n500\n'
        else
          printf '{"alert":{"state":"set"}}\n200\n'
        fi ;;
      *) printf '{"error":"not found"}\n404\n' ;;
    esac ;;
  *) echo '{}' ;;
esac
CURLEOF
} > "$T/fakebin/curl"; chmod +x "$T/fakebin/curl"

# ssh: runs the remote command against a second tree ($T/remote), so the GRAB
# snippet really drains a remote box's quarantine file.
{ echo '#!/bin/bash'; echo "HROOT=$H"; echo "RROOT=$T/remote"; cat <<'SSHEOF'
CMD="${!#}"
exec bash -c "${CMD//$HROOT/$RROOT}"
SSHEOF
} > "$T/fakebin/ssh"; chmod +x "$T/fakebin/ssh"

printf '#!/bin/sh\necho MERGED\n' > "$T/fakebin/gh"; chmod +x "$T/fakebin/gh"
printf '#!/bin/sh\nexit 0\n' > "$T/fakebin/flock"; chmod +x "$T/fakebin/flock"
printf '#!/bin/sh\nshift\nexec "$@"\n' > "$T/fakebin/timeout"; chmod +x "$T/fakebin/timeout"

# agent-call.sh: records the prompt it was handed, and refuses on the price
# cliff when AGENT_STUB_CLIFF=1 — rc 79 with agent-call's own marker as the
# first line of $OUT, copied from tests/triage-volume-caps.bh-1039-test.sh.
cat > "$H/bin/agent-call.sh" <<'CALLEOF'
#!/bin/bash
N=$(ls "$CALLDIR"/prompt-*.txt 2>/dev/null | wc -l | tr -d ' ')
printf '%s' "$6" > "$CALLDIR/prompt-$N.txt"
if [ "${AGENT_STUB_CLIFF:-0}" = 1 ]; then
  printf 'AGENT_CALL_CLIFF_ROUTED grok projected 1408081 > cliff 200000\n' > "$5"
  exit 79
fi
echo "handled=1 escalated=0 noise=0" > "$5"
CALLEOF
chmod +x "$H/bin/agent-call.sh"

# --- harness -----------------------------------------------------------------
: > "$T/allreq.log"
fresh() { rm -rf "${T:?}/calls"; mkdir -p "$T/calls"; : > "$T/req.log"; }
# ONE TICK, exactly as the hub cron runs it. TRIAGE_CLIFF_FLOOR_RETRY=0 so one
# refusal is one tick's whole story; TRIAGE_CLIFF_MAX_REFUSALS is left at its
# production default (3), so the fourth tick is the one that parks.
tick() { # tick [VAR=VAL ...]
  ( export CALLDIR="$T/calls" REQ_SINK="$T/req.log" PATH="$T/fakebin:$PATH" \
           TRIAGE_CLIFF_FLOOR_RETRY=0
    [ "$#" -gt 0 ] && export "$@"
    triage_tick "$H/bin/alert-triage.sh" >/dev/null 2>&1 )
  cat "$T/req.log" >> "$T/allreq.log" 2>/dev/null
}
cliff4() { local n=0; while [ "$n" -lt 4 ]; do tick AGENT_STUB_CLIFF=1; n=$((n+1)); done; }
ncalls() { ls "$T/calls"/prompt-*.txt 2>/dev/null | wc -l | tr -d ' '; }
count() { grep -c "$1" "$T/req.log" 2>/dev/null || true; }
lineno() { grep -n "$1" "$T/req.log" 2>/dev/null | head -1 | cut -d: -f1; }
tlog() { cat "$H/logs/alert-triage.log" 2>/dev/null; }
parkfile() { echo "$H/state/alert-triage-cliff-parked.tsv"; }
parklines() { grep -c . "$H/state/alert-triage-cliff-parked.tsv" 2>/dev/null || true; }
flag_on()  { touch "$H/flags/alerts-db"; }
flag_off() { rm -f "$H/flags/alerts-db"; }

reset_triage() {
  triage_tick_reset "$H"
  : > "$H/logs/alert-triage.log"; : > "$H/logs/ALERTS.log"
  echo '{}' > "$H/state/alert-families.json"
  : > "$H/state/alert-triage-deferred.tsv"
  : > "$H/state/alert-quarantine.jsonl"
  : > "$T/remote/state/alert-quarantine.jsonl"
  rm -f "$H/state/alert-triage-cliff.json" "$H/state/alert-triage-cliff-parked.tsv" \
        "$H/flags/"alerted-triage-cliff-* "$H/state/"alert-triage-expired-*.tsv
  echo '{"alerts":[]}' > "$T/claim.json"
  : > "$T/norow.txt"; : > "$T/err.txt"
}
norow() { printf '%s\n' "$@" > "$T/norow.txt"; }   # ids the worker has no row for
errids() { printf '%s\n' "$@" > "$T/err.txt"; }    # ids whose PATCH 500s (rc 1)

# --- fixtures ----------------------------------------------------------------
# A quarantine line in the real on-disk shape (epoch<TAB>beat-json). $4 is any
# extra JSON the case needs (an `alertid`, a `dbrow` marker).
q() { # q <file> <akey> <line> [extra-json]
  printf '%s\t{"kind":"fleet_alert","project":"p-%s","akey":"k-%s","line":"%s"%s}\n' \
    "$(( NOW - 300 ))" "$2" "$2" "$3" "${4:-}" >> "$1"
}
row() { # row <id> <line> — one claimed, quarantined row in the table's TSV order
  printf '{"id":"%s","family":"f","box":"hub","project":"","state":"quarantined","count":1,"first_seen":"%s","last_seen":"%s","claimed_by":"alert-triage@hub","claimed_at":"%s","notified_at":"","severity":"warn","line":"%s"}' \
    "$1" "$(iso 600)" "$(iso 60)" "$(iso 0)" "$2"
}
claim_rows() { # claim_rows <id> <line> [<id> <line>...]
  { echo '{"alerts":['
    local i=0
    while [ "$#" -gt 1 ]; do
      [ "$i" -gt 0 ] && echo ','
      row "$1" "$2"; shift 2; i=$((i+1))
    done
    echo ']}'; } > "$T/claim.json"
}

L1="the project-9 subsystem is unhappy: 3 builds stuck"
L2="the project-9 subsystem is unhappy: 17 builds stuck"
LOTHER="MEDIC: the walrus lane needs a human #p0other"
echo '{"alerts":[]}' > "$T/claim.json"
: > "$T/norow.txt"; : > "$T/err.txt"

# ---------- p0. the fixture really is ONE family -----------------------------
# Every case below assumes L1 and L2 collapse into a single family (one session,
# one park, one PATCH loop). A bad fixture fails in the exact shape of a code
# bug, so it is asserted before anything else.
SAME=$(PYTHONPATH="$DIR/bin" python3 -c 'import sys
from alert_family import family
print(len({family(a) for a in sys.argv[1:3]}), len({family(a) for a in sys.argv[1:4]}))' "$L1" "$L2" "$LOTHER")
[ "$SAME" = "1 2" ] \
  && ok || bad "p0: L1/L2 must be ONE family and LOTHER a second (got '$SAME')"

# ================= p1 — the park writes through to the table =================
# Four cliff refusals. The first three re-spool (and must PATCH nothing); the
# fourth parks the lines in the file AND stamps the claimed row `parked`, which
# is what takes it out of `alert_claim alert-triage quarantined`.
flag_on
reset_triage; fresh
claim_rows cliff-row-1 "$L1"
n=0; while [ "$n" -lt 3 ]; do tick AGENT_STUB_CLIFF=1; n=$((n+1)); done
[ "$(count '"state":"parked"')" = 0 ] \
  && ok || bad "p1: a re-spooled refusal must stamp nothing (got $(count '"state":"parked"'))"
[ "$(count 'PATCH https://jobs.invalid/api/alerts/state')" = 0 ] \
  && ok || bad "p1: refusals 1-3 must send no state PATCH at all"
grep -q 'CLIFF REFUSED (attempt 3 of 3)' <<<"$(tlog)" \
  && ok || bad "p1: the third refusal must still be a re-spool: $(tlog)"
tick AGENT_STUB_CLIFF=1
[ "$(count 'PATCH https://jobs.invalid/api/alerts/state')" = 1 ] \
  && ok || bad "p1: the park must send exactly ONE state PATCH (got $(count 'PATCH https://jobs.invalid/api/alerts/state'))"
SB=$(grep -m1 'PATCH https://jobs.invalid/api/alerts/state' "$T/req.log" | sed 's/^[^ ]* [^ ]* //')
[ "$(jq -r '.id' <<<"$SB" 2>/dev/null)" = "cliff-row-1" ] \
  && [ "$(jq -r '.state' <<<"$SB" 2>/dev/null)" = "parked" ] \
  && [ "$(jq -r '.actor' <<<"$SB" 2>/dev/null)" = "alert-triage" ] \
  && ok || bad "p1: the parked PATCH body is missing or wrong: $SB"
# WRITE AFTER RECORD: the park file already held the family's line when the
# request arrived. The marker the curl stub wrote sits on the very next line.
PLN=$(lineno 'PATCH https://jobs.invalid/api/alerts/state')
[ -n "$PLN" ] && [ "$(sed -n "$((PLN+1))p" "$T/req.log")" = "PARKFILE=1" ] \
  && ok || bad "p1: the parked PATCH must follow the park file append (marker: '$(sed -n "$((PLN+1))p" "$T/req.log")')"
[ "$(parklines)" = 1 ] \
  && ok || bad "p1: the family's line must be parked exactly once (got $(parklines)): $(cat "$(parkfile)")"
grep -q 'CLIFF REFUSED 4 times' <<<"$(tlog)" \
  && ok || bad "p1: the fourth refusal must be the park: $(tlog)"
! grep -q 'parked stamp rc=' <<<"$(tlog)" \
  && ok || bad "p1: a stamp that landed must not be logged as a miss: $(tlog)"
[ "$(ncalls)" = 4 ] \
  && ok || bad "p1: four ticks, four refused prompts, nothing billed (calls=$(ncalls))"

# ================= p2 — only the rows this lane CLAIMED ======================
# A beat `alertid` served by a grab has no row here and no lease to lapse.
# Parking it would be this lane stamping a row it never claimed. It is seeded
# in the HUB's own queue: with the claim ok the per-box ssh grab no longer runs
# (BH-2366), and the hub's local grab is the path that still serves such a line.
#
# The two lines are two FAMILIES, not one, and they cannot be otherwise: family()
# hashes the whole rendered line, so `"dbrow":true` is itself part of the key and
# a claimed row can never share a family with a line a grab served. That is
# the shape the dbrow filter has to survive — a whole family with no claimed row
# in it, whose `alertid` must still be left alone.
reset_triage; fresh
claim_rows cliff-row-2 "$L1"
q "$H/state/alert-quarantine.jsonl" p2beat "$L2" ',"alertid":"beat-2"'
cliff4
[ "$(count '"state":"parked"')" = 1 ] \
  && ok || bad "p2: exactly one id may be parked (got $(count '"state":"parked"'))"
grep -q '"id":"cliff-row-2","state":"parked"' "$T/req.log" \
  && ok || bad "p2: the claimed row must be the one parked: $(grep -o '{[^}]*parked[^}]*}' "$T/req.log")"
! grep -q '"id":"beat-2"' "$T/req.log" \
  && ok || bad "p2: a beat alertid this lane never claimed must not be stamped"
[ "$(parklines)" = 2 ] \
  && ok || bad "p2: both refused families' lines must still be parked (got $(parklines))"

# ================= p3 — the flag off is byte-for-byte today ==================
flag_off
reset_triage; fresh
q "$H/state/alert-quarantine.jsonl" p3 "$L1"
cliff4
[ "$(count 'jobs.invalid/api/alerts')" = 0 ] \
  && ok || bad "p3: with the flag off the lane made $(count 'jobs.invalid/api/alerts') jobs request(s)"
[ "$(parklines)" = 1 ] \
  && ok || bad "p3: the park file is still written with the flag off (got $(parklines))"
grep -q 'CLIFF REFUSED 4 times' <<<"$(tlog)" \
  && ok || bad "p3: the park must still happen with the flag off: $(tlog)"

# ============ p4 — a parked stamp that misses is logged, not silent ==========
# Best effort, never retried: the local park stands, the lease re-offers the row
# once more, and the operator can see why from the lane log.
flag_on
reset_triage; fresh
claim_rows row-4 "$L1"
norow row-4
cliff4
grep -q 'parked stamp rc=2 for row-4' <<<"$(tlog)" \
  && ok || bad "p4: a failed parked stamp must name its rc and its id: $(tlog)"
[ "$(count '"state":"parked"')" = 1 ] \
  && ok || bad "p4: a failed parked stamp is not retried (got $(count '"state":"parked"') attempt(s))"
[ "$(parklines)" = 1 ] \
  && ok || bad "p4: the local park stands even when the table never hears about it (got $(parklines))"

# ============ p5 — the triaged miss line is true for the id it names =========
# One tick, three ids the write-through stamps `triaged`: two CLAIMED rows in one
# family (row-51 lands, row-52 404s — the lease wording is RIGHT for it) and a
# beat alertid in its own family that never had a row at all (the lease wording
# is a lie for it). row-51 and row-52 fold to one family key because family()
# folds every digit run; so do the two beats.
#
# The third rendering of the miss line gets its own id: a beat alertid whose
# PATCH fails with an OUTAGE (500 -> rc 1) rather than a 404. There may well be
# a row behind it on a writer-on box — but not one THIS lane holds a lease on,
# so it may not borrow the lease wording either (D13).
#
# The beats are seeded in the HUB's own queue, as in p2: with the claim ok the
# per-box ssh grab no longer runs (BH-2366).
reset_triage; fresh
claim_rows row-51 "$L1" row-52 "$L2"
norow row-52 beat-53
errids beat-54
q "$H/state/alert-quarantine.jsonl" p5beat53 "$L2" ',"alertid":"beat-53"'
q "$H/state/alert-quarantine.jsonl" p5beat54 "$L2" ',"alertid":"beat-54"'
tick
[ "$(ncalls)" = 2 ] \
  && ok || bad "p5: the two claimed rows are one family, the two beats a second (calls=$(ncalls))"
[ "$(count 'PATCH https://jobs.invalid/api/alerts/state')" = 4 ] \
  && ok || bad "p5: every alertid is still stamped triaged (got $(count 'PATCH https://jobs.invalid/api/alerts/state'))"
grep -q 'triaged stamp: no table row for beat-53 (a beat alertid this lane never claimed) — nothing to stamp, nothing is re-offered' <<<"$(tlog)" \
  && ok || bad "p5: a beat alertid's 404 must say there is no row and no lease: $(grep 'triaged stamp' <<<"$(tlog)")"
! grep -q 're-offered when its lease lapses' <<<"$(grep 'beat-53' <<<"$(tlog)")" \
  && ok || bad "p5: a beat alertid has no lease, so it must never be described as re-offered"
grep -q 'triaged stamp rc=1 for beat-54 (a beat alertid this lane never claimed) — no lease here to re-offer it' <<<"$(tlog)" \
  && ok || bad "p5: an outage on a beat alertid must not claim a lease either: $(grep 'triaged stamp' <<<"$(tlog)")"
! grep -q 'lease lapses' <<<"$(grep 'beat-54' <<<"$(tlog)")" \
  && ok || bad "p5: an outage on a beat alertid must not borrow the lease wording"
grep -q 'triaged stamp rc=2 for row-52 — the row is re-offered when its lease lapses' <<<"$(tlog)" \
  && ok || bad "p5: a CLAIMED row's 404 keeps the lease wording, unchanged: $(grep 'triaged stamp' <<<"$(tlog)")"
! grep -q 'row-51' <<<"$(tlog)" \
  && ok || bad "p5: a stamp that landed must be silent: $(grep 'triaged stamp' <<<"$(tlog)")"

# ============ R4 — only the contract's own routes are ever called ============
BAD=""
while read -r U; do
  case "$U" in
    */api/alerts|*/api/alerts\?*|*/api/alerts/claim|*/api/alerts/state|*/api/alerts/resolve|*/api/alerts/families\?*) ;;
    # BH-1510.2: the lane's MODEL is a model_routes read (bin/lib/model-route.sh,
    # its own contract) — a GET that writes nothing about alerts.
    */api/model-routes/*) ;;
    "") ;;
    *) BAD="$BAD $U" ;;
  esac
done < <(grep -o 'https://jobs.invalid[^ ]*' "$T/allreq.log" 2>/dev/null | sort -u)
[ -z "$BAD" ] && ok || bad "a request shape outside the BH-1068 contract was used:$BAD"

echo "alerts-claims-bh-1327: pass=$PASS fail=$FAIL"
[ "$FAIL" -eq 0 ]
