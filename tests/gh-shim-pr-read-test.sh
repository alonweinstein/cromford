#!/bin/bash
# tests/gh-shim-pr-read-test.sh — bin/lib/gh-shim/pr-read.sh (#769 chunk 2):
# `gh pr view` and `gh pr list` translated to REST.
#
# HOW IT DRIVES. Every block runs the REAL bin/gh-rest-shim with the REAL
# bin/lib/gh-shim handlers behind it (GH_SHIM_LIB is left unset on purpose, so
# the shipped directory is what is exercised), with tests/lib/gh-shim-stub.sh's
# stub standing in for the gh binary. No block greps handler source: assertions
# are stdout, the exit code, and the recorded argv in $T/gh-calls.txt.
#
# MUTATION CHECK (D1) is the `mutation` block: a sed copy of pr-read.sh with
# MERGED misspelled must make the merged-state assertion fail. These behaviours
# were each broken once during the build and each turned a block red:
#   - emit merge_commit_sha on an open PR -> pr-view-mergecommit-null-when-open
#   - fetch /files unconditionally        -> pr-view-files-on-demand
#   - drop the [bot] -> app/ rewrite      -> pr-view-author-app
#   - slice to --limit before filtering   -> pr-list-label-and
#   - map --state merged to state=merged  -> pr-list-state-merged-filter
#
# Run from anywhere:  bash tests/gh-shim-pr-read-test.sh (exit 0 = pass)
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

SYS_PATH="$PATH"
gshim_stub_setup
logfile="$T/h/logs/gh-passthrough.log"
logline() { [ -f "$logfile" ] && cat "$logfile"; return 0; }

# One open PR fixture, reused. Literal timestamps: this suite reads no clock.
pull_fixture() { # pull_fixture <state> <merged_at|null> [mergeable] [mergeable_state]
  gshim_fixture repos_o_r_pulls_1 <<J
{"number":1,"node_id":"PR_kwn1","html_url":"https://github.com/o/r/pull/1",
 "title":"Title","body":"Body text","state":"$1","merged_at":$2,
 "merged":$([ "$2" = null ] && echo false || echo true),
 "merge_commit_sha":"abc123","mergeable":${3:-true},"mergeable_state":"${4:-clean}",
 "draft":false,"created_at":"2026-09-01T00:00:00Z","updated_at":"2026-09-02T00:00:00Z",
 "closed_at":null,"additions":10,"deletions":2,"changed_files":3,
 "head":{"ref":"br","sha":"deadbeef","repo":{"full_name":"o/r"}},
 "base":{"ref":"main","repo":{"full_name":"o/r"}},
 "user":{"login":"operator","type":"User"},"merged_by":null,
 "labels":[{"node_id":"LA_1","name":"ai-build","description":"d","color":"ff0000"}],
 "assignees":[],"milestone":null}
J
}

# ── pr-view-state-open|closed|merged ─────────────────────────────────────────
gshim_reset; pull_fixture open null
gshim_run pr view 1 -R o/r --json state -q .state
eq "pr-view-state-open" "$OUT" "OPEN"
eq "pr-view-state-open rc" "$RC" "0"
has "pr-view-state-open one REST call" "$(gshim_calls)" "api repos/o/r/pulls/1"

gshim_reset; pull_fixture closed null
gshim_run pr view 1 -R o/r --json state -q .state
eq "pr-view-state-closed" "$OUT" "CLOSED"

gshim_reset; pull_fixture closed '"2026-09-03T00:00:00Z"'
gshim_run pr view 1 -R o/r --json state -q .state
eq "pr-view-state-merged" "$OUT" "MERGED"

# ── pr-view-mergecommit-null-when-open ───────────────────────────────────────
# REST's merge_commit_sha on an open PR is a TEST-MERGE sha. Three merge-path
# scripts read .mergeCommit.oid as "what landed".
gshim_reset; pull_fixture open null
gshim_run pr view 1 -R o/r --json mergeCommit -q .mergeCommit.oid
eq "pr-view-mergecommit-null-when-open" "$OUT" "null"
gshim_reset; pull_fixture closed '"2026-09-03T00:00:00Z"'
gshim_run pr view 1 -R o/r --json mergeCommit -q .mergeCommit.oid
eq "pr-view-mergecommit-sha-when-merged" "$OUT" "abc123"

