#!/bin/bash
# tests/alerts-claims.bh-1071-test.sh — the three hub alert lanes CLAIM rows in
# the alerts table (BH-1071 / BH-1030.3), and do exactly nothing new when the
# flag is absent.
#
# Runs the REAL bin/alert-triage.sh, bin/alerts-medic.sh and bin/alerts-groom.sh
# end to end (the CI precedent: only the harness ROOT is rewritten). What is
# stubbed is what would leave this machine or spend money — curl, ssh, gh,
# agent-call.sh — and what they RECEIVE is the assertion: the recorded requests
# in req.log and the prompt the session would have been handed.
#
# WHAT IS AT STAKE. The claim is the persisted "have we already paid for this
# row?" check, and it is issued BEFORE agent-call.sh. Three failure shapes this
# file exists to catch:
#   * the flag absent and a request going out anyway (c0) — the whole fleet is
#     supposed to be byte-for-byte today until an operator says otherwise;
#   * the table answering rc 0 with NOTHING and a lane reading that as "go"
#     (c3d): rc 0 + empty is a real answer, and it means no session;
#   * the table being unreachable and a lane going quiet (c2, c3-down, c4-down):
#     every DB call fails OPEN onto today's ssh/file path.
# The fourth is ordering: a row is stamped `triaged` only AFTER the session that
# triaged it returned (c1), never before — a stamp that outruns the work is how
# an alert is marked handled and never handled.
#
# Run from anywhere: tests/alerts-claims.bh-1071-test.sh   (exit 0 = all pass)
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
mkdir -p "$H/bin/lib" "$H/logs" "$H/state" "$H/locks" "$H/env" "$H/flags" \
         "$T/fakebin" "$T/calls" "$T/remote/state"

printf 'CONSOLE_URL=https://console.invalid\nJOBS_URL=https://jobs.invalid\nHARNESS_SECRET=testsecret\nJOBS_RETRIES=0\n' \
  > "$H/env/global.env"

# --- the scripts under test, with only their harness root repointed ----------
for s in alert-triage.sh alerts-medic.sh alerts-groom.sh; do
  sed "s|/root/harness|$H|g" "$DIR/bin/$s" > "$H/bin/$s"; chmod +x "$H/bin/$s"
done
groom_real() { sed "s|/root/harness|$H|g" "$DIR/bin/alerts-groom.sh" > "$H/bin/alerts-groom.sh"; chmod +x "$H/bin/alerts-groom.sh"; }
groom_stub() { printf '#!/bin/sh\nexit 0\n' > "$H/bin/alerts-groom.sh"; chmod +x "$H/bin/alerts-groom.sh"; }

# The real libraries: alerts_db_on sources $HARNESS/bin/jobs-client.sh, and
# alert_state_key runs $HARNESS/bin/alert_family.py. Both are the checkout's.
# BH-1194 made jobs-client.sh a SHIM over bin/lib/jobs/*.sh, and the modules
# resolve off BASH_SOURCE — for a sourced symlink that is the symlink's own
# dir ($H/bin), not the checkout's, so the modules are copied next to it too
# (same pattern as tests/alerts-client.bh-1068-test.sh); without them the
# client refuses to half-load and alert_claim/alert_state_set never fire.
for s in jobs-client.sh triage-map.sh fleet-conf.sh box-for.sh project-of.sh alert_family.py; do
  ln -sf "$DIR/bin/$s" "$H/bin/$s"
