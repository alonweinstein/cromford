#!/bin/bash
# tests/pr-scoped-test-lint.bh-5684-test.sh — BH-5684: a test must pass on main
# after its PR merges. bin/pr-scoped-test-lint.sh refuses a test line that reads
# its own PR's commit range with no merged-case guard.
#
#   L1  an unguarded own-range count assertion is reported with file:line, rc 1
#   L2  the same with an empty-range skip (a variable and a function subject) is clean
#   L3  a `# pr-scoped: ok <reason>` marker suppresses one hit; a reasonless
#       marker is `marker-no-reason`, rc 1
#   L4  the real tree, no args: rc 0, `0 unguarded`, more than 1000 files scanned
#   L5  pattern ids (diff-quiet = W6 verbatim, merge-base, grep-bh) and the
#       negatives (diff --quiet HEAD, echo, comment, heredoc, merge-base --is-ancestor)
#   L6  a *.test.js is scanned; a plain *.js is not, in default mode
#   L7  a root with no test files is rc 2, never 0
#   L8  a `<<WORD` inside a quoted string is text, not a heredoc start: the
#       read after it is still scanned (lead review of 5ce03f81, NOTE 3); a
#       real `<<'EOF'` still opens one
#
# Every fixture is a quoted heredoc: the lint skips heredoc bodies, so this
# suite passes its own L4.
# determinism: ok-file branch-arm-ungated every branch-diff line here is fixture
# text in a quoted heredoc, fed to the lint; this suite never diffs its own branch.
#
# Run from anywhere: HARNESS_TEST_SANDBOX=1 bash tests/pr-scoped-test-lint.bh-5684-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
REPO=$(cd "$(dirname "$0")/.." && pwd)
LINT="$REPO/bin/pr-scoped-test-lint.sh"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
# run <name> <args...>: stdout to $T/<name>.out, rc to $T/<name>.rc
run() { local n="$1"; shift; bash "$LINT" "$@" > "$T/$n.out" 2> "$T/$n.err"; echo $? > "$T/$n.rc"; }
rc()  { cat "$T/$1.rc"; }
lineof() { grep -n -F -- "$2" "$1" | head -1 | cut -d: -f1; }

# ── L1: unguarded count assertion ────────────────────────────────────────────
mkdir -p "$T/l1"
cat > "$T/l1/x-test.sh" <<'EOF'
#!/bin/bash
DIR=$(pwd)
n=$(git -C "$DIR" log --format=%H origin/main..HEAD | grep -c .)
[ "$n" -gt 0 ] && echo ok
EOF
run l1 "$T/l1/x-test.sh"
L=$(lineof "$T/l1/x-test.sh" 'n=$(git')
[ "$(rc l1)" = 1 ] && ok || bad "L1: an unguarded range read exits 1 (rc $(rc l1))"
grep -qF "$T/l1/x-test.sh:$L: pr-scoped-unguarded: range: " "$T/l1.out" && ok \
  || bad "L1: the finding names x-test.sh:$L and the range id (got: $(cat "$T/l1.out"))"
grep -qx 'pr-scoped-test-lint: 1 unguarded in 1 files (1 scanned)' "$T/l1.out" && ok \
  || bad "L1: the summary counts 1 finding (got: $(tail -1 "$T/l1.out"))"

# ── L2: the empty-range skip guards it ───────────────────────────────────────
mkdir -p "$T/l2"
cat > "$T/l2/var-test.sh" <<'EOF'
#!/bin/bash
DIR=$(pwd)
own=$(git -C "$DIR" log --format=%H origin/main..HEAD)
if [ -n "$own" ]; then
  [ "$(printf '%s\n' "$own" | grep -c .)" -gt 0 ] && echo ok
else
  echo "note: skipped (range empty: the ticket has merged)"
fi
EOF
cat > "$T/l2/fn-test.sh" <<'EOF'
#!/bin/bash
DIR=$(pwd)
q_scope_commits() {
  { git -C "$DIR" log --no-merges -i --format=%H --grep='bh-4584' origin/main..HEAD
    git -C "$DIR" log --no-merges --format=%H origin/main..HEAD -- bin/x.sh; } | sort -u
}
q_scope() { local c hit=0; for c in $(q_scope_commits); do hit=$((hit+0)); done; [ "$hit" = 0 ]; }
if [ -n "$(q_scope_commits)" ]; then
  q_scope && echo ok