# ── pr-view-mergeable-spellings ──────────────────────────────────────────────
gshim_reset; pull_fixture open null true clean
gshim_run pr view 1 -R o/r --json mergeable,mergeStateStatus
eq "pr-view-mergeable-true" "$OUT" '{"mergeable":"MERGEABLE","mergeStateStatus":"CLEAN"}'
gshim_reset; pull_fixture open null false dirty
gshim_run pr view 1 -R o/r --json mergeable -q .mergeable
eq "pr-view-mergeable-false" "$OUT" "CONFLICTING"
gshim_reset; pull_fixture open null null blocked
gshim_run pr view 1 -R o/r --json mergeable,mergeStateStatus
eq "pr-view-mergeable-null" "$OUT" '{"mergeable":"UNKNOWN","mergeStateStatus":"BLOCKED"}'

# ── pr-view-author-app ───────────────────────────────────────────────────────
author_case() { # author_case <name> <login> <type> <want-login> <want-bot>
  gshim_reset
  gshim_fixture repos_o_r_pulls_1 <<J
{"number":1,"state":"open","merged_at":null,"user":{"login":"$2","type":"$3"},
 "head":{"ref":"br","sha":"s","repo":{"full_name":"o/r"}},
 "base":{"ref":"main","repo":{"full_name":"o/r"}},"labels":[],"assignees":[],"milestone":null}
J
  gshim_run pr view 1 -R o/r --json author -q .author.login
  eq "$1 login" "$OUT" "$4"
  gshim_run pr view 1 -R o/r --json author -q '.author.is_bot'
  eq "$1 is_bot" "$OUT" "$5"
}
author_case pr-view-author-app 'cromford[bot]' Bot 'app/cromford' true
author_case pr-view-author-suffix-not-bot 'foo[bot]' User 'foo[bot]' false
author_case pr-view-author-human operator User operator false

# ── pr-view-q-raw / labels ───────────────────────────────────────────────────
gshim_reset; pull_fixture open null
gshim_run pr view 1 -R o/r --json title -q .title
eq "pr-view-q-raw" "$OUT" "Title"
gshim_run pr view 1 -R o/r --json labels -q '.labels[0].id'
eq "pr-view-labels-node-id" "$OUT" "LA_1"
gshim_run pr view 1 -R o/r --json labels -q '.labels[0].name'
eq "pr-view-labels-name" "$OUT" "ai-build"

# ── pr-view-files-on-demand ──────────────────────────────────────────────────
gshim_fixture repos_o_r_pulls_1_files <<'J'
[{"filename":"bin/x.sh","additions":3,"deletions":1,"status":"modified"}]
J
gshim_reset; pull_fixture open null
gshim_run pr view 1 -R o/r --json state
eq "pr-view-files-on-demand not fetched" "$(gshim_calls | grep -c '/files')" "0"
gshim_reset
gshim_run pr view 1 -R o/r --json files
eq "pr-view-files-on-demand fetched once" "$(gshim_calls | grep -c '/files')" "1"
eq "pr-view-files-shape" "$OUT" '{"files":[{"path":"bin/x.sh","additions":3,"deletions":1}]}'

# ── pr-view-comments-reviews-shape ───────────────────────────────────────────
gshim_fixture repos_o_r_issues_1_comments <<'J'
[{"node_id":"IC_9","id":555,"user":{"login":"cromford[bot]","type":"Bot"},
  "author_association":"MEMBER","body":"hi","created_at":"2026-09-01T01:00:00Z",
  "updated_at":"2026-09-01T02:00:00Z","html_url":"https://github.com/o/r/pull/1#ic9"}]
