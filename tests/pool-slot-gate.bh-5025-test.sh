#!/bin/bash
# tests/pool-slot-gate.bh-5025-test.sh — A POOL MACHINE NEVER DEFERS ON A LEFTOVER SLOT LOCK.
#
# BH-5046 (BH-5025.1). fly/entrypoint.sh writes flags/build-slots=1 on every
# machine, so bin/lib/build-caps.sh:build_slots answered 1 and the
# `# >>> build slots` block of bin/lib/rb/gates.sh took locks/build-slot-1.lock
# with `flock -n`. On a reused pool machine a process left over from the
# previous job still held that fd, and the next job answered
# `BUILD_DEFERRED all 1 slots busy` (2026-10-06 23:43Z and 2026-10-07 00:05Z).
# docs/BUILD-CONCURRENCY.md already said the pool route ignores BUILD_SLOTS.
#
# WHAT IS PROVEN HERE, driven for real: the block is lifted out of the
# flattened pipeline by its markers and run with a background process holding
# slot 1.
#   P1 POOL_MODE=1 + BUILDER_EXEC=1 passes the held slot, one `slot gate
#      skipped` line, no `overridden` line.
#   P2 a watcher box (no pool env) still defers.
#   P3 POOL_MODE=1 without BUILDER_EXEC=1 still defers.
#   P4 a watcher box with BUILD_SLOTS=2 takes slot 2.
#   P5 a dedicated builder (BUILDER_EXEC=1, no POOL_MODE) still defers.
#   P6 BUILD_SLOTS=0 on a pool machine logs nothing; off the pool the
#      `overridden` line is still written exactly once.
#
# Run from anywhere: tests/pool-slot-gate.bh-5025-test.sh   (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
. "$(dirname "$0")/lib/wait-for.sh" || exit 1  # BH-6049: wait_holder, not a fixed sleep
DIR=$(cd "$(dirname "$0")/.." && pwd)
. "$DIR/tests/lib/rb-all.sh" || exit 1
RB_ALL=$(rb_all "$DIR" "$T/run-build.all.sh")
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

mkdir -p "$T/h/locks" "$T/h/env" "$T/h/flags" "$T/b"
scratch_install_closure bin/lib/build-caps.sh "$T/h" >/dev/null \
  || { echo "FAIL: could not install bin/lib/build-caps.sh into the scratch harness"; exit 1; }
awk '/^# >>> build slots/{f=1;next} /^# <<< build slots/{exit} f' "$RB_ALL" > "$T/slots.sh"
[ -s "$T/slots.sh" ] && ok || bad "could not extract the build-slots gate — markers missing?"
: > "$T/h/env/global.env"
echo 1 > "$T/h/flags/build-slots"

