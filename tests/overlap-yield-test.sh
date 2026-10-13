#!/bin/bash
# tests/overlap-yield-test.sh — the OVERLAP-DEFER PRIORITY YIELD in
# bin/run-build.sh (#647, BH-643 fix 3): when a build defers on a file overlap
# and it outranks the sibling holding the claim, it asks that sibling to stand
# down at its next safe checkpoint instead of waiting out the 4h claims ageout.
#
# WHY EACH HALF IS DRIVEN RATHER THAN GREPPED. Both halves fail silently in the
# expensive direction. Too eager and an ordinary build evicts another ordinary
# build — work thrown away for nothing, by a comparison nobody would look at
# again. Too shy and the emergency this exists for waits four hours anyway,
# which is indistinguishable from the feature not being there. So the rank
# comparison is driven through EVERY pair that must NOT yield (§2) before the
# one pair that must, and the release half is driven against a real git repo and
# a real bare origin so the sentence it writes about where the tree is can be
# checked against where the tree actually is (§3).
#
# The two regions are lifted out of bin/run-build.sh by their own
# `# >>> name` / `# <<< name` markers and executed, the same way
# tests/run-build-checkpoint-test.sh and tests/hotfix-wip-gate-test.sh drive
# theirs. §4 is the WIRING — the three call sites in the real script, by
# position — because an extracted function nothing calls is a dead feature.
# No network, no gh, no LLM.
# Run from anywhere: tests/overlap-yield-test.sh   (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }
unset HOTFIX HOTFIX_LANE HOTFIX_LABEL MAIN_RED_LABEL PRIORITY_YIELD JOB_ID 2>/dev/null || true

# BH-568 seam: the driver is being split into bin/lib/rb/ stage modules, so a
# suite that reads bin/run-build.sh RAW goes blind to any block that has already
# moved — and §4 below judges the three call sites BY LINE NUMBER. rb_all puts
# every moved body back exactly where its call site is, so this text is the
# pipeline in its original order at every state of the split.
. "$DIR/tests/lib/rb-all.sh" || exit 1
SRC=$(rb_all "$DIR" "$T/run-build.all.sh") || exit 1

# ══ 0. EXTRACTION ═══════════════════════════════════════════════════════════
cut_block() { # cut_block <marker-word...> <outfile>
  local name="$1" out="$2"
  awk -v n="$name" 'index($0,"# >>> " n)==1{f=1;next} index($0,"# <<< " n)==1{exit} f' \
    "$SRC" > "$out"
}
cut_block "overlap wait"   "$T/wait.sh"
cut_block "priority yield" "$T/yield.sh"
for B in wait yield; do
  [ -s "$T/$B.sh" ] && ok || bad "could not extract the '$B' block from bin/run-build.sh — markers missing?"
  bash -n "$T/$B.sh" 2>/dev/null && ok || bad "the extracted '$B' block does not parse on its own"
done
grep -q 'YIELD_CHECK' "$T/yield.sh" \
  && ok || bad "the 'priority yield' block must define YIELD_CHECK"

# ══ THE REQUEST FIXTURE (§1, §2) ════════════════════════════════════════════
# A scratch $HARNESS carrying the REAL hotfix-lib (the rank vocabulary this
# slice imports) and a conflict-check that prints whatever the case under test
# wants it to print, in bin/conflict-check.sh:29's shape.
H="$T/h"
# The wake sentence as it reads TODAY, before this feature — pinned once, as a
# constant, so every negative can assert it character for character rather than
# "looks about the same".
WAKE_OLD="the sibling build releases its claim (it writes a RESULT, or state/claims/tproj/ ages it out at 4h) and the next triage tick re-offers TK-1"
CONFLICT_MSG="CONFLICT with tproj-TK-9-202609171200: a.ts ~ a.ts"

mk_meta() { # mk_meta <file> <label|-> — the shape run-build.sh saves to ticket-meta.json
  case "$2" in
    -) printf '{"title":"x","labels":[]}\n' > "$1" ;;
    *) printf '{"title":"x","labels":[{"name":"%s"}]}\n' "$2" > "$1" ;;
  esac
}

