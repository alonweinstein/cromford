#!/bin/bash
# tests/alert-loop-test.sh — the alert lanes must not generate their own work.
#
# THE INCIDENT THIS PINS (2026-08-31, overnight). Nothing was broken in a way any
# lane could see. Eight genuinely unfixable conditions produced a night of pages
# and ~20-25 LLM sessions/day at 2-4M input tokens each, because three separate
# mechanisms each turned one problem into an endless stream:
#
#   1. The medic escalated a family it could not fix. The escalation is a beat,
#      so it became an open console row. 20 minutes later that row was a fresh
#      unseen alert in the medic's OWN queue. Its family is hashed from the
#      escalation's prose — LLM-written, different every pass — so it presented
#      as a brand-new family, sailed past the 6h brake, and bought a full session
#      to re-verify the lane's own words. Then escalated again. Observed: one
#      project-2 condition wearing two family keys (bb1c4472dc0a, 2370fcfa03a5)
#      and announcing its own "6th session"; 34 distinct medic akeys over ~8 real
#      problems.
#   2. The escalation akey carried a `<utc-hour>` suffix, so even identical text
#      minted a new console row and a new Telegram page every hour, and defeated
#      beat.sh's REM_WINDOW throttle (a new key is a new eligible attempt).
#   3. ALERTS.log -> console (poll-commands.sh) keyed on md5 of the WHOLE line,
#      which begins with a timestamp. Unique forever, and that path skips the
#      quarantine and the triage lane entirely, so it had no brake at all.
#
# The unifying rule these assertions defend: A LANE'S OWN OUTPUT IS NEVER ITS
# OWN INPUT, and an alert that only a human can clear is stated once, not
# re-derived on a timer.
#
# Run from anywhere: tests/alert-loop-test.sh   (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

H="$T/h"
. "$DIR/tests/lib/model-route-stub.sh" || exit 1; model_routes_fixture "$H" || exit 1  # BH-1510.2: lanes read models from model_routes
mkdir -p "$H/bin" "$H/logs" "$H/state" "$H/locks" "$H/env" "$T/stub" "$T/calls"
printf 'CONSOLE_URL=https://console.invalid\nHARNESS_SECRET=testsecret\n' > "$H/env/global.env"
sed "s|/root/harness|$H|g" "$DIR/bin/alerts-medic.sh" > "$H/bin/alerts-medic.sh"
chmod +x "$H/bin/alerts-medic.sh"
for s in triage-map.sh fleet-conf.sh box-for.sh alert_family.py; do ln -sf "$DIR/bin/$s" "$H/bin/$s"; done
export FLEET_CONF="$DIR/fleet.conf"
printf '#!/bin/sh\nexit 0\n' > "$H/bin/alerts-groom.sh"; chmod +x "$H/bin/alerts-groom.sh"
# BH-5942: the medic runs per project; rows with no project are the cromford
# run's, and its state is state/alerts-medic/cromford/.
( cd "$DIR" && scratch_install_closure bin/lib/llm-lane-project.sh "$H" ) >/dev/null || exit 1
MS="$H/state/alerts-medic/cromford"; mkdir -p "$MS"

cat > "$H/bin/agent-call.sh" <<'STUB'
#!/bin/bash
N=$(ls "$CALLDIR"/prompt-* 2>/dev/null | wc -l | tr -d ' ')
printf '%s' "$6" > "$CALLDIR/prompt-$N.txt"
echo "medic done" > "$5"
STUB
chmod +x "$H/bin/agent-call.sh"
# The console API is this lane's queue AND, after a session, the place it asks
# whether it escalated. One fixture answers both reads.
cat > "$T/stub/curl" <<STUB
#!/bin/sh
cat "$T/alerts.json"
STUB
chmod +x "$T/stub/curl"
printf '#!/bin/sh\nexit 0\n' > "$T/stub/flock"; chmod +x "$T/stub/flock"
cat > "$T/stub/date" <<'STUB'
#!/bin/sh
if [ "$1" = "-u" ] && [ "$2" = "-d" ]; then shift 3; exec /bin/date -u "$@"; fi
exec /bin/date "$@"
STUB
chmod +x "$T/stub/date"

