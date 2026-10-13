#!/bin/bash
# tests/run-build-graph-test.sh — docs/RUN-BUILD-GRAPH.md must describe the
# script that actually exists.
#
# A transition table nobody checks becomes fiction within a month, and a fiction
# about which exits are terminal is worse than no table — it is the document
# someone would consult while chasing the next leak.
#
# Both directions are checked, because they fail differently:
#   terminal in doc, not in script  -> the table describes a pipeline we do not run
#   terminal in script, not in doc  -> an exit path nobody has audited (the leak shape)
#
# grep -a throughout is DEFENSIVE, not a workaround for a live problem: checked
# 2026-08-24, run-build.sh is valid UTF-8 with no NUL bytes and plain grep
# returns identical results. The flag keeps this extraction correct if the file
# ever gains binary content. (The earlier comment here asserted grep was ALREADY
# treating it as binary. That was true of harness-console/src/index.js, which
# really does carry NUL sentinels, and I carried the lesson across to a file
# that does not have the problem. In a test whose whole job is stopping docs
# from becoming fiction, a false justification has no business standing.)
# Run from anywhere: tests/run-build-graph-test.sh   (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
. "$DIR/tests/lib/rb-all.sh" || exit 1
RB_ALL=$(rb_all "$DIR" "$T/run-build.all.sh")
SCRIPT="$RB_ALL"
DOC="$DIR/docs/RUN-BUILD-GRAPH.md"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

[ -s "$DOC" ] && ok || bad "docs/RUN-BUILD-GRAPH.md is missing"
[ -s "$SCRIPT" ] && ok || bad "bin/run-build.sh is missing"

# Terminals the script actually writes, read from the RESULT calls themselves.
SCRIPT_TERMS=$(grep -a -oE 'RESULT "[A-Z_]+' "$SCRIPT" | sed 's/RESULT "//' | sort -u)
[ -n "$SCRIPT_TERMS" ] && ok || bad "found no RESULT terminals in the script — is the grep still right?"
# A sanity floor: if this ever drops to a handful, the extraction broke rather
# than the pipeline shrinking.
[ "$(grep -c . <<<"$SCRIPT_TERMS")" -ge 10 ] \
  && ok || bad "only $(grep -c . <<<"$SCRIPT_TERMS") terminals extracted — extraction likely broken"

# Terminals the doc claims, taken ONLY from the transition table's "To" column.
# Scraping every backticked CAPS token instead would sweep up env vars from the
# Guard column (TARGET_BRANCH), the console's stage-set names discussed in F6,
# and the TAMPER_BLOCKED/REPRO_BLOCKED that F5 explains we deliberately did NOT
# add — none of which are claims that the pipeline writes them.
DOC_TERMS=$(awk -F'|' 'NF==7 && $1=="" {print $4}' "$DOC" \
  | grep -oE '`[A-Z_]{4,}' | tr -d '`' | sort -u)
[ -n "$DOC_TERMS" ] && ok || bad "found no terminals in the doc"

# ---------- 1. every terminal the script writes appears in the doc ----------
# This is the direction that matters: an unaudited exit path is the leak shape.
MISSING_FROM_DOC=""
while read -r t; do
  [ -n "$t" ] || continue
  grep -qxF "$t" <<<"$DOC_TERMS" || MISSING_FROM_DOC="$MISSING_FROM_DOC $t"
done <<<"$SCRIPT_TERMS"
[ -z "$MISSING_FROM_DOC" ] && ok \
  || bad "run-build.sh writes terminals the graph does not document:$MISSING_FROM_DOC"

# ---------- 2. every terminal the doc claims is one the script can write ----
# Terminals written by sibling scripts are declared in their own section, so
# they are allowed here.
ELSEWHERE="RESULT_UNVERIFIED BUILD_DEAD"
MISSING_FROM_SCRIPT=""
while read -r t; do
  [ -n "$t" ] || continue
  grep -qxF "$t" <<<"$SCRIPT_TERMS" && continue
  grep -qw "$t" <<<"$ELSEWHERE" && continue
  grep -a -qw "$t" "$DIR/bin/fly-pool.sh" "$DIR/bin/lib/resume-dead.sh" 2>/dev/null && continue
  MISSING_FROM_SCRIPT="$MISSING_FROM_SCRIPT $t"
