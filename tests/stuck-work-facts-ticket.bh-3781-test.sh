#!/bin/bash
# tests/stuck-work-facts-ticket.bh-3781-test.sh — BH-3792 (BH-3781.3): the
# open-ticket fact reader, swf_ticket_facts. Only the transports are doubles:
# gh_rest answers from fixture files under $T/gh (a missing file is rc 75),
# job_rows from $T/jobs, and the jobs ledger lives in $T/ledger so the real
# sw_first_seen (seen.sh) and the real hold_classify (hold.sh) both run.
#
#   T0  no gh_rest                      -> rc 1, nothing on stdout
#   T1  buildable, no job, no PR        -> f17/f18 `-`, f19 0, f20 0, f21 0, anchors
#   T2  a running build in execute      -> f17 execute, f18 the `<job>|<stage>` anchor
#   T3  blocker open / closed / unread  -> f19 1 / 0 / ?
#   T4  HOLD / HOLD then RESUME / unread-> f20 1 / 0 / ?
#   T5  job_rows rc 1                   -> f17 ? and f18 ?, rc 0
#   T6  open-PR items file              -> f21 1 on ticket/bh-7, 0 on BH-70/BH-7.1, ? when missing
#   T6b a pull_request entry is dropped; T6c no graphql in the lib
#   T7  STUCK_WORK_MAX_ITEMS=2, 3 issues -> the two oldest, rc 3
#   T8  list read fails -> rc 3 and nothing; page 2 fails -> page 1 lines, rc 3
#   T9  empty html_url                -> f3 ?, labels and blockers not shifted
#
# Run: HARNESS_TEST_SANDBOX=1 bash tests/stuck-work-facts-ticket.bh-3781-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
LIB="$DIR/bin/lib/stuck-work/facts-ticket.sh"
[ -f "$LIB" ] || { echo "FAIL: $LIB is missing"; echo "stuck-work-facts-ticket: 0 passed, 1 failed"; exit 1; }

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

export HARNESS_TEST_SANDBOX=1 STUCK_WORK_NOW=1700000500 T
EPOCH=1700000500

