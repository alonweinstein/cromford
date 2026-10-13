#!/bin/bash
# tests/responder-fix.bh-2548-test.sh — a condition the responder already knows
# the answer to is settled by a script, and the model runs only on the rest.
#
# WHY (BH-2548). The watchdog responder costs about $2.5 a call. Two of the
# conditions it is paid to look at have a fixed answer bash can already read off
# the evidence it fetched:
#   * evidence_missing — the board could not be read for an item. The decide
#     prompt forces "act" on it and the tooled pass is told to escalate it as
#     "evidence unavailable", so a MISSING item bought TWO calls for one beat;
#   * not_owed — the FETCHED ticket says waitingOn=client and no open PR matches
#     the key. It has left the stale-owed set since the snapshot, and the model
#     can only answer "healthy / none".
# Each is mapped by a settings row (RESPONDER_FIX_EVIDENCE_MISSING,
# RESPONDER_FIX_NOT_OWED) to `model`, `none` or a script in bin/responder-fix/.
#
# HOW IT DRIVES THE REAL THING: every section runs the shipped
# bin/watchdog-responder.sh, unedited, under HARNESS=<scratch>, as the project
# run `watchdog-responder.sh <project>` that cron's and bin/watchdog-poll.sh's
# no-argument dispatch starts once per fleet.conf project (BH-5942). curl (the board API), gh, agent-call.sh and
# beat.sh are stubbed; what they RECEIVE is the assertion. The fixtures are
# board and gh answers that the real prefetch turns into evidence, never
# hand-written evidence files.
# Run from anywhere: tests/responder-fix.bh-2548-test.sh   (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
# Inside SCRATCH: scratch_install_closure only installs into the scratch tree.
T=$(mktemp -d "$SCRATCH/responder-fix.XXXXXX") || exit 1
cleanup() {
  rm -rf "$T"
  command -v scratch_cleanup >/dev/null 2>&1 && scratch_cleanup >/dev/null 2>&1
  return 0
}
trap cleanup EXIT
DIR=$(cd "$(dirname "$0")/.." && pwd)
NOW=$(date +%s)
mkdir -p "$T/tmp"; export TMPDIR="$T/tmp"

SEC=0; SECNAME=""; SECFAIL=0; TOTALFAIL=0
_end() {
  [ "$SEC" = 0 ] && return 0
  [ "$SECFAIL" -eq 0 ] && echo "ok $SEC. $SECNAME"
  return 0
}
sec()  { _end; SEC="$1"; SECNAME="$2"; SECFAIL=0; }
ok()   { :; }
bad()  { SECFAIL=$((SECFAIL+1)); TOTALFAIL=$((TOTALFAIL+1)); echo "FAIL $SEC. $1"; }
has()   { grep -qF -- "$2" "$1" 2>/dev/null && ok || bad "$3"; }
hasnt() { grep -qF -- "$2" "$1" 2>/dev/null && bad "$3" || ok; }

H="$T/h"
. "$DIR/tests/lib/model-route-stub.sh" || exit 1; model_routes_fixture "$H" || exit 1
mkdir -p "$H/bin/lib" "$H/bin/responder-fix" "$H/logs" "$H/locks" "$H/env" "$H/flags" \
         "$H/state/responder" "$T/stub" "$T/calls" "$T/api"

# The two new sources, where the lane looks for them under HARNESS.
ln -sf "$DIR/bin/lib/responder-fix.sh" "$H/bin/lib/responder-fix.sh"
ln -sf "$DIR/bin/responder-fix/escalate-missing.sh" "$H/bin/responder-fix/escalate-missing.sh"
for s in fleet-conf.sh internal-token-for.sh board-fetch.sh box-for.sh; do
  ln -sf "$DIR/bin/$s" "$H/bin/$s"
done
ln -sf "$DIR/bin/lib/gh-budget.sh" "$H/bin/lib/gh-budget.sh"
# BH-5942: a project run sources the per-project runner seam and its runner.
( cd "$DIR" && scratch_install_closure bin/lib/llm-lane-project.sh "$H" ) >/dev/null || exit 1

