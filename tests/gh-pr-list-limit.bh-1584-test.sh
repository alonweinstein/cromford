#!/bin/bash
# tests/gh-pr-list-limit.bh-1584-test.sh — harness_pr_list's REST path stops
# paging once it holds `limit` PRs, always asks for full pages (per_page=100),
# and lists closed/merged/all by sort=updated.
#
# THE WASTE THIS PINS (gh-reads audit, 2026-09-23). The REST walk ignored the
# limit it was handed: it paged until a SHORT page or the page cap, then cut the
# answer to `limit` at the end. merge-conductor asks for 30 closed PRs every
# tick and got three full pages of 100 read for them — about 500 of the
# conductor's 640 GET R/pulls an hour. It also listed closed PRs by
# sort=created, so an old PR that closed a minute ago sat below 30 younger ones
# and the closed-unmerged settle never saw it.
#
# FULL PAGES, ALWAYS (#1591 review). The author filter runs on EVERY REST row,
# so a page of `limit` rows almost never holds `limit` of ours. per_page=30
# turned project-9 (11 of ours in 300 closed) from 3 requests into 10 and
# saved nothing on repos where partner authors half the PRs — fleet net ~27 vs
# ~27. With per_page=100 a walk needs ceil(pos/100) <= ceil(pos/30) requests
# and never more than main's. Scan depth stays GH_PR_LIST_REST_PAGES x 100.
# A10/A11 pin "never more requests than main" at realistic author densities.
#
# Run from anywhere: tests/gh-pr-list-limit.bh-1584-test.sh  (exit 0 = pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
mkdir -p "$T/h/env" "$T/h/logs" "$T/fakebin"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }

# gh shim: a synthetic repo of N rows, newest first. It honours per_page and
# page exactly as GitHub does (rows (page-1)*pp .. page*pp-1), records every
# request path, and says who authored each row per the repo's shape:
#   o/big     1000 rows, all ours
#   o/few       45 rows, all ours
#   o/sparse  1000 rows, ours only at index 200..259
#   o/deep    1000 rows, ours only at index >= 300 (beyond the scan budget)
#   o/third   1000 rows, one in three ours (project-1/project-2-like density)
#   o/eleven  1000 rows, 11 of the first 300 ours, none after (project-9-like)
cat > "$T/fakebin/gh" <<'GH'
#!/bin/bash
[ "$1" = api ] || exit 1
shift; P=""
while [ $# -gt 0 ]; do
  case "$1" in
    -i) shift ;;
    -X|-f|-F|-H) shift 2 ;;
    -*) shift ;;
    *) P="$1"; shift; break ;;
  esac
done
printf '%s\n' "$P" >> "$GH_CALLS"
q="${P#*\?}"; repo="${P%%/pulls*}"; repo="${repo#repos/}"
pp=$(printf '%s' "$q" | tr '&' '\n' | sed -n 's/^per_page=//p'); pp="${pp:-30}"
pg=$(printf '%s' "$q" | tr '&' '\n' | sed -n 's/^page=//p'); pg="${pg:-1}"
case "$repo" in
  o/big)    N=1000; OURS='true' ;;
  o/few)    N=45;   OURS='true' ;;
  o/sparse) N=1000; OURS='($i >= 200 and $i < 260)' ;;
  o/deep)   N=1000; OURS='($i >= 300)' ;;
  o/third)  N=1000; OURS='($i % 3 == 0)' ;;
  o/eleven) N=1000; OURS='($i < 300 and $i % 28 == 0)' ;;
  *) printf 'HTTP/2.0 404\r\n\r\n{"message":"Not Found"}\n'; exit 1 ;;