gate() { # gate [VAR=val...] — prints PASSED slot=<n|none>, or nothing when it deferred
  rm -f "$T/RESULT"; : > "$T/b/pipeline.log"
  ( env -u BUILD_SLOTS -u POOL_MODE -u BUILDER_EXEC -u HOTFIX \
      HARNESS="$T/h" BUILD="$T/b" PROJECT=widget-os KEY=WD-9 "$@" \
    bash -c 'set -uo pipefail
             STAMP() { echo TS; }
             RESULT() { echo "$*" > "'"$T"'/RESULT"; }
             . "$0"; echo "PASSED slot=${GOT:-none}"' "$T/slots.sh" 2>&1 )
}
deferred() { grep -q '^BUILD_DEFERRED all 1 slots busy' "$T/RESULT" 2>/dev/null; }
skips()    { grep -c 'slot gate skipped' "$T/b/pipeline.log"; }
overs()    { grep -c 'overridden' "$T/b/pipeline.log"; }

if ! command -v flock >/dev/null 2>&1; then
  echo "SKIP: flock is not installed, the held-slot cases P1-P6 cannot run"
  echo "pool-slot-gate.bh-5025: $PASS pass, $FAIL fail"
  [ "$FAIL" -eq 0 ]; exit
fi

( exec 9>"$T/h/locks/build-slot-1.lock"; flock 9; exec sleep 30 ) &
HOLDER=$!
trap 'kill "$HOLDER" 2>/dev/null; wait "$HOLDER" 2>/dev/null' EXIT
wait_holder "$HOLDER"

# P1. pool machine passes a held slot, says so once, and never says overridden.
S=$(date +%s); OUT=$(gate POOL_MODE=1 BUILDER_EXEC=1); E=$(date +%s)
grep -q 'PASSED slot=none' <<<"$OUT" \
  && ok || bad "P1 a pool machine must pass a held slot without taking one (got: $OUT; RESULT: $(cat "$T/RESULT" 2>/dev/null))"
[ -e "$T/RESULT" ] && bad "P1 a pool machine must write no RESULT (got: $(cat "$T/RESULT"))" || ok
[ "$(skips)" = 1 ] && ok || bad "P1 want exactly one 'slot gate skipped' line, got $(skips)"
grep -qF 'TS [widget-os/WD-9] build slots: pool machine (POOL_MODE=1)' "$T/b/pipeline.log" \
  && ok || bad "P1 the skip line must carry the STAMP [PROJECT/KEY] prefix and name POOL_MODE"
grep -qF '(BUILD_SLOTS=1 not applied)' "$T/b/pipeline.log" \
  && ok || bad "P1 the skip line must name the slot count it did not apply"
[ "$(overs)" = 0 ] && ok || bad "P1 a pool build must not also log the 'overridden' line"
# BH-6049: the holder keeps the slot for 30 s, so a gate that waited would take
# 30 s; 8 s leaves room for a loaded runner and still catches that.
[ "$((E - S))" -le 8 ] && ok || bad "P1 the gate took $((E - S))s"

# P2. control: a watcher box with the same holder still defers.
OUT=$(gate)
grep -q PASSED <<<"$OUT" && bad "P2 a watcher box must not pass a held slot (got: $OUT)" || ok
deferred && ok || bad "P2 want BUILD_DEFERRED all 1 slots busy (got: $(cat "$T/RESULT" 2>/dev/null))"
[ "$(skips)" = 0 ] && ok || bad "P2 a watcher box must not log a skip"

# P3. POOL_MODE alone is not a pool build.
OUT=$(gate POOL_MODE=1)
deferred && ok || bad "P3 POOL_MODE=1 without BUILDER_EXEC=1 must still defer (got: $OUT)"
[ "$(skips)" = 0 ] && ok || bad "P3 POOL_MODE=1 without BUILDER_EXEC=1 must not log a skip"

# P4. a watcher box with a real cap takes the free slot.
printf 'BUILD_SLOTS=2\n' > "$T/h/env/global.env"
OUT=$(gate)
grep -q 'PASSED slot=2' <<<"$OUT" && ok || bad "P4 BUILD_SLOTS=2 with slot 1 held must take slot 2 (got: $OUT)"
[ "$(skips)" = 0 ] && ok || bad "P4 a watcher box must not log a skip"
: > "$T/h/env/global.env"

# P5. a dedicated (non-pool) builder keeps the gate.
OUT=$(gate BUILDER_EXEC=1)
deferred && ok || bad "P5 BUILDER_EXEC=1 without POOL_MODE=1 must still defer (got: $OUT)"
[ "$(skips)" = 0 ] && ok || bad "P5 a dedicated builder must not log a skip"

# P6. BUILD_SLOTS=0 on a pool machine: nothing applied, nothing logged.
printf 'BUILD_SLOTS=0\n' > "$T/h/env/global.env"
OUT=$(gate POOL_MODE=1 BUILDER_EXEC=1)
grep -q 'PASSED slot=none' <<<"$OUT" && ok || bad "P6 BUILD_SLOTS=0 must pass (got: $OUT)"
[ "$(skips)" = 0 ] && ok || bad "P6 BUILD_SLOTS=0 must not log a skip"
[ "$(overs)" = 0 ] && ok || bad "P6 a pool build must not log 'overridden'"
OUT=$(gate)
[ "$(overs)" = 1 ] && ok || bad "P6 off the pool the 'overridden' line must still be written once, got $(overs)"
: > "$T/h/env/global.env"

echo "pool-slot-gate.bh-5025: $PASS pass, $FAIL fail"
[ "$FAIL" -eq 0 ]