reset_state() {
  : > "$H/logs/medic.log"; : > "$H/logs/ALERTS.log"
  echo '{}' > "$MS/medic-families.json"
  echo '{}' > "$MS/medic-parked.json"
  : > "$MS/medic-seen.txt"
}
run() {
  rm -rf "$T/calls"; mkdir -p "$T/calls"
  CALLDIR="$T/calls" PATH="$T/stub:$PATH" bash "$H/bin/alerts-medic.sh" cromford >/dev/null 2>&1
}
ncalls() { ls "$T/calls"/prompt-* 2>/dev/null | wc -l | tr -d ' '; }

# ---------- 1. an escalation is never investigated ---------------------------
# Three rows: a real incident, a medic escalation, an alert-triage escalation.
# Only the incident may cost a session. This is THE assertion — without it the
# lane feeds itself and the other brakes only decide how fast.
reset_state
cat > "$T/alerts.json" <<'EOF'
{"alerts":[
{"id":"i1","akey":"prompteval:project-4:20260831","createdAt":"2026-08-25T01:00:00Z","line":"the alpha subsystem is unhappy"},
{"id":"m1","akey":"medic:aaaaaaaaaaaa","createdAt":"2026-08-25T02:00:00Z","line":"MEDIC: the bravo subsystem needs a human to push a repo change"},
{"id":"t1","akey":"triage:deadbeefcafe","createdAt":"2026-08-25T03:00:00Z","line":"the charlie subsystem needs your judgement"}]}
EOF
run
[ "$(ncalls)" = 1 ] && ok || bad "only the real incident may be investigated; escalations are conclusions, not work (got $(ncalls) sessions)"
grep -q "the alpha subsystem" "$T/calls/prompt-0.txt" \
  && ok || bad "the one session must be the genuine incident"
# Coverage control: counting sessions would also pass if the lane investigated an
# escalation and skipped the incident. Name what must be absent.
! grep -qs 'MEDIC: the bravo' "$T"/calls/prompt-*.txt \
  && ok || bad "the medic must never be handed its own escalation to re-verify"
! grep -qs 'the charlie subsystem' "$T"/calls/prompt-*.txt \
  && ok || bad "the medic must never be handed alert-triage's escalation to re-verify"
# An escalation must not be marked seen either — it was never consumed, and the
# 500-entry SEEN window is not where visibility should be decided.
! grep -q '^m1$' "$MS/medic-seen.txt" \
  && ok || bad "an un-investigated escalation must not be recorded as seen"

# ---------- 2. escalating PARKS the family -----------------------------------
# The 6h brake is a rate limit that assumes a later pass might fix the thing. For
# an out-of-bounds problem no pass ever can, so the brake just re-buys the same
# diagnosis four times a day. Escalation is the signal to stop asking.
reset_state
cat > "$T/alerts.json" <<'EOF'
{"alerts":[
{"id":"i1","akey":"prompteval:project-4:20260831","createdAt":"2026-08-25T01:00:00Z","line":"the alpha subsystem is unhappy"}]}
EOF
run
[ "$(ncalls)" = 1 ] && ok || bad "the incident must be investigated once (got $(ncalls))"
FKEY=$(PYTHONPATH="$DIR/bin" python3 -c '
from alert_family import family; print(family("the alpha subsystem is unhappy"))')
[ ! -s "$MS/medic-parked.json" ] || \
  python3 -c 'import json,sys; sys.exit(1 if json.load(open(sys.argv[1])) else 0)' "$MS/medic-parked.json" \
  && ok || bad "an incident with no escalation must NOT be parked — parking is earned by escalating"
# Now the console also holds this family's escalation: the medic has spoken.
cat > "$T/alerts.json" <<EOF
{"alerts":[
{"id":"i1","akey":"prompteval:project-4:20260831","createdAt":"2026-08-25T01:00:00Z","line":"the alpha subsystem is unhappy"},
{"id":"e1","akey":"medic:$FKEY","createdAt":"2026-08-25T02:00:00Z","line":"MEDIC: alpha needs a human"}]}
EOF
echo '{}' > "$MS/medic-families.json"   # 6h brake expired — only the park may hold
: > "$MS/medic-seen.txt"                # and the 500-entry id memory rolled over
: > "$H/logs/medic.log"
run
python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); sys.exit(0 if sys.argv[2] in d else 1)' \
  "$MS/medic-parked.json" "$FKEY" \
  && ok || bad "a family whose escalation is open on the console must be parked"
