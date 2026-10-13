#!/bin/bash
# tests/conductor-hold-comment.bh-3455-test.sh — mc_hold_comment's real body
# (BH-3455, order 4 of BH-3436): one deduped PR comment per (PR, kind).
#
# Every case sources bin/lib/mc-hold-comment.sh in a fresh bash with the
# conductor's helpers stubbed (mc_log, mc_issue_comment, job_ledger_get/put,
# mc_rest_pages, mc_ready_why) and a scratch root of its own.
#   H2'  three calls, one POST, one HOLD_COMMENT line, posted in ledger + file,
#        no ledger read once the file answers, one ready-why; repo case folds.
#   H4'  non-comment kinds and malformed keys: no POST, no WOULD, no ledger.
#        provenance posts but writes no ready-why (not a READY-row kind).
#   H5   observe (ACTIONS=0) and kill (KILL=1): one WOULD line, nothing sent.
#   H6   MC_HOLD_COMMENT=0: nothing at all.
#   H8   the head moves on the same kind: still one POST.
#   H9   POST 500: failed-1..3, never posted, one give-up line, 4th call silent.
#   H10  ledger down and no file line: zero POSTs, one skipped line; a file
#        line answers while the ledger is down.
#   H11  a hostile reason is flattened: two lines, no em dash, and no PR-thread
#        reader (block gate, hold) acts on the body.
#   H12  this suite names the lib on a non-comment line.
#   H13  a leftover posting row is resolved by one thread read for the marker.
#   H14  re-entry through mc_ready_why terminates with one POST; with another
#        kind it posts that one without a second mc_ready_why (_MC_HC_IN).
#   H15  bin/merge-conductor.sh's real source line loads a lib that posts.
# HC_LIB=<path> runs the suite against another copy of the lib (the red proof).
# Run from anywhere: tests/conductor-hold-comment.bh-3455-test.sh   (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

LIB="${HC_LIB:-"$DIR/bin/lib/mc-hold-comment.sh"}"
[ -f "$LIB" ] && ok || bad "missing $LIB"

# The conductor's helpers, as the lib finds them already defined at call time.
# shellcheck disable=SC2016
STUBS='
mc_log() { printf "%s\n" "$*" >> "$C/mc.log"; }
mc_issue_comment() {
  local n; n=$(( $(cat "$C/posts" 2>/dev/null | wc -l) + 1 ))
  printf "%s %s\n" "$1" "$2" >> "$C/posts"
  printf "%s" "$3" > "$C/body.$n"
  GH_REST_STATUS=${STUB_POST_STATUS:-201}
  case "$GH_REST_STATUS" in 2??) return 0 ;; esac
  return 75
}
job_ledger_get() {
  echo "get $1 $2" >> "$C/lget"
  [ "${STUB_LEDGER_DOWN:-0}" = 1 ] && return 1
  local s; s=$(awk -F"\t" -v k="$1" -v v="$2" "\$1==k && \$2==v {s=\$3} END {print s}" "$C/ledger.tsv" 2>/dev/null)
  [ -n "$s" ] || return 2
  printf "%s" "$s"
}
job_ledger_put() {
  echo "put $1 $2 $3" >> "$C/lput"
  [ "${STUB_LEDGER_DOWN:-0}" = 1 ] && return 1
  printf "%s\t%s\t%s\t%s\n" "$1" "$2" "$3" "${4:-}" >> "$C/ledger.tsv"
}
mc_rest_pages() {
  echo "$1" >> "$C/reads"
  [ -n "${STUB_THREAD:-}" ] && [ -r "$STUB_THREAD" ] || return 75
  cat "$STUB_THREAD"
}
mc_ready_why() {
  printf "%s\t%s\t%s\t%s\n" "$@" >> "$C/why"
  [ "${STUB_WHY_REENTER:-0}" = 1 ] && mc_hold_comment "$1" "$2" "${STUB_WHY_KIND:-$3}" "$4"
  return 0
}
'