printf 'PROJECT_1_INTERNAL_API_TOKEN=tok-m\n' > "$H/env/project-1.env"
: > "$H/env/global.env"
cat > "$H/fleet.conf" <<'CONF'
# scratch registry
project-1 example-org/project-1 https://project-1.invalid /api/board 2 local 127.0.0.1
noboard-os  -                     -                        -          9 local 127.0.0.1
CONF

# ---------- stubs ------------------------------------------------------------
printf '#!/bin/sh\nexit 0\n' > "$H/bin/stale-owed-tickets.sh"; chmod +x "$H/bin/stale-owed-tickets.sh"

cat > "$H/bin/agent-call.sh" <<'STUB'
#!/bin/bash
N=$(ls "$CALLDIR"/prompt-*.txt 2>/dev/null | wc -l | tr -d ' ')
printf 'call=%s notools=%s stage=%s project=%s\n' "$N" "${AGENT_CALL_NO_TOOLS:-unset}" "$1" "$2" >> "$CALLDIR/calls.log"
printf '%s' "$6" > "$CALLDIR/prompt-$N.txt"
printf '%b\n' "${STUB_DECISION:-}" > "$5"
exit 0
STUB
chmod +x "$H/bin/agent-call.sh"

# beat.sh: one line per call — the strict flag, then the payload verbatim.
cat > "$H/bin/beat.sh" <<'STUB'
#!/bin/bash
printf 'strict=%s %s\n' "${BEAT_STRICT:-unset}" "$1" >> "$CALLDIR/beat.log"
exit "${STUB_BEAT_RC:-0}"
STUB
chmod +x "$H/bin/beat.sh"

# curl: the project-1 board. /tickets/<id> is served from $T/api/<id>.json.
cat > "$T/stub/curl" <<STUBEOF
#!/bin/bash
OUTF=""; CODEW=0; URL=""
while [ \$# -gt 0 ]; do
  case "\$1" in
    -o) shift; OUTF="\${1:-}" ;;
    -w) shift; CODEW=1 ;;
    -H|-m|-A) shift ;;
    http*) URL="\$1" ;;
  esac
  shift
done
CODE=200; BODY=""
case "\$URL" in
  */boards)            BODY='[{"id":"b1","name":"Product"}]' ;;
  */boards/*/tickets)  BODY='[{"id":"t1","key":"TK-1"},{"id":"t2","key":"TK-2"}]' ;;
  */tickets/*)
    ID="\${URL##*/}"
    if [ -f "$T/api/\$ID.json" ]; then BODY=\$(cat "$T/api/\$ID.json"); else CODE=404; BODY="no such ticket"; fi ;;
  *) CODE=404; BODY="unknown url" ;;
esac
if [ -n "\$OUTF" ]; then printf '%s' "\$BODY" > "\$OUTF"; else printf '%s' "\$BODY"; fi
[ "\$CODEW" = 1 ] && printf '%s' "\$CODE"
exit 0
STUBEOF
chmod +x "$T/stub/curl"

# gh: TK-1 has one open PR (#12), every other key has none; GH_FAIL=1 fails.
cat > "$T/stub/gh" <<STUBEOF
#!/bin/bash
case "\$1 \${2:-}" in
  "api rate_limit")
    printf '{"resources":{"core":{"remaining":5000,"limit":5000,"reset":1},"graphql":{"remaining":5000,"limit":5000,"reset":1}}}'
    exit 0 ;;
  "auth token") echo "ghs_faketoken"; exit 0 ;;
esac
if [ "\${GH_FAIL:-0}" = 1 ]; then echo "gh: could not reach github" >&2; exit 1; fi
if [ "\$1" = pr ] && [ "\${2:-}" = list ]; then
  case " \$* " in
    *" TK-1 "*) echo '[{"number":12,"url":"https://github.com/example-org/project-1/pull/12","state":"OPEN","headRefName":"ticket/TK-1"}]'; exit 0 ;;
  esac
  echo '[]'; exit 0
fi
if [ "\$1" = pr ] && [ "\${2:-}" = view ]; then
  echo '{"state":"OPEN","mergeStateStatus":"BLOCKED","headRefOid":"abc123def4567890"}'; exit 0
fi
echo '[]'
STUBEOF
chmod +x "$T/stub/gh"

