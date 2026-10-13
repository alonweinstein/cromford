#!/bin/bash
# tests/mc-hold-comment-contract.bh-3452-test.sh — the hold-comment CONTRACT
# slice (BH-3452, order 1 of BH-3436).
#
# The slice ships an interface and no behaviour, so what this pins is that the
# interface exists and is inert:
#   C1. sourcing bin/lib/mc-hold-comment.sh with no root returns non-zero and
#       defines nothing; with a root it returns 0.
#   C2. mc_hold_comment appends key<TAB>head<TAB>kind<TAB>reason to
#       MC_HOLD_COMMENT_TRACE and returns 0.
#   C3. MC_HOLD_COMMENT=0 returns 0 and writes nothing.
#   C4. it never fails the caller: unwritable trace path, no args.
#   C5. mc_hold_comment_clears answers for all ten kinds, one plain line each.
#   C6. it prints nothing and returns 1 for any other kind.
#   C7. bin/merge-conductor.sh's real source line loads the lib, right after
#       the tier2-autoenqueue source line.
#   C8. the composed lanes registry carries lib hold-comment and its knob.
#   C9. the lib posts nothing: no gh, curl, mc_pr_comment or _jobs_req.
# Run from anywhere: tests/mc-hold-comment-contract.bh-3452-test.sh   (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

LIB="$DIR/bin/lib/mc-hold-comment.sh"
CONDUCTOR="$DIR/bin/merge-conductor.sh"
mkdir -p "$T/h"
TAB=$(printf '\t')

[ -f "$LIB" ] && ok || bad "missing $LIB"

# Every case runs in a fresh bash with a scratch root and no worker env, so the
# lib's lib_env_apply read fails open and MC_HOLD_COMMENT is whatever we pass.
run() {
  env -u H -u MC_H -u MC_HOLD_COMMENT -u MC_HOLD_COMMENT_TRACE HARNESS="$T/h" \
    "$@"
}

# --- C1: empty root refuses ---------------------------------------------------
out=$(env -u HARNESS -u H -u MC_H bash -c '. "$1"; rc=$?; declare -F mc_hold_comment mc_hold_comment_clears; exit $rc' _ "$LIB" 2>&1)
rc=$?
[ "$rc" -ne 0 ] && ok || bad "C1 source with empty root returned 0"
[ -z "$out" ] && ok || bad "C1 empty root still defined or printed: $out"
out=$(run bash -c '. "$1" || exit 9; declare -F mc_hold_comment mc_hold_comment_clears >/dev/null || exit 8' _ "$LIB" 2>&1)
rc=$?
[ "$rc" -eq 0 ] && ok || bad "C1 source with HARNESS set rc=$rc: $out"

# --- C2: the trace seam appends one line per call -----------------------------
tr="$T/trace"
out=$(run MC_HOLD_COMMENT_TRACE="$tr" bash -c '. "$1" || exit 9; mc_hold_comment "o/r#7" abc123 ticket-hold "held for X"' _ "$LIB" 2>&1)
rc=$?
[ "$rc" -eq 0 ] && ok || bad "C2 mc_hold_comment rc=$rc: $out"
want="o/r#7${TAB}abc123${TAB}ticket-hold${TAB}held for X"
if [ -f "$tr" ]; then
  [ "$(wc -l < "$tr")" -eq 1 ] && ok || bad "C2 trace has $(wc -l < "$tr") lines, want 1"
  [ "$(cat "$tr")" = "$want" ] && ok || bad "C2 trace line is '$(cat "$tr")'"
else
  bad "C2 trace file not written"
fi
run MC_HOLD_COMMENT_TRACE="$tr" MC_HOLD_COMMENT=1 bash -c '. "$1" || exit 9; mc_hold_comment "o/r#8" def456 pr-hold "second"' _ "$LIB" >/dev/null 2>&1
[ -f "$tr" ] && [ "$(wc -l < "$tr")" -eq 2 ] && ok || bad "C2 second call did not append"

# --- C3: MC_HOLD_COMMENT=0 is a no-op -----------------------------------------
tr0="$T/trace0"
out=$(run MC_HOLD_COMMENT=0 MC_HOLD_COMMENT_TRACE="$tr0" bash -c '. "$1" || exit 9; mc_hold_comment "o/r#7" abc123 ticket-hold "held"' _ "$LIB" 2>&1)
rc=$?
[ "$rc" -eq 0 ] && ok || bad "C3 off rc=$rc: $out"
[ ! -e "$tr0" ] && ok || bad "C3 MC_HOLD_COMMENT=0 still wrote the trace"
[ -z "$out" ] && ok || bad "C3 off printed: $out"

