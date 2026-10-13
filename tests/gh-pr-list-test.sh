#!/bin/bash
# tests/gh-pr-list-test.sh — bin/lib/gh-pr-list.sh REST path and strict fallback.
# Run from anywhere: tests/gh-pr-list-test.sh   (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
mkdir -p "$T/h/env" "$T/h/logs" "$T/h/state" "$T/h/flags" "$T/h/locks" "$T/h/builds" "$T/fixtures" "$T/fakebin"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }

# REST fixtures
jq -n '[
  {number:1, html_url:"https://github.com/o/repo/pull/1", title:"pat-one",
   head:{sha:"aaa111", ref:"feat-1"}, base:{ref:"main"}, draft:false,
   user:{login:"operator", type:"User"}, created_at:"2026-01-01T00:00:00Z",
   updated_at:"2026-01-02T00:00:00Z", merged_at:null, closed_at:null,
   state:"open", labels:[{name:"bug"}]},
  {number:2, html_url:"https://github.com/o/repo/pull/2", title:"app-two",
   head:{sha:"bbb222", ref:"feat-2"}, base:{ref:"main"}, draft:true,
   user:{login:"cromford[bot]", type:"Bot"}, created_at:"2026-01-03T00:00:00Z",
   updated_at:"2026-01-04T00:00:00Z", merged_at:null, closed_at:null,
   state:"open", labels:[]},
  {number:3, html_url:"https://github.com/o/repo/pull/3", title:"stranger-three",
   head:{sha:"ccc333", ref:"feat-3"}, base:{ref:"main"}, draft:false,
   user:{login:"stranger", type:"User"}, created_at:"2026-01-05T00:00:00Z",
   updated_at:"2026-01-06T00:00:00Z", merged_at:null, closed_at:null,
   state:"open", labels:[]}
]' > "$T/fixtures/repo.json"

jq -n '[
  {number:10, html_url:"https://github.com/o/closed/pull/10", title:"merged-ten",
   head:{sha:"ddd444", ref:"feat-10"}, base:{ref:"main"}, draft:false,
   user:{login:"operator", type:"User"}, created_at:"2026-01-01T00:00:00Z",
   updated_at:"2026-01-01T00:00:00Z", merged_at:"2026-01-02T00:00:00Z",
   closed_at:"2026-01-02T00:00:00Z", state:"closed", labels:[]},
  {number:11, html_url:"https://github.com/o/closed/pull/11", title:"closed-eleven",
   head:{sha:"eee555", ref:"feat-11"}, base:{ref:"main"}, draft:false,
   user:{login:"operator", type:"User"}, created_at:"2026-01-02T00:00:00Z",
   updated_at:"2026-01-02T00:00:00Z", merged_at:null,
   closed_at:"2026-01-03T00:00:00Z", state:"closed", labels:[]}
]' > "$T/fixtures/closed.json"

jq -n '[
  {number:20, html_url:"https://github.com/o/mergedstate/pull/20", title:"merged-twenty",
   head:{sha:"fff666", ref:"feat-20"}, base:{ref:"main"}, draft:false,
   user:{login:"operator", type:"User"}, created_at:"2026-01-01T00:00:00Z",
   updated_at:"2026-01-01T00:00:00Z", merged_at:"2026-01-02T00:00:00Z",
   closed_at:"2026-01-02T00:00:00Z", state:"closed", labels:[]},
  {number:21, html_url:"https://github.com/o/mergedstate/pull/21", title:"unmerged-twentyone",
   head:{sha:"ggg777", ref:"feat-21"}, base:{ref:"main"}, draft:false,
   user:{login:"operator", type:"User"}, created_at:"2026-01-02T00:00:00Z",
   updated_at:"2026-01-02T00:00:00Z", merged_at:null,
   closed_at:"2026-01-03T00:00:00Z", state:"closed", labels:[]}
]' > "$T/fixtures/mergedstate.json"

jq -n '[range(101;201) | {number:., html_url:"https://github.com/o/nonmatch/pull/\(.)", title:"stranger-\(.)",
   head:{sha:"sha\(.)", ref:"branch\(.)"}, base:{ref:"main"}, draft:false,
   user:{login:"stranger", type:"User"}, created_at:"2026-01-01T00:00:00Z",
   updated_at:"2026-01-01T00:00:00Z", merged_at:null, closed_at:null,
   state:"open", labels:[]}]' > "$T/fixtures/nonmatch.json"