done <<<"$DOC_TERMS"
[ -z "$MISSING_FROM_SCRIPT" ] && ok \
  || bad "the graph documents terminals nothing writes:$MISSING_FROM_SCRIPT"

# ---------- 3. the stages named in the doc exist in the script ----------
for STAGE in PLAN EXECUTE SEMGREP REVIEW; do
  grep -a -q "$STAGE" "$SCRIPT" && ok || bad "stage $STAGE named in the doc is absent from the script"
done
# the two gates this wave added
grep -a -q 'test-tamper-scan.sh' "$SCRIPT" && ok || bad "the test-tamper gate is documented but not wired"
grep -a -q 'repro-gate.sh' "$SCRIPT" && ok || bad "the reproduction gate is documented but not wired"
grep -q 'test-tamper gate' "$DOC" && ok || bad "the tamper gate must appear in the table"
grep -q 'reproduction gate' "$DOC" && ok || bad "the repro gate must appear in the table"

# ---------- 3b. head-bound approval: doc and script say the same thing -------
# SDLC item 1 lives in a demoter rather than a stage, so it has no row of its
# own — which is exactly how a documented gate rots unnoticed. Both halves are
# asserted: the markers the block is extracted by (tests/head-bound-approval-
# test.sh drives them), and the doc section that explains why transition 41 now
# depends on a sha.
grep -a -q '^# >>> head-bound approval' "$SCRIPT" \
  && ok || bad "the head-bound approval block is gone from the script"
grep -a -q 'review-head' "$SCRIPT" \
  && ok || bad "nothing in the script reads review-head — the head-bound gate cannot work"
grep -q 'Head-bound approval' "$DOC" \
  && ok || bad "the graph doc no longer explains the head-bound gate"
grep -q 'approval bound to THIS head' "$DOC" \
  && ok || bad "transition 41's guard must say the approval is bound to the head that merges"
for SW in HEADBOUND_REREVIEW HEADBOUND_ENFORCE; do
  grep -a -q "$SW" "$SCRIPT" && ok || bad "$SW is documented in the graph but absent from the script"
  grep -q "$SW" "$DOC" && ok || bad "$SW is a live switch in the script but undocumented in the graph"
done
# Four movers push a branch head after the approval and the doc is the only place
# that says which of them rebind it. A reader who cannot tell the rebase train
# from the lander here will re-open the starvation hole by hand.
for MOVER in 'rebase-train.sh' 'lander.sh' 'pre-PR rebase'; do
  grep -q "$MOVER" "$DOC" \
    && ok || bad "the head-bound section does not say whether $MOVER rebinds the approval"
done
grep -q 'job_verdict_rebind' "$DOC" \
  && ok || bad "the doc never names the helper the mechanical movers rebind through"
grep -q 'reviewed-sha' "$DOC" \
  && ok || bad "the doc still points the sweep's fallback at review-head, which the old pipeline never moved"

# ---------- 3c. scope gate: doc and script say the same thing ---------------
# SDLC item 4 runs inside the mechanical-gates block and settles in a demoter,
# so like the head-bound gate it has no row of its own — and for the same reason
# that is a rot risk, both halves are asserted here. tests/scope-gate-test.sh
# drives the behaviour; this only keeps the doc from describing a gate the
# script no longer runs.
grep -a -q '^# >>> scope gate' "$SCRIPT" \
  && ok || bad "the scope-gate demoter block is gone from the script"
grep -a -q 'scope-gate.sh' "$SCRIPT" \
  && ok || bad "nothing in the script calls bin/scope-gate.sh — the scope gate cannot work"
[ -x "$DIR/bin/scope-gate.sh" ] && ok || bad "bin/scope-gate.sh is missing or not executable"
grep -q 'Scope gate' "$DOC" && ok || bad "the graph doc no longer explains the scope gate"
grep -q 'no row of its own in the table above' "$DOC" \
  && ok || bad "the doc must say WHY the scope gate has no transition row"
for SW in SCOPE_GATE_ENFORCE SCOPE_GATE_MAX_LIST; do
  grep -a -q "$SW" "$SCRIPT" || grep -a -q "$SW" "$DIR/bin/scope-gate.sh" \
    && ok || bad "$SW is documented in the graph but absent from the scripts"
  grep -q "$SW" "$DOC" && ok || bad "$SW is a live switch but undocumented in the graph"
