#!/bin/bash
# tests/pre-arm-guards-test.sh — bin/pre-arm-guards.sh against a gh shim.
# Run from anywhere: tests/pre-arm-guards-test.sh   (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
export PRE_ARM_WAIT_SECS=3 PRE_ARM_POLL_SECS=0 MODE_FILE="$T/mode"
PASS=0; FAIL=0
ok()   { PASS=$((PASS+1)); }
bad()  { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
mkdir -p "$T/bin"
# gh shim driven by $MODE_FILE: noworkflow | success | moved | failure | infra | cancelled | timed_out | hang
cat > "$T/bin/gh" <<'SH'
#!/bin/bash
MODE=$(cat "$MODE_FILE")
case "$1 $2" in
  "workflow view") [ "$MODE" = noworkflow ] && exit 1; exit 0 ;;
  "workflow run")  echo "run $*" >> "$MODE_FILE.calls"; exit 0 ;;
  "run list")      echo '[{"databaseId":777,"createdAt":"2999-01-01T00:00:00Z"}]' ;;
  # TEST-CHANGE (BH-1585): the workflow read, the run lookup and the run status
  # are REST through bin/lib/gh-rest.sh (`gh api -i -X GET <path>`: status line,
  # blank line, body). Same modes, same answers, in the REST shape.
  "api -i")
    case "$*" in
      *actions/workflows/static-guards.yml/runs*)
        printf 'HTTP/2.0 200\r\n\r\n{"workflow_runs":[{"id":777,"created_at":"2999-01-01T00:00:00Z"}]}\n' ;;
      *actions/workflows/static-guards.yml*)
        [ "$MODE" = noworkflow ] && { printf 'HTTP/2.0 404\r\n\r\n{"message":"Not Found"}\n'; exit 1; }
        printf 'HTTP/2.0 200\r\n\r\n{"id":1,"path":".github/workflows/static-guards.yml"}\n' ;;
      *actions/runs/777*)
        printf 'HTTP/2.0 200\r\n\r\n'
        case "$MODE" in
          success|moved) echo '{"status":"completed","conclusion":"success"}' ;;
          failure|infra) echo '{"status":"completed","conclusion":"failure"}' ;;
          cancelled) echo '{"status":"completed","conclusion":"cancelled"}' ;;
          timed_out) echo '{"status":"completed","conclusion":"timed_out"}' ;;
          *)       echo '{"status":"in_progress","conclusion":null}' ;;
        esac ;;
      *) printf 'HTTP/2.0 404\r\n\r\n{}\n'; exit 1 ;;
    esac ;;
  "api repos/org/repo/branches/main")
    if [ "$MODE" = moved ]; then echo cccccccccccccccccccccccccccccccccccccccc; else echo aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa; fi ;;
  "run view")
    case "$*" in
      *--log-failed*)
        if [ "$MODE" = infra ]; then printf 'The merge ref must be against CURRENT main\nmerge-ref base=  origin/main=abc\nmerge ref stale or base is not main\n##[error]Process completed with exit code 1.\n';
        else printf ' FAIL  tests/level2-unit/scripts-local-env-ratchet.test.ts > every script imports the loader FIRST\n ❯ tests/level2-unit/scan-credit-config.test.ts (3 tests | 1 failed)\n'; fi ;;
      *--log)
        printf 'main=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa  pr-head=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb\n' ;;
      *) case "$MODE" in
           success|moved) echo '{"status":"completed","conclusion":"success"}' ;;
           failure|infra) echo '{"status":"completed","conclusion":"failure"}' ;;
           cancelled) echo '{"status":"completed","conclusion":"cancelled"}' ;;
           timed_out) echo '{"status":"completed","conclusion":"timed_out"}' ;;
           *)       echo '{"status":"in_progress","conclusion":null}' ;;
         esac ;;
    esac ;;
  *) exit 1 ;;
esac
SH
chmod +x "$T/bin/gh"; export PATH="$T/bin:$PATH"
# HARNESS is pinned to the scratch tree so the script's gh-app-auth arm looks for
# $T/env/github-app.env (absent) instead of falling back to a live /root/harness
# and minting a real token for org/repo from inside a fixture.
run() { HARNESS="$T" "$DIR/bin/pre-arm-guards.sh" org/repo 42 2>"$T/err"; }

echo noworkflow > "$MODE_FILE"; OUT=$(run); RC=$?
[ "$RC" -eq 2 ] && [ -z "$OUT" ] && grep -q "no static-guards.yml" "$T/err" && ok || bad "no workflow → rc 2 silent stdout (rc=$RC out=$OUT err=$(cat "$T/err"))"
[ ! -f "$MODE_FILE.calls" ] && ok || bad "no dispatch when the workflow is absent"

echo success > "$MODE_FILE"; OUT=$(run); RC=$?
[ "$RC" -eq 0 ] && [ -z "$OUT" ] && ok || bad "green → rc 0 (rc=$RC out=$OUT)"
grep -q "run static-guards.yml -R org/repo --ref main -f pr=42" "$MODE_FILE.calls" && ok || bad "dispatch shape (got: $(cat "$MODE_FILE.calls"))"

echo moved > "$MODE_FILE"; OUT=$(run); RC=$?
[ "$RC" -eq 3 ] && [ -z "$OUT" ] && grep -q "main is now cccccccc" "$T/err" && ok || bad "green against a main that moved → rc 3 retry, never rc 0 (rc=$RC out=$OUT err=$(cat "$T/err"))"

echo failure > "$MODE_FILE"; OUT=$(run); RC=$?
[ "$RC" -eq 1 ] && ok || bad "red → rc 1 (rc=$RC)"
[ "$OUT" = $'tests/level2-unit/scan-credit-config.test.ts\ntests/level2-unit/scripts-local-env-ratchet.test.ts' ] && ok || bad "red names the failing files sorted unique (got: $OUT)"

echo infra > "$MODE_FILE"; OUT=$(run); RC=$?
[ "$RC" -eq 2 ] && [ -z "$OUT" ] && grep -q "before the guards ran" "$T/err" && ok || bad "a failure naming no test file → rc 2, not a park (rc=$RC out=$OUT err=$(cat "$T/err"))"

echo cancelled > "$MODE_FILE"; OUT=$(run); RC=$?
[ "$RC" -eq 3 ] && [ -z "$OUT" ] && grep -q "not green, retry" "$T/err" && ok || bad "cancelled run → rc 3 (rc=$RC out=$OUT err=$(cat "$T/err"))"

echo hang > "$MODE_FILE"; OUT=$(run); RC=$?
[ "$RC" -eq 3 ] && [ -z "$OUT" ] && grep -q "not finished" "$T/err" && ok || bad "run still running when the wait ends → rc 3 retry, never rc 2 (rc=$RC err=$(cat "$T/err"))"

echo timed_out > "$MODE_FILE"; OUT=$(run); RC=$?
[ "$RC" -eq 3 ] && [ -z "$OUT" ] && grep -q "time budget" "$T/err" && ok || bad "runner-side timeout → rc 3 retry (rc=$RC out=$OUT err=$(cat "$T/err"))"

echo "pre-arm-guards: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
