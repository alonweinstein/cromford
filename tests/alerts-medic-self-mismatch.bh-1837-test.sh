#!/bin/bash
# tests/alerts-medic-self-mismatch.bh-1837-test.sh — alerts-medic never
# triages its own MODEL/RUNNER MISMATCH line (BH-1837).
#
# The medic calls `agent-call.sh triage medic <floor fallback model>` with
# RUNNER_TRIAGE=<floor runner>. On the hub that is a grok runner with a claude
# model, so agent-call writes `<stamp> [medic] MODEL/RUNNER MISMATCH: triage/medic …`
# into ALERTS.log, which reaches the console and then the medic's own queue.
# Diagnosing it would buy one more call of exactly that shape. So the medic
# drops rows whose OWN leading project tag is [medic] and that are a mismatch
# line; everything else still reaches it.
#
# The real bin/alerts-medic.sh runs (the sed-copy harness from
# tests/alert-loop-test.sh) against a fixture console and a stub agent-call
# that saves every prompt it is handed.
#   A1  only the medic's own mismatch line -> 0 sessions, a medic.log count line
#   A2  [project-1] MODEL/RUNNER MISMATCH -> investigated
#   A3  [project-4] … mentions [medic] MODEL/RUNNER MISMATCH in prose -> investigated
#   A4  the own line plus a [medic] triage failure -> only the failure is handed over
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

H="$T/h"
. "$DIR/tests/lib/model-route-stub.sh" || exit 1; model_routes_fixture "$H" || exit 1
mkdir -p "$H/bin" "$H/logs" "$H/state" "$H/locks" "$H/env" "$T/stub" "$T/calls"
printf 'CONSOLE_URL=https://console.invalid\nHARNESS_SECRET=testsecret\n' > "$H/env/global.env"
sed "s|/root/harness|$H|g" "$DIR/bin/alerts-medic.sh" > "$H/bin/alerts-medic.sh"
chmod +x "$H/bin/alerts-medic.sh"
for s in triage-map.sh fleet-conf.sh box-for.sh alert_family.py; do ln -sf "$DIR/bin/$s" "$H/bin/$s"; done
# BH-5942: the lane runs per project; its runner seam.
( cd "$DIR" && scratch_install_closure bin/lib/llm-lane-project.sh "$H" ) >/dev/null || exit 1
# BH-5942: rows with no project belong to the cromford run.
MS="$H/state/alerts-medic/cromford"
export FLEET_CONF="$DIR/fleet.conf"
printf '#!/bin/sh\nexit 0\n' > "$H/bin/alerts-groom.sh"; chmod +x "$H/bin/alerts-groom.sh"

cat > "$H/bin/agent-call.sh" <<'STUB'
#!/bin/bash
N=$(ls "$CALLDIR"/prompt-* 2>/dev/null | wc -l | tr -d ' ')
printf '%s' "$6" > "$CALLDIR/prompt-$N.txt"
echo "medic done" > "$5"
STUB
chmod +x "$H/bin/agent-call.sh"
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
  echo '{}' > "$H/state/medic-families.json"
  echo '{}' > "$H/state/medic-parked.json"
  : > "$H/state/medic-seen.txt"
  scratch_rm "$MS"
}
run() {
  rm -rf "$T/calls"; mkdir -p "$T/calls"
  CALLDIR="$T/calls" PATH="$T/stub:$PATH" bash "$H/bin/alerts-medic.sh" cromford >/dev/null 2>&1
}
ncalls() { ls "$T/calls"/prompt-* 2>/dev/null | wc -l | tr -d ' '; }
# queue <line>... — the console's open alerts, one row per line, all past the cutoff
queue() {
  local i=0 l
  { printf '{"alerts":['
    for l in "$@"; do
      [ "$i" -gt 0 ] && printf ','
      jq -nc --arg id "q$i" --arg l "$l" --arg k "alert:$(printf '%s' "$l" | md5sum | cut -c1-12):20260924" \
        '{id:$id,akey:$k,createdAt:"2026-09-24T01:00:00Z",line:$l}'
      i=$((i+1))
    done
    printf ']}\n'; } > "$T/alerts.json"
}

# Exactly the line bin/agent-call.sh writes for the medic's own call on the hub.
SELF="2026-09-24 01:00:00Z [medic] MODEL/RUNNER MISMATCH: triage/medic asked for claude-fable-5-1 but RUNNER_TRIAGE=grok would run grok-4.6 (AGENT_CALL_MODEL_MISMATCH=warn). Pass a grok-family model, or change RUNNER_TRIAGE / the stage.triage route."
OTHER="2026-09-24 01:00:00Z [project-1] MODEL/RUNNER MISMATCH: triage/project-1 asked for claude-fable-5-1 but RUNNER_TRIAGE=grok would run grok-4.6 (AGENT_CALL_MODEL_MISMATCH=warn). Pass a grok-family model, or change RUNNER_TRIAGE / the stage.triage route."
PROSE="2026-09-24 01:00:00Z [project-4] note: see [medic] MODEL/RUNNER MISMATCH: earlier, the project-4 board poll is still failing"
MFAIL="2026-09-24 01:00:00Z [medic] triage: agent-call failed rc=1 for the zulu family"

# ---- A1: the medic's own mismatch line is never a session
reset_state
queue "$SELF"
run
[ "$(ncalls)" = 0 ] && ok || bad "A1 the medic investigated its own mismatch line ($(ncalls) session(s))"
grep -q 'own MODEL/RUNNER MISMATCH' "$H/logs/medic.log" && ok \
  || bad "A1 no 'held … own MODEL/RUNNER MISMATCH' count line in medic.log: $(cat "$H/logs/medic.log")"
! grep -q '^q0$' "$MS/medic-seen.txt" && ok || bad "A1 a dropped row must not be marked seen"

# ---- A2: another project's mismatch line still reaches the medic
reset_state
queue "$OTHER"
run
[ "$(ncalls)" = 1 ] && grep -qF '[project-1] MODEL/RUNNER MISMATCH' "$T/calls/prompt-0.txt" && ok \
  || bad "A2 [project-1] mismatch was not investigated ($(ncalls) session(s))"

# ---- A3: [medic] in another row's prose is not the row's own tag
reset_state
queue "$PROSE"
run
[ "$(ncalls)" = 1 ] && grep -qF 'the project-4 board poll is still failing' "$T/calls/prompt-0.txt" && ok \
  || bad "A3 a [project-4] row mentioning [medic] MODEL/RUNNER MISMATCH was dropped ($(ncalls) session(s))"

# ---- A4: a mixed queue — the own line goes, the medic's real failure stays
reset_state
queue "$SELF" "$MFAIL"
run
[ "$(ncalls)" -ge 1 ] && grep -qsF 'agent-call failed rc=1 for the zulu family' "$T"/calls/prompt-*.txt && ok \
  || bad "A4 the [medic] triage failure did not reach a session ($(ncalls) session(s))"
! grep -qsF 'MODEL/RUNNER MISMATCH: triage/medic' "$T"/calls/prompt-*.txt && ok \
  || bad "A4 the medic's own mismatch line was handed to a session"

echo "alerts-medic-self-mismatch: $PASS pass, $FAIL fail"
[ "$FAIL" -eq 0 ]