# gh shim: records every call; answers REST pulls and per-author pr list.
cat > "$T/fakebin/gh" <<'GH'
#!/bin/bash
printf '%s\n' "$*" >> "$GH_CALLS"
case "$1" in
  api)
    # TEST-CHANGE (BH-782): the library reads REST through bin/lib/gh-rest.sh
    # now, which runs `gh api -i` and parses the STATUS LINE. So the shim peels
    # the flags to find the path and answers status line + blank line + body —
    # same fixtures, in the shape the library now reads. `o/notfound` became a
    # real 404 and `o/bad` a real empty 200 rather than bodies that merely
    # looked like failures, because the status is what is classified.
    shift
    P=""
    while [ $# -gt 0 ]; do
      case "$1" in
        -i) shift ;;
        -X|-f|-F|-H) shift 2 ;;
        -*) shift ;;
        *) P="$1"; shift; break ;;
      esac
    done
    ST=200; BODY=""
    case "$P" in
      repos/o/repo/pulls*)        BODY=$(cat "$T/fixtures/repo.json") ;;
      repos/o/closed/pulls*)      BODY=$(cat "$T/fixtures/closed.json") ;;
      repos/o/mergedstate/pulls*) BODY=$(cat "$T/fixtures/mergedstate.json") ;;
      repos/o/nonmatch/pulls*)
        p=$(echo "$P" | sed -n 's/.*page=\([0-9]*\).*/\1/p')
        case "${p:-1}" in
          1|2|3) BODY=$(cat "$T/fixtures/nonmatch.json") ;;
          *) BODY="PAGE_FOUR_WAS_REQUESTED" ;;
        esac
        ;;
      repos/o/notfound/pulls*)    ST=404; BODY='{"message":"Not Found"}' ;;
      repos/o/bad/pulls*)         BODY="" ;;
      repos/o/nonarray/pulls*)    BODY='{"message":"something that is not a list"}' ;;
      repos/o/empty/pulls*)       BODY='[]' ;;
      *) exit 1 ;;
    esac
    printf 'HTTP/2.0 %s\r\n' "$ST"
    printf '\r\n'
    [ -n "$BODY" ] && printf '%s\n' "$BODY"
    case "$ST" in 2*) exit 0 ;; *) exit 1 ;; esac
    ;;
  pr)
    A=""; R=""; L=""; F=""
    while [ $# -gt 0 ]; do
      case "$1" in
        -R) R="$2"; shift 2 ;;
        --author) A="$2"; shift 2 ;;
        --limit) L="$2"; shift 2 ;;
        --json) F="$2"; shift 2 ;;
        *) shift ;;
      esac
    done
    printf '%s %s %s %s\n' "$R" "$A" "$L" "$F" >> "$GH_FALLBACK_CALLS"
    case "$R/$A" in
      o/repo/operator)             echo '[{"number":1,"title":"pat-one","mergeStateStatus":"CLEAN"},{"number":2,"title":"both","mergeStateStatus":"CLEAN"}]' ;;
      o/repo/app/cromford)  echo '[{"number":2,"title":"both","mergeStateStatus":"DIRTY"},{"number":3,"title":"app-three","mergeStateStatus":"CLEAN"}]' ;;
      o/notfound/operator)         echo '[{"number":1,"title":"fallback-one"}]' ;;
      o/notfound/app/cromford) echo '[{"number":2,"title":"fallback-two"}]' ;;
      o/bad/operator)              echo '[{"number":1,"title":"fallback-bad-one"}]' ;;
      o/bad/app/cromford)   echo '[{"number":2,"title":"fallback-bad-two"}]' ;;
      *) exit 1 ;;
    esac
    ;;
  *) exit 1 ;;
esac
GH
chmod +x "$T/fakebin/gh"

drive() {
  ( export T="$T" PATH="$T/fakebin:$PATH" HARNESS="$T/h" GH_CALLS="$T/gh-calls.txt" GH_FALLBACK_CALLS="$T/fallback-calls.txt"
    unset HARNESS_PR_AUTHORS GH_PR_LIST_REST_PAGES
    # shellcheck source=/dev/null
    . "$DIR/bin/lib/gh-pr-list.sh"; eval "$1" )
}

