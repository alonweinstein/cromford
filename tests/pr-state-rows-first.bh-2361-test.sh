#!/bin/bash
# tests/pr-state-rows-first.bh-2361-test.sh — BH-2361 (BH-2311.4): with the
# pr-state-rows flag up, mc_rows_rehydrate reads the pr_state view on EVERY
# mc_init, not only when pr-state.tsv is empty, and merges a COMPLETE read into
# the file under mc_row_put's own flock.
#
# THE DEFECT (the REPRO, case a). A rebuilt hub that comes up with a non-empty
# but stale pr-state.tsv — `alerted=-` where the pr_state view already carries
# the alert mark — returned at `[ -s "$MC_ROWS" ] && return 0` without asking,
# so the next mc_budget_check paged again about a PR the old box already paged.
#
# WHAT IT DRIVES. The real mc_init (which calls mc_rows_rehydrate) and the real
# mc_budget_check, through the real bin/jobs-client.sh with _jobs_req replaced
# by a stub that records every request and answers from fixture files. The
# assertions read pr-state.tsv, the request log and the lane-alert stub's call
# log — never the source text (D3).
#
#   (a) stale alerted=- + view mark        -> mark merged, 0 pages
#   (b) view outage                        -> file byte-identical, 0 ledger GETs
#   (c) view capped / cursor-less          -> file byte-identical
#   (d) flag down                          -> file byte-identical, 0 view GETs
#   (e) local newer since kept, local-only kept, view-only added
#   (f) a mc_row_put landing during the fetch survives the merge
#   (g) empty file + view outage           -> the ledger path, as today
#   (h) repo case differs                  -> one row, the local spelling
#   (i) the BH-1831 <tick>.pr-rows-down latch -> 0 view GETs, file unchanged
#   (k) same state + since, local head/reviewed/alerted/reason ahead of the
#       view (mc_transition's no-change refresh, a failed mark event) -> kept
#   (l) a held page for the CURRENT head flushes as a page after mc_init, not
#       released as "moved" (review D12)
#   (m) same entry, the view's later-day mark lands; an earlier one does not
#
# Run from anywhere: HARNESS_TEST_SANDBOX=1 bash tests/pr-state-rows-first.bh-2361-test.sh   (exit 0 = all pass)
. "$(dirname "$0")/lib/scratch.sh" || exit 1
set -uo pipefail
DIR=$(cd "$(dirname "$0")/.." && pwd)
[ -f "$DIR/bin/lib/mc/settle.sh" ] || exit 1   # impact: drives mc_rows_rehydrate
[ -f "$DIR/bin/lib/merge-conductor-lib.sh" ] || exit 1   # impact: fx_mc_harness copies it; sourced below
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }

# shellcheck source=tests/lib/fixture-harness.sh
. "$DIR/tests/lib/fixture-harness.sh" || exit 1

# ONE clock read; mc_now is pinned to it below.
NOW=$(date -u '+%s')
S=$((NOW-5400))
iso() { date -u -d "@$1" +%Y-%m-%dT%H:%M:%SZ; }

