#!/bin/bash
# tests/issue-comment-cmd.bh-5820-test.sh — BH-5820: the hub side of the
# console's comment_issue command, and the Pages fallback that queues it.
#
# bin/lib/issue-comment-cmd.sh posts ONE comment on a GitHub issue as the App,
# exactly once per console command id: the comment carries the marker
# `<!-- mc-command:<id> -->`, and a re-run that finds the marker posts nothing.
# bin/poll-commands.sh runs it from one marked arm.
#
# `gh` is a stub on PATH. It keeps the issue and its comments as state, so a
# comment POST is seen by the next comments read. gh_auth_for and gh_auth_reset
# are stubs defined after the lib is sourced.
#
# Sections: C1-C3 posts and the per-id marker, C4-C5 and C8 retryable failures,
# C6-C7 refusals, C9 the poller arm, C10 the poller's unknown-type arm, C11 the
# Pages fallback source, driven by its node suite when console-ui deps are in.
# Run from anywhere: tests/issue-comment-cmd.bh-5820-test.sh   (exit 0 = pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
LIB="$DIR/bin/lib/issue-comment-cmd.sh"
PC="$DIR/bin/poll-commands.sh"
PAGES_LIB="$DIR/console-ui/functions/_lib/board-commands.js"
[ -r "$LIB" ] || { echo "FAIL: $LIB is missing"; exit 1; }

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

mkdir -p "$T/h" "$T/stubbin" "$T/state"
scratch_install_closure bin/fleet-conf.sh "$T/h" >/dev/null || { echo "FAIL: cannot install fleet-conf.sh"; exit 1; }
cat > "$T/h/fleet.conf" <<'EOF'
# fixture
fixture-proj example-org/fixture -                     -              1 hub
inapp-proj   example-org/inapp   https://inapp.example /api/board     6 box-x
EOF
export FLEET_CONF="$T/h/fleet.conf"

# gh stub. One log line per call: the GH_TOKEN it ran with, its argv, and its
# stdin (or -), as printed by the printf below.
# State: $GHSTATE/issue.json is the issue, $GHSTATE/comments.json its comments;
# a comment POST appends to it. GH_ISSUE_RC/_ERR, GH_COMMENTS_RC/_ERR and
# GH_POST_RC/_ERR make one kind of call fail.
cat > "$T/stubbin/gh" <<'EOF'
#!/bin/bash
method=GET; path=""; input=0; a=("$@")
for ((i=0; i<${#a[@]}; i++)); do
  case "${a[$i]}" in
    -X) method="${a[$((i+1))]}" ;;
    --input) input=1 ;;
    repos/*) path="${a[$i]}" ;;
  esac
done
body=-; [ "$input" = 1 ] && body=$(cat)
printf 'TOKEN=%s %s BODY=%s\n' "${GH_TOKEN:-}" "$*" "$body" >> "$GHLOG"
fail() { [ -n "$2" ] && echo "$2" >&2; exit "$1"; }
case "$method $path" in
  "GET repos/"*/issues/[0-9]*/comments*)
    [ "${GH_COMMENTS_RC:-0}" = 0 ] || fail "$GH_COMMENTS_RC" "${GH_COMMENTS_ERR:-}"
    cat "$GHSTATE/comments.json" ;;
  "GET repos/"*/issues/[0-9]*)
    [ "${GH_ISSUE_RC:-0}" = 0 ] || fail "$GH_ISSUE_RC" "${GH_ISSUE_ERR:-}"
    cat "$GHSTATE/issue.json" ;;
  "POST repos/"*/comments)
    [ "${GH_POST_RC:-0}" = 0 ] || fail "$GH_POST_RC" "${GH_POST_ERR:-}"
    jq -c --argjson c "$body" '. + [{id: (length + 1), body: $c.body}]' "$GHSTATE/comments.json" > "$GHSTATE/c.tmp" \
      && mv "$GHSTATE/c.tmp" "$GHSTATE/comments.json"
    echo '{"id":1}' ;;
  *) fail 9 "gh stub: unexpected call $method $path" ;;
esac
EOF
chmod +x "$T/stubbin/gh"

# Stubs defined AFTER the lib, so they replace gh-app-auth.sh's real ones.
# STUB_TOKEN is the token gh_auth_for leaves behind (an App token by default).
cat > "$T/stubs.sh" <<'EOF'
gh_auth_for() { printf 'gh_auth_for %s\n' "$1" >> "$GHLOG"; export GH_TOKEN="${STUB_TOKEN:-ghs_fixture_app}"; return 0; }
gh_auth_reset() { printf 'gh_auth_reset\n' >> "$GHLOG"; export GH_TOKEN=ghp_fixture_pat; }
EOF

