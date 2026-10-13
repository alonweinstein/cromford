#!/bin/bash
# tests/gh-shim-issue-write.bh-789-test.sh — bin/lib/gh-shim/issue-write.sh (#769
# chunk 3, BH-789): `gh issue create|edit|comment|close` as single REST calls.
#
# HOW IT DRIVES. The real bin/gh-rest-shim through the PATH symlink $T/shim/gh,
# shipped handlers sourced from bin/lib/gh-shim, a stub behind it
# (tests/lib/gh-shim-stub.sh). Assertions read recorded argv, stdout and exit
# codes; no block greps handler source.
#
# Behaviours broken once during the build, each turning a block red:
#   - drop labels from the create body        -> issue-create red
#   - POST the removals instead of DELETE     -> issue-edit-remove-label red
#   - PATCH the state before the comment POST -> issue-close-comment-order red
#
# Run from anywhere:  bash tests/gh-shim-issue-write.bh-789-test.sh (exit 0 = pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
. "$(dirname "$0")/lib/gh-shim-stub.sh" || exit 1
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
eq() { if [ "$2" = "$3" ]; then ok; else bad "$1: want [$3] got [$2]"; fi; }
has() { case "$2" in *"$3"*) ok ;; *) bad "$1: [$2] does not contain [$3]" ;; esac; }
hasnt() { case "$2" in *"$3"*) bad "$1: [$2] must not contain [$3]" ;; *) ok ;; esac; }
lineno() {
  local n=0 i=0 line
  while IFS= read -r line; do
    i=$((i+1))
    case "$line" in *"$1"*) [ "$n" -eq 0 ] && n=$i ;; esac
  done < <(gshim_calls)
  printf '%s\n' "$n"
}
before() {
  local a b; a=$(lineno "$2"); b=$(lineno "$3")
  if [ "$a" -gt 0 ] && [ "$b" -gt 0 ] && [ "$a" -lt "$b" ]; then ok
  else bad "$1: [$2]=$a is not recorded before [$3]=$b"; fi
}
calls_no_bodies() { gshim_calls | sed 's/ input=.*//'; }

gshim_stub_setup
printf 'https://github.com/o/r\n' >"$T/fixtures/git-origin.txt"
printf '{"html_url":"https://github.com/o/r/issues/5","number":5,"title":"T"}\n' | gshim_fixture repos_o_r_issues
printf '{"html_url":"https://github.com/o/r/issues/5","number":5,"title":"T","state":"open"}\n' | gshim_fixture repos_o_r_issues_5
printf '{"html_url":"https://github.com/o/r/issues/5#issuecomment-9"}\n' | gshim_fixture repos_o_r_issues_5_comments
printf '[]\n' | gshim_fixture repos_o_r_issues_5_labels
printf '[]\n' | gshim_fixture repos_o_r_issues_5_labels_ai-build

BODY='pipe|quote '"'"'q'"'"' $(echo x) ünïcode'

# ── issue-create ─────────────────────────────────────────────────────────────
gshim_reset
gshim_run issue create --title "New thing" --body "$BODY" --label ai-build
eq  "issue-create rc"     "$RC" "0"
eq  "issue-create stdout" "$OUT" "https://github.com/o/r/issues/5"
has "issue-create call"   "$(gshim_calls)" "-X POST repos/o/r/issues --input"
has "issue-create body"   "$(gshim_calls)" 'input={"title":"New thing","body":"pipe|quote '"'"'q'"'"' $(echo x) ünïcode","labels":["ai-build"]}'
hasnt "issue-create body not in argv" "$(calls_no_bodies)" 'echo x'
hasnt "issue-create no passthru"      "$(gshim_calls)" "PASSTHRU"

# ── issue-create-body-file ───────────────────────────────────────────────────
gshim_reset
printf '%s' "$BODY" >"$T/body.md"
gshim_run issue create --title "From file" -F "$T/body.md" -R o/r
eq  "issue-create-body-file rc" "$RC" "0"
has "issue-create-body-file body" "$(gshim_calls)" 'input={"title":"From file","body":"pipe|quote '"'"'q'"'"' $(echo x) ünïcode"}'

