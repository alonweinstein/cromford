#!/bin/bash
# tests/list-fallthrough.bh-847-test.sh — harness_pr_list falls through to the
# next token rung when a list is RATE-LIMITED, and only then.
#
# THE SILENCE THIS KILLS (BH-847). An App installation token has its own small
# bucket. When it ran out, `harness_pr_list` returned rc 1, the caller logged
# "list failed this tick" and every PR on that repo was invisible for the tick,
# while the box still held two other credentials that would have answered. The
# rule: ONE retry on the next rung the ladder knows, one log line naming the rung
# WORD that answered, and a 404 is never a fall-through.
#
# THE RUNG ORDER IS A QUESTION, NOT A LIST (review finding 1 on PR #867). From
# the app rung the next rung is the DEFAULT PAT only when that PAT can see the
# repo; on the 2026-09-12 project-5 shape it cannot, and the retry has to go
# straight to admin — case H is that case.
# Run from anywhere: tests/list-fallthrough.bh-847-test.sh   (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
mkdir -p "$T/h/env" "$T/h/logs" "$T/h/flags" "$T/h/bin" "$T/h/state" "$T/fixtures" "$T/fakebin"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }

echo 'GH_ADMIN_TOKEN=admintok' > "$T/h/env/github-admin.env"
echo 'GH_APP_SLUG=cromford' > "$T/h/env/github-app.env"
printf '#!/bin/bash\necho apptok\n' > "$T/h/bin/gh-token.sh"; chmod +x "$T/h/bin/gh-token.sh"

jq -n '[
  {number:1, html_url:"https://github.com/o/r/pull/1", title:"one",
   head:{sha:"aaa111", ref:"feat-1"}, base:{ref:"main"}, draft:false,
   user:{login:"operator", type:"User"}, created_at:"2026-01-01T00:00:00Z",
   updated_at:"2026-01-02T00:00:00Z", merged_at:null, closed_at:null,
   state:"open", labels:[]},
  {number:2, html_url:"https://github.com/o/r/pull/2", title:"two",
   head:{sha:"bbb222", ref:"feat-2"}, base:{ref:"main"}, draft:false,
   user:{login:"cromford[bot]", type:"Bot"}, created_at:"2026-01-03T00:00:00Z",
   updated_at:"2026-01-04T00:00:00Z", merged_at:null, closed_at:null,
   state:"open", labels:[]}
]' > "$T/fixtures/pulls.json"

