#!/bin/bash
# tests/gh-shim-issue-read-test.sh — bin/lib/gh-shim/issue-read.sh (#769 chunk
# 2): `gh issue view` and `gh issue list` translated to REST.
#
# HOW IT DRIVES. The real bin/gh-rest-shim with the real shipped handlers
# (GH_SHIM_LIB unset) over tests/lib/gh-shim-stub.sh's fixture stub. Assertions
# are stdout, the exit code and $T/gh-calls.txt — never handler source.
#
# THE TRAP IT PINS: /repos/{slug}/issues answers PULL REQUESTS TOO. A board pass
# that reads a PR as a ticket triages a PR. These were broken once each and each
# turned a block red:
#   - drop the .pull_request filter          -> issue-list-drops-prs
#   - slice to --limit before that filter    -> issue-list-drops-prs (count)
#   - emit the integer comment id            -> issue-list-comments-per-issue-node-id
#
# Run from anywhere:  bash tests/gh-shim-issue-read-test.sh (exit 0 = pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
. "$(dirname "$0")/lib/gh-shim-stub.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
eq() { if [ "$2" = "$3" ]; then ok; else bad "$1: want [$3] got [$2]"; fi; }
has() { case "$2" in *"$3"*) ok ;; *) bad "$1: [$2] does not contain [$3]" ;; esac; }
hasnt() { case "$2" in *"$3"*) bad "$1: [$2] must not contain [$3]" ;; *) ok ;; esac; }

gshim_stub_setup
logfile="$T/h/logs/gh-passthrough.log"
logline() { [ -f "$logfile" ] && cat "$logfile"; return 0; }

issue_row() { # issue_row <n> <extra-json>
  printf '{"number":%s,"node_id":"I_%s","html_url":"https://github.com/o/r/issues/%s","title":"Title","body":"Body text","state":"open","created_at":"2026-09-01T00:00:00Z","updated_at":"2026-09-01T00:00:00Z","closed_at":null,"user":{"login":"operator","type":"User"},"labels":[{"node_id":"LA_1","name":"ai-build","description":null,"color":"0"},{"node_id":"LA_2","name":"hotfix","description":null,"color":"0"}],"assignees":[],"milestone":null%s}' \
    "$1" "$1" "$1" "${2:-}"
}

# ── issue-list-drops-prs ─────────────────────────────────────────────────────
gshim_reset
{ printf '['; issue_row 1; printf ','; issue_row 2 ',"pull_request":{"url":"x"}'; printf ']'; } \
  >"$T/fixtures/repos_o_r_issues.json"
gshim_run issue list -R o/r --json number
eq "issue-list-drops-prs rows" "$OUT" '[{"number":1}]'
eq "issue-list-drops-prs rc" "$RC" "0"

# The filter runs BEFORE --limit: --limit 1 over [issue, pr] is still the issue.
gshim_reset
{ printf '['; issue_row 2 ',"pull_request":{"url":"x"}'; printf ','; issue_row 1; printf ']'; } \
  >"$T/fixtures/repos_o_r_issues.json"
gshim_run issue list -R o/r --limit 1 --json number
eq "issue-list-drops-prs before limit" "$OUT" '[{"number":1}]'

# ── issue-list-labels-state-limit (bin/triage-gate.sh's exact call) ──────────
gshim_reset
{ printf '['; issue_row 1; printf ']'; } >"$T/fixtures/repos_o_r_issues.json"
gshim_fixture repos_o_r_issues_1_comments <<'J'
[]
J
gshim_run issue list -R o/r --label ai-build --state all --limit 100 --json number,state,title,comments,updatedAt
has "issue-list-labels-state-limit labels" "$(gshim_calls)" "labels=ai-build"
has "issue-list-labels-state-limit state" "$(gshim_calls)" "state=all"
has "issue-list-labels-state-limit per_page" "$(gshim_calls)" "per_page=100"
eq "issue-list-labels-state-limit rc" "$RC" "0"
gshim_reset
gshim_run issue list -R o/r --label a --label b --state open --json number
has "issue-list-labels-joined" "$(gshim_calls)" "labels=a,b"

# ── issue-list-comments-per-issue-node-id ────────────────────────────────────
gshim_reset
{ printf '['; issue_row 1; printf ','; issue_row 3; printf ']'; } >"$T/fixtures/repos_o_r_issues.json"
gshim_fixture repos_o_r_issues_1_comments <<'J'
[{"node_id":"IC_1","id":111,"user":{"login":"operator","type":"User"},"author_association":"OWNER",
  "body":"first","created_at":"2026-09-01T01:00:00Z","updated_at":"2026-09-01T01:00:00Z",
  "html_url":"https://github.com/o/r/issues/1#ic1"}]
J
gshim_fixture repos_o_r_issues_3_comments <<'J'
[{"node_id":"IC_3","id":333,"user":{"login":"cromford[bot]","type":"Bot"},
  "author_association":"MEMBER","body":"third","created_at":"2026-09-01T03:00:00Z",
  "updated_at":"2026-09-01T03:00:00Z","html_url":"https://github.com/o/r/issues/3#ic3"}]
J
gshim_run issue list -R o/r --json number,comments
eq "issue-list-comments two fetches" "$(gshim_calls | grep -c 'issues/[13]/comments')" "2"
gshim_run issue list -R o/r --json number,comments -q '.[0].comments[0].id'
eq "issue-list-comments-per-issue-node-id" "$OUT" "IC_1"
gshim_run issue list -R o/r --json number,comments -q '.[1].comments[0].id'
eq "issue-list-comments-second-issue" "$OUT" "IC_3"
gshim_run issue list -R o/r --json number,comments -q '.[1].comments[0].author.login'
eq "issue-list-comments-author-app" "$OUT" "app/cromford"
# Not requested, not paid for.
gshim_reset
gshim_run issue list -R o/r --json number,title
eq "issue-list-comments-on-demand" "$(gshim_calls | grep -c '/comments')" "0"

