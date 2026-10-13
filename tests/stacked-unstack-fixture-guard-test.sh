#!/bin/bash
# tests/stacked-unstack-fixture-guard-test.sh — a broken fixture must be reported
# as a BROKEN FIXTURE, never as a bin/run-build.sh behaviour regression (#1135).
#
# THE INCIDENT. tests/stacked-unstack-test.sh built its git fixtures inside
# `( cd … && git init -q . && … ) >/dev/null 2>&1`: no step's rc was checked and
# no byte of stderr survived. PR #1014 at head e999973 went red on exactly one
# assertion out of 113 —
#
#   FAIL: nothing may rewrite the branch when the parent is not provably merged
#   stacked-unstack: 112 passed, 1 failed
#
# — on a head that touches neither bin/run-build.sh, its RB_MODULES, the suite,
# tests/lib/rb-all.sh nor tests/lib/scratch.sh, and whose flattened pipeline text
# is byte-identical to origin/main. The suite named the wrong file, and a
# resolver round was spent reading an innocent one.
#
# WHY THAT ONE ASSERTION IS THE ONE THAT NOTICES. If the seed's
# `checkout -qb ticket/TK-611` or the child's
# `checkout -b ticket/bh-574 origin/ticket/TK-611` silently failed, then either
# `git rev-parse origin/ticket/TK-611` printed its own ARGUMENT and exited 128
# (so $P_SHA is the literal string), or the child was cut from main instead of
# the parent. Either way that single assertion fails and every other assertion
# in the case still passes, because the recheck block escalates on a
# gone-and-unmerged parent whatever shape the child has.
#
# WHY DRIVEN AND NOT GREPPED. "the fixture checks its rc" is not a property of
# the text — a `|| return 1` that is never reached, or a diagnostic that goes to
# a file nobody reads, greps exactly as well as one that works. So this suite
# RUNS tests/stacked-unstack-test.sh three times with one real setup step
# sabotaged by a `git` shim (twice a hard rc, once a step that LIES and reports
# success while deleting nothing), and once clean, and reads what the suite says.
#
# Run from anywhere: tests/stacked-unstack-fixture-guard-test.sh (exit 0 = pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" 2>/dev/null || { T=$(mktemp -d); trap 'rm -rf "$T"' EXIT; }
DIR=$(cd "$(dirname "$0")/.." && pwd)
SUITE="$DIR/tests/stacked-unstack-test.sh"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v git >/dev/null || { echo "git missing — skipping"; exit 0; }
command -v jq  >/dev/null || { echo "jq missing — skipping";  exit 0; }
[ -r "$SUITE" ] || { echo "FAIL: $SUITE is not readable"; exit 1; }

# A REAL git with exactly one step sabotaged. Nothing else in the run changes:
# the suite under test is the repo's own file, unedited, and every other git
# call reaches the real binary through the exec at the bottom.
REAL_GIT=$(command -v git); export REAL_GIT
mkdir -p "$T/shim"
cat > "$T/shim/git" <<'SH'
#!/bin/bash
case "${SABOTAGE:-}" in
  child-checkout)
    case "$*" in
      *"checkout -q -b ticket/bh-574"*)
        echo "sabotage: refusing to cut the child branch" >&2; exit 43 ;;
    esac ;;
  parent-branch)
    case "$*" in
      *"checkout -qb ticket/TK-611"*)
        echo "sabotage: refusing to create the parent branch" >&2; exit 44 ;;
    esac ;;
  kill-parent)
    # THE LIAR: reports success and deletes nothing. rc alone can never catch
    # this one — only a postcondition can.
    case "$*" in *"branch -D ticket/TK-611"*) exit 0 ;; esac ;;
esac
exec "$REAL_GIT" "$@"
SH
chmod +x "$T/shim/git"

# run_suite <sabotage-name|clean> — runs the suite, leaves its whole output in
# $T/out.<name>.txt and RETURNS the suite's own rc. It deliberately does not
# print: `OUT=$(run_suite x)` would put the rc in a subshell the caller cannot
# read, which is the same class of silence this suite exists to refuse.
run_suite() {
  local s="$1"
  ( export PATH="$T/shim:$PATH"
    if [ "$s" = clean ]; then unset SABOTAGE; else export SABOTAGE="$s"; fi
    bash "$SUITE" ) > "$T/out.$s.txt" 2>&1
}

# ============================================================================
# 1. the child branch is never cut — the exact shape behind #1014's lone red
# ============================================================================
run_suite child-checkout; A_RC=$?
OUT=$(cat "$T/out.child-checkout.txt")
[ "$A_RC" -ne 0 ] \
  && ok || bad "a suite whose fixture never built must exit nonzero (rc $A_RC)"