done
mkdir -p "$H/bin/lib/jobs"
cp "$DIR"/bin/lib/jobs/*.sh "$H/bin/lib/jobs/"
ln -sf "$DIR/bin/lib/alert-state.sh" "$H/bin/lib/alert-state.sh"
ln -sf "$DIR/bin/lib/env-path.sh" "$H/bin/lib/env-path.sh"
export FLEET_CONF="$DIR/fleet.conf"
triage_tick_setup "$H" || exit 1   # BH-5942: the triage lane is a dispatch + per-project runs
printf '#!/bin/sh\nexit 0\n' > "$H/bin/fleet-projects-or-alert.sh"; chmod +x "$H/bin/fleet-projects-or-alert.sh"
printf '#!/usr/bin/env python3\n' > "$H/bin/alerts-supersede.py"

# --- stubs -------------------------------------------------------------------
# curl: records "METHOD URL BODY" and answers per host. The jobs host speaks the
# jobs-client wire shape (body then a status line); the console host answers raw
# JSON, exactly as those two callers parse them today.
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
  *jobs.invalid*)
    [ "${CURL_MODE:-ok}" = down ] && exit 7
    case "$METHOD $URL" in
      "POST "*/api/alerts/claim)     printf '%s\n200\n' "$(cat "$FIX/claim.json")" ;;
      "GET "*/api/alerts/families*)  printf '%s\n200\n' "$(cat "$FIX/families.json")" ;;
      "GET "*/api/alerts*)           printf '%s\n200\n' "$(cat "$FIX/list.json")" ;;
      "PATCH "*/api/alerts/state)    printf '{"alert":{"state":"set"}}\n200\n' ;;
      "POST "*/api/alerts/resolve)   printf '{"resolved":1}\n200\n' ;;
      *)                             printf '{"error":"not found"}\n404\n' ;;
    esac ;;
  *console.invalid/api/alerts/open) cat "$FIX/console.json" ;;
  *) echo '{}' ;;
esac
CURLEOF
} > "$T/fakebin/curl"; chmod +x "$T/fakebin/curl"

# ssh: 255 when the box is "down", otherwise it runs the remote command against
# a second tree ($T/remote), so the GRAB snippet really drains a remote file.
{ echo '#!/bin/bash'; echo "HROOT=$H"; echo "RROOT=$T/remote"; cat <<'SSHEOF'
[ "${SSH_MODE:-ok}" = down ] && exit 255
CMD="${!#}"
exec bash -c "${CMD//$HROOT/$RROOT}"
SSHEOF
} > "$T/fakebin/ssh"; chmod +x "$T/fakebin/ssh"

printf '#!/bin/sh\necho MERGED\n' > "$T/fakebin/gh"; chmod +x "$T/fakebin/gh"
printf '#!/bin/sh\nexit 0\n' > "$T/fakebin/flock"; chmod +x "$T/fakebin/flock"
printf '#!/bin/sh\nshift\nexec "$@"\n' > "$T/fakebin/timeout"; chmod +x "$T/fakebin/timeout"

# agent-call.sh: records the prompt it was handed AND how many requests had been
# made when it was called — that number is what proves the `triaged` PATCH comes
# after the session rather than before it.
cat > "$H/bin/agent-call.sh" <<'CALLEOF'
#!/bin/bash
N=$(ls "$CALLDIR"/prompt-*.txt 2>/dev/null | wc -l | tr -d ' ')
printf '%s' "$6" > "$CALLDIR/prompt-$N.txt"
{ wc -l < "$REQ_SINK" 2>/dev/null || echo 0; } | tr -d ' ' > "$CALLDIR/reqcount"
echo "handled=1 escalated=0 noise=0" > "$5"
CALLEOF
chmod +x "$H/bin/agent-call.sh"