# 1. REST happy path: two harness rows in REST order, only requested keys, mappings correct.
: > "$T/gh-calls.txt"
OUT=$(drive 'harness_pr_list o/repo open number,url,title,headRefOid,state,author')
[ "$(jq -c '[.[].number]' <<<"$OUT")" = "[1,2]" ] && ok || bad "happy path numbers: $OUT"
[ "$(jq 'length' <<<"$OUT")" = 2 ] && ok || bad "happy path count"
[ "$(jq -r '.[0].author.login' <<<"$OUT")" = "operator" ] && ok || bad "first author login"
[ "$(jq -r '.[0].author.is_bot' <<<"$OUT")" = "false" ] && ok || bad "first author is_bot"
[ "$(jq -r '.[1].author.login' <<<"$OUT")" = "cromford[bot]" ] && ok || bad "bot author login"
[ "$(jq -r '.[1].author.is_bot' <<<"$OUT")" = "true" ] && ok || bad "bot author is_bot"
[ "$(jq -r '.[1].headRefOid' <<<"$OUT")" = "bbb222" ] && ok || bad "headRefOid mapping"
[ "$(jq -r '.[0].state' <<<"$OUT")" = "OPEN" ] && ok || bad "state uppercase"
[ "$(jq -r '.[0].url' <<<"$OUT")" = "https://github.com/o/repo/pull/1" ] && ok || bad "url mapping"
[ "$(jq -c '.[0] | keys_unsorted' <<<"$OUT")" = '["number","url","title","headRefOid","state","author"]' ] && ok || bad "only requested keys: $(jq -c '.[0] | keys_unsorted' <<<"$OUT")"
[ "$(grep -c 'repos/o/repo/pulls' "$T/gh-calls.txt")" = 1 ] && ok || bad "happy path should issue one REST call: $(cat "$T/gh-calls.txt")"

# 2. Unmappable field falls back to one pr list per author, no REST call.
# TEST-CHANGE (BH-1585): mergeStateStatus is a lazy REST field now, so a field
# no read carries (potentialMergeCommit) drives this section, and the
# fallback it exercises is opt-in (GH_PR_LIST_GRAPHQL_FALLBACK=1). The default,
# refused with no call at all, is pinned first. The assertions below it are
# unchanged: the fake answers the same rows whatever --json asked for.
: > "$T/gh-calls.txt"
OUT=$(drive 'harness_pr_list o/repo open number,title,potentialMergeCommit; echo "rc=$?"')
[ "$OUT" = "rc=75" ] && [ ! -s "$T/gh-calls.txt" ] && ok || bad "fallback off (default): an unmappable field must be refused 75 with no call (out: $OUT, calls: $(cat "$T/gh-calls.txt"))"
: > "$T/gh-calls.txt"
OUT=$(drive 'GH_PR_LIST_GRAPHQL_FALLBACK=1 harness_pr_list o/repo open number,title,potentialMergeCommit')
[ "$(jq -c '[.[].number]' <<<"$OUT")" = "[1,2,3]" ] && ok || bad "fallback union numbers: $OUT"
[ "$(jq -c 'map(.mergeStateStatus)' <<<"$OUT")" = '["CLEAN","CLEAN","CLEAN"]' ] && ok || bad "fallback field preserved: $(jq -c 'map(.mergeStateStatus)' <<<"$OUT")"
! grep -q 'api -i' "$T/gh-calls.txt" && ok || bad "fallback should not call REST"
# TEST-CHANGE (BH-1668): "once per author" is counted against the author set
# itself rather than the literal 2 it had when the set was two logins; the
# builders App made it three. Same assertion, no longer pinned to the default.
NAUTH=$(drive 'harness_pr_authors' | wc -w | tr -d ' ')
[ "$(grep -c 'pr list' "$T/gh-calls.txt")" = "$NAUTH" ] && ok || bad "fallback should call once per author ($NAUTH) (got $(grep -c 'pr list' "$T/gh-calls.txt"))"