J
gshim_fixture repos_o_r_pulls_1_reviews <<'J'
[{"node_id":"PRR_3","id":77,"user":{"login":"operator"},"body":"lgtm",
  "state":"APPROVED","submitted_at":"2026-09-02T00:00:00Z","commit_id":"cafe"}]
J
gshim_fixture repos_o_r_pulls_1_commits <<'J'
[{"sha":"c0ffee","author":{"login":"operator"},
  "commit":{"message":"head line\n\nbody line","author":{"name":"the operator","email":"l@x.com"},
            "committer":{"date":"2026-09-01T03:00:00Z"}}}]
J
gshim_reset; pull_fixture open null
gshim_run pr view 1 -R o/r --json comments -q '.comments[0].id'
eq "pr-view-comments-node-id" "$OUT" "IC_9"
has "pr-view-comments-endpoint" "$(gshim_calls)" "repos/o/r/issues/1/comments"
gshim_run pr view 1 -R o/r --json comments -q '.comments[0].author.login'
eq "pr-view-comments-author-app" "$OUT" "app/cromford"
gshim_run pr view 1 -R o/r --json comments -q '.comments[0].createdAt'
eq "pr-view-comments-createdAt" "$OUT" "2026-09-01T01:00:00Z"
gshim_run pr view 1 -R o/r --json reviews -q '.reviews[0] | "\(.id)|\(.author.login)|\(.state)|\(.submittedAt)|\(.commit.oid)"'
eq "pr-view-reviews-shape" "$OUT" "PRR_3|operator|APPROVED|2026-09-02T00:00:00Z|cafe"
gshim_run pr view 1 -R o/r --json commits -q '.commits[0] | "\(.oid)|\(.messageHeadline)|\(.committedDate)|\(.authors[0].login)|\(.authors[0].email)"'
eq "pr-view-commits-shape" "$OUT" "c0ffee|head line|2026-09-01T03:00:00Z|operator|l@x.com"

# ── pr-view-statuscheckrollup ────────────────────────────────────────────────
# bin/review-autopilot.sh reads `.name // .context` and `.conclusion // .state`,
# so check runs AND commit statuses ride in one upper-cased array.
gshim_fixture repos_o_r_commits_deadbeef_check-runs <<'J'
{"total_count":1,"check_runs":[{"name":"build","status":"completed","conclusion":"success",
  "started_at":"2026-09-01T00:00:00Z","completed_at":"2026-09-01T00:05:00Z",
  "details_url":"https://github.com/o/r/runs/1"}]}
J
gshim_fixture repos_o_r_commits_deadbeef_status <<'J'
{"state":"success","statuses":[{"context":"vercel","state":"success",
  "target_url":"https://vercel.com/x","created_at":"2026-09-01T00:02:00Z"}]}
J
gshim_reset; pull_fixture open null
gshim_run pr view 1 -R o/r --json statusCheckRollup -q '.statusCheckRollup[] | "\(.__typename)|\(.name // .context)|\(.conclusion // .state)"'
eq "pr-view-statuscheckrollup" "$OUT" "CheckRun|build|SUCCESS
StatusContext|vercel|SUCCESS"
gshim_run pr view 1 -R o/r --json statusCheckRollup -q '.statusCheckRollup[0].status'
eq "pr-view-statuscheckrollup-status-upper" "$OUT" "COMPLETED"
gshim_run pr view 1 -R o/r --json statusCheckRollup -q '.statusCheckRollup[0].workflowName'
eq "pr-view-statuscheckrollup-workflowname" "$OUT" "null"

# ── pr-view-url-arg-overrides-R ──────────────────────────────────────────────
gshim_reset; pull_fixture open null
gshim_run pr view https://github.com/o/r/pull/1 -R other/repo --json state -q .state
eq "pr-view-url-arg-overrides-R" "$OUT" "OPEN"
has "pr-view-url-arg-overrides-R endpoint" "$(gshim_calls)" "api repos/o/r/pulls/1"
hasnt "pr-view-url-arg-overrides-R not -R repo" "$(gshim_calls)" "other/repo"

