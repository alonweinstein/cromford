#!/bin/bash
# tests/guard-silenced-test.sh — a fix round that makes a guard pass by editing
# the guard is not a fix.
#
# BH-641 names the shape: a review blocks on a static check, the fix round
# answers it by adding the offending path to the checker's own allow-list (or
# its ignore file, or its fixture), the guard goes quiet, and the code the guard
# was pointing at never changed. bin/lib/guard-silenced.sh classifies a changed-
# file list so the mechanical gates in bin/run-build.sh and bin/blocked-
# resolver.sh can refuse that diff without asking an LLM to notice.
#
# THE NEGATIVES CARRY THE WEIGHT. This classifier gates an irreversible action
# (a build BLOCK, a push refused), so every adversarial negative from the plan's
# system-invariants section is here: one real code file in the diff means
# CODE_CHANGED, a doc inside checks/ is documentation, a test is not a fixture,
# and a manifest or a workflow is scope-gate territory, not guard silencing.
#
# Run from anywhere: tests/guard-silenced-test.sh   (exit 0 = all pass)
set -uo pipefail
# shellcheck source=tests/lib/scratch.sh
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

LIB="$DIR/bin/lib/guard-silenced.sh"
[ -r "$LIB" ] || { echo "FAIL: bin/lib/guard-silenced.sh is missing — the classifier this suite is about does not exist"; exit 1; }
# shellcheck source=/dev/null
. "$LIB"

# classify <expected-word> <expected-rc> <path>... — drives gs_classify exactly
# as the gates do: the changed-file list on stdin, the word on stdout, the rc as
# the block/allow signal.
classify() {
  local want="$1" wantrc="$2"; shift 2
  local got rc
  got=$(printf '%s\n' "$@" | gs_classify); rc=$?
  [ "$got" = "$want" ] && [ "$rc" = "$wantrc" ] \
    && ok || bad "[$*] -> $got (rc $rc), expected $want (rc $wantrc)"
}

# ============================================================================
# 1. Positives — every path in the diff is a guard's own rule, list or fixture
# ============================================================================
classify GUARD_SILENCED 1 '.eslintignore'
classify GUARD_SILENCED 1 'checks/secret-literals/rules.yml'
classify GUARD_SILENCED 1 'tests/fixtures/mergify/x.yml' '__snapshots__/y.snap'
classify GUARD_SILENCED 1 '.gitleaks.toml'
classify GUARD_SILENCED 1 'config/generated-paths.conf'
classify GUARD_SILENCED 1 '.gitleaksignore'
classify GUARD_SILENCED 1 '.semgrepignore' '.prettierignore'
classify GUARD_SILENCED 1 'tests/env-path-allowlist.d/project-5.txt'
classify GUARD_SILENCED 1 'tests/fleet-projects-allowlist.txt'
classify GUARD_SILENCED 1 'guardrails/verification-map-freshness/check.sh'
classify GUARD_SILENCED 1 'eslint.config.mjs'
classify GUARD_SILENCED 1 'src/testdata/rows.json'
classify GUARD_SILENCED 1 'src/components/__snapshots__/Table.test.tsx.snap'
classify GUARD_SILENCED 1 'apps/web/.eslintrc.json' 'semgrep.yml'

# ============================================================================
# 2. Adversarial negatives — one line of real code makes it a real fix round
# ============================================================================
classify CODE_CHANGED 0 'src/lib/x.ts' '.eslintignore'
classify CODE_CHANGED 0 'tests/x-test.sh'
classify CODE_CHANGED 0 'checks/README.md'
classify CODE_CHANGED 0 'docs/verification-map/x.md'
classify CODE_CHANGED 0 'bin/foo.sh' 'tests/fixtures/a.json'
classify CODE_CHANGED 0 'package.json'
classify CODE_CHANGED 0 '.github/workflows/ci.yml'
classify CODE_CHANGED 0 'guardrails/lib/escape-hatch.sh' 'bin/run-build.sh'
classify CODE_CHANGED 0 'tsconfig.json'
classify CODE_CHANGED 0 'checks/secret-literals/README.md'

# ============================================================================
# 3. Empty — a fix round that produced no diff is not silencing anything
# ============================================================================
[ "$(printf '' | gs_classify)" = EMPTY ] \
  && ok || bad "no paths at all must classify EMPTY (got $(printf '' | gs_classify))"
printf '' | gs_classify >/dev/null; [ "$?" = 0 ] \
  && ok || bad "EMPTY must never block — the 'fix round produced no commit' path already owns that case"
[ "$(printf '\n\n' | gs_classify)" = EMPTY ] \
  && ok || bad "blank lines are not paths (got $(printf '\n\n' | gs_classify))"

# ============================================================================
# 4. GUARD_SILENCED_EXTRA_GLOBS — a target repo extends the list without a fork
# ============================================================================
[ "$(printf '%s\n' '.harness/rules/x.yml' | gs_classify)" = CODE_CHANGED ] \
  && ok || bad "an unknown path is code until a repo says otherwise"
export GUARD_SILENCED_EXTRA_GLOBS='.harness/rules/*'
classify GUARD_SILENCED 1 '.harness/rules/x.yml'
classify CODE_CHANGED 0 '.harness/rules/x.yml' 'src/app/page.tsx'
unset GUARD_SILENCED_EXTRA_GLOBS
[ "$(printf '%s\n' '.harness/rules/x.yml' | gs_classify)" = CODE_CHANGED ] \
  && ok || bad "with the extra globs unset the path is code again"

# ============================================================================
# 5. The shapes git actually hands the gate
# ============================================================================
classify GUARD_SILENCED 1 './.eslintignore'
classify CODE_CHANGED 0 './src/a.ts' './.eslintignore'

echo "guard-silenced: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ] || exit 1