export PATH="$T/stub:$PATH"
export FLEET_CONF="$H/fleet.conf"
export CALLDIR="$T/calls"
export GH_TOKEN=ghs_faketoken

# mk_ticket <id> <key> <waitingOn> [title] [nocomments] — the board record.
mk_ticket() {
  local id="$1" key="$2" wo="$3" title="${4:-ticket $2 title}" nc="${5:-}"
  if [ "$nc" = nocomments ]; then
    jq -nc --arg id "$id" --arg k "$key" --arg t "$title" --arg wo "$wo" \
      '{id:$id,key:$k,title:$t,status:"review",waitingOn:$wo,triageVerdict:"ready"}' > "$T/api/$id.json"
    return 0
  fi
  jq -nc --arg id "$id" --arg k "$key" --arg t "$title" --arg wo "$wo" \
    '{id:$id,key:$k,title:$t,status:"review",waitingOn:$wo,triageVerdict:"ready",
      turnChangedAt:"2026-09-16T00:00:00Z",updatedAt:"2026-09-16T12:00:00Z",
      comments:[{id:"c1",createdAt:"2026-09-01T00:00:00Z",author:{name:"Ana"},body:("thread of " + $k)}]}' \
    > "$T/api/$id.json"
}

# seed <project:key>... — those keys persisted across two sweeps, none in
# cooldown, no wedged queue job unless WEDGE=1. Every key of one seed is in ONE
# project, and SEEDP names it: since BH-5942 a pass is one project's run (the
# wedged-only seed is project-1, the queue it writes). The previous snapshot
# is that project's own state/watchdog-responder/<project>/stale-history.json.
seed() {
  local pk p k snap='{}'
  rm -rf "$T/h/state/responder" "$T/h/state/watchdog-responder" "$T/h/state/build-queue" "$T/calls"
  mkdir -p "$H/state/responder" "$T/calls"
  SEEDP=project-1
  [ "$#" -gt 0 ] && SEEDP="${1%%:*}"
  : > "$H/logs/responder.log"
  for pk in "$@"; do
    p="${pk%%:*}"; k="${pk#*:}"
    snap=$(jq -c --arg p "$p" --arg k "$k" \
      '.[$p].tickets += [{key:$k,title:("snapshot " + $k),status:"review",waitingOn:"team",hours:30}]
       | .[$p].count = (.[$p].tickets | length)' <<< "$snap")
  done
  printf '%s' "$snap" > "$H/state/stale-owed.json"
  mkdir -p "$H/state/watchdog-responder/$SEEDP"
  jq -nc --argjson ts "$((NOW-6000))" --slurpfile cur "$H/state/stale-owed.json" \
    '{ts:$ts,snap:$cur[0]}' > "$H/state/watchdog-responder/$SEEDP/stale-history.json"
  echo '{}' > "$H/state/responder/handled.json"
  if [ "${WEDGE:-0}" = 1 ]; then
    mkdir -p "$H/state/build-queue/project-1"
    printf '{"key":"TK-9"}' > "$H/state/build-queue/project-1/x.json"
    touch -d "@$((NOW-3630))" "$H/state/build-queue/project-1/x.json"
  fi
  rm -f "$H/flags/responder-prefetch-off"
}

OUT="$T/out.txt"; RC=0
# run <VAR=VAL ...> -- — one pass of the SHIPPED script over the seeded state,
# as the seeded project's run.
run() {
  env HARNESS="$H" "$@" bash "$DIR/bin/watchdog-responder.sh" "$SEEDP" > "$OUT" 2>"$OUT.err"
  RC=$?
}
ncalls() { ls "$T/calls"/prompt-*.txt 2>/dev/null | wc -l | tr -d ' '; }
nbeats() { [ -f "$T/calls/beat.log" ] && wc -l < "$T/calls/beat.log" | tr -d ' ' || echo 0; }
stamped() { jq -r --arg k "$1" '.[$k] // 0' "$H/state/responder/handled.json" 2>/dev/null; }
LOGF="$H/logs/responder.log"

# =================== 1 — evidence_missing makes no model call ===============
sec 1 "a MISSING item is escalated by script, and agent-call is never invoked"
seed noboard-os:NB-1
run
[ "$RC" = 0 ] && ok || bad "the pass exited $RC (stderr: $(head -3 "$OUT.err"))"
[ "$(ncalls)" = 0 ] && ok || bad "agent-call was invoked on a known condition ($(ncalls) call(s))"
[ "$(nbeats)" = 1 ] && ok || bad "expected exactly one escalation beat, got $(nbeats)"
BL=$(sed -n 1p "$T/calls/beat.log" 2>/dev/null)
case "$BL" in strict=1\ *) ok ;; *) bad "the escalation beat was not sent BEAT_STRICT=1: $BL" ;; esac
BP="${BL#strict=* }"
[ "$(jq -r '.kind' <<< "$BP" 2>/dev/null)" = fleet_alert ] && ok || bad "the beat is not a fleet_alert: $BP"
[ "$(jq -r '.project' <<< "$BP" 2>/dev/null)" = noboard-os ] && ok || bad "the beat's project is not the item's: $BP"
case "$(jq -r '.akey' <<< "$BP" 2>/dev/null)" in responder:missing:noboard-os:*) ok ;; *) bad "the beat's akey is not responder:missing:<P>:…: $BP" ;; esac
case "$(jq -r '.line' <<< "$BP" 2>/dev/null)" in *noboard-os:NB-1*) ok ;; *) bad "the beat line does not name the item: $BP" ;; esac
case "$(jq -r '.line' <<< "$BP" 2>/dev/null)" in *"no board access for noboard-os"*) ok ;; *) bad "the beat line does not say why the evidence is missing: $BP" ;; esac
S=$(stamped noboard-os:NB-1)
[ "$S" -ge "$NOW" ] 2>/dev/null && ok || bad "the scripted item was not stamped handled (got '$S')"
has "$LOGF" 'noboard-os:NB-1 evidence_missing -> scripted:escalate-missing' "the scripted remedy is not journalled"
has "$LOGF" 'no model call this pass' "an all-scripted pass does not say it made no model call"

