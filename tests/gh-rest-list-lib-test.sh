#!/bin/bash
# tests/gh-rest-list-lib-test.sh — bin/lib/gh-rest-list.sh on its own: paging,
# the `.pull_request` filter, the row cap, and what a bad page does to the
# whole read.
#
# WHY THIS SUITE EXISTS (BH-1163). The lanes that reconcile a board replaced a
# `gh … list --limit 200` with these readers. Two things can go wrong quietly:
# a second page that never gets fetched halves the board and every ticket past
# row 100 reads as "not there", and a page that answers 429 gets stitched onto
# the rows already collected and half a board is returned AS the board. Both
# look like a smaller board, neither raises anything, and both are the #768
# shape — silence read as fact. So every row here asserts the rc AND what
# reached stdout, and the mutation block at the end proves the assertions
# actually catch each failure rather than passing on a library that is wrong.
#
# Nothing here touches the network: `gh` is a stub on PATH that replays queued
# fixture responses and records its own argv.
#
# Run from anywhere: bash tests/gh-rest-list-lib-test.sh   (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
LIB="$DIR/bin/lib/gh-rest-list.sh"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }

export HARNESS="$T/h"
mkdir -p "$T/h/logs" "$T/tmp" "$T/bin" "$T/fx" "$T/mut"
export TMPDIR="$T/tmp"
export PATH="$T/bin:$PATH"
export GH_STUB_DIR="$T"

# ── the stub `gh` ────────────────────────────────────────────────────────────
# Replays the lowest-numbered queued fixture and records every argv line, so a
# row can assert WHICH pages were asked for as well as what came back. No
# fixture queued = exit 1 with nothing on stdout, which is what a killed or
# missing `gh` looks like to the library.
cat > "$T/bin/gh" <<'STUB'
#!/bin/bash
D="$GH_STUB_DIR"
printf '%s\n' "$*" >> "$D/gh-calls.txt"
f=$(find "$D/fx" -maxdepth 1 -type f -name '[0-9][0-9]' 2>/dev/null | sort | head -1)
[ -n "$f" ] || exit 1
cat "$f"
rm -f "$f"
exit 0
STUB
chmod +x "$T/bin/gh"

