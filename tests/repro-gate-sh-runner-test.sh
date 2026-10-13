#!/bin/bash
# tests/repro-gate-sh-runner-test.sh — the .sh path of bin/repro-gate.sh.
#
# BH-608. A cromford diff that adds a sourced shell LIBRARY plus a
# self-test was judged dishonestly by three stacked defects: the library was
# classified as a test (directory rule `tests/*`, substring rule `*test*.sh`),
# it was therefore overlaid into the base worktree so the thing under test was
# present "before the change", and `bash lib.sh the-test.sh` ran only the
# library — which, being a sourced lib, exits 0. Verdict: `GATE FAILED — these
# ADDED tests PASS against the code as it was before the change`, on a diff
# that was honest. BH-459 and BH-583 both died on it.
#
# The property these fixtures pin: a shell file is a test by its BASENAME, a
# library is not evidence, a committed fixture script is never executed, and
# every added shell test gets its own bash invocation so the second one cannot
# be swallowed as a positional argument of the first.
#
# Real tmp git repos and the real gate — never the live harness tree.
# Run from anywhere: tests/repro-gate-sh-runner-test.sh   (exit 0 = all pass)
set -uo pipefail
DIR=$(cd "$(dirname "$0")/.." && pwd)
if [ -f "$DIR/tests/lib/scratch.sh" ]; then
  . "$DIR/tests/lib/scratch.sh" || exit 1
else
  # tests/lib/scratch.sh lands with #609 (BH-459) — the very branch this gate
  # fix unblocks — so it does not exist at base, at head, or on main today.
  # Until it does, the suite provisions its own scratch dir.
  T=$(mktemp -d) || exit 1
  trap 'rm -rf "$T"' EXIT
fi
GATE="$DIR/bin/repro-gate.sh"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

# A fresh repo whose base commit is README.md and nothing else.
newrepo() {
  R="$T/$1"; mkdir -p "$R/tests"; cd "$R" || exit 1
  git init -q .; git config user.email t@t; git config user.name t
  echo "placeholder" > README.md
  git add -A; git commit -qm init
  BASE=$(git rev-parse HEAD)
}
# One gate run per fixture; GOUT/GRC are what the assertions read.
run() { GOUT=$("$GATE" "$BASE" "$R" 2>&1); GRC=$?; }
tail5() { tail -5 <<<"$GOUT"; }

# ---------- A. a tests/lib library plus the self-test that sources it ----------
# The exact BH-459 shape, and the reproduction command in the BH-608 plan.
# Honest verdict: the test is red at base because the library is not there, and
# green at head because it is. The library itself is not evidence and is never
# copied into the base worktree.
newrepo libtests
mkdir -p tests/lib
printf 'example_fn() { return 0; }\n' > tests/lib/example.sh
cat > tests/example-lib-test.sh <<'EOF'
#!/bin/bash
. ./tests/lib/example.sh || exit 1
example_fn || exit 1
exit 0
EOF
git add -A; git commit -qm "lib + self-test"
run
[ "$GRC" = 0 ] && ok || bad "A: tests/lib lib + self-test must reach an honest verdict (rc=$GRC, out: $(tail5))"
grep -q 'RED at base' <<<"$GOUT" && ok || bad "A: the absent library must make the added test red at base"
grep -q 'GREEN at head' <<<"$GOUT" && ok || bad "A: the same test must pass at head"
grep -q 'GATE FAILED' <<<"$GOUT" \
  && bad "A: the library was run as a test and exited 0, so the gate called an honest diff vacuous" || ok

# ---------- B. the same, with the library in bin/lib ----------
# The BH-583 shape: a product file that matches *test*.sh only because it is
# named test-home-lib. Quiet sourced lib, so the base tail was empty and the
# verdict was unexplainable.
newrepo libbin
mkdir -p bin/lib
printf 'example_fn() { return 0; }\n' > bin/lib/example-test-home-lib.sh
cat > tests/example-lib-test.sh <<'EOF'
#!/bin/bash
. ./bin/lib/example-test-home-lib.sh || exit 1
example_fn || exit 1
exit 0
EOF
git add -A; git commit -qm "lib + self-test"
run
[ "$GRC" = 0 ] && ok || bad "B: bin/lib lib + self-test must reach an honest verdict (rc=$GRC, out: $(tail5))"
grep -q 'RED at base' <<<"$GOUT" && ok || bad "B: the absent library must make the added test red at base"
grep -q 'GREEN at head' <<<"$GOUT" && ok || bad "B: the same test must pass at head"
grep -q 'GATE FAILED' <<<"$GOUT" \
  && bad "B: a quiet sourced library exited 0 and was counted as an added test passing at base" || ok

# ---------- C. a library ALONE is not added test evidence ----------
newrepo libonlybin
mkdir -p bin/lib
printf 'example_fn() { return 0; }\n' > bin/lib/example-test-home-lib.sh
git add -A; git commit -qm "library only"
run
[ "$GRC" = 2 ] && ok || bad "C: bin/lib/*-test-home-lib.sh alone must not be blocking evidence (rc=$GRC)"
grep -q 'NO_NEW_TESTS' <<<"$GOUT" && ok || bad "C: a lib-only diff offers no added tests and must say so"

