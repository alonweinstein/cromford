#!/bin/bash
# tests/triage-full-sweep-clock.bh-2751-test.sh — a SCOPED triage tick must not
# restamp the full-sweep clock, or the daily sweep never fires again.
#
# WHAT WENT WRONG (BH-2751 / BH-2753). rt_gate_consume wrote `date +%s` into
# state/<project>.gate-meta on EVERY consumed tick: sharded wakes (shards.sh),
# every rc=0 single session (launch.sh) and the BH-1021 fail cap. bin/triage-gate.sh
# answers `RUN daily-sweep` only when now - gate-meta >= FULL_SWEEP_SECS, so a
# board woken more often than once a day kept pushing its own clock forward and
# cromford had no daily sweep after 2026-09-24.
#
# THE PROPERTY. The clock is stamped only when the tick ran the full SOP
# (SCOPE_N=full; unset counts as full). A scoped tick (a shard dispatch, a
# queue slice, a board-changed diff) still absorbs gate.pending into gate.json
# and still mirrors the ledger row, but leaves gate-meta alone.
#
# Driven, not grepped: sections A-C run the REAL bin/run-triage.sh (with its real
# bin/lib/rt/*.sh stages and the real bin/triage-shard.sh) in a scratch harness,
# the tests/triage-fail-consume.bh-1021-test.sh fixture. The "does the daily
# sweep come back" half runs the REAL bin/triage-gate.sh against the same
# scratch state, with no force/wake/queue/results state, so it reaches step 4
# before any GitHub read (a gh stub that always fails backs that up).
# Run from anywhere: HARNESS_TEST_SANDBOX=1 bash tests/triage-full-sweep-clock.bh-2751-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
# bin/run-triage.sh resolves HARNESS as "${HARNESS:-/root/harness}", so an
# inherited HARNESS would make the scratch copy drive the LIVE harness.
unset HARNESS H HARNESS_CHECKOUT
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

P=project-5
export FLEET_CONF="$DIR/fleet.conf"
# ONE clock read for the whole suite (bin/test-determinism-lint.sh).
NOW=$(date +%s)
OLD=$((NOW - 90000))   # 25h ago: past the default FULL_SWEEP_SECS of 86400

# The real gate, copied once. It sources its libs from beside itself first, and
# every state path it reads is $HARNESS, so one copy serves every fixture.
mkdir -p "$T/realgate/bin" "$T/fakebin"
cp "$DIR/bin/triage-gate.sh" "$T/realgate/bin/triage-gate.sh"
cp -r "$DIR/bin/lib" "$T/realgate/bin/lib"
printf '#!/bin/sh\nexit 1\n' > "$T/fakebin/gh"; chmod +x "$T/fakebin/gh"

