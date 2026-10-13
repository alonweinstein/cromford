#!/bin/bash
# tests/gh-shim-pr-read.bh-788-test.sh — the review round on bin/lib/gh-shim/
# pr-read.sh (PR #882, the operator's CHANGES_REQUESTED of 2026-09-18): findings 2
# (over-fetch ignores the page ceiling), 4 (search terms unencoded) and 5 (the
# per-hit GET /pulls/{n} trigger names fields the search hit already carries).
#
# HOW IT DRIVES. The real bin/gh-rest-shim with the real shipped handlers
# (GH_SHIM_LIB unset) over tests/lib/gh-shim-stub.sh's fixture stub. Assertions
# are stdout, the exit code and $T/gh-calls.txt — never handler source.
#
# WHY A SEPARATE FILE from tests/gh-shim-pr-read-test.sh: bin/lib/test-home-lib.sh's
# th_is_own reads ownership off the BASENAME (`.bh-788-test.sh`), and the
# launch-time test reroute applies that rule mechanically.
#
# Run from anywhere:  bash tests/gh-shim-pr-read.bh-788-test.sh (exit 0 = pass)
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

pull_row() { # pull_row <n> — a merged pull, the shape GET /pulls answers
  printf '{"number":%s,"node_id":"PR_%s","html_url":"https://github.com/o/r/pull/%s","title":"T%s","body":"b","state":"closed","draft":false,"merged_at":"2026-09-02T00:00:00Z","created_at":"2026-09-01T00:00:00Z","updated_at":"2026-09-02T00:00:00Z","closed_at":"2026-09-02T00:00:00Z","head":{"ref":"ticket/bh-%s","sha":"sha%s","repo":{"full_name":"o/r"}},"base":{"ref":"main","repo":{"full_name":"o/r"}},"user":{"login":"operator","type":"User"},"labels":[],"assignees":[],"milestone":null}' \
    "$1" "$1" "$1" "$1" "$1" "$1"
}

page_of_100() { # page_of_100 <file> <first-number>
  local f="$1" base="$2" i
  { printf '['
    for i in $(seq 0 99); do
      [ "$i" = 0 ] || printf ','
      pull_row $((base + i))
    done
    printf ']'
  } >"$f"
}

# A search hit carries the ISSUE shape: .draft, .pull_request.merged_at, .node_id.
search_hit() {
  printf '{"total_count":1,"items":[{"number":7,"node_id":"PR_7","html_url":"https://github.com/o/r/pull/7","title":"BH-788 read side","body":"b","state":"closed","draft":false,"created_at":"2026-09-01T00:00:00Z","updated_at":"2026-09-02T00:00:00Z","closed_at":"2026-09-02T00:00:00Z","user":{"login":"operator","type":"User"},"labels":[],"pull_request":{"merged_at":"2026-09-02T00:00:00Z"}}]}'
}

# THE CEILING CASES PIN FACTOR 1 ON PURPOSE. A drop-filtered read pages under
# GH_SHIM_MAX_PAGES x GH_SHIM_DROP_PAGE_FACTOR (BH-788 fix round 1: 10 x 3 = 3000
# rows), because a window that only ever holds --limit records can never deliver
# --limit rows once the filter eats into it. These four cases are about what the
# CEILING does when it is reached, so they pin the factor at 1 and keep the
# 2-page ceiling they were written against; the widening itself is pinned by
# pr-list-filter-window* below.
# ── pr-list-over-ceiling (finding 2) ─────────────────────────────────────────
# --state merged filters AFTER the fetch, so the query over-fetches; asking for
# limit*2 with no cap made gshim_paginate run out of pages and exit 1 with 200 rows
# already in hand.
gshim_reset
page_of_100 "$T/fixtures/repos_o_r_pulls.p1.json" 1000
page_of_100 "$T/fixtures/repos_o_r_pulls.p2.json" 2000
GH_SHIM_MAX_PAGES=2 GH_SHIM_DROP_PAGE_FACTOR=1 gshim_run pr list -R o/r --state merged --limit 200 --json number -q length
eq "pr-list-over-ceiling rc" "$RC" "0"
eq "pr-list-over-ceiling rows" "$OUT" "200"
eq "pr-list-over-ceiling err" "$ERR" ""
eq "pr-list-over-ceiling two calls" "$(gshim_calls | grep -c 'api repos/o/r/pulls')" "2"
has "pr-list-over-ceiling closed not merged" "$(gshim_calls)" "state=closed"