grep -q 'FIXTURE BROKEN' <<<"$OUT" \
  && ok || bad "a failed setup step must be named FIXTURE BROKEN, not left to a behaviour assertion (got: $(tail -3 <<<"$OUT"))"
grep -q 'FAIL: FIXTURE BROKEN' <<<"$OUT" \
  && ok || bad "a broken fixture must be COUNTED as a failure, not merely printed (got: $(grep -c '^FAIL' <<<"$OUT") FAIL lines)"
grep -qF 'git checkout -b ticket/bh-574 origin/ticket/TK-611' <<<"$OUT" \
  && ok || bad "the FIXTURE BROKEN line must name the step that failed"
grep -qF 'sabotage: refusing to cut the child branch' <<<"$OUT" \
  && ok || bad "git's OWN stderr must survive into the report — swallowing it is the whole bug"
grep -qE 'FIXTURE BROKEN: [a-z]+ —' <<<"$OUT" \
  && ok || bad "the FIXTURE BROKEN line must name WHICH fixture broke"
grep -qE 'stacked-unstack: [0-9]+ passed, [1-9][0-9]* failed' <<<"$OUT" \
  && ok || bad "the summary must still count the failures (got: $(grep 'stacked-unstack:' <<<"$OUT"))"
# and the behaviour assertion that used to carry the whole (wrong) story now
# prints what it actually saw, so it is readable next to the real cause
grep -qF "parent tip '" <<<"$OUT" \
  && ok || bad "the closed/typedred assertions must print the parent sha and HEAD they saw"

# ============================================================================
# 2. the parent branch is never created — $P_SHA becomes its own argument
# ============================================================================
run_suite parent-branch; B_RC=$?
OUT=$(cat "$T/out.parent-branch.txt")
[ "$B_RC" -ne 0 ] && ok || bad "a seed that never branched must fail the suite (rc $B_RC)"
grep -q 'FIXTURE BROKEN' <<<"$OUT" \
  && ok || bad "a seed step that failed must be named FIXTURE BROKEN (got: $(tail -3 <<<"$OUT"))"
grep -qF 'git checkout -b ticket/TK-611 (seed)' <<<"$OUT" \
  && ok || bad "the report must name the seed step that failed"
grep -qF 'sabotage: refusing to create the parent branch' <<<"$OUT" \
  && ok || bad "the seed step's stderr must survive into the report"
grep -q 'could not extract' <<<"$OUT" \
  && bad "a broken seed must not be reported as a missing bin/run-build.sh marker" || ok

# ============================================================================
# 3. THE LIAR: a step that exits 0 and does nothing. rc cannot catch it; the
#    fixture's own postconditions must.
# ============================================================================
run_suite kill-parent; C_RC=$?
OUT=$(cat "$T/out.kill-parent.txt")
[ "$C_RC" -ne 0 ] \
  && ok || bad "a parent branch that was never actually deleted must fail the suite (rc $C_RC)"
grep -q 'FIXTURE BROKEN' <<<"$OUT" \
  && ok || bad "a setup step that lies about succeeding must still be named FIXTURE BROKEN"
grep -qF 'still exists in origin.git after branch -D' <<<"$OUT" \
  && ok || bad "the report must say the postcondition failed, not that the step errored (got: $(grep 'FIXTURE BROKEN' <<<"$OUT" | head -1))"

# ============================================================================
# 4. AND THE CLEAN RUN IS UNTOUCHED. A guard that fires on a good tree is worse
#    than no guard: it would re-teach the fleet to ignore the word.
# ============================================================================
run_suite clean; D_RC=$?
OUT=$(cat "$T/out.clean.txt")
[ "$D_RC" -eq 0 ] && ok || bad "the unsabotaged suite must still pass (rc $D_RC; $(tail -3 <<<"$OUT"))"
grep -q 'FIXTURE BROKEN' <<<"$OUT" \
  && bad "a healthy fixture must never be reported broken (got: $(grep 'FIXTURE BROKEN' <<<"$OUT" | head -2))" || ok
grep -qE 'stacked-unstack: [0-9]+ passed, 0 failed' <<<"$OUT" \
  && ok || bad "the clean run must still report zero failures (got: $(grep 'stacked-unstack:' <<<"$OUT"))"
D_PASSED=$(sed -n 's/^stacked-unstack: \([0-9][0-9]*\) passed.*/\1/p' <<<"$OUT" | tail -1)
[ "${D_PASSED:-0}" -ge 100 ] \
  && ok || bad "the clean run must still run its whole body — a truncated suite is not a pass (got: $(grep 'stacked-unstack:' <<<"$OUT"))"

echo "stacked-unstack-fixture-guard: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