# newcase <name> — a fresh scratch dir C for one case.
newcase() { C="$T/$1"; mkdir -p "$C/h"; }
# hc <shell-body> [env...] — source the lib with stubs in case dir C and run
# the body. ACTIONS=1 KILL=0 unless the env list says otherwise.
hc() {
  local body="$1"; shift
  env -u H -u MC_H -u MC_HOLD_COMMENT -u MC_HOLD_COMMENT_TRACE -u STUB_THREAD \
    HARNESS="$C/h" MC_STATE_DIR="$C/h/state/merge-conductor" C="$C" LIBF="$LIB" \
    ACTIONS=1 KILL=0 "$@" \
    bash -c "$STUBS"'
. "$LIBF" || exit 9
'"$body"
}
lines()  { if [ -f "$1" ]; then wc -l < "$1" | tr -d ' '; else echo 0; fi; }
count()  { if [ -f "$2" ]; then grep -cxF -- "$1" "$2"; else echo 0; fi; }
hcfile() { echo "$C/h/state/merge-conductor/hold-comments.txt"; }
laststatus() { awk -v h="$1" '$1==h {s=$2} END {print s}' "$(hcfile)" 2>/dev/null; }

# --- H2': one POST across three calls ------------------------------------------
newcase h2
for i in 1 2 3; do
  hc 'mc_hold_comment "o/r#7" h1aaaaaaaaa lead "lead PR waits"'; rc=$?
  [ "$rc" -eq 0 ] && ok || bad "H2' call $i rc=$rc"
  [ "$i" = 1 ] && gets_after_1=$(lines "$C/lget")
