#!/bin/bash
# tests/preplan-adopt.bh-776-test.sh — the BUILDER half of BH-658: every branch
# of the pre-plan adopt saying out loud what it did, and the evidence row that
# renders the answer onto the PR page.
# Run from anywhere: tests/preplan-adopt.bh-776-test.sh   (exit 0 = all pass)
#
# THE NAME. The ticket calls this file tests/preplan-adopt-test.sh; it ships
# under the per-ticket form because bin/lib/test-home-lib.sh:th_is_per_ticket
# only recognises `<area>.bh-776-test.sh`, and the execute stage would reroute
# the plain name anyway.
#
# WHY THIS FILE AND NOT tests/preplan-relay-test.sh (BH-776). The ticket names
# tests/preplan-relay-test.sh for "the build records PREPLAN_HIT", but that file
# belongs to the publish/relay child (#775) — run-preplan.sh publishing,
# fly-pool.sh push_preplan, the jobs-client verbs. So THIS suite carries the
# builder half on its own and the two slices never race on one file. The cases
# below are round 1's sections 7 and 8 (origin/ticket/bh-658), renumbered.
#
# THE DEFECT IT PINS (BH-658). The adopt block was silent: "adopted" and
# "skipped" were indistinguishable from outside — 0 of 1052 build records on
# box-project-4-1 carried a PREPLAN_ line while that box's own plans/ held 58
# plan dirs. And a pre-plan's board fingerprint was copied into $BUILD, where
# the resume-stale gate would read it, find the thread had moved, and exit
# PLAN_STALE — ending a whole Fly machine for a condition whose correct answer
# is simply "plan fresh". So: thread staleness is judged HERE, a stale pre-plan
# is discarded and the run continues, and EVERY branch writes
# $BUILD/preplan-outcome (HIT / STALE / MISS / OFF, each with its reason) plus
# one pipeline.log line that bin/evidence-summary.sh renders into the PR body.
#
# HOW IT IS DRIVEN. The adopt block is EXTRACTED VERBATIM from the shipped
# bin/run-build.sh by its own markers (a paraphrase would pass on a version that
# never shipped) and driven against a real scratch git repo, the same way
# tests/preplan-speculative-test.sh drives preplan_check. Every assertion reads
# a file the code wrote — $BUILD/preplan-outcome, pipeline.log, the presence of
# $BUILD/plan.md, the rendered evidence table and its --json — never source text.
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
. "$DIR/tests/lib/rb-all.sh" || exit 1
RB_ALL=$(rb_all "$DIR" "$T/run-build.all.sh")
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

mkdir -p "$T/bin/lib" "$T/env" "$T/flags" "$T/logs" "$T/plans" "$T/repos" "$T/builds"
cp "$DIR/bin/evidence-summary.sh" "$DIR/bin/size-scope.sh" "$T/bin/"
cp "$DIR/bin/lib/preplan-lib.sh" "$T/bin/lib/"
: > "$T/env/global.env"

echo "--- 1. the adopt block (extracted verbatim from bin/run-build.sh)"
awk '/^# >>> preplan adopt$/{f=1} /^# <<< preplan adopt$/{exit} f' "$RB_ALL" > "$T/adopt.sh"
[ -s "$T/adopt.sh" ] && ok || bad "could not extract the preplan adopt block from bin/run-build.sh"

R="$T/repo"; mkdir -p "$R/src/lib" "$R/src/ui"
git -C "$R" init -q -b main
git -C "$R" config user.email t@t; git -C "$R" config user.name t
echo a > "$R/src/lib/pay.ts"; echo b > "$R/src/ui/card.tsx"
git -C "$R" add -A; git -C "$R" commit -qm one
BASE0=$(git -C "$R" rev-parse main)

