#!/bin/bash
# tests/run-triage-callguard-skip.bh-4120-test.sh — BH-4120: a call-guard REPEAT
# refusal on a triage tick is a skip, not a failure.
#
# THE INCIDENT. harness-console (0 open issues) kept buying queue-pending
# sessions on another project's queue lines; after two identical paid prompts
# bin/agent-call.sh refused the third with `AGENT_CALL_REFUSED call-guard repeat`
# and rc 74. bin/run-triage.sh logged `rc=74`, wrote an ALERTS line and sent a
# run beat with rc 74, so Mission Control's LAST RESULT read FAILED — for a guard
# that did exactly its job. The guard refusing is "no new input", not "the lane
# broke".
#
# WHAT IS KEPT. The log still carries a line for the tick, and the BH-1021
# failed-attempt counter on the pending fingerprint still counts it (that
# counter is what eventually consumes a fingerprint that keeps failing).
# WHAT IS NOT CHANGED. Any other rc 74 (`call-guard counter-unreadable`) and
# any other failure keep the FAILED path.
#
# Driven, not grepped: the REAL bin/run-triage.sh with its real bin/lib/rt/*.sh
# stages in a scratch harness (the tests/triage-full-sweep-clock.bh-2751-test.sh
# fixture), with stub agent-call.sh / beat.sh.
# Run from anywhere: HARNESS_TEST_SANDBOX=1 bash tests/run-triage-callguard-skip.bh-4120-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
# bin/run-triage.sh resolves HARNESS as "${HARNESS:-/root/harness}", so an
# inherited HARNESS would make the scratch copy drive the LIVE harness.
unset HARNESS H HARNESS_CHECKOUT
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }

P=project-5
export FLEET_CONF="$DIR/fleet.conf"
# ONE clock read for the whole suite (bin/test-determinism-lint.sh).
NOW=$(date +%s)

