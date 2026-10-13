#!/bin/bash
# tests/headbound-outcome-test.sh — the head-bound gate's OUTCOME, and the relay
# that carries its evidence off a pool builder.
#
# THE DEFECT THIS CLOSES (project-5 TK-419 / TK-290, 2026-09-12). A pool build
# drifted, bin/run-build.sh bought the re-review, and the re-review wrote no
# verdict file — a dead session, not a reviewer's BLOCK. The gate read that
# silence through the same `elif` as an explicit BLOCK, demoted to tier 2 with
# the note "not re-approved", and left reviewed-sha on the OLD head. Nothing
# downstream could tell the two apart: bin/merge-sweep.sh parked the PR on the
# sha mismatch and the conductor classified it HEAD_MOVED forever, because the
# one fact that distinguishes "a reviewer said no" from "nobody answered" was
# never written anywhere a reader could reach. On top of that bin/fly-pool.sh
# relayed neither headbound-review.md nor reviewed-sha nor e2e.md off the
# builder, so the findings that caused the demotion did not even exist on the
# hub.
#
# WHY DRIVEN AND NOT GREPPED. `grep -q no-verdict bin/run-build.sh` passes just
# as happily on a gate that writes the word on every path. What is under test is
# which of three words each shape of re-review produces, that a missing verdict
# file buys exactly ONE retry (and a BLOCK buys none), and that the demotion
# still happens for BOTH non-approvals — the gate must not be weakened by being
# made more talkative. The gate block is extracted VERBATIM from the shipped
# script by its markers, so a regression in the real lines fails here.
# Run from anywhere: tests/headbound-outcome-test.sh   (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
# BH-1625: the lane under test reads every verdict through bin/lib/verdict-parse.sh,
# which this suite's scratch harness / extracted block does not carry by itself.
# shellcheck source=tests/lib/verdict-fixture.sh
. "$(dirname "$0")/lib/verdict-fixture.sh" || exit 1
vpf_export || exit 1
. "$DIR/tests/lib/rb-all.sh" || exit 1
RB_ALL=$(rb_all "$DIR" "$T/run-build.all.sh")
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

# ============================================================================
# 1. bin/run-build.sh — the three outcomes
# ============================================================================
awk '/^# >>> head-bound approval/{f=1;next} /^# <<< head-bound approval/{exit} f' \
  "$RB_ALL" > "$T/gate.sh"
[ -s "$T/gate.sh" ] && ok || bad "could not extract the head-bound block from bin/run-build.sh — markers missing?"

# The gate re-runs the repo's suite on the moved head through HARNESS_SUITE_RUN,
# which lives in its own marked block and calls the stage timers. Extracted
# VERBATIM, like the gate itself.
awk '/^# >>> stage timing/{f=1;next} /^# <<< stage timing/{exit} f' \
  "$RB_ALL" > "$T/timing.sh"
[ -s "$T/timing.sh" ] && ok || bad "could not extract the stage-timing block — markers missing?"
awk '/^# >>> harness suite run/{f=1;next} /^# <<< harness suite run/{exit} f' \
  "$RB_ALL" > "$T/suite-run.sh"
[ -s "$T/suite-run.sh" ] && ok || bad "could not extract the harness-suite-run block — markers missing?"

REPO="$T/repo"
setup_repo() { # setup_repo <extra-commits>
  scratch_rm "$REPO"; mkdir -p "$REPO"
  ( cd "$REPO" || exit 1
    git init -q -b main
    git config user.email t@example.com; git config user.name tester
    echo one > a.txt; git add -A; git -c commit.gpgsign=false commit -qm "base"
  )
  rm -rf "$T/build"; mkdir -p "$T/build"
  ( cd "$REPO" && git rev-parse HEAD ) > "$T/build/review-head"
  if [ "${1:-0}" -gt 0 ]; then
    ( cd "$REPO" || exit 1
      echo fix >> a.txt; git add -A; git -c commit.gpgsign=false commit -qm "qa fix round" )
  fi
}