# A limit the ceiling can never satisfy still exits rather than returning a
# ceiling's worth of rows as if it were the whole list.
gshim_reset
GH_SHIM_MAX_PAGES=2 GH_SHIM_DROP_PAGE_FACTOR=1 gshim_run pr list -R o/r --state merged --limit 250 --json number -q length
eq "pr-list-past-ceiling rc" "$RC" "1"
eq "pr-list-past-ceiling no body" "$OUT" ""
has "pr-list-past-ceiling says why" "$ERR" "narrow the query"

# Unfiltered lists never over-fetched and still do not.
gshim_reset
rm -f "$T/fixtures/repos_o_r_pulls.p1.json" "$T/fixtures/repos_o_r_pulls.p2.json"
{ printf '['; pull_row 1; printf ']'; } >"$T/fixtures/repos_o_r_pulls.json"
gshim_run pr list -R o/r --limit 30 --json number
has "pr-list-unfiltered-no-overfetch" "$(gshim_calls)" "per_page=30"
gshim_reset
gshim_run pr list -R o/r --state merged --limit 30 --json number
has "pr-list-filtered-overfetch-unchanged" "$(gshim_calls)" "per_page=60"

# ── pr-list-filter-window (fix round 1, review Important 2) ─────────────────
# `merged`, --label and --author are applied AFTER the fetch, and a window that
# came back FULL with fewer than --limit survivors used to be answered as if it
# were the whole list: `pr list --state merged --limit 100` returned 80 rows
# rc 0 where real gh (GraphQL `states: MERGED`) returns 100, and
# bin/board-invariants.sh:81, bin/pr-owner-sweep.sh:261 and
# bin/lib/revdep-lib.sh:163 read that as "these are all the merged PRs".
# Here the first 95 closed pulls are UNMERGED, so the limit*2 window holds none
# of what was asked for; the window widens until 30 merged rows are in hand.
mixed_page() { # mixed_page <file> <first> <count> <first-merged-offset>
  jq -nc --argjson b "$2" --argjson c "$3" --argjson m "$4" '[ range($b; $b+$c) | . as $n
    | {number: $n, node_id: ("PR_"+($n|tostring)),
       html_url: ("https://github.com/o/r/pull/"+($n|tostring)), title: ("T"+($n|tostring)),
       body: "b", state: "closed", draft: false,
       merged_at: (if ($n - $b) >= $m then "2026-09-02T00:00:00Z" else null end),
       created_at:"2026-09-01T00:00:00Z", updated_at:"2026-09-02T00:00:00Z",
       closed_at:"2026-09-02T00:00:00Z",
       head: {ref: ("ticket/bh-"+($n|tostring)), sha: ("sha"+($n|tostring)), repo: {full_name:"o/r"}},
       base: {ref:"main", repo:{full_name:"o/r"}},
       user: {login:"operator",type:"User"}, labels: [], assignees: [], milestone: null} ]' >"$1"
}
gshim_reset
rm -f "$T"/fixtures/repos_o_r_pulls*.json
mixed_page "$T/fixtures/repos_o_r_pulls.p1.json" 1000 100 95
mixed_page "$T/fixtures/repos_o_r_pulls.p2.json" 2000 40 0
GH_SHIM_MAX_PAGES=1 gshim_run pr list -R o/r --state merged --limit 30 --json number -q length
eq "pr-list-filter-window rc" "$RC" "0"
eq "pr-list-filter-window rows" "$OUT" "30"
eq "pr-list-filter-window err" "$ERR" ""
has "pr-list-filter-window first window" "$(gshim_calls)" "per_page=60"
# Three windows were asked for (each starts again at page=1): 60, then 120,
# then 240 — the first two came back full with too few merged rows in them.
eq "pr-list-filter-window widened" "$(gshim_calls | grep -c 'page=1 query=')" "3"
has "pr-list-filter-window widened past the plain ceiling" "$(gshim_calls)" "per_page=100&page=2"

