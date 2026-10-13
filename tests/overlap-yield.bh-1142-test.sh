#!/bin/bash
# tests/overlap-yield.bh-1142-test.sh — BH-1142 items 3 and 4, the two holes
# the #717 review found in bin/run-build.sh's PRIORITY YIELD.
#
#   item 3: a sibling whose urgency came from HOTFIX=1 in ITS environment read
#           as rank 2 to the requester (only its ticket-meta.json was read), so
#           a rank-1 build evicted a hotfix. Each build now records its own rank
#           in $BUILD/priority-rank, and the requester takes the lower of that
#           and the meta rank. Y1-Y4.
#   item 4: a sibling already past its last checkpoint (YIELD_CHECK review)
#           can never honour a YIELD, yet the requester's RESULT promised it
#           would. YIELD_CHECK review now leaves $BUILD/YIELD_CLOSED, and the
#           request half neither writes a marker nor changes the wake sentence
#           for a closed sibling. Y5-Y8.
#
# Same method as tests/overlap-yield-test.sh: the `# >>> priority yield` and
# `# >>> overlap wait` blocks are lifted out of the flattened pipeline
# (tests/lib/rb-all.sh) and executed with the REAL bin/lib/hotfix-lib.sh.
# No network, no gh, no LLM.
# Run from anywhere: HARNESS_TEST_SANDBOX=1 bash tests/overlap-yield.bh-1142-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }
unset HOTFIX HOTFIX_LANE HOTFIX_LABEL MAIN_RED_LABEL PRIORITY_YIELD JOB_ID 2>/dev/null || true

. "$DIR/tests/lib/rb-all.sh" || exit 1
SRC=$(rb_all "$DIR" "$T/run-build.all.sh") || exit 1
cut_block() { # cut_block <marker-word...> <outfile>
  awk -v n="$1" 'index($0,"# >>> " n)==1{f=1;next} index($0,"# <<< " n)==1{exit} f' "$SRC" > "$2"
}
cut_block "overlap wait"   "$T/wait.sh"
cut_block "priority yield" "$T/yield.sh"
for B in wait yield; do
  [ -s "$T/$B.sh" ] && bash -n "$T/$B.sh" 2>/dev/null && ok \
    || bad "could not extract a parseable '$B' block from bin/run-build.sh"
done

H="$T/h"
WAKE_OLD="the sibling build releases its claim (it writes a RESULT, or state/claims/tproj/ ages it out at 4h) and the next triage tick re-offers TK-1"
CONFLICT_MSG="CONFLICT with tproj-TK-9-202609171200: a.ts ~ a.ts"

mk_meta() { # mk_meta <file> <label|->
  case "$2" in
    -) printf '{"title":"x","labels":[]}\n' > "$1" ;;
    *) printf '{"title":"x","labels":[{"name":"%s"}]}\n' "$2" > "$1" ;;
  esac
}
mk_case() { # mk_case <candidate-label|-> <sibling-label|-> — rebuilds the tree
  scratch_rm "$H" 2>/dev/null
  mkdir -p "$H/bin/lib" "$H/builds" "$H/logs" "$H/flags" "$H/env" "$H/state/claims/tproj"
  : > "$H/env/global.env"
  cp "$DIR/bin/lib/hotfix-lib.sh" "$H/bin/lib/hotfix-lib.sh"
  cat > "$H/bin/conflict-check.sh" <<'SH'
#!/bin/bash
printf '%s\n' "${CMSG_OUT-}"
exit 1
SH
  chmod +x "$H/bin/conflict-check.sh"
  CAND="$H/builds/tproj-TK-1-202609171100"
  SIB="$H/builds/tproj-TK-9-202609171200"
  mkdir -p "$CAND" "$SIB"
  : > "$CAND/pipeline.log"
  mk_meta "$CAND/ticket-meta.json" "$1"
  mk_meta "$SIB/ticket-meta.json" "$2"
}