# The CC stub records lane, model and the RUN-FILE it was handed ($4) — the run
# file is how a reader tells the first call from the retry.
gate() { # gate <cc-verdict: APPROVE|BLOCK|none> [env assignments...]
  local v="$1"; shift
  : > "$T/cc-calls.txt"
  ( cd "$REPO" || exit 1
    env CC_VERDICT="$v" BUILD="$T/build" PROJECT=p KEY=K BASE=main BRANCH=b \
        REVIEW_MODEL=review-model TIER=1 QA_NOTE="" CC_SINK="$T/cc-calls.txt" "$@" \
    bash -c '
      set -uo pipefail
      STAMP() { echo TS; }
      CC() { printf "%s %s %s\n" "$1" "$2" "$4" >> "$CC_SINK"
             [ "$CC_VERDICT" = none ] || printf "findings\nVERDICT: %s\n" "$CC_VERDICT" > "$BUILD/headbound-review.md"; }
      . "$1"
      . "$2"
      . "$0"
      printf "TIER=%s|NOTE=%s|OUT=%s\n" "$TIER" "$QA_NOTE" "$(cat "$BUILD/headbound-outcome" 2>/dev/null)"
    ' "$T/gate.sh" "$T/timing.sh" "$T/suite-run.sh" 2>/dev/null )
}

# 1a. no drift at all: there is no head-bound question to answer, and the file
#     must say exactly that rather than be absent (absent is what a reader of an
#     OLD record sees, and it must not be confused with "this build was clean").
setup_repo 0
OUT=$(gate APPROVE)
grep -q 'OUT=n/a$' <<<"$OUT" && ok || bad "an unmoved head must record a BARE headbound-outcome=n/a (got: $OUT)"
[ -s "$T/cc-calls.txt" ] && bad "an unmoved head bought a re-review it did not need" || ok

# 1b. drift + APPROVE: reapproved, the tier stands, and the approval rebinds.
setup_repo 1
HEAD1=$(cd "$REPO" && git rev-parse HEAD)
OUT=$(gate APPROVE)
grep -q "OUT=reapproved@$HEAD1\$" <<<"$OUT" \
  && ok || bad "a re-approved head must record headbound-outcome=reapproved@<that head> (got: $OUT)"
grep -q '^TIER=1' <<<"$OUT" && ok || bad "a re-approved head must keep its tier (got: $OUT)"
[ "$(head -1 "$T/build/reviewed-sha" 2>/dev/null)" = "$HEAD1" ] \
  && ok || bad "a re-approved head must rebind reviewed-sha to the new head (got: $(cat "$T/build/reviewed-sha" 2>/dev/null))"
[ "$(wc -l < "$T/cc-calls.txt")" -eq 1 ] \
  && ok || bad "an APPROVE must buy exactly one review call (got: $(cat "$T/cc-calls.txt"))"

# 1c. drift + an explicit BLOCK: a reviewer ANSWERED. No retry — re-asking a
#     reviewer who already said no is the expensive way to get the same word —
#     and the outcome says BLOCK so the conductor can stop buying re-reviews.
setup_repo 1
HEAD1=$(cd "$REPO" && git rev-parse HEAD)
OUT=$(gate BLOCK)
grep -q "OUT=blocked@$HEAD1\$" <<<"$OUT" \
  && ok || bad "an explicit BLOCK must record headbound-outcome=blocked@<the head it judged> (got: $OUT)"
grep -q '^TIER=2' <<<"$OUT" && ok || bad "a blocked re-review must still demote to tier 2 (got: $OUT)"
grep -q 'not re-approved (BLOCK)' <<<"$OUT" \
  && ok || bad "the demotion note must say the verdict was a BLOCK (got: $OUT)"
[ "$(wc -l < "$T/cc-calls.txt")" -eq 1 ] \
  && ok || bad "a BLOCK must NOT be retried (calls: $(cat "$T/cc-calls.txt"))"

# 1d. drift + NO verdict file: a dead session, not a verdict. Exactly one retry,
#     onto its own run file, and if that is silent too the outcome is
#     `no-verdict` — a different word from `blocked`, with the SAME demotion.
setup_repo 1
HEAD1=$(cd "$REPO" && git rev-parse HEAD)
OUT=$(gate none)
grep -q "OUT=no-verdict@$HEAD1\$" <<<"$OUT" \
  && ok || bad "a silent re-review must record headbound-outcome=no-verdict@<that head> (got: $OUT)"
grep -q '^TIER=2' <<<"$OUT" && ok || bad "a silent re-review must still demote to tier 2 (got: $OUT)"
grep -q 'no verdict after retry' <<<"$OUT" \
  && ok || bad "the demotion note must say no verdict came back (got: $OUT)"
[ "$(wc -l < "$T/cc-calls.txt")" -eq 2 ] \
  && ok || bad "a missing verdict file must buy exactly ONE retry (calls: $(cat "$T/cc-calls.txt"))"
grep -q 'headbound-review-run.txt.2$' "$T/cc-calls.txt" \
  && ok || bad "the retry must write its own run file (calls: $(cat "$T/cc-calls.txt"))"
grep -q 'no verdict file' "$T/build/pipeline.log" 2>/dev/null \
  && ok || bad "the retry must say why it happened in pipeline.log"

# 1e. the retry lives inside the HEADBOUND_REREVIEW switch: off means no model
#     call at all, and the outcome still says nobody answered.
setup_repo 1
OUT=$(gate APPROVE HEADBOUND_REREVIEW=0)
grep -q 'OUT=no-verdict@' <<<"$OUT" && ok || bad "re-review off must still record no-verdict@<head> (got: $OUT)"
[ -s "$T/cc-calls.txt" ] && bad "HEADBOUND_REREVIEW=0 bought a review: $(cat "$T/cc-calls.txt")" || ok

# 1f. THE SHA IS THE POINT. An outcome that names no head outlives the head it
#     judged: a human pushes a fix on top of a BLOCKed head, the record still
#     reads "blocked", and a reader parks a head no reviewer has ever seen —
#     the same never-ending park this file exists to close, one commit further
#     along. So every word but `n/a` carries the head it was about, and the
#     conductor's mc_hb_blocks only fires when that sha IS the current head.
setup_repo 1
HEADB=$(cd "$REPO" && git rev-parse HEAD)
gate BLOCK >/dev/null
[ "$(cat "$T/build/headbound-outcome")" = "blocked@$HEADB" ] \
  && ok || bad "the outcome file must bind the word to the head (got: $(cat "$T/build/headbound-outcome"))"
# a human pushes a fix on top of the refused head
( cd "$REPO" || exit 1
  echo human >> a.txt; git add -A; git -c commit.gpgsign=false commit -qm "human fix on top of the blocked head" )
HEADC=$(cd "$REPO" && git rev-parse HEAD)
# shellcheck source=/dev/null
( export HARNESS="$T/h"; mkdir -p "$T/h/logs" "$T/h/state"
  . "$DIR/bin/lib/merge-conductor-lib.sh"
  HBO=$(cat "$T/build/headbound-outcome")
  mc_hb_blocks "$HBO" "$HEADB" || exit 1          # the head it judged: a block
  mc_hb_blocks "$HBO" "$HEADC" && exit 1          # the head after it: NOT a block
  exit 0 ) \
  && ok || bad "a BLOCK must park only the head it judged, never the commit pushed after it"

# ============================================================================
# 2. The ledger row carries the same word
# ============================================================================
awk '/^# >>> verdict artifact/{f=1} /^# <<< verdict artifact/{exit} f' \
  "$RB_ALL" | grep -q 'headbound' \
  && ok || bad "the verdict ledger row does not carry the head-bound outcome — a relay outage would erase it"

# ============================================================================
# 3. The relay: every load-bearing head-bound artifact leaves the builder
# ============================================================================
# bin/fly-pool.sh reaps a pool machine and bin/fly-results-ingest.sh reaps a
# dedicated builder. Both run on the HUB, and the hub is where merge-sweep.sh
# and the conductor read records — so an artifact that does not make the trip is
# an artifact the merge gate cannot see. merge-sweep.sh:291 treats an ABSENT
# e2e.md as "never ran" and merges; :332 falls back to the record's
# reviewed-sha. Those two are safety holes, not conveniences.
for A in reviewed-sha e2e.md headbound-review.md headbound-review-run.txt \
         harness-suite-head.txt refute-review.md evidence.md changed-files.txt \
         security-review-run.txt headbound-outcome; do
  grep -q "$A" "$DIR/bin/fly-pool.sh" \
    && ok || bad "bin/fly-pool.sh does not relay $A off a pool machine"
  grep -q "$A" "$DIR/bin/fly-results-ingest.sh" \
    && ok || bad "bin/fly-results-ingest.sh does not relay $A off a builder"
done

echo "headbound-outcome: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
