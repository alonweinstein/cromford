#!/bin/bash
# tests/build-slot-gate-early.bh-5021-test.sh — a build that cannot have a slot
# is refused before anything expensive runs, and a hotfix gets one extra slot
# (BH-5021).
#
#   G1  pool runner, slot held by something the cleaner may not kill: the REAL
#       _run_job (lifted from fly/builder-runner.sh) answers
#       `BUILD_DEFERRED all 1 slots busy — slot held on this machine …` with
#       zero calls on warm_up, gh, git, run-build.sh, agent-call.sh and claude,
#       one cleaner call, and no 60s hang-guard timeout (BH-5292: no seconds)
#   G2  the same runner on a clean machine: warm_up, then run-build.sh
#   G3  a hotfix job on G1's dirty machine goes on to run-build.sh with HOTFIX=1
#   G4  run-build's order, driven: the real `# >>> build slots` block followed by
#       the real claim-and-workspace body refuses with rc 3 and makes no
#       `git worktree` and no agent call; in the flattened pipeline the
#       trigger-actor gate and the slot gate both sit above the first checkout
#       and the first agent call
#   G5  hotfix + every slot held -> takes slot SLOTS+1, logs it
#   G6  a plain build never opens the extra slot
#   G7  one extra slot only: when it is held too, the hotfix defers
#   G8  on a pool machine (BUILDER_EXEC=1) the refusal says the machine is dirty
# Run from anywhere: bash tests/build-slot-gate-early.bh-5021-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
# A pool build runs this suite with its own HOTFIX=1 / BUILDER_EXEC=1 /
# POOL_MODE=1 in the environment; every case here sets the ones it means
# (POOL_MODE+BUILDER_EXEC skip the slot gate, BH-5046).
unset HOTFIX BUILDER_EXEC POOL_MODE
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v flock >/dev/null 2>&1 || { echo "build-slot-gate-early.bh-5021: flock absent — skipping"; exit 0; }
command -v jq >/dev/null 2>&1 || { echo "build-slot-gate-early.bh-5021: jq absent — skipping"; exit 0; }
. "$DIR/tests/lib/rb-all.sh" || exit 1
RB_ALL=$(rb_all "$DIR" "$T/run-build.all.sh") || { echo "could not flatten the pipeline"; exit 1; }

HOLDERS=()
trap 'for p in "${HOLDERS[@]:-}"; do [ -n "$p" ] && kill -9 "$p" 2>/dev/null; done' EXIT
# hold <lock> -> starts a background holder, sets HP; the trap reaps it
hold() {
  ( exec 9>"$1"; flock 9; exec sleep 300 ) </dev/null >/dev/null 2>&1 &  # determinism: ok a slot holder, killed by drop or the EXIT trap
  HP=$!; HOLDERS+=("$HP")
  local i=0; while flock -n "$1" true && [ "$i" -lt 50 ]; do sleep 0.1; i=$((i+1)); done  # determinism: ok bounded wait for the holder's flock, 5s cap
}
drop() { kill -9 "$1" 2>/dev/null; wait "$1" 2>/dev/null; }

