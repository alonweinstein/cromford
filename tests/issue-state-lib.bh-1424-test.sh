#!/bin/bash
# tests/issue-state-lib.bh-1424-test.sh — App-token REST reads for issue close-outs.
#
# WHAT THIS PINS AND WHY. The helper that reads and closes issues used the
# GraphQL-backed `gh issue` subcommands, which the hub's fine-grained PAT cannot
# see (Issues:Read is missing). The helper already arms itself with the App
# installation token for the repo, but the call must be REST so the token's
# permissions actually apply. This suite proves that a default PAT that answers
# 403 still yields the right answer once the App rung is armed.
#
# Run from anywhere: tests/issue-state-lib.bh-1424-test.sh   (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null 2>&1 || { echo "jq missing — skipping"; exit 0; }

LIB="$DIR/bin/lib/issue-state-lib.sh"
if [ ! -r "$LIB" ]; then
  echo "FAIL: bin/lib/issue-state-lib.sh does not exist"
  exit 1
fi

mkdir -p "$T/h/bin/lib" "$T/h/env" "$T/h/flags" "$T/bin"
cp "$LIB" "$T/h/bin/lib/"
[ -r "$DIR/bin/lib/gh-rest.sh" ] && cp "$DIR/bin/lib/gh-rest.sh" "$T/h/bin/lib/"
# Deliberately do NOT copy gh-app-auth.sh: this test mints its own App token.
: > "$T/h/env/global.env"

export GH_ARGS="$T/gh-args.txt"; : > "$GH_ARGS"
export ISSUE_JSON="$T/issue.json"
printf '{"state":"closed","body":"plain body","labels":[{"name":"ai-build"}]}' > "$ISSUE_JSON"

# The default token is a PAT (not ghs_). The stub 403s every REST issue call
# unless GH_TOKEN starts with ghs_, which is the shape of an App token.
cat > "$T/bin/gh" <<'SH'
#!/bin/bash
printf '%s\n' "$*" >> "$GH_ARGS"
case "$GH_TOKEN" in
  ghs_*) ;;
  *)
    printf 'HTTP/1.1 403 Forbidden\r\n\r\n{"message":"Resource not accessible by personal access token"}\n'
    exit 1
    ;;
esac
case "$*" in
  *"api -i -X GET"*"issues"*)
    printf 'HTTP/1.1 200 OK\r\n\r\n'; cat "$ISSUE_JSON" ;;
  *"api -i -X POST"*"comments"*)
    printf 'HTTP/1.1 201 Created\r\n\r\n{"id":1}\n' ;;
  *"api -i -X PATCH"*"issues"*)
    printf 'HTTP/1.1 200 OK\r\n\r\n{"state":"closed"}\n' ;;
  *"api -i -X DELETE"*"labels/ai-build"*)
    printf 'HTTP/1.1 200 OK\r\n\r\n[]\n' ;;
esac
exit 0
SH
chmod +x "$T/bin/gh"
export PATH="$T/bin:$PATH"

export HARNESS="$T/h"
export GH_TOKEN="ghp_default_pat"
# shellcheck source=bin/lib/issue-state-lib.sh
. "$T/h/bin/lib/issue-state-lib.sh" || { echo "FAIL: the lib could not be sourced"; exit 1; }

# Override the App-token arm: tests should not depend on the real minting script.
gh_auth_for() {
  [ "${APP_TOKEN_MODE:-0}" = 1 ] || return 1
  export GH_TOKEN="ghs_testapp_$(date +%s)"
  return 0
}

# ════════════════════════════════════════════════════════════════════════════
# 1. Default PAT path: reads are unverifiable.
# ════════════════════════════════════════════════════════════════════════════
: > "$GH_ARGS"
OUT=$(issue_state example-org/proj 1424 "$T/h"); RC=$?
[ "$RC" = 2 ] && ok || bad "a PAT-only box must answer UNKNOWN rc 2 (rc=$RC out=$OUT)"
grep -q 'api -i -X GET repos/example-org/proj/issues/1424' "$GH_ARGS" \
  && ok || bad "the PAT path must still attempt the REST read (got: $(cat "$GH_ARGS"))"

export APP_TOKEN_MODE=1

# ════════════════════════════════════════════════════════════════════════════
# 2. App-token path: reads succeed and close-out runs to stripped.
# ════════════════════════════════════════════════════════════════════════════
: > "$GH_ARGS"
OUT=$(issue_state example-org/proj 1424 "$T/h"); RC=$?
[ "$RC" = 0 ] && [ "$OUT" = CLOSED ] && ok \
  || bad "issue_state must return CLOSED when armed with an App token (rc=$RC out=$OUT)"
# Verify the GET went through the App token shape by inspecting the stub log.
grep -q 'api -i -X GET repos/example-org/proj/issues/1424' "$GH_ARGS" \
  && ok || bad "issue_state must use a REST GET when armed (got: $(cat "$GH_ARGS"))"

: > "$GH_ARGS"
W=$(issue_close_shipped example-org/proj 1424 "shipped comment" "$T/h"); RC=$?
[ "$RC" = 0 ] && [ "$W" = stripped ] && ok \
  || bad "issue_close_shipped must run comment→close→read→strip and answer stripped (rc=$RC w=$W)"
grep -q 'api -i -X POST repos/example-org/proj/issues/1424/comments' "$GH_ARGS" \
  && ok || bad "must POST the comment (got: $(cat "$GH_ARGS"))"
grep -q 'api -i -X PATCH repos/example-org/proj/issues/1424' "$GH_ARGS" \
  && ok || bad "must PATCH close (got: $(cat "$GH_ARGS"))"
grep -q 'api -i -X GET repos/example-org/proj/issues/1424' "$GH_ARGS" \
  && ok || bad "must GET read-back (got: $(cat "$GH_ARGS"))"
grep -q 'api -i -X DELETE repos/example-org/proj/issues/1424/labels/ai-build' "$GH_ARGS" \
  && ok || bad "must DELETE ai-build (got: $(cat "$GH_ARGS"))"

# ════════════════════════════════════════════════════════════════════════════
# 3. If the arm function is disabled, the whole helper stays UNKNOWN / fails.
# ════════════════════════════════════════════════════════════════════════════
gh_auth_for() { return 1; }
: > "$GH_ARGS"
OUT=$(issue_state example-org/proj 1424 "$T/h"); RC=$?
[ "$RC" = 2 ] && ok || bad "with no App token, issue_state must stay UNKNOWN (rc=$RC out=$OUT)"

echo "issue-state-lib.bh-1424: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