# --- C4: never fails the caller -----------------------------------------------
out=$(run MC_HOLD_COMMENT_TRACE="$T/no/such/dir/t" bash -c '. "$1" || exit 9; mc_hold_comment k h ticket-hold r' _ "$LIB" 2>&1)
rc=$?
[ "$rc" -eq 0 ] && ok || bad "C4 unwritable trace rc=$rc: $out"
[ -z "$out" ] && ok || bad "C4 unwritable trace printed: $out"
out=$(run bash -c '. "$1" || exit 9; mc_hold_comment' _ "$LIB" 2>&1)
rc=$?
[ "$rc" -eq 0 ] && ok || bad "C4 no-args rc=$rc: $out"
out=$(run bash -c 'set -u; . "$1" || exit 9; mc_hold_comment' _ "$LIB" 2>&1)
rc=$?
[ "$rc" -eq 0 ] && ok || bad "C4 no-args under set -u rc=$rc: $out"

# --- C5: the ten kinds --------------------------------------------------------
KINDS="ticket-hold pr-hold hold-label lead lead-mergify dep-hold hotfix tightened provenance iron-law"
for k in $KINDS; do
  out=$(run bash -c '. "$1" || exit 9; mc_hold_comment_clears "$2"' _ "$LIB" "$k" 2>&1)
  rc=$?
  [ "$rc" -eq 0 ] && ok || bad "C5 clears $k rc=$rc"
  [ -n "$out" ] && [ "$(printf '%s\n' "$out" | wc -l)" -eq 1 ] && ok || bad "C5 clears $k not one non-empty line: '$out'"
  case "$out" in *—*) bad "C5 clears $k has an em dash: $out" ;; *) ok ;; esac
  case "$k" in
    ticket-hold) case "$out" in *RESUME*ticket*) ok ;; *) bad "C5 ticket-hold line: $out" ;; esac ;;
    pr-hold)     case "$out" in *RESUME*PR*) ok ;; *) bad "C5 pr-hold line: $out" ;; esac ;;
    hold-label)  case "$out" in *label*) ok ;; *) bad "C5 hold-label line: $out" ;; esac ;;
    iron-law)    case "$out" in *MERGE*) ok ;; *) bad "C5 iron-law line: $out" ;; esac ;;
  esac
done

# --- C6: anything else answers rc 1, nothing printed --------------------------
for k in main-red merges-off asked conductor block-gate ""; do
  out=$(run bash -c '. "$1" || exit 9; mc_hold_comment_clears "$2"' _ "$LIB" "$k" 2>&1)
  rc=$?
  [ "$rc" -eq 1 ] && ok || bad "C6 clears '$k' rc=$rc, want 1"
  [ -z "$out" ] && ok || bad "C6 clears '$k' printed: $out"
done

# --- C7: the conductor's real source line loads it ----------------------------
src_line=$(grep -nE '^[^#]*\. "\$H/bin/lib/mc-hold-comment\.sh"' "$CONDUCTOR" | head -n 1)
if [ -z "$src_line" ]; then
  bad "C7 no non-comment line in merge-conductor.sh sources mc-hold-comment.sh"
else
  ok
  n=${src_line%%:*}; line=${src_line#*:}
  out=$(env -u HARNESS -u MC_H -u MC_HOLD_COMMENT H="$DIR" bash -c 'eval "$1"; declare -F mc_hold_comment >/dev/null && declare -F mc_hold_comment_clears >/dev/null' _ "$line" 2>&1)
  rc=$?
  [ "$rc" -eq 0 ] && ok || bad "C7 conductor line did not define both functions: $out"
  prev=$(sed -n "$((n-2))p" "$CONDUCTOR")
  case "$prev" in
    *'. "$H/bin/lib/autoenqueue.sh"'*) ok ;;
    *) bad "C7 the source is not right after tier2-autoenqueue's (line $((n-2)): $prev)" ;;
  esac
  [ "$(sed -n "$((n-1))p" "$CONDUCTOR")" = "# shellcheck source=bin/lib/mc-hold-comment.sh" ] && ok \
    || bad "C7 no shellcheck source= line above the source"
fi

# --- C8: the registry carries the knob ----------------------------------------
# catalog/lanes.json is generated and git-ignored: compose it into scratch.
if HARNESS_TEST_SANDBOX=1 "$DIR/bin/lanes-build.sh" --root "$DIR" --to "$T/lanes.json" >"$T/lb.out" 2>&1; then
  ok
  jq -e '.libs[] | select(.id=="hold-comment" and .file=="bin/lib/mc-hold-comment.sh")
         | .knobs | length==1 and (.[0] | .env=="MC_HOLD_COMMENT" and .type=="int" and .default==1
           and .min==0 and .max==1 and .required==true)' "$T/lanes.json" >/dev/null \
    && ok || bad "C8 lanes registry has no lib hold-comment with knob MC_HOLD_COMMENT {int,1,0..1,required}"
else
  bad "C8 bin/lanes-build.sh failed: $(cat "$T/lb.out")"
fi

# --- C9: inert, nothing posts -------------------------------------------------
if [ -r "$LIB" ]; then
  hits=$(grep -vE '^[[:space:]]*#' "$LIB" | grep -nE '(^|[^A-Za-z_])gh[[:space:]]|curl|mc_pr_comment|_jobs_req' || true)
  [ -z "$hits" ] && ok || bad "C9 lib has a posting call: $hits"
else
  bad "C9 lib unreadable"
fi

echo "mc-hold-comment-contract: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