done
# The protected set is the only class that can move a tier, so the doc naming a
# member the classifier does not implement would be a promise nothing keeps.
for P in 'workflows' 'prisma' 'scripts/migrations'; do
  grep -q "$P" "$DOC" && grep -a -q "$P" "$DIR/bin/scope-gate.sh" \
    && ok || bad "the doc's protected set names '$P' but bin/scope-gate.sh does not classify it"
done

# ---------- 3d. plan gate: the one that refuses --------------------------
# SDLC item 5 is the first of these waves to add a real terminal, so unlike the
# three gates above it IS in the table — and that makes four more places it can
# drift: the script, the doc, every sweep SOP, and the console stage sets.
grep -a -q '^# >>> plan gate' "$SCRIPT" \
  && ok || bad "the plan-gate block is gone from the script"
grep -a -q 'plan-gate.sh' "$SCRIPT" \
  && ok || bad "nothing in the script calls bin/plan-gate.sh — the plan gate cannot work"
[ -x "$DIR/bin/plan-gate.sh" ] && ok || bad "bin/plan-gate.sh is missing or not executable"
grep -a -q '^# >>> ticket fingerprint' "$SCRIPT" \
  && ok || bad "the ticket-fp snapshot is gone — a resumed build cannot re-arm the stale gate"
grep -a -q '# >>> resume stale gate' "$SCRIPT" \
  && ok || bad "the resume stale gate is gone from the script"
grep -q 'plan gate that refuses' "$DOC" \
  && ok || bad "the graph doc no longer explains the plan gate"
grep -q 'ticket-fp' "$DOC" \
  && ok || bad "the doc must say WHERE the resumed build reads its pre-PLAN snapshot"
for SW in PLAN_GATE_ENFORCE PLAN_GATE_MAX_LIST; do
  grep -a -q "$SW" "$SCRIPT" || grep -a -q "$SW" "$DIR/bin/plan-gate.sh" \
    && ok || bad "$SW is documented in the graph but absent from the scripts"
  grep -q "$SW" "$DOC" && ok || bad "$SW is a live switch but undocumented in the graph"
done
# The gate REFUSES by default, which is the exception to the warn-first rule.
# A silent flip of that default would be invisible everywhere else.
grep -a -q 'PLAN_GATE_ENFORCE:-1' "$SCRIPT" \
  && ok || bad "PLAN_GATE_ENFORCE no longer defaults to 1 — the plan gate stopped refusing"