# RACE_CLOSE=1 makes STAMP close the sibling the first time it is called after
# $SIBD is known — which is the `at=$(STAMP)` inside the YIELD write itself, so
# the sibling passes its last checkpoint between the guard and the write (Y8).
cat > "$T/drive-wait.sh" <<'SH'
set -uo pipefail
STAMP() {
  if [ -n "${RACE_CLOSE:-}" ] && [ -n "${SIBD:-}" ]; then : > "$SIBD/YIELD_CLOSED"; fi
  echo "2026-09-23 00:00:00Z"
}
RESULT() { echo "$*" > "$BUILD/RESULT"; }
# shellcheck source=/dev/null
[ -r "$HARNESS/bin/lib/hotfix-lib.sh" ] && . "$HARNESS/bin/lib/hotfix-lib.sh"
. "$YIELD_BLOCK"
. "$WAIT_BLOCK"
SH
run_wait() { # run_wait [env...] -> rc
  rm -f "$CAND/RESULT" "$CAND/overlap-defer.txt"
  ( env HARNESS="$H" PROJECT=tproj KEY=TK-1 BUILD="$CAND" ALERTS="$H/logs/ALERTS.log" \
        OVERLAP_WAIT_SECS=0 CMSG_OUT="$CONFLICT_MSG" \
        YIELD_BLOCK="$T/yield.sh" WAIT_BLOCK="$T/wait.sh" "$@" \
    bash "$T/drive-wait.sh" >/dev/null 2>&1 )
}
wake_of() { sed -n 's/^WAKE: //p' "$CAND/overlap-defer.txt" 2>/dev/null; }
no_yield() { # no_yield <label>
  [ -f "$SIB/YIELD" ] && bad "$1: a YIELD must NOT be written ($(cat "$SIB/YIELD"))" || ok
  [ "$(wake_of)" = "$WAKE_OLD" ] && ok || bad "$1: overlap-defer.txt wake must be today's 4h sentence — got: $(wake_of)"
  grep -qF "wakes when $WAKE_OLD" "$CAND/RESULT" 2>/dev/null && ok \
    || bad "$1: the RESULT must carry the 4h sentence: $(cat "$CAND/RESULT" 2>/dev/null)"
}
yields() { # yields <label>
  [ -f "$SIB/YIELD" ] && ok || bad "$1: a YIELD must be written"
  case "$(wake_of)" in *"yields at its next checkpoint"*) ok ;;
    *) bad "$1: the wake sentence must name the yield, got: $(wake_of)" ;; esac
}

# ══ Y1 a rank-1 build does not evict a sibling whose rank 0 came from its env ══
mk_case fix-main-red -; printf '0\n' > "$SIB/priority-rank"
run_wait; RC=$?
[ "$RC" = 3 ] && ok || bad "Y1 the deferral must still exit 3 (rc=$RC)"
no_yield "Y1 main-red (1) vs env-hotfix sibling (priority-rank 0)"

# ══ Y2 equal ranks: HOTFIX=1 vs an env-hotfix sibling ═══════════════════════
mk_case - -; printf '0\n' > "$SIB/priority-rank"
run_wait HOTFIX=1
no_yield "Y2 hotfix (0) vs env-hotfix sibling (0)"

# ══ Y3 every build records its own rank, env HOTFIX included ════════════════
mk_case - -; run_wait HOTFIX=1
[ "$(cat "$CAND/priority-rank" 2>/dev/null)" = 0 ] && ok \
  || bad "Y3 HOTFIX=1 must record priority-rank 0, got '$(cat "$CAND/priority-rank" 2>/dev/null)'"
mk_case - -; run_wait
[ "$(cat "$CAND/priority-rank" 2>/dev/null)" = 2 ] && ok \
  || bad "Y3 a plain build must record priority-rank 2, got '$(cat "$CAND/priority-rank" 2>/dev/null)'"
mk_case fix-main-red -; run_wait
[ "$(cat "$CAND/priority-rank" 2>/dev/null)" = 1 ] && ok \
  || bad "Y3 a main-red meta must record priority-rank 1, got '$(cat "$CAND/priority-rank" 2>/dev/null)'"
# ...and the recorded rank is what a LATER requester reads: a HOTFIX=1 build
# that publishes its rank is not evicted by a main-red one (end to end).
mk_case - -
( env HARNESS="$H" PROJECT=tproj KEY=TK-9 BUILD="$SIB" HOTFIX=1 YIELD_BLOCK="$T/yield.sh" \
    bash -c '. "$HARNESS/bin/lib/hotfix-lib.sh"; STAMP() { :; }; . "$YIELD_BLOCK"' >/dev/null 2>&1 )