# --- harness -----------------------------------------------------------------
fresh() { rm -rf "$T/calls"; mkdir -p "$T/calls"; : > "$T/req.log"; }
lane() { # lane <script>  — run one lane exactly as cron does
  local rc
  if [ "$1" = alert-triage.sh ]; then   # BH-5942: one tick = the dispatch, then each project's run
    CALLDIR="$T/calls" REQ_SINK="$T/req.log" PATH="$T/fakebin:$PATH" \
      CURL_MODE="${CURL_MODE:-ok}" SSH_MODE="${SSH_MODE:-ok}" \
      triage_tick "$H/bin/$1" >/dev/null 2>&1
  else
    CALLDIR="$T/calls" REQ_SINK="$T/req.log" PATH="$T/fakebin:$PATH" \
      CURL_MODE="${CURL_MODE:-ok}" SSH_MODE="${SSH_MODE:-ok}" \
      bash "$H/bin/$1" >/dev/null 2>&1
  fi
  rc=$?
  cat "$T/req.log" >> "$T/allreq.log" 2>/dev/null
  return $rc
}
ncalls() { ls "$T/calls"/prompt-*.txt 2>/dev/null | wc -l | tr -d ' '; }
prompts() { cat "$T/calls"/prompt-*.txt 2>/dev/null; }
count() { grep -c "$1" "$T/req.log" 2>/dev/null || true; }
lineno() { grep -n "$1" "$T/req.log" 2>/dev/null | head -1 | cut -d: -f1; }
flag_on()  { touch "$H/flags/alerts-db"; }
flag_off() { rm -f "$H/flags/alerts-db"; }
: > "$T/allreq.log"

reset_triage() { triage_tick_reset "$H"; : > "$H/logs/alert-triage.log"; echo '{}' > "$H/state/alert-families.json"
                 : > "$H/state/alert-triage-deferred.tsv"; : > "$H/state/alert-quarantine.jsonl"; }
# BH-5942: the medic runs per project. These rows carry no project, so they are
# the cromford run's, with its state in state/alerts-medic/cromford/.
# Linked like the libs above, not installed as a closure: the closure brings
# bin/lib/lane-gate.sh, whose flag and settings reads would change the request
# shapes this suite pins for every lane.
for l in llm-lane-project.sh project-lanes.sh; do ln -sf "$DIR/bin/lib/$l" "$H/bin/lib/$l"; done
MS="$H/state/alerts-medic/cromford"
reset_medic()  { : > "$H/logs/medic.log"; : > "$H/logs/ALERTS.log"
                 echo '{}' > "$H/state/medic-families.json"; echo '{}' > "$H/state/medic-parked.json"
                 : > "$H/state/medic-seen.txt"; scratch_rm "$MS"; }
medic_lane() { # medic_lane — lane() for the medic's cromford run
  CALLDIR="$T/calls" REQ_SINK="$T/req.log" PATH="$T/fakebin:$PATH" \
    CURL_MODE="${CURL_MODE:-ok}" SSH_MODE="${SSH_MODE:-ok}" \
    bash "$H/bin/alerts-medic.sh" cromford >/dev/null 2>&1
  local rc=$?
  cat "$T/req.log" >> "$T/allreq.log" 2>/dev/null
  return $rc
}

# quarantine line in the real on-disk shape (epoch<TAB>beat-json)
q() { printf '%s\t{"kind":"fleet_alert","project":"p-%s","akey":"k-%s","line":"%s"%s}\n' \
        "$(( NOW - 300 ))" "$2" "$2" "$3" "${4:-}" >> "$1"; }

# --- fixtures ----------------------------------------------------------------
L1="the project-9 subsystem is unhappy: 3 builds stuck"
L2="the project-9 subsystem is unhappy: 17 builds stuck"
L3="the project-9 subsystem is unhappy: 42 builds stuck"
LESC="MEDIC: the walrus lane needs a human #c3esc"
LCLAIMED="the narwhal subsystem is unhappy #c3claimed"