grep -q "parked family $FKEY" "$H/logs/medic.log" \
  && ok || bad "parking must be declared in the log, not just recorded in state"

# ---------- 3. a parked family is not re-diagnosed, and says so --------------
[ "$(ncalls)" = 0 ] && ok || bad "a parked family must not buy another session even after the 6h brake expires (got $(ncalls))"
grep -q 'medic pass: held 1 alert(s) across 1 parked family' "$H/logs/medic.log" \
  && ok || bad "a held alert must be DECLARED — silence about a wait is indistinguishable from a drop"
# The count alone does not say WHICH problem stopped being worked.
grep -q 'medic held alert i1 in a parked family' "$H/logs/medic.log" \
  && ok || bad "the held alert must be named, not just counted"

# ---------- 3b. the park OUTLIVES its console row ---------------------------
# This lane runs alerts-groom.sh at the top of every pass, which runs
# alerts-supersede.py, which resolves medic rows on a 72h TTL and collapses any
# naming the same ticket as another machine alert. A park anchored on "is the
# escalation still open?" is therefore deleted by our own groomer within hours —
# MEDIC_PARK_TTL would be dead config and the loop merely slowed. The park is
# this lane's memory; the escalation row is a human's page. Different lifetimes.
: > "$H/logs/medic.log"
cat > "$T/alerts.json" <<'EOF'
{"alerts":[
{"id":"i1","akey":"prompteval:project-4:20260831","createdAt":"2026-08-25T01:00:00Z","line":"the alpha subsystem is unhappy"}]}
EOF
echo '{}' > "$MS/medic-families.json"; : > "$MS/medic-seen.txt"
run
[ "$(ncalls)" = 0 ] && ok || bad "the park must survive the groomer resolving its escalation row (got $(ncalls) sessions)"
python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); sys.exit(0 if sys.argv[2] in d else 1)' \
  "$MS/medic-parked.json" "$FKEY" \
  && ok || bad "the park record must persist after its console row is gone"
# The digest is then the only surface carrying this problem, so it must name it.
grep -q "ONE ACTION: MEDIC: alpha needs a human" "$H/logs/medic.log" \
  && ok || bad "a parked family must keep restating the ONE ACTION it is waiting on"

# ---------- 3c. a NEW incident in a parked family is not held ---------------
# family() folds digits, so a second stuck build under a different ticket lands
# in the same family as the first. The first may be awaiting a human merge; the
# second may be one the medic is explicitly allowed to fix. Holding it for the
# park window would be a week-long suppression of fixable work.
: > "$H/logs/medic.log"
cat > "$T/alerts.json" <<'EOF'
{"alerts":[
{"id":"i2","akey":"health:project-1:20260831","createdAt":"2026-08-25T04:00:00Z","line":"the alpha subsystem is unhappy"}]}
EOF
echo '{}' > "$MS/medic-families.json"; : > "$MS/medic-seen.txt"
run
[ "$(ncalls)" = 1 ] && ok || bad "an alert id the park has never seen is a different incident and must be worked (got $(ncalls))"

