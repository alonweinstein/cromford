#!/bin/bash
# tests/test-suite-run-test.sh — bin/test-suite-run.sh must tell a suite that
# DIED apart from a suite that RAN AND FAILED.
#
# On 2026-09-17 tests/checks-suite-test.sh died sourcing a tests/lib/ file main
# did not have. It printed no summary line, and the CI log read as one more
# ordinary failure in a run that also carried genuine FAILs from the same
# missing file — so the real cause was the hardest line to find in the log.
#
# Every case here drives the REAL bin/test-suite-run.sh over a scratch tests/
# tree of fixture suites and asserts on its stdout and its exit code. Nothing
# reads the script's source text: what the runner PRINTS is the whole contract,
# because the CI log is the only thing a reader ever sees.
#
# Self-contained: no network, no secrets, no $HARNESS, no clock read.
set -uo pipefail
DIR=$(cd "$(dirname "$0")/.." && pwd)
RUNNER="$DIR/bin/test-suite-run.sh"
# shellcheck source=lib/scratch.sh
. "$(dirname "$0")/lib/scratch.sh" || exit 1
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

OUT=""; RC=0

# A fresh scratch tests/ tree. The lib/ dir sits one level down on purpose: the
# runner globs the top level only, so lib/ must never be run as a suite.
tree_reset() {
  rm -rf "$T/c"
  mkdir -p "$T/c/tests/lib"
  printf '#!/bin/bash\n' > "$T/c/tests/lib/scratch.sh"
}

# suite <name> — body on stdin, written verbatim.
suite() {
  cat > "$T/c/tests/$1"
}

run() { OUT=$(bash "$RUNNER" "$T/c/tests" 2>&1); RC=$?; }

# The three shapes the classifier has to tell apart, as separate builders so a
# case can pick the ones it needs.
fixture_pass() {
  suite "$1" <<'EOF'
#!/bin/bash
echo MARK-A
echo "a-pass-test: 1 pass, 0 fail"
exit 0
EOF
}
fixture_honest_fail() {
  suite "$1" <<'EOF'
#!/bin/bash
echo MARK-B
echo "FAIL: a thing this suite genuinely measured"
echo "b-honest-fail-test: 1 pass, 1 fail"
exit 1
EOF
}
fixture_dies() {
  suite "$1" <<'EOF'
#!/bin/bash
set -uo pipefail
echo MARK-C
. "$(dirname "$0")/lib/missing.sh" || exit 1
echo "c-dies-test: 1 pass, 0 fail"
EOF
}

# ── 1. all green ────────────────────────────────────────────────────────────
# all-pass-exit-0-no-block
tree_reset
fixture_pass a-pass-test.sh
fixture_pass b-pass-test.sh
fixture_pass c-pass-test.sh
run
[ "$RC" -eq 0 ] && ok || bad "all-pass-exit-0-no-block: rc was $RC, expected 0"
grep -q '^SUITE ERRORS' <<<"$OUT" && bad "all-pass-exit-0-no-block: printed a SUITE ERRORS block on a green run" || ok

# ── 2. every suite's own output survives ────────────────────────────────────
# every-suite-output-echoed
tree_reset
fixture_pass a-pass-test.sh
fixture_honest_fail b-honest-fail-test.sh
fixture_dies c-dies-test.sh
run
for M in MARK-A MARK-B MARK-C; do
  grep -q "$M" <<<"$OUT" && ok || bad "every-suite-output-echoed: $M missing from the run output"
done
for S in a-pass-test.sh b-honest-fail-test.sh c-dies-test.sh; do
  grep -q "^--- $T/c/tests/$S\$" <<<"$OUT" && ok || bad "every-suite-output-echoed: no '--- …/$S' header line"
done

