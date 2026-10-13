#!/bin/bash
# tests/gh-shim-issue-read.bh-788-test.sh — the review round on bin/lib/gh-shim/
# issue-read.sh (PR #882, the operator's CHANGES_REQUESTED of 2026-09-18): findings 1
# (search drops --state/--label), 2 (over-fetch ignores the page ceiling), 3
# (TSV column order) and 4 (search terms unencoded).
#
# HOW IT DRIVES. The real bin/gh-rest-shim with the real shipped handlers
# (GH_SHIM_LIB unset) over tests/lib/gh-shim-stub.sh's fixture stub. Assertions
# are stdout, the exit code and $T/gh-calls.txt — never handler source.
#
# WHY A SEPARATE FILE from tests/gh-shim-issue-read-test.sh: bin/lib/test-home-
# lib.sh's th_is_own reads OWNERSHIP OFF THE BASENAME (`.bh-788-test.sh`), and
# the launch-time test reroute applies that rule mechanically. Cases this ticket
# owns go where the rule can see they are its own.
#
# THE TWO HIGHs EACH HAVE A MUTANT (D1), not a claim: `mutation-state` strips the
# state: qualifier back out and fails if issue-list-search-state-label still
# passes; `mutation-cap` puts the uncapped `GSHIM_LIMIT * 2` back and fails if the
# 200-row read still comes back rc 0.
#
# Run from anywhere:  bash tests/gh-shim-issue-read.bh-788-test.sh (exit 0 = pass)
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

issue_row() { # issue_row <n> <extra-json>
  printf '{"number":%s,"node_id":"I_%s","html_url":"https://github.com/o/r/issues/%s","title":"Title","body":"Body text","state":"open","created_at":"2026-09-01T00:00:00Z","updated_at":"2026-09-02T04:05:06Z","closed_at":null,"user":{"login":"operator","type":"User"},"labels":[{"node_id":"LA_1","name":"ai-build","description":null,"color":"0"},{"node_id":"LA_2","name":"hotfix","description":null,"color":"0"}],"assignees":[],"milestone":null%s}' \
    "$1" "$1" "$1" "${2:-}"
}

page_of_100() { # page_of_100 <file> <first-number>
  local f="$1" base="$2" i
  { printf '['
    for i in $(seq 0 99); do
      [ "$i" = 0 ] || printf ','
      issue_row $((base + i))
    done
    printf ']'
  } >"$f"
}

hit_of_one() { # a one-hit search/issues answer
  printf '{"total_count":1,"items":[%s]}' "$(issue_row 9)"
}

# ── issue-list-search-state-label (bin/up10-lane.sh:91, verbatim) ────────────
# The lane's own call. Without state:/label: on the query a CLOSED `up10:` issue
# matches and the lane reuses it instead of filing a new one.
gshim_reset
hit_of_one >"$T/fixtures/search_issues.json"
gshim_run issue list -R o/r --label ai-build --state open --search '"up10: x" in:title' --json number,title
eq "issue-list-search-state-label rc" "$RC" "0"
eq "issue-list-search-state-label rows" "$OUT" '[{"number":9,"title":"Title"}]'
has "issue-list-search-state-label q" "$(gshim_calls)" \
  "q=repo:o/r+is:issue+state:open+label:%22ai-build%22+%22up10%3A%20x%22%20in%3Atitle"
# The search endpoint takes neither of the REST list's query params.
hasnt "issue-list-search-state-label no rest state param" "$(gshim_calls)" "state=open"
hasnt "issue-list-search-state-label no rest labels param" "$(gshim_calls)" "labels=ai-build"
eq "issue-list-search-state-label one call" "$(gshim_calls | grep -c 'api search/issues')" "1"

# ── issue-list-search-state-all / closed / default ───────────────────────────
# `all` carries NO state: qualifier, which is what gh does; no --state at all is
# open, gh's default.
gshim_reset
gshim_run issue list -R o/r --state all --search x --json number
hasnt "issue-list-search-state-all" "$(gshim_calls)" "state:"
has "issue-list-search-state-all is:issue" "$(gshim_calls)" "q=repo:o/r+is:issue+x"
gshim_reset
gshim_run issue list -R o/r --state closed --search x --json number
has "issue-list-search-state-closed" "$(gshim_calls)" "state:closed"
gshim_reset
gshim_run issue list -R o/r --search x --json number
has "issue-list-search-state-default-open" "$(gshim_calls)" "state:open"