# 3. An unreadable REST answer is CLASSIFIED and RETURNED — never retried over
#    GraphQL.
#
# TEST-CHANGE (BH-782, the #768 incident). These two cases asserted the exact
# behaviour this ticket removes: a failed REST page fell back to `gh pr list`,
# the very call #768 caught exiting 0 and printing nothing under a rate limit,
# and the caller got rc 0 with a list. The fixtures are unchanged; the
# assertions are INVERTED on purpose, because the old ones pinned the bug.
# 3a. Not Found -> rc 44, and no GraphQL retry.
: > "$T/h/logs/gh-pr-list.log"
: > "$T/gh-calls.txt"
RC=0
OUT=$(drive 'harness_pr_list o/notfound open number,title') || RC=$?
[ "$RC" = 44 ] && [ -z "$OUT" ] && ok || bad "Not Found must be rc 44 with no output: rc=$RC out=$OUT"
grep -q "REST list unavailable" "$T/h/logs/gh-pr-list.log" && ok || bad "Not Found reason not logged"
grep -q 'api -i' "$T/gh-calls.txt" && ok || bad "Not Found should have tried REST"
! grep -q 'pr list' "$T/gh-calls.txt" && ok || bad "Not Found must NOT be retried over gh pr list"
# 3b. Empty body on a 2xx -> rc 75, and no GraphQL retry.
: > "$T/h/logs/gh-pr-list.log"
: > "$T/gh-calls.txt"
RC=0
OUT=$(drive 'harness_pr_list o/bad open number,title') || RC=$?
[ "$RC" = 75 ] && [ -z "$OUT" ] && ok || bad "an empty 2xx body must be rc 75 with no output: rc=$RC out=$OUT"
! grep -q 'pr list' "$T/gh-calls.txt" && ok || bad "an empty body must NOT be retried over gh pr list"
# 3c. A 2xx whose body is not an array -> rc 75, logged, no retry.
: > "$T/h/logs/gh-pr-list.log"
: > "$T/gh-calls.txt"
RC=0
OUT=$(drive 'harness_pr_list o/nonarray open number,title') || RC=$?
[ "$RC" = 75 ] && ok || bad "a non-array 2xx body must be rc 75: rc=$RC out=$OUT"
grep -q "REST list unavailable" "$T/h/logs/gh-pr-list.log" && ok || bad "non-array reason not logged"
! grep -q 'pr list' "$T/gh-calls.txt" && ok || bad "a non-array body must NOT be retried over gh pr list"

# 4. REST [] is a real answer, not a fallback.
: > "$T/gh-calls.txt"
OUT=$(drive 'harness_pr_list o/empty open number,title'); RC=$?
[ "$RC" = 0 ] && [ "$(jq -c . <<<"$OUT")" = "[]" ] && ok || bad "empty array should be [] rc 0: rc=$RC out=$OUT"
! grep -q 'pr list' "$T/gh-calls.txt" && ok || bad "empty array should not fall back"

# 5. Page cap: 100 non-matching rows walk pages, stop at 3, log cap, never request page 4.
: > "$T/h/logs/gh-pr-list.log"
: > "$T/gh-calls.txt"
OUT=$(drive 'harness_pr_list o/nonmatch open number,title')
[ "$(jq 'length' <<<"$OUT")" = 0 ] && ok || bad "nonmatch should return 0 rows"
[ "$(grep -c 'repos/o/nonmatch/pulls' "$T/gh-calls.txt")" = 3 ] && ok || bad "default should request exactly 3 pages (got $(grep -c 'repos/o/nonmatch/pulls' "$T/gh-calls.txt"))"
! grep -q 'page=4' "$T/gh-calls.txt" && ok || bad "page 4 should not be requested"
! grep -q 'PAGE_FOUR_WAS_REQUESTED' "$T/gh-calls.txt" && ok || bad "page 4 was sent to shim"
grep -q "REST page cap reached" "$T/h/logs/gh-pr-list.log" && ok || bad "cap not logged"

# 6. GH_PR_LIST_REST_PAGES=1 requests exactly one page.
: > "$T/gh-calls.txt"
OUT=$(drive 'GH_PR_LIST_REST_PAGES=1 harness_pr_list o/nonmatch open number,title')
[ "$(grep -c 'repos/o/nonmatch/pulls' "$T/gh-calls.txt")" = 1 ] && ok || bad "PAGES=1 should request exactly 1 page"
! grep -q 'page=2' "$T/gh-calls.txt" && ok || bad "page 2 requested with PAGES=1"

