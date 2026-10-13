#!/bin/bash
# tests/review-bought.bh-3930-test.sh — BH-3930 contract slice (BH-3937): the
# names every review lane imports to stop paying for an unchanged PR head.
#
#   A0  bin/lib/review-bought.sh: review_bought with no jobs client loaded is
#       rc 1 (BH-3938; its reads are tests/review-bought-reads.bh-3930-test.sh),
#       REVIEW_DEDUPE=0 is rc 2, validates its args (rc 1), clears RB_*;
#       review_dedupe_on
#   A10 review_fp / lead_fp shape, the ~reason suffix, a bad reason dropped
#       with one log line
#   A11 bin/lib/call-guard.sh guards review-head and lead-head at K=1, the
#       catalog documents the same defaults, review/mc-rereview/lead-review
#       keep their K
#   A12 review_skip_log writes the review_skip_unchanged literal
#   A13 the lib has no side effect at source time and survives a double source
#   A14 catalog/lanes.d/_lib.review-bought.json carries the two knobs
#
# Run from anywhere: tests/review-bought.bh-3930-test.sh (exit 0 = pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }

LIB="$DIR/bin/lib/review-bought.sh"
S=0123456789abcdef0123456789abcdef01234567
H="$T/h"; mkdir -p "$H"

# rbq <shell text> — run against a freshly sourced lib, HARNESS=$H, knobs unset
rbq() {
  ( unset REVIEW_DEDUPE REVIEW_DEDUPE_REBUY_AFTER RB_SOURCE RB_WORD RB_CLASS
    export HARNESS="$H"
    . "$LIB" || exit 9
    eval "$1" )
}

# --- A0. the call contract with no jobs client --------------------------------
# rbq loads no jobs client, so a valid call cannot read and answers rc 1 (buy
# the review); the kill switch answers rc 2 before it looks for one.
out=$(rbq "RB_SOURCE=x RB_WORD=x RB_CLASS=x; review_bought o/r 7 $S; rc=\$?
           printf '%s|%s|%s|%s' \"\$rc\" \"\$RB_SOURCE\" \"\$RB_WORD\" \"\$RB_CLASS\"")
[ "$out" = "1|||" ] && ok || bad "A0a valid call, no jobs client: want '1|||' (rc 1, RB_* cleared), got '$out'"
out=$(rbq "RB_SOURCE=x RB_WORD=x RB_CLASS=x; REVIEW_DEDUPE=0 review_bought o/r 7 $S; rc=\$?
           printf '%s|%s|%s|%s' \"\$rc\" \"\$RB_SOURCE\" \"\$RB_WORD\" \"\$RB_CLASS\"")
[ "$out" = "2|||" ] && ok || bad "A0a REVIEW_DEDUPE=0: want '2|||' (rc 2, RB_* cleared), got '$out'"
for c in "--class lead" "--class review" "--except-builder" "--class lead --except-builder"; do
  rbq "review_bought o/r 7 $S $c" >/dev/null; rc=$?
  [ "$rc" = 1 ] && ok || bad "A0a review_bought o/r 7 <sha> $c, no jobs client: rc $rc, want 1"
  rbq "REVIEW_DEDUPE=0 review_bought o/r 7 $S $c" >/dev/null; rc=$?
  [ "$rc" = 2 ] && ok || bad "A0a REVIEW_DEDUPE=0 review_bought o/r 7 <sha> $c: rc $rc, want 2"
done
for args in "bad 7 $S" "o/r 7x $S" "o/r 7 ${S:0:12}" "o/r 7 $S --class nope" \
            "o/r 7 $S --bogus" "o/r 7 $(printf '%s' "$S" | tr a-f A-F)" "o/r '' $S" \
            "'o/r x' 7 $S" "o/r 7 $S --class"; do
  rbq "RB_WORD=x; review_bought $args; rc=\$?; printf '%s|%s' \"\$rc\" \"\$RB_WORD\"" >"$T/out" 2>/dev/null
  [ "$(cat "$T/out")" = "1|" ] && ok || bad "A0b review_bought $args: want '1|', got '$(cat "$T/out")'"
done
grep -q 'rc 0 = covered' "$LIB" && grep -q 'rc 2 = miss' "$LIB" && grep -q 'rc 1 = ' "$LIB" \
  && ok || bad "A0 the lib does not state the rc 0/1/2 return contract"

rbq "REVIEW_DEDUPE=0 review_dedupe_on" && bad "A0c REVIEW_DEDUPE=0: review_dedupe_on is true" || ok
rbq "review_dedupe_on" && ok || bad "A0c unset REVIEW_DEDUPE: review_dedupe_on is false"
err=$(rbq "unset -f lib_env_apply 2>/dev/null; review_dedupe_on" 2>&1 >/dev/null); rc=$?
[ "$rc" = 0 ] && [ -z "$err" ] && ok || bad "A0c no lib_env_apply: rc $rc stderr '$err'"
# lib_env_apply runs once per process with the lib id, and its answer is read
out=$(rbq "lib_env_apply() { echo \"\$1\" >> '$T/lea'; REVIEW_DEDUPE=0; }
           review_dedupe_on; a=\$?; REVIEW_DEDUPE=1; review_dedupe_on; printf '%s %s' \"\$a\" \"\$?\"")