esac
lo=$(( (pg - 1) * pp )); hi=$(( pg * pp )); [ "$hi" -gt "$N" ] && hi=$N
printf 'HTTP/2.0 200\r\n\r\n'
jq -nc --argjson lo "$lo" --argjson hi "$hi" "[range(\$lo; \$hi) as \$i | {
  number: (5000 - \$i), html_url: \"https://github.com/$repo/pull/\(5000 - \$i)\",
  title: \"row-\(\$i)\", head: {sha: \"s\(\$i)\", ref: \"b\(\$i)\"}, base: {ref: \"main\"},
  draft: false, user: {login: (if $OURS then \"operator\" else \"stranger\" end), type: \"User\"},
  created_at: \"2026-01-01T00:00:00Z\", updated_at: \"2026-01-01T00:00:00Z\",
  merged_at: \"2026-01-02T00:00:00Z\", closed_at: \"2026-01-02T00:00:00Z\",
  state: \"closed\", labels: []}]"
GH
chmod +x "$T/fakebin/gh"

drive() {
  ( export T="$T" PATH="$T/fakebin:$PATH" HARNESS="$T/h" GH_CALLS="$T/calls.txt"
    unset HARNESS_PR_AUTHORS GH_PR_LIST_REST_PAGES
    # shellcheck source=/dev/null
    . "$DIR/bin/lib/gh-pr-list.sh"; eval "$1" )
}
calls()  { grep -c 'pulls' "$T/calls.txt" 2>/dev/null || true; }
qparam() { tr '&?' '\n\n' < "$T/calls.txt" | sed -n "s/^$1=//p" | sort -u | paste -sd, -; }

# A1. THE ISSUE'S CASE: limit=30 closed -> exactly one request, per_page=100,
#     sort=updated&direction=desc, and 30 rows back.
: > "$T/calls.txt"
OUT=$(drive 'harness_pr_list o/big closed number,url,headRefName,mergedAt,closedAt,state 30'); RC=$?
[ "$RC" = 0 ] && ok || bad "A1 rc=$RC"
[ "$(calls)" = 1 ] && ok || bad "A1 limit=30 must make exactly 1 request, made $(calls): $(cat "$T/calls.txt")"
[ "$(qparam per_page)" = 100 ] && ok || bad "A1 per_page must be 100 (full pages under the author filter), got '$(qparam per_page)'"
[ "$(qparam sort)" = updated ] && ok || bad "A1 closed list must sort=updated, got '$(qparam sort)'"
[ "$(qparam direction)" = desc ] && ok || bad "A1 direction must be desc, got '$(qparam direction)'"
[ "$(jq length <<<"$OUT")" = 30 ] && ok || bad "A1 must return 30 rows, got $(jq length <<<"$OUT")"

# A2. limit=250 -> per_page=100, three requests, 250 rows, stops.
: > "$T/calls.txt"
OUT=$(drive 'harness_pr_list o/big closed number,state 250')
[ "$(calls)" = 3 ] && ok || bad "A2 limit=250 must make 3 requests, made $(calls)"
[ "$(qparam per_page)" = 100 ] && ok || bad "A2 per_page must be 100, got '$(qparam per_page)'"
[ "$(jq length <<<"$OUT")" = 250 ] && ok || bad "A2 must return 250 rows"

# A3. It stops at the LIMIT, not at the page cap: with room for ten pages a
#     limit=250 walk still makes three requests and never asks for page 4.
: > "$T/calls.txt"
OUT=$(drive 'GH_PR_LIST_REST_PAGES=10 harness_pr_list o/big closed number 250')
[ "$(calls)" = 3 ] && ok || bad "A3 limit=250 with PAGES=10 must stop after 3 requests, made $(calls)"
! grep -q 'page=4' "$T/calls.txt" && ok || bad "A3 page 4 requested after the limit was met"
[ "$(jq length <<<"$OUT")" = 250 ] && ok || bad "A3 must return 250 rows"

# A4. The default limit (100) on an open list of 1000: one request, not three.
#     Open lists keep sort=created — the issue moves closed/all only.
: > "$T/calls.txt"
OUT=$(drive 'harness_pr_list o/big open number')
[ "$(calls)" = 1 ] && ok || bad "A4 default-limit open list must make 1 request, made $(calls)"
[ "$(qparam sort)" = created ] && ok || bad "A4 open list must keep sort=created, got '$(qparam sort)'"
[ "$(jq length <<<"$OUT")" = 100 ] && ok || bad "A4 must return 100 rows"

# A5. merged and all are closed-side lists: sort=updated.
: > "$T/calls.txt"
drive 'harness_pr_list o/big merged number 10' >/dev/null
[ "$(qparam sort)" = updated ] && ok || bad "A5 merged list must sort=updated, got '$(qparam sort)'"
[ "$(qparam state)" = closed ] && ok || bad "A5 merged must still ask REST for state=closed"
: > "$T/calls.txt"
drive 'harness_pr_list o/big all number 10' >/dev/null
[ "$(qparam sort)" = updated ] && ok || bad "A5 all list must sort=updated, got '$(qparam sort)'"

# A6. A short page still ends the walk: 45 rows, limit=100 -> one request.
: > "$T/calls.txt"
OUT=$(drive 'harness_pr_list o/few closed number 100')
[ "$(calls)" = 1 ] && ok || bad "A6 a short page must end the walk, made $(calls)"
[ "$(jq length <<<"$OUT")" = 45 ] && ok || bad "A6 must return all 45 rows"

# A7. SCAN DEPTH UNCHANGED. Ours sit at rows 200..259: the old walk (3 x 100)
#     found the first 30 of them, so the new one must too — in the same three
#     requests, never more.
: > "$T/calls.txt"
OUT=$(drive 'harness_pr_list o/sparse closed number 30')
WANT=$(jq -c '[range(200;230) | 5000 - .]' <<<null)
[ "$(jq -c '[.[].number]' <<<"$OUT")" = "$WANT" ] && ok || bad "A7 sparse limit=30 must return rows 200..229 as before, got $(jq -c '[.[].number]' <<<"$OUT")"
[ "$(calls)" = 3 ] && ok || bad "A7 must take main's 3 requests (3 x 100 rows), made $(calls)"

# A8. ...and never deeper than the old walk could look: ours only past row 300
#     is [] rc 0, the cap is logged, no row past 299 is requested.
: > "$T/calls.txt"; : > "$T/h/logs/gh-pr-list.log"
OUT=$(drive 'harness_pr_list o/deep closed number 30'); RC=$?
[ "$RC" = 0 ] && [ "$(jq -c . <<<"$OUT")" = "[]" ] && ok || bad "A8 deep must be [] rc 0: rc=$RC out=$OUT"
[ "$(calls)" = 3 ] && ok || bad "A8 must scan 300 rows in main's 3 requests, made $(calls)"
! grep -q 'page=4' "$T/calls.txt" && ok || bad "A8 read past the 300-row scan budget"
grep -q 'REST page cap reached' "$T/h/logs/gh-pr-list.log" && ok || bad "A8 cap not logged"

# A9. A limit that is not a positive integer is refused before any request.
for L in abc 0 -5; do
  : > "$T/calls.txt"
  RC=0; OUT=$(drive "harness_pr_list o/big closed number $L") || RC=$?
  [ "$RC" != 0 ] && [ -z "$OUT" ] && ok || bad "A9 limit=$L must fail with no output: rc=$RC out=$OUT"
  [ "$(calls)" = 0 ] && ok || bad "A9 limit=$L must make no request, made $(calls)"
done

# A10. REALISTIC DENSITY (#1591 review): one row in three ours, limit=30.
#     main made 3 requests (it paged to the cap on any repo of 300+ closed);
#     the walk must make no more than that — and at full pages, exactly one.
MAIN_REQS=3
: > "$T/calls.txt"
OUT=$(drive 'harness_pr_list o/third closed number 30')
[ "$(calls)" -le "$MAIN_REQS" ] && ok || bad "A10 1-in-3 density must make <= main's $MAIN_REQS requests, made $(calls)"
[ "$(calls)" = 1 ] && ok || bad "A10 1-in-3 density: 33 of ours in the first 100 rows must end the walk on request 1, made $(calls)"
[ "$(jq length <<<"$OUT")" = 30 ] && ok || bad "A10 must return 30 rows, got $(jq length <<<"$OUT")"

# A11. SPARSE (project-9: 11 of ours in 300 closed): the walk never fills the
#      limit and runs to the cap — which must cost no more than main's 3.
: > "$T/calls.txt"
OUT=$(drive 'harness_pr_list o/eleven closed number 30')
[ "$(calls)" -le "$MAIN_REQS" ] && ok || bad "A11 sparse (11/300) must make <= main's $MAIN_REQS requests, made $(calls)"
[ "$(jq length <<<"$OUT")" = 11 ] && ok || bad "A11 must return all 11 of ours, got $(jq length <<<"$OUT")"

echo "gh-pr-list-limit: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