# ── 3. the dying suite is named once, at the end ────────────────────────────
# dying-suite-is-one-suite-error-block
[ "$RC" -eq 1 ] && ok || bad "dying-suite-is-one-suite-error-block: rc was $RC, expected 1"
[ "$(grep -c '^SUITE ERRORS' <<<"$OUT")" -eq 1 ] \
  && ok || bad "dying-suite-is-one-suite-error-block: expected exactly one SUITE ERRORS header, got $(grep -c '^SUITE ERRORS' <<<"$OUT")"
BLOCK=$(sed -n '/^SUITE ERRORS/,$p' <<<"$OUT")
grep -q 'c-dies-test\.sh' <<<"$BLOCK" && ok || bad "dying-suite-is-one-suite-error-block: block does not name c-dies-test.sh"

# block-quotes-first-error-line: the line under the header carries the reason,
# not just the path — a block that says "it failed" is the log we already had.
grep -q 'lib/missing\.sh: No such file or directory' <<<"$BLOCK" \
  && ok || bad "block-quotes-first-error-line: block does not quote the suite's first error line: $BLOCK"

# honest-fail-is-not-a-suite-error: THE negative. A suite that ran, counted and
# reported failures must never be dressed up as broken infrastructure.
grep -q 'b-honest-fail-test\.sh' <<<"$BLOCK" \
  && bad "honest-fail-is-not-a-suite-error: the honest FAIL was listed as a SUITE ERROR" || ok

# dying-suite-does-not-stop-later-suites: no errexit — the suite AFTER the one
# that died still runs. c sorts last above, so use a tree where it does not.
tree_reset
fixture_pass a-pass-test.sh
fixture_dies b-dies-test.sh
suite c-later-test.sh <<'EOF'
#!/bin/bash
echo MARK-LATER
echo "c-later-test: 1 pass, 0 fail"
exit 0
EOF
run
grep -q 'MARK-LATER' <<<"$OUT" && ok || bad "dying-suite-does-not-stop-later-suites: the suite after the dying one never ran"
[ "$RC" -eq 1 ] && ok || bad "dying-suite-does-not-stop-later-suites: rc was $RC, expected 1"

# ── 4. ordinary failures keep today's behaviour exactly ─────────────────────
# honest-fail-no-block-exit-1
tree_reset
fixture_pass a-pass-test.sh
fixture_honest_fail b-honest-fail-test.sh
run
[ "$RC" -eq 1 ] && ok || bad "honest-fail-no-block-exit-1: rc was $RC, expected 1"
grep -q '^SUITE ERRORS' <<<"$OUT" && bad "honest-fail-no-block-exit-1: a run with only honest FAILs printed a block" || ok

# alt-summary-shape-is-honest-fail: 20 suites in this repo count with
# "pass=N fail=M" instead. An honest failure there is still an honest failure.
tree_reset
fixture_pass a-pass-test.sh
suite b-alt-shape-test.sh <<'EOF'
#!/bin/bash
echo "FAIL: measured and counted"
echo "pass=1 fail=1"
exit 1
EOF
run
[ "$RC" -eq 1 ] && ok || bad "alt-summary-shape-is-honest-fail: rc was $RC, expected 1"
grep -q '^SUITE ERRORS' <<<"$OUT" && bad "alt-summary-shape-is-honest-fail: pass=N fail=M summary was read as a dead suite" || ok

# real-summary-shapes-are-honest-fails: the two shapes above are not the only
# ones this repo prints. Four suites at head count in shapes the first regex
# could not read — a parenthesised ticket key in the name
# (tests/heartbeat-reaper.bh-638-test.sh, tests/review-prs-state.bh-977-test.sh),
# a `name: pass=N fail=M` (tests/tg-outbound-topic-test.sh) and a bare
# `N pass, M fail` with no name at all (tests/cache-hit-report-test.sh). An
# honest failure in any of them must not be filed under "these suites did not
# run, the FAIL lines above are noise" — that is D10 broken in the opposite
# direction from the incident.
for SHAPE in "heartbeat-reaper (BH-638): 7 passed, 1 failed" \
             "review-prs-state (BH-977): 7 passed, 1 failed" \
             "tg-outbound-topic: pass=7 fail=1" \
             "7 pass, 1 fail"; do
  tree_reset
  fixture_pass a-pass-test.sh
  { printf '#!/bin/bash\n'
    printf 'echo "FAIL: measured and counted"\n'
    printf 'echo %s\n' "\"$SHAPE\""
    printf 'exit 1\n'
  } | suite b-shape-test.sh
  run
  [ "$RC" -eq 1 ] && ok || bad "real-summary-shapes-are-honest-fails [$SHAPE]: rc was $RC, expected 1"
  grep -q '^SUITE ERRORS' <<<"$OUT" \
    && bad "real-summary-shapes-are-honest-fails [$SHAPE]: a counted summary was read as a dead suite: $(sed -n '/^SUITE ERRORS/,$p' <<<"$OUT")" \
    || ok