GHLOG="$T/gh.log"; GHSTATE="$T/state"
issue() { # issue [pr]
  if [ "${1:-}" = pr ]; then jq -nc '{number:7,state:"open",title:"t",body:"",labels:[],pull_request:{url:"x"}}'
  else jq -nc '{number:7,state:"open",title:"t",body:"",labels:[]}'; fi > "$GHSTATE/issue.json"
}
reset_state() { issue "$@"; echo '[]' > "$GHSTATE/comments.json"; }
# icc <project> <payload> <id>: stdout in OUT, rc in RC. The log is cleared
# per call; the comment state is not, so C2 sees what C1 posted.
icc() {
  : > "$GHLOG"
  OUT=$(PATH="$T/stubbin:$PATH" HARNESS="$T/h" GHLOG="$GHLOG" GHSTATE="$GHSTATE" GH_TOKEN=ghp_fixture_pat \
    bash -c 'set -uo pipefail; . "$0"; . "$1"; icc_run "$2" "$3" "$4"' "$LIB" "$T/stubs.sh" "$@"); RC=$?
}
posts() { grep -c -- '-X POST repos/example-org/fixture/issues/7/comments' "$GHLOG" 2>/dev/null || true; }
repo_calls() { grep -c 'repos/' "$GHLOG" 2>/dev/null || true; }
ncomments() { jq length "$GHSTATE/comments.json"; }

echo "--- C1: one comment, as the App, with the command marker"
reset_state
icc fixture-proj '{"issue":7,"body":"hello"}' 41
PB=$(grep -- '-X POST' "$GHLOG" | sed 's/.* BODY=//')
[ "$RC" = 0 ] && [ "$OUT" = "commented on #7 as the App (command 41)" ] && [ "$(posts)" = 1 ] \
  && [ "$(jq -r .body <<<"$PB")" = "$(printf 'hello\n\n<!-- mc-command:41 -->')" ] \
  && grep -q '^TOKEN=ghs_fixture_app ' <<<"$(grep -- '-X POST' "$GHLOG")" \
  && ! grep -q 'hello' <<<"$(grep -- '-X POST' "$GHLOG" | sed 's/ BODY=.*//')" \
  && grep -q '^gh_auth_reset$' "$GHLOG" \
  && ok || bad "C1 (rc=$RC out=$OUT log=$(cat "$GHLOG"))"
# The comments read pages through every comment, never just the first page.
grep -q -- '--paginate' <<<"$(grep -- 'issues/7/comments' "$GHLOG" | grep -v -- '-X POST')" && ok || bad "C1 comments read is paginated"

echo "--- C2: the same command id again posts nothing"
icc fixture-proj '{"issue":7,"body":"hello"}' 41
[ "$RC" = 0 ] && [ "$OUT" = "comment already posted on #7 (command 41)" ] && [ "$(posts)" = 0 ] && [ "$(ncomments)" = 1 ] \
  && ok || bad "C2 (rc=$RC out=$OUT n=$(ncomments))"
# The marker of id 4 must not match a comment for id 41.
icc fixture-proj '{"issue":7,"body":"hello"}' 4
[ "$RC" = 0 ] && [ "$(posts)" = 1 ] && [ "$(ncomments)" = 2 ] && ok || bad "C2b id 4 is not id 41 (rc=$RC out=$OUT)"

echo "--- C3: the same text under a new id is a new comment"
icc fixture-proj '{"issue":7,"body":"hello"}' 42
[ "$RC" = 0 ] && [ "$OUT" = "commented on #7 as the App (command 42)" ] && [ "$(posts)" = 1 ] && [ "$(ncomments)" = 3 ] \
  && ok || bad "C3 (rc=$RC out=$OUT n=$(ncomments))"

echo "--- C4: no App token: retryable, never posted on the PAT"
reset_state
STUB_TOKEN=ghp_fixture_x icc fixture-proj '{"issue":7,"body":"hello"}' 43
[ "$RC" = 1 ] && [[ "$OUT" != refused:* ]] && [ "$OUT" = "comment not posted: no App token on this box; retry" ] \
  && [ "$(posts)" = 0 ] && [ "$(ncomments)" = 0 ] && ok || bad "C4 (rc=$RC out=$OUT)"