FXN=0
fx() {  # fx <status> <body>
  FXN=$((FXN+1))
  printf 'HTTP/2 %s\r\nserver: x\r\n\r\n%s' "$1" "$2" > "$(printf '%s/fx/%02d' "$T" "$FXN")"
}
reset() { rm -f "$T"/fx/* "$T/gh-calls.txt" "$T/out" 2>/dev/null; FXN=0; : > "$T/gh-calls.txt"; }
# A page of N issue objects numbered from <first>. `kind=pr` marks every row as
# a pull request, which is what GET /issues actually returns for them.
page() { # page <n> <first> [pr]
  jq -nc --argjson n "$1" --argjson f "$2" --arg pr "${3:-}" \
    '[range($n) | {number: (. + $f), title: ("t" + (.+$f|tostring)), body: ""}
      | if $pr == "pr" then . + {pull_request:{url:"u"}} else . end]'
}
rows() { jq -r 'length' "$T/out" 2>/dev/null || echo "-"; }
nums() { jq -rc '[.[].number]' "$T/out" 2>/dev/null || echo "-"; }
pages_asked() { grep -c 'page=' "$T/gh-calls.txt" 2>/dev/null || echo 0; }

# shellcheck source=bin/lib/gh-rest-list.sh
. "$LIB" || { echo "cannot source $LIB"; exit 2; }

# ══ 1. one short page is one request ════════════════════════════════════════
# The common case, and the one that must not cost a second round trip: a page
# shorter than per_page is the end of the list by definition.
reset
fx 200 "$(page 3 1)"
RC=0; gh_rest_issue_list o/r open ai-build 200 > "$T/out" || RC=$?
[ "$RC" = 0 ] && ok || bad "1: a single short page must be rc 0, got $RC"
[ "$(rows)" = 3 ] && ok || bad "1: three rows must come back, got $(rows)"
[ "$(pages_asked)" = 1 ] && ok || bad "1: a short page must not be followed by a second request, asked $(pages_asked)"
grep -q 'per_page=100' "$T/gh-calls.txt" && ok || bad "1: the read must ask for per_page=100: $(cat "$T/gh-calls.txt")"
grep -q 'labels=ai-build' "$T/gh-calls.txt" && ok || bad "1: the label must reach the query: $(cat "$T/gh-calls.txt")"
grep -q 'state=open' "$T/gh-calls.txt" && ok || bad "1: the state must reach the query: $(cat "$T/gh-calls.txt")"

# ══ 2. a full page is followed, and the rows are concatenated in order ══════
# `--limit 200` was the CLI's cap and REST's per_page stops at 100, so a board
# of 120 open tickets is TWO requests or it is not the board.
reset
fx 200 "$(page 100 1)"
fx 200 "$(page 20 101)"
RC=0; gh_rest_issue_list o/r open ai-build 200 > "$T/out" || RC=$?
[ "$RC" = 0 ] && ok || bad "2: a two-page read must be rc 0, got $RC"
[ "$(rows)" = 120 ] && ok || bad "2: both pages must land, got $(rows) rows"
[ "$(jq -r '.[0].number, .[119].number' "$T/out" | tr '\n' ' ')" = "1 120 " ] && ok \
  || bad "2: the pages must concatenate in order, got $(jq -r '.[0].number, .[-1].number' "$T/out" | tr '\n' ' ')"
[ "$(pages_asked)" = 2 ] && ok || bad "2: exactly two pages must be asked for, asked $(pages_asked)"
grep -q 'page=2' "$T/gh-calls.txt" && ok || bad "2: the second request must name page=2: $(cat "$T/gh-calls.txt")"

# ══ 3. a bad page poisons the WHOLE read, it never trims it ════════════════
# This is the row the incident is about. Returning page 1 when page 2 answered
# 429 hands the caller a smaller board with rc 0 — indistinguishable from a
# board that really is smaller, and the caller then acts on tickets it thinks
# nobody owns.
reset
fx 200 "$(page 100 1)"
fx 429 '{"message":"API rate limit exceeded for installation."}'
RC=0; gh_rest_issue_list o/r open ai-build 200 > "$T/out" || RC=$?
[ "$RC" = 75 ] && ok || bad "3: a rate-limited second page must make the whole read 75, got $RC"
[ ! -s "$T/out" ] && ok || bad "3: nothing may reach stdout on a declined read, got $(cat "$T/out")"
[ "$GH_REST_STATUS" = 429 ] && ok || bad "3: the caller must still see the status, got $GH_REST_STATUS"
[ "$GH_REST_REASON" = rate-limit ] && ok || bad "3: the caller must still see the reason, got '$GH_REST_REASON'"
# …and a 404 on the first page is ABSENT, which is a different sentence
reset
fx 404 '{"message":"Not Found"}'
RC=0; gh_rest_issue_list o/r open ai-build 200 > "$T/out" || RC=$?
[ "$RC" = 44 ] && ok || bad "3: a 404 must be 44, not 75, got $RC"
[ ! -s "$T/out" ] && ok || bad "3: a 404 must print nothing, got $(cat "$T/out")"
# …and a dead `gh` is 75 with no partial answer
reset
RC=0; gh_rest_issue_list o/r open ai-build 200 > "$T/out" || RC=$?
[ "$RC" = 75 ] && ok || bad "3: a dead gh must be 75, got $RC"

# ══ 4. an empty list is a FACT, not an unknown ═════════════════════════════
# gh-rest.sh's own rule, and the one this file could most easily break: `[]`
# under a 200 is a board with nothing on it.
reset
fx 200 '[]'
RC=0; gh_rest_issue_list o/r open ai-build 200 > "$T/out" || RC=$?
[ "$RC" = 0 ] && ok || bad "4: an empty list must be rc 0, got $RC"
[ "$(cat "$T/out")" = "[]" ] && ok || bad "4: an empty list must come back as [], got '$(cat "$T/out")'"

# ══ 5. a 2xx body that is not a list is nobody's empty board ═══════════════
reset
fx 200 '{"message":"Moved"}'
RC=0; gh_rest_issue_list o/r open ai-build 200 > "$T/out" || RC=$?
[ "$RC" = 75 ] && ok || bad "5: a 2xx object where a list belongs must be 75, got $RC"
[ ! -s "$T/out" ] && ok || bad "5: …and must print nothing, got $(cat "$T/out")"

# ══ 6. pull requests are not issues ════════════════════════════════════════
# GET /repos/{slug}/issues returns pull requests as issues; `gh issue list` did
# not. A lane that reconciles TICKETS reads an unfiltered PR as a ticket with
# no owner and launches a build for it.
reset
fx 200 "$(jq -nc --argjson a "$(page 2 1)" --argjson b "$(page 2 50 pr)" '$a + $b')"
RC=0; gh_rest_issue_list o/r open ai-build 200 > "$T/out" || RC=$?
[ "$RC" = 0 ] && ok || bad "6: the mixed page must read cleanly, got $RC"
[ "$(nums)" = '[1,2]' ] && ok || bad "6: the two pull requests must be dropped, got $(nums)"
# the PR reader keeps them, because /pulls returns nothing else
reset
fx 200 "$(page 2 50 pr)"
RC=0; gh_rest_pr_list_all o/r open 200 > "$T/out" || RC=$?
[ "$RC" = 0 ] && [ "$(rows)" = 2 ] && ok || bad "6: gh_rest_pr_list_all must keep its rows (rc=$RC rows=$(rows))"
grep -q 'repos/o/r/pulls' "$T/gh-calls.txt" && ok || bad "6: …from /pulls: $(cat "$T/gh-calls.txt")"

# ══ 7. the row cap is honoured, and stops the paging ═══════════════════════
reset
fx 200 "$(page 100 1)"
fx 200 "$(page 100 101)"
fx 200 "$(page 100 201)"
RC=0; gh_rest_issue_list o/r open ai-build 150 > "$T/out" || RC=$?
[ "$RC" = 0 ] && ok || bad "7: a capped read must be rc 0, got $RC"
[ "$(rows)" = 150 ] && ok || bad "7: the cap must trim the answer, got $(rows)"
[ "$(pages_asked)" = 2 ] && ok || bad "7: the cap must stop the paging, asked $(pages_asked) pages"

# ══ 8. the comment reader ══════════════════════════════════════════════════
reset
fx 200 '[{"id":1,"body":"HOLD"},{"id":2,"body":"RESUME"}]'
RC=0; gh_rest_issue_comments o/r 887 200 > "$T/out" || RC=$?
[ "$RC" = 0 ] && ok || bad "8: a thread read must be rc 0, got $RC"
[ "$(jq -r '.[1].body' "$T/out")" = RESUME ] && ok || bad "8: the thread must come back oldest-first: $(cat "$T/out")"
grep -q 'repos/o/r/issues/887/comments' "$T/gh-calls.txt" && ok \
  || bad "8: …from the issue's own comments endpoint: $(cat "$T/gh-calls.txt")"
reset
fx 200 '[]'
RC=0; gh_rest_issue_comments o/r 888 200 > "$T/out" || RC=$?
[ "$RC" = 0 ] && [ "$(cat "$T/out")" = "[]" ] && ok || bad "8: an issue with no comments is [] under rc 0 (rc=$RC out=$(cat "$T/out"))"

# ══ 9. bad arguments never reach the network ═══════════════════════════════
reset
RC=0; gh_rest_issue_list "not a slug" open ai-build 200 > "$T/out" 2>/dev/null || RC=$?
[ "$RC" = 75 ] && ok || bad "9: a malformed slug must be 75, got $RC"
[ "$GH_REST_REASON" = bad-args ] && ok || bad "9: …and must say bad-args, got '$GH_REST_REASON'"
[ ! -s "$T/gh-calls.txt" ] && ok || bad "9: a malformed slug must not spend a request: $(cat "$T/gh-calls.txt")"
reset
RC=0; gh_rest_issue_comments o/r abc 200 > "$T/out" 2>/dev/null || RC=$?
[ "$RC" = 75 ] && ok || bad "9: a non-numeric issue number must be 75, got $RC"
[ ! -s "$T/gh-calls.txt" ] && ok || bad "9: …and must not spend a request: $(cat "$T/gh-calls.txt")"

# ══ 10. hygiene ════════════════════════════════════════════════════════════
reset
fx 200 "$(page 3 1)"
gh_rest_issue_list o/r open ai-build 200 > "$T/out" 2>/dev/null
[ "$(find "$TMPDIR" -maxdepth 1 -name 'gh-rest.*' | wc -l)" = 0 ] && ok \
  || bad "10: a clean read must leave no temp file: $(find "$TMPDIR" -maxdepth 1 -name 'gh-rest.*')"
reset
fx 429 '{"message":"API rate limit exceeded"}'
gh_rest_issue_list o/r open ai-build 200 > "$T/out" 2>/dev/null
[ "$(find "$TMPDIR" -maxdepth 1 -name 'gh-rest.*' | wc -l)" = 0 ] && ok \
  || bad "10: a DECLINED read must leave no temp file either: $(find "$TMPDIR" -maxdepth 1 -name 'gh-rest.*')"
grep -qx '# gh-rest: no-graphql' "$LIB" && ok \
  || bad "10: the library must carry the exact marker line '# gh-rest: no-graphql'"
# The comment-stripped library goes to a FILE, never down a pipe into `grep -q`:
# `grep -q` exits at its first match, SIGPIPEs the upstream file-grep, and under
# `set -o pipefail` that kill becomes the pipeline's status — so this row would
# flip on a race with a 100-line file rather than on the library. That shape is
# swept repo-wide by tests/rollup-crash-loud-test.sh §5, which this suite tripped.
RAWGH='(^|[^_[:alnum:]])gh (pr|issue|run|api) '
grep -v '^[[:space:]]*#' "$LIB" > "$T/lib.nocomments"
grep -qE "$RAWGH" "$T/lib.nocomments" \
  && bad "10: the library must reach GitHub only through gh_rest" || ok
# …and the detector is proved to bite, so the row above cannot be green because
# the pattern stopped matching: the same two commands over a file that DOES call
# `gh pr list` (plus a decoy in a comment) must find it.
printf '%s\n' '# gh pr list — a comment, not a call' 'gh pr list --limit 200' > "$T/fx/rawgh.sh"
grep -v '^[[:space:]]*#' "$T/fx/rawgh.sh" > "$T/fx/rawgh.nocomments"
grep -qE "$RAWGH" "$T/fx/rawgh.nocomments" && ok \
  || bad "10: the raw-gh detector misses a literal 'gh pr list' — the row above proves nothing"

# ══ 11. mutation checks ════════════════════════════════════════════════════
# A guard nobody has watched fail is a guard nobody knows is wired up. Each
# mutant is the plausible wrong version of one rule above; the runner asserts
# the suite's own rows go RED on it.
mutate() { # mutate <name> <sed program> <row to re-run>
  local name="$1" prog="$2" row="$3" m="$T/mut/lib.sh" r=0
  sed "$prog" "$LIB" > "$m"
  ( set +u
    # shellcheck source=/dev/null
    unset GH_REST_LIST_LIB; . "$DIR/bin/lib/gh-rest.sh"; . "$m"
    eval "$row" ) && r=0 || r=$?
  if [ "$r" != 0 ]; then echo "mutant caught ($name)"; ok
  else bad "11: mutant NOT caught: $name"; fi
}
# (a) a declined page returns the rows already collected
reset
fx 200 "$(page 100 1)"
fx 429 '{"message":"API rate limit exceeded"}'
mutate "a declined page is trimmed, not refused" \
  's|if \[ "$rc" != 0 \]; then rm -f "$raw" "$acc"; return "$rc"; fi|if [ "$rc" != 0 ]; then rm -f "$raw"; jq -c "." "$acc"; rm -f "$acc"; return 0; fi|' \
  'RC=0; gh_rest_issue_list o/r open ai-build 200 > "$T/out" || RC=$?; [ "$RC" = 75 ] && [ ! -s "$T/out" ]'
# (b) the paging stops after page 1
reset
fx 200 "$(page 100 1)"
fx 200 "$(page 20 101)"
mutate "only page 1 is ever read" \
  's|if \[ "$n" -lt 100 \]; then break; fi|break|' \
  'gh_rest_issue_list o/r open ai-build 200 > "$T/out" 2>/dev/null; [ "$(jq -r length "$T/out")" = 120 ]'
# (c) pull requests are kept
reset
fx 200 "$(jq -nc --argjson a "$(page 2 1)" --argjson b "$(page 2 50 pr)" '$a + $b')"
mutate "the pull_request filter is dropped" \
  "s|'select(.pull_request == null)'|'.'|" \
  'gh_rest_issue_list o/r open ai-build 200 > "$T/out" 2>/dev/null; [ "$(jq -rc "[.[].number]" "$T/out")" = "[1,2]" ]'
# (d) the cap is applied to the paging but not to the answer, so a caller that
#     asked for 150 rows gets 200 and the row it never asked about decides
reset
fx 200 "$(page 100 1)"
fx 200 "$(page 100 101)"
mutate "the row cap does not trim the answer" \
  's|jq -c "\.\[:$max\]" "$acc"|jq -c "." "$acc"|' \
  'gh_rest_issue_list o/r open ai-build 150 > "$T/out" 2>/dev/null; [ "$(jq -r length "$T/out")" = 150 ]'

echo "gh-rest-list-lib: PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