# ── issue-list-search-labels-comma (both spellings, one shape) ───────────────
gshim_reset
gshim_run issue list -R o/r --label a,b --search x --json number
has "issue-list-search-labels-comma" "$(gshim_calls)" "label:%22a%22+label:%22b%22"
gshim_reset
gshim_run issue list -R o/r --label a --label b --search x --json number
has "issue-list-search-labels-repeated" "$(gshim_calls)" "label:%22a%22+label:%22b%22"
gshim_reset
gshim_run issue list -R o/r --label "needs review" --search x --json number
has "issue-list-search-label-with-space" "$(gshim_calls)" "label:%22needs%20review%22"

# ── issue-list-search-encoded (finding 4) ────────────────────────────────────
# `&` opened a second query parameter and `#` truncated the URL at a fragment.
gshim_reset
gshim_run issue list -R o/r --state all --search 'a&b #1' --json number
has "issue-list-search-encoded" "$(gshim_calls)" "q=repo:o/r+is:issue+a%26b%20%231"
hasnt "issue-list-search-encoded no split" "$(gshim_calls)" "+a&b"
hasnt "issue-list-search-encoded no fragment" "$(gshim_calls)" "#1"
# The alnum case is untouched: @uri leaves A-Za-z0-9-_.~ alone.
gshim_reset
gshim_run issue list -R o/r --search BH-788 --json number
has "issue-list-search-plain-term-unchanged" "$(gshim_calls)" "q=repo:o/r+is:issue+state:open+BH-788"

# THE CEILING CASES PIN FACTOR 1 ON PURPOSE. A drop-filtered read pages under
# GH_SHIM_MAX_PAGES x GH_SHIM_DROP_PAGE_FACTOR (BH-788 fix round 1: 10 x 3 = 3000
# rows), so that `--limit 1000` can reach past the pulls interleaved in front of
# the issues. These cases are about what the CEILING does when it IS reached, so
# they pin the factor at 1 and keep the ceiling they were written against; the
# widening itself is pinned by issue-list-drop-window-widens below.
# ── issue-list-limit-over-ceiling (finding 2, bin/load-project.sh:227,265) ───
# --limit 200 against a 2-page ceiling: the over-fetch used to ask for 400, so
# gshim_paginate ran out of pages and exited 1 with 200 rows already in hand.
gshim_reset
rm -f "$T/fixtures/repos_o_r_issues.json"
page_of_100 "$T/fixtures/repos_o_r_issues.p1.json" 1000
page_of_100 "$T/fixtures/repos_o_r_issues.p2.json" 2000
GH_SHIM_MAX_PAGES=2 GH_SHIM_DROP_PAGE_FACTOR=1 gshim_run issue list -R o/r --state all --limit 200 --json number -q length
eq "issue-list-limit-over-ceiling rc" "$RC" "0"
eq "issue-list-limit-over-ceiling rows" "$OUT" "200"
eq "issue-list-limit-over-ceiling err" "$ERR" ""
eq "issue-list-limit-over-ceiling two calls" "$(gshim_calls | grep -c 'repos/o/r/issues')" "2"
has "issue-list-limit-over-ceiling per_page" "$(gshim_calls)" "per_page=100"

# A limit wider than the ceiling can EVER deliver still exits, rather than
# answering a ceiling's worth of rows as if it were the whole list.
gshim_reset
GH_SHIM_MAX_PAGES=2 GH_SHIM_DROP_PAGE_FACTOR=1 gshim_run issue list -R o/r --state all --limit 250 --json number -q length
eq "issue-list-limit-past-ceiling rc" "$RC" "1"
eq "issue-list-limit-past-ceiling no body" "$OUT" ""
has "issue-list-limit-past-ceiling says why" "$ERR" "narrow the query"

# The knob's own sanitation is the contract's: junk means 10 pages, not 0.
gshim_reset
rm -f "$T/fixtures/repos_o_r_issues.p1.json" "$T/fixtures/repos_o_r_issues.p2.json"
{ printf '['; issue_row 1; printf ']'; } >"$T/fixtures/repos_o_r_issues.json"
GH_SHIM_MAX_PAGES=abc gshim_run issue list -R o/r --state all --limit 30 --json number -q length
eq "issue-list-limit-junk-knob rc" "$RC" "0"
eq "issue-list-limit-junk-knob rows" "$OUT" "1"
eq "issue-list-limit-junk-knob one call" "$(gshim_calls | grep -c 'repos/o/r/issues')" "1"
has "issue-list-limit-junk-knob still over-fetches" "$(gshim_calls)" "per_page=60"