echo "--- C5: a failed comments read posts nothing"
reset_state
GH_COMMENTS_RC=1 GH_COMMENTS_ERR='gh: Bad Gateway (HTTP 502)' icc fixture-proj '{"issue":7,"body":"hello"}' 44
[ "$RC" = 1 ] && [ "$(posts)" = 0 ] && [[ "$OUT" == *"HTTP 502"* ]] && [[ "$OUT" != refused:* ]] && ok || bad "C5 (rc=$RC out=$OUT)"
GH_ISSUE_RC=1 GH_ISSUE_ERR='gh: API rate limit exceeded (HTTP 429)' icc fixture-proj '{"issue":7,"body":"hello"}' 44
[ "$RC" = 1 ] && [ "$(posts)" = 0 ] && [[ "$OUT" != refused:* ]] && ok || bad "C5b issue read 429 (rc=$RC out=$OUT)"
GH_POST_RC=1 GH_POST_ERR='gh: Server Error (HTTP 500)' icc fixture-proj '{"issue":7,"body":"hello"}' 44
[ "$RC" = 1 ] && [ "$OUT" = "comment not posted on #7 (gh: Server Error (HTTP 500))" ] && ok || bad "C5c POST 500 (rc=$RC out=$OUT)"

echo "--- C6: refusals make no gh call"
reset_state
BIG=$(head -c 20001 /dev/zero | tr '\0' 'a')
while IFS='|' read -r proj payload id want; do
  icc "$proj" "$payload" "$id"
  [ "$RC" = 3 ] && [ "$OUT" = "$want" ] && [ "$(repo_calls)" = 0 ] && ok || bad "C6 $proj $payload $id (rc=$RC out=$OUT want=$want)"
done <<EOF
inapp-proj|{"issue":7,"body":"x"}|45|refused: inapp-proj is not a GitHub-issues board
unknown-proj|{"issue":7,"body":"x"}|45|refused: unknown-proj is not a GitHub-issues board
fixture-proj;rm|{"issue":7,"body":"x"}|45|refused: fixture-proj;rm is not a GitHub-issues board
fixture-proj|{"issue":"7","body":"x"}|45|refused: bad issue
fixture-proj|{"issue":0,"body":"x"}|45|refused: bad issue
fixture-proj|{"issue":-1,"body":"x"}|45|refused: bad issue
fixture-proj|{"issue":1.5,"body":"x"}|45|refused: bad issue
fixture-proj|{"issue":7}|45|refused: empty body
fixture-proj|{"issue":7,"body":"   "}|45|refused: empty body
fixture-proj|{"issue":7,"body":"$BIG"}|45|refused: body too long
fixture-proj|{"issue":7,"body":"x"}|abc|refused: bad command id
fixture-proj|{"issue":7,"body":"x"}|0|refused: bad command id
fixture-proj|not json|45|refused: bad payload
EOF
# Exactly 20000 characters is allowed.
reset_state
icc fixture-proj "{\"issue\":7,\"body\":\"${BIG:1}\"}" 46
[ "$RC" = 0 ] && [ "$(posts)" = 1 ] && ok || bad "C6 a 20000-char body posts (rc=$RC out=$OUT)"

echo "--- C7: a pull request is refused"
reset_state pr
icc fixture-proj '{"issue":7,"body":"hello"}' 47
[ "$RC" = 3 ] && [ "$OUT" = "refused: #7 is a pull request" ] && [ "$(posts)" = 0 ] && ok || bad "C7 (rc=$RC out=$OUT)"

echo "--- C8: an unreadable fleet.conf is retryable, never refused:"
reset_state
mv "$T/h/bin/fleet-conf.sh" "$T/h/bin/fleet-conf.real"
printf '#!/bin/bash\nexit 1\n' > "$T/h/bin/fleet-conf.sh"; chmod +x "$T/h/bin/fleet-conf.sh"
icc fixture-proj '{"issue":7,"body":"hello"}' 48
[ "$RC" = 1 ] && [[ "$OUT" != refused:* ]] && [ "$(repo_calls)" = 0 ] && ok || bad "C8 (rc=$RC out=$OUT)"
mv "$T/h/bin/fleet-conf.real" "$T/h/bin/fleet-conf.sh"