# ── doubles ────────────────────────────────────────────────────────────────
gh_rest() {
  local p="${2:-}" f
  printf '%s %s\n' "${1:-}" "$p" >> "$T/gh.calls"
  case "$p" in
    repos/o/r/issues\?*)          f="$T/gh/list.${p##*page=}" ;;
    repos/o/r/issues/*/comments*) f=${p#repos/o/r/issues/}; f="$T/gh/comments.${f%%/*}.${p##*page=}" ;;
    repos/o/r/issues/*)           f="$T/gh/issue.${p#repos/o/r/issues/}" ;;
    *) GH_REST_STATUS=404; return 75 ;;
  esac
  [ -f "$f" ] || { GH_REST_STATUS=000; return 75; }
  GH_REST_STATUS=200; cat "$f"
}
job_rows() {
  [ "${1:-}" = running ] || return 1
  [ -f "$T/jobs.rc" ] && return "$(cat "$T/jobs.rc")"
  [ -f "$T/jobs" ] && cat "$T/jobs"; return 0
}
job_ledger_row() {
  local l; l=$(awk -F'\t' -v k="$1" -v key="$2" '$1==k && $2==key {print $3; exit}' "$T/ledger" 2>/dev/null)
  [ -n "$l" ] || return 2
  printf '{"status":"seen","detail":%s}\n' "$(printf '%s' "$l" | jq -Rs .)"
}
job_ledger_put() { printf '%s\t%s\t%s\n' "$1" "$2" "$4" >> "$T/ledger"; }

# issue <n> <body> [created] -> one REST issue object
issue() {
  jq -cn --argjson n "$1" --arg b "$2" --arg c "${3:-2026-09-01T00:00:00Z}" \
    '{number:$n, state:"open", title:("ticket " + ($n|tostring)), body:$b, created_at:$c,
      html_url:("https://github.com/o/r/issues/" + ($n|tostring)),
      labels:[{name:"ai-build"},{name:"size:M"}], user:{login:"operator",type:"User"}}'
}
comment() { jq -cn --arg b "$1" --arg at "$2" --arg t "${3:-User}" '{body:$b, created_at:$at, user:{login:"operator", type:$t}}'; }

reset() {
  rm -rf "$T/gh" "$T/jobs" "$T/jobs.rc" "$T/ledger" "$T/gh.calls" "$T/items"
  mkdir -p "$T/gh"; : > "$T/ledger"; : > "$T/items"
}
# list <issue-json...> -> page 1 of the issue list
list() { printf '%s\n' "$@" | jq -s . > "$T/gh/list.1"; }
nocomments() { local n; for n in "$@"; do echo '[]' > "$T/gh/comments.$n.1"; done; }
# run [items-file] -> stdout in $T/out, rc in $RC, a fresh shell that sources the lib by path
run() {
  ( . "$LIB" || exit 99; swf_ticket_facts o/r "${1-$T/items}" ) > "$T/out" 2> "$T/err"
  RC=$?
}
f() { awk -F'\t' -v n="$2" -v i="$1" '$2==i {print $n; exit}' "$T/out"; }
nf() { awk -F'\t' '{print NF}' "$T/out" | sort -u | tr '\n' ' '; }
ledger_has() { awk -F'\t' -v key="$1" '$1=="stuck_work_seen" && $2==key {f=1} END {exit !f}' "$T/ledger"; }

# ── T0 ─────────────────────────────────────────────────────────────────────
reset
( unset -f gh_rest; . "$LIB" || exit 99; swf_ticket_facts o/r "$T/items" ) > "$T/out" 2>/dev/null; rc=$?
[ "$rc" = 1 ] && ok || bad "T0 no gh_rest answered rc $rc, wanted 1"
[ -s "$T/out" ] && bad "T0 no gh_rest printed: $(cat "$T/out")" || ok
( . "$LIB" || exit 99; swf_ticket_facts not-a-repo "$T/items" ) > "$T/out" 2>/dev/null; rc=$?
[ "$rc" = 1 ] && [ ! -s "$T/out" ] && ok || bad "T0 a bad repo answered rc $rc: $(cat "$T/out")"

# ── T1 ─────────────────────────────────────────────────────────────────────
reset
list "$(issue 7 'Plain body, no blocker.')"; nocomments 7
run
[ "$RC" = 0 ] && ok || bad "T1 rc $RC, wanted 0 ($(cat "$T/err"))"
[ "$(wc -l < "$T/out")" = 1 ] && ok || bad "T1 wanted one line, got: $(cat "$T/out")"
[ "$(nf)" = "22 " ] && ok || bad "T1 field count is '$(nf)', wanted 22"
want=$(printf 'ticket\to/r#7\thttps://github.com/o/r/issues/7\t-\tai-build,size:M\t-\t-\t-\t-\t-\t-\t-\t-\t-\t-\t-\t-\t-\t0\t0\t0\t%s' "$EPOCH")
[ "$(cat "$T/out")" = "$want" ] && ok || bad "T1 line is
  $(cat "$T/out")
wanted
  $want"
ledger_has 'issue:o/r#7|unlaunched' && ok || bad "T1 the ledger has no issue:o/r#7|unlaunched anchor: $(cat "$T/ledger")"
grep -q 'labels=ai-build&state=open' "$T/gh.calls" && ok || bad "T1 the list read was not the ai-build/open REST query: $(cat "$T/gh.calls")"
# The anchor is write-once: a later tick prints the first epoch, not its own clock.
STUCK_WORK_NOW=1700009999 run
[ "$(f o/r#7 22)" = "$EPOCH" ] && ok || bad "T1 the second tick printed first_seen $(f o/r#7 22), wanted $EPOCH"

# ── T2 ─────────────────────────────────────────────────────────────────────
reset
list "$(issue 7 'body')"; nocomments 7
printf 'j0\tcromford\tplan\tplan\thub\tBH-7\t1\t0\t0\t-\t1\nj1\tcromford\tbuild\texecute\thub\tbh-7\t30\t0\t0\t-\t1\nj2\tcromford\tbuild\treview\thub\tBH-70\t3\t0\t0\t-\t1\n' > "$T/jobs"
run
[ "$(f o/r#7 17)" = execute ] && ok || bad "T2 job_stage is '$(f o/r#7 17)', wanted execute"
[ "$(f o/r#7 18)" = "$EPOCH" ] && ok || bad "T2 job_stage_seen is '$(f o/r#7 18)', wanted $EPOCH"
ledger_has 'j1|execute' && ok || bad "T2 the ledger has no j1|execute anchor: $(cat "$T/ledger")"
[ "$RC" = 0 ] && ok || bad "T2 rc $RC"

# ── T3 ─────────────────────────────────────────────────────────────────────
reset
list "$(issue 7 $'Scope.\n\nBlocked-by: #9 (hard)')" "$(issue 8 $'> **Blocked-by:** #9, #12')"; nocomments 7 8
echo '{"number":9,"state":"open"}' > "$T/gh/issue.9"
echo '{"number":12,"state":"closed"}' > "$T/gh/issue.12"
run
[ "$(f o/r#7 19)" = 1 ] && ok || bad "T3 open blocker gave issue_blocked '$(f o/r#7 19)', wanted 1"
[ "$(f o/r#8 19)" = 1 ] && ok || bad "T3 quoted Blocked-by with one open blocker gave '$(f o/r#8 19)', wanted 1"
[ "$(grep -c 'issues/9$' "$T/gh.calls")" = 1 ] && ok || bad "T3 blocker #9 read $(grep -c 'issues/9$' "$T/gh.calls") times, wanted once per call"
[ "$(nf)" = "22 " ] && ok || bad "T3 field count '$(nf)'"
# T3b — every blocker closed.
echo '{"number":9,"state":"closed"}' > "$T/gh/issue.9"
run
[ "$(f o/r#7 19)" = 0 ] && ok || bad "T3b closed blocker gave '$(f o/r#7 19)', wanted 0"
[ "$(f o/r#8 19)" = 0 ] && ok || bad "T3b two closed blockers gave '$(f o/r#8 19)', wanted 0"
# T3c — the blocker read fails: unreadable, never unblocked. An open sibling still dominates.
rm -f "$T/gh/issue.9"
run
[ "$(f o/r#7 19)" = '?' ] && ok || bad "T3c unreadable blocker gave '$(f o/r#7 19)', wanted ?"
echo '{"number":12,"state":"open"}' > "$T/gh/issue.12"
run
[ "$(f o/r#8 19)" = 1 ] && ok || bad "T3c an open blocker beside an unreadable one gave '$(f o/r#8 19)', wanted 1"
# A self-reference is not a blocker.
reset
list "$(issue 7 'Blocked-by: #7')"; nocomments 7
run
[ "$(f o/r#7 19)" = 0 ] && ok || bad "T3 a self-reference gave '$(f o/r#7 19)', wanted 0"

# ── T4 ─────────────────────────────────────────────────────────────────────
reset
list "$(issue 7 'body')"
printf '%s\n' "$(comment 'Looks good to build.' 2026-09-02T00:00:00Z)" "$(comment 'HOLD — waiting on vendor' 2026-09-03T00:00:00Z)" | jq -s . > "$T/gh/comments.7.1"
run
[ "$(f o/r#7 20)" = 1 ] && ok || bad "T4 a HOLD comment gave issue_hold '$(f o/r#7 20)', wanted 1"
# T4b — a later RESUME lifts it.
printf '%s\n' "$(comment 'HOLD — waiting on vendor' 2026-09-03T00:00:00Z)" "$(comment 'RESUME' 2026-09-04T00:00:00Z)" | jq -s . > "$T/gh/comments.7.1"
run
[ "$(f o/r#7 20)" = 0 ] && ok || bad "T4b HOLD then RESUME gave '$(f o/r#7 20)', wanted 0"
# A bot's HOLD is not a hold.
comment 'HOLD — bot noise' 2026-09-03T00:00:00Z Bot | jq -s . > "$T/gh/comments.7.1"
run
[ "$(f o/r#7 20)" = 0 ] && ok || bad "T4 a bot HOLD gave '$(f o/r#7 20)', wanted 0"
# T4c — the comments read fails.
rm -f "$T/gh/comments.7.1"
run
[ "$(f o/r#7 20)" = '?' ] && ok || bad "T4c unreadable thread gave '$(f o/r#7 20)', wanted ?"
[ "$(nf)" = "22 " ] && ok || bad "T4c field count '$(nf)'"

# ── T5 ─────────────────────────────────────────────────────────────────────
reset
list "$(issue 7 'body')"; nocomments 7
echo 1 > "$T/jobs.rc"
run
[ "$(f o/r#7 17)" = '?' ] && ok || bad "T5 job_rows rc 1 gave job_stage '$(f o/r#7 17)', wanted ?"
[ "$(f o/r#7 18)" = '?' ] && ok || bad "T5 job_rows rc 1 gave job_stage_seen '$(f o/r#7 18)', wanted ?"
[ "$RC" = 0 ] && ok || bad "T5 rc $RC, wanted 0"
# No job_rows loaded at all is the same answer.
( unset -f job_rows; . "$LIB" || exit 99; swf_ticket_facts o/r "$T/items" ) > "$T/out" 2>/dev/null
[ "$(f o/r#7 17)/$(f o/r#7 18)" = '?/?' ] && ok || bad "T5 no job_rows gave '$(f o/r#7 17)/$(f o/r#7 18)', wanted ?/?"

# ── T6 ─────────────────────────────────────────────────────────────────────
reset
list "$(issue 7 'body')"; nocomments 7
printf 'pr\to/r#40\thttps://github.com/o/r/pull/40\tticket/bh-7\n' > "$T/items"
run
[ "$(f o/r#7 21)" = 1 ] && ok || bad "T6 ticket/bh-7 in the items file gave open_pr '$(f o/r#7 21)', wanted 1"
printf 'BH-7: the ticket title\n' > "$T/items"
run
[ "$(f o/r#7 21)" = 1 ] && ok || bad "T6 'BH-7:' gave open_pr '$(f o/r#7 21)', wanted 1"
printf 'ticket/bh-70\nBH-7.1 child\nXBH-7\nBH-71\n' > "$T/items"
run
[ "$(f o/r#7 21)" = 0 ] && ok || bad "T6 BH-70/BH-7.1/XBH-7/BH-71 gave open_pr '$(f o/r#7 21)', wanted 0"
run "$T/no-such-file"
[ "$(f o/r#7 21)" = '?' ] && ok || bad "T6 a missing items file gave open_pr '$(f o/r#7 21)', wanted ?"

# T6b — a pull request in the issues list is dropped.
reset
list "$(issue 7 'body')" "$(issue 8 'a PR' | jq -c '. + {pull_request:{url:"https://api.github.com/repos/o/r/pulls/8"}}')"; nocomments 7 8
run
grep -q $'\to/r#8\t' "$T/out" && bad "T6b the pull_request entry #8 printed a line" || ok
[ "$(wc -l < "$T/out")" = 1 ] && ok || bad "T6b wanted exactly the one issue line, got $(wc -l < "$T/out")"

# T6c — REST only.
n=$(grep -c graphql "$LIB")
[ "$n" = 0 ] && ok || bad "T6c $LIB mentions graphql $n times"

# ── T7 ─────────────────────────────────────────────────────────────────────
reset
list "$(issue 3 a 2026-09-01T00:00:00Z)" "$(issue 5 b 2026-09-02T00:00:00Z)" "$(issue 6 c 2026-09-03T00:00:00Z)"; nocomments 3 5 6
STUCK_WORK_MAX_ITEMS=2 run
[ "$RC" = 3 ] && ok || bad "T7 the cap answered rc $RC, wanted 3"
[ "$(cut -f2 "$T/out" | tr '\n' ' ')" = "o/r#3 o/r#5 " ] && ok || bad "T7 capped lines are '$(cut -f2 "$T/out" | tr '\n' ' ')', wanted the two oldest"
grep -q 'direction=asc' "$T/gh.calls" && ok || bad "T7 the list is not read oldest first: $(head -n 1 "$T/gh.calls")"
STUCK_WORK_MAX_ITEMS=junk run
[ "$RC" = 0 ] && [ "$(wc -l < "$T/out")" = 3 ] && ok || bad "T7 a non-numeric cap answered rc $RC with $(wc -l < "$T/out") lines, wanted the default"

# ── T8 ─────────────────────────────────────────────────────────────────────
reset
run
[ "$RC" = 3 ] && ok || bad "T8 a failed list read answered rc $RC, wanted 3"
[ -s "$T/out" ] && bad "T8 a failed list read printed: $(cat "$T/out")" || ok
echo '{"message":"Not Found"}' > "$T/gh/list.1"
run
[ "$RC" = 3 ] && [ ! -s "$T/out" ] && ok || bad "T8 a non-array list answered rc $RC, wanted 3: $(cat "$T/out")"
# A full page 1, then page 2 fails: the 100 lines read, and rc 3.
reset
for i in $(seq 100 199); do issue "$i" b; done | jq -s . > "$T/gh/list.1"
run
[ "$RC" = 3 ] && ok || bad "T8 page 2 failing answered rc $RC, wanted 3"
[ "$(wc -l < "$T/out")" = 100 ] && ok || bad "T8 page 2 failing printed $(wc -l < "$T/out") lines, wanted page 1's 100"
[ "$(nf)" = "22 " ] && ok || bad "T8 field count '$(nf)'"
echo '[]' > "$T/gh/list.2"
run
[ "$RC" = 0 ] && [ "$(wc -l < "$T/out")" = 100 ] && ok || bad "T8 an empty page 2 answered rc $RC with $(wc -l < "$T/out") lines, wanted rc 0 and 100"
# ── T9 ─────────────────────────────────────────────────────────────────────
# An empty html_url must not collapse and shift labels/blockers left.
reset
list "$(issue 7 'Blocked-by: #3' | jq -c '.html_url = ""')"
echo '{"state":"open"}' > "$T/gh/issue.3"
nocomments 7
run
[ "$(nf)" = "22 " ] && ok || bad "T9 field count '$(nf)'"
[ "$(f o/r#7 3)" = '?' ] && ok || bad "T9 an empty html_url gave url '$(f o/r#7 3)', wanted ?"
[ "$(f o/r#7 5)" = 'ai-build,size:M' ] && ok || bad "T9 an empty html_url shifted labels to '$(f o/r#7 5)'"
[ "$(f o/r#7 19)" = 1 ] && ok || bad "T9 an empty html_url lost the blocker: issue_blocked '$(f o/r#7 19)'"

echo "stuck-work-facts-ticket: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
