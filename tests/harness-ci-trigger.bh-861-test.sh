#!/bin/bash
# tests/harness-ci-trigger.bh-861-test.sh — BH-861: A PR WITH NO CI IS NOT A PR
# THAT PASSED.
#
# THE SILENCE THIS KILLS. `Harness CI` filtered `pull_request` on BASE branch
# `[main]`, so every stacked child PR (base `ticket/**`) got no run at all, and
# the merge conductor answered `re-review deferred — ci=absent` for them
# forever. 15 clean PRs sat there.
#
# So: the pull_request base filter carries BOTH `main` and `ticket/**`, and
# `push` stays main-only on purpose (a run per push to every ticket branch is
# double CI spend for nothing).
#
# Asserted against the real .github/workflows/harness-ci.yml. No network.
# Run from anywhere: tests/harness-ci-trigger.bh-861-test.sh   (exit 0 = all pass)
set -uo pipefail
DIR=$(cd "$(dirname "$0")/.." && pwd)
WF="${BH861_WORKFLOW:-$DIR/.github/workflows/harness-ci.yml}"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

[ -f "$WF" ] || { echo "FAIL: workflow not found at $WF"; exit 1; }

# The `branches:` line inside each trigger block, read positionally so a
# missing block yields an empty string (and fails) rather than the other's line.
block_branches() {
  awk -v want="$1" '
    /^  [a-z_]+:/ { inblk = ($0 ~ "^  "want":") }
    inblk && /^    branches:/ { print; exit }
  ' "$WF"
}

PR_LINE=$(block_branches pull_request)
PUSH_LINE=$(block_branches push)

# (d) both trigger blocks must actually declare a base filter
if [ -n "$PR_LINE" ]; then ok; else bad "no 'branches:' line under pull_request: in $WF"; fi
if [ -n "$PUSH_LINE" ]; then ok; else bad "no 'branches:' line under push: in $WF"; fi

# (a) pull_request runs on main AND on stacked ticket bases
case "$PR_LINE" in
  *main*) ok ;;
  *) bad "pull_request branches must still include main, got: ${PR_LINE:-<none>}" ;;
esac
case "$PR_LINE" in
  *'ticket/**'*) ok ;;
  *) bad "pull_request branches must include 'ticket/**' (BH-861), got: ${PR_LINE:-<none>}" ;;
esac

# (b) push stays main-only
NORM_PUSH=$(printf '%s' "$PUSH_LINE" | sed 's/^ *branches: *//; s/ //g')
if [ "$NORM_PUSH" = "[main]" ]; then ok; else bad "push branches must be exactly [main], got: ${PUSH_LINE:-<none>}"; fi

# (c) exactly one ticket/** in the file — proves push was not widened too
N=$(grep -c 'ticket/\*\*' "$WF")
if [ "$N" = "1" ]; then ok; else bad "'ticket/**' must appear exactly once in $WF, found $N"; fi

echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