echo "--- C9: the poll-commands arm, extracted by its markers"
{ echo 'case "$TYPE" in'
  awk '/^    # >>> comment_issue handler/{f=1;next} /^    # <<< comment_issue handler/{exit} f{print}' "$PC"
  echo '  *) RESULT="unknown command type $TYPE" ;;'
  echo 'esac'
} > "$T/arm.body"
[ "$(wc -l < "$T/arm.body")" -gt 4 ] || { echo "FAIL: could not extract the comment_issue handler — markers missing?"; echo "issue-comment-cmd: $PASS passed, $((FAIL+1)) failed"; exit 1; }
grep -qxF '[ -r "$HARNESS/bin/lib/issue-comment-cmd.sh" ] && . "$HARNESS/bin/lib/issue-comment-cmd.sh"' "$PC" && ok || bad "guarded source line in poll-commands"
! grep -qE 'box_ccmd_forward|bcx_run' "$T/arm.body" && ok || bad "the arm is not forwarded"
arm() { # arm <type> <stub-rc|none> -> "OK=.. OUTCOME=.. RESULT=.."
  TYPE="$1" SRC="$2" bash -c '
    set -uo pipefail
    if [ "$SRC" != none ]; then icc_run() { echo "$1 $2 $3" > "$0.args"; [ "$SRC" = 3 ] && echo "refused: bad issue" || echo "r$SRC"; return "$SRC"; }; fi
    ID=41 PROJECT=fixture-proj PAYLOAD="{\"issue\":7}" OK=false RESULT="" OUTCOME=""
    . "$0"; echo "OK=$OK OUTCOME=$OUTCOME RESULT=$RESULT"' "$T/arm.body"
}
[ "$(arm comment_issue 0)" = "OK=true OUTCOME= RESULT=r0" ] && [ "$(cat "$T/arm.body.args")" = 'fixture-proj {"issue":7} 41' ] \
  && ok || bad "arm rc 0 (got $(arm comment_issue 0))"
[ "$(arm comment_issue 3)" = "OK=false OUTCOME=refused RESULT=refused: bad issue" ] && ok || bad "arm rc 3 (got $(arm comment_issue 3))"
[ "$(arm comment_issue 1)" = "OK=false OUTCOME= RESULT=r1" ] && ok || bad "arm rc 1 (got $(arm comment_issue 1))"
[ "$(arm comment_issue none)" = "OK=false OUTCOME= RESULT=comment not posted (lib not loaded)" ] && ok || bad "arm lib absent (got $(arm comment_issue none))"
# End to end: the real lib behind the real arm, twice with one command id.
reset_state; : > "$GHLOG"
e2e() {
  PATH="$T/stubbin:$PATH" HARNESS="$T/h" GHLOG="$GHLOG" GHSTATE="$GHSTATE" GH_TOKEN=ghp_fixture_pat \
    TYPE=comment_issue ID=77 PROJECT=fixture-proj PAYLOAD='{"issue":7,"body":"from the console","actor":"operator"}' bash -c '
      set -uo pipefail; . "$0"; . "$1"; OK=false RESULT="" OUTCOME=""
      . "$2"; echo "OK=$OK OUTCOME=$OUTCOME RESULT=$RESULT TOKEN=$GH_TOKEN"' "$LIB" "$T/stubs.sh" "$T/arm.body"
}
E1=$(e2e); E2=$(e2e)
[ "$E1" = "OK=true OUTCOME= RESULT=commented on #7 as the App (command 77) TOKEN=ghp_fixture_pat" ] \
  && [ "$E2" = "OK=true OUTCOME= RESULT=comment already posted on #7 (command 77) TOKEN=ghp_fixture_pat" ] \
  && [ "$(ncomments)" = 1 ] && ok || bad "e2e arm + lib (e1=$E1 e2=$E2 n=$(ncomments))"

echo "--- C10: the poller's default arm names an unknown type"
{ echo 'case "$TYPE" in'
  awk '/^    # <<< ticket hold handler/{f=1;next} f && /^  esac/{exit} f{print}' "$PC"
  echo 'esac'
} > "$T/tail.body"
DEF=$(TYPE=bogus_type bash -c 'set -uo pipefail; OK=false RESULT="" OUTCOME=""; icc_run() { echo called; return 0; }
  . "$0"; echo "OK=$OK RESULT=$RESULT"' "$T/tail.body")
[ "$DEF" = "OK=false RESULT=unknown command type bogus_type" ] && ok || bad "C10 default arm (got $DEF)"

echo "--- C11: the Pages fallback lib"
[ -f "$PAGES_LIB" ] && ok || bad "missing $PAGES_LIB"
grep -q "^import .*BOARD_FALLBACK_TYPES.*from '../_lib/board-commands.js'" "$DIR/console-ui/functions/api/[[path]].js" \
  && ok || bad "the Pages proxy imports the fallback lib"
if command -v node >/dev/null 2>&1 && [ -d "$DIR/console-ui/node_modules/preact" ]; then
  if (cd "$DIR/console-ui" && node --test tests/board-commands.bh-5820.test.js >"$T/node.out" 2>&1); then ok
  else bad "console-ui/tests/board-commands.bh-5820.test.js failed: $(tail -n 30 "$T/node.out")"; fi
else echo "  (console-ui deps not installed: the node suite runs in the console-ui CI job)"; fi

echo "issue-comment-cmd: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
