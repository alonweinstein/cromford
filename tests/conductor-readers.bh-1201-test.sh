#!/bin/bash
# tests/conductor-readers.bh-1201-test.sh — BH-1201.2: the two lanes that READ
# alert lines stand still on the conductor's own lines while the conductor is
# paused, and do exactly what they do today when it is not.
#
# Runs the REAL bin/alert-triage.sh and bin/alerts-medic.sh end to end (only the
# harness ROOT is rewritten, the CI precedent from tests/alerts-claims.bh-1071).
# What is stubbed is what would leave the machine or spend money — curl, ssh,
# agent-call.sh. The assertions are on what the lanes LEFT BEHIND: the deferral
# spool, state/alert-families.json, the recorded requests, medic-seen.txt and
# the lane logs. Never on script text.
#
# WHAT IS AT STAKE. A held line must be HELD, not dropped: the whole point of
# standing still is that the alert is still there when the conductor finishes.
# Four failure shapes this file exists to catch:
#   * a conductor line buying a session while the conductor owns that PR (1a) —
#     two lanes writing to the same pull request is the incident;
#   * a held line being stamped into alert-families.json or claimed in the
#     alerts table (1a, 3a) — a stamp that outruns the work means the alert is
#     marked handled and never handled;
#   * the hold reading a FLAG FILE instead of the D1 settings row (1b) — a
#     box-local file would let two boxes disagree with nothing saying so;
#   * a held line being DROPPED rather than re-offered (1e) — it must come back
#     next tick and, past the age ceiling, retire on STEP 0's audited path.
#
# Run from anywhere: tests/conductor-readers.bh-1201-test.sh   (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
. "$(dirname "$0")/lib/triage-tick.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

# The box's own knobs do not get a vote (as in tests/triage-noise-budget.bh-1168-test.sh):
# the hub's env/global.env sets TRIAGE_MAX_FAMILIES=0 as the operator's pause,
# which made every triage case read STOPPED when this suite ran on a box.
unset TRIAGE_MAX_FAMILIES LANE_USD_CAP_ALERT_TRIAGE LANE_NOISE_CAP_ALERT_TRIAGE \
      LANE_BYTES_CAP_ALERT_TRIAGE TRIAGE_CONDUCTOR_HOLD MEDIC_CONDUCTOR_HOLD

# ONE clock read for the whole file; every fixture age is derived from it.
NOW=$(date -u +%s)
iso() { date -u -d "@$(( NOW - ${1:-0} ))" '+%Y-%m-%dT%H:%M:%SZ'; }

H="$T/h"
. "$DIR/tests/lib/model-route-stub.sh" || exit 1; model_routes_fixture "$H" || exit 1  # BH-1510.2: lanes read models from model_routes
mkdir -p "$H/bin/lib/jobs" "$H/logs" "$H/state" "$H/locks" "$H/env" "$H/flags" \
         "$H/catalog" "$T/fakebin" "$T/calls" "$T/remote/state"

printf 'CONSOLE_URL=https://console.invalid\nJOBS_URL=https://jobs.invalid\nHARNESS_SECRET=testsecret\nJOBS_RETRIES=0\n' \
  > "$H/env/global.env"

# --- the scripts under test, with only their harness root repointed ----------
for s in alert-triage.sh alerts-medic.sh; do
  sed "s|/root/harness|$H|g" "$DIR/bin/$s" > "$H/bin/$s"; chmod +x "$H/bin/$s"
done
printf '#!/bin/sh\nexit 0\n' > "$H/bin/alerts-groom.sh"; chmod +x "$H/bin/alerts-groom.sh"

# The real libraries, exactly as tests/alerts-claims.bh-1071-test.sh links them:
# jobs-client.sh is a shim whose modules resolve off BASH_SOURCE, so bin/lib/jobs
# is copied next to the symlink or the client refuses to half-load.
for s in jobs-client.sh triage-map.sh fleet-conf.sh box-for.sh project-of.sh alert_family.py \
         triage-spool-retire.sh gh-pr-state.sh; do
  [ -e "$DIR/bin/$s" ] && ln -sf "$DIR/bin/$s" "$H/bin/$s"
