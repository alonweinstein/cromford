#!/bin/bash
# tests/issue-list-rest.bh-1641-test.sh — BH-1650: bin/decompose-parent-close.sh
# and bin/unblocked-children.sh read the ai-build issue list through
# gh_rest_issue_list, not `gh issue list`.
#
# The stub speaks REST only: GET repos/<slug>/issues answers a REST page
# (lower-case state, one pull_request row mixed in); any `gh issue list` call is
# recorded and answered with nothing, so a lane still on the CLI reads no issues.
# Both scripts run as the real entry point.
#   HARNESS_TEST_SANDBOX=1 bash tests/issue-list-rest.bh-1641-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null 2>&1 || { echo "FAIL: jq required"; exit 1; }
command -v python3 >/dev/null 2>&1 || { echo "FAIL: python3 required"; exit 1; }
SLUG="example-org/scoutish"

mkdir -p "$T/bin"
cat > "$T/bin/gh" <<'STUB'
#!/bin/bash
printf '%s\n' "$*" >> "$CASE/gh-calls.log"
[ "${1:-}" = api ] || { case "$*" in *"pr list"*) echo '[]' ;; *"issue view"*) echo '{"number":9,"state":"OPEN","title":"the parent"}' ;; esac; exit 0; }
M=GET; P=""; PG=1; prev=""
for a in "$@"; do
  [ "$prev" = -X ] && M="$a"
  case "$a" in repos/*) P="$a" ;; page=*) PG="${a#page=}" ;; esac
  prev="$a"
done
# `gh api` without -i (the parent-close's per-record reads) prints the body only.
send() { case " $* $ARGS " in *" -i "*) printf 'HTTP/2.0 %s X\r\n\r\n%s\n' "$1" "$2" ;; *) printf '%s\n' "$2" ;; esac; }
ARGS="$*"
case "$M $P" in
  "GET "*/pulls)
    [ -f "$CASE/pulls.json" ] || { send 200 ''; exit 0; }
    [ "$PG" = 1 ] || { send 200 '[]'; exit 0; }
    send 200 "$(cat "$CASE/pulls.json")" ;;
  "GET "*/issues)
    [ "$PG" = 1 ] || { send 200 '[]'; exit 0; }
    send "$(cat "$CASE/st-list" 2>/dev/null || echo 200)" "$(cat "$CASE/page.json")" ;;
  "GET "*/issues/*/comments) send 200 '[]' ;;
  "GET "*/issues/*) send 200 "$(cat "$CASE/state.json" 2>/dev/null || echo '{"state":"open","title":"parent","labels":[]}')" ;;
  "POST "*/comments) send 201 '{"id":1}' ;;
  "PATCH "*) echo '{"state":"closed","title":"parent","labels":[]}' > "$CASE/state.json"; send 200 '{"state":"closed"}' ;;
  *) send 200 '' ;;
esac
exit 0
STUB
chmod +x "$T/bin/gh"

newcase() {
  CASE="$T/case-$1"; export CASE
  H="$CASE/h"
  mkdir -p "$H/bin/lib" "$H/logs" "$H/state" "$H/flags" "$H/env" "$H/builds"
  cp "$DIR/bin/lib/gh-rest.sh" "$DIR/bin/lib/gh-rest-var.sh" "$DIR/bin/lib/gh-rest-list.sh" \
     "$DIR/bin/lib/revdep-lib.sh" "$DIR/bin/lib/env-path.sh" "$DIR/bin/lib/dep-verify-lib.sh" "$H/bin/lib/" 2>/dev/null
  cp "$DIR/bin/decompose-parent-close.sh" "$H/bin/"
  printf '#!/bin/bash\nexit 0\n' > "$H/bin/beat.sh"; chmod +x "$H/bin/beat.sh"
  : > "$CASE/gh-calls.log"
  export PATH="$T/bin:$H/bin:$PATH"
}
calls() { cat "$CASE/gh-calls.log"; }
dp() { HARNESS="$H" GH_ISSUES_REPO="$SLUG" GH_ETAG=0 "$H/bin/decompose-parent-close.sh" scoutish 2>/dev/null; }
uc() { HARNESS="$H" GH_ISSUES_REPO="$SLUG" GH_ETAG=0 "$DIR/bin/unblocked-children.sh" scoutish 2>/dev/null; }