mk_case() { # mk_case <candidate-label|-|none> <sibling-label|-|none> — rebuilds the tree
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
  [ "$1" = none ] || mk_meta "$CAND/ticket-meta.json" "$1"
  [ "$2" = none ] || mk_meta "$SIB/ticket-meta.json" "$2"
}

# The driver: the REAL overlap-wait block, with the REAL priority-yield block
# and the REAL hotfix-lib sourced above it, exactly the order bin/run-build.sh
# has them in (lib at :156, the yield block above the wait block).
cat > "$T/drive-wait.sh" <<'SH'
set -uo pipefail
STAMP() { echo "2026-09-17 00:00:00Z"; }
RESULT() { echo "$*" > "$BUILD/RESULT"; }
# shellcheck source=/dev/null
[ -r "$HARNESS/bin/lib/hotfix-lib.sh" ] && . "$HARNESS/bin/lib/hotfix-lib.sh"
. "$YIELD_BLOCK"
. "$WAIT_BLOCK"
SH

run_wait() { # run_wait [KEY=...] [env...] -> rc; RESULT/overlap-defer.txt in $CAND
  rm -f "$CAND/RESULT" "$CAND/overlap-defer.txt"
  ( env HARNESS="$H" PROJECT=tproj KEY=TK-1 BUILD="$CAND" ALERTS="$H/logs/ALERTS.log" \
        OVERLAP_WAIT_SECS=0 CMSG_OUT="${CMSG_OUT-$CONFLICT_MSG}" \
        YIELD_BLOCK="$T/yield.sh" WAIT_BLOCK="$T/wait.sh" "$@" \
    bash "$T/drive-wait.sh" >/dev/null 2>&1 )
}
wake_of() { sed -n 's/^WAKE: //p' "$CAND/overlap-defer.txt"; }

# ══ 1. THE REQUEST, HAPPY PATH ══════════════════════════════════════════════
# A hotfix candidate (rank 0) overlapping a plain sibling (rank 2).
mk_case hotfix -
run_wait HOTFIX=1; RC=$?
[ "$RC" = 3 ] && ok || bad "§1.6 the deferral must still exit 3 (rc=$RC)"        # R9
[ -f "$SIB/YIELD" ] && ok || bad "§1.1 a rank-0 build must ask a rank-2 sibling to stand down — no $SIB/YIELD"
grep -qE '^requested_by=TK-1 rank=0 at=' "$SIB/YIELD" 2>/dev/null \
  && ok || bad "§1.1 YIELD content: $(cat "$SIB/YIELD" 2>/dev/null)"            # R5
head -1 "$CAND/RESULT" 2>/dev/null | grep -q '^BUILD_DEFERRED file overlap' \
  && ok || bad "§1.2 the terminal must stay BUILD_DEFERRED file overlap: $(cat "$CAND/RESULT" 2>/dev/null)"
grep -q 'TK-9' "$CAND/RESULT" 2>/dev/null \
  && ok || bad "§1.2 the RESULT must name the sibling KEY: $(cat "$CAND/RESULT" 2>/dev/null)"
grep -q 'priority yield' "$CAND/pipeline.log" \
  && ok || bad "§1.4 one pipeline.log line is owed: $(cat "$CAND/pipeline.log")"  # R6
grep -q 'rank 0' "$CAND/pipeline.log" && grep -q 'rank 2' "$CAND/pipeline.log" \
  && ok || bad "§1.4 the log line must name BOTH ranks: $(cat "$CAND/pipeline.log")"
# D13: the wake sentence the RESULT quotes and the one the artifact records are
# the same sentence, or one of the two is a lie about the same build.
W=$(wake_of)
case "$W" in *"yields at its next checkpoint"*) ok ;;
  *) bad "§1.5 the wake sentence must name the yield, got: $W" ;; esac          # R7
case "$W" in *"ages it out at 4h"*) bad "§1.5 the 4h-ageout sentence must be replaced: $W" ;; *) ok ;; esac
grep -qF "wakes when $W" "$CAND/RESULT" \
  && ok || bad "§1.5 RESULT and overlap-defer.txt must carry the SAME wake sentence: RESULT=$(cat "$CAND/RESULT") artifact=$W"