# A window that is STILL full at the drop ceiling is the one case that errors —
# a short list there would be the same lie, with no window left to widen into.
gshim_reset
rm -f "$T"/fixtures/repos_o_r_pulls*.json
mixed_page "$T/fixtures/repos_o_r_pulls.p1.json" 1000 100 100
GH_SHIM_MAX_PAGES=1 GH_SHIM_DROP_PAGE_FACTOR=1 \
  gshim_run pr list -R o/r --state merged --limit 30 --json number -q length
eq "pr-list-filter-window-ceiling rc" "$RC" "1"
eq "pr-list-filter-window-ceiling no body" "$OUT" ""
has "pr-list-filter-window-ceiling says why" "$ERR" "narrow the query"

# An UNFILTERED list never had rows dropped under it, so it neither widens nor
# errors: --limit is the ask and a short page is the whole answer.
gshim_reset
rm -f "$T"/fixtures/repos_o_r_pulls*.json
mixed_page "$T/fixtures/repos_o_r_pulls.json" 1000 5 5
GH_SHIM_MAX_PAGES=1 GH_SHIM_DROP_PAGE_FACTOR=1 \
  gshim_run pr list -R o/r --state closed --limit 30 --json number -q length
eq "pr-list-unfiltered-never-widens rc" "$RC" "0"
eq "pr-list-unfiltered-never-widens rows" "$OUT" "5"
eq "pr-list-unfiltered-never-widens one call" "$(gshim_calls | grep -c 'api repos/o/r/pulls')" "1"

# ── pr-list-search-encoded (finding 4) ───────────────────────────────────────
gshim_reset
search_hit >"$T/fixtures/search_issues.json"
gshim_run pr list -R o/r --state all --search 'a&b #1' --json number
eq "pr-list-search-encoded rc" "$RC" "0"
has "pr-list-search-encoded q" "$(gshim_calls)" "q=repo:o/r+is:pr+a%26b%20%231"
hasnt "pr-list-search-encoded no split" "$(gshim_calls)" "+a&b"
hasnt "pr-list-search-encoded no fragment" "$(gshim_calls)" "#1"
# The existing pin's plain term is untouched: @uri leaves A-Za-z0-9-_.~ alone.
gshim_reset
gshim_run pr list -R o/r --state all --search "BH-788" --json number
has "pr-list-search-plain-term-unchanged" "$(gshim_calls)" "q=repo:o/r+is:pr+BH-788"

# ── pr-list-search-hit-fields-no-refetch (finding 5) ─────────────────────────
# mergedAt, isDraft and id all come out of the hit. Asking for them used to cost
# one GET /pulls/{n} per hit for an answer already in hand.
gshim_reset
rm -f "$T/fixtures/repos_o_r_pulls_7.json"
gshim_run pr list -R o/r --state all --search x --json number,mergedAt,isDraft,id
eq "pr-list-search-hit-fields rc" "$RC" "0"
eq "pr-list-search-hit-fields rows" "$OUT" \
  '[{"number":7,"mergedAt":"2026-09-02T00:00:00Z","isDraft":false,"id":"PR_7"}]'
eq "pr-list-search-hit-fields-no-refetch" "$(gshim_calls | grep -c 'api repos/o/r/pulls/')" "0"
# state comes off .pull_request.merged_at, so MERGED without a per-hit read too.
gshim_reset
gshim_run pr list -R o/r --state all --search x --json number,state -q '.[0].state'
eq "pr-list-search-state-from-hit" "$OUT" "MERGED"
eq "pr-list-search-state-no-refetch" "$(gshim_calls | grep -c 'api repos/o/r/pulls/')" "0"

