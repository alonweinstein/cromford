#!/bin/bash
# tests/ci-verdicts-test.sh — bin/ci-verdicts.sh: the two fan-in checks read
# ONE traced run's verdict files and each judges only its own lane.
#
# WHY (CI cost cut, 2026-09-24). `Pure-logic gate fixtures` and `Tests cannot
# touch a real harness` used to fan in two separate 8-shard matrices by
# `needs.<job>.result`. Now one matrix runs the corpus once under the tracer
# (bin/test-trace-safety.sh --gate) and writes shard-<i>.txt with both
# verdicts. The check names are what Mergify and the merge conductor gate on, so
# each must still mean exactly its old thing:
#   - a failing test with a clean trace turns `pure` red and leaves `trace` green;
#   - a hit with passing tests turns `trace` red and leaves `pure` green;
#   - a shard that wrote NO verdict (infra step died, cancelled, rc 2 scan) is
#     red for BOTH — "did not run" is never a pass;
#   - the plan job failing is red for both;
#   - the shards together must have run exactly the suites the plan selected:
#     a split that dropped suites looks exactly like a fast green.
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
V="$DIR/bin/ci-verdicts.sh"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
has() { case "$2" in *"$1"*) return 0 ;; esac; return 1; }

vfile() { # <dir> <i> <tests> <failed> <hits>
  mkdir -p "$1"
  local pure=pass trace=clean
  [ "$4" -eq 0 ] || pure=fail
  [ "$5" -eq 0 ] || trace=dirty
  printf 'tests=%s\nfailed=%s\nhits=%s\npure=%s\ntrace=%s\n' "$3" "$4" "$5" "$pure" "$trace" > "$1/shard-$2.txt"
}
judge() { # judge <lane> <dir> <n> <count> [PLAN_RESULT] — sets RC and OUT
  OUT=$(PLAN_RESULT="${5:-success}" "$V" "$1" "$2" "$3" "$4" 2>&1); RC=$?
}

# ── V1. all green: both lanes pass, and say how much they cover.
vfile "$T/g" 0 50 0 0; vfile "$T/g" 1 49 0 0
judge pure "$T/g" 2 99;  [ "$RC" -eq 0 ] && ok || bad "V1: all-green shards must pass pure (rc=$RC) [$OUT]"
has "99 suites" "$OUT" && ok || bad "V1: the green must say how many suites it covers [$OUT]"
judge trace "$T/g" 2 99; [ "$RC" -eq 0 ] && ok || bad "V1: all-green shards must pass trace (rc=$RC) [$OUT]"

# ── V2. a failing test, clean trace: pure red, trace green.
vfile "$T/f" 0 50 1 0; vfile "$T/f" 1 49 0 0
judge pure "$T/f" 2 99;  [ "$RC" -eq 1 ] && ok || bad "V2: a failing test must turn pure red (rc=$RC) [$OUT]"
has "shard 0" "$OUT" && ok || bad "V2: the red must name the shard to open [$OUT]"
judge trace "$T/f" 2 99; [ "$RC" -eq 0 ] && ok || bad "V2: a failing test is not a trace hit — trace must stay green (rc=$RC) [$OUT]"

# ── V3. a hit, tests passing: trace red, pure green.
vfile "$T/h" 0 50 0 0; vfile "$T/h" 1 49 0 2
judge trace "$T/h" 2 99; [ "$RC" -eq 1 ] && ok || bad "V3: a hit must turn trace red (rc=$RC) [$OUT]"
judge pure "$T/h" 2 99;  [ "$RC" -eq 0 ] && ok || bad "V3: a hit with passing tests must leave pure green (rc=$RC) [$OUT]"

# ── V4. a missing verdict is red for BOTH lanes.
vfile "$T/m" 0 50 0 0
judge pure "$T/m" 2 99;  [ "$RC" -eq 1 ] && ok || bad "V4: a missing shard verdict must turn pure red (rc=$RC) [$OUT]"
has "shard 1" "$OUT" && ok || bad "V4: and name the shard that did not report [$OUT]"
judge trace "$T/m" 2 99; [ "$RC" -eq 1 ] && ok || bad "V4: a missing shard verdict must turn trace red (rc=$RC) [$OUT]"
judge pure "$T/no-such-dir" 1 10; [ "$RC" -eq 1 ] && ok || bad "V4: no verdicts at all is red (rc=$RC) [$OUT]"

# ── V5. the plan job failed (or never ran): red for both, whatever is on disk.
judge pure "$T/g" 2 99 failure;  [ "$RC" -eq 1 ] && ok || bad "V5: a failed plan must turn pure red (rc=$RC) [$OUT]"
judge trace "$T/g" 2 99 skipped; [ "$RC" -eq 1 ] && ok || bad "V5: a skipped plan must turn trace red (rc=$RC) [$OUT]"

# ── V6. the shards ran fewer suites than the plan selected: a split that
#    dropped suites is red, never a fast green.
judge pure "$T/g" 2 120;  [ "$RC" -eq 1 ] && ok || bad "V6: 99 run of 120 planned must be red (rc=$RC) [$OUT]"
judge trace "$T/g" 2 120; [ "$RC" -eq 1 ] && ok || bad "V6: the trace lane must refuse the short count too (rc=$RC) [$OUT]"

# ── V7. malformed inputs are red, never a pass.
mkdir -p "$T/bad"; printf 'tests=zero\nfailed=0\nhits=0\npure=pass\ntrace=clean\n' > "$T/bad/shard-0.txt"
judge pure "$T/bad" 1 1; [ "$RC" -eq 1 ] && ok || bad "V7: a non-numeric tests= must be red (rc=$RC) [$OUT]"
vfile "$T/z" 0 0 0 0
judge pure "$T/z" 1 0; [ "$RC" -ne 0 ] && ok || bad "V7: a verdict of zero tests is not a pass (rc=$RC) [$OUT]"
judge pure "$T/g" x 99; [ "$RC" -eq 2 ] && ok || bad "V7: a non-numeric shard count is a usage error (rc=$RC) [$OUT]"
judge nope "$T/g" 2 99; [ "$RC" -eq 2 ] && ok || bad "V7: an unknown lane is a usage error (rc=$RC) [$OUT]"

echo "ci-verdicts-test.sh: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] || exit 1