# 1.3 — WRITE, NEVER OVERWRITE. The second run is a DIFFERENT requester, so an
# overwrite would be visible in the bytes as well as the mtime.
MT1=$(stat -c %Y "$SIB/YIELD" 2>/dev/null)
: > "$CAND/pipeline.log"
run_wait KEY=TK-7 HOTFIX=1; RC=$?
MT2=$(stat -c %Y "$SIB/YIELD" 2>/dev/null)
[ -n "$MT1" ] && [ "$MT2" = "$MT1" ] \
  && ok || bad "§1.3 an existing YIELD must not be rewritten (mtime '$MT1' -> '$MT2')"
grep -qE '^requested_by=TK-1 ' "$SIB/YIELD" \
  && ok || bad "§1.3 an existing YIELD must keep its first requester: $(cat "$SIB/YIELD")"
grep -q 'already carries a YIELD' "$CAND/pipeline.log" \
  && ok || bad "§1.3 the second requester must log that the marker was already there: $(cat "$CAND/pipeline.log")"
case "$(wake_of)" in *"yields at its next checkpoint"*) ok ;;
  *) bad "§1.3 a sibling already asked to yield still yields — the sentence stays true: $(wake_of)" ;; esac

# ══ 2. THE NEGATIVES ════════════════════════════════════════════════════════
# Every one of these asserts BOTH halves: no marker written, and the wake
# sentence character-for-character what it was before this feature existed.
no_yield() { # no_yield <label> — assert the two properties
  [ -f "$SIB/YIELD" ] && bad "$1: a YIELD must NOT be written ($(cat "$SIB/YIELD"))" || ok
  [ "$(wake_of)" = "$WAKE_OLD" ] \
    && ok || bad "$1: the wake sentence must be byte-identical to today's — got: $(wake_of)"
}

mk_case - -;                 run_wait;            no_yield "§2.1 plain vs plain"
mk_case hotfix hotfix;       run_wait HOTFIX=1;   no_yield "§2.2 hotfix vs hotfix"
mk_case fix-main-red hotfix; run_wait;            no_yield "§2.3 main-red candidate vs hotfix sibling"
mk_case - fix-main-red;      run_wait;            no_yield "§2.4 plain candidate vs main-red sibling"
mk_case none -;              run_wait;            no_yield "§2.5 HOTFIX unset and own meta missing (rank 2)"

# §2.6 a sibling that finished during the wait cannot yield — and a RESULT line
# claiming it will would be a wake condition that never fires.
mk_case hotfix -; : > "$SIB/RESULT"; run_wait HOTFIX=1; no_yield "§2.6 sibling already wrote a RESULT"

# §2.7 a CMSG that is not bin/conflict-check.sh:29's shape names nobody.
mk_case hotfix -; CMSG_OUT="something went wrong" run_wait HOTFIX=1
no_yield "§2.7 CMSG with no 'CONFLICT with' prefix"
mk_case hotfix -; CMSG_OUT="" run_wait HOTFIX=1
no_yield "§2.7 empty CMSG"

# §2.8 an unreadable sibling meta is rank 2 (the lib's rule), never rank 0 —
# treating unknown as urgent would let every pre-meta dir block an emergency.
mk_case - none; run_wait
no_yield "§2.8 sibling ticket-meta.json absent, plain candidate"
grep -q 'no readable ticket-meta.json' "$CAND/pipeline.log" \
  && ok || bad "§2.8 an unknown sibling must be VISIBLE, not silently plain: $(cat "$CAND/pipeline.log")"

# §2.9 THE PINNED POSITIVE beyond the headline case: 0 beats 1.
mk_case hotfix fix-main-red; run_wait HOTFIX=1
[ -f "$SIB/YIELD" ] && ok || bad "§2.9 a hotfix (0) must yield a main-red sibling (1)"
grep -qE '^requested_by=TK-1 rank=0 ' "$SIB/YIELD" 2>/dev/null \
  && ok || bad "§2.9 the marker must carry the requester's rank: $(cat "$SIB/YIELD" 2>/dev/null)"

# §2.10 the two kill switches, each against a real 0-vs-2 pair.
mk_case hotfix -; run_wait HOTFIX=1 PRIORITY_YIELD=0
no_yield "§2.10 PRIORITY_YIELD=0"
mk_case hotfix -; run_wait HOTFIX=1 PRIORITY_YIELD=off
no_yield "§2.10 PRIORITY_YIELD=off"
mk_case hotfix -; touch "$H/flags/priority-yield-off"; run_wait HOTFIX=1
no_yield "§2.10 flags/priority-yield-off"