# ── pr-view-no-arg-branch ────────────────────────────────────────────────────
# `gh pr view --json state` with no number resolves the checked-out branch.
gshim_reset; pull_fixture open null
gshim_fixture repos_o_r_pulls <<'J'
[{"number":1}]
J
mkdir -p "$T/gitbin"
cat >"$T/gitbin/git" <<GITW
#!/bin/bash
T=$(printf '%q' "$T")
GITW
cat >>"$T/gitbin/git" <<'GITW'
if [ "${1:-}" = "symbolic-ref" ]; then
  [ -s "$T/fixtures/branch.txt" ] || exit 1
  cat "$T/fixtures/branch.txt"; exit 0
fi
exec "$T/real/git" "$@"
GITW
chmod 755 "$T/gitbin/git"
GITPATH="$T/shim:$T/gitbin:$T/real:$SYS_PATH"
BR=feature-x
printf '%s
' "$BR" >"$T/fixtures/branch.txt"
PATH="$GITPATH" gshim_run pr view -R o/r --json state -q .state
eq "pr-view-no-arg-branch" "$OUT" "OPEN"
has "pr-view-no-arg-branch head query" "$(gshim_calls)" "head=o:$BR"

# Detached HEAD is an ERROR, never a pass-through: passing it through spends the
# GraphQL points the shim exists to save.
gshim_reset
: >"$T/fixtures/branch.txt"
PATH="$GITPATH" gshim_run pr view -R o/r --json state -q .state
eq "pr-view-no-arg-branch detached rc" "$RC" "1"
has "pr-view-no-arg-branch detached stderr" "$ERR" "not on a branch"
printf '%s
' "$BR" >"$T/fixtures/branch.txt"
gshim_reset
rm -f "$T/fixtures/repos_o_r_pulls.json"
printf '[]' >"$T/fixtures/repos_o_r_pulls.json"
PATH="$GITPATH" gshim_run pr view -R o/r --json state -q .state
eq "pr-view-no-arg-branch-none rc" "$RC" "1"
eq "pr-view-no-arg-branch-none no body" "$OUT" ""
has "pr-view-no-arg-branch-none stderr" "$ERR" "no pull requests found for branch"
rm -f "$T/fixtures/repos_o_r_pulls.json"

# ── pr-view-unmappable-field-passthru ────────────────────────────────────────
gshim_reset; pull_fixture open null
gshim_run pr view 1 -R o/r --json state,isInMergeQueue
has "pr-view-unmappable-field-passthru argv" "$(gshim_calls)" "PASSTHRU pr view 1 -R o/r --json state,isInMergeQueue"
eq "pr-view-unmappable-field-passthru depth" "$(gshim_env | grep -c 'depth=1 pr view')" "1"
has "pr-view-unmappable-field-passthru reason" "$(logline)" "reason=field:isInMergeQueue"
eq "pr-view-unmappable-field-passthru no REST" "$(gshim_calls | grep -c 'api repos')" "0"

# ── pr-view-404-exit1 ────────────────────────────────────────────────────────
gshim_reset
rm -f "$T/fixtures/repos_o_r_pulls_1.json"
gshim_run pr view 1 -R o/r --json state -q .state
eq "pr-view-404-exit1 rc" "$RC" "1"
eq "pr-view-404-exit1 no body" "$OUT" ""

# ── pr-view-no-json-passthru ─────────────────────────────────────────────────
gshim_reset; pull_fixture open null
gshim_run pr view 1 -R o/r
has "pr-view-no-json-passthru argv" "$(gshim_calls)" "PASSTHRU pr view 1 -R o/r"
has "pr-view-no-json-passthru reason" "$(logline)" "reason=untranslated"

# ── pr-view-graphql-dead (ticket AC R20 — the reason the shim exists) ────────
# GraphQL is rate limited, so the stub's own `pr view` dies; REST answers.
gshim_reset; pull_fixture open null
printf 'GraphQL: API rate limit already exceeded\n' >"$T/fixtures/passthru.err"
printf '1\n' >"$T/fixtures/passthru.rc"
gshim_run pr view 1 -R o/r --json state -q .state
eq "pr-view-graphql-dead out" "$OUT" "OPEN"
eq "pr-view-graphql-dead rc" "$RC" "0"
hasnt "pr-view-graphql-dead no passthru" "$(gshim_calls)" "PASSTHRU"