mkfixture() { # mkfixture <root> — a scratch harness running the REAL run-triage.sh
  local h="$1" s
  mkdir -p "$h/bin/lib/rt" "$h/logs" "$h/state" "$h/locks" "$h/env" "$h/flags" \
           "$h/prompts" "$h/builds" "$h/catalog" "$h/fixture"
  . "$DIR/tests/lib/model-route-stub.sh" || exit 1; model_routes_fixture "$h" project-5 || exit 1
  : > "$h/env/global.env"
  : > "$h/logs/READY-QUEUE.log"
  : > "$h/flags/triage-shards-off"
  echo "SOP for $P. Fetch the thread. Do the work." > "$h/prompts/$P.md"
  for s in run-triage.sh triage-shard.sh; do
    sed -e "s|/root/harness|$h|g" -e "s|/root/repos|$T/repos|g" "$DIR/bin/$s" > "$h/bin/$s"
    chmod +x "$h/bin/$s"
  done
  for s in "$DIR"/bin/lib/rt/*.sh; do
    sed -e "s|/root/harness|$h|g" -e "s|/root/repos|$T/repos|g" "$s" > "$h/bin/lib/rt/$(basename "$s")"
  done
  # scratch-closure-allow: run-triage is installed sed-rewritten (/root/harness -> scratch), so the closure cannot install it; this lib is its one plain dependency
  cp "$DIR/bin/lib/triage-shards-lib.sh" "$h/bin/lib/triage-shards-lib.sh"
  for s in fleet-conf.sh project-of.sh decision-log.sh queue-line-drop.sh; do
    ln -sf "$DIR/bin/$s" "$h/bin/$s"
  done
  printf '#!/bin/sh\necho box-project-5-1\n' > "$h/bin/box-name.sh"
  printf '{"issues":[{"number":561,"state":"OPEN","title":"a"}],"prs":[]}' > "$h/fixture/pending.json"
  printf 'OLD-BOARD-STATE' > "$h/state/$P.gate.json"
  echo "$((NOW - 600))" > "$h/state/$P.gate-meta"
  cat > "$h/bin/triage-gate.sh" <<STUB
#!/bin/bash
cp "$h/fixture/pending.json" "$h/state/\$1.gate.pending"
[ "\${2:-}" = "--pending" ] && exit 0
echo "RUN forced"
exit 0
STUB
  printf '#!/bin/sh\nexit 2\n' > "$h/bin/gate-diff.sh"
  printf '#!/bin/sh\nexit 0\n' > "$h/bin/unblocked-children.sh"
  printf '#!/bin/sh\necho "CONTRACT: end with DECISION lines."\n' > "$h/bin/triage-contract.sh"
  printf '#!/bin/sh\nprintf "%%s\\n" "$1" >> "%s/fixture/beats"\nexit 0\n' "$h" > "$h/bin/beat.sh"
  printf '#!/bin/sh\nexit 0\n' > "$h/bin/lane-alert.sh"
  # agent-call.sh <stage> <project> <model> <timeout> <outfile> <prompt|@file>
  cat > "$h/bin/agent-call.sh" <<STUB
#!/bin/bash
case "\$(cat "$h/fixture/mode")" in
  repeat)     echo "AGENT_CALL_REFUSED call-guard repeat triage paid=2/2 fp=abc" > "\$5"; exit 74 ;;
  unreadable) echo "AGENT_CALL_REFUSED call-guard counter-unreadable metered claude" > "\$5"; exit 74 ;;
  fail)       echo "boom" > "\$5"; exit 1 ;;
  *)          echo "tickets=1 triage ran" > "\$5"; exit 0 ;;
esac
STUB
  chmod +x "$h/bin/agent-call.sh" "$h/bin/triage-gate.sh" "$h/bin/gate-diff.sh" \
           "$h/bin/unblocked-children.sh" "$h/bin/triage-contract.sh" \
           "$h/bin/beat.sh" "$h/bin/box-name.sh" "$h/bin/lane-alert.sh"
}

HR=""
tick()     { "$HR/bin/run-triage.sh" "$P" >/dev/null 2>&1; }
plog()     { cat "$HR/logs/$P.log" 2>/dev/null; }
alerts()   { cat "$HR/logs/ALERTS.log" 2>/dev/null; }
beat_rc()  { tail -1 "$HR/fixture/beats" 2>/dev/null | jq -r '.rc' 2>/dev/null; }
nbeats()   { awk 'END{print NR}' "$HR/fixture/beats" 2>/dev/null || echo 0; }

# ---------- C1. a call-guard REPEAT renders as skip --------------------------
HR="$T/c1"; mkfixture "$HR"
echo repeat > "$HR/fixture/mode"
tick
grep -q '\] rc=skip :: call-guard repeat (no new input)' <<<"$(plog)" && ok \
  || bad "C1: the project log must carry 'rc=skip :: call-guard repeat (no new input)': $(plog | tail -3)"
grep -q '\] rc=74 ::' <<<"$(plog)" \
  && bad "C1: a call-guard repeat must not be logged as rc=74: $(plog | tail -3)" || ok
grep -q 'AGENT_CALL_REFUSED call-guard repeat triage paid=2/2' <<<"$(plog)" && ok \
  || bad "C1: the skip line must keep the refusal itself readable: $(plog | tail -3)"
grep -q 'triage run exited rc=74' <<<"$(alerts)" \
  && bad "C1: a call-guard repeat must not write an ALERTS rc=74 line: $(alerts)" || ok
[ "$(nbeats)" = 1 ] && ok || bad "C1: expected exactly 1 run beat, got $(nbeats)"
[ "$(beat_rc)" = 0 ] && ok || bad "C1: the run beat must carry rc 0 (LAST RESULT OK), got '$(beat_rc)'"
grep -q 'call-guard repeat (no new input)' <<<"$(tail -1 "$HR/fixture/beats" | jq -r '.summary')" && ok \
  || bad "C1: the run beat's summary must say why it skipped: $(tail -1 "$HR/fixture/beats")"

# ---------- C2. the failed-attempt counter is kept ---------------------------
SHA=$(sha256sum < "$HR/fixture/pending.json" | cut -c1-16)
[ "$(head -1 "$HR/state/$P.gate.fail" 2>/dev/null)" = "$SHA" ] \
  && [ "$(sed -n 2p "$HR/state/$P.gate.fail" 2>/dev/null)" = 1 ] && ok \
  || bad "C2: state/$P.gate.fail must hold $SHA / 1, got: $(cat "$HR/state/$P.gate.fail" 2>/dev/null)"
grep -q "triage rc=74: fingerprint $SHA NOT consumed, failed attempt 1/3" <<<"$(plog)" && ok \
  || bad "C2: the failed-attempt line must still be logged: $(plog | tail -3)"
tick
[ "$(sed -n 2p "$HR/state/$P.gate.fail" 2>/dev/null)" = 2 ] && ok \
  || bad "C2: a second identical refusal must count attempt 2, got: $(cat "$HR/state/$P.gate.fail" 2>/dev/null)"
[ -e "$HR/state/$P.gate.pending" ] && ok || bad "C2: a refused tick must not consume the pending fingerprint"

# ---------- C3. counter-unreadable is still a failure ------------------------
HR="$T/c3"; mkfixture "$HR"
echo unreadable > "$HR/fixture/mode"
tick
grep -q '\] rc=74 ::' <<<"$(plog)" && ok || bad "C3: counter-unreadable must stay rc=74: $(plog | tail -3)"
grep -q 'rc=skip' <<<"$(plog)" && bad "C3: counter-unreadable must not read as a skip" || ok
grep -q 'triage run exited rc=74' <<<"$(alerts)" && ok || bad "C3: counter-unreadable must still write the ALERTS line"
[ "$(beat_rc)" = 74 ] && ok || bad "C3: counter-unreadable must beat rc 74, got '$(beat_rc)'"

# ---------- C4. other outcomes are unchanged ---------------------------------
HR="$T/c4f"; mkfixture "$HR"
echo fail > "$HR/fixture/mode"
tick
grep -q '\] rc=1 ::' <<<"$(plog)" && ok || bad "C4: an rc 1 session must log rc=1: $(plog | tail -3)"
grep -q 'triage run exited rc=1' <<<"$(alerts)" && ok || bad "C4: an rc 1 session must write the ALERTS line"
[ "$(beat_rc)" = 1 ] && ok || bad "C4: an rc 1 session must beat rc 1, got '$(beat_rc)'"
HR="$T/c4o"; mkfixture "$HR"
echo ok > "$HR/fixture/mode"
tick
grep -q '\] rc=0 :: tickets=1' <<<"$(plog)" && ok || bad "C4: an rc 0 session must log rc=0: $(plog | tail -3)"
[ "$(beat_rc)" = 0 ] && ok || bad "C4: an rc 0 session must beat rc 0, got '$(beat_rc)'"
[ ! -e "$HR/state/$P.gate.pending" ] && ok || bad "C4: an rc 0 session must consume the pending fingerprint"

echo "pass=$PASS fail=$FAIL"
[ "$FAIL" -eq 0 ]