# ── pr-list-search-branch-refetches ──────────────────────────────────────────
# The three fields a search hit CANNOT carry still cost their call, once per hit.
gshim_reset
pull_row 7 >"$T/fixtures/repos_o_r_pulls_7.json"
gshim_run pr list -R o/r --state all --search x --json number,headRefName -q '.[0].headRefName'
eq "pr-list-search-branch-refetches rc" "$RC" "0"
eq "pr-list-search-branch-refetches value" "$OUT" "ticket/bh-7"
eq "pr-list-search-branch-refetches one call" "$(gshim_calls | grep -c 'api repos/o/r/pulls/7')" "1"
gshim_reset
gshim_run pr list -R o/r --state all --search x --json number,headRefOid -q '.[0].headRefOid'
eq "pr-list-search-headRefOid-refetches" "$OUT" "sha7"
gshim_reset
gshim_run pr list -R o/r --state all --search x --json number,baseRefName -q '.[0].baseRefName'
eq "pr-list-search-baseRefName-refetches" "$OUT" "main"

# ── mutation-search-trigger (D1): put the over-broad regex back ───────────────
mkdir -p "$T/lib"
for f in "$DIR"/bin/lib/gh-shim/*.sh; do cp "$f" "$T/lib/"; done
sed -i 's/(headRefName|headRefOid|baseRefName),/(headRefName|headRefOid|baseRefName|isDraft|mergedAt|id),/' \
  "$T/lib/pr-read.sh"
if [ "$(grep -c 'isDraft|mergedAt|id),' "$DIR/bin/lib/gh-shim/pr-read.sh")" -eq 0 ] &&
   [ "$(grep -c 'isDraft|mergedAt|id),' "$T/lib/pr-read.sh")" -ge 1 ]; then ok
else bad "mutation-search-trigger: the sed did not change anything"; fi
gshim_reset
GH_SHIM_LIB="$T/lib" gshim_run pr list -R o/r --state all --search x --json number,mergedAt,isDraft,id
if [ "$(gshim_calls | grep -c 'api repos/o/r/pulls/')" -eq 0 ]; then
  bad "mutation-search-trigger: the mutant made no per-hit read — the block pins nothing"
else
  ok
fi

# ── mutation-cap (D1): put the uncapped GSHIM_LIMIT * 2 back ───────────────────
for f in "$DIR"/bin/lib/gh-shim/*.sh; do cp "$f" "$T/lib/"; done
sed -i 's|fetch=$(gshim_overfetch "$GSHIM_LIMIT")|fetch=$((GSHIM_LIMIT * 2))|' "$T/lib/pr-read.sh"
if [ "$(grep -cF 'fetch=$(gshim_overfetch' "$DIR/bin/lib/gh-shim/pr-read.sh")" -ge 1 ] &&
   [ "$(grep -cF 'fetch=$(gshim_overfetch' "$T/lib/pr-read.sh")" -eq 0 ]; then ok
else bad "mutation-cap: the sed did not change anything"; fi
gshim_reset
rm -f "$T/fixtures/repos_o_r_pulls.json"
page_of_100 "$T/fixtures/repos_o_r_pulls.p1.json" 1000
page_of_100 "$T/fixtures/repos_o_r_pulls.p2.json" 2000
GH_SHIM_MAX_PAGES=2 GH_SHIM_DROP_PAGE_FACTOR=1 gshim_run pr list -R o/r --state merged --limit 200 --json number -q length
eq "mutation-cap baseline rc" "$RC" "0"
GH_SHIM_MAX_PAGES=2 GH_SHIM_DROP_PAGE_FACTOR=1 GH_SHIM_LIB="$T/lib" gshim_run pr list -R o/r --state merged --limit 200 --json number -q length
if [ "$RC" = "0" ]; then
  bad "mutation-cap: the mutant still answers rc 0 — pr-list-over-ceiling pins nothing"
else
  ok
fi


# ── pr-view-comments-argv (fix round: a body never travels through argv) ─────
# `gh pr view N --json comments` on a long thread: 50 comments of 3 KB is 150 KB
# of JSON, over MAX_ARG_STRLEN. gshim_pr_attach carried it as `--argjson v`, so
# jq never started, and the pipeline printed EMPTY with rc 0. The attachment is
# read from a temp file now.
gshim_reset
rm -f "$T"/fixtures/repos_o_r_pulls*.json
big=$(head -c 3072 /dev/zero | tr '\0' 'x')
pull_row 1 >"$T/fixtures/repos_o_r_pulls_1.json"
jq -nc --arg b "$big" '[ range(50) | {node_id: ("IC_"+tostring), id: .,
  user:{login:"operator",type:"User"}, author_association:"OWNER", body:$b,
  created_at:"2026-09-01T00:00:00Z", updated_at:"2026-09-01T00:00:00Z",
  html_url:"u"} ]' >"$T/fixtures/repos_o_r_issues_1_comments.json"
gshim_run pr view 1 -R o/r --json comments -q '.comments | length'
eq "pr-view-comments-argv rc" "$RC" "0"
eq "pr-view-comments-argv err" "$ERR" ""
eq "pr-view-comments-argv count" "$OUT" "50"
gshim_run pr view 1 -R o/r --json number,comments -q '.comments[49].body | length'
eq "pr-view-comments-argv last body intact" "$OUT" "3072"

# ── pr-view-rollup-argv (fix round) ──────────────────────────────────────────
# gshim_pr_rollup had the same `--argjson r "$runs"`: 100 check runs with long
# detail URLs is one 200 KB body.
jq -nc --arg b "$big" '{check_runs: [ range(100) | {name: ("c"+tostring),
  status:"completed", conclusion:"success", started_at:"2026-09-01T00:00:00Z",
  completed_at:"2026-09-01T00:01:00Z", details_url: ("https://x/"+$b)} ]}' \
  >"$T/fixtures/repos_o_r_commits_sha1_check-runs.p1.json"
printf '{"check_runs":[]}' >"$T/fixtures/repos_o_r_commits_sha1_check-runs.p2.json"
printf '{"statuses":[]}' >"$T/fixtures/repos_o_r_commits_sha1_status.json"
gshim_run pr view 1 -R o/r --json statusCheckRollup -q '.statusCheckRollup | length'
eq "pr-view-rollup-argv rc" "$RC" "0"
eq "pr-view-rollup-argv count" "$OUT" "100"
rm -f "$T/fixtures/repos_o_r_issues_1_comments.json" "$T"/fixtures/repos_o_r_commits_sha1_*.json

# ── pr-view-rollup-paginates (fix round) ─────────────────────────────────────
# Both halves of the rollup were one un-paginated per_page=100 read: run 101
# vanished with rc 0, and bin/merge-conductor-lib.sh reads this array for the
# Mergify queue check, so a check past row 100 read as "no queue check" on a
# merge gate. Both go through gshim_paginate now.
gshim_reset
jq -nc '{check_runs: [ range(100) | {name: ("c"+tostring), status:"completed",
  conclusion:"success", started_at:"2026-09-01T00:00:00Z",
  completed_at:"2026-09-01T00:01:00Z", details_url:"u"} ]}' \
  >"$T/fixtures/repos_o_r_commits_sha1_check-runs.p1.json"
jq -nc '{check_runs: [ range(100;150) | {name: ("c"+tostring), status:"completed",
  conclusion:"success", started_at:"2026-09-01T00:00:00Z",
  completed_at:"2026-09-01T00:01:00Z", details_url:"u"} ]}' \
  >"$T/fixtures/repos_o_r_commits_sha1_check-runs.p2.json"
printf '{"statuses":[{"context":"vercel","state":"success","target_url":"u","created_at":"2026-09-01T00:00:00Z"}]}' \
  >"$T/fixtures/repos_o_r_commits_sha1_status.json"
gshim_run pr view 1 -R o/r --json statusCheckRollup -q '[ .statusCheckRollup[] | select(.__typename == "CheckRun") ] | length'
eq "pr-view-rollup-paginates rc" "$RC" "0"
eq "pr-view-rollup-paginates all runs" "$OUT" "150"
eq "pr-view-rollup-paginates two pages" "$(gshim_calls | grep -c 'check-runs')" "2"
gshim_run pr view 1 -R o/r --json statusCheckRollup -q '.statusCheckRollup[150].context'
eq "pr-view-rollup-paginates statuses kept" "$OUT" "vercel"
gshim_run pr view 1 -R o/r --json statusCheckRollup -q '.statusCheckRollup[149].name'
eq "pr-view-rollup-paginates last run" "$OUT" "c149"
rm -f "$T"/fixtures/repos_o_r_commits_sha1_*.json

# ── pr-list-search-argv (fix round) ──────────────────────────────────────────
# The per-hit GET /pulls/{n} path (headRefName asked for) accumulated rows with
# `--argjson a "$out"`: 30 hits of 6 KB bodies overflowed it, and the handler
# printed "" with rc 0 — blocked-resolver read "no merged PR" and rebuilt a
# landed ticket. Rows go to one temp file each, joined by `jq -s`.
gshim_reset
big6=$(head -c 6144 /dev/zero | tr '\0' 'y')
jq -nc --arg b "$big6" '{total_count: 30, items: [ range(1;31) | {number: .,
  node_id: ("PR_"+tostring), html_url: ("https://github.com/o/r/pull/"+tostring),
  title: ("T"+tostring), body: $b, state:"closed", draft:false,
  created_at:"2026-09-01T00:00:00Z", updated_at:"2026-09-02T00:00:00Z",
  closed_at:"2026-09-02T00:00:00Z", user:{login:"operator",type:"User"}, labels:[],
  pull_request:{merged_at:"2026-09-02T00:00:00Z"}} ]}' >"$T/fixtures/search_issues.json"
for n in $(seq 1 30); do
  pull_row "$n" | jq -c --arg b "$big6" '.body = $b' >"$T/fixtures/repos_o_r_pulls_$n.json"
done
gshim_run pr list -R o/r --search 'BH-788' --state merged --limit 30 --json number,headRefName -q length
eq "pr-list-search-argv rc" "$RC" "0"
eq "pr-list-search-argv err" "$ERR" ""
eq "pr-list-search-argv rows" "$OUT" "30"
eq "pr-list-search-argv one GET per hit" "$(gshim_calls | grep -c 'api repos/o/r/pulls/[0-9]')" "30"
gshim_reset
gshim_run pr list -R o/r --search 'BH-788' --state merged --limit 30 --json number,headRefName,body -q '.[29] | .headRefName + " " + (.body|length|tostring)'
eq "pr-list-search-argv last row intact" "$OUT" "ticket/bh-30 6144"
rm -f "$T"/fixtures/repos_o_r_pulls_*.json

# ── pr-list-search-qualifiers (fix round) ────────────────────────────────────
# --author and --label with --search were post-filters with no qualifier and
# no over-fetch, so --limit N under-answered. Both are qualifiers on q now.
gshim_reset
search_hit >"$T/fixtures/search_issues.json"
gshim_run pr list -R o/r --search x --author operator --label ai-build --label 'needs review' --json number
eq "pr-list-search-qualifiers rc" "$RC" "0"
has "pr-list-search-qualifiers author" "$(gshim_calls)" "+author:operator+label:%22ai-build%22+label:%22needs%20review%22+x"

# ── pr-list-search-tsv-branch (fix round) ────────────────────────────────────
# `gh pr list --state all --search "<KEY>"` with no --json is the duplicate-work
# check every project prompt hands a build lane, and field 3 of gh's own columns
# is the branch. A search hit cannot carry it, so the column printed empty for
# every row; the TSV path refetches /pulls/{n} the way the --json path does.
gshim_reset
search_hit >"$T/fixtures/search_issues.json"
pull_row 7 >"$T/fixtures/repos_o_r_pulls_7.json"
gshim_run pr list -R o/r --state all --search 'BH-788'
eq "pr-list-search-tsv-branch rc" "$RC" "0"
eq "pr-list-search-tsv-branch f1" "$(printf '%s' "$OUT" | cut -f1)" "7"
eq "pr-list-search-tsv-branch f2" "$(printf '%s' "$OUT" | cut -f2)" "T7"
eq "pr-list-search-tsv-branch f3" "$(printf '%s' "$OUT" | cut -f3)" "ticket/bh-7"
eq "pr-list-search-tsv-branch one refetch" "$(gshim_calls | grep -c 'api repos/o/r/pulls/7')" "1"
# A --json read that names none of the three still costs nothing extra.
gshim_reset
gshim_run pr list -R o/r --state all --search 'BH-788' --json number,title
eq "pr-list-search-json-no-refetch" "$(gshim_calls | grep -c 'api repos/o/r/pulls/')" "0"
rm -f "$T/fixtures/repos_o_r_pulls_7.json"

# ── pr-view-reviews-app-author (fix round 1, review Nit 6) ──────────────────
# A review left by a GitHub App used to come out as the raw REST login
# `cromford[bot]` while a COMMENT by the same App came out as
# `app/cromford` — and bin/review-prs.sh:713-714 prints both into one
# thread, so the same actor appeared twice under two names and
# harness_pr_author_match only recognised one of them. Reviews map through the
# same gshim_author as comments now.
gshim_reset
rm -f "$T"/fixtures/repos_o_r_pulls*.json
printf '%s' '{"number":1,"node_id":"PR_1","html_url":"https://github.com/o/r/pull/1","title":"T","body":"b","state":"open","draft":false,"merged_at":null,"created_at":"2026-09-01T00:00:00Z","updated_at":"2026-09-02T00:00:00Z","closed_at":null,"head":{"ref":"ticket/bh-788","sha":"sha1","repo":{"full_name":"o/r"}},"base":{"ref":"main","repo":{"full_name":"o/r"}},"user":{"login":"operator","type":"User"},"labels":[],"assignees":[],"milestone":null,"merge_commit_sha":null,"mergeable_state":"clean","additions":1,"deletions":0,"changed_files":1,"comments":0,"review_comments":0,"commits":1}' \
  >"$T/fixtures/repos_o_r_pulls_1.json"
printf '%s' '[{"node_id":"PRR_9","id":9,"user":{"login":"cromford[bot]","type":"Bot"},"body":"lgtm","state":"APPROVED","submitted_at":"2026-09-02T00:00:00Z","commit_id":"cafe"}]' \
  >"$T/fixtures/repos_o_r_pulls_1_reviews.json"
gshim_run pr view 1 -R o/r --json reviews -q '.reviews[0].author.login'
eq "pr-view-reviews-app-author rc" "$RC" "0"
eq "pr-view-reviews-app-author login" "$OUT" "app/cromford"

# ── pr-list-bad-state-passthru (fix round 1) ────────────────────────────────
# An unknown --state has to reach real gh. The check used to live inside
# gshim_pr_list_rest, which runs inside `rows=$(…)`: gshim_passthru takes over
# the process there, so gh's answer would have been captured into $rows and fed
# to jq instead of reaching the caller. It is validated before the substitution
# now, and the depth marker proves the shim is the one that handed it over.
gshim_reset
rm -f "$T"/fixtures/repos_o_r_pulls*.json
gshim_run pr list -R o/r --state queued --json number
eq "pr-list-bad-state-passthru rc" "$RC" "0"
has "pr-list-bad-state-passthru argv" "$(gshim_calls)" "PASSTHRU pr list -R o/r --state queued --json number"
has "pr-list-bad-state-passthru depth" "$(gshim_env)" "depth=1 pr list -R o/r --state queued"
eq "pr-list-bad-state-passthru no rest call" "$(gshim_calls | grep -c 'api repos/o/r/pulls')" "0"

# ── pr-list-refname-encoded (train #1227 review, finding 3) ──────────────────
# A GIT REFNAME IS CALLER DATA, AND `&` AND `#` ARE BOTH LEGAL IN ONE. Raw
# interpolation of --head/--base into the REST query let a branch name open a
# second query parameter (`--base 'x&state=all'` turned a --state open read into
# a --state all read) or truncate the URL at a fragment (`feature#1`). Same
# defect finding 4 fixed for --search terms; the `:` between owner and ref is
# the API's separator and stays literal.
gshim_reset
printf '%s' "[$(pull_row 1)]" >"$T/fixtures/repos_o_r_pulls.json"
gshim_run pr list -R o/r --head 'x&state=all' --base 'feature#1' --json number
eq "pr-list-refname-encoded rc" "$RC" "0"
has "pr-list-refname-encoded head" "$(gshim_calls)" "head=o:x%26state%3Dall"
has "pr-list-refname-encoded base" "$(gshim_calls)" "base=feature%231"
hasnt "pr-list-refname-encoded no injected param" "$(gshim_calls)" "head=o:x&state=all"
hasnt "pr-list-refname-encoded no fragment" "$(gshim_calls)" "feature#1"
# A plain refname is untouched, so the query gh has always sent is byte-identical.
gshim_reset
gshim_run pr list -R o/r --head feature --base main --json number
has "pr-list-plain-refname-unchanged head" "$(gshim_calls)" "head=o:feature"
has "pr-list-plain-refname-unchanged base" "$(gshim_calls)" "base=main"

# pr view with no argument resolves the CHECKED-OUT branch, which is the same
# caller data arriving by another door.
gshim_reset
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
printf 'bug#7&state=all\n' >"$T/fixtures/branch.txt"
printf '%s' "[$(pull_row 1)]" >"$T/fixtures/repos_o_r_pulls.json"
pull_row 1 >"$T/fixtures/repos_o_r_pulls_1.json"
PATH="$T/shim:$T/gitbin:$T/real:$PATH" gshim_run pr view -R o/r --json number -q .number
eq "pr-view-branch-encoded rc" "$RC" "0"
has "pr-view-branch-encoded head" "$(gshim_calls)" "head=o:bug%237%26state%3Dall"
hasnt "pr-view-branch-encoded no fragment" "$(gshim_calls)" "bug#7"

# ── pr-list-filter-jq-failure (train #1227 review, finding 5) ────────────────
# A FAILED FILTER AND AN EMPTY RESULT SET ARE THE SAME BYTES. gshim_pr_filter
# narrows rows step by step; a jq that dies mid-filter left `rows` empty and the
# function still returned 0 through its final printf, so `pr list --author X`
# answered `[]` rc 0 — read by bin/board-invariants.sh:81 and
# bin/pr-owner-sweep.sh:261 as "nothing matches". It has to exit instead.
gshim_reset
mkdir -p "$T/jqbin"
cat >"$T/jqbin/jq" <<JQW
#!/bin/bash
REALJQ=$(printf '%q' "$(command -v jq)")
JQW
cat >>"$T/jqbin/jq" <<'JQW'
# Fail ONLY the author filter's program, so every other jq in the read still works.
for a in "$@"; do
  case "$a" in *'sub("^app/"; "")'*) exit 5 ;; esac
done
exec "$REALJQ" "$@"
JQW
chmod 755 "$T/jqbin/jq"
printf '%s' "[$(pull_row 1)]" >"$T/fixtures/repos_o_r_pulls.json"
PATH="$T/shim:$T/jqbin:$T/real:$PATH" gshim_run pr list -R o/r --author operator --json number
hasnt "pr-list-filter-jq-failure not a silent empty answer" "$OUT" "[]"
if [ "$RC" != "0" ]; then ok; else bad "pr-list-filter-jq-failure rc: a dead filter answered rc 0 with [$OUT]"; fi

# issue list --author takes the same filter through issue-read.sh.
gshim_reset
printf '%s' '[{"number":1,"node_id":"I_1","html_url":"https://github.com/o/r/issues/1","title":"T","body":"b","state":"open","created_at":"2026-09-01T00:00:00Z","updated_at":"2026-09-01T00:00:00Z","closed_at":null,"user":{"login":"operator","type":"User"},"labels":[],"assignees":[],"milestone":null,"comments":0}]' \
  >"$T/fixtures/repos_o_r_issues.json"
PATH="$T/shim:$T/jqbin:$T/real:$PATH" gshim_run issue list -R o/r --author operator --json number
hasnt "issue-list-filter-jq-failure not a silent empty answer" "$OUT" "[]"
if [ "$RC" != "0" ]; then ok; else bad "issue-list-filter-jq-failure rc: a dead filter answered rc 0 with [$OUT]"; fi

echo "gh-shim-pr-read.bh-788: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] || exit 1
exit 0