# The same call the fly-pool PR_CREATED gate makes, by URL.
gshim_reset
gshim_run pr view https://github.com/o/r/pull/1 --json state -q .state
eq "pr-view-graphql-dead by-url" "$OUT" "OPEN"
eq "pr-view-graphql-dead by-url rc" "$RC" "0"
rm -f "$T/fixtures/passthru.rc" "$T/fixtures/passthru.err"

# ── pr list ──────────────────────────────────────────────────────────────────
list_fixture() { # rows on stdin
  cat >"$T/fixtures/repos_o_r_pulls.json"
}
row() { # row <n> <state> <merged_at> <login> <type> <labels-json> <branch>
  printf '{"number":%s,"node_id":"PR_%s","html_url":"https://github.com/o/r/pull/%s","title":"Title","body":"b","state":"%s","merged_at":%s,"draft":false,"created_at":"2026-09-01T00:00:00Z","updated_at":"2026-09-01T00:00:00Z","closed_at":null,"head":{"ref":"%s","sha":"s%s","repo":{"full_name":"o/r"}},"base":{"ref":"main","repo":{"full_name":"o/r"}},"user":{"login":"%s","type":"%s"},"labels":%s,"assignees":[],"milestone":null}' \
    "$1" "$1" "$1" "$2" "$3" "${7:-br}" "$1" "$4" "$5" "$6"
}

# pr-list-state-merged-filter: --state merged is state=closed + merged_at.
gshim_reset
{ printf '['; row 1 closed '"2026-09-02T00:00:00Z"' operator User '[]'; printf ','; row 2 closed null operator User '[]'; printf ']'; } | list_fixture
gshim_run pr list -R o/r --state merged --json number,state
eq "pr-list-state-merged-filter rows" "$OUT" '[{"number":1,"state":"MERGED"}]'
has "pr-list-state-merged-filter query" "$(gshim_calls)" "state=closed"
hasnt "pr-list-state-merged-filter no merged query" "$(gshim_calls)" "state=merged"

# pr-list-head-base
gshim_reset
{ printf '['; row 1 open null operator User '[]' feature; printf ']'; } | list_fixture
gshim_run pr list -R o/r --head feature --base main --json number
eq "pr-list-head-base rows" "$OUT" '[{"number":1}]'
has "pr-list-head-base head" "$(gshim_calls)" "head=o:feature"
has "pr-list-head-base base" "$(gshim_calls)" "base=main"

# pr-list-label-and: gh's --label is AND, both spellings.
gshim_reset
{ printf '['
  row 1 open null operator User '[{"node_id":"L1","name":"a","description":null,"color":"0"},{"node_id":"L2","name":"b","description":null,"color":"0"}]'
  printf ','
  row 2 open null operator User '[{"node_id":"L1","name":"a","description":null,"color":"0"}]'
  printf ']'; } | list_fixture
gshim_run pr list -R o/r --label a --label b --json number
eq "pr-list-label-and repeated" "$OUT" '[{"number":1}]'
gshim_run pr list -R o/r --label a,b --json number
eq "pr-list-label-and csv" "$OUT" '[{"number":1}]'
gshim_run pr list -R o/r --label a --json number
eq "pr-list-label-and single keeps both" "$OUT" '[{"number":1},{"number":2}]'

# pr-list-author-bare: app/x, x[bot] and x are the same account.
gshim_reset
{ printf '['; row 1 open null 'cromford[bot]' Bot '[]'; printf ','; row 2 open null operator User '[]'; printf ']'; } | list_fixture
gshim_run pr list -R o/r --author app/cromford --json number
eq "pr-list-author-bare app-form" "$OUT" '[{"number":1}]'
gshim_run pr list -R o/r --author 'cromford[bot]' --json number
eq "pr-list-author-bare bot-form" "$OUT" '[{"number":1}]'
gshim_run pr list -R o/r --author operator --json number
eq "pr-list-author-bare human" "$OUT" '[{"number":2}]'