done
cp "$DIR"/bin/lib/jobs/*.sh "$H/bin/lib/jobs/"
for l in alert-state.sh env-path.sh lane-gate.sh conductor-mode.sh lane-caps.sh llm-gate.sh \
         lanes-registry.sh; do
  [ -e "$DIR/bin/lib/$l" ] && ln -sf "$DIR/bin/lib/$l" "$H/bin/lib/$l"
done
export FLEET_CONF="$DIR/fleet.conf"
printf '#!/bin/sh\nexit 0\n' > "$H/bin/fleet-projects-or-alert.sh"; chmod +x "$H/bin/fleet-projects-or-alert.sh"
printf '#!/usr/bin/env python3\n' > "$H/bin/alerts-supersede.py"
triage_tick_setup "$H" || exit 1
# BH-5942: project "fleet" is not in fleet.conf, so the home project's run owns
# these lines; its spool and brake files live here.
HP="$H/state/alert-triage/cromford"

# THE REAL REGISTRY, composed into the scratch tree. The knob defaults the hold
# resolves through (TRIAGE_CONDUCTOR_HOLD / MEDIC_CONDUCTOR_HOLD, default 1) are
# catalog/lanes.d's, so registering them is part of what these cases prove.
bash "$DIR/bin/lanes-build.sh" --to "$H/catalog/lanes.json" >/dev/null 2>&1 \
  || { echo "FAIL: could not compose the lane registry"; exit 1; }

# --- stubs -------------------------------------------------------------------
# curl: records "METHOD URL BODY" and answers per host. MODE_ROW is the value of
# the merge-conductor.mode settings row (empty = no row at all) and KNOB_ROW the
# value of lane.<id>.<knob>, so a case can move the worker's answer.
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
      "GET "*/api/settings)
          ROWS="[]"
          [ -n "${MODE_ROW:-}" ] && ROWS=$(printf '[{"key":"merge-conductor.mode","value":"%s"}]' "$MODE_ROW")
          [ -n "${KNOB_ROW:-}" ] && ROWS=$(printf '%s' "$ROWS" | jq -c --arg k "${KNOB_KEY:-lane.alert-triage.triage_conductor_hold}" --arg v "$KNOB_ROW" '. + [{key:$k,value:$v}]')
          printf '{"settings":%s}\n200\n' "$ROWS" ;;
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

# ssh: the fleet's other boxes have nothing to give in this file.
printf '#!/bin/sh\nexit 255\n' > "$T/fakebin/ssh"; chmod +x "$T/fakebin/ssh"
printf '#!/bin/sh\necho MERGED\n' > "$T/fakebin/gh"; chmod +x "$T/fakebin/gh"
printf '#!/bin/sh\nexit 0\n' > "$T/fakebin/flock"; chmod +x "$T/fakebin/flock"
printf '#!/bin/sh\nshift\nexec "$@"\n' > "$T/fakebin/timeout"; chmod +x "$T/fakebin/timeout"

# agent-call.sh: records the prompt it was handed. Its COUNT is what proves a
# held line bought nothing.
cat > "$H/bin/agent-call.sh" <<'CALLEOF'
#!/bin/bash
N=$(ls "$CALLDIR"/prompt-*.txt 2>/dev/null | wc -l | tr -d ' ')
printf '%s' "$6" > "$CALLDIR/prompt-$N.txt"
echo "handled=1 escalated=0 noise=0" > "$5"
CALLEOF
chmod +x "$H/bin/agent-call.sh"

# --- harness -----------------------------------------------------------------
fresh() { rm -rf "$T/calls"; mkdir -p "$T/calls"; : > "$T/req.log"
          # A mode flip must be SEEN, and the lane-gate settings cache holds for
          # 60s — so the cache and its miss marker go between cases.
          rm -f "$H/state/settings-cache.json" "$H/state/lane-gate/.settings-miss"; }