# §2.11 WHOLE-NAME MATCH ONLY. `hotfix-candidate` is somebody ASKING whether a
# ticket is urgent and `not-hotfix` is somebody saying it is not; a substring
# read of either would spend an eviction on it.
for L in hotfix-candidate not-hotfix fix-main-red-ish hotfixes; do
  mk_case - "$L"; run_wait
  no_yield "§2.11 sibling labelled '$L' is rank 2, plain candidate"
  mk_case hotfix "$L"; run_wait HOTFIX=1
  [ -f "$SIB/YIELD" ] && ok || bad "§2.11 sibling labelled '$L' is rank 2, so a hotfix (0) DOES outrank it"
done

# ══ THE RELEASE FIXTURE (§3, §5) ════════════════════════════════════════════
export HOME="$T/home"; mkdir -p "$HOME"
git config --global user.email harness@localhost >/dev/null 2>&1
git config --global user.name  harness           >/dev/null 2>&1
git config --global init.defaultBranch main      >/dev/null 2>&1
git config --global protocol.file.allow always   >/dev/null 2>&1

mkdir -p "$T/fakebin"
cat > "$T/fakebin/agent-call.sh" <<'SH'
#!/bin/bash
printf '%s\n' "$*" >> "$AGENT_SINK"
exit 0
SH
chmod +x "$T/fakebin/agent-call.sh"

# The trap line is bin/run-build.sh:1799's, minus CKPT_ON_EXIT (which needs the
# whole checkpoint machinery): the claim removal and _job_finish ARE the claim
# release this feature depends on, so they are what gets driven.
cat > "$T/drive-yield.sh" <<'SH'
set -uo pipefail
STAMP() { echo "2026-09-17 00:00:00Z"; }
RESULT() { echo "$*" > "$BUILD/RESULT"; }
_job_finish() { echo finished >> "$JOBFINISH"; }
trap 'rm -f "$HARNESS/state/claims/$PROJECT/$KEY"; _job_finish' EXIT
. "$YIELD_BLOCK"
YIELD_CHECK "$STAGE"
echo ran-on > "$BUILD/after.txt"
SH

RN=0
mk_release() { # mk_release <sibling-yield-content|-> — fresh repo, origin, BUILD, claim
  RN=$((RN+1))
  scratch_rm "$H" 2>/dev/null
  mkdir -p "$H/bin" "$H/builds" "$H/logs" "$H/flags" "$H/state/claims/tproj"
  ORIGIN="$T/origin$RN.git"; WT="$T/wt$RN"; RBUILD="$H/builds/tproj-TK-9-20260917$RN"
  mkdir -p "$RBUILD"; : > "$RBUILD/pipeline.log"
  echo claimed > "$H/state/claims/tproj/TK-9"
  : > "$T/jobfinish$RN.txt"; : > "$T/agent$RN.txt"
  git init --bare -q "$ORIGIN"; git init -q "$WT"
  git -C "$WT" remote add origin "$ORIGIN"
  echo base > "$WT/base.txt"
  git -C "$WT" add -A >/dev/null; git -C "$WT" commit -qm base >/dev/null
  git -C "$WT" push -q -u origin main >/dev/null 2>&1
  git -C "$WT" checkout -qb ticket/TK-9 >/dev/null 2>&1
  echo work > "$WT/a.txt"
  git -C "$WT" add -A >/dev/null; git -C "$WT" commit -qm work >/dev/null
  [ "$1" = "-" ] || printf '%s\n' "$1" > "$RBUILD/YIELD"
}
run_yield() { # run_yield <stage> [env...] -> rc
  rm -f "$RBUILD/RESULT" "$RBUILD/after.txt"
  ( env HARNESS="$H" PROJECT=tproj KEY=TK-9 BUILD="$RBUILD" WT="$WT" BRANCH=ticket/TK-9 \
        ALERTS="$H/logs/ALERTS.log" PATH="$T/fakebin:$PATH" AGENT_SINK="$T/agent$RN.txt" \
        JOBFINISH="$T/jobfinish$RN.txt" YIELD_BLOCK="$T/yield.sh" STAGE="$1" "${@:2}" \
    bash "$T/drive-yield.sh" >/dev/null 2>&1 )
}