# pr-list-limit-paginate-150: two pages, sliced to 150.
gshim_reset
rm -f "$T/fixtures/repos_o_r_pulls.json"
jq -c -n '[range(1;101) | {number: ., node_id: "x", html_url: "u", title: "t", body: "b", state: "open", merged_at: null, draft: false, created_at: "2026-09-01T00:00:00Z", updated_at: "2026-09-01T00:00:00Z", closed_at: null, head: {ref: "br", sha: "s", repo: {full_name: "o/r"}}, base: {ref: "main", repo: {full_name: "o/r"}}, user: {login: "operator", type: "User"}, labels: [], assignees: [], milestone: null}]' >"$T/fixtures/repos_o_r_pulls.p1.json"
jq -c -n '[range(101;201) | {number: ., node_id: "x", html_url: "u", title: "t", body: "b", state: "open", merged_at: null, draft: false, created_at: "2026-09-01T00:00:00Z", updated_at: "2026-09-01T00:00:00Z", closed_at: null, head: {ref: "br", sha: "s", repo: {full_name: "o/r"}}, base: {ref: "main", repo: {full_name: "o/r"}}, user: {login: "operator", type: "User"}, labels: [], assignees: [], milestone: null}]' >"$T/fixtures/repos_o_r_pulls.p2.json"
gshim_run pr list -R o/r --limit 150 --json number -q 'length'
eq "pr-list-limit-paginate-150 count" "$OUT" "150"
eq "pr-list-limit-paginate-150 two calls" "$(gshim_calls | grep -c 'api repos/o/r/pulls')" "2"
eq "pr-list-limit-paginate-150 page1" "$(gshim_calls | grep -c 'page=1$')" "1"
eq "pr-list-limit-paginate-150 page2" "$(gshim_calls | grep -c 'page=2$')" "1"
has "pr-list-limit-paginate-150 per_page" "$(gshim_calls)" "per_page=100"
rm -f "$T/fixtures/repos_o_r_pulls.p1.json" "$T/fixtures/repos_o_r_pulls.p2.json"

# pr-list-search: the search index, not the list endpoint.
gshim_reset
gshim_fixture search_issues <<'J'
{"total_count":1,"items":[{"number":7,"node_id":"PR_7","html_url":"https://github.com/o/r/pull/7",
 "title":"BH-788 read side","body":"b","state":"open","draft":false,
 "created_at":"2026-09-01T00:00:00Z","updated_at":"2026-09-01T00:00:00Z","closed_at":null,
 "user":{"login":"operator","type":"User"},"labels":[],"pull_request":{"merged_at":null}}]}
J
gshim_run pr list -R o/r --state all --search "BH-788" --json number,title
eq "pr-list-search rows" "$OUT" '[{"number":7,"title":"BH-788 read side"}]'
has "pr-list-search endpoint" "$(gshim_calls)" "api search/issues"
has "pr-list-search qualifiers" "$(gshim_calls)" "q=repo:o/r+is:pr"
has "pr-list-search terms" "$(gshim_calls)" "BH-788"
eq "pr-list-search no per-PR reads" "$(gshim_calls | grep -c 'api repos/o/r/pulls/')" "0"

# pr-list-empty-is-[]: zero hits with --json is [], exit 0.
gshim_reset
printf '[]' >"$T/fixtures/repos_o_r_pulls.json"
gshim_run pr list -R o/r --json number
eq "pr-list-empty-is-[] out" "$OUT" "[]"
eq "pr-list-empty-is-[] rc" "$RC" "0"

# pr-list-tsv-without-json: gh's non-TTY TSV.
gshim_reset
{ printf '['; row 1 open null operator User '[]'; printf ']'; } | list_fixture
gshim_run pr list -R o/r
eq "pr-list-tsv-without-json" "$OUT" "$(printf '1\tTitle\tbr\tOPEN\t2026-09-01T00:00:00Z')"
eq "pr-list-tsv-without-json rc" "$RC" "0"