mkfixture() { # mkfixture <root> — a scratch harness running the REAL run-triage.sh
  local h="$1" s
  mkdir -p "$h/bin/lib/rt" "$h/logs" "$h/state" "$h/locks" "$h/env" "$h/flags" \
           "$h/prompts" "$h/builds" "$h/catalog" "$h/calls" "$h/fixture"
  . "$DIR/tests/lib/model-route-stub.sh" || exit 1; model_routes_fixture "$h" project-5 || exit 1
  : > "$h/env/global.env"
  : > "$h/logs/READY-QUEUE.log"
  echo "SOP for $P. Fetch the thread. Do the work." > "$h/prompts/$P.md"
  for s in run-triage.sh triage-shard.sh; do
    sed -e "s|/root/harness|$h|g" -e "s|/root/repos|$T/repos|g" "$DIR/bin/$s" > "$h/bin/$s"
    chmod +x "$h/bin/$s"
  done
  for s in "$DIR"/bin/lib/rt/*.sh; do
    sed -e "s|/root/harness|$h|g" -e "s|/root/repos|$T/repos|g" "$s" > "$h/bin/lib/rt/$(basename "$s")"
  done
  cp "$DIR/bin/lib/triage-shards-lib.sh" "$h/bin/lib/triage-shards-lib.sh"
  for s in fleet-conf.sh project-of.sh decision-log.sh queue-line-drop.sh; do
    ln -sf "$DIR/bin/$s" "$h/bin/$s"
  done
  printf '#!/bin/sh\necho box-project-5-1\n' > "$h/bin/box-name.sh"

  printf '{"issues":[{"number":561,"state":"OPEN","title":"a"}],"prs":[]}' > "$h/fixture/pending.json"
  printf 'OLD-BOARD-STATE' > "$h/state/$P.gate.json"
  echo "$OLD" > "$h/state/$P.gate-meta"
  : > "$h/fixture/diff"

  # The stub gate: writes the pending fingerprint where the real one does (unless
  # the fixture is the no-pending daily-sweep shape) and answers what it is told.
  cat > "$h/bin/triage-gate.sh" <<STUB
#!/bin/bash
PJ="\$1"; MODE="\${2:-}"
[ -e "$h/fixture/no-pending" ] || cp "$h/fixture/pending.json" "$h/state/\$PJ.gate.pending"
[ "\$MODE" = "--pending" ] && exit 0
cat "$h/fixture/gate-decision"
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
  printf '#!/bin/sh\nexit 0\n' > "$h/bin/lane-alert.sh"
  # agent-call.sh <stage> <project> <model> <timeout> <outfile> <prompt|@file>
  cat > "$h/bin/agent-call.sh" <<STUB
#!/bin/bash
: > "\$(mktemp "$h/calls/call-XXXXXXXX.txt")"
echo "tickets=1 triage ran" > "\$5"
exit 0
STUB
  chmod +x "$h/bin/agent-call.sh" "$h/bin/triage-gate.sh" "$h/bin/gate-diff.sh" \
           "$h/bin/unblocked-children.sh" "$h/bin/triage-contract.sh" \
           "$h/bin/beat.sh" "$h/bin/box-name.sh" "$h/bin/lane-alert.sh"
}

HR=""
tick()     { "$HR/bin/run-triage.sh" "$P" >/dev/null 2>&1; }
ncalls()   { ls "$HR/calls"/call-* 2>/dev/null | wc -l | tr -d ' '; }
meta()     { cat "$HR/state/$P.gate-meta" 2>/dev/null; }
realgate() { ( export HARNESS="$HR" PATH="$T/fakebin:$PATH"; "$T/realgate/bin/triage-gate.sh" "$P" 2>/dev/null ); }
held() { # held <lockfile> -> 0 when some other process holds it
  [ -e "$1" ] || return 1
  if ( exec 9>"$1" || exit 0; flock -n 9 || exit 1 ) 2>/dev/null; then return 1; fi
  return 0
}
settle() { # settle <calls> — wait for detached shards to land and release their locks
  local i=0 busy L
  while [ "$i" -lt 80 ]; do
    if [ "$(ncalls)" -ge "$1" ]; then
      busy=0
      for L in "$HR"/locks/triage-key-*.lock; do held "$L" && busy=1; done
      [ "$busy" = 0 ] && { sleep 1; return 0; }
    fi
    i=$((i+1)); sleep 0.25
  done
  return 1
}
absorbed() { # (d) gate.pending gone, gate.json == the fixture's pending content
  [ ! -e "$HR/state/$P.gate.pending" ] && cmp -s "$HR/fixture/pending.json" "$HR/state/$P.gate.json"
}

# ---------- A. a sharded event-wake (shards.sh path) -------------------------
HR="$T/a"; mkfixture "$HR"
echo "RUN event-wake" > "$HR/fixture/gate-decision"
echo 561 > "$HR/state/wake-keys-$P"
printf 'board issues: CHANGED 561 "a" (comments: 1 -> 2)\n' > "$HR/fixture/diff"
tick
settle 1 || bad "A: the shard did not land"
# A0 — the control: exactly one paid session, and it was a shard dispatch.
[ "$(ncalls)" = 1 ] && ok || bad "A0: expected 1 shard session, got $(ncalls) — this section proves nothing"
grep -q "dispatched 1 shards:.*scope=1 " "$HR/logs/$P.log" && ok \
  || bad "A0: the tick must be a 1-key shard dispatch (scope=1): $(grep -v '^$' "$HR/logs/$P.log" | tail -3)"
# A1 — the fix: the scoped tick left the 25h-old clock alone.
[ "$(meta)" = "$OLD" ] && ok \
  || bad "A1: a sharded scoped tick restamped $P.gate-meta ($OLD -> $(meta)) — the daily sweep can never fire"
# A2 (d) — and it still consumed the fingerprint.
absorbed && ok || bad "A2: the shard dispatch must absorb gate.pending into gate.json (got: $(cat "$HR/state/$P.gate.json" 2>/dev/null))"
# A3 — the whole point: the real gate answers the daily sweep.
OUT=$(realgate)
[ "$OUT" = "RUN daily-sweep" ] && ok || bad "A3: after a scoped tick the real gate must answer RUN daily-sweep, got '$OUT'"

# ---------- B. a queue-pending single session (launch.sh path) ---------------
HR="$T/b"; mkfixture "$HR"
: > "$HR/flags/triage-shards-off"
echo "RUN queue-pending" > "$HR/fixture/gate-decision"
echo "TK-561 waiting on PR #9 to merge" > "$HR/logs/READY-QUEUE.log"
tick
[ "$(ncalls)" = 1 ] && ok || bad "B0: expected 1 session, got $(ncalls) — this section proves nothing"
grep -q "gate=queue-pending scope=queue " "$HR/logs/$P.log" && ok \
  || bad "B0: the tick must run the queue scope (scope=queue): $(grep -v '^$' "$HR/logs/$P.log" | tail -3)"
[ "$(meta)" = "$OLD" ] && ok \
  || bad "B1: a queue-scoped rc=0 tick restamped $P.gate-meta ($OLD -> $(meta))"
absorbed && ok || bad "B2: the queue tick must absorb gate.pending into gate.json"

# ---------- B2. a board-changed diff, single session -------------------------
HR="$T/b2"; mkfixture "$HR"
: > "$HR/flags/triage-shards-off"
echo "RUN board-changed" > "$HR/fixture/gate-decision"
printf 'board issues: CHANGED 561 "a" (comments: 1 -> 2)\n' > "$HR/fixture/diff"
tick
[ "$(ncalls)" = 1 ] && ok || bad "B2.0: expected 1 session, got $(ncalls)"
grep -q "gate=board-changed scope=1 " "$HR/logs/$P.log" && ok \
  || bad "B2.0: the tick must run a 1-line board scope (scope=1): $(grep -v '^$' "$HR/logs/$P.log" | tail -3)"
[ "$(meta)" = "$OLD" ] && ok \
  || bad "B2.1: a board-changed scoped tick restamped $P.gate-meta ($OLD -> $(meta))"
absorbed && ok || bad "B2.2: the board-changed tick must absorb gate.pending into gate.json"
OUT=$(realgate)
[ "$OUT" = "RUN daily-sweep" ] && ok || bad "B2.3: the real gate must still answer RUN daily-sweep, got '$OUT'"

# ---------- C. a full daily-sweep tick DOES restamp ---------------------------
HR="$T/c"; mkfixture "$HR"
: > "$HR/flags/triage-shards-off"
: > "$HR/fixture/no-pending"
echo "RUN daily-sweep" > "$HR/fixture/gate-decision"
tick
[ "$(ncalls)" = 1 ] && ok || bad "C0: expected 1 session, got $(ncalls)"
grep -q "gate=daily-sweep scope=full " "$HR/logs/$P.log" && ok \
  || bad "C0: the tick must run the full SOP (scope=full): $(grep -v '^$' "$HR/logs/$P.log" | tail -3)"
M=$(meta)
case "$M" in
  ''|*[!0-9]*) bad "C1: a full tick must stamp $P.gate-meta with an epoch (got '$M')" ;;
  *) [ $((M - NOW)) -ge -5 ] && [ $((M - NOW)) -le 120 ] && ok \
       || bad "C1: a full tick must restamp $P.gate-meta to now (got $M, suite started $NOW)" ;;
esac
OUT=$(realgate)
[ "$OUT" != "RUN daily-sweep" ] && ok || bad "C2: right after a full sweep the real gate must not answer daily-sweep again"

# ---------- F/G. the function itself -----------------------------------------
# F — SCOPE_N unset counts as full: a bare caller keeps today's stamp.
G="$T/f"; mkdir -p "$G/state"
printf 'PENDING-FP' > "$G/state/$P.gate.pending"
( unset SCOPE_N; HARNESS="$G" PROJECT="$P"; . "$DIR/bin/lib/rt/gate.sh"; rt_gate_consume ) >/dev/null 2>&1
case "$(cat "$G/state/$P.gate-meta" 2>/dev/null)" in
  ''|*[!0-9]*) bad "F: rt_gate_consume with SCOPE_N unset must stamp gate-meta (unset = full)" ;;
  *) ok ;;
esac
# G — a scoped consume still mirrors the ledger row (tgl_put_gate once), still
# absorbs, does not stamp, and returns 0.
G="$T/g"; mkdir -p "$G/state"
printf 'PENDING-FP' > "$G/state/$P.gate.pending"
echo "$OLD" > "$G/state/$P.gate-meta"
( SCOPE_N=3 HARNESS="$G" PROJECT="$P"
  tgl_put_gate() { echo "put $*" >> "$G/tgl-calls"; }
  . "$DIR/bin/lib/rt/gate.sh"; rt_gate_consume; echo "rc=$?" > "$G/rc" ) >/dev/null 2>&1
[ "$(grep -c '^put ' "$G/tgl-calls" 2>/dev/null)" = 1 ] && ok || bad "G1: a scoped consume must call tgl_put_gate once (calls: $(cat "$G/tgl-calls" 2>/dev/null))"
[ "$(cat "$G/state/$P.gate.json" 2>/dev/null)" = PENDING-FP ] && [ ! -e "$G/state/$P.gate.pending" ] && ok \
  || bad "G2: a scoped consume must still absorb gate.pending"
[ "$(cat "$G/state/$P.gate-meta")" = "$OLD" ] && ok || bad "G3: a scoped consume must not stamp gate-meta"
[ "$(cat "$G/rc" 2>/dev/null)" = rc=0 ] && ok || bad "G4: a scoped consume must return 0 (got $(cat "$G/rc" 2>/dev/null))"

echo "pass=$PASS fail=$FAIL"
[ "$FAIL" -eq 0 ]
