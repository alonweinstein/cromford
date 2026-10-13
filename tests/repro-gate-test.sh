#!/bin/bash
# tests/repro-gate-test.sh — bin/repro-gate.sh against real git repos.
#
# The property that matters: a NEW TEST THAT PASSES AT BASE must fail the gate.
# That is the vacuous-test detector, and everything else here exists so it can
# be trusted — a gate that reports red for the wrong reason (missing deps, no
# runner) would rubber-stamp every build while looking like it worked.
#
# Bash fixtures are used as the runner because they need no npm and no network,
# so these cases exercise the real control flow rather than a mocked one.
# Run from anywhere: tests/repro-gate-test.sh   (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
GATE="$DIR/bin/repro-gate.sh"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

# A repo whose "feature" is a function in app.sh, tested by a bash fixture.
newrepo() {
  R="$T/$1"; mkdir -p "$R/tests"; cd "$R" || exit 1
  git init -q .; git config user.email t@t; git config user.name t
  echo 'feature_exists() { return 1; }' > app.sh
  echo "placeholder" > README.md
  git add -A; git commit -qm init
  BASE=$(git rev-parse HEAD)
}
out() { "$GATE" "$BASE" "$R" 2>&1 || true; }
rc()  { "$GATE" "$BASE" "$R" >/dev/null 2>&1; echo $?; }
has() { grep -q "$1" <<<"$(out)"; }

# ---------- 1. honest red -> green: the gate passes ----------
# The test fails at base because the feature is not there, and passes at head.
newrepo honest
cat > tests/feature-test.sh <<'EOF'
#!/bin/bash
. ./app.sh
feature_exists || exit 1
exit 0
EOF
echo 'feature_exists() { return 0; }' > app.sh
git add -A; git commit -qm "feat: the feature, with a test"
[ "$(rc)" = 0 ] && ok || bad "honest red-then-green must pass the gate (rc=$(rc), out: $(out|tail -3))"
has 'RED at base' && ok || bad "the red-at-base result must be stated"
has 'GREEN at head' && ok || bad "the green-at-head result must be stated"

# ---------- 2. THE ONE THAT MATTERS: a test that passes at base ----------
# Asserting something that already worked. Green either way, proves nothing.
newrepo vacuous
cat > tests/vacuous-test.sh <<'EOF'
#!/bin/bash
[ 1 -eq 1 ] || exit 1
exit 0
EOF
echo 'feature_exists() { return 0; }' > app.sh
git add -A; git commit -qm "feat: with a tautological test"
[ "$(rc)" = 1 ] && ok || bad "a test that passes at base must FAIL the gate (rc=$(rc))"
has 'PASS against the code as it was before' && ok || bad "the gate must say why it failed"
has 'vacuous-test.sh' && ok || bad "the offending file must be named, not just counted"

# ---------- 3. no new tests: recorded, never blocking ----------
# Whether shipping without tests is acceptable stays the reviewer's call; the
# gate's job is to make the absence visible rather than to veto.
newrepo notests
echo 'feature_exists() { return 0; }' > app.sh
git add -A; git commit -qm "feat: no tests offered"
[ "$(rc)" = 2 ] && ok || bad "no new test files must exit 2, not block (rc=$(rc))"
has 'NO_NEW_TESTS' && ok || bad "the absence of evidence must be stated explicitly"

# ---------- 4. a gate that cannot run honestly says so ----------
# Each of these would otherwise produce a NON-ZERO base run and be miscounted as
# an honest red — the exact false-green this gate exists to prevent.
newrepo norunner
mkdir -p tests; echo 'nothing' > tests/thing.test.rb   # no runner for ruby here
git add -A; git commit -qm "feat: unrunnable test"
[ "$(rc)" = 3 ] && ok || bad "no runner must exit 3 (cannot run), not 0 (rc=$(rc))"
has 'GATE_UNAVAILABLE' && ok || bad "an unrunnable gate must say GATE_UNAVAILABLE"

# The JS case: package.json but no node_modules. A base run would fail on
# imports for every test, feature or not — reporting that as RED would make the
# gate a rubber stamp on every JS repo in the fleet.
newrepo nodeps
printf '{"scripts":{"test":"vitest run"}}\n' > package.json
mkdir -p tests; echo 'test' > tests/thing.test.js
git add -A; git commit -qm "feat: js test, no node_modules"
[ "$(rc)" = 3 ] && ok || bad "package.json without node_modules must exit 3, never a fake RED (rc=$(rc))"
has 'no node_modules to link' && ok || bad "the reason must name the missing dependency"
has 'prove nothing' && ok || bad "the message must say why a base run would be meaningless"