# EVERY sweep SOP has a close-out rule for the new terminal. This is the F5 gap
# in advance: a terminal the sweep has no instruction for lands between silent
# and improvised, and eleven prompts are eleven chances to forget one.
SOP_MISS=""; RELAUNCH_MISS=""
for P in "$DIR"/prompts/*.md; do
  grep -aq 'Results sweep FIRST' "$P" || continue
  grep -aq 'PLAN_MALFORMED' "$P" || SOP_MISS="$SOP_MISS $(basename "$P")"
  # ...and the rule RELAUNCHES. `requeued once` names no actor by itself: the
  # build exits, the dir is COMMENTED, and run-triage scopes its ticks off board
  # movement or RESULT dirs — neither of which a refused plan moves. If the sweep
  # does not relaunch it, "requeued" is a wait for the daily unscoped tick.
  grep -a 'PLAN_MALFORMED' "$P" | grep -aq 'relaunch' || RELAUNCH_MISS="$RELAUNCH_MISS $(basename "$P")"
done
[ -z "$SOP_MISS" ] && ok || bad "sweep SOPs with no PLAN_MALFORMED rule:$SOP_MISS"
[ -z "$RELAUNCH_MISS" ] && ok || bad "sweep SOPs whose requeue names no relaunch:$RELAUNCH_MISS"
# ...and the beat stage the terminal rides on is one the console knows. F6: a
# stage the kanban does not know makes a stopped build invisible instead.
grep -a -qE '^[[:space:]]*BB plan_malformed' "$SCRIPT" \
  && ok || bad "the PLAN_MALFORMED path beats no stage — the console cannot show it"
# ...and the JOB ROW agrees with that beat. A requeued or held plan is parked,
# not failed: the console files plan_malformed under PARKED_STAGES, so a `failed`
# job row would make the two halves of the same build disagree.
PARKED_CASE=$(grep -a -m1 'st=parked' "$SCRIPT")
case "$PARKED_CASE" in *PLAN_MALFORMED\**) ok ;;
  *) bad "PLAN_MALFORMED closes the job as failed, but the console parks it: $PARKED_CASE" ;; esac
case "$PARKED_CASE" in *PLAN_STALE\**) ok ;;
  *) bad "PLAN_STALE closes the job as failed, but it is a deferral: $PARKED_CASE" ;; esac
for F in src/lib/stages.js 'functions/api/cockpit/[[path]].js'; do
  grep -q 'plan_malformed' "$DIR/console-ui/$F" \
    && ok || bad "console-ui/$F does not know the plan_malformed stage — a stopped build falls off the board"
done

# ---------- 3e. every stop has an owner (SDLC item 6) --------------------
# The overlap timeout is the one stop this item ADDS, and like the gates above
# it settles inside run-build.sh rather than in a stage of its own — but unlike
# them it can end the build, so both halves are pinned: the markers the block is
# extracted by (tests/stop-owners-test.sh drives the behaviour), and the doc
# section that explains the wake condition.
grep -a -q '^# >>> overlap wait' "$SCRIPT" \
  && ok || bad "the overlap-wait block is gone from the script"
grep -a -q 'conflict-check.sh' "$SCRIPT" \
  && ok || bad "nothing in the script calls bin/conflict-check.sh — the overlap wait cannot work"
grep -q 'Every stop has an owner' "$DOC" \
  && ok || bad "the graph doc no longer explains item 6's stops"
for SW in OVERLAP_DEFER_ENFORCE OVERLAP_WAIT_SECS; do
  grep -a -q "$SW" "$SCRIPT" && ok || bad "$SW is documented in the graph but absent from the script"
  grep -q "$SW" "$DOC" && ok || bad "$SW is a live switch in the script but undocumented in the graph"
done
# It DEFERS by default (SDLC item 6 row 6): the union-merge class the wait
# exists to kill is the expensive side, so proceeding into the collision is the
# behaviour that has to be opted into, not the deferral. A silent flip back to 0
# would restore the exact stop this item closed while the doc still claims it is
# shut. Same for the cap: it has a numeric fallback, so a typo cannot un-cap it.
grep -a -q 'OVERLAP_DEFER_ENFORCE:-1' "$SCRIPT" \
  && ok || bad "OVERLAP_DEFER_ENFORCE no longer defaults to 1 — the timeout went back to proceeding into the collision"
# THE FALLBACK IS 0 SINCE 2026-09-13 ("we never lock and serialize"): a build may
# not wait in line behind another build, so the shipped cap is "do not wait" and
# the first overlap defers. The property this pins is unchanged — a typo must not
# un-cap the loop — and 0 is the strongest cap there is.
grep -a -q 'OV_CAP=0 ;;' "$SCRIPT" \
  && ok || bad "OVERLAP_WAIT_SECS lost its numeric fallback — a typo removes the cap entirely"
# The deferral is only useful if it says what it is waiting for.
grep -a -q 'wakes when' "$SCRIPT" \
  && ok || bad "the overlap deferral's RESULT no longer names a wake condition"
# ...and the timeout is recorded whichever way it goes, file plus ledger row.
grep -a -q 'overlap-defer.txt' "$SCRIPT" \
  && ok || bad "the overlap timeout writes no file fallback"
grep -a -q 'job_artifact_put overlap_defer' "$SCRIPT" \
  && ok || bad "the overlap timeout never reaches the ledger — the 'proceeded' rows are the evidence for arming it"

# ---------- 3f. KIND: the bug flow (SDLC item 7) -------------------------
# Item 7 adds no terminal and no transition — it changes which PROMPT a stage
# sends and which optional lenses run — so like items 1, 3 and 4 it can only rot
# in the doc. tests/kind-flow-test.sh drives the behaviour; this pins that the
# doc still describes a pipeline the script runs.
grep -a -q '^# >>> kind flow' "$SCRIPT" \
  && ok || bad "the kind-flow block is gone from the script"
grep -a -q '^# >>> kind demoter' "$SCRIPT" \
  && ok || bad "the kind demoter block is gone from the script"
grep -a -q 'kind-gate.sh' "$SCRIPT" \
  && ok || bad "nothing in the script calls bin/kind-gate.sh — the bug flow cannot work"
[ -x "$DIR/bin/kind-gate.sh" ] && ok || bad "bin/kind-gate.sh is missing or not executable"
grep -q 'KIND: the bug flow' "$DOC" && ok || bad "the graph doc no longer explains the bug flow"
grep -q 'No new terminal and no new transition' "$DOC" \
  && ok || bad "the doc must say WHY the bug flow has no transition row"
grep -a -q 'KIND_GATE_ENFORCE' "$SCRIPT" \
  && ok || bad "KIND_GATE_ENFORCE is documented in the graph but absent from the script"
grep -q 'KIND_GATE_ENFORCE' "$DOC" \
  && ok || bad "KIND_GATE_ENFORCE is a live switch in the script but undocumented in the graph"
# It WARNS by default: this gate can withhold a merge AND skip verification, so
# a silent flip to 1 would arm both on a classifier the fleet has no data on.
grep -a -q 'KIND_GATE_ENFORCE:-0' "$SCRIPT" \
  && ok || bad "KIND_GATE_ENFORCE no longer defaults to 0 — a new demoter armed itself"
# The bug flow's whole point: the reproduction becomes red.txt, which is the
# artifact the repro gate already checks at the merge base.
grep -a -q 'KIND_EXEC_NOTE' "$SCRIPT" \
  && ok || bad "the execute prompt no longer carries the bug-flow instruction"
BUGNOTE=$(grep -a -m1 'BUG FLOW' "$SCRIPT")
case "$BUGNOTE" in *red.txt*) ok ;;
  *) bad "the bug-flow prompt never names red.txt — nothing connects the reproduction to the repro gate" ;; esac
# The path in that note must be the EXPANDED one. An escaped \$BUILD reaches
# the executing session as literal text and writes /red.txt, while the execute
# prompt's own red.txt sentence uses the real path — two files, one prompt.
case "$BUGNOTE" in *'\$BUILD/red.txt'*)
  bad "the bug-flow prompt escapes \$BUILD — the executor gets a literal, not the build dir" ;;
  *) ok ;; esac
# The hint the PLAN prompt carries is graded by its evidence: a type field or a
# label is the board SAYING the kind, a title prefix is the gate READING one off
# a sentence. The weakest source must not be presented in the strongest words.
grep -a -q 'KIND_HINT_SRC" in' "$SCRIPT" \
  && ok || bad "the plan hint no longer distinguishes its evidence — a title prefix asserts as hard as a label"
grep -a -q 'title=\*)' "$SCRIPT" \
  && ok || bad "the title-prefix branch of the plan hint is gone"
# ...and the kind reaches the two readers the doc claims: the ledger and the
# findings log.
grep -a -q 'job_artifact_put build_kind' "$SCRIPT" \
  && ok || bad "the KIND never reaches the ledger — the doc claims a build_kind row"
grep -a -q 'kind-gate.sh' "$DIR/bin/findings-log.sh" \
  && ok || bad "findings-log.sh does not import the kind gate — the kind= field would be a second definition"
# jobs.kind means something else entirely (which pipeline this is). The doc
# says so; assert the script did not quietly start writing the KIND there.
grep -q 'jobs.kind' "$DOC" \
  && ok || bad "the doc must distinguish the build KIND from the jobs.kind column"

# ---------- 4. the findings are specific enough to act on ----------
# A findings section that says "some exits are silent" helps nobody.
for F in F1 F2 F3 F4 F5 F6 F7; do
  grep -q "$F" "$DOC" && ok || bad "finding $F is missing"
done
# F1-F4 are CLOSED (SDLC item 6): each of those four exits must now write the
# owner the doc says it writes. This is the direction that rots — a refactor
# that drops the RESULT restores the leak while the doc still claims it is shut.
REPO_LINE=$(grep -a -m1 '^\[ -d "\$REPO" \]' "$SCRIPT")
case "$REPO_LINE" in *'RESULT "BUILD_REFUSED'*) ok ;;
  *) bad "F2 (missing repo) exits without a RESULT again: $REPO_LINE" ;; esac
for F in F3 F4; do
  L=$(grep -a -m1 "# $F\$" "$SCRIPT")
  case "$L" in *'RESULT "BUILD_DEFERRED'*) ok ;;
    *) bad "$F exits without a RESULT again: ${L:-<line gone>}" ;; esac
done
# F1 has no build dir to write into, so ALERTS is its only owner.
grep -a -q 'resume abandoned: RESUME_BUILD' "$SCRIPT" \
  && ok || bad "F1 (a resume dir that vanished) writes neither a RESULT nor an ALERTS line"

# ---------- 5. F5 is CLOSED, and every terminal has an owner ----------
# This check used to assert the OPPOSITE: that the five orphan terminals were
# still absent from the sweep SOP, so that whoever fixed them had to come back
# and update the doc. Item 6 fixed them, so the assertion inverts — every
# terminal run-build.sh writes must have a close-out rule in EVERY sweep SOP.
# Eleven prompts are eleven chances to forget one, which is how F5 happened.
SOPS=$(grep -al 'Results sweep FIRST' "$DIR"/prompts/*.md)
[ -n "$SOPS" ] && ok || bad "no sweep SOPs found — has the results-sweep section been renamed?"
# SHARE MIRROR: 2, not 11 — the per-project prompts are not published, so
# the TEMPLATEs are the only sweep SOPs here. Upstream this is one per
# watched project and the number is the whole point of the check.
[ "$(grep -c . <<<"$SOPS")" -ge 2 ] \
  && ok || bad "only $(grep -c . <<<"$SOPS") sweep SOPs found, expected at least 2 — extraction likely broken"
UNOWNED=""
while read -r t; do
  [ -n "$t" ] || continue
  for P in $SOPS; do
    grep -aq "$t" "$P" || UNOWNED="$UNOWNED $(basename "$P"):$t"
  done
done <<<"$SCRIPT_TERMS"
# BUILD_DEAD is written by resume-dead-builds.sh, not by run-build.sh, and the
# SOPs have carried its rule since long before this wave — assert it anyway,
# because a build that died repeatedly is the loudest stop there is.
for P in $SOPS; do
  grep -aq BUILD_DEAD "$P" || UNOWNED="$UNOWNED $(basename "$P"):BUILD_DEAD"
done
[ -z "$UNOWNED" ] && ok || bad "terminals with no close-out rule in a sweep SOP:$UNOWNED"
# The two that matter most do not just APPEAR — they carry the action. A
# security block that reads as "post the what-shipped comment" would be worse
# than the silence it replaced.
for P in $SOPS; do
  RULE=$(grep -a 'SECURITY_BLOCKED' "$P" | head -1)
  case "$RULE" in *ALERTS.log*) ;; *) bad "$(basename "$P"): the SECURITY_BLOCKED rule raises no ALERTS line" ;; esac
  case "$RULE" in *"held for a human"*) ;; *) bad "$(basename "$P"): the SECURITY_BLOCKED rule does not hold the change for a human" ;; esac
done
ok

# ---------- 5c. F7 records the accepted evasion path ----------
# The added-vs-modified split leaves a vacuous test appended to an EXISTING file
# uncaught. That is a chosen trade, and the point of writing it down is that the
# next person to find it reads "accepted, here is why" instead of "bug".
grep -q 'evasion path' "$DOC" && ok || bad "F7 must name the evasion path explicitly"
grep -q 'accepted by design, not an oversight' "$DOC" \
  && ok || bad "F7 must say the trade was chosen, not missed"
grep -q 'MODNOTE' "$DOC" && ok || bad "F7 must say how it degrades (reviewer gets the modified-file evidence)"
# ...and the mechanism it describes must still exist in the gate.
grep -a -q 'diff-filter=A ' "$DIR/bin/repro-gate.sh" \
  && ok || bad "F7 describes an ADDED-only gate but repro-gate no longer filters that way"
grep -a -q 'MODNOTE' "$DIR/bin/repro-gate.sh" \
  && ok || bad "F7 claims the reviewer is told about modified tests, but MODNOTE is gone"

# ---------- 6. the two vocabularies stay distinct (F6) ----------
# Beat stages are lowercase, RESULT terminals are UPPER_SNAKE. Mixing them is
# how a live build falls out of the kanban without appearing anywhere else.
BEATS=$(grep -a -oE '^BB [a-z_]+' "$SCRIPT" | awk '{print $2}' | sort -u)
while read -r b; do
  [ -n "$b" ] || continue
  U=$(tr '[:lower:]' '[:upper:]' <<<"$b")
  grep -qxF "$U" <<<"$SCRIPT_TERMS" && bad "beat stage '$b' collides with terminal '$U' — the two vocabularies must stay distinct"
done <<<"$BEATS"
ok

echo "run-build-graph-test: $PASS pass, $FAIL fail"
[ "$FAIL" -eq 0 ]