# gh shim: the answer depends on WHICH token is exported, so a rung fall-through
# is observable. Every call appends "<token-word> <argv>" to the argv sink.
cat > "$T/fakebin/gh" <<'GH'
#!/bin/bash
tokword="${GH_TOKEN:-keyring}"
printf '%s %s\n' "$tokword" "$*" >> "$ARGV_SINK"
v="MODE_$tokword"; mode="${!v:-ok}"
# TEST-CHANGE (BH-782): the REST list is read through bin/lib/gh-rest.sh, which
# runs `gh api -i` and classifies the STATUS LINE. So an -i call is answered
# with a status line, a blank line and a body, and the rate-limit shapes that
# used to arrive only on stderr now also arrive as 403/429 carrying the same
# message text — which is where the classifier reads them from. Every mode keeps
# its old stderr line as well, because the per-author `gh pr list` path still
# reads those. The modes, the cases and the assertions are unchanged.
inc=0
if [ "${1:-}" = api ]; then for a in "$@"; do [ "$a" = -i ] && inc=1; done; fi
reply() { # reply <status> <body> — only an -i call gets a status line
  [ "$inc" = 1 ] && { printf 'HTTP/2.0 %s\r\n' "$1"; printf '\r\n'; }
  [ -n "$2" ] && printf '%s\n' "$2"
  case "$1" in 2*) exit 0 ;; *) exit 1 ;; esac
}
case "$mode" in
  limit_graphql)
    [ "$inc" = 1 ] && reply 403 '{"message":"API rate limit already exceeded for installation ID 1"}'
    echo "GraphQL: API rate limit already exceeded for installation ID 1" >&2; exit 1 ;;
  limit_403)
    [ "$inc" = 1 ] && reply 403 '{"message":"API rate limit exceeded for user ID 7"}'
    echo "HTTP 403: API rate limit exceeded for user ID 7 (https://api.github.com/repos)" >&2; exit 1 ;;
  limit_429)
    [ "$inc" = 1 ] && reply 429 '{"message":"Too Many Requests"}'
    echo "HTTP 429: Too Many Requests" >&2; exit 1 ;;
  limit_message)
    case "$*" in *repos/o/r/pulls*) reply 200 '{"message":"API rate limit exceeded"}' ;; esac
    [ "$inc" = 1 ] && reply 403 '{"message":"API rate limit exceeded for user ID 7"}'
    echo "HTTP 403: API rate limit exceeded for user ID 7" >&2; exit 1 ;;
  notfound)
    [ "$inc" = 1 ] && reply 404 '{"message":"Not Found"}'
    echo "HTTP 404: Not Found (https://api.github.com/repos/o/r/pulls)" >&2; exit 1 ;;
  perm)
    [ "$inc" = 1 ] && reply 403 '{"message":"Resource not accessible by integration"}'
    echo "GraphQL: Resource not accessible by integration" >&2; exit 1 ;;
  badcreds)
    [ "$inc" = 1 ] && reply 401 '{"message":"Bad credentials"}'
    echo "HTTP 401: Bad credentials" >&2; exit 1 ;;
  quiet)      exit 1 ;;
  notfoundmsg)
    case "$*" in *repos/o/r/pulls*) reply 200 '{"message":"Not Found"}' ;; esac
    exit 1 ;;