[ "$out" = "1 0" ] && ok || bad "A0c the settings row is not applied: got '$out', want '1 0'"
[ "$(cat "$T/lea" 2>/dev/null)" = "review-bought" ] && ok || bad "A0c lib_env_apply calls: '$(cat "$T/lea" 2>/dev/null)', want one 'review-bought'"

# review_rebuy_after: the operator's epoch, 0 = off; not a whole number is off + one log line
got=$(rbq "review_rebuy_after");                                  [ "$got" = 0 ] && ok || bad "A0d unset: '$got', want 0"
got=$(rbq "REVIEW_DEDUPE_REBUY_AFTER=1759500000 review_rebuy_after"); [ "$got" = 1759500000 ] && ok || bad "A0d set: '$got'"
rm -f "$H/logs/review-bought.log"
got=$(rbq "REVIEW_DEDUPE_REBUY_AFTER=soon review_rebuy_after");   [ "$got" = 0 ] && ok || bad "A0d 'soon': '$got', want 0"
[ "$(grep -c "REVIEW_DEDUPE_REBUY_AFTER 'soon'" "$H/logs/review-bought.log" 2>/dev/null)" = 1 ] && ok || bad "A0d 'soon' left no log line"
rm -f "$H/logs/review-bought.log" "$T/lea"
got=$(rbq "lib_env_apply() { echo \"\$1\" >> '$T/lea'; REVIEW_DEDUPE_REBUY_AFTER=1759600000; }
           review_rebuy_after; review_dedupe_on")
[ "$got" = 1759600000 ] && [ "$(cat "$T/lea" 2>/dev/null)" = review-bought ] && ok \
  || bad "A0d the settings row: '$got', lib_env_apply calls '$(cat "$T/lea" 2>/dev/null)'"

# --- A10. the per-head fingerprints ------------------------------------------
L="$H/logs/review-bought.log"
for p in review lead; do
  rm -f "$L"
  got=$(rbq "${p}_fp o/r 7 $S");          [ "$got" = "$p:o/r#7@$S" ] && ok || bad "A10 ${p}_fp: '$got'"
  got=$(rbq "${p}_fp o/r 7 $S rereq");    [ "$got" = "$p:o/r#7@$S~rereq" ] && ok || bad "A10 ${p}_fp rereq: '$got'"
  got=$(rbq "${p}_fp o/r 7 $S rebuy1759500000"); [ "$got" = "$p:o/r#7@$S~rebuy1759500000" ] && ok || bad "A10 ${p}_fp rebuy<epoch>: '$got'"
  got=$(rbq "${p}_fp o/r 7 $S ''");       [ "$got" = "$p:o/r#7@$S" ] && ok || bad "A10 ${p}_fp empty reason: '$got'"
  [ -e "$L" ] && bad "A10 ${p}_fp: a good or empty reason wrote a log line" || ok
  got=$(rbq "${p}_fp o/r 7 $S 'Bad Reason!'"); [ "$got" = "$p:o/r#7@$S" ] && ok || bad "A10 ${p}_fp bad reason: '$got'"
  n=$(wc -l < "$L" 2>/dev/null || echo 0)
  [ "$n" = 1 ] && grep -q "dropped bad fp reason 'Bad Reason!' for o/r#7" "$L" && ok \
    || bad "A10 ${p}_fp bad reason: log has $n lines, want 1 naming the reason"
  for r in abcdefghijklmnopqrstuvwxy 'a~b' 'a#b' 'a b' Rereq; do
    got=$(rbq "${p}_fp o/r 7 $S '$r'"); [ "$got" = "$p:o/r#7@$S" ] && ok || bad "A10 ${p}_fp '$r' kept: '$got'"
  done
done
# no harness root: the reason is still dropped, nothing is written anywhere
got=$( ( unset HARNESS H; . "$LIB"; review_fp o/r 7 "$S" 'Bad!' ) 2>&1 ); rc=$?
[ "$rc" = 0 ] && [ "$got" = "review:o/r#7@$S" ] && ok || bad "A10 no HARNESS: rc $rc out '$got'"

# --- A11. the guard stages ----------------------------------------------------
cgq() {
  ( unset CALL_GUARD CALL_GUARD_STAGES CALL_GUARD_MAX_MAP AGENT_CALL_GUARD_STAGE
    export HARNESS="$T/cgh"; mkdir -p "$HARNESS"
    . "$DIR/bin/lib/call-guard.sh" || exit 9
    eval "$1" )
}
for s in review-head lead-head; do
  cgq "call_guard_enabled $s" && ok || bad "A11 stage $s is not guarded by default"
  k=$(cgq "call_guard_max $s"); [ "$k" = 1 ] && ok || bad "A11 K for $s is '$k', want 1"
done
for kv in review=2 mc-rereview=5 lead-review=2; do
  k=$(cgq "call_guard_max ${kv%=*}"); [ "$k" = "${kv#*=}" ] && ok || bad "A11b K for ${kv%=*} is '$k', want ${kv#*=}"
done
CAT="$DIR/catalog/lanes.d/_lib.call-guard.json"
for pair in "CALL_GUARD_STAGES:CALL_GUARD_STAGES_DEFAULT" "CALL_GUARD_MAX_MAP:CALL_GUARD_MAX_MAP_DEFAULT"; do
  c=$(jq -r --arg e "${pair%%:*}" '.libs[0].knobs[] | select(.env==$e) | .default' "$CAT")
  v=$(cgq "printf %s \"\$${pair#*:}\"")
  [ -n "$v" ] && [ "$c" = "$v" ] && ok || bad "A11 catalog ${pair%%:*} '$c' != code '$v'"
done

# --- A12. the skip line -------------------------------------------------------
rbq "RB_SOURCE=hist RB_WORD=APPROVE review_skip_log '$T/l' o/r 7 $S autopilot"; rc=$?
[ "$rc" = 0 ] && grep -qE "^[0-9]{4}-[0-9]{2}-[0-9]{2} [0-9:]{8}Z review_skip_unchanged o/r#7@${S:0:12} lane=autopilot by=hist/APPROVE\$" "$T/l" \
  && ok || bad "A12 skip line: rc $rc, got '$(cat "$T/l" 2>/dev/null)'"
rbq "review_skip_log '$T/l2' o/r 7 $S mc"; rc=$?
[ "$rc" = 0 ] && grep -q "review_skip_unchanged o/r#7@${S:0:12} lane=mc by=/\$" "$T/l2" && ok || bad "A12 unset RB_*: rc $rc '$(cat "$T/l2" 2>/dev/null)'"
rbq "review_skip_log '$T/nodir/x/l' o/r 7 $S mc" 2>"$T/err"; rc=$?
[ "$rc" = 0 ] && [ ! -s "$T/err" ] && ok || bad "A12 unwritable log: rc $rc stderr '$(cat "$T/err")'"

# --- A13. no side effect at source time ---------------------------------------
E="$T/empty"; mkdir -p "$E"
out=$( ( export HARNESS="$E"; cd "$E" || exit 9; . "$LIB"; . "$LIB"
         type review_bought review_fp lead_fp review_skip_log review_dedupe_on >/dev/null || echo MISSING ) 2>&1 )
[ -z "$out" ] && [ -z "$(ls -A "$E")" ] && ok || bad "A13 double source printed '$out' / created '$(ls -A "$E")'"
out=$(rbq "_RB_ENV_SET=1; REVIEW_DEDUPE=0; . '$LIB'; review_dedupe_on && echo on || echo off")
[ "$out" = off ] && ok || bad "A13 a double source reset the memo / env: '$out'"
out=$(rbq "RB_SOURCE=hist RB_WORD=APPROVE RB_CLASS=approve; . '$LIB'; printf '%s|%s|%s' \"\$RB_SOURCE\" \"\$RB_WORD\" \"\$RB_CLASS\"")
[ "$out" = "hist|APPROVE|approve" ] && ok || bad "A13 a double source cleared a caller's RB_*: '$out'"

# --- A14. the catalog knobs ---------------------------------------------------
RC="$DIR/catalog/lanes.d/_lib.review-bought.json"
q() { jq -r --arg e "$1" ".libs[] | select(.id==\"review-bought\") | .knobs[] | select(.env==\$e) | $2" "$RC" 2>/dev/null; }
[ "$(jq -r '.libs[0].file' "$RC" 2>/dev/null)" = bin/lib/review-bought.sh ] && ok || bad "A14 lib file"
[ "$(q REVIEW_DEDUPE '"\(.type) \(.default) \(.zero_means)"')" = "int 1 off" ] && ok || bad "A14 REVIEW_DEDUPE: '$(q REVIEW_DEDUPE '"\(.type) \(.default) \(.zero_means)"')'"
[ "$(q REVIEW_DEDUPE_REBUY_AFTER '"\(.type) \(.default) \(.zero_means)"')" = "int 0 off" ] && ok || bad "A14 REVIEW_DEDUPE_REBUY_AFTER: '$(q REVIEW_DEDUPE_REBUY_AFTER '"\(.type) \(.default) \(.zero_means)"')'"
# catalog/lanes.json is git-ignored (BH-1247): compose it the way lanes_json_path does
HARNESS_TEST_SANDBOX=1 "$DIR/bin/lanes-build.sh" --root "$DIR" --to "$T/lanes.json" >/dev/null 2>&1
jq -e '.libs[] | select(.id=="review-bought" and .file=="bin/lib/review-bought.sh")' "$T/lanes.json" >/dev/null 2>&1 \
  && ok || bad "A14 the composed registry has no review-bought lib"

echo "review-bought.bh-3930: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