# ── issue-edit-remove-label ──────────────────────────────────────────────────
gshim_reset
gshim_run issue edit 5 -R o/r --remove-label ai-build --add-label done
eq  "issue-edit rc"     "$RC" "0"
has "issue-edit remove" "$(gshim_calls)" "-X DELETE repos/o/r/issues/5/labels/ai-build"
has "issue-edit add"    "$(gshim_calls)" "-X POST repos/o/r/issues/5/labels --input"
has "issue-edit add body" "$(gshim_calls)" 'input={"labels":["done"]}'
gshim_reset
gshim_run issue edit https://github.com/o/r/issues/5 --title "Renamed"
has "issue-edit patch" "$(gshim_calls)" "-X PATCH repos/o/r/issues/5 --input"
has "issue-edit patch body" "$(gshim_calls)" 'input={"title":"Renamed"}'

# ── issue-comment ────────────────────────────────────────────────────────────
gshim_reset
gshim_run issue comment 5 -R o/r --body "$BODY"
eq  "issue-comment rc"     "$RC" "0"
eq  "issue-comment stdout" "$OUT" "https://github.com/o/r/issues/5#issuecomment-9"
has "issue-comment call"   "$(gshim_calls)" "-X POST repos/o/r/issues/5/comments --input"
has "issue-comment body"   "$(gshim_calls)" 'input={"body":"pipe|quote '"'"'q'"'"' $(echo x) ünïcode"}'
hasnt "issue-comment body not in argv" "$(calls_no_bodies)" 'echo x'
gshim_reset
printf '%s' "$BODY" >"$T/c.md"
gshim_run issue comment 5 -R o/r --body-file - <"$T/c.md"
has "issue-comment stdin body" "$(gshim_calls)" 'input={"body":"pipe|quote '"'"'q'"'"' $(echo x) ünïcode"}'

# ── issue-close-comment-order ────────────────────────────────────────────────
gshim_reset
gshim_run issue close 5 -R o/r --comment "done here"
eq  "issue-close rc"    "$RC" "0"
has "issue-close comment" "$(gshim_calls)" "-X POST repos/o/r/issues/5/comments --input"
has "issue-close patch"   "$(gshim_calls)" "-X PATCH repos/o/r/issues/5 --input"
has "issue-close state"   "$(gshim_calls)" 'input={"state":"closed"}'
before "issue-close comment first" "issues/5/comments" "-X PATCH repos/o/r/issues/5"

# ── issue-close-reason ───────────────────────────────────────────────────────
# gh's documented values are `completed` and `"not planned"`; REST's field is
# `not_planned`. Accepting the flag and passing gh's spelling through verbatim
# is a 422 where real gh succeeds.
gshim_reset
gshim_run issue close 5 -R o/r --reason "not planned"
eq  "issue-close-reason not-planned rc"   "$RC" "0"
has "issue-close-reason not-planned body" "$(gshim_calls)" 'input={"state":"closed","state_reason":"not_planned"}'
gshim_reset
gshim_run issue close 5 -R o/r --reason completed
has "issue-close-reason completed body" "$(gshim_calls)" 'input={"state":"closed","state_reason":"completed"}'
gshim_reset
gshim_run issue close 5 -R o/r --reason duplicate
has "issue-close-reason other body" "$(gshim_calls)" 'input={"state":"closed","state_reason":"duplicate"}'

# ── issue-close-comment-fail-aborts ──────────────────────────────────────────
gshim_reset
printf 'HTTP 403: Resource not accessible by integration\n' | gshim_fixture repos_o_r_issues_5_comments 1
gshim_run issue close 5 -R o/r --comment "nope"
eq    "issue-close-fail rc" "$RC" "1"
hasnt "issue-close-fail no patch" "$(gshim_calls)" "-X PATCH repos/o/r/issues/5"
rm -f "$T/fixtures/repos_o_r_issues_5_comments.rc" "$T/fixtures/repos_o_r_issues_5_comments.err"
printf '{"html_url":"https://github.com/o/r/issues/5#issuecomment-9"}\n' | gshim_fixture repos_o_r_issues_5_comments

# ── unsupported flags pass through ───────────────────────────────────────────
gshim_reset
gshim_run issue create --title T --body b --web
has "issue flag passthru" "$(gshim_calls)" "PASSTHRU issue create"
has "issue flag depth"    "$(gshim_env)"   "depth=1 issue create"
hasnt "issue flag no post" "$(gshim_calls)" "-X POST repos/o/r/issues "

echo "gh-shim-issue-write: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] || exit 1
exit 0