# =================== 2 — not_owed makes no model call =======================
sec 2 "waitingOn=client with no open PR is journalled and stamped, no call, no beat"
seed project-1:TK-2
mk_ticket t2 TK-2 client
run
[ "$(ncalls)" = 0 ] && ok || bad "agent-call was invoked on a not-owed item ($(ncalls) call(s))"
[ "$(nbeats)" = 0 ] && ok || bad "a not-owed item sent $(nbeats) beat(s)"
S=$(stamped project-1:TK-2)
[ "$S" -ge "$NOW" ] 2>/dev/null && ok || bad "the not-owed item was not stamped handled (got '$S')"
has "$LOGF" 'project-1:TK-2 not_owed -> scripted:none' "the not-owed item is not journalled"

# =================== 3 — an unknown item still reaches the model ============
sec 3 "a team-owed item with a readable thread gets today's decision call"
seed project-1:TK-2
mk_ticket t2 TK-2 team
run STUB_DECISION='DECISION: project-1:TK-2 :: healthy :: none :: fine'
[ "$(ncalls)" = 1 ] && ok || bad "an unknown item made $(ncalls) agent calls, expected the decision call"
has "$T/calls/calls.log" 'call=0 notools=1 stage=triage project=responder' "the model call is not today's no-tools decision call"
hasnt "$LOGF" 'scripted:' "an unknown item was handled by a script"

# =================== 4 — mixed pass: the model sees only the unknown ========
# Since BH-5942 a pass is one project's run, so the mix is two items of ONE
# project: TK-3 is not on the project-1 board (its evidence is MISSING) and TK-2
# is team-owed with a readable thread. A noboard-os item and a project-1 item
# are two runs now and never share a pass.
sec 4 "a mixed pass scripts the known item and sends only the unknown one to the model"
seed project-1:TK-3 project-1:TK-2
mk_ticket t2 TK-2 team
run STUB_DECISION='DECISION: project-1:TK-2 :: healthy :: none :: fine'
[ "$(ncalls)" = 1 ] && ok || bad "a mixed pass made $(ncalls) agent calls, expected 1"
has   "$T/calls/prompt-0.txt" 'project-1:TK-2' "the unknown item is not in the model's prompt"
hasnt "$T/calls/prompt-0.txt" 'TK-3' "the scripted item still reached the model's prompt"
[ "$(nbeats)" = 1 ] && ok || bad "the scripted item's beat was not sent in a mixed pass ($(nbeats))"
has "$LOGF" 'project-1:TK-3 evidence_missing -> scripted:escalate-missing' "the mixed pass did not journal the scripted item"
S=$(stamped project-1:TK-3); [ "$S" -ge "$NOW" ] 2>/dev/null && ok || bad "the scripted item was not stamped in a mixed pass"
hasnt "$LOGF" 'no model call this pass' "a mixed pass claims it made no model call"