# ══ 3. THE RELEASE ══════════════════════════════════════════════════════════
mk_release 'requested_by=TK-1 rank=0 at=2026-09-17 00:00:00Z'
git -C "$WT" push -q -u origin ticket/TK-9 >/dev/null 2>&1
SHA=$(git -C "$WT" rev-parse --short=8 HEAD)
run_yield execute; RC=$?
head -1 "$RBUILD/RESULT" 2>/dev/null | grep -qE '^BUILD_DEFERRED yielded to TK-1 at execute' \
  && ok || bad "§3.1 the release terminal: $(cat "$RBUILD/RESULT" 2>/dev/null)"   # R12
[ "$RC" = 3 ] && ok || bad "§3.2 a yield must exit 3 (rc=$RC)"
[ ! -s "$T/agent$RN.txt" ] && ok || bad "§3.2 a yield must buy no agent session: $(cat "$T/agent$RN.txt")"
[ ! -f "$RBUILD/after.txt" ] && ok || bad "§3.2 the build must STOP — code after YIELD_CHECK ran"
[ ! -e "$H/state/claims/tproj/TK-9" ] && ok || bad "§3.3 the claim must be released by the EXIT trap"  # R13
[ -s "$T/jobfinish$RN.txt" ] && ok || bad "§3.3 _job_finish must run (it is what parks and re-queues the ticket)"
[ ! -f "$RBUILD/YIELD" ] && ok || bad "§3.4 the marker must be consumed"
[ -f "$RBUILD/YIELD.honored" ] && ok || bad "§3.4 the consumed marker must be kept as YIELD.honored"
grep -q 'PRIORITY YIELD at execute' "$RBUILD/pipeline.log" \
  && ok || bad "§3.1 the recipient owes a pipeline.log line: $(cat "$RBUILD/pipeline.log")"
# §3.5 $WHERE, case B: HEAD is on origin, so the sentence may name it.
grep -qF "$SHA" "$RBUILD/RESULT" && ok || bad "§3.5 a pushed HEAD must be named by its sha: $(cat "$RBUILD/RESULT")"
grep -qF "TARGET_BRANCH=ticket/TK-9" "$RBUILD/RESULT" \
  && ok || bad "§3.5 the sentence must name the escape that actually works: $(cat "$RBUILD/RESULT")"
# ...and a re-entry of the same dir does not stand down forever.
run_yield execute; RC=$?
[ "$RC" = 0 ] && ok || bad "§3.4 a consumed marker must not yield again (rc=$RC)"
[ ! -f "$RBUILD/RESULT" ] && ok || bad "§3.4 the second pass must write no RESULT: $(cat "$RBUILD/RESULT" 2>/dev/null)"
[ -f "$RBUILD/after.txt" ] && ok || bad "§3.4 the second pass must run on"

# §3.5 case A: nothing of this build reached origin. The ticket's suggested
# sentence ("branch is checkpointed on origin") is FALSE here, which is why the
# sentence is measured rather than asserted.
mk_release 'requested_by=TK-1 rank=0 at=2026-09-17 00:00:00Z'
run_yield plan; RC=$?
[ "$RC" = 3 ] && ok || bad "§3.5A a yield at plan must exit 3 (rc=$RC)"
grep -q 'nothing of this build reached origin' "$RBUILD/RESULT" \
  && ok || bad "§3.5A with no origin branch the sentence must say so: $(cat "$RBUILD/RESULT")"
grep -q 'is on origin at' "$RBUILD/RESULT" \
  && bad "§3.5A must not claim an origin branch that does not exist: $(cat "$RBUILD/RESULT")" || ok

# §3.5 case C: origin has the branch, but this machine moved on.
mk_release 'requested_by=TK-1 rank=0 at=2026-09-17 00:00:00Z'
git -C "$WT" push -q -u origin ticket/TK-9 >/dev/null 2>&1
PUSHED=$(git -C "$WT" rev-parse --short=8 HEAD)
echo more > "$WT/b.txt"; git -C "$WT" add -A >/dev/null; git -C "$WT" commit -qm more >/dev/null
LOCAL=$(git -C "$WT" rev-parse --short=8 HEAD)
run_yield review
grep -qF "$PUSHED" "$RBUILD/RESULT" && grep -qF "$LOCAL" "$RBUILD/RESULT" \
  && ok || bad "§3.5C both shas must be named: $(cat "$RBUILD/RESULT")"