done

# a-summary-shaped-line-is-still-needed: loosening the summary reader must not
# swallow the incident itself. A suite that dies with a colon in its error text
# and no counts is still a SUITE ERROR.
tree_reset
fixture_pass a-pass-test.sh
suite b-colon-death-test.sh <<'EOF'
#!/bin/bash
set -uo pipefail
echo "some-suite: starting the pass over tests/lib"
. "$(dirname "$0")/lib/missing.sh" || exit 1
EOF
run
[ "$RC" -eq 1 ] && ok || bad "a-summary-shaped-line-is-still-needed: rc was $RC, expected 1"
grep -q 'b-colon-death-test\.sh' <<<"$(sed -n '/^SUITE ERRORS/,$p' <<<"$OUT")" \
  && ok || bad "a-summary-shaped-line-is-still-needed: a suite that died with no counts was not named: $OUT"

# honest-fail-large-output: the summary line followed by more than a pipe
# buffer of output. Under pipefail a `printf | grep -q` probe returns 141 when
# grep exits on the match while printf still has bytes to write, and an honest
# FAIL comes out as a SUITE ERROR. 300 KB is well past any pipe buffer.
tree_reset
fixture_pass a-pass-test.sh
suite b-big-fail-test.sh <<'EOF'
#!/bin/bash
echo "FAIL: measured and counted"
echo "pass=1 fail=1"
i=0; while [ $i -lt 3000 ]; do printf '%0100d\n' 0; i=$((i+1)); done
exit 1
EOF
run
[ "$RC" -eq 1 ] && ok || bad "honest-fail-large-output: rc was $RC, expected 1"
grep -q '^SUITE ERRORS' <<<"$OUT" && bad "honest-fail-large-output: a summary followed by 300 KB of output was read as a dead suite" || ok

# silent-pass-is-not-an-error: exit 0 with no summary (skips, node --test
# wrappers) is a pass and is never inspected.
tree_reset
fixture_pass a-pass-test.sh
suite b-silent-test.sh <<'EOF'
#!/bin/bash
exit 0
EOF
run
[ "$RC" -eq 0 ] && ok || bad "silent-pass-is-not-an-error: rc was $RC, expected 0"
grep -q '^SUITE ERRORS' <<<"$OUT" && bad "silent-pass-is-not-an-error: a silent green suite was reported as an error" || ok

# ── 5. a suite that says nothing at all still gets named ────────────────────
# no-output-nonzero-is-suite-error
tree_reset
fixture_pass a-pass-test.sh
suite b-mute-test.sh <<'EOF'
#!/bin/bash
exit 3
EOF
run
[ "$RC" -eq 1 ] && ok || bad "no-output-nonzero-is-suite-error: rc was $RC, expected 1"
grep -qE 'b-mute-test\.sh: exited 3 with no output$' <<<"$OUT" \
  && ok || bad "no-output-nonzero-is-suite-error: expected 'exited 3 with no output', got: $(sed -n '/^SUITE ERRORS/,$p' <<<"$OUT")"