# ── pool-gate-768: the LIVE PR_CREATED gate from bin/fly-pool.sh ─────────────
# The gate block and its two REST helpers are lifted VERBATIM from
# bin/fly-pool.sh by their BH-709 markers and RUN, so this is the production
# entry point (D2) rather than a paraphrase of it: delete the gate from
# fly-pool.sh and the extraction below is empty and this block goes red.
#
# NOTE (plan A1). Since BH-709 the gate already reads REST through `gh api -i`
# and never calls `gh pr view`, so the shim does not change its verdict. What
# this block proves is the two things the hotfix cares about: with GraphQL dead
# a real open PR is still verified and the RESULT is left alone, and an
# affirmative 404 over a visible repo still relabels.
gshim_reset
mkdir -p "$T/build" "$T/h/logs" "$T/h/env" "$T/igh"
marked() { # marked <start> <end> <file> — the block BETWEEN the markers
  awk -v s="$1" -v e="$2" 'index($0,s){f=1;next} index($0,e){f=0} f' "$3"
}
marked '# >>> pr verify gate (BH-709)' '# <<< pr verify gate' "$DIR/bin/fly-pool.sh" >"$T/gate.sh"
marked '# >>> pr verify rest (BH-709)' '# <<< pr verify rest' "$DIR/bin/fly-pool.sh" >"$T/rest.sh"
mkdir -p "$T/h/bin/lib"
cp "$DIR/bin/lib/gh-rest.sh" "$T/h/bin/lib/gh-rest.sh"
cp "$DIR/bin/lib/gh-rest-var.sh" "$T/h/bin/lib/gh-rest-var.sh"
cp "$DIR/bin/alert-line.sh" "$T/h/bin/alert-line.sh"

if [ -s "$T/gate.sh" ] && [ -s "$T/rest.sh" ]; then ok
else bad "pool-gate-768: the BH-709 markers extracted nothing from bin/fly-pool.sh"; fi
eq "pool-gate-768 block is the relabeler" "$(grep -c 'RESULT_UNVERIFIED %s' "$T/gate.sh")" "1"
# AND THE EXTRACTED READER REALLY DEFINES THE READ. The gate has a silent arm
# for "bin/lib/gh-rest.sh is not on this box" — no relabel, one alert — which
# every assertion below would read as a verdict. Prove the reader is live
# before believing any of them.
eq "pool-gate-768 rest block defines the reader" \
  "$(HARNESS="$T/h" bash -c '. "$0" >/dev/null 2>&1; command -v gh_rest_pr_state >/dev/null && echo yes || echo no' "$T/rest.sh")" \
  "yes"

# THE GATE'S READER IS A LIBRARY ON THE BOX, NOT A BLOCK IN fly-pool.sh
# (BH-781, landed on main after this branch's base). The extracted `rest.sh` is
# now one `. "$HARNESS/bin/lib/gh-rest.sh"`, so a $HARNESS without that file
# sends the gate down its "no REST reader on this box" arm — one alert, no
# relabel, and all three assertions below read a gate that never ran. Install
# the REAL library into the fixture harness: the point of this block is that the
# production entry point is what executes, and after BH-781 the production
# reader is this file.
# `gh api -i` is what gh_rest calls, and the fixture stub answers bodies only.
# This wrapper adds the status line the library reads FIRST and hands every
# other call to the stub behind it, so the library's own parsing is what runs.
# The path is found by scanning argv (`api -i -X GET <path> …`) rather than
# taken from $3, which was the method flag once BH-781 put gh_rest in front.
cat >"$T/igh/gh" <<IGH
#!/bin/bash
T=$(printf '%q' "$T")
IGH
cat >>"$T/igh/gh" <<'IGH'
if [ "${1:-}" = api ] && [ "${2:-}" = -i ]; then
  shift 2; path=""
  while [ $# -gt 0 ]; do
    case "$1" in
      -X|-f|-F|-H|--field|--raw-field|--header|--method) shift 2; continue ;;
      -*) shift; continue ;;
      *) path="$1"; break ;;
    esac
  done
  body=$("$T/real/gh" api "$path" 2>/dev/null); rc=$?
  if [ "$rc" -eq 0 ]; then printf 'HTTP/2.0 200 OK\r\n\r\n%s\n' "$body"
  else printf 'HTTP/2.0 404 Not Found\r\n\r\n'; fi
  exit 0