# ---------- 3d. a LEGACY escalation key still parks --------------------------
# Escalations written before this contract changed carry `medic:<fkey>:<utc-hour>`
# and live on the console for up to 72h. If only the bare form parked, every one
# of them would both fail to park and be reported as contract drift — the fix
# would land looking like a fresh fault, on exactly the lane it was fixing.
reset_state
FK2=$(PYTHONPATH="$DIR/bin" python3 -c '
from alert_family import family; print(family("the delta subsystem is unhappy"))')
cat > "$T/alerts.json" <<EOF
{"alerts":[
{"id":"d1","akey":"health:x:20260831","createdAt":"2026-08-25T01:00:00Z","line":"the delta subsystem is unhappy"},
{"id":"e9","akey":"medic:$FK2:15","createdAt":"2026-08-25T02:00:00Z","line":"MEDIC: delta needs a human"}]}
EOF
run
[ "$(ncalls)" = 0 ] && ok || bad "a legacy medic:<fkey>:<hour> escalation must still park its family (got $(ncalls))"
! grep -q 'ESCALATION AKEY DRIFT' "$H/logs/ALERTS.log" \
  && ok || bad "the legacy key shape is not drift and must not be alerted as such"
# A genuinely malformed key IS drift, and must be named rather than absorbed —
# it excludes itself from investigation but can never park, so the lane would
# quietly go back to paying 6h-brake cost with nothing saying why.
reset_state
cat > "$T/alerts.json" <<'EOF'
{"alerts":[
{"id":"d1","akey":"health:x:20260831","createdAt":"2026-08-25T01:00:00Z","line":"the delta subsystem is unhappy"},
{"id":"e9","akey":"medic:not-a-family-key","createdAt":"2026-08-25T02:00:00Z","line":"MEDIC: delta needs a human"}]}
EOF
run
grep -q 'ESCALATION AKEY DRIFT' "$H/logs/ALERTS.log" \
  && ok || bad "an unparseable medic akey must be declared, not absorbed"

# ---------- 4. the park expires -------------------------------------------
# Parking is a wait, not a delete. Even with the escalation still standing — a
# human who never acted — the TTL must eventually hand the problem back, or a
# forgotten escalation becomes a permanent blind spot.
: > "$H/logs/medic.log"
cat > "$T/alerts.json" <<EOF
{"alerts":[
{"id":"i1","akey":"prompteval:project-4:20260831","createdAt":"2026-08-25T01:00:00Z","line":"the alpha subsystem is unhappy"},
{"id":"e1","akey":"medic:$FKEY","createdAt":"2026-08-25T02:00:00Z","line":"MEDIC: alpha needs a human"}]}
EOF
echo '{}' > "$MS/medic-families.json"; : > "$MS/medic-seen.txt"
scratch_rm "$T/calls"; mkdir -p "$T/calls"
MEDIC_PARK_TTL=0 CALLDIR="$T/calls" PATH="$T/stub:$PATH" \
  bash "$H/bin/alerts-medic.sh" cromford >/dev/null 2>&1
[ "$(ncalls)" -ge 1 ] && ok || bad "an expired park must return the family to the queue even with the escalation still open (got $(ncalls))"

# ---------- 5. ALERTS.log -> console is keyed on the CONDITION ---------------
# poll-commands.sh hashed the whole line, timestamp included, so an unchanged
# condition was a new akey — and a new page — on every single write. That path
# bypasses the quarantine and the triage lane, so nothing else could brake it.
KEY_OF() { PYTHONPATH="$DIR/bin" python3 -c '
import sys
from alert_family import row_key
print(row_key(sys.argv[1]))' "$1"; }
A=$(KEY_OF '2026-08-31 11:51:37Z [project-4] PROMPT EVAL DID NOT RUN: no scenarios recorded.')
B=$(KEY_OF '2026-08-31 12:51:37Z [project-4] PROMPT EVAL DID NOT RUN: no scenarios recorded.')
[ "$A" = "$B" ] && ok || bad "the same condition an hour later must be the same key (got $A vs $B)"
C=$(KEY_OF '2026-08-31 11:51:37Z [project-3] DEPLOY FAILED: build could not start.')
[ "$A" != "$C" ] && ok || bad "genuinely different conditions must still be different keys"
# ...and the far more dangerous direction. family() folds every digit run, so it
# maps TK-1 and TK-99 to ONE signature. Keying a console ROW on that would have
# swapped an over-paging bug for a genuine alert-LOSS bug: the second stuck build
# never gets a row, on the one path with no quarantine and no triage lane behind
# it to recover it. This is why the row key carries identifiers, not just family.
D=$(KEY_OF '2026-08-31 09:00:00Z [project-1] BUILD STUCK: builds/TK-1 no output for 45 min')
E=$(KEY_OF '2026-08-31 14:00:00Z [project-1] BUILD STUCK: builds/TK-99 no output for 45 min')
[ "$D" != "$E" ] && ok || bad "two DIFFERENT stuck builds must get two rows — same-family collapse here loses the second one entirely"
F=$(KEY_OF '2026-08-31 09:00:00Z [project-2] PR #464 open 31h and cannot land')
G=$(KEY_OF '2026-08-31 15:00:00Z [project-2] PR #464 open 37h and cannot land')
[ "$F" = "$G" ] && ok || bad "the SAME PR aging must stay one row — only the count changed"
H=$(KEY_OF '2026-08-31 09:00:00Z [project-1] BUILD STUCK: builds/TK-1 no output for 45 min')
I=$(KEY_OF '2026-08-31 09:00:00Z [project-1] BUILD STUCK: builds/TK-1 no output for 120 min')
[ "$H" = "$I" ] && ok || bad "a bare duration is a magnitude, not an identity — it must not split the row"
# ...and the script must actually USE it. A correct helper the caller ignores is
# the shape of bug this whole file exists to catch.
grep -q 'from alert_family import row_key' "$DIR/bin/poll-commands.sh" \
  && ok || bad "poll-commands.sh must key the ALERTS.log beat on the shared row_key (family + identities)"
# V1 alert hygiene (2026-09-25) REVERSED the day suffix this used to pin: it
# re-opened one unchanged condition as a new console row (and a new page) every
# UTC day. Repeats belong to the state machine in bin/beat.sh; the akey is the
# condition id, with no date.
grep -q 'AKEY="alert:\$AKEY"$' "$DIR/bin/poll-commands.sh" \
  && ok || bad "the ALERTS.log akey must be alert:<condition id>, with no date"
grep -q 'AKEY="alert:\$AKEY:\$(date' "$DIR/bin/poll-commands.sh" \
  && bad "the ALERTS.log akey still carries a date — the same condition re-opens daily" || ok
grep -q 'alert_state_key "\$LINE"' "$DIR/bin/poll-commands.sh" \
  && ok || bad "the ALERTS.log akey must be the state machine's condition id (alert_state_key)"
# THE GUARANTEE THE DAY SUFFIX USED TO GIVE, KEPT (review of #2291): a
# PERSISTENT condition still says itself again. It now does so through the state
# machine's remind, not a new row per day: the same line re-beaten past
# ALERT_REMINDER_S goes out again, on the SAME akey, carrying alertstate
# "remind" — which is what the console pings a still-open row on
# (cromford-console src/alert-ping.js). Driven through the real re-beat
# block and the real bin/beat.sh; only curl is faked.
RB="$T/rb"; mkdir -p "$RB/bin/lib" "$RB/logs" "$RB/flags" "$RB/state" "$RB/env" "$RB/stub"
for s in beat.sh alert_family.py fleet-conf.sh; do ln -sf "$DIR/bin/$s" "$RB/bin/$s"; done
ln -sf "$DIR/bin/lib/alert-state.sh" "$RB/bin/lib/alert-state.sh"
printf '#!/bin/bash\necho ""\n' > "$RB/bin/project-of.sh"; chmod +x "$RB/bin/project-of.sh"
touch "$RB/flags/alert-quarantine-disabled" "$RB/flags/remediation-disabled"
printf 'CONSOLE_URL=https://console.invalid\nHARNESS_SECRET=s\n' > "$RB/env/global.env"
printf '#!/bin/bash\nprev=""; for a in "$@"; do [ "$prev" = "-d" ] && printf "%%s\\n" "$a" >> "%s/sent.jsonl"; prev="$a"; done; echo "{}"\n' "$RB" > "$RB/stub/curl"
chmod +x "$RB/stub/curl"
awk '/^# >>> alerts re-beat/{f=1;next} /^# <<< alerts re-beat/{exit} f{print}' "$DIR/bin/poll-commands.sh" > "$RB/rebeat.sh"
rebeat() { # rebeat <line> [reminder_s] — append the line to ALERTS.log and run the re-beat block once
  printf '%s\n' "$1" >> "$RB/logs/ALERTS.log"
  ( export HARNESS="$RB" PATH="$RB/stub:$PATH" ALERT_REMINDER_S="${2:-21600}"; BEAT="$RB/bin/beat.sh"
    # shellcheck disable=SC1090
    . "$RB/rebeat.sh" ) >/dev/null 2>&1
}
rebeat '2026-08-31 11:51:37Z [project-4] PROMPT EVAL DID NOT RUN: no scenarios recorded.'
rebeat '2026-08-31 12:51:37Z [project-4] PROMPT EVAL DID NOT RUN: no scenarios recorded.'
rebeat '2026-09-01 11:51:37Z [project-4] PROMPT EVAL DID NOT RUN: no scenarios recorded.' 0
SENT_N=$(grep -c . "$RB/sent.jsonl" 2>/dev/null || echo 0)
[ "$SENT_N" = 2 ] && ok || bad "a persistent condition must be sent on first sight and again at the reminder, and not in between (sent $SENT_N, want 2)"
ST1=$(sed -n 1p "$RB/sent.jsonl" 2>/dev/null | jq -r '.alertstate // ""'); ST2=$(sed -n 2p "$RB/sent.jsonl" 2>/dev/null | jq -r '.alertstate // ""')
AK1=$(sed -n 1p "$RB/sent.jsonl" 2>/dev/null | jq -r '.akey // ""'); AK2=$(sed -n 2p "$RB/sent.jsonl" 2>/dev/null | jq -r '.akey // ""')
[ "$ST1" = fire ] && [ "$ST2" = remind ] && ok || bad "the persistent condition must re-say itself as alertstate remind (got '$ST1' then '$ST2')"
[ -n "$AK1" ] && [ "$AK1" = "$AK2" ] && ok || bad "the reminder must land on the SAME console row (akeys '$AK1' vs '$AK2')"
# Fail OPEN: a missing normalizer must page as before, never go quiet.
grep -q '\[ -n "\$AKEY" \] || AKEY=\$(printf %s "\$LINE" | md5sum' "$DIR/bin/poll-commands.sh" \
  && ok || bad "if the normalizer is unavailable the alert must still page (fail open), not vanish"

# ---------- 6. prompt-eval states coverage debt once ------------------------
# Seven uncovered projects produced seven weekly pages that no lane could ever
# clear — the fuel the medic then burned all night. One fact, one alert, keyed on
# the SET so it re-fires when the set changes and is quiet when it merely persists.
grep -q 'PROMPT EVAL COVERAGE DEBT' "$DIR/bin/prompt-eval.sh" \
  && ok || bad "prompt-eval must roll uncovered projects into ONE coverage-debt alert"
grep -q 'prompteval-coverage:\$NOCOV_KEY' "$DIR/bin/prompt-eval.sh" \
  && ok || bad "the coverage alert must be keyed on the uncovered SET, not the date"
# The rollup must not swallow a genuinely broken gate on a COVERED project.
grep -q 'EV_WHY" = "no-scenarios"' "$DIR/bin/prompt-eval.sh" \
  && ok || bad "only no-scenarios may roll up; run-failed / nothing-graded / coverage-shrank must still alert per project"
grep -q 'This is a broken gate, not a coverage gap' "$DIR/bin/prompt-eval.sh" \
  && ok || bad "a covered project that produced no result must still page on its own"

echo "pass=$PASS fail=$FAIL"
[ "$FAIL" -eq 0 ]