esac
case "${1:-}" in
  api)
    case "$*" in
      *repos/o/r/pulls*) reply 200 "$(cat "$T/fixtures/pulls.json")" ;;
      *repos/*)          exit 0 ;;
      *) exit 1 ;;
    esac ;;
  pr) echo '[{"number":1,"title":"one"},{"number":2,"title":"two"}]' ;;
  *) exit 1 ;;
esac
GH
chmod +x "$T/fakebin/gh"

# The libs are sourced the way a lane sources them: gh-app-auth and
# gh-repo-token first (so _GHRT_DEFAULT_TOK is the lane's own PAT), then the
# App token is exported over it, then gh-pr-list.
drive() { # drive <env-setup> <snippet>
  ( export T="$T" PATH="$T/fakebin:$PATH" HARNESS="$T/h" ARGV_SINK="$T/argv.txt"
    unset HARNESS_PR_AUTHORS GH_PR_LIST_REST_PAGES
    eval "${1:-:}"
    export GH_TOKEN=pattok
    # shellcheck source=/dev/null
    . "$DIR/bin/lib/gh-app-auth.sh"
    # shellcheck source=/dev/null
    . "$DIR/bin/lib/gh-repo-token.sh"
    export GH_TOKEN="${START_TOKEN:-apptok}"
    # shellcheck source=/dev/null
    . "${LIB:-$DIR/bin/lib/gh-pr-list.sh}"
    eval "$2" )
}
reset_sinks() { : > "$T/argv.txt"; : > "$T/h/logs/gh-pr-list.log"; }
# LIST calls only. The rung question now also runs the PAT probe (`api repos/o/r`
# with no /pulls), and counting those as rungs would read "apptok,pattok,admintok"
# for a retry that only ever listed twice.
list_rungs() { awk '/ api .*repos\/[^ ]*\/pulls/ || / pr list /{print $1}' "$T/argv.txt" | uniq | paste -sd, -; }

# case A — App rung rate-limited (GraphQL shape), default PAT can see the repo
# and answers.
reset_sinks
OUT=$(drive 'export MODE_apptok=limit_graphql' 'harness_pr_list o/r open number,title'); RC=$?
[ "$RC" = 0 ] && ok || bad "A: limited app rung should fall through to rc 0 (rc=$RC)"
[ "$(jq -c '[.[].number]' <<<"$OUT" 2>/dev/null)" = "[1,2]" ] && ok || bad "A: PRs from the default rung: $OUT"
[ "$(list_rungs)" = "apptok,pattok" ] && ok || bad "A: rung order should be app then default, got $(list_rungs)"
grep -q "o/r (open): list rate-limited on the app rung — retrying once on the default rung" "$T/h/logs/gh-pr-list.log" \
  && ok || bad "A: no retry line: $(cat "$T/h/logs/gh-pr-list.log")"
grep -q "o/r (open): answered by the default rung" "$T/h/logs/gh-pr-list.log" \
  && ok || bad "A: no answered-by line: $(cat "$T/h/logs/gh-pr-list.log")"
grep -rqE 'apptok|pattok|admintok' "$T/h/logs" && bad "A: a token VALUE reached a log: $(grep -rlE 'apptok|pattok|admintok' "$T/h/logs")" || ok

# case B — no App on this box: the default PAT is limited (403 shape) and the
# admin token answers. ONE retry, so the ladder starts at the current rung.
reset_sinks
OUT=$(drive 'export MODE_pattok=limit_403 START_TOKEN=pattok; touch "$HARNESS/flags/gh-app-tokens-off"' \
            'harness_pr_list o/r open number,title'); RC=$?
rm -f "$T/h/flags/gh-app-tokens-off"
[ "$RC" = 0 ] && ok || bad "B: limited default rung should fall through to admin (rc=$RC)"
[ "$(jq -c '[.[].number]' <<<"$OUT" 2>/dev/null)" = "[1,2]" ] && ok || bad "B: PRs from the admin rung: $OUT"
[ "$(list_rungs)" = "pattok,admintok" ] && ok || bad "B: rung order should be default then admin, got $(list_rungs)"
grep -q "answered by the admin rung" "$T/h/logs/gh-pr-list.log" && ok || bad "B: no admin answered-by line: $(cat "$T/h/logs/gh-pr-list.log")"

# case C — every reachable rung limited: rc 1, no output, and the caller's
# gh_repo_list_failed fires exactly ONCE (the conductor's arm, mirrored).
reset_sinks; : > "$T/failed.txt"
OUT=$(drive 'export MODE_apptok=limit_graphql MODE_pattok=limit_429 MODE_admintok=limit_403' '
  gh_repo_list_failed() { printf "%s\n" "$*" >> "$T/failed.txt"; }
  harness_pr_list o/r open number,title; rc=$?
  [ "$rc" = 0 ] || gh_repo_list_failed merge-conductor o/r "PR list failed this tick"
  printf %s "$rc" > "$T/rc.txt"')
RC=$(cat "$T/rc.txt")
[ "$RC" != 0 ] && ok || bad "C: every rung limited must stay non-zero (rc=$RC)"
[ -z "$OUT" ] && ok || bad "C: a failed list must print nothing, got: $OUT"
[ "$(wc -l < "$T/failed.txt")" = 1 ] && ok || bad "C: gh_repo_list_failed should fire once, got $(cat "$T/failed.txt")"

# case D — 404 is NOT a fall-through: the invisible-repo path keeps it.
reset_sinks
OUT=$(drive 'export MODE_apptok=notfound' 'harness_pr_list o/r open number,title'); RC=$?
[ "$RC" != 0 ] && ok || bad "D: a 404 list must still fail (rc=$RC)"
[ "$(list_rungs)" = "apptok" ] && ok || bad "D: a 404 must not try a second rung, got $(list_rungs)"
! grep -q "retrying once" "$T/h/logs/gh-pr-list.log" && ok || bad "D: 404 wrote a retry line: $(cat "$T/h/logs/gh-pr-list.log")"

# case E — the REST body (not stderr) carries the limit message.
reset_sinks
OUT=$(drive 'export MODE_apptok=limit_message' 'harness_pr_list o/r open number,title'); RC=$?
[ "$RC" = 0 ] && ok || bad "E: a limit message in the REST body should fall through (rc=$RC)"
[ "$(list_rungs)" = "apptok,pattok" ] && ok || bad "E: rung order: $(list_rungs)"

# case F — negative list: nothing else is a limit.
for mode in perm badcreds quiet notfoundmsg; do
  reset_sinks
  drive "export MODE_apptok=$mode" 'harness_pr_list o/r open number,title' >/dev/null 2>&1
  [ "$(list_rungs)" = "apptok" ] && ok || bad "F/$mode: must not retry on another rung, got $(list_rungs)"
  ! grep -q "retrying once" "$T/h/logs/gh-pr-list.log" && ok || bad "F/$mode: wrote a retry line"
done

# case G — GH_TOKEN is exactly what it was on entry, retry or not.
for setup in 'export MODE_apptok=limit_graphql' 'export MODE_apptok=limit_graphql MODE_pattok=limit_403' 'export MODE_apptok=notfound' ':'; do
  reset_sinks
  GOT=$(drive "$setup" 'harness_pr_list o/r open number,title >/dev/null 2>&1; printf %s "${GH_TOKEN:-unset}"')
  [ "$GOT" = apptok ] && ok || bad "G: token after the call should be the entry token, got $GOT ($setup)"
done
reset_sinks
GOT=$(drive 'export MODE_keyring=limit_graphql; START_TOKEN=""' '
  unset GH_TOKEN; harness_pr_list o/r open number,title >/dev/null 2>&1; printf %s "${GH_TOKEN:-unset}"')
[ "$GOT" = unset ] && ok || bad "G: an unset token must come back unset, got $GOT"

# case H — review finding 1: the app rung steps to ADMIN when the default PAT
# cannot see the repo. The default PAT 404s here (the project-5 shape), so a
# ladder that always stepped to `default` would spend its one retry on a
# credential that cannot answer and report the tick blind.
reset_sinks
OUT=$(drive 'export MODE_apptok=limit_graphql MODE_pattok=notfound' 'harness_pr_list o/r open number,title'); RC=$?
[ "$RC" = 0 ] && ok || bad "H: the admin rung should answer (rc=$RC)"
[ "$(jq -c '[.[].number]' <<<"$OUT" 2>/dev/null)" = "[1,2]" ] && ok || bad "H: PRs from the admin rung: $OUT"
[ "$(list_rungs)" = "apptok,admintok" ] && ok || bad "H: rung order should be app then admin, got $(list_rungs)"
grep -q "list rate-limited on the app rung — retrying once on the admin rung" "$T/h/logs/gh-pr-list.log" \
  && ok || bad "H: retry line should name the admin rung: $(cat "$T/h/logs/gh-pr-list.log")"
grep -q "answered by the admin rung" "$T/h/logs/gh-pr-list.log" \
  && ok || bad "H: no admin answered-by line: $(cat "$T/h/logs/gh-pr-list.log")"
grep -rqE 'apptok|pattok|admintok' "$T/h/logs" && bad "H: a token VALUE reached a log" || ok

# mutation — delete the limit classifier and case A stops falling through.
mkdir -p "$T/mutlib"
cp "$DIR/bin/lib/gh-rest.sh" "$DIR/bin/lib/gh-rest-var.sh" "$T/mutlib/"
cp "$DIR/bin/lib/gh-pr-list.sh" "$T/mutlib/gh-pr-list.sh"
sed -i '/_HPL_LIMITED=1/d' "$T/mutlib/gh-pr-list.sh"
reset_sinks
RC=0
OUT=$(LIB="$T/mutlib/gh-pr-list.sh" drive 'export MODE_apptok=limit_graphql' 'harness_pr_list o/r open number,title') || RC=$?
[ "$RC" != 0 ] && ok || bad "mutation: without the limit classifier the list must NOT fall through (rc=$RC out=$OUT)"

echo "list-fallthrough: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