# 7. Closed rows carry mergedAt/closedAt and correct state.
: > "$T/gh-calls.txt"
OUT=$(drive 'harness_pr_list o/closed closed number,mergedAt,closedAt,state')
[ "$(jq -c '[.[].number]' <<<"$OUT")" = "[10,11]" ] && ok || bad "closed numbers: $OUT"
[ "$(jq -r '.[0].mergedAt' <<<"$OUT")" = "2026-01-02T00:00:00Z" ] && ok || bad "mergedAt present"
[ "$(jq -r '.[0].state' <<<"$OUT")" = "MERGED" ] && ok || bad "merged state"
[ "$(jq -r '.[1].mergedAt' <<<"$OUT")" = "null" ] && ok || bad "unmerged mergedAt null"
[ "$(jq -r '.[1].state' <<<"$OUT")" = "CLOSED" ] && ok || bad "unmerged state CLOSED"

# 8. state=merged maps to closed+merged_at filter.
: > "$T/gh-calls.txt"
OUT=$(drive 'harness_pr_list o/mergedstate merged number,state,mergedAt')
[ "$(jq -c '[.[].number]' <<<"$OUT")" = "[20]" ] && ok || bad "merged state numbers: $OUT"
[ "$(jq -r '.[0].state' <<<"$OUT")" = "MERGED" ] && ok || bad "merged filter state"
grep -q 'state=closed' "$T/gh-calls.txt" && ok || bad "merged should query closed"

# 9. HARNESS_PR_AUTHORS with three authors still issues one REST call; fallback issues three.
: > "$T/gh-calls.txt"
OUT=$(drive 'HARNESS_PR_AUTHORS="operator app/cromford foo" harness_pr_list o/repo open number,title')
[ "$(grep -c 'repos/o/repo/pulls' "$T/gh-calls.txt")" = 1 ] && ok || bad "three authors REST should be one call (got $(grep -c 'repos/o/repo/pulls' "$T/gh-calls.txt"))"
: > "$T/gh-calls.txt"
# TEST-CHANGE (BH-1585): an uncarried field + the opt-in fallback, as in section 2.
OUT=$(drive 'HARNESS_PR_AUTHORS="operator app/cromford foo" GH_PR_LIST_GRAPHQL_FALLBACK=1 harness_pr_list o/repo open number,title,potentialMergeCommit')
[ "$(grep -c 'pr list' "$T/gh-calls.txt")" = 3 ] && ok || bad "three authors fallback should call three times (got $(grep -c 'pr list' "$T/gh-calls.txt"))"

# 10. Mutation check: removing the array guard stops a 2xx non-array body being
#     CLASSIFIED. TEST-CHANGE (BH-782): the fixture moved from o/bad to
#     o/nonarray, because an empty 2xx body is now answered 75 by the contract
#     library BEFORE the array guard is reached — so o/bad no longer exercises
#     the guard at all and the old assertion would have stayed green on a
#     deleted guard. The claim is sharper too: unmutated is rc 75 (a classified
#     unknown), mutated is anything else.
# The mutant lives in a lib DIRECTORY with gh-rest.sh beside it: the library
# resolves the contract from its own directory first, and a mutant on its own
# would answer 75 "no contract lib on this box" before the guard was reached —
# a mutation test that never ran the mutated line.
mkdir -p "$T/mutlib"
cp "$DIR/bin/lib/gh-rest.sh" "$DIR/bin/lib/gh-rest-var.sh" "$T/mutlib/"
cp "$DIR/bin/lib/gh-pr-list.sh" "$T/mutlib/gh-pr-list.sh"
sed -i '/REST-ARRAY-GUARD/s/if ! jq -e .*/if false; then # MUTATED: removed array guard/' "$T/mutlib/gh-pr-list.sh"
grep -q 'MUTATED: removed array guard' "$T/mutlib/gh-pr-list.sh" \
  && ok || bad "mutation check: the REST-ARRAY-GUARD line no longer matches — the mutation was not applied"
drive_mutated() {
  ( export T="$T" PATH="$T/fakebin:$PATH" HARNESS="$T/h" GH_CALLS="$T/gh-calls.txt"
    unset HARNESS_PR_AUTHORS GH_PR_LIST_REST_PAGES
    # shellcheck source=/dev/null
    . "$T/mutlib/gh-pr-list.sh"; eval "$1" )
}
: > "$T/gh-calls.txt"
RC=0
OUT=$(drive_mutated 'harness_pr_list o/nonarray open number,title') || RC=$?
[ "$RC" != 75 ] && ok || bad "mutation check: removing the array guard must stop the 75 classification (rc=$RC out=$OUT)"

echo "gh-pr-list: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