newrepo libonlytests
mkdir -p tests/lib
printf 'helper_fn() { return 0; }\n' > tests/lib/helper.sh
git add -A; git commit -qm "tests/lib helper only"
run
[ "$GRC" = 2 ] && ok || bad "C: tests/lib/helper.sh alone must not be blocking evidence (rc=$GRC)"
grep -q 'NO_NEW_TESTS' <<<"$GOUT" && ok || bad "C: a helper-only diff offers no added tests and must say so"

# ---------- D. the vacuous-test detector still fires ----------
# Everything above widens what the gate declines to run. This is the one that
# must not widen: a real added test that passes at base still fails the gate.
newrepo vacuous
cat > tests/vacuous-test.sh <<'EOF'
#!/bin/bash
true
exit 0
EOF
git add -A; git commit -qm "a tautological test"
run
[ "$GRC" = 1 ] && ok || bad "D: an added test that passes at base must still FAIL the gate (rc=$GRC)"
grep -q 'GATE FAILED' <<<"$GOUT" && ok || bad "D: the gate must say it failed"
grep -q 'tests/vacuous-test.sh' <<<"$GOUT" && ok || bad "D: the offending file must be named, not just counted"

# ---------- E. every added shell test runs, not just the first ----------
# `bash a.sh b.sh` runs a.sh with b.sh as $1 — b.sh never executes. Two honest
# tests must both be run and counted.
newrepo twohonest
echo 'feature_exists() { return 1; }' > app.sh
git add -A; git commit -qm "the feature, absent"
BASE=$(git rev-parse HEAD)
cat > tests/a-test.sh <<'EOF'
#!/bin/bash
. ./app.sh || exit 1
feature_exists || exit 1
exit 0
EOF
cat > tests/b-test.sh <<'EOF'
#!/bin/bash
. ./app.sh || exit 1
feature_exists || exit 1
exit 0
EOF
echo 'feature_exists() { return 0; }' > app.sh
git add -A; git commit -qm "feat: the feature, with two tests"
run
[ "$GRC" = 0 ] && ok || bad "E: two honest added shell tests must pass the gate (rc=$GRC, out: $(tail5))"
grep -q '2 added test file(s)' <<<"$GOUT" && ok || bad "E: both added test files must be counted as evidence"

# The half that only per-file invocation can catch: the SECOND file is still
# red at head. Under the list-of-files runner it never ran, so the head run
# exited 0 and the gate stamped a build whose test does not pass.
newrepo stillred
echo 'feature_exists() { return 1; }' > app.sh
git add -A; git commit -qm "the feature, absent"
BASE=$(git rev-parse HEAD)
cat > tests/a-test.sh <<'EOF'
#!/bin/bash
. ./app.sh || exit 1
feature_exists || exit 1
exit 0
EOF
cat > tests/b-still-red-test.sh <<'EOF'
#!/bin/bash
exit 1
EOF
echo 'feature_exists() { return 0; }' > app.sh
git add -A; git commit -qm "feat: second test never passes"
run
[ "$GRC" = 4 ] && ok || bad "E: a second added test that is still red at head must exit 4 (rc=$GRC, out: $(tail5))"
grep -q 'GREEN check FAILED' <<<"$GOUT" && ok || bad "E: a failing head run must be named as such"
grep -q 'exit 1: tests/b-still-red-test.sh' <<<"$GOUT" \
  && ok || bad "E: the per-file result must name which added test failed (out: $(tail5))"

# ---------- F. a filename must never reach a shell, on the per-file path ----------
# The runner is still an argv array per file; no string is ever built. `grep -x`
# distinguishes the marker being EXECUTED from the filename being listed.
newrepo rce
cat > 'tests/a;echo INJECTED_RCE_MARKER;#_test.sh' <<'EOF'
#!/bin/bash
exit 1
EOF
git add -A; git commit -qm "hostile test filename"
run
grep -qx 'INJECTED_RCE_MARKER' <<<"$GOUT" \
  && bad "F: RCE — a metacharacter in a test filename EXECUTED on the per-file runner" || ok
[ "$GRC" = 0 ] || [ "$GRC" = 1 ] || [ "$GRC" = 3 ] || [ "$GRC" = 4 ] \
  && ok || bad "F: a hostile filename must still produce a defined verdict (rc=$GRC)"

# ---------- G. committed fixture scripts are never executed ----------
# With one bash invocation per file, every *-test.sh under a checks fixture
# tree would otherwise RUN. They are data for another checker, not tests.
newrepo fixtures
mkdir -p checks/x/fixtures/tree-bad/tests
cat > checks/x/fixtures/tree-bad/tests/rm-h-test.sh <<'EOF'
#!/bin/bash
echo FIXTURE_RAN
exit 0
EOF
git add -A; git commit -qm "a committed fixture script"
run
[ "$GRC" = 2 ] && ok || bad "G: a fixture script must not be blocking evidence (rc=$GRC)"
grep -q 'NO_NEW_TESTS' <<<"$GOUT" && ok || bad "G: a fixture-only diff offers no added tests and must say so"
grep -q 'FIXTURE_RAN' <<<"$GOUT" && bad "G: a committed fixture script was EXECUTED by the gate" || ok

echo "repro-gate-sh-runner-test: $PASS pass, $FAIL fail"
[ "$FAIL" -eq 0 ]