lane() { # lane <script> — run one lane exactly as cron does
  # `env`, not a bare assignment prefix: a prefix is parsed before $EXTRA_ENV
  # expands, so `${EXTRA_ENV:-}` there becomes the COMMAND NAME and the lane
  # never runs at all — silently, with an empty log that reads like a pass.
  env CALLDIR="$T/calls" REQ_SINK="$T/req.log" PATH="$T/fakebin:$PATH" \
    CURL_MODE="${CURL_MODE:-ok}" MODE_ROW="${MODE_ROW:-}" KNOB_ROW="${KNOB_ROW:-}" \
    KNOB_KEY="${KNOB_KEY:-lane.alert-triage.triage_conductor_hold}" \
    LANE_REGISTRY="$H/catalog/lanes.json" \
    ${EXTRA_ENV:-} \
    bash "$H/bin/$1" >/dev/null 2>&1
}
ncalls()  { ls "$T/calls"/prompt-*.txt 2>/dev/null | wc -l | tr -d ' '; }
prompts() { cat "$T/calls"/prompt-*.txt 2>/dev/null; }
spool()   { cat "$HP/deferred.tsv" 2>/dev/null; }
# tlane — one alert-triage tick (BH-5942: the dispatch, then each project's run),
# with the same environment lane() gives a lane.
tlane() {
  ( export CALLDIR="$T/calls" REQ_SINK="$T/req.log" PATH="$T/fakebin:$PATH" \
      CURL_MODE="${CURL_MODE:-ok}" MODE_ROW="${MODE_ROW:-}" KNOB_ROW="${KNOB_ROW:-}" \
      KNOB_KEY="${KNOB_KEY:-lane.alert-triage.triage_conductor_hold}" \
      LANE_REGISTRY="$H/catalog/lanes.json"
    [ -n "${EXTRA_ENV:-}" ] && export ${EXTRA_ENV}
    triage_tick "$H/bin/alert-triage.sh" >/dev/null 2>&1 )
}

reset_triage() { triage_tick_reset "$H"; : > "$H/logs/alert-triage.log"; echo '{}' > "$H/state/alert-families.json"
                 : > "$H/state/alert-triage-deferred.tsv"; : > "$H/state/alert-quarantine.jsonl"
                 rm -f "$H"/state/alert-triage-expired-*.tsv "$H"/flags/alerted-spoolretire-* ; }
# BH-5942: the medic runs per project. These rows carry no project, so they are
# the cromford run's, with its state in state/alerts-medic/cromford/.
( cd "$DIR" && scratch_install_closure bin/lib/llm-lane-project.sh "$H" ) >/dev/null || exit 1
MS="$H/state/alerts-medic/cromford"
reset_medic()  { : > "$H/logs/medic.log"; : > "$H/logs/ALERTS.log"
                 echo '{}' > "$H/state/medic-families.json"; echo '{}' > "$H/state/medic-parked.json"
                 : > "$H/state/medic-seen.txt"; scratch_rm "$MS"; }
medic_lane() { # medic_lane — lane() for the medic's cromford run
  env CALLDIR="$T/calls" REQ_SINK="$T/req.log" PATH="$T/fakebin:$PATH" \
    CURL_MODE="${CURL_MODE:-ok}" MODE_ROW="${MODE_ROW:-}" KNOB_ROW="${KNOB_ROW:-}" \
    KNOB_KEY="${KNOB_KEY:-lane.alert-triage.triage_conductor_hold}" \
    LANE_REGISTRY="$H/catalog/lanes.json" \
    ${EXTRA_ENV:-} \
    bash "$H/bin/alerts-medic.sh" cromford >/dev/null 2>&1
}

# quarantine line in the real on-disk shape (epoch<TAB>beat-json)
q() { # q <file> <akey> <line> [age-seconds]
  printf '%s\t{"kind":"fleet_alert","project":"fleet","akey":"orclane:%s","line":%s}\n' \
    "$(( NOW - ${4:-300} ))" "$2" "$(jq -Rn --arg l "$3" '$l')" >> "$1"; }

echo '{"families":[]}' > "$T/families.json"
echo '{"alerts":[]}'   > "$T/claim.json"
echo '{"alerts":[]}'   > "$T/list.json"
echo '{"alerts":[]}'   > "$T/console.json"