# With node_modules present, the same repo becomes runnable (npm stubbed so the
# case tests OUR control flow, not npm's).
newrepo withdeps
printf '{"scripts":{"test":"echo ran"}}\n' > package.json
mkdir -p node_modules tests
cat > tests/thing.test.js <<'EOF'
placeholder
EOF
git add -A; git commit -qm "feat: js test with deps"
mkdir -p "$T/fakebin"
# fails at base (no feature marker), succeeds where the marker exists
cat > "$T/fakebin/npm" <<'EOF'
#!/bin/bash
[ -f FEATURE ] && exit 0
exit 1
EOF
chmod +x "$T/fakebin/npm"
touch FEATURE; git add -A; git commit -qm "feat: marker"
RCJS=$(PATH="$T/fakebin:$PATH" "$GATE" "$BASE" "$R" >/dev/null 2>&1; echo $?)
[ "$RCJS" = 0 ] && ok || bad "a JS repo with node_modules must run the gate for real (rc=$RCJS)"

# A runner that is DETECTED but whose binary is missing at execution exits 127.
# That is not a test failing for want of the feature — it is the gate not
# running. This case exists because the gate's first version counted exactly
# that as an honest RED (a missing `timeout` binary), which would have stamped
# every build on any box with an incomplete toolchain.
#
# The missing binary is SIMULATED by stubs that exit 127, not by narrowing PATH
# to directories that happen not to hold node. The earlier version used
# `$T/emptybin:/usr/bin:/bin` and so encoded "where node is installed" as part
# of "a runner is missing": on Debian (apt `nodejs`, NodeSource — every box in
# the fleet) npm IS under /usr/bin, the base run really ran, and the case failed
# with `RED at base: exit 254`; on GitHub-hosted Ubuntu node sits under
# /usr/local and the narrowing worked by accident of layout (BH-1219). Stubs
# shadow whatever npm/npx/node the host has, so the gate sees exit 127 wherever
# it runs, and the rest of PATH stays intact for the tools the gate needs.
newrepo missingbin
printf '{"scripts":{"test":"vitest run"}}\n' > package.json
mkdir -p node_modules tests; echo 'x' > tests/thing.test.js
git add -A; git commit -qm "feat: js test"
mkdir -p "$T/stubbin"
for b in npm npx node; do
  cat > "$T/stubbin/$b" <<EOS
#!/bin/bash
echo "$b: command not found" >&2
exit 127
EOS
  chmod +x "$T/stubbin/$b"
done
RCMB=$(PATH="$T/stubbin:$PATH" "$GATE" "$BASE" "$R" >/dev/null 2>&1; echo $?)
[ "$RCMB" = 3 ] && ok || bad "a runner binary missing at exec (127) must exit 3, never count as RED (rc=$RCMB)"
OUTMB=$(PATH="$T/stubbin:$PATH" "$GATE" "$BASE" "$R" 2>&1 || true)
grep -q 'not counted as red' <<<"$OUTMB" && ok || bad "the 127 path must say it is not counted as red (got: $(tail -2 <<<"$OUTMB"))"

# ---------- 4c. A FILENAME MUST NEVER REACH A SHELL ----------
# Proven exploitable in review: the first version built a command STRING from
# unquoted filenames and ran it through `bash -c`, so a committed test file
# named `a;echo MARKER;#_test.sh` executed as root. Filenames come from a diff
# written by a builder steered by client-authored ticket text — the path from a
# board comment to root execution was real. Same class as the #37/#38 RCEs.
#
# The marker is a RELATIVE path, because a filename cannot contain a slash: the
# injected `touch` lands in whatever directory the gate is running in, which is
# the repo for the head run and the base worktree for the base run. Checking an
# absolute path under $T would be a test that can never fire — which is exactly
# what the first version of THIS case did.
# The marker is an ECHO, not a file. A filename cannot contain a slash, so an
# injected `touch` can only land in the current directory — which for the base
# run is the temporary worktree the gate deletes on exit. The first version of
# this case checked for that file in the repo and could therefore NEVER fire,
# passing against code that was provably exploitable. An echoed marker travels
# out in the gate's own captured output instead, and `grep -x` distinguishes the
# string being EXECUTED from the filename merely being listed.
newrepo rce
# The reviewer's exact proof shape, so its re-run and this pin are one test.
cat > 'tests/a;echo INJECTED_RCE_MARKER;#_test.sh' <<'EOF'
#!/bin/bash
exit 1
EOF
git add -A; git commit -qm "feat: hostile test filename"
RCEOUT=$("$GATE" "$BASE" "$R" 2>&1 || true)
grep -qx 'INJECTED_RCE_MARKER' <<<"$RCEOUT" \
  && bad "RCE: a metacharacter in a test filename EXECUTED as the gate ran" || ok