grep -q 'lost' "$RBUILD/RESULT" \
  && ok || bad "§3.5C the unpushed difference must be declared lost: $(cat "$RBUILD/RESULT")"

# §3 the requester's rank is read from the FILE, never invented (D26).
mk_release 'rank=0 at=2026-09-17 00:00:00Z'
run_yield plan
grep -q 'yielded to a higher-priority build at plan' "$RBUILD/RESULT" \
  && ok || bad "§3.1 a marker with no requested_by must not invent a key: $(cat "$RBUILD/RESULT")"

# ══ 5. NO MARKER, NO CHANGE ═════════════════════════════════════════════════
mk_release -
run_yield execute; RC=$?
[ "$RC" = 0 ] && ok || bad "§5.1 no YIELD file must be a no-op (rc=$RC)"
[ ! -f "$RBUILD/RESULT" ] && ok || bad "§5.1 no YIELD file must write no RESULT: $(cat "$RBUILD/RESULT" 2>/dev/null)"
[ ! -s "$RBUILD/pipeline.log" ] && ok || bad "§5.1 no YIELD file must log nothing: $(cat "$RBUILD/pipeline.log")"
[ -f "$RBUILD/after.txt" ] && ok || bad "§5.1 the build must run on"
[ -e "$H/state/claims/tproj/TK-9" ] && bad "§5.1 the claim is removed by the trap on every exit" || ok

# §5.2 the kill switch on the RECIPIENT half: the marker is LEFT IN PLACE, so
# arming the switch again honours it rather than losing the request.
mk_release 'requested_by=TK-1 rank=0 at=2026-09-17 00:00:00Z'
run_yield execute PRIORITY_YIELD=0; RC=$?
[ "$RC" = 0 ] && ok || bad "§5.2 PRIORITY_YIELD=0 must not stand the build down (rc=$RC)"
[ ! -f "$RBUILD/RESULT" ] && ok || bad "§5.2 PRIORITY_YIELD=0 must write no RESULT: $(cat "$RBUILD/RESULT" 2>/dev/null)"
[ -f "$RBUILD/YIELD" ] && ok || bad "§5.2 a switched-off yield must leave the marker in place"
[ ! -f "$RBUILD/YIELD.honored" ] && ok || bad "§5.2 a switched-off yield must not consume the marker"
mk_release 'requested_by=TK-1 rank=0 at=2026-09-17 00:00:00Z'
touch "$H/flags/priority-yield-off"
run_yield execute; RC=$?
[ "$RC" = 0 ] && [ -f "$RBUILD/YIELD" ] && ok \
  || bad "§5.2 flags/priority-yield-off must leave the marker and the build alone (rc=$RC)"

# ══ 4. THE WIRING, against the real bin/run-build.sh ════════════════════════
# Positional, and every assertion fails CLOSED: a missing marker yields an empty
# line number and the comparison below is false, not vacuously true.
mapfile -t CALLS < <(grep -nE '^[[:space:]]*YIELD_CHECK[[:space:]]+[a-z]+[[:space:]]*$' "$SRC")
[ "${#CALLS[@]}" = 3 ] && ok \
  || bad "§4.1 exactly three YIELD_CHECK call sites are owed, found ${#CALLS[@]}: ${CALLS[*]-}"
STAGES=$(printf '%s\n' "${CALLS[@]-}" | sed -E 's/^[0-9]+:[[:space:]]*YIELD_CHECK[[:space:]]+//; s/[[:space:]]*$//' | tr '\n' ' ')
[ "$STAGES" = "plan execute review " ] && ok \
  || bad "§4.1 the three stages, in pipeline order, must be plan/execute/review — got: $STAGES"

# TOP LEVEL, every one of them. YIELD_CHECK stands the build down with `exit 3`;
# inside a subshell or a pipeline that exit leaves the subshell and the pipeline
# runs on, which is a build that announced it stood down and then did not.
INDENTED=$(grep -cE '^[[:space:]]+YIELD_CHECK[[:space:]]+[a-z]+[[:space:]]*$' "$SRC")
[ "$INDENTED" = 0 ] && ok \
  || bad "§4.1 $INDENTED YIELD_CHECK call(s) are indented — an exit 3 inside a subshell does not stop the build"

