#!/bin/bash
# tests/project-account-shared.bh-1657-test.sh — BH-1657: the value `shared` in
# a settings row account.<project> is an explicit UNPIN. The worker refuses an
# empty value and has no DELETE, so without this word an operator who pinned a
# project from the console could never put it back on the shared pool.
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
mkdir -p "$T/env/accounts.d" "$T/state"
# A file NAMED shared.env must not turn the word into a pin either.
printf 'CLAUDE_CODE_OAUTH_TOKEN=sk-ant-oat01-FIXTURE-shared\n' > "$T/env/accounts.d/shared.env"
cache() { jq -n --argjson fa "$(date -u +%s)" --argjson v "$1" '{fetched_at:$fa,values:$v,seeded:{}}' > "$T/state/settings-cache.json"; }
run() { # run <fn> <project> [ENV=...]
  local fn="$1" p="$2"; shift 2
  env HARNESS="$T" JOBS_URL= "$@" bash -c '. "$0"; '"$fn"' "$1"' "$DIR/bin/lib/project-account.sh" "$p" 2>"$T/err"
}

cache '{"account.project-3":"shared"}'
out=$(run account_for_project project-3)
[ "$out" = "label= source=db" ] && ok || bad "db shared -> unpinned from db: $out"
out=$(run project_account_exports project-3); rc=$?
[ "$rc" = 1 ] && [ -z "$out" ] && ok || bad "db shared exports rc=$rc out=$out"
# The db answer wins over the env fallback: `shared` unpins even when the env pins.
out=$(run account_for_project project-3 ACCOUNT_OWN_PROJECTS=project-3=own:project-3)
[ "$out" = "label= source=db" ] && ok || bad "db shared must beat the env pin: $out"

rm -f "$T/state/settings-cache.json"
out=$(run account_for_project project-3 ACCOUNT_OWN_PROJECTS=project-3=shared)
[ "$out" = "label= source=env" ] && ok || bad "env shared -> unpinned from env: $out"

# Neighbours: a real label still pins, and a label that merely CONTAINS the word does too.
cache '{"account.project-3":"own:shared"}'
out=$(run account_for_project project-3)
[ "$out" = "label=own:shared source=db" ] && ok || bad "own:shared is a label: $out"

echo "project-account-shared.bh-1657: $PASS pass, $FAIL fail"
[ "$FAIL" = 0 ]