done
[ "$(lines "$C/posts")" = 1 ] && ok || bad "H2' POSTs=$(lines "$C/posts"), want 1"
[ "$(count 'HOLD_COMMENT o/r#7 lead' "$C/mc.log")" = 1 ] && ok || bad "H2' HOLD_COMMENT log lines: $(cat "$C/mc.log" 2>/dev/null)"
[ "$(awk -F'\t' '$1=="hold_comment" && $2=="o/r#7@lead" {s=$3} END {print s}' "$C/ledger.tsv" 2>/dev/null)" = posted ] \
  && ok || bad "H2' ledger row hold_comment o/r#7@lead is not posted: $(cat "$C/ledger.tsv" 2>/dev/null)"
[ "$(laststatus 'o/r#7@lead')" = posted ] && ok || bad "H2' file last status: $(cat "$(hcfile)" 2>/dev/null)"
[ "$(lines "$C/lget")" = "${gets_after_1:-x}" ] && ok || bad "H2' calls 2-3 read the ledger ($(lines "$C/lget") gets, ${gets_after_1:-?} after call 1)"
[ "$(lines "$C/why")" = 1 ] && ok || bad "H2' ready-why lines=$(lines "$C/why"), want 1"
[ "$(cat "$C/why" 2>/dev/null)" = "o/r#7	h1aaaaaaaaa	lead	lead PR waits" ] && ok || bad "H2' ready-why args: $(cat "$C/why" 2>/dev/null)"
[ "$(cat "$C/posts" 2>/dev/null)" = "o/r 7" ] && ok || bad "H2' posted to: $(cat "$C/posts" 2>/dev/null)"
hc 'mc_hold_comment "O/R#7" h1aaaaaaaaa lead "lead PR waits"'
[ "$(lines "$C/posts")" = 1 ] && ok || bad "H2' O/R#7 after o/r#7 posted again"

# --- H4': non-comment kinds and malformed keys ----------------------------------
for k in conductor main-red merges-off asked block-gate unreadable checks mergeable lead-held lead-unread "" TICKET-HOLD; do
  for a in 1 0; do
    newcase "h4-$a-${k:-empty}"
    hc 'mc_hold_comment "o/r#7" h1 "$K" "why"' K="$k" ACTIONS="$a"; rc=$?
    [ "$rc" -eq 0 ] && ok || bad "H4' kind '$k' rc=$rc"
    [ "$(lines "$C/posts")" = 0 ] && ok || bad "H4' kind '$k' posted"
    [ ! -e "$C/h/state/merge-conductor/hold-comments-would.txt" ] && ok || bad "H4' kind '$k' ACTIONS=$a wrote a WOULD line"
    [ ! -e "$C/lget" ] && [ ! -e "$C/lput" ] && ok || bad "H4' kind '$k' touched the ledger"
    [ ! -e "$C/mc.log" ] && ok || bad "H4' kind '$k' logged: $(cat "$C/mc.log")"
  done
done
for key in foo 'o/r#x' 'o/r/x#3' '#3' 'o/r#' 'o r/x#3'; do
  newcase "h4-key-$(printf '%s' "$key" | tr -c 'A-Za-z0-9' _)"
  hc 'mc_hold_comment "$KEY" h1 lead "why"' KEY="$key"; rc=$?
  [ "$rc" -eq 0 ] && ok || bad "H4' key '$key' rc=$rc"
  [ "$(lines "$C/posts")" = 0 ] && [ ! -e "$C/lget" ] && [ ! -e "$C/lput" ] && ok || bad "H4' malformed key '$key' reached the ledger or posted"
done
newcase h4-prov
hc 'mc_hold_comment "o/r#9" h1 provenance "needs re-review"'
[ "$(lines "$C/posts")" = 1 ] && ok || bad "H4' provenance POSTs=$(lines "$C/posts"), want 1"
[ ! -e "$C/why" ] && ok || bad "H4' provenance wrote a ready-why line"

# --- H5: observe and kill --------------------------------------------------------
for mode in "ACTIONS=0 KILL=0" "ACTIONS=1 KILL=1"; do
  newcase "h5-${mode// /-}"
  # shellcheck disable=SC2086
  hc 'mc_hold_comment "o/r#7" h1 lead "w"; mc_hold_comment "o/r#7" h2 lead "w"' $mode
  [ "$(lines "$C/posts")" = 0 ] && ok || bad "H5 $mode posted"
  [ "$(count 'HOLD_COMMENT WOULD o/r#7 lead' "$C/mc.log")" = 1 ] && ok || bad "H5 $mode WOULD lines: $(cat "$C/mc.log" 2>/dev/null)"
  [ "$(lines "$C/mc.log")" = 1 ] && ok || bad "H5 $mode mc.log has $(lines "$C/mc.log") lines"
  [ ! -e "$C/lput" ] && ok || bad "H5 $mode wrote the ledger"
  [ ! -e "$(hcfile)" ] && ok || bad "H5 $mode wrote the post file"
  [ "$(cat "$C/h/state/merge-conductor/hold-comments-would.txt" 2>/dev/null)" = "o/r#7@lead" ] && ok || bad "H5 $mode would file"
done

# --- H6: off ---------------------------------------------------------------------
newcase h6
hc 'mc_hold_comment "o/r#7" h1 lead "w"' MC_HOLD_COMMENT=0; rc=$?
[ "$rc" -eq 0 ] && [ "$(lines "$C/posts")" = 0 ] && ok || bad "H6 off rc=$rc posts=$(lines "$C/posts")"
[ ! -s "$C/mc.log" ] && ok || bad "H6 off logged: $(cat "$C/mc.log")"
[ ! -e "$C/h/state/merge-conductor/hold-comments-would.txt" ] && [ ! -e "$C/lget" ] && ok || bad "H6 off touched state"

# --- H8: head moves --------------------------------------------------------------
newcase h8
hc 'mc_hold_comment "o/r#7" h1 lead "w"'
hc 'mc_hold_comment "o/r#7" h2 lead "w"'
[ "$(lines "$C/posts")" = 1 ] && ok || bad "H8 POSTs=$(lines "$C/posts"), want 1"
hc 'mc_hold_comment "o/r#7" h2 pr-hold "w"'
[ "$(lines "$C/posts")" = 2 ] && ok || bad "H8 a different kind on the same PR did not post"

# --- H9: failed posts cap at 3 ---------------------------------------------------
newcase h9
for i in 1 2 3 4; do hc 'mc_hold_comment "o/r#7" h1 lead "w"' STUB_POST_STATUS=500; done
[ "$(lines "$C/posts")" = 3 ] && ok || bad "H9 POSTs=$(lines "$C/posts"), want 3"
seen=$(awk '{print $4}' "$C/lput" 2>/dev/null | tr '\n' ' ')
[ "$seen" = "posting failed-1 posting failed-2 posting failed-3 " ] && ok || bad "H9 ledger statuses: '$seen'"
! grep -q ' posted ' "$(hcfile)" 2>/dev/null && ! grep -q 'posted' "$C/lput" 2>/dev/null && ok || bad "H9 posted recorded on a failed POST"
[ "$(laststatus 'o/r#7@lead')" = failed-3 ] && ok || bad "H9 file last status $(laststatus 'o/r#7@lead')"
[ "$(grep -c 'gave up after 3' "$C/mc.log" 2>/dev/null)" = 1 ] && ok || bad "H9 give-up lines: $(cat "$C/mc.log" 2>/dev/null)"
grep -q 'HTTP 500' "$C/mc.log" 2>/dev/null && ok || bad "H9 give-up line does not name HTTP 500"
! grep -qx 'HOLD_COMMENT o/r#7 lead' "$C/mc.log" 2>/dev/null && ok || bad "H9 logged a post"
grep -q '"attempts":3' "$C/ledger.tsv" 2>/dev/null && ok || bad "H9 failed-3 detail has no attempts:3: $(cat "$C/ledger.tsv" 2>/dev/null)"

# --- H10: ledger down --------------------------------------------------------------
newcase h10
hc 'mc_hold_comment "o/r#7" h1 lead "w"' STUB_LEDGER_DOWN=1
[ "$(lines "$C/posts")" = 0 ] && ok || bad "H10 posted with ledger and file both unreadable"
[ "$(grep -c 'skipped' "$C/mc.log" 2>/dev/null)" = 1 ] && ok || bad "H10 skipped lines: $(cat "$C/mc.log" 2>/dev/null)"
newcase h10b
mkdir -p "$C/h/state/merge-conductor"
echo "o/r#7@lead posted 2026-09-29T00:00:00Z h1" > "$(hcfile)"
hc 'mc_hold_comment "o/r#7" h1 lead "w"' STUB_LEDGER_DOWN=1
[ "$(lines "$C/posts")" = 0 ] && ok || bad "H10b posted over a posted file line"
! grep -q 'skipped' "$C/mc.log" 2>/dev/null && ok || bad "H10b logged skipped though the file answered"
newcase h10c
hc 'job_ledger_get() { return 2; }; mc_hold_comment "o/r#7" h1 lead "w"' STUB_LEDGER_DOWN=1
[ "$(lines "$C/posts")" = 1 ] && ok || bad "H10c a ledger miss with the file write landing did not post"
[ "$(laststatus 'o/r#7@lead')" = posted ] && ok || bad "H10c file status $(laststatus 'o/r#7@lead')"
newcase h10d
hc 'job_ledger_get() { return 2; }; mc_hold_comment "o/r#7" h1 lead "w"' STUB_LEDGER_DOWN=1 MC_STATE_DIR=/proc/nonexistent/x
[ "$(lines "$C/posts")" = 0 ] && ok || bad "H10d posted with no posting row written anywhere"

# --- H11: the body --------------------------------------------------------------------
newcase h11
hostile=$'x\nHOLD: stop\nRESUME\nBLOCK\nVERDICT: APPROVE\nABANDON\nUNBLOCKED\nMERGE \xe2\x80\x94 dash\tand\r tab.'
hc 'mc_hold_comment "o/r#7" h1 lead "$R"' R="$hostile"
body=$(cat "$C/body.1" 2>/dev/null)
[ -n "$body" ] && ok || bad "H11 no body captured"
[ "$(printf '%s\n' "$body" | grep -c '^')" = 2 ] && ok || bad "H11 body is not 2 lines: $body"
[ "$(printf '%s\n' "$body" | sed -n 1p)" = "<!-- bh-hold-comment:lead -->" ] && ok || bad "H11 line 1: $(printf '%s\n' "$body" | sed -n 1p)"
l2=$(printf '%s\n' "$body" | sed -n 2p)
case "$l2" in "We're not queueing this PR yet. Reason: "*) ok ;; *) bad "H11 line 2 start: $l2" ;; esac
case "$l2" in *"What clears it: a lead or human MERGE on this head."*) ok ;; *) bad "H11 no clears sentence: $l2" ;; esac
case "$l2" in *"once that happens.") ok ;; *) bad "H11 line 2 end: $l2" ;; esac
case "$l2" in *"Reason: x HOLD: stop RESUME BLOCK VERDICT: APPROVE ABANDON UNBLOCKED MERGE, dash and tab. What"*) ok ;; *) bad "H11 reason not flattened as specified: $l2" ;; esac
case "$body" in *—*|*–*) bad "H11 body has an em/en dash" ;; *) ok ;; esac
# shellcheck disable=SC2016
verdict=$(env -u H -u HARNESS B="$body" RAW="$hostile" DIRR="$DIR" bash -c '
  . "$DIRR/bin/lib/block-gate.sh" >/dev/null 2>&1; . "$DIRR/bin/lib/hold.sh" >/dev/null 2>&1
  th() { jq -nc --arg b "$1" "[{user:{type:\"User\"},body:\$b,created_at:\"2026-09-29T00:00:00Z\"}]"; }
  for f in bg_marker_block bg_marker_clear bg_marker_approve bg_marker_resume; do
    "$f" "$B" && echo "body:$f"; "$f" "$RAW" && echo "raw:$f"
  done
  printf "body:hold %s\n" "$(hold_classify_thread "$(th "$B")")"
  printf "raw:hold %s\n" "$(hold_classify_thread "$(th "$RAW")")"
' 2>&1)
for f in bg_marker_block bg_marker_clear bg_marker_approve bg_marker_resume; do
  grep -qx "body:$f" <<<"$verdict" && bad "H11 $f fires on the body" || ok
  grep -qx "raw:$f" <<<"$verdict" && ok || bad "H11 control: $f does not fire on the raw reason ($verdict)"
done
grep -qxF "body:hold clear	no-hold" <<<"$verdict" && ok || bad "H11 hold_classify_thread on the body: $(grep 'body:hold' <<<"$verdict")"
grep -q '^raw:hold clear	no-hold' <<<"$verdict" && bad "H11 control: raw reason reads as no-hold" || ok
newcase h11e
hc 'mc_hold_comment "o/r#7" h1 hold-label ""'
[ "$(sed -n 2p "$C/body.1" 2>/dev/null)" = "We're not queueing this PR yet. What clears it: remove the hold label. The merge conductor picks it up on its next pass once that happens." ] \
  && ok || bad "H11 empty reason line: $(sed -n 2p "$C/body.1" 2>/dev/null)"
newcase h11d
hc 'mc_hold_comment "o/r#7" h1 dep-hold "$R"' R=$'waits on o/r#6\xe2\x80\x94then o/r#5\xe2\x80\x93next...'
[ "$(sed -n 2p "$C/body.1" 2>/dev/null)" = "We're not queueing this PR yet. Reason: waits on o/r#6, then o/r#5, next. What clears it: the named dependency closes. The merge conductor picks it up on its next pass once that happens." ] \
  && ok || bad "H11 unspaced dashes: $(sed -n 2p "$C/body.1" 2>/dev/null)"
newcase h11l
hc 'mc_hold_comment "o/r#7" h1 lead "$R"' R="$(printf 'a%.0s' $(seq 1 400))"
r=$(sed -n 2p "$C/body.1" 2>/dev/null | sed -e 's/^.*Reason: //' -e 's/\. What clears it:.*$//')
[ "${#r}" = 300 ] && ok || bad "H11 long reason is ${#r} chars, want 300"

# --- H12: the lib is named on a non-comment line ---------------------------------
# Read first, then grep -q the variable: a grep -q on the right of a pipe can
# exit before the left side is done, and under pipefail that SIGPIPE is a FAIL.
H12_CODE=$(grep -vE '^[[:space:]]*#' "$0")
grep -qF '"$DIR/bin/lib/mc-hold-comment.sh"' <<<"$H12_CODE" && ok || bad "H12 lib path not named on a code line"

# --- H13: a leftover posting row ---------------------------------------------------
seed_posting() { mkdir -p "$C/h/state/merge-conductor"; echo "o/r#7@lead posting 2026-09-29T01:02:03Z h1" > "$(hcfile)"; }
newcase h13
seed_posting
jq -nc '[{user:{type:"User"},body:"<!-- bh-hold-comment:lead -->\nWe are not queueing"}]' > "$C/thread.json"
hc 'mc_hold_comment "o/r#7" h1 lead "w"' STUB_THREAD="$C/thread.json"
[ "$(lines "$C/posts")" = 0 ] && ok || bad "H13 re-sent with the marker on the thread"
[ "$(laststatus 'o/r#7@lead')" = posted ] && ok || bad "H13 status after recovery: $(laststatus 'o/r#7@lead')"
grep -q 'issues/7/comments' "$C/reads" 2>/dev/null && grep -q 'since=2026-09-29T01:02:03Z' "$C/reads" && ok || bad "H13 thread read: $(cat "$C/reads" 2>/dev/null)"
grep -q '"recovered":true' "$C/ledger.tsv" 2>/dev/null && ok || bad "H13 no recovered detail"
newcase h13b
seed_posting
jq -nc '[{user:{type:"User"},body:"<!-- bh-hold-comment:pr-hold -->\nother kind"}]' > "$C/thread.json"
hc 'mc_hold_comment "o/r#7" h1 lead "w"' STUB_THREAD="$C/thread.json"
[ "$(lines "$C/posts")" = 1 ] && ok || bad "H13b marker absent: POSTs=$(lines "$C/posts"), want 1"
newcase h13c
seed_posting
hc 'mc_hold_comment "o/r#7" h1 lead "w"'
[ "$(lines "$C/posts")" = 0 ] && ok || bad "H13c thread unreadable but it sent"
[ "$(laststatus 'o/r#7@lead')" = posting ] && ok || bad "H13c status moved: $(laststatus 'o/r#7@lead')"

# --- H14: re-entry through mc_ready_why ------------------------------------------------
newcase h14
out=$(timeout 10 env -u H -u MC_H -u MC_HOLD_COMMENT HARNESS="$C/h" MC_STATE_DIR="$C/h/state/merge-conductor" \
  C="$C" LIBF="$LIB" ACTIONS=1 KILL=0 STUB_WHY_REENTER=1 \
  bash -c "$STUBS"'
. "$LIBF" || exit 9
mc_hold_comment "o/r#7" h1 lead "w"' 2>&1); rc=$?
[ "$rc" != 124 ] && ok || bad "H14 re-entry did not terminate"
[ "$rc" = 0 ] && ok || bad "H14 rc=$rc: $out"
[ "$(lines "$C/posts")" = 1 ] && ok || bad "H14 POSTs=$(lines "$C/posts"), want 1"
[ "$(lines "$C/why")" = 1 ] && ok || bad "H14 ready-why ran $(lines "$C/why") times, want 1"
# H14b: the call back in names another kind (the READY arm's own). It posts,
# and the guard keeps it from calling mc_ready_why a second time.
newcase h14b
out=$(timeout 10 env -u H -u MC_H -u MC_HOLD_COMMENT HARNESS="$C/h" MC_STATE_DIR="$C/h/state/merge-conductor" \
  C="$C" LIBF="$LIB" ACTIONS=1 KILL=0 STUB_WHY_REENTER=1 STUB_WHY_KIND=pr-hold \
  bash -c "$STUBS"'
. "$LIBF" || exit 9
mc_hold_comment "o/r#7" h1 lead "w"' 2>&1); rc=$?
[ "$rc" = 0 ] && ok || bad "H14b rc=$rc: $out"
[ "$(lines "$C/posts")" = 2 ] && ok || bad "H14b POSTs=$(lines "$C/posts"), want 2 (lead, then pr-hold)"
[ "$(lines "$C/why")" = 1 ] && ok || bad "H14b ready-why ran $(lines "$C/why") times, want 1 (_MC_HC_IN)"

# --- H15: the conductor's real source line -----------------------------------------------
newcase h15
src=$(grep -E '^[^#]*\. "\$H/bin/lib/mc-hold-comment\.sh"' "$DIR/bin/merge-conductor.sh" | head -n 1)
[ -n "$src" ] && ok || bad "H15 merge-conductor.sh has no source line for the lib"
if [ -z "${HC_LIB:-}" ] && [ -n "$src" ]; then
  env -u HARNESS -u MC_HOLD_COMMENT H="$DIR" MC_H="$C/h" MC_STATE_DIR="$C/h/state/merge-conductor" C="$C" SRC="$src" \
    ACTIONS=1 KILL=0 bash -c "$STUBS"'
eval "$SRC" || exit 9
mc_hold_comment "o/r#7" h1 dep-hold "waits on o/r#6"' >/dev/null 2>&1
  [ "$(lines "$C/posts")" = 1 ] && ok || bad "H15 the conductor-sourced lib did not post"
  [ -e "$C/h/locks/hold-comment-o_r_7_dep-hold.lock" ] && ok || bad "H15 no lock under the MC_H root: $(ls "$C/h/locks" 2>&1)"
elif [ -n "${HC_LIB:-}" ]; then
  bad "H15 skipped: HC_LIB overrides the conductor's lib"
fi

echo "conductor-hold-comment: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