# 1. decompose-parent-close: lower-case `closed` children close the parent; the PR row is ignored
newcase dp1
cat > "$CASE/page.json" <<'JSON'
[{"number":11,"state":"closed","state_reason":"completed","title":"BH-9.1 first","body":"Part of #9\nOrder: 1 of 2"},
 {"number":12,"state":"closed","state_reason":"completed","title":"BH-9.2 second","body":"Part of #9\nOrder: 2 of 2"},
 {"number":13,"state":"open","title":"BH-9.3 a PR","body":"Part of #9\nOrder: 3 of 3","pull_request":{"url":"x"}}]
JSON
# BH-949: a child counts only when it closed COMPLETED and a merged PR shipped it.
cat > "$CASE/pulls.json" <<'JSON'
[{"number":21,"html_url":"https://github.com/example-org/scoutish/pull/21","title":"BH-11: first","head":{"ref":"ticket/bh-11"},"state":"closed","merged_at":"2026-09-20T10:00:00Z"},
 {"number":22,"html_url":"https://github.com/example-org/scoutish/pull/22","title":"BH-12: second","head":{"ref":"ticket/bh-12"},"state":"closed","merged_at":"2026-09-20T10:00:00Z"}]
JSON
OUT=$(dp)
[ "$OUT" = 9 ] && ok || bad "1: closed (lower-case) children must close parent #9 (stdout '$OUT'; calls: $(calls))"
calls | grep -q -- '-X PATCH repos/example-org/scoutish/issues/9' && ok || bad "1: parent PATCH expected"
grep -q 'issue list' <<<"$(calls)" && bad "1: no gh issue list call allowed: $(calls | grep 'issue list')" || ok
calls | grep -q -- '-X GET repos/example-org/scoutish/issues .*labels=ai-build' && ok || bad "1: must read the REST list with labels=ai-build"

# 2. 403 page: rc 0, no comment, no close
newcase dp2; cp "$T/case-dp1/page.json" "$T/case-dp1/pulls.json" "$CASE/"; echo 403 > "$CASE/st-list"
OUT=$(dp); RC=$?
[ "$RC" -eq 0 ] && ok || bad "2: 403 must exit 0 (rc=$RC)"
[ -z "$OUT" ] && ok || bad "2: nothing announced on 403 ('$OUT')"
grep -qE -- '-X (POST|PATCH)' <<<"$(calls)" && bad "2: no comment/close after a 403 list: $(calls)" || ok

# 3. unblocked-children: a lower-case closed blocker releases its child
newcase uc1
cat > "$CASE/page.json" <<'JSON'
[{"number":331,"state":"closed","title":"TK-323.1 keys","body":"parent #323"},
 {"number":332,"state":"open","title":"TK-323.2 ui","body":"Blocked-by: #331 (hard)"},
 {"number":340,"state":"open","title":"a PR","body":"Blocked-by: #331 (hard)","pull_request":{"url":"x"}}]
JSON
OUT=$(uc <<<'board issues: CHANGED 331 "TK-323.1" (state: OPEN -> CLOSED)')
grep -q 'UNBLOCKED 332' <<<"$OUT" && ok || bad "3: 332 must be released (got '$OUT')"
grep -q '340' <<<"$OUT" && bad "3: a PR row must never be released ('$OUT')" || ok
grep -q 'issue list' <<<"$(calls)" && bad "3: no gh issue list call allowed" || ok

# 4. unblocked-children: 403 page -> rc 0, nothing emitted, no comment
newcase uc2; cp "$T/case-uc1/page.json" "$CASE/page.json"; echo 403 > "$CASE/st-list"
OUT=$(uc <<<'board issues: CHANGED 331 "TK-323.1" (state: OPEN -> CLOSED)'); RC=$?
[ "$RC" -eq 0 ] && ok || bad "4: rc=$RC"
[ -z "$OUT" ] && ok || bad "4: nothing emitted on 403 ('$OUT')"
grep -q -- '-X POST' <<<"$(calls)" && bad "4: no comment on 403" || ok

echo "issue-list-rest.bh-1641: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