fi
exec "$T/real/gh" "$@"
IGH
chmod 755 "$T/igh/gh"

run_gate() {
  cat >"$T/gate-run.sh" <<'RUN'
set -u
HARNESS="$GT/h"; LOCAL="$GT/build"; KEY=k; P=p; HENV="$GT/h/env"
STAMP() { printf 'TS'; }
say() { :; }
sleep() { :; }
RLINE="PR_CREATED https://github.com/o/r/pull/1"
. "$GT/rest.sh"
. "$GT/gate.sh"
RUN
  GT="$T" PATH="$T/shim:$T/igh:$SYS_PATH" bash "$T/gate-run.sh" >"$T/gate.out" 2>"$T/gate.err"
}
# A RESULT whose second line carries a '|' — those lines are why the gate
# rewrites with printf and not sed.
printf 'PR_CREATED https://github.com/o/r/pull/1\nsecond line|with a pipe\n' >"$T/build/RESULT"
pull_fixture open null
gshim_fixture repos_o_r <<'J'
{"id":1,"name":"r","default_branch":"main","archived":false,"full_name":"o/r"}
J
printf 'GraphQL: API rate limit already exceeded\n' >"$T/fixtures/passthru.err"
printf '1\n' >"$T/fixtures/passthru.rc"
run_gate
eq "pool-gate-768 RESULT untouched" "$(head -1 "$T/build/RESULT")" "PR_CREATED https://github.com/o/r/pull/1"
eq "pool-gate-768 no alert" "$([ -e "$T/h/logs/ALERTS.log" ] && echo present || echo absent)" "absent"
# The control: an affirmative 404 with the repo itself visible DOES relabel,
# which is what proves the extracted block is the live gate and not inert text.
rm -f "$T/fixtures/repos_o_r_pulls_1.json"
run_gate
eq "pool-gate-768 404 relabels" "$(head -1 "$T/build/RESULT")" "RESULT_UNVERIFIED PR_CREATED https://github.com/o/r/pull/1"
eq "pool-gate-768 404 keeps the pipe line" "$(sed -n 2p "$T/build/RESULT")" "second line|with a pipe"
eq "pool-gate-768 404 alerts once" "$(grep -c 'rewritten RESULT_UNVERIFIED' "$T/h/logs/ALERTS.log")" "1"
rm -f "$T/fixtures/passthru.rc" "$T/fixtures/passthru.err" "$T/h/logs/ALERTS.log"
pull_fixture open null

# ── mutation (D1): misspell MERGED, watch pr-view-state-merged go red ────────
mkdir -p "$T/lib"
for f in "$DIR"/bin/lib/gh-shim/*.sh; do cp "$f" "$T/lib/"; done
sed -i 's/"MERGED"/"MERGD"/g' "$T/lib/pr-read.sh"
if [ "$(grep -c '"MERGED"' "$DIR/bin/lib/gh-shim/pr-read.sh")" -ge 1 ] &&
   [ "$(grep -c '"MERGED"' "$T/lib/pr-read.sh")" -eq 0 ]; then ok
else bad "mutation: the sed did not change anything"; fi
gshim_reset; pull_fixture closed '"2026-09-03T00:00:00Z"'
gshim_run pr view 1 -R o/r --json state -q .state
eq "mutation baseline is MERGED" "$OUT" "MERGED"
GH_SHIM_LIB="$T/lib" gshim_run pr view 1 -R o/r --json state -q .state
if [ "$OUT" = "MERGED" ]; then
  bad "mutation: the mutant still says MERGED — pr-view-state-merged pins nothing"
else
  ok
fi

echo "gh-shim-pr-read: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] || exit 1
exit 0