# ═══ G1-G3 the pool runner ═══════════════════════════════════════════════════
H="$T/h"
mkdir -p "$H/locks" "$H/logs" "$H/bin" "$H/builds" "$T/path" "$T/job"
scratch_install_closure bin/pool-slot-clean.sh "$H" >/dev/null 2>&1 || bad "bin/pool-slot-clean.sh could not be installed into the scratch harness"
# The cleaner, counted: a wrapper records each call (and sleeps
# WALLCLOCK_STUB_SLEEP_S, the slowed run tests/gates-to-reports.bh-5292-test.sh
# R6 drives), then runs the real one.
mv "$H/bin/pool-slot-clean.sh" "$H/bin/pool-slot-clean.real.sh"
printf '#!/bin/bash\necho cleaner >> "%s/cleaner-calls"\nsleep "${WALLCLOCK_STUB_SLEEP_S:-0}"\nexec "%s/bin/pool-slot-clean.real.sh" "$@"\n' "$T" "$H" > "$H/bin/pool-slot-clean.sh"
chmod +x "$H/bin/pool-slot-clean.sh"
awk '/^slot_preflight\(\) \{/,/^\}/' "$DIR/fly/builder-runner.sh" > "$T/runner.sh"
grep -q 'pool-slot-clean' "$T/runner.sh" && ok || bad "G1: could not extract slot_preflight from fly/builder-runner.sh"
awk '/^_run_job\(\) \{/,/^\}/' "$DIR/fly/builder-runner.sh" >> "$T/runner.sh"
grep -q 'warm_up' "$T/runner.sh" && ok || bad "G1: could not extract _run_job from fly/builder-runner.sh"
for f in "$H/bin/agent-call.sh" "$T/path/claude" "$T/path/gh" "$T/path/git"; do
  printf '#!/bin/bash\necho "%s $*" >> "%s/called"\nexit 0\n' "$(basename "$f")" "$T" > "$f"; chmod +x "$f"
done
printf '#!/bin/bash\necho "run-build.sh HOTFIX=${HOTFIX:-} $*" >> "%s/called"\nexit 0\n' "$T" > "$H/bin/run-build.sh"
chmod +x "$H/bin/run-build.sh"

# runner <job-json> [hold-slot 0|1] -> RESULT, RRC (124 = the 60s hang guard
# fired), $T/called, $T/cleaner-calls
runner() {
  rm -f "$T/called" "$T/cleaner-calls" "$T/job/RESULT"; printf '%s\n' "$1" > "$T/job/job.json"
  timeout 60 env PATH="$T/path:$PATH" HARNESS="$H" JOB="$T/job/job.json" JOBDIR="$T/job" RESULT_FILE="$T/job/RESULT" \
      PROJECT=proj REPO="$T/repo" POOL_SLOT_CLEAN_GRACE_S=1 HOLDSLOT="${2:-0}" LOCKF="$H/locks/build-slot-1.lock" \
      bash -c '
    log() { :; }; load_env() { :; }; model_routes_warm() { :; }
    start_heartbeat() { :; }; stop_heartbeat() { :; }; beat() { :; }; fly_result_put() { :; }
    warm_up() { echo warm_up >> "'"$T"'/called"; return 0; }
    # The runner shell itself holds the slot: the cleaner never kills its own
    # ancestor, so this is a holder it cannot clear.
    [ "$HOLDSLOT" = 1 ] && { exec 8>"$LOCKF"; flock 8; }
    . "$0"; _run_job' "$T/runner.sh" >/dev/null 2>&1
  RRC=$?
  RESULT=$(head -1 "$T/job/RESULT" 2>/dev/null)
}
cleaner_calls() { grep -c . "$T/cleaner-calls" 2>/dev/null || echo 0; }

runner '{"key":"BH-9","ticket_id":"9"}' 1
[[ "$RESULT" == "BUILD_DEFERRED all 1 slots busy — slot held on this machine"* ]] && ok \
  || bad "G1: a held slot must defer before warm-up, got RESULT '$RESULT'"
[ ! -s "$T/called" ] && ok || bad "G1: an expensive step ran before the refusal: $(tr '\n' '|' < "$T/called" 2>/dev/null)"
# TEST-CHANGE BH-5292: was `ELAPSED -le 3` (grace 1s + 2s). the operator changed the
# rule (2026-10-07): no wall-clock asserts. The refusal is proved BOUNDED by work
# done: it returned on its own (not the 60s hang guard, rc 124), the cleaner ran
# exactly ONCE (no wait-and-retry loop on the held slot), and nothing expensive
# ran (the check above). A slowed cleaner still passes; a preflight that loops
# on the cleaner or waits for the slot fails here.
[ "$RRC" != 124 ] && ok || bad "G1: the refusal never returned — the 60s hang guard fired"
[ "$(cleaner_calls)" = 1 ] && ok || bad "G1: the cleaner must run exactly once before the refusal, ran $(cleaner_calls) time(s)"