else
  echo "note: Q-SCOPE skipped (no BH-4584 commit in the range)"
fi
EOF
run l2 "$T/l2/var-test.sh" "$T/l2/fn-test.sh"
[ "$(rc l2)" = 0 ] && ok || bad "L2: an empty-range skip guards the read (rc $(rc l2): $(cat "$T/l2.out"))"
grep -qx 'pr-scoped-test-lint: 0 unguarded in 0 files (2 scanned)' "$T/l2.out" && ok \
  || bad "L2: no finding (got: $(tail -1 "$T/l2.out"))"
# The guard is the emptiness test AND the note: drop the note and it is a hit.
grep -v 'note: skipped' "$T/l2/var-test.sh" > "$T/l2/nonote-test.sh"
run l2b "$T/l2/nonote-test.sh"
[ "$(rc l2b)" = 1 ] && ok || bad "L2: an emptiness test with no skip note does not guard (rc $(rc l2b))"

# ── L3: the marker ───────────────────────────────────────────────────────────
mkdir -p "$T/l3"
cat > "$T/l3/m-test.sh" <<'EOF'
#!/bin/bash
# pr-scoped: ok fixture repo, the branch under test is built by this suite
a=$(git diff --name-only origin/main...HEAD)

b=$(git diff --name-only origin/main...HEAD)
EOF
run l3 "$T/l3/m-test.sh"
LB=$(grep -n '^b=' "$T/l3/m-test.sh" | cut -d: -f1)
[ "$(rc l3)" = 1 ] && ok || bad "L3: the unmarked hit still fails (rc $(rc l3))"
[ "$(grep -c ': pr-scoped-unguarded: ' "$T/l3.out")" = 1 ] && grep -qF "m-test.sh:$LB: pr-scoped-unguarded: range" "$T/l3.out" && ok \
  || bad "L3: exactly one finding, on the unmarked line $LB (got: $(cat "$T/l3.out"))"
cat > "$T/l3/bare-test.sh" <<'EOF'
#!/bin/bash
# pr-scoped: ok
a=$(git diff --name-only origin/main...HEAD)
EOF
run l3b "$T/l3/bare-test.sh"
[ "$(rc l3b)" = 1 ] && grep -qF "bare-test.sh:2: pr-scoped-unguarded: marker-no-reason" "$T/l3b.out" && ok \
  || bad "L3: a reasonless marker is marker-no-reason, rc 1 (rc $(rc l3b): $(cat "$T/l3b.out"))"
grep -qF "bare-test.sh:3: pr-scoped-unguarded: range" "$T/l3b.out" && ok \
  || bad "L3: a reasonless marker guards nothing (got: $(cat "$T/l3b.out"))"

# ── L4: the real tree, through the production entry point ────────────────────
( cd "$T" && bash "$LINT" ) > "$T/l4.out" 2> "$T/l4.err"; L4RC=$?
[ "$L4RC" = 0 ] && ok || bad "L4: the real tree has no unguarded hit (rc $L4RC): $(cat "$T/l4.out" "$T/l4.err")"
SUM=$(tail -1 "$T/l4.out")
K=$(sed -n 's/^pr-scoped-test-lint: 0 unguarded in 0 files (\([0-9]*\) scanned)$/\1/p' <<<"$SUM")
[ -n "$K" ] && [ "$K" -gt 1000 ] && ok || bad "L4: '0 unguarded' over more than 1000 files (got '$SUM')"

# ── L5: the pattern ids, and the negatives ───────────────────────────────────
mkdir -p "$T/l5"
cat > "$T/l5/p-test.sh" <<'EOF'
#!/bin/bash
git diff --quiet $(git merge-base HEAD origin/main) -- .mergify.yml && ok || bad "W6"
BASE=$(git merge-base HEAD origin/main)
F=$(git diff --name-only "$BASE"...HEAD)
L=$(git log --format=%H --grep=BH-12 abc..def)
EOF
run l5 "$T/l5/p-test.sh"
for want in "p-test.sh:2: pr-scoped-unguarded: diff-quiet" "p-test.sh:4: pr-scoped-unguarded: merge-base" \
            "p-test.sh:5: pr-scoped-unguarded: grep-bh"; do
  grep -qF "$want" "$T/l5.out" && ok || bad "L5: '$want' (got: $(cat "$T/l5.out"))"