# A second shape, in case a future runner quotes one metacharacter but not all.
newrepo rce2
cat > 'tests/b$(echo SUBSHELL_RCE)_test.sh' <<'EOF'
#!/bin/bash
exit 1
EOF
git add -A; git commit -qm "feat: command-substitution filename"
RCEOUT2=$("$GATE" "$BASE" "$R" 2>&1 || true)
# BH-608: the gate now prints one `--- bash <file> ---` / `--- exit N: <file> ---`
# pair per added shell test, so this filename — literal `$(echo SUBSHELL_RCE)`
# and all — appears in the output as TEXT. Evaluation is what this case exists
# to catch, not mention, exactly as the marker case above uses grep -x to tell
# an EXECUTED string from a listed one. Drop every line carrying the unevaluated
# spelling; anything left holding the marker means a shell expanded it.
grep -q 'SUBSHELL_RCE' <<<"$(grep -v '[$](echo SUBSHELL_RCE)' <<<"$RCEOUT2")" \
  && bad "RCE: command substitution in a filename was evaluated" || ok

# The implementation property behind it. Comment lines excluded: the header
# explains WHY there is no bash -c, and a naive grep matches its own explanation.
grep -q 'bash -c' <(grep -v '^[[:space:]]*#' "$GATE") \
  && bad "repro-gate must never run a command string through bash -c" || ok
# No $(printf …) around the file list either. Those were message formatting and
# safe, but they are the shape an auditor greps for, and a guard that needs a
# paragraph to read as safe is one someone will eventually misread.
grep -q '\$(printf' <(grep -v '^[[:space:]]*#' "$GATE") \
  && bad "repro-gate must not nest \$(printf …) around the file list — it reads as command-building" || ok
# The runner really is separate argv elements, not one blob.
# BH-608: `bash a.sh b.sh` runs a.sh with b.sh as $1. The list-of-files runner
# is gone; each shell test is its own argv (behaviour pinned in
# tests/repro-gate-sh-runner-test.sh).
grep -q 'bash "${ADDED\[@\]}"' "$GATE" \
  && bad "the runner must not hand the whole file list to one bash invocation" || ok
# A hostile filename must not break the gate either — it should still reach a
# verdict rather than crashing into a pass.
RCRCE=$("$GATE" "$BASE" "$R" >/dev/null 2>&1; echo $?)
[ "$RCRCE" = 0 ] || [ "$RCRCE" = 1 ] || [ "$RCRCE" = 3 ] || [ "$RCRCE" = 4 ] \
  && ok || bad "a hostile filename must still produce a defined verdict (rc=$RCRCE)"

# ---------- 4d. only ADDED tests are blocking evidence ----------
# A modified test may be a comment edit, a rename, or a coverage backfill on
# behaviour that already shipped — none of which should fail at base, and none
# of which deserve a terminal. Blocking on them was backwards, given a diff with
# no tests at all only warns.
newrepo modonly
cat > tests/feature-test.sh <<'EOF'
#!/bin/bash
exit 0
EOF
git add -A; git commit -qm "add a passing test"
BASE=$(git rev-parse HEAD)
printf '# a clarifying comment\n' >> tests/feature-test.sh
git add -A; git commit -qm "comment-only edit to an existing test"
[ "$(rc)" = 2 ] && ok || bad "a MODIFIED-only test diff must not block (rc=$(rc))"
has 'not used as blocking evidence' && ok || bad "modified tests must be reported as non-blocking"
has 'NO_NEW_TESTS' && ok || bad "a modified-only diff is still 'no added evidence'"

# ---------- 4e. a non-JS stack with unresolvable deps ----------
# The deps guard was JS-only, so a Python repo failing on imports at base was
# counted as an honest RED that was never earned — the same false-green, for
# every non-JS repo in the fleet.
#
# pytest and python3 are stubbed to exit 127 on an otherwise intact PATH, for
# the layout reason argued at the node case above (BH-1219). The stubbed pytest
# satisfies build_runner's `command -v pytest` on every host, so deps_ready is
# reached; its `python3 -c 'import pytest'` then hits the stub and the gate
# exits 3 through the deps guard rather than through "no runner". Both lines
# are asserted, because rc 3 alone cannot tell those two paths apart.
newrepo pydeps
printf '[project]\nname = "x"\n' > pyproject.toml
mkdir -p tests; printf 'def test_x():\n    assert False\n' > tests/test_x.py
git add -A; git commit -qm "feat: python test, no environment"
mkdir -p "$T/pystub"
for b in pytest python3; do
  cat > "$T/pystub/$b" <<EOS