export HARNESS="$T/h"
fx_mc_harness "$DIR" "$T" || exit 1
mkdir -p "$T/h/bin/lib/jobs" "$T/h/env" "$T/h/state" "$T/h/flags" || exit 1
cp "$DIR/bin/jobs-client.sh" "$T/h/bin/jobs-client.sh" || exit 1
cp "$DIR"/bin/lib/jobs/*.sh "$T/h/bin/lib/jobs/" || exit 1
echo 'HARNESS_SECRET=test-secret' > "$T/h/env/global.env"
export HARNESS_SECRET=test-secret JOBS_URL=https://jobs.invalid JOBS_BOX=test-box JOBS_RETRIES=0 JOBS_ALERT=0

CALLS="$T/lane-alert.calls"
cat > "$T/h/bin/lane-alert.sh" <<EOF
#!/bin/bash
printf '%s\n' "\$*" >> "$CALLS"
exit 0
EOF
chmod +x "$T/h/bin/lane-alert.sh"

# shellcheck source=/dev/null
. "$T/h/bin/jobs-client.sh" || exit 1
# shellcheck source=/dev/null
. "$T/h/bin/lib/merge-conductor-lib.sh" || exit 1
mc_now() { echo "$NOW"; }

# THE STUB CLIENT. Every request is one "METHOD PATH" line in $REQ (appended,
# so a request made inside a `$( )` subshell is still counted). VIEW_MODE=down
# is an outage (rc 1); VIEW_HOOK is eval'd inside the view fetch, which is how
# case (f) lands a row write between the fetch and the merge.
REQ="$T/req.log"
_jobs_req() {
  printf '%s %s\n' "$1" "$2" >> "$REQ"
  case "$1 $2" in
    "GET /api/pr-state"*)
      [ -n "${VIEW_HOOK:-}" ] && eval "$VIEW_HOOK"
      [ "${VIEW_MODE:-ok}" = down ] && return 1
      cat "$T/view.json"; return 0 ;;
    "GET /api/ledger"*) return 2 ;;
    "GET /api/conductor/held"*) printf '{"rows":[],"n_total":0}'; return 0 ;;
    *) return 2 ;;
  esac
}

ROW="$MC_ROWS"
flag_up()   { touch "$T/h/flags/pr-state-rows"; _PR_ROWS_ON=""; _PR_ROWS_DOWN=0; }
flag_down() { rm -f "$T/h/flags/pr-state-rows"; _PR_ROWS_ON=""; _PR_ROWS_DOWN=0; }
reset_io()  { : > "$REQ"; : > "$CALLS"; unset VIEW_MODE VIEW_HOOK MC_REHYDRATE_PAGES; }
nreq()      { grep -c "$1" "$REQ" 2>/dev/null || true; }
ncalls()    { wc -l < "$CALLS" | tr -d ' '; }
col()       { awk -F'\t' -v k="$1" -v c="$2" '$1==k {print $c; exit}' "$ROW"; }
# vrow <repo> <num> <state> <since-epoch> <alerted> [id] — one pr_state view row
vrow() {
  jq -nc --arg r "$1" --arg n "$2" --arg s "$3" --arg si "$(iso "$4")" --arg a "$5" --arg id "${6:-1}" \
    '{id:($id|tonumber),repo:$r,number:($n|tonumber),state:$s,since:$si,head:"aaaaaaaa1111",
      reviewed:"aaaaaaaa1111",alerted:$a,reason:"-",url:("https://github.com/"+$r+"/pull/"+$n)}'
}
set_view() { jq -sc '{rows:.}' > "$T/view.json"; }
tline() { printf '%s\t%s\t%s\taaaaaaaa1111\taaaaaaaa1111\t%s\t-\thttps://github.com/%s/pull/%s\n' "$1" "$2" "$3" "$4" "${1%#*}" "${1##*#}"; }

mc_init   # creates the tree; the file is empty and the view answers nothing yet
printf '{"rows":[]}' > "$T/view.json"

echo "== (a) a stale alerted=- is repaired from the view; the budget page is not re-sent =="
flag_up; reset_io; export MC_MODE=merge
tline "example-org/a#7" WAIT_CI "$S" - > "$ROW"
vrow example-org/a 7 WAIT_CI "$S" "WAIT_CI@$S" | set_view
mc_init
[ "$(col 'example-org/a#7' 6)" = "WAIT_CI@$S" ] && ok || bad "(a) col 6 is '$(col 'example-org/a#7' 6)', wanted WAIT_CI@$S: $(cat "$ROW")"
[ "$(nreq '^GET /api/pr-state')" -ge 1 ] && ok || bad "(a) no pr_state view request on a non-empty file"
[ "$(nreq '^GET /api/ledger')" = 0 ] && ok || bad "(a) the ledger was asked on a non-empty file: $(cat "$REQ")"
mc_budget_check "example-org/a#7" WAIT_CI "$S" "https://github.com/example-org/a/pull/7" "checks pending"
[ "$(ncalls)" = 0 ] && ok || bad "(a) lane-alert called $(ncalls) times after the mark was restored, wanted 0: $(cat "$CALLS")"
unset MC_MODE

echo "== (b) view outage leaves the file byte for byte =="
flag_up; reset_io
tline "example-org/a#7" WAIT_CI "$S" - > "$ROW"; cp "$ROW" "$T/before"
vrow example-org/a 7 WAIT_CI "$S" "WAIT_CI@$S" | set_view
VIEW_MODE=down mc_init
cmp -s "$ROW" "$T/before" && ok || bad "(b) the file changed on a view outage: $(cat "$ROW")"
[ "$(nreq '^GET /api/pr-state')" -ge 1 ] && ok || bad "(b) the view was never asked, so the outage path was not driven"
[ "$(nreq '^GET /api/ledger')" = 0 ] && ok || bad "(b) a non-empty file fell through to the ledger: $(cat "$REQ")"

echo "== (c) a capped or cursor-less view is never merged =="
flag_up; reset_io
cp "$T/before" "$ROW"
# 1000 rows WITH ids: a full page, the cap is 1 page -> rc cap.
jq -nc --arg si "$(iso "$S")" '{rows:[range(0;1000) | {id:(2000-.),repo:"example-org/a",number:.,state:"READY",since:$si,
  head:"h",reviewed:"h",alerted:"READY@1",reason:"-",url:"u"}]}' > "$T/view.json"
MC_REHYDRATE_PAGES=1 mc_init
cmp -s "$ROW" "$T/before" && ok || bad "(c1) a capped view was merged: $(head -3 "$ROW")"
[ "$(nreq '^GET /api/pr-state')" = 1 ] && ok || bad "(c1) wanted exactly 1 view page under the cap, got $(nreq '^GET /api/pr-state')"
# 1000 rows WITHOUT ids: the cursor breaks -> rc cursor.
reset_io
jq -nc --arg si "$(iso "$S")" '{rows:[range(0;1000) | {repo:"example-org/a",number:.,state:"READY",since:$si,
  head:"h",reviewed:"h",alerted:"READY@1",reason:"-",url:"u"}]}' > "$T/view.json"
mc_init
cmp -s "$ROW" "$T/before" && ok || bad "(c2) a cursor-less full page was merged: $(head -3 "$ROW")"

echo "== (d) flag down: no view request, file untouched =="
flag_down; reset_io
cp "$T/before" "$ROW"
vrow example-org/a 7 WAIT_CI "$S" "WAIT_CI@$S" | set_view
mc_init
cmp -s "$ROW" "$T/before" && ok || bad "(d) flag down changed the file: $(cat "$ROW")"
[ "$(nreq '/api/pr-state')" = 0 ] && ok || bad "(d) flag down asked the view: $(cat "$REQ")"
[ "$(nreq '/api/ledger')" = 0 ] && ok || bad "(d) flag down asked the ledger: $(cat "$REQ")"

echo "== (e) newer local since kept, local-only kept, view-only added =="
flag_up; reset_io
{ tline "example-org/a#8" WAIT_CI "$((S+100))" -; tline "example-org/a#9" READY "$S" -; } > "$ROW"
L8=$(sed -n 1p "$ROW"); L9=$(sed -n 2p "$ROW")
{ vrow example-org/a 8 WAIT_REVIEW "$S" "WAIT_REVIEW@$S" 3; vrow example-org/a 10 READY "$S" "READY@$S" 2; } | set_view
mc_init
[ "$(grep -c . "$ROW")" = 3 ] && ok || bad "(e) wanted 3 rows, got: $(cat "$ROW")"
grep -qxF "$L8" "$ROW" && ok || bad "(e) the newer local #8 was overwritten by an older view row: $(cat "$ROW")"
grep -qxF "$L9" "$ROW" && ok || bad "(e) the local-only #9 was dropped: $(cat "$ROW")"
[ "$(col 'example-org/a#10' 6)" = "READY@$S" ] && ok || bad "(e) the view-only #10 was not added: $(cat "$ROW")"
[ "$(col 'example-org/a#10' 3)" = "$S" ] && ok || bad "(e) #10 since is not the epoch: $(cat "$ROW")"
grep -q 'rehydrate(merge): 2 from view, 1 local kept newer, 1 added$' "$MC_LOG" && ok \
  || bad "(e) the merge log line does not count what it did: $(grep 'rehydrate(merge)' "$MC_LOG" | tail -1)"

echo "== (f) a row written during the fetch survives the merge =="
flag_up; reset_io
tline "example-org/a#7" WAIT_CI "$S" - > "$ROW"
vrow example-org/a 7 WAIT_CI "$S" "WAIT_CI@$S" | set_view
VIEW_HOOK="mc_row_put 'example-org/a#11' READY $NOW aaaaaaaa1111 aaaaaaaa1111 - - u11" mc_init
[ "$(col 'example-org/a#11' 2)" = READY ] && ok || bad "(f) the row written during the fetch was lost: $(cat "$ROW")"
[ "$(col 'example-org/a#7' 6)" = "WAIT_CI@$S" ] && ok || bad "(f) the view mark was not merged beside it: $(cat "$ROW")"

echo "== (g) an EMPTY file still falls through to the ledger on a view outage =="
flag_up; reset_io
: > "$ROW"
VIEW_MODE=down mc_init
[ "$(nreq '^GET /api/pr-state')" -ge 1 ] && ok || bad "(g) the view was not asked first"
[ "$(nreq '^GET /api/ledger')" = 1 ] && ok || bad "(g) wanted exactly 1 ledger GET, got $(nreq '^GET /api/ledger'): $(cat "$REQ")"
[ -s "$ROW" ] && bad "(g) the empty file was written from nothing: $(cat "$ROW")" || ok

echo "== (h) the repo is matched case-folded; the local spelling is kept =="
flag_up; reset_io
tline "example-org/A#7" WAIT_CI "$S" - > "$ROW"
vrow example-org/a 7 WAIT_CI "$S" "WAIT_CI@$S" | set_view
mc_init
[ "$(grep -c . "$ROW")" = 1 ] && ok || bad "(h) wanted one row, got: $(cat "$ROW")"
[ "$(col 'example-org/A#7' 6)" = "WAIT_CI@$S" ] && ok || bad "(h) the mark did not land on the local key: $(cat "$ROW")"

echo "== (i) the BH-1831 pr-rows-down latch skips the read =="
flag_up; reset_io
export MC_TICK_ID=tick-i
: > "$MC_TICK_DIR/tick-i.pr-rows-down"
tline "example-org/a#7" WAIT_CI "$S" - > "$ROW"; cp "$ROW" "$T/before"
vrow example-org/a 7 WAIT_CI "$S" "WAIT_CI@$S" | set_view
mc_init
[ "$(nreq '/api/pr-state')" = 0 ] && ok || bad "(i) the view was asked under the latch: $(cat "$REQ")"
cmp -s "$ROW" "$T/before" && ok || bad "(i) the file changed under the latch"
unset MC_TICK_ID

echo "== (j) MC_REHYDRATE=0 still disables it =="
flag_up; reset_io
cp "$T/before" "$ROW"
MC_REHYDRATE=0 mc_init
[ "$(nreq '/api/pr-state')" = 0 ] && ok || bad "(j) MC_REHYDRATE=0 still asked the view"

echo "== (k) same state + since: the file's newer head/reviewed/alerted/reason survive =="
flag_up; reset_io
printf 'example-org/a#7\tWAIT_CI\t%s\tbbbbbbbb2222\tbbbbbbbb2222\tWAIT_CI@%s\tnew-reason\thttps://github.com/example-org/a/pull/7\n' "$S" "$S" > "$ROW"
cp "$ROW" "$T/before"
vrow example-org/a 7 WAIT_CI "$S" - | set_view
mc_init
[ "$(nreq '^GET /api/pr-state')" -ge 1 ] && ok || bad "(k) the view was never asked, so the merge was not driven"
cmp -s "$ROW" "$T/before" && ok || bad "(k) the view rolled the file back: $(cat "$ROW")"
[ "$(col 'example-org/a#7' 4)" = bbbbbbbb2222 ] && ok || bad "(k) head reverted to '$(col 'example-org/a#7' 4)'"
[ "$(col 'example-org/a#7' 5)" = bbbbbbbb2222 ] && ok || bad "(k) reviewed reverted to '$(col 'example-org/a#7' 5)'"
[ "$(col 'example-org/a#7' 6)" = "WAIT_CI@$S" ] && ok || bad "(k) alerted reverted to '$(col 'example-org/a#7' 6)'"
[ "$(col 'example-org/a#7' 7)" = new-reason ] && ok || bad "(k) reason reverted to '$(col 'example-org/a#7' 7)'"
export MC_MODE=merge
mc_budget_check "example-org/a#7" WAIT_CI "$S" "https://github.com/example-org/a/pull/7" "checks pending"
[ "$(ncalls)" = 0 ] && ok || bad "(k) the kept mark did not stop a re-page: $(cat "$CALLS")"
unset MC_MODE

echo "== (l) a page held for the current head is paged after mc_init, not released as moved =="
flag_up; reset_io
printf 'example-org/a#7\tWAIT_CI\t%s\tbbbbbbbb2222\tbbbbbbbb2222\t-\t-\thttps://github.com/example-org/a/pull/7\n' "$S" > "$ROW"
vrow example-org/a 7 WAIT_CI "$S" - | set_view
mc_init
M0=$(grep -c 'held page released: the PR moved' "$MC_LOG" 2>/dev/null || true)
mc_hold_flush_one example-org/a 7 WAIT_CI bbbbbbbb2222 BUDGET "90m in WAIT_CI" "WAIT_CI@$S" kill-switch 2026-09-27T00:00:00Z
[ "$(ncalls)" = 1 ] && ok || bad "(l) the held page for the current head was not paged: $(ncalls) pages"
[ "$(grep -c 'held page released: the PR moved' "$MC_LOG" 2>/dev/null || true)" = "$M0" ] && ok \
  || bad "(l) the held page was released as moved: $(grep 'PR moved' "$MC_LOG" | tail -1)"
[ "$(col 'example-org/a#7' 6)" = "WAIT_CI@$S" ] && ok || bad "(l) the flush did not spend the mark: $(cat "$ROW")"

echo "== (m) same entry: a later-day view mark lands, an earlier one does not =="
flag_up; reset_io
printf 'example-org/a#7\tBLOCKED_HUMAN\t%s\taaaaaaaa1111\taaaaaaaa1111\tBLOCKED_HUMAN@%s@20260926\t-\thttps://github.com/example-org/a/pull/7\n' "$S" "$S" > "$ROW"
vrow example-org/a 7 BLOCKED_HUMAN "$S" "BLOCKED_HUMAN@$S@20260927" | set_view
mc_init
[ "$(col 'example-org/a#7' 6)" = "BLOCKED_HUMAN@$S@20260927" ] && ok || bad "(m1) the later view mark did not land: $(cat "$ROW")"
reset_io
vrow example-org/a 7 BLOCKED_HUMAN "$S" "BLOCKED_HUMAN@$S@20260925" | set_view
mc_init
[ "$(col 'example-org/a#7' 6)" = "BLOCKED_HUMAN@$S@20260927" ] && ok || bad "(m2) an earlier view mark replaced a later local one: $(cat "$ROW")"
reset_io
vrow example-org/a 7 BLOCKED_HUMAN "$S" "WAIT_CI@1" | set_view
mc_init
[ "$(col 'example-org/a#7' 6)" = "BLOCKED_HUMAN@$S@20260927" ] && ok || bad "(m3) a mark for another entry landed: $(cat "$ROW")"

echo "pr-state-rows-first.bh-2361: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