done
[ "$(grep -c ': pr-scoped-unguarded: ' "$T/l5.out")" = 3 ] && [ "$(rc l5)" = 1 ] && ok \
  || bad "L5: exactly 3 findings, rc 1 (BASE= alone reads no range) (rc $(rc l5): $(cat "$T/l5.out"))"
cat > "$T/l5/neg-test.sh" <<'EOF'
#!/bin/bash
git -C "$W" diff --quiet HEAD -- generated.md && ok || bad "worktree clean"
echo "SKIP the builder pastes git diff --name-only origin/main...HEAD instead"
printf 'range was origin/main..HEAD\n'
# git log --format=%H origin/main..HEAD is what the branch arm reads
cat > "$W/probe.sh" <<'PROBE'
git diff --name-only origin/main...HEAD | sort
PROBE
git merge-base --is-ancestor origin/main HEAD && ok
EOF
run l5n "$T/l5/neg-test.sh"
[ "$(rc l5n)" = 0 ] && ok || bad "L5: no negative is flagged (rc $(rc l5n): $(cat "$T/l5n.out"))"

# ── L6: *.test.js in, plain *.js out (default mode, a fixture git repo) ───────
mkdir -p "$T/l6/tests"
cat > "$T/l6/tests/a.test.js" <<'EOF'
const { execSync } = require('child_process');
const out = execSync('git diff --name-only origin/main...HEAD').toString();
EOF
cat > "$T/l6/tests/helper.js" <<'EOF'
const out = execSync('git diff --name-only origin/main...HEAD').toString();
EOF
git -C "$T/l6" init -q && git -C "$T/l6" add tests
run l6 --root "$T/l6"
[ "$(rc l6)" = 1 ] && grep -qF "tests/a.test.js:2: pr-scoped-unguarded: range" "$T/l6.out" && ok \
  || bad "L6: a *.test.js read is flagged (rc $(rc l6): $(cat "$T/l6.out" "$T/l6.err"))"
grep -q 'helper\.js' "$T/l6.out" && bad "L6: a plain *.js is not scanned (got: $(cat "$T/l6.out"))" || ok
grep -qx 'pr-scoped-test-lint: 1 unguarded in 1 files (1 scanned)' "$T/l6.out" && ok \
  || bad "L6: one file scanned (got: $(tail -1 "$T/l6.out"))"

# ── L7: scanned nothing is never green ───────────────────────────────────────
mkdir -p "$T/l7/tests"
git -C "$T/l7" init -q
run l7 --root "$T/l7"
[ "$(rc l7)" = 2 ] && ok || bad "L7: a root with no test files exits 2 (rc $(rc l7))"
run l7b "$T/l7/no-such-test.sh"
[ "$(rc l7b)" = 2 ] && ok || bad "L7: an unreadable path exits 2 (rc $(rc l7b))"

# ── L8: a quoted `<<EOF` is not a heredoc ────────────────────────────────────
mkdir -p "$T/l8"
cat > "$T/l8/x-test.sh" <<'EOF'
#!/bin/bash
DIR=$(pwd)
echo "use <<EOF here"
n=$(git -C "$DIR" log --format=%H origin/main..HEAD | grep -c .)
[ "$n" -gt 0 ] && echo ok
cat <<'DOC'
git log origin/main..HEAD
DOC
EOF
run l8 "$T/l8/x-test.sh"
L=$(lineof "$T/l8/x-test.sh" 'n=$(git')
grep -qF "$T/l8/x-test.sh:$L: pr-scoped-unguarded: range: " "$T/l8.out" && ok \
  || bad "L8: the read after a quoted <<EOF is still scanned (got: $(cat "$T/l8.out"))"
[ "$(rc l8)" = 1 ] && grep -qx 'pr-scoped-test-lint: 1 unguarded in 1 files (1 scanned)' "$T/l8.out" && ok \
  || bad "L8: exactly one finding; the real heredoc body stays skipped (rc $(rc l8): $(cat "$T/l8.out"))"

echo "pr-scoped-test-lint.bh-5684-test: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