mk_meta "$CAND/ticket-meta.json" fix-main-red
run_wait
no_yield "Y3 main-red (1) vs a sibling that recorded its own HOTFIX=1"

# ══ Y4 garbage in priority-rank changes nothing ═════════════════════════════
for G in x '' 7 $'0\n0' ' 0' -1; do
  mk_case - -; printf '%s' "$G" > "$SIB/priority-rank"
  run_wait HOTFIX=1
  yields "Y4 sibling priority-rank '$G' is ignored, meta rank 2 stands vs HOTFIX=1"
  mk_case - -; printf '%s' "$G" > "$SIB/priority-rank"
  run_wait
  no_yield "Y4 sibling priority-rank '$G', plain candidate"
done
# The file can only RAISE urgency: a stale '2' does not demote a hotfix label.
mk_case fix-main-red hotfix; printf '2\n' > "$SIB/priority-rank"
run_wait
no_yield "Y4 priority-rank 2 does not demote a hotfix-labelled sibling"

# ══ Y5 a sibling past its last checkpoint is promised nothing ═══════════════
mk_case - -; : > "$SIB/YIELD_CLOSED"
run_wait HOTFIX=1; RC=$?
[ "$RC" = 3 ] && ok || bad "Y5 the deferral must still exit 3 (rc=$RC)"
no_yield "Y5 hotfix vs a sibling past YIELD_CHECK review"
grep -q 'past its last yield checkpoint' "$CAND/pipeline.log" && ok \
  || bad "Y5 one pipeline.log line is owed: $(cat "$CAND/pipeline.log")"

# ══ Y6 positive control: the same pair, not closed, still yields ════════════
mk_case - -
run_wait HOTFIX=1
yields "Y6 hotfix vs an open plain sibling"
grep -qE '^requested_by=TK-1 rank=0 ' "$SIB/YIELD" 2>/dev/null && ok \
  || bad "Y6 YIELD content: $(cat "$SIB/YIELD" 2>/dev/null)"

# ══ Y7 only boundary 3 closes the build ═════════════════════════════════════
cat > "$T/drive-check.sh" <<'SH'
set -euo pipefail
STAMP() { echo "2026-09-23 00:00:00Z"; }
RESULT() { echo "$*" > "$BUILD/RESULT"; }
. "$YIELD_BLOCK"
YIELD_CHECK "$STAGE"
echo ran-on > "$BUILD/after.txt"
SH
for S in plan execute review; do
  mk_case - -
  ( env HARNESS="$H" PROJECT=tproj KEY=TK-9 BUILD="$SIB" WT="$T" BRANCH=x STAGE="$S" \
      YIELD_BLOCK="$T/yield.sh" bash "$T/drive-check.sh" >/dev/null 2>&1 ); RC=$?
  [ "$RC" = 0 ] && [ -f "$SIB/after.txt" ] && ok || bad "Y7 YIELD_CHECK $S with no marker must run on under set -e (rc=$RC)"
  if [ "$S" = review ]; then
    [ -f "$SIB/YIELD_CLOSED" ] && ok || bad "Y7 YIELD_CHECK review must leave YIELD_CLOSED"
  else
    [ -f "$SIB/YIELD_CLOSED" ] && bad "Y7 YIELD_CHECK $S must not close the build" || ok
  fi
done

# ══ Y8 the sibling closes between the guard and the write ═══════════════════
# The marker lands, but the requester re-reads YIELD_CLOSED after writing it
# and so must not promise a yield the sibling will never check for.
mk_case - -
run_wait HOTFIX=1 RACE_CLOSE=1
[ -f "$SIB/YIELD_CLOSED" ] && ok || bad "Y8 the race fixture never closed the sibling"
[ "$(wake_of)" = "$WAKE_OLD" ] && ok || bad "Y8 a sibling that closed during the write must not be promised a yield: $(wake_of)"
grep -qF "wakes when $WAKE_OLD" "$CAND/RESULT" 2>/dev/null && ok \
  || bad "Y8 the RESULT must carry the 4h sentence: $(cat "$CAND/RESULT" 2>/dev/null)"

echo "overlap-yield.bh-1142: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
