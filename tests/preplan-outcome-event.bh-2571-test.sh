#!/bin/bash
# tests/preplan-outcome-event.bh-2571-test.sh — the build half of BH-2571
# (BH-2543.1): every NON-resumed build records its pre-plan outcome as one
# stage_events row, `job_event "$JOB_ID" preplan <ADOPTED|STALE|MISS|OFF> <detail>`,
# so GET /api/preplans/adoption can count how many pre-plans the fleet bought
# actually got used.
# Run from anywhere: tests/preplan-outcome-event.bh-2571-test.sh   (exit 0 = all pass)
#
# HOW IT IS DRIVEN. Both blocks — `# >>> preplan adopt` and the event block right
# after it, `# >>> preplan outcome event (BH-2543)` — are EXTRACTED VERBATIM from
# the flattened pipeline (tests/lib/rb-all.sh) and run against a real scratch git
# repo, the same harness as tests/preplan-adopt.bh-776-test.sh. job_event is a
# stub that records its argv to a file; every assertion reads that file or
# pipeline.log, never source text.
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
. "$DIR/tests/lib/rb-all.sh" || exit 1
RB_ALL=$(rb_all "$DIR" "$T/run-build.all.sh")
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

mkdir -p "$T/bin/lib" "$T/env" "$T/flags" "$T/logs" "$T/plans" "$T/repos" "$T/builds"
cp "$DIR/bin/lib/preplan-lib.sh" "$T/bin/lib/"
: > "$T/env/global.env"

echo "--- 0. the adopt + event blocks (extracted verbatim from the flattened pipeline)"
awk '/^# >>> preplan adopt$/{f=1} f{print} /^# <<< preplan adopt$/{f=0}
     /^# >>> preplan outcome event \(BH-2543\)$/{g=1} g{print} /^# <<< preplan outcome event \(BH-2543\)$/{g=0}' \
  "$RB_ALL" > "$T/block.sh"
grep -q '^# >>> preplan adopt$' "$T/block.sh" && ok || bad "could not extract the preplan adopt block"
grep -q '^# <<< preplan outcome event (BH-2543)$' "$T/block.sh" && ok \
  || bad "could not extract the '# >>> preplan outcome event (BH-2543)' block — it is not in the pipeline"

R="$T/repo"; mkdir -p "$R/src/lib"
git -C "$R" init -q -b main
git -C "$R" config user.email t@t; git -C "$R" config user.name t
echo a > "$R/src/lib/pay.ts"
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
RUN_N=0; RC=0
# run_block <script> <build-dir> <fp-before> [VAR=VAL ...] — rc of the subshell in $RC.
# JOB_ID defaults to job-1; NO_JE=1 leaves job_event undefined; JE_RC is the
# stub's exit code. `set -u` mirrors the pipeline's own `set -uo pipefail`.
run_block() {
  local script=$1 bld=$2 fp=$3; shift 3
  ( set -u
    HARNESS="$T"; PROJECT=proj; KEY=AB-1; BUILD="$bld"; WT="$R"; BASE=main
    FP_BEFORE="$fp"; JOB_ID=job-1
    export PREPLAN_RELAY_DIR="$T/relay-none"
    [ $# -gt 0 ] && export "$@"
    STAMP() { printf '2026-09-17 12:00:00Z'; }
    BB() { :; }
    if [ "${NO_JE:-0}" != 1 ]; then
      job_event() {
        { printf '%s' "$1"; shift; for a in "$@"; do printf '\t%s' "$a"; done; printf '\n'; } >> "$BUILD/job_event.argv"
        return "${JE_RC:-0}"
      }
    fi
    # shellcheck source=/dev/null
    . "$script" ) >/dev/null 2>&1
  RC=$?
}
adopt() { # adopt <fp-before> [VAR=VAL ...] -> a fresh $BUILD, left in $BLD
  RUN_N=$((RUN_N+1))
  BLD="$T/builds/run-$RUN_N"; scratch_rm "$BLD"; mkdir -p "$BLD"
  run_block "$T/block.sh" "$BLD" "$@"
}
argv() { cat "$BLD/job_event.argv" 2>/dev/null; }
calls() { grep -c . "$BLD/job_event.argv" 2>/dev/null || echo 0; }
field() { cut -f"$1" "$BLD/job_event.argv" 2>/dev/null | head -1; }
logged() { grep -q -- "$1" "$BLD/pipeline.log" 2>/dev/null; }

echo "--- 1. HIT -> ADOPTED"
mkplan "$FP_NOW"; adopt "$FP_NOW"
[ "$(calls)" = 1 ] && ok || bad "a HIT must post exactly one event (calls: $(calls))"
[ "$(field 1)" = job-1 ] && [ "$(field 2)" = preplan ] && [ "$(field 3)" = ADOPTED ] && ok \
  || bad "a HIT must post 'job-1 preplan ADOPTED <detail>' (argv: $(argv))"
[ "$(field 4)" = "$(sed 's/^HIT //' "$BLD/preplan-outcome")" ] && ok \
  || bad "the detail must be the outcome minus its verb (argv: $(argv), outcome: $(cat "$BLD/preplan-outcome"))"
logged 'PREPLAN_EVENT ADOPTED recorded' && ok || bad "a HIT must log PREPLAN_EVENT ADOPTED recorded"
[ "$RC" = 0 ] && ok || bad "the blocks must exit 0 on a HIT (rc=$RC)"

echo "--- 2. thread moved -> STALE"
mkplan '2026-09-17T09:00:00Z|2026-09-17T09:00:00Z||1'; adopt "$FP_NOW"
[ "$(field 3)" = STALE ] && ok || bad "a thread-stale pre-plan must post STALE (argv: $(argv))"
case "$(field 4)" in "thread moved since the pre-plan was written"*) ok ;;
  *) bad "the STALE detail must be the outcome's reason (argv: $(argv))" ;; esac
