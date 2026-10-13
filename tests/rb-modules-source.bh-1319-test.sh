#!/bin/bash
# reads-run-build: raw — the one-copy pin asserts the driver's own text carries none of the four units (each lives once in its stage module since the BH-572 cut); the flatten puts the module's copy back in the driver's place, so only a raw read can see a second copy pasted into the driver.
# tests/rb-modules-source.bh-1319-test.sh — BH-1319: the four checkpoint units
# this ticket edited live in exactly ONE place.
#
# WHY THIS EXISTS. Four of the pipeline's checkpoint units (CKPT_SQUASH_WIP and
# the `lane checkpoints`, `checkpoint adopt` and `execute result` marker blocks)
# used to live twice: inline in bin/run-build.sh (the copy that ran) and in the
# dark stage module under bin/lib/rb/ that would replace it at cutover. BH-1310
# and BH-1319 edited both copies by hand, and this suite pinned them
# byte-identical. The BH-572 cut deleted the inline copies, so that drift is now
# impossible — and the pin says so rather than going red: each unit is ABSENT
# from the raw driver, present exactly ONCE in its module, and present exactly
# once in the pipeline the driver runs (the flatten, tests/lib/rb-all.sh).
#
# The module extraction is guarded against being EMPTY, so a renamed marker or a
# deleted function fails loudly instead of counting nothing (D3).
#
# Run from anywhere. No network, no clock, no git, no LLM.
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
. "$DIR/tests/lib/rb-all.sh" || exit 1
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

DRIVER="$DIR/bin/run-build.sh"
RB_ALL=$(rb_all "$DIR" "$T/run-build.all.sh") || { echo "FAIL: rb_all could not flatten bin/run-build.sh"; exit 1; }

# one_copy <label> <opening-line ERE> <module-path> <extracted-body-file>
one_copy() {
  local label="$1" re="$2" mod="$3" body="$4" nd nm na
  nd=$(grep -cE "$re" "$DRIVER"); nm=$(grep -cE "$re" "$DIR/$mod"); na=$(grep -cE "$re" "$RB_ALL")
  [ "$nd" = 0 ] && ok \
    || bad "$label: bin/run-build.sh carries its own copy again ($nd) — a second copy is the drift the BH-572 cut removed"
  [ "$nm" = 1 ] && [ -s "$body" ] && ok \
    || bad "$label: $mod must hold it exactly once with a non-empty body (found $nm, body $(wc -l < "$body") line(s)) — renamed or deleted?"
  [ "$na" = 1 ] && ok \
    || bad "$label: the pipeline (flatten) must run it exactly once (found $na)"
}

# --- P1. the CKPT_SQUASH_WIP body, in bin/lib/rb/plan.sh ---------------------
# The function opens at column 0 and closes at the next column-0 `}`.
cut_fn() { # cut_fn <function-name> <file> <outfile>
  awk -v n="$1" 'index($0,n"() {")==1 {f=1; next} f && index($0,"}")==1 {exit} f' \
    "$2" > "$3"
}
cut_fn CKPT_SQUASH_WIP "$DIR/bin/lib/rb/plan.sh" "$T/sq.plan"
one_copy "P1: CKPT_SQUASH_WIP" '^CKPT_SQUASH_WIP\(\) \{' bin/lib/rb/plan.sh "$T/sq.plan"

# --- P2-P4. the three marker blocks this ticket edited -----------------------
cut_block() { # cut_block <marker-word...> <file> <outfile>
  awk -v n="$1" 'index($0,"# >>> " n)==1{f=1;next} index($0,"# <<< " n)==1{exit} f' \
    "$2" > "$3"
}
pin_block() { # pin_block <marker> <module-path>
  local name="$1" mod="$2"
  cut_block "$name" "$DIR/$mod" "$T/blk.mod"
  one_copy "the '$name' block" "^# >>> $name" "$mod" "$T/blk.mod"
}
pin_block "lane checkpoints" bin/lib/rb/plan.sh
pin_block "checkpoint adopt" bin/lib/rb/gates.sh
pin_block "execute result"   bin/lib/rb/execute.sh

# --- P5. this suite is a declared raw reader ---------------------------------
# tests/rb-modules-source-test.sh case (f) requires both halves; asserted here
# too so the pair is visible from the suite that needs it.
SELF=$(basename "$0")
grep -q '^# reads-run-build: raw' "$DIR/tests/$SELF" \
  && ok || bad "P5: this suite reads the driver raw and must declare it in its header"
[ -s "$DIR/tests/rb-raw-readers-baseline/$SELF.txt" ] \
  && ok || bad "P5: a raw reader needs its registry entry tests/rb-raw-readers-baseline/$SELF.txt"

echo "rb-modules-source.bh-1319-test: $PASS pass, $FAIL fail"
[ "$FAIL" -eq 0 ]