FP_NOW='2026-09-17T12:00:00Z|2026-09-17T12:00:00Z||4'
mkplan() { # mkplan <ticket-fp> — the hub-side pre-plan dir for AB-1
  scratch_rm "$T/plans/proj-AB-1"; mkdir -p "$T/plans/proj-AB-1"
  printf '## Scope\nTouch src/lib/pay.ts.\nSIZE: S\n' > "$T/plans/proj-AB-1/plan.md"
  printf '%s\n' "$BASE0" > "$T/plans/proj-AB-1/base-sha"
  printf 'src/lib/pay.ts\n' > "$T/plans/proj-AB-1/planned-files.txt"
  printf 'AB-1\n' > "$T/plans/proj-AB-1/key"
  [ -n "${1:-}" ] && printf '%s\n' "$1" > "$T/plans/proj-AB-1/ticket-fp"
  return 0
}
RUN_N=0
adopt() { # adopt <fp-before> [VAR=VAL ...] -> a fresh $BUILD, left in $BLD
  RUN_N=$((RUN_N+1))
  BLD="$T/builds/run-$RUN_N"; scratch_rm "$BLD"; mkdir -p "$BLD"
  ( HARNESS="$T"; PROJECT=proj; KEY=AB-1; BUILD="$BLD"; WT="$R"; BASE=main
    FP_BEFORE="$1"; shift
    export PREPLAN_RELAY_DIR="$T/relay-none"
    [ $# -gt 0 ] && export "$@"
    STAMP() { printf '2026-09-17 12:00:00Z'; }
    BB() { printf 'BB %s\n' "$1" >> "$BUILD/bb.log"; }
    # shellcheck source=/dev/null
    . "$T/adopt.sh" ) >/dev/null 2>&1
}
outcome() { cat "$BLD/preplan-outcome" 2>/dev/null; }
# EXACTLY ONE PREPLAN_ LINE PER RUN (the operator's review of #824, item 4). Two lines
# would mean a branch fell through into another and the evidence row is reading
# one answer while the log tells a second story.
one_line() { # one_line <case>
  [ "$(grep -c 'PREPLAN_' "$BLD/pipeline.log" 2>/dev/null)" = 1 ] && ok \
    || bad "$1 must log exactly one PREPLAN_ line per run (got: $(grep -c 'PREPLAN_' "$BLD/pipeline.log" 2>/dev/null))"
}

# (i) fresh base, same thread -> HIT
mkplan "$FP_NOW"; adopt "$FP_NOW"
case "$(outcome)" in HIT*) ok ;; *) bad "a fresh pre-plan on an unmoved thread must be a HIT (got: $(outcome))" ;; esac
[ -s "$BLD/plan.md" ] && ok || bad "a HIT must land the plan where the PLAN checkpoint reads it"
[ -s "$BLD/ticket-fp" ] && ok || bad "a HIT must carry ticket-fp, or it deletes the thread-stability gate"
grep -q 'PREPLAN_HIT' "$BLD/pipeline.log" && ok || bad "a HIT must be in pipeline.log (log: $(cat "$BLD/pipeline.log" 2>/dev/null))"
one_line "a HIT"

# (ii) the thread moved since the plan was written -> STALE, and this build
# PLANS FRESH in the same run (never PLAN_STALE, which would waste the machine)
mkplan '2026-09-17T09:00:00Z|2026-09-17T09:00:00Z||1'; adopt "$FP_NOW"
case "$(outcome)" in STALE*thread*) ok ;; *) bad "a pre-plan written against an OLDER thread must be STALE (got: $(outcome))" ;; esac
[ ! -e "$BLD/plan.md" ] && ok || bad "a stale pre-plan must NOT be adopted"
[ ! -e "$BLD/ticket-fp" ] && ok \
  || bad "a discarded pre-plan must leave no ticket-fp — the resume-stale gate would exit PLAN_STALE on it"
grep -q 'PREPLAN_STALE' "$BLD/pipeline.log" && ok || bad "a thread-stale discard must be in pipeline.log"
one_line "a thread-stale discard"

# (iii) no pre-plan anywhere -> MISS, said out loud
scratch_rm "$T/plans/proj-AB-1"; adopt "$FP_NOW"
case "$(outcome)" in MISS*) ok ;; *) bad "no pre-plan must record MISS (got: $(outcome))" ;; esac
grep -q 'PREPLAN_MISS' "$BLD/pipeline.log" && ok || bad "a MISS must be in pipeline.log — never a silent skip"
one_line "a MISS"

# (iv) the kill flag -> OFF, still never silent
mkplan "$FP_NOW"; adopt "$FP_NOW" PREPLAN_SPECULATIVE=0
case "$(outcome)" in OFF*) ok ;; *) bad "the kill flag must record OFF (got: $(outcome))" ;; esac
grep -q 'PREPLAN_OFF' "$BLD/pipeline.log" && ok || bad "OFF must be in pipeline.log"
[ ! -e "$BLD/plan.md" ] && ok || bad "the kill flag must adopt nothing"
one_line "the kill flag"