# ── 6. the environment CI sets reaches the suites ───────────────────────────
# env-passthrough: the decisions job exports CODEGRAPH_REQUIRED=1 so the
# capability suite cannot skip. The runner must pass it through and set nothing.
tree_reset
suite a-env-test.sh <<'EOF'
#!/bin/bash
echo "CODEGRAPH_REQUIRED=${CODEGRAPH_REQUIRED:-unset}"
echo "a-env-test: 1 pass, 0 fail"
exit 0
EOF
OUT=$(CODEGRAPH_REQUIRED=1 bash "$RUNNER" "$T/c/tests" 2>&1); RC=$?
grep -q '^CODEGRAPH_REQUIRED=1$' <<<"$OUT" && ok || bad "env-passthrough: CODEGRAPH_REQUIRED=1 did not reach the suite"
# The other half asks whether the RUNNER invents a value, so the ambient one has
# to be removed rather than assumed absent: the decisions job that runs this
# suite exports CODEGRAPH_REQUIRED=1 itself, and a plain `run` there measures
# that job's environment instead of the runner — 43/1 on every push.
OUT=$(env -u CODEGRAPH_REQUIRED bash "$RUNNER" "$T/c/tests" 2>&1); RC=$?
grep -q '^CODEGRAPH_REQUIRED=unset$' <<<"$OUT" && ok || bad "env-passthrough: the runner set CODEGRAPH_REQUIRED itself"

# ── 7. several dirs are one sweep ───────────────────────────────────────────
# CI passes `tests tests/mc` because its bash has no globstar (#929).
# two-dirs-both-swept: every dir's suites run, in the order given.
tree_reset
fixture_pass a-test.sh
mkdir -p "$T/c/tests/mc"
cat > "$T/c/tests/mc/m-test.sh" <<'EOF'
#!/bin/bash
echo "m-test: 1 pass, 0 fail"
exit 0
EOF
OUT=$(bash "$RUNNER" "$T/c/tests" "$T/c/tests/mc" 2>&1); RC=$?
[ "$RC" -eq 0 ] && ok || bad "two-dirs-both-swept: rc was $RC, expected 0: $OUT"
grep -q 'a-test\.sh$' <<<"$OUT" && ok || bad "two-dirs-both-swept: the first dir's suite did not run: $OUT"
grep -q 'm-test\.sh$' <<<"$OUT" && ok || bad "two-dirs-both-swept: the second dir's suite did not run: $OUT"

# a-failing-suite-in-the-second-dir: rc must still be 1, not the first dir's 0.
cat > "$T/c/tests/mc/m-test.sh" <<'EOF'
#!/bin/bash
echo "m-test: 0 pass, 1 fail"
exit 1
EOF
OUT=$(bash "$RUNNER" "$T/c/tests" "$T/c/tests/mc" 2>&1); RC=$?
[ "$RC" -eq 1 ] && ok || bad "second-dir-failure-counts: rc was $RC, expected 1: $OUT"

# empty-second-dir-is-not-rc-2: tests/mc carries no suite yet, and a dir with
# nothing in it must not fail a run whose other dir swept fine.
tree_reset
fixture_pass a-test.sh
mkdir -p "$T/c/tests/mc"
OUT=$(bash "$RUNNER" "$T/c/tests" "$T/c/tests/mc" 2>&1); RC=$?
[ "$RC" -eq 0 ] && ok || bad "empty-second-dir-is-not-rc-2: rc was $RC, expected 0: $OUT"

# ── 8. a sweep over nothing is not green ────────────────────────────────────
# empty-dir-is-rc-2
tree_reset
run
[ "$RC" -eq 2 ] && ok || bad "empty-dir-is-rc-2: rc was $RC, expected 2"

# all-dirs-empty-is-rc-2: the guard holds across a multi-dir sweep too.
tree_reset
mkdir -p "$T/c/tests/mc"
OUT=$(bash "$RUNNER" "$T/c/tests" "$T/c/tests/mc" 2>&1); RC=$?
[ "$RC" -eq 2 ] && ok || bad "all-dirs-empty-is-rc-2: rc was $RC, expected 2: $OUT"

rm -rf "$T/c"
echo "test-suite-run: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