# ── issue-list-tsv-gh-order (finding 3) ──────────────────────────────────────
# Real `gh issue list` non-TTY prints number, STATE, title, labels, updatedAt. A
# reader that takes field 2 as the title used to read `OPEN` as a title.
gshim_reset
gshim_run issue list -R o/r
eq "issue-list-tsv-gh-order rc" "$RC" "0"
eq "issue-list-tsv-gh-order f1" "$(printf '%s' "$OUT" | cut -f1)" "1"
eq "issue-list-tsv-gh-order f2" "$(printf '%s' "$OUT" | cut -f2)" "OPEN"
eq "issue-list-tsv-gh-order f3" "$(printf '%s' "$OUT" | cut -f3)" "Title"
eq "issue-list-tsv-gh-order f4" "$(printf '%s' "$OUT" | cut -f4)" "ai-build,hotfix"
eq "issue-list-tsv-gh-order f5" "$(printf '%s' "$OUT" | cut -f5)" "2026-09-02T04:05:06Z"

# ── mutation-state (D1): strip the state: qualifier, watch the block go red ───
mkdir -p "$T/lib"
for f in "$DIR"/bin/lib/gh-shim/*.sh; do cp "$f" "$T/lib/"; done
sed -i 's/+state:/+stat:/g' "$T/lib/issue-read.sh"
if [ "$(grep -c '+state:' "$DIR/bin/lib/gh-shim/issue-read.sh")" -ge 1 ] &&
   [ "$(grep -c '+state:' "$T/lib/issue-read.sh")" -eq 0 ]; then ok
else bad "mutation-state: the sed did not change anything"; fi
gshim_reset
hit_of_one >"$T/fixtures/search_issues.json"
gshim_run issue list -R o/r --label ai-build --state open --search '"up10: x" in:title' --json number
has "mutation-state baseline" "$(gshim_calls)" "state:open"
gshim_reset
GH_SHIM_LIB="$T/lib" gshim_run issue list -R o/r --label ai-build --state open --search '"up10: x" in:title' --json number
case "$(gshim_calls)" in
  *state:open*) bad "mutation-state: the mutant still sends state:open — the block pins nothing" ;;
  *) ok ;;
esac

# ── mutation-cap (D1): put the uncapped GSHIM_LIMIT * 2 back ───────────────────
for f in "$DIR"/bin/lib/gh-shim/*.sh; do cp "$f" "$T/lib/"; done
sed -i 's|gshim_overfetch "$GSHIM_LIMIT"|echo $((GSHIM_LIMIT * 2))|' "$T/lib/issue-read.sh"
if [ "$(grep -cF 'fetch=$(gshim_overfetch' "$DIR/bin/lib/gh-shim/issue-read.sh")" -ge 1 ] &&
   [ "$(grep -cF 'fetch=$(gshim_overfetch' "$T/lib/issue-read.sh")" -eq 0 ]; then ok
else bad "mutation-cap: the sed did not change anything"; fi
gshim_reset
rm -f "$T/fixtures/repos_o_r_issues.json"
page_of_100 "$T/fixtures/repos_o_r_issues.p1.json" 1000
page_of_100 "$T/fixtures/repos_o_r_issues.p2.json" 2000
GH_SHIM_MAX_PAGES=2 GH_SHIM_DROP_PAGE_FACTOR=1 gshim_run issue list -R o/r --state all --limit 200 --json number -q length
eq "mutation-cap baseline rc" "$RC" "0"
GH_SHIM_MAX_PAGES=2 GH_SHIM_DROP_PAGE_FACTOR=1 GH_SHIM_LIB="$T/lib" gshim_run issue list -R o/r --state all --limit 200 --json number -q length
if [ "$RC" = "0" ]; then
  bad "mutation-cap: the mutant still answers rc 0 — issue-list-limit-over-ceiling pins nothing"
else
  ok
fi


# ── issue-list-comments-argv (fix round: a body never travels through argv) ──
# A production-sized board pass: 100 issues, 3 comments each, 3 KB bodies. The
# first build accumulated the threads with `jq --argjson a "$out"`, which is
# E2BIG (MAX_ARG_STRLEN 128 KB) after ~40 threads: jq exited non-zero, the
# unguarded `out=$(...)` became "" and the handler exited 1 — a triage-gate
# read that fails open. Threads now ride in temp files, joined by one `jq -s`.
gshim_reset
rm -f "$T"/fixtures/repos_o_r_issues*.json
big=$(head -c 3072 /dev/zero | tr '\0' 'x')
jq -nc --arg b "$big" '[ range(1;101) | {number: ., node_id: ("I_"+tostring),
  html_url: ("https://github.com/o/r/issues/"+tostring), title: ("T"+tostring),
  body: $b, state: "open", labels: [], user: {login:"operator",type:"User"},
  created_at:"2026-09-01T00:00:00Z", updated_at:"2026-09-01T00:00:00Z",
  closed_at:null, assignees:[], milestone:null} ]' >"$T/fixtures/repos_o_r_issues.json"
for n in $(seq 1 100); do
  jq -nc --arg b "$big" --arg n "$n" '[ range(3) | {node_id: ("IC_"+$n+"_"+tostring),
    id: ., user:{login:"operator",type:"User"}, author_association:"OWNER", body:$b,
    created_at:"2026-09-01T00:00:00Z", updated_at:"2026-09-01T00:00:00Z",
    html_url:"u"} ]' >"$T/fixtures/repos_o_r_issues_${n}_comments.json"
done
gshim_run issue list -R o/r --limit 100 --json number,comments -q '[ .[].comments | length ] | add'
eq "issue-list-comments-argv rc" "$RC" "0"
eq "issue-list-comments-argv err" "$ERR" ""
eq "issue-list-comments-argv comment count" "$OUT" "300"
gshim_run issue list -R o/r --limit 100 --json number,comments -q 'length'
eq "issue-list-comments-argv rows" "$OUT" "100"
gshim_run issue list -R o/r --limit 100 --json number,comments -q '.[99].comments[2].body | length'
eq "issue-list-comments-argv last body intact" "$OUT" "3072"
rm -f "$T"/fixtures/repos_o_r_issues_*_comments.json "$T/fixtures/repos_o_r_issues.json"

# ── issue-list-search-author-qualifier (fix round) ───────────────────────────
# --author with --search was a post-filter with no author: qualifier and no
# over-fetch, so --limit N under-answered. It is a qualifier on the index now.
gshim_reset
hit_of_one >"$T/fixtures/search_issues.json"
gshim_run issue list -R o/r --search x --author operator --json number
eq "issue-list-search-author-qualifier rc" "$RC" "0"
has "issue-list-search-author-qualifier q" "$(gshim_calls)" "+author:operator+x"

# ── issue-list-pr-window (fix round, the autopilot's HIGH) ───────────────────
# /repos/{slug}/issues interleaves pulls. When the fetch came back at its own
# cap and the pulls ate the window, the handler used to emit whatever issues
# survived with rc 0 — and bin/load-project.sh's `--limit 1000 --json title |
# grep -qxF` duplicate guard read that short list as the whole board and filed
# a duplicate ticket. A window that could not be filled is an error now — this
# case pins the CEILING end of that: one page of ceiling (factor 1) and a window
# that is still full of pulls, so there is nothing left to widen into.
gshim_reset
rm -f "$T"/fixtures/repos_o_r_issues*.json
# 100 rows for a --limit 50 read (fetch = 100): 60 of them are pulls, so 40
# issues survive and the raw page came back full.
jq -nc '[ range(100) | {number: ., node_id: ("I_"+tostring),
  html_url: ("https://github.com/o/r/issues/"+tostring), title: ("T"+tostring),
  body: "b", state: "open", labels: [], user: {login:"operator",type:"User"},
  created_at:"2026-09-01T00:00:00Z", updated_at:"2026-09-01T00:00:00Z",
  closed_at:null, assignees:[], milestone:null }
  | if (.number >= 40) then . + {pull_request: {url: "u"}} else . end ]' \
  >"$T/fixtures/repos_o_r_issues.p1.json"
GH_SHIM_MAX_PAGES=1 GH_SHIM_DROP_PAGE_FACTOR=1 \
  gshim_run issue list -R o/r --state all --limit 50 --json number -q length
eq "issue-list-pr-window rc" "$RC" "1"
eq "issue-list-pr-window no body" "$OUT" ""
has "issue-list-pr-window says why" "$ERR" "narrow the query"

# The same read when the page came back SHORT: no more records exist, so the
# filtered list is the whole list and it answers, short, with rc 0.
gshim_reset
rm -f "$T"/fixtures/repos_o_r_issues*.json
jq -nc '[ range(40) | {number: ., node_id: ("I_"+tostring),
  html_url: ("https://github.com/o/r/issues/"+tostring), title: ("T"+tostring),
  body: "b", state: "open", labels: [], user: {login:"operator",type:"User"},
  created_at:"2026-09-01T00:00:00Z", updated_at:"2026-09-01T00:00:00Z",
  closed_at:null, assignees:[], milestone:null }
  | if (.number >= 30) then . + {pull_request: {url: "u"}} else . end ]' \
  >"$T/fixtures/repos_o_r_issues.json"
gshim_run issue list -R o/r --state all --limit 50 --json number -q length
eq "issue-list-pr-window-complete rc" "$RC" "0"
eq "issue-list-pr-window-complete rows" "$OUT" "30"
eq "issue-list-pr-window-complete err" "$ERR" ""

# A full window that the filter does NOT eat into still answers.
gshim_reset
rm -f "$T"/fixtures/repos_o_r_issues*.json
jq -nc '[ range(100) | {number: ., node_id: ("I_"+tostring),
  html_url: ("https://github.com/o/r/issues/"+tostring), title: ("T"+tostring),
  body: "b", state: "open", labels: [], user: {login:"operator",type:"User"},
  created_at:"2026-09-01T00:00:00Z", updated_at:"2026-09-01T00:00:00Z",
  closed_at:null, assignees:[], milestone:null } ]' \
  >"$T/fixtures/repos_o_r_issues.p1.json"
gshim_run issue list -R o/r --state all --limit 50 --json number -q length
eq "issue-list-pr-window-full rc" "$RC" "0"
eq "issue-list-pr-window-full rows" "$OUT" "50"

# ── issue-list-drop-window-widens (fix round 1, review Important 3) ──────────
# THE OTHER END OF THE SAME WINDOW. Exiting 1 whenever the pulls fill the window
# made `issue list --state all --limit 1000` — bin/load-project.sh:330-334,
# 377-381 — exit on EVERY repo with 1000+ issues+pulls (cromford is at
# #1201), where real gh answers from GraphQL and never sees a pull at all. The
# window now DOUBLES under the drop ceiling until either --limit rows survive or
# the endpoint runs out of records; only a ceiling still full of pulls errors.
# Here: two full pages of pulls in front of 40 issues, a one-page PLAIN ceiling,
# and the read still reaches the issues.
gshim_reset
rm -f "$T"/fixtures/repos_o_r_issues*.json
pulls_page() { # pulls_page <file> <first> <count>
  jq -nc --argjson b "$2" --argjson c "$3" '[ range($b; $b+$c) | {number: .,
    node_id: ("I_"+(.|tostring)), html_url: ("https://github.com/o/r/issues/"+(.|tostring)),
    title: ("T"+(.|tostring)), body: "b", state: "open", labels: [],
    user: {login:"operator",type:"User"}, created_at:"2026-09-01T00:00:00Z",
    updated_at:"2026-09-01T00:00:00Z", closed_at:null, assignees:[], milestone:null,
    pull_request: {url: "u"} } ]' >"$1"
}
issues_page() { # issues_page <file> <first> <count>
  jq -nc --argjson b "$2" --argjson c "$3" '[ range($b; $b+$c) | {number: .,
    node_id: ("I_"+(.|tostring)), html_url: ("https://github.com/o/r/issues/"+(.|tostring)),
    title: ("T"+(.|tostring)), body: "b", state: "open", labels: [],
    user: {login:"operator",type:"User"}, created_at:"2026-09-01T00:00:00Z",
    updated_at:"2026-09-01T00:00:00Z", closed_at:null, assignees:[], milestone:null } ]' >"$1"
}
pulls_page  "$T/fixtures/repos_o_r_issues.p1.json" 1000 100
pulls_page  "$T/fixtures/repos_o_r_issues.p2.json" 2000 100
issues_page "$T/fixtures/repos_o_r_issues.p3.json" 3000 40
GH_SHIM_MAX_PAGES=1 gshim_run issue list -R o/r --state all --limit 50 --json number -q length
eq "issue-list-drop-window-widens rc" "$RC" "0"
eq "issue-list-drop-window-widens rows" "$OUT" "40"
eq "issue-list-drop-window-widens err" "$ERR" ""
# It really did widen rather than luck into one big page: the first ask is the
# limit*2 window, a later one is bigger.
has "issue-list-drop-window-widens first window" "$(gshim_calls)" "per_page=100&page=1"
eq "issue-list-drop-window-widens paged past the plain ceiling" \
  "$(gshim_calls | grep -c 'page=3')" "1"

# ── issue-list-author-window (fix round 1, review Important 2) ───────────────
# --author is the OTHER post-filter on this endpoint, and it had no window guard
# at all: a full window whose rows all belong to someone else answered `[]` with
# rc 0 — "this author has no issues" — where gh answers the 30 that exist.
gshim_reset
rm -f "$T"/fixtures/repos_o_r_issues*.json
jq -nc '[ range(100) | {number: ., node_id: ("I_"+(.|tostring)),
  html_url: ("https://github.com/o/r/issues/"+(.|tostring)), title: ("T"+(.|tostring)),
  body: "b", state: "open", labels: [], created_at:"2026-09-01T00:00:00Z",
  updated_at:"2026-09-01T00:00:00Z", closed_at:null, assignees:[], milestone:null }
  | . + {user: (if .number >= 95 then {login:"operator",type:"User"} else {login:"otherguy",type:"User"} end)} ]' \
  >"$T/fixtures/repos_o_r_issues.p1.json"
jq -nc '[ range(200;240) | {number: ., node_id: ("I_"+(.|tostring)),
  html_url: ("https://github.com/o/r/issues/"+(.|tostring)), title: ("T"+(.|tostring)),
  body: "b", state: "open", labels: [], user: {login:"operator",type:"User"},
  created_at:"2026-09-01T00:00:00Z", updated_at:"2026-09-01T00:00:00Z",
  closed_at:null, assignees:[], milestone:null } ]' \
  >"$T/fixtures/repos_o_r_issues.p2.json"
GH_SHIM_MAX_PAGES=1 gshim_run issue list -R o/r --state all --author operator --limit 30 --json number -q length
eq "issue-list-author-window rc" "$RC" "0"
eq "issue-list-author-window rows" "$OUT" "30"
eq "issue-list-author-window err" "$ERR" ""

# ── issue-list-search-no-overfetch (fix round) ───────────────────────────────
# After state:/label:/author: became qualifiers there is no post-filter on the
# search branch, so the 2x over-fetch only paged the 30-per-minute search
# endpoint twice as often. --limit is the ask now; the REST branch still doubles.
gshim_reset
rm -f "$T"/fixtures/repos_o_r_issues*.json
hit_of_one >"$T/fixtures/search_issues.json"
gshim_run issue list -R o/r --state all --search x --limit 30 --json number
eq "issue-list-search-no-overfetch rc" "$RC" "0"
has "issue-list-search-no-overfetch per_page" "$(gshim_calls)" "per_page=30"
hasnt "issue-list-search-no-overfetch not doubled" "$(gshim_calls)" "per_page=60"
gshim_reset
{ printf '['; issue_row 1; printf ']'; } >"$T/fixtures/repos_o_r_issues.json"
gshim_run issue list -R o/r --state all --limit 30 --json number
has "issue-list-rest-still-overfetches" "$(gshim_calls)" "per_page=60"

# ── issue-list-label-encoded (fix round 1, review Nit 7) ────────────────────
# The REST `labels=` parameter was built by joining the raw flag values, so
# `--label "needs review"` put a literal space in the URL. Each label is encoded
# now and the comma — REST's own AND separator between labels — stays a comma.
gshim_reset
rm -f "$T"/fixtures/repos_o_r_issues*.json
{ printf '['; issue_row 1; printf ']'; } >"$T/fixtures/repos_o_r_issues.json"
gshim_run issue list -R o/r --label 'needs review' --label 'ai-build' --limit 5 --json number
eq "issue-list-label-encoded rc" "$RC" "0"
has "issue-list-label-encoded encoded" "$(gshim_calls)" "labels=needs%20review,ai-build"
hasnt "issue-list-label-encoded no raw space" "$(gshim_calls)" "labels=needs review"
# gh's --label is a string SLICE: `--label a,b` is TWO labels there, and
# gshim_label_q on the search branch already split that way. The REST branch
# splits too, so encoding a whole flag value as one label cannot turn `a,b`
# into a label literally called "a,b" (`a%2Cb`).
gshim_reset
gshim_run issue list -R o/r --label 'a,b' --limit 5 --json number
eq "issue-list-label-comma-split rc" "$RC" "0"
has "issue-list-label-comma-split" "$(gshim_calls)" "labels=a,b"
hasnt "issue-list-label-comma-split not one label" "$(gshim_calls)" "a%2Cb"

echo "gh-shim-issue-read.bh-788: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] || exit 1
exit 0