logged 'PREPLAN_EVENT STALE recorded' && ok || bad "STALE must log PREPLAN_EVENT STALE recorded"

echo "--- 3. no pre-plan -> MISS"
scratch_rm "$T/plans/proj-AB-1"; adopt "$FP_NOW"
[ "$(field 3)" = MISS ] && ok || bad "no pre-plan must post MISS (argv: $(argv))"
case "$(field 4)" in "no pre-plan for AB-1"*) ok ;; *) bad "the MISS detail must name the key (argv: $(argv))" ;; esac
logged 'PREPLAN_EVENT MISS recorded' && ok || bad "MISS must log PREPLAN_EVENT MISS recorded"

echo "--- 4. kill flag -> OFF"
mkplan "$FP_NOW"; adopt "$FP_NOW" PREPLAN_SPECULATIVE=0
[ "$(field 3)" = OFF ] && ok || bad "the kill flag must post OFF (argv: $(argv))"
logged 'PREPLAN_EVENT OFF recorded' && ok || bad "OFF must log PREPLAN_EVENT OFF recorded"

echo "--- 5. a resumed dir posts nothing (no double count)"
resume_case() { # resume_case <script> -> BLD is a resumed dir with a HIT recorded
  RUN_N=$((RUN_N+1))
  BLD="$T/builds/run-$RUN_N"; scratch_rm "$BLD"; mkdir -p "$BLD"
  printf 'a plan from the earlier attempt\n' > "$BLD/plan.md"
  printf 'HIT fresh against abc1234\n' > "$BLD/preplan-outcome"
  mkplan "$FP_NOW"
  run_block "$1" "$BLD" "$FP_NOW"
}
resume_ok() { [ ! -e "$BLD/job_event.argv" ] && ! logged 'PREPLAN_EVENT'; }
resume_case "$T/block.sh"
resume_ok && ok || bad "a resumed dir must post no event and log no PREPLAN_EVENT line (argv: $(argv))"
[ "$(cat "$BLD/preplan-outcome")" = "HIT fresh against abc1234" ] && ok || bad "the resume must keep its outcome"
# ...and a resume with no outcome file (MISS resumed…) posts nothing either
RUN_N=$((RUN_N+1)); BLD="$T/builds/run-$RUN_N"; scratch_rm "$BLD"; mkdir -p "$BLD"
printf 'a plan\n' > "$BLD/plan.md"
run_block "$T/block.sh" "$BLD" "$FP_NOW"
resume_ok && ok || bad "a resumed dir with no outcome file must post nothing (argv: $(argv))"