#!/bin/bash
echo "$b: command not found" >&2
exit 127
EOS
  chmod +x "$T/pystub/$b"
done
RCPY=$(PATH="$T/pystub:$PATH" "$GATE" "$BASE" "$R" >/dev/null 2>&1; echo $?)
[ "$RCPY" = 3 ] && ok || bad "a python repo with no resolvable environment must exit 3, never a trusted RED (rc=$RCPY)"
OUTPY=$(PATH="$T/pystub:$PATH" "$GATE" "$BASE" "$R" 2>&1 || true)
grep -q 'no resolvable environment' <<<"$OUTPY" && ok \
  || bad "a python repo with no resolvable environment must exit via the deps guard (got: $(tail -2 <<<"$OUTPY"))"

# ---------- 5. red at base but still red at head ----------
# Reproduction proven, delivery not. Distinct from a vacuous test, so it gets
# its own exit code rather than being lumped in as a gate failure.
newrepo stillred
cat > tests/feature-test.sh <<'EOF'
#!/bin/bash
. ./app.sh
feature_exists || exit 1
exit 0
EOF
git add -A; git commit -qm "test only, feature never implemented"
[ "$(rc)" = 4 ] && ok || bad "red at base and red at head must exit 4 (rc=$(rc))"
has 'GREEN check FAILED' && ok || bad "a failing head run must be named as such"

# ---------- 6. the base run uses the NEW test against the OLD code ----------
# Not the old test, and not the whole new tree — that distinction is the gate.
newrepo isolation
cat > tests/feature-test.sh <<'EOF'
#!/bin/bash
. ./app.sh
feature_exists || exit 1
[ -f NEWFILE ] && exit 0
exit 1
EOF
echo 'feature_exists() { return 0; }' > app.sh
touch NEWFILE
git add -A; git commit -qm "feat: needs both the function and the new file"
[ "$(rc)" = 0 ] && ok || bad "the base run must see the NEW test but the OLD tree (rc=$(rc))"

# ---------- 7. compound npm test:unit must not arg-append onto the last command ----------
# project-4 2026-09-02 TK-791: `npm run test:unit -- added.ts` appends onto
# `tsx --test ...` (the last && command). tsx without the strip-types loader
# reports `Top-level await not supported (cjs)` and GREEN false-fails while
# `node --test` on the same files exits 0. The tsx stub here fires that same
# CJS error if a .test.ts path reaches it — so a regression is rc=4, not rc=0.
newrepo compoundnpm
printf '%s\n' '{
  "scripts": {
    "test:unit": "node --experimental-strip-types --test tests/suite.test.js && tsx --test tests/render.test.tsx"
  }
}' > package.json
mkdir -p node_modules/.bin tests
cat > node_modules/.bin/tsx <<'EOF'
#!/bin/bash
for a in "$@"; do
  case "$a" in
    *.test.ts)
      echo "ERROR: Top-level await is currently not supported with the \"cjs\" output format" >&2
      exit 1 ;;
  esac
done
exit 0
EOF
chmod +x node_modules/.bin/tsx
cat > tests/suite.test.js <<'EOF'
import { test } from 'node:test';
test('suite placeholder', () => {});
EOF
echo 'placeholder' > tests/render.test.tsx
git add package.json tests
git commit -qm "js suite, compound test:unit"
BASE=$(git rev-parse HEAD)
cat > tests/feature.test.ts <<'EOF'
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { existsSync } from 'node:fs';
test('feature exists', () => { assert.equal(existsSync('FEATURE'), true); });
EOF
touch FEATURE
git add tests/feature.test.ts FEATURE
git commit -qm "feat: feature plus an added .ts unit test"
[ "$(rc)" = 0 ] && ok || bad "compound test:unit must run added .ts files via node, not tsx (rc=$(rc), out: $(out | tail -5))"
has 'GREEN at head' && ok || bad "compound test:unit green check must pass when node --test would"
has 'RED at base' && ok || bad "compound test:unit must still prove red at base"

echo "repro-gate-test: $PASS pass, $FAIL fail"
[ "$FAIL" -eq 0 ]
