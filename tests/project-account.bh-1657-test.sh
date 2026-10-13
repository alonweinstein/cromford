#!/bin/bash
# tests/project-account.bh-1657-test.sh — BH-1657 resolver: which account a
# project is pinned to (settings row account.<project>, env fallback, none),
# path-traversal refusal, rc3 on a missing token file, and no token in stderr.
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
TOK="sk-ant-oat01-FIXTURE-project-3-own-token"
mkdir -p "$T/env/accounts.d" "$T/state"
printf 'CLAUDE_CODE_OAUTH_TOKEN=%s\n' "$TOK" > "$T/env/accounts.d/own:project-3.env"
cache() { jq -n --argjson fa "$(date -u +%s)" --argjson v "$1" '{fetched_at:$fa,values:$v,seeded:{}}' > "$T/state/settings-cache.json"; }
run() { # run <fn> <project> [ENV=...]
  local fn="$1" p="$2"; shift 2
  env HARNESS="$T" JOBS_URL= "$@" bash -c '. "$0"; '"$fn"' "$1"' "$DIR/bin/lib/project-account.sh" "$p" 2>"$T/err"
}

cache '{"account.project-3":"own:project-3"}'
out=$(run account_for_project project-3)
[ "$out" = "label=own:project-3 source=db" ] && ok || bad "db row: $out"
out=$(run account_for_project project-3-staging)
[ "$out" = "label= source=none" ] && ok || bad "exact match only: $out"
out=$(run account_for_project project-5-os ACCOUNT_OWN_PROJECTS=project-3=own:project-3)
[ "$out" = "label= source=none" ] && ok || bad "project-5 unpinned: $out"

rm -f "$T/state/settings-cache.json"
out=$(run account_for_project project-3 ACCOUNT_OWN_PROJECTS="x=own:x,project-3=own:project-3")
[ "$out" = "label=own:project-3 source=env" ] && ok || bad "api down -> env: $out"
out=$(run account_for_project project-3)
[ "$out" = "label= source=none" ] && ok || bad "unset -> none: $out"

cache '{"account.project-3":"../max1"}'
out=$(run account_for_project project-3); rc=$?
[ "$out" = "label= source=none" ] && ok || bad "traversal label must not pin: $out"
grep -q refused "$T/err" && ok || bad "traversal refusal not logged"
cache '{"account.project-3":""}'
out=$(run account_for_project project-3)
[ "$out" = "label= source=none" ] && ok || bad "empty value: $out"
out=$(run account_for_project "")
[ "$out" = "label= source=none" ] && ok || bad "empty project: $out"

cache '{"account.project-3":"own:project-3","account.project-9":"own:project-9"}'
out=$(run project_account_exports project-3); rc=$?
[ "$rc" = 0 ] && [ "$out" = "export CLAUDE_CODE_OAUTH_TOKEN='$TOK'" ] && ok || bad "exports rc=$rc out=$out"
grep -qF "$TOK" "$T/err" && bad "token leaked to stderr" || ok
out=$(run project_account_exports project-9); rc=$?
[ "$rc" = 3 ] && [ -z "$out" ] && ok || bad "missing file -> rc3, got rc=$rc out=$out"
out=$(run project_account_exports project-5-os); rc=$?
[ "$rc" = 1 ] && [ -z "$out" ] && ok || bad "unpinned exports rc1, got rc=$rc"

echo "project-account.bh-1657: $PASS pass, $FAIL fail"
[ "$FAIL" = 0 ]