# (v) main moved IN a planned file -> STALE on the base sha
echo moved >> "$R/src/lib/pay.ts"; git -C "$R" add -A; git -C "$R" commit -qm two
mkplan "$FP_NOW"; adopt "$FP_NOW"
case "$(outcome)" in STALE*) ok ;; *) bad "main moving in a planned file must be STALE (got: $(outcome))" ;; esac
[ ! -e "$BLD/plan.md" ] && ok || bad "a base-stale pre-plan must not be adopted"

# (c4) main moved OUTSIDE the planned files -> still a HIT
echo moved >> "$R/src/ui/card.tsx"; git -C "$R" add -A; git -C "$R" commit -qm three
BASE1=$(git -C "$R" rev-parse main)
mkplan "$FP_NOW"; printf '%s\n' "$BASE1" > "$T/plans/proj-AB-1/base-sha"
echo again >> "$R/src/ui/card.tsx"; git -C "$R" add -A; git -C "$R" commit -qm four
adopt "$FP_NOW"
case "$(outcome)" in HIT*) ok ;; *) bad "main moving outside the planned files must stay a HIT (got: $(outcome))" ;; esac

# (c2) a boardless project: the relayed fp is ABSENT -> fails OPEN on the thread
BASE2=$(git -C "$R" rev-parse main)
mkplan ""; printf '%s\n' "$BASE2" > "$T/plans/proj-AB-1/base-sha"
adopt "$FP_NOW"
case "$(outcome)" in HIT*) ok ;; *) bad "an absent relayed ticket-fp must fail OPEN, not stale (got: $(outcome))" ;; esac

# (c3) the board was down at build time: FP_BEFORE empty -> fails OPEN
mkplan "$FP_NOW"; printf '%s\n' "$BASE2" > "$T/plans/proj-AB-1/base-sha"
adopt ""
case "$(outcome)" in HIT*) ok ;; *) bad "an empty FP_BEFORE must fail OPEN, not stale (got: $(outcome))" ;; esac

# (c5) a relay dir left by ANOTHER ticket is not this ticket's pre-plan
scratch_rm "$T/plans/proj-AB-1"
RELAY="$T/relay"; mkdir -p "$RELAY"
printf 'someone elses plan\n' > "$RELAY/plan.md"; printf 'AB-9\n' > "$RELAY/key"
BLD="$T/builds/run-relay"; scratch_rm "$BLD"; mkdir -p "$BLD"
( HARNESS="$T"; PROJECT=proj; KEY=AB-1; BUILD="$BLD"; WT="$R"; BASE=main; FP_BEFORE="$FP_NOW"
  export PREPLAN_RELAY_DIR="$RELAY"
  STAMP() { printf '2026-09-17 12:00:00Z'; }
  BB() { :; }
  . "$T/adopt.sh" ) >/dev/null 2>&1
case "$(outcome)" in MISS*) ok ;; *) bad "a relay dir for another ticket must be a MISS, never a stale-of-the-wrong-plan (got: $(outcome))" ;; esac
[ ! -e "$BLD/plan.md" ] && ok || bad "another ticket's relayed plan must never be adopted"

# a RESUMED dir that already carries a plan: the outcome file still gets written
BLD="$T/builds/run-resume"; scratch_rm "$BLD"; mkdir -p "$BLD"
printf 'a plan from the earlier attempt\n' > "$BLD/plan.md"
mkplan "$FP_NOW"
( HARNESS="$T"; PROJECT=proj; KEY=AB-1; BUILD="$BLD"; WT="$R"; BASE=main; FP_BEFORE="$FP_NOW"
  export PREPLAN_RELAY_DIR="$T/relay-none"
  STAMP() { printf '2026-09-17 12:00:00Z'; }
  BB() { :; }
  . "$T/adopt.sh" ) >/dev/null 2>&1
[ "$(cat "$BLD/plan.md")" = "a plan from the earlier attempt" ] && ok \
  || bad "a resumed dir's own plan must never be overwritten by a pre-plan"
case "$(outcome)" in MISS*resumed*) ok ;; *) bad "a resumed dir must record why it adopted nothing (got: $(outcome))" ;; esac