COND="[orchestrator/merge-conductor] conductor: example-org/project-5#11 STUCK — 95m in WAIT_CI"
OTHER="[pipeline-health] the alpha subsystem is unhappy: 3 builds stuck"

# family() of a line, through the SAME implementation the lanes use.
fam() { PYTHONPATH="$DIR/bin" python3 -c 'import sys
from alert_family import family
print(family(sys.argv[1]))' "$1"; }
CONDFAM=$(fam "$COND")
has_fam() { python3 -c 'import json,sys
d=json.load(open(sys.argv[1]))
sys.exit(0 if sys.argv[2] in d else 1)' "$1" "$2"; }

# ============ 1a — kill-switch: the conductor line is held ===================
echo "== 1a: kill-switch holds the conductor line =="
reset_triage
q "$H/state/alert-quarantine.jsonl" c1 "$COND"
q "$H/state/alert-quarantine.jsonl" o1 "$OTHER"
fresh; MODE_ROW=kill-switch tlane
grep -qF 'merge-conductor' <<<"$(spool)" \
  && ok || bad "1a: the conductor line must be back in the deferral spool (spool: $(spool))"
! grep -qF 'pipeline-health' <<<"$(spool)" \
  && ok || bad "1a: the non-conductor line must NOT have been spooled"
[ "$(ncalls)" = 1 ] && ok || bad "1a: exactly one session, for the other family (calls=$(ncalls))"
! grep -qF 'merge-conductor' <<<"$(prompts)" \
  && ok || bad "1a: the held line reached a session prompt"
! has_fam "$HP/alert-families.json" "$CONDFAM" \
  && ok || bad "1a: the held line was STAMPED in alert-families.json ($CONDFAM)"
grep -q 'held 1 conductor line(s): conductor paused (mode=kill-switch)' "$H/logs/alert-triage.log" \
  && ok || bad "1a: the hold must be declared (log: $(cat "$H/logs/alert-triage.log"))"

# ============ 1b — files are NOT consulted ===================================
# The source of truth is the D1 settings row. flags/automerge-disabled is what a
# box-local reading of "is the conductor paused" would have looked at.
echo "== 1b: a flag file never holds =="
reset_triage
touch "$H/flags/automerge-disabled" "$H/flags/conductor-owns-merges"
q "$H/state/alert-quarantine.jsonl" c1 "$COND"
q "$H/state/alert-quarantine.jsonl" o1 "$OTHER"
fresh; MODE_ROW=merge tlane
[ "$(ncalls)" = 2 ] && ok || bad "1b: with mode=merge both families must be sessioned (calls=$(ncalls))"
[ ! -s "$HP/deferred.tsv" ] \
  && ok || bad "1b: nothing may be spooled when the conductor is not paused (spool: $(spool))"
! grep -q 'conductor paused' "$H/logs/alert-triage.log" \
  && ok || bad "1b: a 'held' line was written on the go path"
rm -f "$H/flags/automerge-disabled" "$H/flags/conductor-owns-merges"

# ============ 1c — the lane knob at 0 is the opt-out ========================
echo "== 1c: knob 0 wins over kill-switch =="
reset_triage
q "$H/state/alert-quarantine.jsonl" c1 "$COND"
q "$H/state/alert-quarantine.jsonl" o1 "$OTHER"
fresh; MODE_ROW=kill-switch KNOB_ROW=0 tlane
[ "$(ncalls)" = 2 ] && ok || bad "1c: the knob opt-out must let both through (calls=$(ncalls))"
[ ! -s "$HP/deferred.tsv" ] \
  && ok || bad "1c: nothing may be spooled with the knob at 0 (spool: $(spool))"

# ============ 1d — the worker is down: unknown, and unknown holds ============
echo "== 1d: worker down holds (fail closed on spend) =="
reset_triage
q "$H/state/alert-quarantine.jsonl" c1 "$COND"
q "$H/state/alert-quarantine.jsonl" o1 "$OTHER"
fresh; CURL_MODE=down tlane
grep -qF 'merge-conductor' <<<"$(spool)" \
  && ok || bad "1d: an unreachable worker must HOLD the conductor line (spool: $(spool))"
[ "$(ncalls)" = 1 ] && ok || bad "1d: only the other family may buy a session (calls=$(ncalls))"
grep -q 'held 1 conductor line(s): conductor paused (mode=unknown)' "$H/logs/alert-triage.log" \
  && ok || bad "1d: the log must name mode=unknown (log: $(cat "$H/logs/alert-triage.log"))"

# ============ 1e — re-offered next tick, retired on the audited path =========
echo "== 1e: held twice, never dropped, retired at the ceiling =="
reset_triage
q "$H/state/alert-quarantine.jsonl" c1 "$COND"
fresh; MODE_ROW=kill-switch tlane
grep -qF 'merge-conductor' <<<"$(spool)" && ok || bad "1e: first tick did not hold the line"
[ "$(ncalls)" = 0 ] && ok || bad "1e: a tick of nothing but conductor lines must buy no session (calls=$(ncalls))"
fresh; MODE_ROW=kill-switch tlane
grep -qF 'merge-conductor' <<<"$(spool)" \
  && ok || bad "1e: the held line was DROPPED on the second tick (spool: $(spool))"
[ "$(wc -l < "$HP/deferred.tsv")" = 1 ] \
  && ok || bad "1e: the spool must hold exactly one copy (got $(wc -l < "$HP/deferred.tsv"))"
# Past its ceiling STEP 0 archives it WITH A REASON, before the hold sees it —
# so a pause that outlives the spool ends in the audit file, never in a silent
# drop. Which reason is STEP 0's business: this fixture line is a per-PR budget
# note, so rule 1 retires it as EXPIRED-CONDSTATE at 6h rather than waiting for
# EXPIRED-AGE at 24h. The assertion is that it is archived with one of them.
fresh; MODE_ROW=kill-switch EXTRA_ENV="TRIAGE_NOW=$(( NOW + 25*3600 ))" tlane
EXP=$(cat "$H"/state/alert-triage-expired-*.tsv 2>/dev/null)
grep -qE 'EXPIRED-[A-Z]+' <<<"$EXP" && grep -qF 'merge-conductor' <<<"$EXP" \
  && ok || bad "1e: the aged line must retire on STEP 0's audited path (expired: $EXP)"
[ ! -s "$HP/deferred.tsv" ] \
  && ok || bad "1e: a retired line must leave the spool (spool: $(spool))"

# ============ 2 — the adversarial negatives ==================================
# Everything here NAMES the conductor without being one of its lines, plus two
# malformed beats. Under kill-switch not one of them may be held.
echo "== 2: negatives are never held =="
reset_triage
Q="$H/state/alert-quarantine.jsonl"
q "$Q" n1 "[merge-conductor-x] a lane whose tag merely starts the same way"
q "$Q" n2 "[pipeline-health] the merge-conductor lane is 40m stale"
q "$Q" n3 "[orchestrator/merge-sweep] the sweep found nothing to land"
q "$Q" n4 "[blocked-resolver] ladder round 2 for cromford BH-9"
q "$Q" n5 ""
printf '%s\tnot json at all\n' "$(( NOW - 300 ))" >> "$Q"
fresh; MODE_ROW=kill-switch EXTRA_ENV="TRIAGE_MAX_FAMILIES=20" tlane
[ ! -s "$HP/deferred.tsv" ] \
  && ok || bad "2: a negative was held (spool: $(spool))"
! grep -q 'conductor paused' "$H/logs/alert-triage.log" \
  && ok || bad "2: a 'held' line was written with nothing to hold"
[ "$(ncalls)" -ge 4 ] \
  && ok || bad "2: every parseable negative must still reach a session (calls=$(ncalls))"

# ============ 3a — the medic leaves a conductor row unclaimed ================
echo "== 3a: the medic holds a conductor row =="
touch "$H/flags/alerts-db"
MEDCOND="[orchestrator/merge-conductor] conductor: example-org/project-3#7 BUDGET — 3 rounds"
MEDOTHER="the alpha subsystem is unhappy: 11 builds stuck"
cat > "$T/console.json" <<EOF
{"alerts":[
{"id":"alert-cond","createdAt":"$(iso 3600)","akey":"beat:cond","line":$(jq -Rn --arg l "$MEDCOND" '$l')},
{"id":"alert-other","createdAt":"$(iso 3600)","akey":"beat:other","line":$(jq -Rn --arg l "$MEDOTHER" '$l')}]}
EOF
echo '{"alerts":[]}' > "$T/list.json"
MEDFAM=$(fam "$MEDCOND")
# The medic claims a console candidate under the row id every producer derives
# from its LINE (bin/lib/alert-state.sh), not under the console id — so that is
# the string the "never claimed" assertion has to look for.
skey() { HARNESS="$H" ALERTS_CONF="$H/flags/alerts.conf" \
         bash -c '. "$1/bin/lib/alert-state.sh"; alert_state_key "$2"' _ "$DIR" "$1"; }
CONDKEY=$(skey "$MEDCOND"); OTHERKEY=$(skey "$MEDOTHER")
[ -n "$CONDKEY" ] && [ -n "$OTHERKEY" ] && [ "$CONDKEY" != "$OTHERKEY" ] \
  && ok || bad "3a fixture: could not derive the two row keys ('$CONDKEY' / '$OTHERKEY')"
# The table grants whatever it is asked for: what the claim BODY names is the
# assertion, not what the stub hands back.
row() { printf '{"id":"%s","family":"f","box":"hub","project":"","state":"new","count":1,"first_seen":"%s","last_seen":"%s","claimed_by":"medic@hub","claimed_at":"","notified_at":"","severity":"warn","line":"x"}' \
          "$1" "$(iso 3600)" "$(iso 600)"; }
{ echo '{"alerts":['; row "$CONDKEY"; echo ','; row "$OTHERKEY"; echo ']}'; } > "$T/claim.json"
reset_medic
fresh; MODE_ROW=kill-switch KNOB_KEY=lane.alerts-medic.medic_conductor_hold medic_lane
[ "$(ncalls)" = 1 ] && ok || bad "3a: only the non-conductor family may buy a session (calls=$(ncalls))"
! grep -qF 'merge-conductor' <<<"$(prompts)" \
  && ok || bad "3a: the held row reached a session prompt"
! has_fam "$MS/medic-families.json" "$MEDFAM" \
  && ok || bad "3a: the held row was stamped in medic-families.json ($MEDFAM)"
CB=$(grep 'POST https://jobs.invalid/api/alerts/claim' "$T/req.log" 2>/dev/null)
[ -n "$CB" ] && ! grep -qF "$CONDKEY" <<<"$CB" \
  && ok || bad "3a: the held row was CLAIMED (key $CONDKEY): $CB"
grep -qF "$OTHERKEY" <<<"$CB" \
  && ok || bad "3a: the OTHER row must still be claimed, or this case proves nothing: $CB"
! grep -q 'alert-cond' "$MS/medic-seen.txt" \
  && ok || bad "3a: the held row was marked seen, so it can never be re-offered"
grep -q 'held 1 conductor alert(s): conductor paused (mode=kill-switch)' "$H/logs/medic.log" \
  && ok || bad "3a: the hold must be declared (log: $(cat "$H/logs/medic.log"))"

# ============ 3b — and consumes it once the conductor is done ===============
echo "== 3b: mode=merge consumes the row =="
reset_medic
fresh; MODE_ROW=merge KNOB_KEY=lane.alerts-medic.medic_conductor_hold medic_lane
[ "$(ncalls)" = 2 ] && ok || bad "3b: both families must be sessioned once the conductor runs (calls=$(ncalls))"
grep -qF 'merge-conductor' <<<"$(prompts)" \
  && ok || bad "3b: the conductor row must reach a session on the go path"
grep -q 'alert-cond' "$MS/medic-seen.txt" \
  && ok || bad "3b: the dispatched row must be marked seen"
! grep -q 'conductor paused' "$H/logs/medic.log" \
  && ok || bad "3b: a 'held' line was written on the go path"
rm -f "$H/flags/alerts-db"

echo "conductor-readers-bh-1201: pass=$PASS fail=$FAIL"
[ "$FAIL" -eq 0 ]