# ── issue-view-shape (what prompts/cromford.md reads) ───────────────────
gshim_reset
issue_row 1 >"$T/fixtures/repos_o_r_issues_1.json"
gshim_run issue view 1 -R o/r --json title,body,state,labels,comments,createdAt
eq "issue-view-shape rc" "$RC" "0"
gshim_run issue view 1 -R o/r --json state -q .state
eq "issue-view-state-upper" "$OUT" "OPEN"
gshim_run issue view 1 -R o/r --json comments -q '.comments[0].author.login'
eq "issue-view-comments-author-login" "$OUT" "operator"
gshim_run issue view 1 -R o/r --json comments -q '.comments[0].body'
eq "issue-view-comments-body" "$OUT" "first"
gshim_run issue view 1 -R o/r --json comments -q '.comments[0].createdAt'
eq "issue-view-comments-createdAt" "$OUT" "2026-09-01T01:00:00Z"
gshim_run issue view 1 -R o/r --json body -q .body
eq "issue-view-body" "$OUT" "Body text"
gshim_run issue view 1 -R o/r --json labels -q '[.labels[].name] | join(",")'
eq "issue-view-labels" "$OUT" "ai-build,hotfix"
gshim_run issue view https://github.com/o/r/issues/1 -R other/repo --json state -q .state
eq "issue-view-url-overrides-R" "$OUT" "OPEN"
gshim_run issue view 1 -R o/r --json number,isPinned
has "issue-view-unmappable-passthru" "$(gshim_calls)" "PASSTHRU issue view 1 -R o/r --json number,isPinned"
has "issue-view-unmappable-reason" "$(logline)" "reason=field:isPinned"

# ── issue-view-404 ───────────────────────────────────────────────────────────
gshim_reset
rm -f "$T/fixtures/repos_o_r_issues_1.json"
gshim_run issue view 1 -R o/r --json state
eq "issue-view-404 rc" "$RC" "1"
eq "issue-view-404 no body" "$OUT" ""
issue_row 1 >"$T/fixtures/repos_o_r_issues_1.json"

# ── issue-list-tsv-without-json ──────────────────────────────────────────────
gshim_reset
{ printf '['; issue_row 1; printf ']'; } >"$T/fixtures/repos_o_r_issues.json"
gshim_run issue list -R o/r
eq "issue-list-tsv-without-json" "$OUT" "$(printf '1\tOPEN\tTitle\tai-build,hotfix\t2026-09-01T00:00:00Z')"
eq "issue-list-tsv-without-json rc" "$RC" "0"
gshim_reset
gshim_run issue view 1 -R o/r
has "issue-view-no-json-passthru" "$(gshim_calls)" "PASSTHRU issue view 1 -R o/r"
has "issue-view-no-json-reason" "$(logline)" "reason=untranslated"

# ── issue-list-empty / search ────────────────────────────────────────────────
gshim_reset
printf '[]' >"$T/fixtures/repos_o_r_issues.json"
gshim_run issue list -R o/r --json number
eq "issue-list-empty-is-[]" "$OUT" "[]"
eq "issue-list-empty rc" "$RC" "0"
gshim_reset
gshim_fixture search_issues <<'J'
{"total_count":1,"items":[{"number":9,"node_id":"I_9","html_url":"https://github.com/o/r/issues/9",
 "title":"BH-788","body":"b","state":"open","created_at":"2026-09-01T00:00:00Z",
 "updated_at":"2026-09-01T00:00:00Z","closed_at":null,"user":{"login":"operator","type":"User"},
 "labels":[],"assignees":[],"milestone":null}]}
J
gshim_run issue list -R o/r --search "BH-788" --json number,title
eq "issue-list-search rows" "$OUT" '[{"number":9,"title":"BH-788"}]'
has "issue-list-search qualifier" "$(gshim_calls)" "q=repo:o/r+is:issue"

# ── mutation (D1): drop the PR filter, watch issue-list-drops-prs go red ─────
mkdir -p "$T/lib"
for f in "$DIR"/bin/lib/gh-shim/*.sh; do cp "$f" "$T/lib/"; done
sed -i 's/select(has("pull_request") | not)/select(true)/' "$T/lib/issue-read.sh"
if [ "$(grep -c 'has("pull_request")' "$DIR/bin/lib/gh-shim/issue-read.sh")" -ge 1 ] &&
   [ "$(grep -c 'has("pull_request")' "$T/lib/issue-read.sh")" -eq 0 ]; then ok
else bad "mutation: the sed did not change anything"; fi
gshim_reset
{ printf '['; issue_row 1; printf ','; issue_row 2 ',"pull_request":{"url":"x"}'; printf ']'; } \
  >"$T/fixtures/repos_o_r_issues.json"
gshim_run issue list -R o/r --json number
eq "mutation baseline drops the PR" "$OUT" '[{"number":1}]'
GH_SHIM_LIB="$T/lib" gshim_run issue list -R o/r --json number
if [ "$OUT" = '[{"number":1}]' ]; then
  bad "mutation: the mutant still drops the PR — issue-list-drops-prs pins nothing"
else
  ok
fi

echo "gh-shim-issue-read: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] || exit 1
exit 0