runner '{"key":"BH-9","ticket_id":"9"}' 0
[ "$(tr '\n' '|' < "$T/called" 2>/dev/null | sed -E 's/run-build\.sh [^|]*/run-build.sh/')" = "warm_up|run-build.sh|" ] && ok \
  || bad "G2: a clean machine must warm up and then run the build: $(tr '\n' '|' < "$T/called" 2>/dev/null)"
[[ "$RESULT" == BUILD_DEFERRED* ]] && bad "G2: a clean machine deferred: $RESULT" || ok

runner '{"key":"BH-9","ticket_id":"9","hotfix":true}' 1
grep -q '^run-build.sh HOTFIX=1 proj 9 BH-9' "$T/called" 2>/dev/null && ok \
  || bad "G3: a hotfix on a dirty machine must reach run-build.sh with HOTFIX=1: $(tr '\n' '|' < "$T/called" 2>/dev/null)"
[[ "$RESULT" == *"slot held on this machine"* ]] && bad "G3: the hotfix was refused at the preflight: $RESULT" || ok

# ═══ G5-G8 the slot gate itself ══════════════════════════════════════════════
G="$T/g"
mkdir -p "$G/locks" "$G/env" "$T/b"
scratch_install_closure bin/lib/build-caps.sh "$G" >/dev/null || { echo "closure install failed"; exit 1; }
awk '/^# >>> build slots/{f=1;next} /^# <<< build slots/{exit} f' "$RB_ALL" > "$T/slots.sh"
[ -s "$T/slots.sh" ] && ok || bad "could not extract the build-slots gate"
# gate [env...] -> OUT (PASSED slot=N | nothing), RC, $T/RESULT; the gate's
# shell reports whether it still holds the slot it took before it exits
gate() {
  rm -f "$T/RESULT" "$T/b/pipeline.log"
  OUT=$( env HARNESS="$G" BUILD="$T/b" PROJECT=proj KEY=BH-9 BUILD_SLOTS=1 "$@" \
    bash -c 'set -uo pipefail; STAMP() { echo TS; }; RESULT() { echo "$*" > "'"$T"'/RESULT"; }
             . "$0"; echo "PASSED slot=${GOT:-none}"
             [ -n "${GOT:-}" ] && ! flock -n "$HARNESS/locks/build-slot-$GOT.lock" true && echo "HOLDS slot=$GOT"' "$T/slots.sh" 2>&1 )
  RC=$?
}

hold "$G/locks/build-slot-1.lock"; H1=$HP
gate HOTFIX=1
grep -qx 'PASSED slot=2' <<<"$OUT" && ok || bad "G5: a hotfix with every slot held must take slot 2 (rc=$RC out=$OUT result=$(cat "$T/RESULT" 2>/dev/null))"
grep -qx 'HOLDS slot=2' <<<"$OUT" && ok || bad "G5: the gate's shell must hold build-slot-2.lock: $OUT"
[ -e "$T/RESULT" ] && bad "G5: the hotfix wrote a RESULT: $(cat "$T/RESULT")" || ok
grep -q 'hotfix: all 1 slots busy, taking extra slot 2 for BH-9' "$T/b/pipeline.log" 2>/dev/null && ok \
  || bad "G5: the extra slot was not logged: $(cat "$T/b/pipeline.log" 2>/dev/null)"

rm -f "$G/locks/build-slot-2.lock"
gate HOTFIX=
[ "$RC" = 3 ] && ok || bad "G6: a plain build with every slot held must exit 3 (rc=$RC out=$OUT)"
[ "$(cat "$T/RESULT" 2>/dev/null)" = "BUILD_DEFERRED all 1 slots busy" ] && ok || bad "G6: RESULT must be exactly 'BUILD_DEFERRED all 1 slots busy', got '$(cat "$T/RESULT" 2>/dev/null)'"
[ -e "$G/locks/build-slot-2.lock" ] && bad "G6: a plain build opened the hotfix slot" || ok

hold "$G/locks/build-slot-2.lock"; H2=$HP
gate HOTFIX=1
[ "$RC" = 3 ] && ok || bad "G7: with the hotfix slot held too the build must exit 3 (rc=$RC out=$OUT)"
[ "$(cat "$T/RESULT" 2>/dev/null)" = "BUILD_DEFERRED all 1 slots busy and the hotfix slot is held" ] && ok \
  || bad "G7: got '$(cat "$T/RESULT" 2>/dev/null)'"
[ -e "$G/locks/build-slot-3.lock" ] && bad "G7: the hotfix tried a third slot" || ok
drop "$H2"

gate BUILDER_EXEC=1
[ "$RC" = 3 ] && ok || bad "G8: rc=$RC"
[[ "$(cat "$T/RESULT" 2>/dev/null)" == "BUILD_DEFERRED all 1 slots busy"*"slot held on this machine"* ]] && ok \
  || bad "G8: on a pool machine the refusal must say the machine is dirty, got '$(cat "$T/RESULT" 2>/dev/null)'"
gate
[ "$(cat "$T/RESULT" 2>/dev/null)" = "BUILD_DEFERRED all 1 slots busy" ] && ok \
  || bad "G8: off the pool the wording must stay exact, got '$(cat "$T/RESULT" 2>/dev/null)'"

# ═══ G4 run-build: refused before any checkout or agent call ═════════════════
# Driven: the real slot block, then the real claim-and-workspace body that
# would `git worktree add`, with git and agent-call.sh recording on PATH.
awk '/^rb_gate_claim_and_workspace\(\) \{/{f=1;next} /^\} # end rb_gate_claim_and_workspace/{exit} f' "$DIR/bin/lib/rb/gates.sh" > "$T/claim.sh"
grep -q 'worktree add' "$T/claim.sh" && ok || bad "G4: could not extract rb_gate_claim_and_workspace (or it no longer adds a worktree)"
cat "$T/slots.sh" "$T/claim.sh" > "$T/g4.sh"
rm -f "$T/called"; mkdir -p "$T/wt"
OUT=$( env PATH="$T/path:$PATH" HARNESS="$G" BUILD="$T/b" PROJECT=proj KEY=BH-9 BUILD_SLOTS=1 REPO="$T/repo" \
  bash -c 'STAMP() { echo TS; }; RESULT() { echo "$*" > "'"$T"'/RESULT"; }
           . "$0"; echo REACHED-CHECKOUT' "$T/g4.sh" 2>&1 ); RC=$?
[ "$RC" = 3 ] && ok || bad "G4: run-build's slot gate must exit 3 (rc=$RC)"
[ "$(cat "$T/RESULT" 2>/dev/null)" = "BUILD_DEFERRED all 1 slots busy" ] && ok || bad "G4: RESULT '$(cat "$T/RESULT" 2>/dev/null)'"
grep -q REACHED-CHECKOUT <<<"$OUT" && bad "G4: the claim-and-workspace body ran after a refused slot" || ok
[ ! -s "$T/called" ] && ok || bad "G4: git/agent stubs were called: $(tr '\n' '|' < "$T/called" 2>/dev/null)"
drop "$H1"
# ...and the order in the whole pipeline text: both gates above the first
# checkout and the first agent call.
ln_of() { grep -n -m1 -- "$1" "$RB_ALL" | cut -d: -f1; }
TA=$(ln_of '^# >>> trigger actor gate'); SL=$(ln_of '^# >>> build slots')
WT=$(ln_of 'git worktree add'); AC=$(ln_of 'agent-call.sh"')
if [ -n "$TA" ] && [ -n "$SL" ] && [ -n "$WT" ] && [ -n "$AC" ] && [ "$TA" -lt "$SL" ] && [ "$SL" -lt "$WT" ] && [ "$SL" -lt "$AC" ]; then ok
else bad "G4: order trigger-actor(${TA:-?}) < slots(${SL:-?}) < first worktree add(${WT:-?}) / first agent call(${AC:-?}) broken"; fi

echo "build-slot-gate-early.bh-5021: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
