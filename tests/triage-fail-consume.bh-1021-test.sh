#!/bin/bash
# tests/triage-fail-consume.bh-1021-test.sh — a triage session that fails every
# time must stop being bought every ten minutes.
#
# WHAT WENT WRONG. bin/lib/rt/launch.sh consumes the pending board fingerprint
# ONLY when the triage agent exits rc=0. A session that fails every time leaves
# state/<project>.gate.pending in place, so the next tick's gate diffs the same
# board against the same old gate.json, answers RUN board-changed again, and
# buys the same failing session ten minutes later. On project-5 on 2026-09-17
# that shape billed 1,168 rc!=0 triage rows in one day on ONE fingerprint.
#
# THE PROPERTY. Consecutive rc!=0 exits are COUNTED per pending-fingerprint sha
# in state/<project>.gate.fail. At the cap (TRIAGE_FAIL_CONSUME_AFTER, default 3)
# the tick consumes the fingerprint anyway, drops the counter and alerts ONCE, so
# the next tick's gate answers SKIP no-change and spends nothing. A success
# clears the counter; a different fingerprint restarts the count at 1.
#
# Driven, not grepped: every section runs the REAL bin/run-triage.sh (with its
# real bin/lib/rt/*.sh stages) in a scratch harness whose agent call is a stub
# that exits with the code the fixture names. The files the tick leaves behind,
# the number of agent calls it made and the argv the alert stub recorded ARE the
# assertions (the tests/triage-lock-not-inherited-test.sh precedent).
# Run from anywhere: tests/triage-fail-consume.bh-1021-test.sh  (exit 0 = all pass)
set -uo pipefail
[ -r "$(dirname "$0")/lib/scratch.sh" ] && . "$(dirname "$0")/lib/scratch.sh"
[ -n "${T:-}" ] || { T=$(mktemp -d); trap 'rm -rf "$T"' EXIT; }
chmod 755 "$T" 2>/dev/null || true
# bin/run-triage.sh resolves HARNESS as "${HARNESS:-/root/harness}", so an
# inherited HARNESS (every build agent exports one) would make the scratch copy
# drive the LIVE harness — real gate, real logs, real money.
unset HARNESS H HARNESS_CHECKOUT
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

P=project-5
export FLEET_CONF="$DIR/fleet.conf"