# ...and a resume of a build that DID adopt keeps that answer. Re-labelling it
# MISS because the plan is now on disk would make the evidence row lie about a
# pre-plan the fleet really did use.
printf 'HIT fresh against abc1234\n' > "$BLD/preplan-outcome"
( HARNESS="$T"; PROJECT=proj; KEY=AB-1; BUILD="$BLD"; WT="$R"; BASE=main; FP_BEFORE="$FP_NOW"
  export PREPLAN_RELAY_DIR="$T/relay-none"
  STAMP() { printf '2026-09-17 12:00:00Z'; }
  BB() { :; }
  . "$T/adopt.sh" ) >/dev/null 2>&1
[ "$(outcome)" = "HIT fresh against abc1234" ] && ok \
  || bad "a resume must not overwrite the earlier attempt's pre-plan outcome (got: $(outcome))"
grep -q 'PREPLAN_HIT resumed dir already carries a plan' "$BLD/pipeline.log" && ok \
  || bad "the resume must still say what it did (log: $(tail -1 "$BLD/pipeline.log"))"

# ...and the kill flag must not re-label it either. PREPLAN_SPECULATIVE=0 on a
# resumed dir that adopted a pre-plan is still a build that USED one: answering
# OFF there is the same lie as answering MISS, so the resume branch is tested
# FIRST in the chain and this case is what pins that ordering.
( HARNESS="$T"; PROJECT=proj; KEY=AB-1; BUILD="$BLD"; WT="$R"; BASE=main; FP_BEFORE="$FP_NOW"
  export PREPLAN_RELAY_DIR="$T/relay-none" PREPLAN_SPECULATIVE=0
  STAMP() { printf '2026-09-17 12:00:00Z'; }
  BB() { :; }
  . "$T/adopt.sh" ) >/dev/null 2>&1
[ "$(outcome)" = "HIT fresh against abc1234" ] && ok \
  || bad "the kill flag must not re-label a resumed dir's recorded HIT as OFF (got: $(outcome))"
case "$(tail -1 "$BLD/pipeline.log")" in
  *"PREPLAN_HIT resumed dir already carries a plan"*) ok ;;
  *) bad "a resume under the kill flag must still log PREPLAN_HIT, not PREPLAN_OFF (log: $(tail -1 "$BLD/pipeline.log"))" ;;
esac

echo "--- 2. the evidence row"
EB="$T/builds/evidence"; mkdir -p "$EB"
printf 'HARNESS_EXIT: 0\n' > "$EB/harness-suite.txt"
printf 'MISS no pre-plan for AB-1 (relay dir empty, hub plans/ empty)\n' > "$EB/preplan-outcome"
OUT=$("$T/bin/evidence-summary.sh" "$EB" 2 "" settled 2>/dev/null)
grep -q '^| pre-plan | MISS' <<<"$OUT" && ok || bad "the evidence block must carry a pre-plan row (got: $(grep -c . <<<"$OUT") lines)"
J=$("$T/bin/evidence-summary.sh" --json "$EB" 2 "" settled 2>/dev/null)
[ "$(printf '%s' "$J" | jq -r '.preplan.outcome')" = MISS ] \
  && ok || bad "the evidence JSON must carry .preplan.outcome (got: $(printf '%s' "$J" | jq -c '.preplan'))"
printf 'HIT fresh against abc1234\n' > "$EB/preplan-outcome"
OUT=$("$T/bin/evidence-summary.sh" "$EB" 2 "" settled 2>/dev/null)
grep -q '^| pre-plan | HIT — fresh against abc1234 |' <<<"$OUT" \
  && ok || bad "a HIT row must name the reason (got: $(grep 'pre-plan' <<<"$OUT"))"
rm -f "$EB/preplan-outcome"
OUT=$("$T/bin/evidence-summary.sh" "$EB" 2 "" settled 2>/dev/null)
grep -q 'pre-plan' <<<"$OUT" && bad "a record with no preplan-outcome must render NO row" || ok
J=$("$T/bin/evidence-summary.sh" --json "$EB" 2 "" settled 2>/dev/null)
[ "$(printf '%s' "$J" | jq -r 'has("preplan")')" = false ] \
  && ok || bad "a record with no preplan-outcome must carry no preplan JSON field"


echo "preplan-adopt: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