echo "--- 6. no JOB_ID -> no call, said out loud"
mkplan "$FP_NOW"; adopt "$FP_NOW" JOB_ID=
[ ! -e "$BLD/job_event.argv" ] && ok || bad "an empty JOB_ID must never call job_event (argv: $(argv))"
logged 'PREPLAN_EVENT not recorded (no job row)' && ok || bad "an empty JOB_ID must log 'not recorded (no job row)'"
[ "$RC" = 0 ] && ok || bad "an empty JOB_ID must not change rc (rc=$RC)"
# job_event absent (the jobs lib is not on this box)
mkplan "$FP_NOW"; adopt "$FP_NOW" NO_JE=1
logged 'PREPLAN_EVENT not recorded (no job row)' && ok || bad "an absent job_event must log 'not recorded (no job row)'"
[ "$RC" = 0 ] && ok || bad "an absent job_event must not change rc (rc=$RC)"

echo "--- 7. a failing post never changes the build's rc"
mkplan "$FP_NOW"; adopt "$FP_NOW" JE_RC=7
[ "$RC" = 0 ] && ok || bad "a failing job_event must leave rc 0 (rc=$RC)"
logged 'PREPLAN_EVENT not recorded (post failed rc=7)' && ok \
  || bad "a failing job_event must log 'not recorded (post failed rc=7)' (log: $(grep PREPLAN_EVENT "$BLD/pipeline.log"))"
logged 'PREPLAN_EVENT ADOPTED recorded' && bad "a failed post must never be logged as recorded" || ok

echo "--- 8. the detail is capped at 400 characters"
LONG=$(printf 'f%.0s' $(seq 1 600))
mkplan "$LONG"; adopt "$FP_NOW"
[ "$(field 3)" = STALE ] && ok || bad "a 600-char fingerprint must still be STALE (argv: $(argv | cut -c1-80))"
D=$(field 4)
[ "${#D}" = 400 ] && ok || bad "the recorded detail must be exactly 400 characters (got ${#D})"

echo "--- 9. mutant: emitting on resume turns case 5 red"
sed 's/^if \[ "\$PP_RESUMED" != 1 \]; then$/if true; then/' "$T/block.sh" > "$T/mutant.sh"
cmp -s "$T/block.sh" "$T/mutant.sh" && bad "the mutant sed matched nothing — the resume guard is not in the shape this case mutates" || ok
resume_case "$T/mutant.sh"
resume_ok && bad "the resume assertion stayed green on a block that emits on resume — case 5 proves nothing" || ok

echo "--- 10. a build that died mid-PLAN (outcome on disk, no plan.md) posts once, not twice"
# A MISS/STALE/OFF build has a preplan-outcome but no plan.md until PLAN ends,
# so a resume after a crash in PLAN is NOT PP_RESUMED. Its $BUILD/preplan-event
# marker is what keeps the second pass from posting a second row.
scratch_rm "$T/plans/proj-AB-1"; adopt "$FP_NOW"
[ "$(calls)" = 1 ] && ok || bad "the first pass must post exactly one event (calls: $(calls))"
[ -s "$BLD/preplan-outcome" ] && [ ! -e "$BLD/plan.md" ] && ok || bad "the first pass must leave an outcome and no plan.md"
run_block "$T/block.sh" "$BLD" "$FP_NOW"
[ "$(calls)" = 1 ] && ok || bad "a resume of a build that died mid-PLAN must not post again (calls: $(calls), argv: $(argv))"
[ "$RC" = 0 ] && ok || bad "the skipped resume must exit 0 (rc=$RC)"
logged 'PREPLAN_EVENT already recorded' && ok || bad "the skipped resume must say it skipped (log: $(grep PREPLAN_EVENT "$BLD/pipeline.log"))"

echo "--- 11. a failed post leaves no marker, so the resume still posts"
scratch_rm "$T/plans/proj-AB-1"; adopt "$FP_NOW" JE_RC=7
[ ! -e "$BLD/preplan-event" ] && ok || bad "a failed post must not write the marker"
run_block "$T/block.sh" "$BLD" "$FP_NOW"
[ "$(calls)" = 2 ] && ok || bad "after a failed post, the resume must try again (calls: $(calls))"
[ -e "$BLD/preplan-event" ] && ok || bad "the successful retry must write the marker"
logged 'PREPLAN_EVENT MISS recorded' && ok || bad "the successful retry must log recorded"

echo "preplan-outcome-event: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