# =================== 5 — the row switches a condition back to the model =====
sec 5 "RESPONDER_FIX_EVIDENCE_MISSING=model restores today's path"
seed noboard-os:NB-1
run RESPONDER_FIX_EVIDENCE_MISSING=model STUB_DECISION='DECISION: noboard-os:NB-1 :: f :: none :: x'
[ "$(ncalls)" -ge 1 ] && ok || bad "row 'model' did not route the item to agent-call"
[ "$(nbeats)" = 0 ] && ok || bad "row 'model' still sent the scripted beat"
has "$T/calls/prompt-0.txt" 'EVIDENCE MISSING for noboard-os:NB-1' "the model did not get the MISSING evidence"
seed project-1:TK-2
mk_ticket t2 TK-2 client
run RESPONDER_FIX_NOT_OWED=model STUB_DECISION='DECISION: project-1:TK-2 :: healthy :: none :: x'
[ "$(ncalls)" = 1 ] && ok || bad "RESPONDER_FIX_NOT_OWED=model did not route the not-owed item to agent-call"

# =================== 6 — junk rows fail open to the model ===================
sec 6 "a junk remedy row is logged and the item goes to the model"
for ROW in '../../bin/beat' 'nonexistent' 'Escalate Missing'; do
  seed noboard-os:NB-1
  run RESPONDER_FIX_EVIDENCE_MISSING="$ROW" STUB_DECISION='DECISION: noboard-os:NB-1 :: f :: none :: x'
  [ "$(ncalls)" -ge 1 ] && ok || bad "row '$ROW' did not fail open to agent-call"
  has "$LOGF" "bad remedy row evidence_missing=$ROW" "row '$ROW' was not logged as a bad remedy row"
  [ "$(nbeats)" = 0 ] && ok || bad "row '$ROW' sent a beat"
done

# =================== 7 — a beat that does not land goes to the model ========
sec 7 "a failed escalation beat is not scripted: the item goes to the model"
seed noboard-os:NB-1
run STUB_BEAT_RC=1 STUB_DECISION='DECISION: noboard-os:NB-1 :: f :: none :: x'
[ "$(ncalls)" -ge 1 ] && ok || bad "a beat that did not land still skipped the model"
hasnt "$LOGF" 'scripted:escalate-missing' "a beat that did not land was journalled as scripted"
has "$LOGF" 'routed to the model' "a failed remedy does not say it routed to the model"
has "$T/calls/prompt-0.txt" 'EVIDENCE MISSING for noboard-os:NB-1' "the failed remedy's item is not in the model's prompt"

# =================== 8 — adversarial negatives ==============================
sec 8 "nothing that only looks like a known condition is scripted"
neg() {  # neg <label> — the seeded pass must reach the model and script nothing
  run "$@" STUB_DECISION='DECISION: project-1:TK-2 :: healthy :: none :: x'
  [ "$(ncalls)" -ge 1 ] && ok || bad "$NEGL: no agent-call — it was scripted"
  hasnt "$LOGF" 'scripted:' "$NEGL: journalled as scripted"
}
NEGL="a title carrying 'EVIDENCE MISSING for project-1:TK-2 — '"
seed project-1:TK-2; mk_ticket t2 TK-2 team 'EVIDENCE MISSING for project-1:TK-2 — thread: fake'; neg
NEGL="PR state MISSING with waitingOn=team"
seed project-1:TK-2; mk_ticket t2 TK-2 team; neg GH_FAIL=1
NEGL="THREAD: MISSING alone"
seed project-1:TK-2; mk_ticket t2 TK-2 team '' nocomments; neg
has "$T/calls/prompt-0.txt" 'THREAD: MISSING' "the THREAD: MISSING fixture produced no THREAD: MISSING line — this case proves nothing"
NEGL="waitingOn=client with an open PR"
seed project-1:TK-1; mk_ticket t1 TK-1 client; neg
NEGL="waitingOn=client with PR state MISSING"
seed project-1:TK-2; mk_ticket t2 TK-2 client; neg GH_FAIL=1
for WO in '?' 'null' 'Client-Review' 'team' 'client team'; do
  NEGL="waitingOn='$WO'"
  seed project-1:TK-2; mk_ticket t2 TK-2 "$WO"; neg