lineof() { grep -nE "$1" "$SRC" | head -1 | cut -d: -f1; }
C1=$(printf '%s\n' "${CALLS[0]-}" | cut -d: -f1)
C2=$(printf '%s\n' "${CALLS[1]-}" | cut -d: -f1)
C3=$(printf '%s\n' "${CALLS[2]-}" | cut -d: -f1)
L_PLANOVL=$(lineof '^# <<< plan overlap$')
L_EXECIF=$(lineof '^if \[ -z "\$\{CKPT_START_POINT:-\}" \]')
L_PUSH=$(lineof '^PUSH_BRANCH execute$')
L_LENSES=$(lineof '^# >>> review lenses')
L_PROPEN=$(lineof '^# >>> pr open')
for M in L_PLANOVL L_EXECIF L_PUSH L_LENSES L_PROPEN; do
  [ -n "${!M}" ] && ok || bad "§4.2 the anchor $M is not in bin/run-build.sh — the wiring cannot be judged"
done
[ -n "$C1" ] && [ "$C1" -gt "${L_PLANOVL:-0}" ] && [ "$C1" -lt "${L_EXECIF:-0}" ] 2>/dev/null \
  && ok || bad "§4.2 call 1 must sit between '# <<< plan overlap' (${L_PLANOVL:-?}) and the EXECUTE checkpoint if (${L_EXECIF:-?}), got ${C1:-none}"
[ -n "$C2" ] && [ "$C2" -gt "${L_PUSH:-0}" ] && [ "$C2" -lt "${L_LENSES:-0}" ] 2>/dev/null \
  && ok || bad "§4.2 call 2 must sit after 'PUSH_BRANCH execute' (${L_PUSH:-?}) — the tree is provably on origin there; got ${C2:-none}"
[ -n "$C3" ] && [ "$C3" -lt "${L_LENSES:-0}" ] && [ "$C3" -gt "${L_PUSH:-0}" ] 2>/dev/null \
  && ok || bad "§4.2 call 3 must sit above '# >>> review lenses' (${L_LENSES:-?}), got ${C3:-none}"
# §4.3 NOTHING AFTER THE PR IS OPEN. A build that stood down after claiming a PR
# would leave an open PR nobody owns.
LATE=0
for C in "${CALLS[@]-}"; do
  N=$(printf '%s' "$C" | cut -d: -f1)
  [ -n "$N" ] && [ -n "$L_PROPEN" ] && [ "$N" -gt "$L_PROPEN" ] 2>/dev/null && LATE=$((LATE+1))
done
[ -n "$L_PROPEN" ] && [ "$LATE" = 0 ] && ok \
  || bad "§4.3 no YIELD_CHECK may sit below '# >>> pr open' (${L_PROPEN:-?}) — $LATE do"

# ══ 6. THE CONTRACT AROUND IT ═══════════════════════════════════════════════
# §6.1 no new RESULT terminal: docs/RUN-BUILD-GRAPH.md is claimed by another
# slice, so every RESULT this diff introduces must reuse BUILD_DEFERRED.
TERMS=$(cat "$T/yield.sh" "$T/wait.sh" | sed -nE 's/.*RESULT "([A-Z_]+).*/\1/p' | sort -u)
[ -n "$TERMS" ] && ok || bad "§6.1 no RESULT call found in either block — the extraction is wrong"
[ "$(printf '%s\n' "$TERMS" | grep -cv '^BUILD_DEFERRED$')" = 0 ] && ok \
  || bad "§6.1 both blocks must terminate as BUILD_DEFERRED, got: $TERMS"
# §6.2 the docs section
D=docs/BUILD-CONCURRENCY.md
grep -q '^## Priority yield' "$DIR/$D" && ok || bad "§6.2 $D is owed a '## Priority yield' section"
for S in PRIORITY_YIELD priority-yield-off YIELD.honored; do
  grep -q "$S" "$DIR/$D" && ok || bad "§6.2 $D must document $S"
done

echo "overlap-yield: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