# Nothing here is ever deleted: every section gets its own fixture root, so this
# file carries no recursive rm of its own (checks/tests-scratch-only R2).
mkfixture() { # mkfixture <root> — a scratch harness running the REAL run-triage.sh
  local h="$1"
  mkdir -p "$h/bin/lib" "$h/logs" "$h/state" "$h/locks" "$h/env" "$h/flags" \
           "$h/prompts" "$h/builds" "$h/catalog" "$h/calls" "$h/fixture"
  . "$DIR/tests/lib/model-route-stub.sh" || exit 1; model_routes_fixture "$h" project-5 || exit 1  # BH-1510.2: lanes read models from model_routes
  : > "$h/env/global.env"
  : > "$h/logs/READY-QUEUE.log"
  echo "SOP for $P. Fetch the thread. Do the work." > "$h/prompts/$P.md"

  # The single-session path is the one under test: shards consume at dispatch and
  # re-arm per key, and never reach this code.
  : > "$h/flags/triage-shards-off"

  # the script under test, with only its roots repointed (the
  # tests/triage-shards-test.sh precedent)
  sed -e "s|/root/harness|$h|g" -e "s|/root/repos|$T/repos|g" \
      "$DIR/bin/run-triage.sh" > "$h/bin/run-triage.sh"
  chmod +x "$h/bin/run-triage.sh"
  mkdir -p "$h/bin/lib/rt"
  local s
  for s in "$DIR"/bin/lib/rt/*.sh; do
    sed -e "s|/root/harness|$h|g" -e "s|/root/repos|$T/repos|g" "$s" > "$h/bin/lib/rt/$(basename "$s")"
  done
  cp "$DIR/bin/lib/triage-shards-lib.sh" "$h/bin/lib/triage-shards-lib.sh"
  for s in fleet-conf.sh project-of.sh decision-log.sh queue-line-drop.sh; do
    ln -sf "$DIR/bin/$s" "$h/bin/$s"
  done
  printf '#!/bin/sh\necho box-project-5-1\n' > "$h/bin/box-name.sh"

  # --- fixture knobs the stubs read ------------------------------------------
  printf '{"issues":[{"number":561,"state":"OPEN","title":"a"}],"prs":[]}' > "$h/fixture/pending.json"
  printf 'OLD-BOARD-STATE' > "$h/state/$P.gate.json"
  echo 1 > "$h/fixture/rc"
  : > "$h/fixture/diff"

  # The gate: writes the pending fingerprint the way bin/triage-gate.sh does, and
  # answers SKIP no-change exactly when the consumed gate.json already equals it.
  # That equality IS the thing the fix is about, so the stub must decide it the
  # same way the real gate does rather than being told the answer.
  cat > "$h/bin/triage-gate.sh" <<STUB
#!/bin/bash
PJ="\$1"; MODE="\${2:-}"
if [ -e "$h/fixture/no-pending" ]; then
  # the daily-sweep / forced / no-gate-state shape: no pending file is written
  [ "\$MODE" = "--pending" ] && exit 0
  echo "RUN daily-sweep"
  exit 0
fi
cp "$h/fixture/pending.json" "$h/state/\$PJ.gate.pending"
[ "\$MODE" = "--pending" ] && exit 0
if cmp -s "$h/fixture/pending.json" "$h/state/\$PJ.gate.json"; then
  echo "SKIP no-change"
else
  echo "RUN board-changed"
fi
exit 0
STUB
  cat > "$h/bin/gate-diff.sh" <<STUB
#!/bin/bash
[ -s "$h/fixture/diff" ] || exit 2
cat "$h/fixture/diff"
STUB
  printf '#!/bin/sh\nexit 0\n' > "$h/bin/unblocked-children.sh"
  printf '#!/bin/sh\necho "CONTRACT: end with DECISION lines."\n' > "$h/bin/triage-contract.sh"
  printf '#!/bin/sh\nexit 0\n' > "$h/bin/beat.sh"

  # agent-call.sh <stage> <project> <model> <timeout> <outfile> <prompt|@file>
  # The paid session. It records that it ran and exits with the fixture's rc.
  cat > "$h/bin/agent-call.sh" <<STUB
#!/bin/bash
: > "\$(mktemp "$h/calls/call-XXXXXXXX.txt")"
echo "tickets=1 triage ran" > "\$5"
exit "\$(cat "$h/fixture/rc")"
STUB
  # lane-alert.sh: its argv is the assertion.
  cat > "$h/bin/lane-alert.sh" <<STUB
#!/bin/bash
printf '%s\n' "\$*" >> "$h/fixture/alerts.txt"
exit 0
STUB
  chmod +x "$h/bin/agent-call.sh" "$h/bin/triage-gate.sh" "$h/bin/gate-diff.sh" \
           "$h/bin/unblocked-children.sh" "$h/bin/triage-contract.sh" \
           "$h/bin/beat.sh" "$h/bin/box-name.sh" "$h/bin/lane-alert.sh"
}

HR=""   # the fixture the helpers below drive
tick()    { "$HR/bin/run-triage.sh" "$P" >/dev/null 2>&1; }
ncalls()  { ls "$HR/calls"/call-* 2>/dev/null | wc -l | tr -d ' '; }
nalerts() { grep -c . "$HR/fixture/alerts.txt" 2>/dev/null || echo 0; }
failn()   { sed -n 2p "$HR/state/$P.gate.fail" 2>/dev/null; }
failsha() { head -1 "$HR/state/$P.gate.fail" 2>/dev/null; }
shaof()   { sha256sum < "$1" | cut -c1-16; }
setrc()   { echo "$1" > "$HR/fixture/rc"; }

# ---------- A. three failures, then the fingerprint is consumed anyway -------
HR="$T/a"; mkfixture "$HR"
SHA_A=$(shaof "$HR/fixture/pending.json")

# A0 — the control: without a session that really ran and really failed, every
# assertion below would pass vacuously.
tick
if [ "$(ncalls)" = 1 ]; then ok
else bad "tick 1 made $(ncalls) agent calls, expected 1 — this section proves nothing"; fi

# A1 — tick 1: counted, NOT consumed.
[ -f "$HR/state/$P.gate.pending" ] && ok \
  || bad "tick 1 (rc=1) consumed the pending fingerprint — a single failure must not"
[ "$(failn)" = 1 ] && [ "$(failsha)" = "$SHA_A" ] && ok \
  || bad "after failure 1, state/$P.gate.fail must be '$SHA_A' + count 1 (got: $(failsha)/$(failn))"
[ "$(nalerts)" = 0 ] && ok || bad "one failure must not alert (alerts: $(cat "$HR/fixture/alerts.txt" 2>/dev/null))"
grep -q 'NOT consumed, failed attempt 1/3' "$HR/logs/$P.log" \
  && ok || bad "tick 1 must log the attempt it did not consume on: $(grep triage "$HR/logs/$P.log" | tail -2)"

# A2 — tick 2: counted again, still not consumed.
tick
[ -f "$HR/state/$P.gate.pending" ] && ok || bad "tick 2 (rc=1) consumed the pending fingerprint before the cap"
[ "$(failn)" = 2 ] && ok || bad "after failure 2 the count must be 2 (got $(failn))"
[ "$(nalerts)" = 0 ] && ok || bad "two failures must not alert yet"
[ "$(ncalls)" = 2 ] && ok || bad "tick 2 must buy its own session (calls: $(ncalls))"

# A3 — tick 3: the cap. Consume anyway, drop the counter, alert once.
tick
[ "$(ncalls)" = 3 ] && ok || bad "tick 3 must buy its own session (calls: $(ncalls))"
[ ! -e "$HR/state/$P.gate.pending" ] && ok \
  || bad "after the third consecutive rc!=0 the pending fingerprint must be consumed anyway — this is the 1,168-rows-a-day shape"
cmp -s "$HR/fixture/pending.json" "$HR/state/$P.gate.json" && ok \
  || bad "the consume must absorb the pending fingerprint into $P.gate.json (got: $(cat "$HR/state/$P.gate.json" 2>/dev/null))"
case "$(cat "$HR/state/$P.gate-meta" 2>/dev/null)" in
  ''|*[!0-9]*) bad "the consume must stamp $P.gate-meta with an epoch second (got: $(cat "$HR/state/$P.gate-meta" 2>/dev/null))" ;;
  *)           ok ;;
esac
[ ! -e "$HR/state/$P.gate.fail" ] && ok || bad "the counter must be dropped once it fired (got: $(cat "$HR/state/$P.gate.fail"))"
[ "$(nalerts)" = 1 ] && ok || bad "the cap must alert exactly once (alerts: $(nalerts))"
A3ALERT=$(cat "$HR/fixture/alerts.txt" 2>/dev/null)
case "$A3ALERT" in
  *"--id triage-fail-consume:$P"*) ok ;;
  *) bad "the alert must carry the stable per-project id so a repeat is deduped: $A3ALERT" ;;
esac
case "$A3ALERT" in
  *"3 times"*"$SHA_A"*) ok ;;
  *) bad "the alert must name the failure count and the fingerprint: $A3ALERT" ;;
esac
grep -q "consumed after 3 failed attempts" "$HR/logs/$P.log" \
  && ok || bad "the cap must log the consume it made: $(grep triage "$HR/logs/$P.log" | tail -2)"

# A4 — tick 4: the whole point. The gate now answers SKIP and nothing is bought.
tick
[ "$(ncalls)" = 3 ] && ok \
  || bad "the tick after the consume must buy NO session — that is the spend this ticket stops (calls: $(ncalls))"
grep -q 'rc=skip :: gate no-change' "$HR/logs/$P.log" \
  && ok || bad "tick 4's gate must answer no-change: $(tail -2 "$HR/logs/$P.log")"
[ "$(nalerts)" = 1 ] && ok || bad "tick 4 must not send a second alert (alerts: $(nalerts))"

# ---------- B. the success path is untouched ---------------------------------
HR="$T/b1"; mkfixture "$HR"; setrc 0
tick
# B1 — rc=0 consumes exactly as it always did, and leaves no counter behind.
[ ! -e "$HR/state/$P.gate.pending" ] && cmp -s "$HR/fixture/pending.json" "$HR/state/$P.gate.json" \
  && ok || bad "a successful tick must still consume the pending fingerprint"
[ ! -e "$HR/state/$P.gate.fail" ] && ok || bad "a successful tick must leave no failure counter"
[ "$(nalerts)" = 0 ] && ok || bad "a successful tick must not alert"

# B2 — fail, fail, succeed: the counter is cleared, so the NEXT failure starts over.
HR="$T/b2"; mkfixture "$HR"
tick; tick
[ "$(failn)" = 2 ] && ok || bad "B2 setup: two failures must count 2 (got $(failn))"
setrc 0; tick
[ ! -e "$HR/state/$P.gate.fail" ] && ok || bad "a success between failures must clear the counter (got: $(cat "$HR/state/$P.gate.fail"))"
[ "$(nalerts)" = 0 ] && ok || bad "fail,fail,success must never alert"

# B3 — a DIFFERENT fingerprint restarts the count at 1: a new board state
# deserves its own attempts.
HR="$T/b3"; mkfixture "$HR"
tick; tick
[ "$(failn)" = 2 ] && ok || bad "B3 setup: two failures must count 2 (got $(failn))"
printf '{"issues":[{"number":999,"state":"OPEN","title":"b"}],"prs":[]}' > "$HR/fixture/pending.json"
SHA_B=$(shaof "$HR/fixture/pending.json")
tick
[ "$(failsha)" = "$SHA_B" ] && [ "$(failn)" = 1 ] && ok \
  || bad "a changed fingerprint must restart the count at 1 (got: $(failsha)/$(failn), expected $SHA_B/1)"
[ -f "$HR/state/$P.gate.pending" ] && ok || bad "the third failure on a NEW fingerprint must not consume it"
[ "$(nalerts)" = 0 ] && ok || bad "three failures across two fingerprints must not alert"

# ---------- C. the operator knob ---------------------------------------------
# C1 — TRIAGE_FAIL_CONSUME_AFTER=0 is today's behaviour, kept reachable.
HR="$T/c1"; mkfixture "$HR"
echo 'TRIAGE_FAIL_CONSUME_AFTER=0' > "$HR/env/global.env"
for _ in 1 2 3 4 5; do tick; done
[ "$(ncalls)" = 5 ] && ok || bad "C1 setup: five ticks must make five calls with the cap off (got $(ncalls))"
[ -f "$HR/state/$P.gate.pending" ] && ok || bad "TRIAGE_FAIL_CONSUME_AFTER=0 must never consume on failure"
[ ! -e "$HR/state/$P.gate.fail" ] && ok || bad "the disabled knob must not even write a counter"
[ "$(nalerts)" = 0 ] && ok || bad "the disabled knob must not alert"

# C2 — garbage reads as the default 3, never as "no cap" and never as 0.
HR="$T/c2"; mkfixture "$HR"
echo 'TRIAGE_FAIL_CONSUME_AFTER=abc' > "$HR/env/global.env"
tick; tick
[ -f "$HR/state/$P.gate.pending" ] && ok || bad "a non-numeric cap must not consume before 3 failures"
tick
[ ! -e "$HR/state/$P.gate.pending" ] && ok || bad "a non-numeric cap must fall back to 3, not to off"
[ "$(nalerts)" = 1 ] && ok || bad "a non-numeric cap must alert once at 3 (alerts: $(nalerts))"

# ---------- D. the no-pending shape (daily-sweep / forced / no-gate-state) ----
# Same runaway: an unstamped full-sweep clock re-answers RUN daily-sweep every
# tick, so the failures are counted under the `none` key and the cap stamps it.
HR="$T/d1"; mkfixture "$HR"
: > "$HR/fixture/no-pending"
tick; tick
[ "$(failsha)" = none ] && [ "$(failn)" = 2 ] && ok \
  || bad "a tick with no pending file must count under the 'none' key (got: $(failsha)/$(failn))"
[ ! -e "$HR/state/$P.gate-meta" ] && ok || bad "D1 setup: the sweep clock must be unstamped before the cap"
tick
case "$(cat "$HR/state/$P.gate-meta" 2>/dev/null)" in
  ''|*[!0-9]*) bad "the cap must stamp the full-sweep clock even with no pending file — that is what ends the daily-sweep loop" ;;
  *)           ok ;;
esac
case "$(cat "$HR/fixture/alerts.txt" 2>/dev/null)" in
  *"(none)"*) ok ;;
  *) bad "the no-pending alert must say the fingerprint was (none): $(cat "$HR/fixture/alerts.txt" 2>/dev/null)" ;;
esac

# ---------- E. the alert can fail; the consume still stands ------------------
HR="$T/e1"; mkfixture "$HR"
chmod -x "$HR/bin/lane-alert.sh"
tick; tick; tick
[ ! -e "$HR/state/$P.gate.pending" ] && ok \
  || bad "an unrunnable lane-alert.sh must not stop the consume — the spend is what we are stopping"
grep -q 'lane-alert.sh did not run' "$HR/logs/ALERTS.log" 2>/dev/null \
  && ok || bad "a consume whose alert could not be sent must leave one raw ALERTS.log line: $(cat "$HR/logs/ALERTS.log" 2>/dev/null | tail -3)"

echo "pass=$PASS fail=$FAIL"
[ "$FAIL" -eq 0 ]