console_pass1() { # the console queue: two candidates of one family + an escalation
  cat > "$T/console.json" <<EOF
{"alerts":[
{"id":"c-one","createdAt":"$(iso 3600)","akey":"beat:one","line":"$L1"},
{"id":"c-two","createdAt":"$(iso 3600)","akey":"beat:two","line":"$L2"},
{"id":"esc-1","createdAt":"$(iso 3600)","akey":"triage:c3esc","line":"$LESC"}]}
EOF
}
console_parked() { # the same queue once the medic's own escalation is open
  cat > "$T/console.json" <<EOF
{"alerts":[
{"id":"c-one","createdAt":"$(iso 3600)","akey":"beat:one","line":"$L1"},
{"id":"c-two","createdAt":"$(iso 3600)","akey":"beat:two","line":"$L2"},
{"id":"esc-1","createdAt":"$(iso 3600)","akey":"medic:$FKEY","line":"$LESC"}]}
EOF
}
row() { # row <id> <claimed_by> <line>
  printf '{"id":"%s","family":"f","box":"hub","project":"","state":"new","count":1,"first_seen":"%s","last_seen":"%s","claimed_by":"%s","claimed_at":"","notified_at":"","severity":"warn","line":"%s"}' \
    "$1" "$(iso 3600)" "$(iso 600)" "$2" "$3"
}
medic_list() {
  { echo '{"alerts":['
    row r-one "" "$L1"; echo ','
    row r-two "" "$L2"; echo ','
    row r-esc "" "$LESC"; echo ','
    row r-claimed "medic@hub" "$LCLAIMED"; echo ','
    row r-new "" "$L3"
    echo ']}'; } > "$T/list.json"
}
claim_answers() { # claim_answers <id>... — what the table says it gave us
  { echo '{"alerts":['
    local i=0 r
    for r in "$@"; do [ "$i" -gt 0 ] && echo ','; row "$r" "medic@hub" "x"; i=$((i+1)); done
    echo ']}'; } > "$T/claim.json"
}
echo '{"families":[]}' > "$T/families.json"
echo '{"alerts":[]}' > "$T/claim.json"
echo '{"alerts":[]}' > "$T/list.json"
echo '{"alerts":[]}' > "$T/console.json"