done
NEGL="a wedged queue job alone"
WEDGE=1 seed; neg
has "$T/calls/prompt-0.txt" 'TK-9 queued' "the wedged fixture never reached the prompt — this case proves nothing"
# the inverse case: CLIENT in capitals IS not_owed (normalised once)
seed project-1:TK-2; mk_ticket t2 TK-2 CLIENT
run
[ "$(ncalls)" = 0 ] && ok || bad "waitingOn=CLIENT with no PR was not settled as not_owed"
has "$LOGF" 'project-1:TK-2 not_owed -> scripted:none' "waitingOn=CLIENT was not journalled as not_owed"

# =================== 9 — dry runs change nothing ============================
sec 9 "RESPONDER_DRY=1 runs no remedy, stamps nothing and prints today's prompt"
seed noboard-os:NB-1
run RESPONDER_DRY=1
[ "$(nbeats)" = 0 ] && ok || bad "a dry run sent a beat"
[ "$(cat "$H/state/responder/handled.json")" = '{}' ] && ok || bad "a dry run stamped handled.json"
has "$OUT" 'EVIDENCE MISSING for noboard-os:NB-1' "the dry prompt lost the MISSING item"
has "$LOGF" 'would run' "a dry run does not say what it would have run"

# =================== 10 — the prefetch kill switch is today's path ==========
sec 10 "flags/responder-prefetch-off keeps today's single tooled call"
seed noboard-os:NB-1; touch "$H/flags/responder-prefetch-off"
run
[ "$(ncalls)" = 1 ] && ok || bad "with the prefetch off the pass made $(ncalls) calls, expected today's 1"
has "$T/calls/calls.log" 'call=0 notools=unset' "the prefetch-off call is not today's tooled call"
[ "$(nbeats)" = 0 ] && ok || bad "the prefetch-off path ran a scripted remedy"
rm -f "$H/flags/responder-prefetch-off"

# =================== 11 — the new sources parse ============================
sec 11 "the two new sources exist and parse"
for f in "$DIR/bin/lib/responder-fix.sh" "$DIR/bin/responder-fix/escalate-missing.sh"; do
  [ -f "$f" ] && ok || bad "$f does not exist"
  bash -n "$f" 2>/dev/null && ok || bad "$f does not parse"
done
[ -x "$DIR/bin/responder-fix/escalate-missing.sh" ] && ok || bad "escalate-missing.sh is not executable"

# =================== 12 — the rows are registered ===========================
sec 12 "both remedy rows are registered knobs with the shipped defaults"
REGF="$DIR/catalog/lanes.d/watchdog-responder.json"
[ "$(jq -r '.knobs[] | select(.env=="RESPONDER_FIX_EVIDENCE_MISSING") | .default' "$REGF")" = escalate-missing ] \
  && ok || bad "RESPONDER_FIX_EVIDENCE_MISSING is not registered with default escalate-missing"
[ "$(jq -r '.knobs[] | select(.env=="RESPONDER_FIX_NOT_OWED") | .default' "$REGF")" = none ] \
  && ok || bad "RESPONDER_FIX_NOT_OWED is not registered with default none"
[ "$(jq -r '[.knobs[] | select(.env|startswith("RESPONDER_FIX_")) | .read_in] | unique | join(",")' "$REGF")" = bin/lib/responder-fix.sh ] \
  && ok || bad "the remedy rows do not name bin/lib/responder-fix.sh as their reader"

_end
echo "responder-fix.bh-2548-test: $TOTALFAIL failed assertion(s)"
[ "$TOTALFAIL" -eq 0 ]