# ---------- 0a. the fixture really is one family, and the escalation is not ---
# Everything in c3 is meaningless if the markers collapse or fail to collapse,
# and a bad fixture fails in a shape that looks exactly like a code bug.
FKEY=$(PYTHONPATH="$DIR/bin" python3 -c 'import sys
from alert_family import family
print(family(sys.argv[1]))' "$L1")
SAME=$(PYTHONPATH="$DIR/bin" python3 -c 'import sys
from alert_family import family
print(len({family(a) for a in sys.argv[1:4]}), len({family(a) for a in sys.argv[1:5]}))' "$L1" "$L2" "$L3" "$LESC")
[ "$SAME" = "1 2" ] && ok || bad "fixture: L1/L2/L3 must be ONE family and the escalation a second (got '$SAME')"

# ============================ c0 — the flag is absent ========================
# Byte-for-byte today: each lane does its job, and not one request reaches the
# jobs host.
flag_off
reset_triage; reset_medic
q "$H/state/alert-quarantine.jsonl" c0 "the c0 subsystem is unhappy #c0line"
fresh; lane alert-triage.sh
[ "$(ncalls)" = 1 ] && prompts | grep -q '#c0line' \
  && ok || bad "c0: triage must still buy its session with the flag off (calls=$(ncalls))"
[ "$(count 'jobs.invalid/api/alerts')" = 0 ] \
  && ok || bad "c0: triage made $(count 'jobs.invalid/api/alerts') jobs request(s) with the flag off"

groom_stub
console_pass1
fresh; medic_lane
[ "$(ncalls)" -ge 1 ] && ok || bad "c0: the medic must still dispatch with the flag off (calls=$(ncalls))"
[ "$(count 'jobs.invalid/api/alerts')" = 0 ] \
  && ok || bad "c0: the medic made $(count 'jobs.invalid/api/alerts') jobs request(s) with the flag off"

groom_real
cat > "$T/console.json" <<EOF
{"alerts":[{"id":"g-1","createdAt":"$(iso 3600)","akey":"beat:g","line":"[rebase-train] https://github.com/example-org/cromford/pull/1083 parked after 2 failed rounds (TK-1) #c4line"}]}
EOF
: > "$H/logs/alerts-groom.log"
fresh; lane alerts-groom.sh
[ "$(count 'POST https://console.invalid/api/alerts/resolve')" = 1 ] \
  && ok || bad "c0: groom must still resolve on the console with the flag off"
[ "$(count 'jobs.invalid/api/alerts')" = 0 ] \
  && ok || bad "c0: groom made $(count 'jobs.invalid/api/alerts') jobs request(s) with the flag off"

# ============ c1 — the hub triages a row from an unreachable box =============
# The box is gone (ssh 255). Today that alert is invisible to this lane until
# the box's own flush dead-man fires; with the table it is claimed and triaged
# from the hub. RED on main: no claim call, no prompt.
flag_on
reset_triage
cat > "$T/claim.json" <<EOF
{"alerts":[{"id":"lanedown-project-9-triage","family":"f1","box":"project-9","project":"","state":"quarantined","count":1,"first_seen":"$(iso 600)","last_seen":"$(iso 60)","claimed_by":"alert-triage@hub","claimed_at":"$(iso 0)","notified_at":"","severity":"critical","line":"LANE DOWN project-9 triage lane failed its canary #c1marker"}]}
EOF
fresh; SSH_MODE=down lane alert-triage.sh
[ "$(ncalls)" = 1 ] && ok || bad "c1: the claimed row must buy exactly one session (calls=$(ncalls))"
P=$(prompts)
grep -q '#c1marker' <<<"$P" && ok || bad "c1: the claimed row's line never reached the prompt"
grep -q '^project-9	' <<<"$P" && ok || bad "c1: the row must be rendered under its own box, not hub"
grep -q '"akey":"orclane:lanedown-project-9-triage"' <<<"$P" \
  && ok || bad "c1: the rendered payload must carry akey orclane:<id>"
grep -q '"dbrow":true' <<<"$P" && ok || bad "c1: the rendered payload must be marked dbrow:true"
CB=$(grep -m1 'POST https://jobs.invalid/api/alerts/claim' "$T/req.log" | sed 's/^[^ ]* [^ ]* //')
[ "$(jq -r '.lane' <<<"$CB" 2>/dev/null)" = "alert-triage" ] \
  && [ "$(jq -r '.state' <<<"$CB" 2>/dev/null)" = "quarantined" ] \
  && [ "$(jq -r '.min_age_s' <<<"$CB" 2>/dev/null)" = "0" ] \
  && [ "$(jq -r '.limit' <<<"$CB" 2>/dev/null)" = "200" ] \
  && ok || bad "c1: the claim body is wrong: $CB"
# The negative twin of c3's ids assertion. An `ids` key here is a FILTER on the
# worker, so a triage claim that carries one matches the rows whose id happens
# to be "0" or "200" — none — and answers empty on every tick forever.
[ "$(jq -r '.ids // "none"' <<<"$CB" 2>/dev/null)" = "none" ] \
  && ok || bad "c1: the triage claim must name no ids, it takes whatever the queue holds: $CB"
SB=$(grep -m1 'PATCH https://jobs.invalid/api/alerts/state' "$T/req.log" | sed 's/^[^ ]* [^ ]* //')
[ "$(jq -r '.id' <<<"$SB" 2>/dev/null)" = "lanedown-project-9-triage" ] \
  && [ "$(jq -r '.state' <<<"$SB" 2>/dev/null)" = "triaged" ] \
  && ok || bad "c1: the triaged PATCH is missing or wrong: $SB"
# write-after-buy: the PATCH's line in req.log must come AFTER the request count
# the agent-call stub recorded when it was handed the prompt.
RQC=$(cat "$T/calls/reqcount" 2>/dev/null || echo -1)
PLN=$(lineno 'PATCH https://jobs.invalid/api/alerts/state')
[ -n "$PLN" ] && [ "$RQC" -ge 0 ] && [ "$PLN" -gt "$RQC" ] \
  && ok || bad "c1: the triaged stamp must follow the session (patch line $PLN, requests at call time $RQC)"
grep -q 'triage claim: 1 row(s) claimed from the alerts table' "$H/logs/alert-triage.log" \
  && ok || bad "c1: the claim must be declared in the lane log"

# ====== c2 — a working claim leaves the box queues to the table ===========
# BH-2366 changed this half: with the claim at rc 0 the per-box ssh grab does
# not run at all, so neither box entry reaches a session from here and the box
# queue is left for that box's own alert-flush.sh (re-mark or 45m dead-man).
flag_off; flag_on
reset_triage
echo '{"alerts":[]}' > "$T/claim.json"
seed_remote() { : > "$T/remote/state/alert-quarantine.jsonl"
  q "$T/remote/state/alert-quarantine.jsonl" plain "plain box line #c2plain"
  q "$T/remote/state/alert-quarantine.jsonl" db "table owned line #c2db" ',"dbrow":true'; }
seed_remote
fresh; lane alert-triage.sh
P=$(prompts)
! grep -q '#c2plain' <<<"$P" && ok || bad "c2: with the claim ok the box entry must not be ssh-grabbed"
! grep -q '#c2db' <<<"$P" && ok || bad "c2: an ssh-served dbrow entry must NOT be triaged again"
[ "$(grep -c . "$T/remote/state/alert-quarantine.jsonl")" = 2 ] \
  && ok || bad "c2: the remote quarantine must be left untouched for its own flush"
grep -q 'triage collect: table claim ok, per-box ssh grab skipped' "$H/logs/alert-triage.log" \
  && ok || bad "c2: the skipped grab must be declared in the lane log"
# ...and when the table is unreachable the grab runs unfiltered, exactly as today
reset_triage
seed_remote
fresh; CURL_MODE=down lane alert-triage.sh
P=$(prompts)
grep -q '#c2plain' <<<"$P" && grep -q '#c2db' <<<"$P" \
  && ok || bad "c2: with the claim down BOTH entries must be triaged (fail open)"
grep -q 'triage claim rc=1' "$H/logs/alert-triage.log" \
  && ok || bad "c2: an unreachable table must be declared in the lane log"

# ==================== c3 — the medic claims before it buys ===================
groom_stub
medic_list
console_pass1
echo '{"families":[]}' > "$T/families.json"
claim_answers r-one
reset_medic
fresh; medic_lane
[ "$(ncalls)" = 1 ] && ok || bad "c3: only the claimed row may buy a session (calls=$(ncalls))"
P=$(prompts)
grep -qF "$L1" <<<"$P" && ok || bad "c3: the claimed row's line must be in the prompt"
! grep -qF "$L2" <<<"$P" && ok || bad "c3: an UNCLAIMED candidate must not ride along into the session"
! grep -qF "$L3" <<<"$P" && ok || bad "c3: the unclaimed DB row must not ride along into the session"
! grep -q '#c3esc' <<<"$P" && ok || bad "c3: a DB row twinning an escalation must never be investigated"
! grep -q '#c3claimed' <<<"$P" && ok || bad "c3: a row another lane already claimed is not a candidate"
grep -q 'GET https://jobs.invalid/api/alerts?state=new&older_than=1200&limit=200' "$T/req.log" \
  && ok || bad "c3: the medic must list unclaimed new rows older than 20 min (got: $(grep -o 'GET [^ ]*' "$T/req.log" | head -3))"
MB=$(grep -m1 'POST https://jobs.invalid/api/alerts/claim' "$T/req.log" | sed 's/^[^ ]* [^ ]* //')
[ "$(jq -r '.lane' <<<"$MB" 2>/dev/null)" = "medic" ] \
  && [ "$(jq -r '.state' <<<"$MB" 2>/dev/null)" = "new" ] \
  && [ "$(jq -r '.min_age_s' <<<"$MB" 2>/dev/null)" = "0" ] \
  && [ "$(jq -r '.limit' <<<"$MB" 2>/dev/null)" = "3" ] \
  && [ "$(jq -r '[.ids[]]|sort|join(",")' <<<"$MB" 2>/dev/null)" = "r-new,r-one,r-two" ] \
  && ok || bad "c3: the claim must name the ROW ids of every candidate it is about to buy: $MB"
[ "$(count '"state":"parked"')" = 0 ] \
  && ok || bad "c3: nothing may be parked before an escalation exists on the console"
grep -q 'medic claim: 1 of 3 candidate row(s) claimed' "$H/logs/medic.log" \
  && ok || bad "c3: the claim outcome must be declared (got: $(grep 'medic claim' "$H/logs/medic.log"))"

# --- c3b: the park is written through once the escalation is open ------------
console_parked
reset_medic
fresh; medic_lane
PARKED=$(grep -c '"state":"parked"' "$T/req.log" 2>/dev/null || true)
[ "$PARKED" -ge 2 ] && ok || bad "c3b: every id the park covers must be stamped parked (got $PARKED)"
grep -q '{"id":"r-one","state":"parked","actor":"medic"}' "$T/req.log" \
  && ok || bad "c3b: the park stamp must name the row id and the medic as actor"
grep -q '{"id":"r-two","state":"parked","actor":"medic"}' "$T/req.log" \
  && ok || bad "c3b: a console candidate must be stamped through the candidate->row map (c-two -> r-two)"
[ "$(ncalls)" = 0 ] && ok || bad "c3b: a fully parked family buys no session (calls=$(ncalls))"
python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); sys.exit(0 if sys.argv[2] in d and d[sys.argv[2]]["ids"] else 1)' \
  "$MS/medic-parked.json" "$FKEY" \
  && ok || bad "c3b: the park must still be recorded in medic-parked.json"

# --- c3c: the DB family brake stops the session ------------------------------
console_pass1
cat > "$T/families.json" <<EOF
{"families":[{"family":"$FKEY","last_claimed_at":"$(iso 600)","n":1}]}
EOF
claim_answers r-one r-two r-new
reset_medic
fresh; medic_lane
[ "$(ncalls)" = 0 ] \
  && ok || bad "c3c: a family another lane claimed inside 6h must buy nothing (calls=$(ncalls))"
grep -q 'medic skip' "$H/logs/medic.log" \
  && ok || bad "c3c: the skip must be declared (got: $(tail -2 "$H/logs/medic.log"))"
echo '{"families":[]}' > "$T/families.json"

# --- c3d: rc 0 with an EMPTY claim is a real answer, and it means no ----------
echo '{"alerts":[]}' > "$T/claim.json"
reset_medic
fresh; medic_lane
[ "$(ncalls)" = 0 ] && ok || bad "c3d: a claim that returned nothing must buy nothing (calls=$(ncalls))"
grep -q "medic claim: family $FKEY 0 of 3 rows claimed — no session" "$H/logs/medic.log" \
  && ok || bad "c3d: a family held elsewhere must say so (got: $(grep 'medic claim' "$H/logs/medic.log"))"

# --- c3e: the table unreachable — today's set, today's session ---------------
reset_medic
fresh; CURL_MODE=down medic_lane
[ "$(ncalls)" = 1 ] && ok || bad "c3e: with the table down the medic must still work today's queue (calls=$(ncalls))"
P=$(prompts)
grep -qF "$L1" <<<"$P" && grep -qF "$L2" <<<"$P" \
  && ok || bad "c3e: fail open means BOTH console candidates ride in the session"
grep -q 'medic claim rc=1' "$H/logs/medic.log" \
  && ok || bad "c3e: the unreachable table must be declared (got: $(grep 'medic' "$H/logs/medic.log" | tail -2))"

# ======================= c4 — the groomer closes the row =====================
# The settled row is a rebase-train park on a merged PR. (V1 alert hygiene: the
# groomer's PR rule settles only rows ABOUT a PR being open; the old fixture, a
# "build ... is stuck, see <PR>" line, is exactly the kind a merge must no longer
# close. This suite pins the console-then-table plumbing, not which lines settle.)
groom_real
GLINE="[rebase-train] https://github.com/example-org/cromford/pull/1083 parked after 2 failed rounds (TK-1) #c4line"
cat > "$T/console.json" <<EOF
{"alerts":[{"id":"g-1","createdAt":"$(iso 3600)","akey":"beat:g","line":"$GLINE"}]}
EOF
GKEY=$(HARNESS="$H" ALERTS_CONF="$H/flags/alerts.conf" bash -c '. "$1/bin/lib/alert-state.sh"; alert_state_key "$2"' _ "$DIR" "$GLINE")
[ -n "$GKEY" ] && ok || bad "c4: the test could not derive the row key the groom will send"
: > "$H/logs/alerts-groom.log"
fresh; lane alerts-groom.sh
CLN=$(lineno 'POST https://console.invalid/api/alerts/resolve')
JLN=$(lineno 'POST https://jobs.invalid/api/alerts/resolve')
[ -n "$CLN" ] && [ -n "$JLN" ] && [ "$JLN" -gt "$CLN" ] \
  && ok || bad "c4: the console resolve must happen first, then the table (console=$CLN jobs=$JLN)"
RB=$(grep -m1 'POST https://jobs.invalid/api/alerts/resolve' "$T/req.log" | sed 's/^[^ ]* [^ ]* //')
[ "$(jq -r '.ids[0]' <<<"$RB" 2>/dev/null)" = "$GKEY" ] \
  && ok || bad "c4: the resolve must carry the id alert_state_key derives from the line (wanted $GKEY, body $RB)"
grep -q 'resolved rows=1' "$H/logs/alerts-groom.log" \
  && ok || bad "c4: the groom must declare how many rows it closed"
# flag off: not one request
flag_off
: > "$H/logs/alerts-groom.log"
fresh; lane alerts-groom.sh
[ "$(count 'jobs.invalid/api/alerts')" = 0 ] \
  && ok || bad "c4: with the flag off the groom must not touch the table"
! grep -q 'resolved rows=' "$H/logs/alerts-groom.log" \
  && ok || bad "c4: with the flag off there is no rows= line to write"
# table unreachable: the console resolve still happened, and the log says so
flag_on
: > "$H/logs/alerts-groom.log"
fresh; CURL_MODE=down lane alerts-groom.sh; RC=$?
[ "$RC" -eq 0 ] && ok || bad "c4: an unreachable table must never fail the groom (rc=$RC)"
[ "$(count 'POST https://console.invalid/api/alerts/resolve')" = 1 ] \
  && ok || bad "c4: the console resolve must happen even when the table is down"
grep -q 'resolved rows=0 (alerts table rc=' "$H/logs/alerts-groom.log" \
  && ok || bad "c4: a failed table resolve must NOT be logged as rows resolved (got: $(cat "$H/logs/alerts-groom.log"))"

# ===================== c5 — the local write-through survives =================
# The files every other lane and the digest read are still written exactly as
# today: the table is a claim store, not a replacement for this lane's memory.
groom_stub
console_pass1
claim_answers r-one
reset_medic
fresh; medic_lane
[ -s "$H/state/alert-families.json" ] && ok || bad "c5: alert-families.json must survive the triage claim"
[ -s "$MS/medic-seen.txt" ] && ok || bad "c5: medic-seen.txt must still be written"
grep -q 'c-one' "$MS/medic-seen.txt" && ok || bad "c5: the dispatched id must still be marked seen"
python3 -c 'import json,sys; sys.exit(0 if json.load(open(sys.argv[1])) else 1)' "$MS/medic-families.json" \
  && ok || bad "c5: the dispatched family must still be stamped in medic-families.json"
[ -s "$MS/medic-parked.json" ] && ok || bad "c5: medic-parked.json must still be written"

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

echo "alerts-claims-bh-1071: pass=$PASS fail=$FAIL"
[ "$FAIL" -eq 0 ]
