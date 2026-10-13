#!/bin/bash
# tests/plan-blocked-marker-test.sh — the PLAN gate must refuse a plan that
# DECLARES itself parked, never a plan whose TITLE happens to contain the word.
# Run from anywhere: tests/plan-blocked-marker-test.sh   (exit 0 = all pass)
#
# BH-387. The gate shipped in the first harness commit as
#   head -1 "$BUILD/plan.md" | grep -q BLOCKED
# an unanchored substring match, and the same loose test decided checkpoint
# reuse. Any ticket whose title carries the harness's own vocabulary
# (BLOCKED_HUMAN, REVIEW_BLOCKED, PLAN_BLOCKED, SECURITY_BLOCKED) produced a
# complete plan that the gate then threw away as "open questions": builds
# cromford-BH-292-202609151734 and -202609151823, and BH-387's own
# -202609160733 and -202609161133, all died that way with full plans, and the
# triage sweep posted a false "open questions" comment on #292 at 17:55Z.
#
# Both directions are load-bearing and they fail differently:
#   refuses a real plan   -> the ticket can never build, at any cost, forever
#   accepts a parked plan -> the builder executes a plan that says "I do not
#                            know what to build", which is the failure the
#                            PLAN_BLOCKED terminal exists to prevent.
#
# The predicate and the gate `if` are lifted VERBATIM out of bin/run-build.sh by
# their markers and executed — no paraphrase of the regex lives in this file —
# and every case asserts on the ARTIFACT the pipeline actually reads ($BUILD/RESULT
# plus the exit code), not on source text. No network, no clock, no LLM.
set -uo pipefail
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

. "$(dirname "$0")/lib/scratch.sh" || exit 1
. "$DIR/tests/lib/rb-all.sh" || exit 1
RB_ALL=$(rb_all "$DIR" "$T/run-build.all.sh")
SCRIPT="$RB_ALL"

# --- the two blocks, lifted verbatim (same idiom as run-build-checkpoint-test) -
cut_block() { # cut_block <marker-word...> <outfile>
  local name="$1" out="$2"
  awk -v n="$name" 'index($0,"# >>> " n)==1{f=1;next} index($0,"# <<< " n)==1{exit} f' \
    "$SCRIPT" > "$out"
}
cut_block "plan blocked marker" "$T/marker.sh"
cut_block "plan blocked gate"   "$T/gate.sh"

[ -s "$T/marker.sh" ] && ok || bad "could not extract the 'plan blocked marker' block from bin/run-build.sh — markers missing?"
[ -s "$T/gate.sh" ]   && ok || bad "could not extract the 'plan blocked gate' block from bin/run-build.sh — markers missing?"
bash -n "$T/marker.sh" 2>/dev/null && ok || bad "the extracted 'plan blocked marker' block does not parse on its own"
bash -n "$T/gate.sh"   2>/dev/null && ok || bad "the extracted 'plan blocked gate' block does not parse on its own"
grep -q 'PLAN_IS_BLOCKED()' "$T/marker.sh" \
  && ok || bad "the 'plan blocked marker' block does not define PLAN_IS_BLOCKED()"
grep -q 'PLAN_IS_BLOCKED' "$T/gate.sh" \
  && ok || bad "the 'plan blocked gate' block does not call PLAN_IS_BLOCKED — it is still judging the plan itself"

# --- drive the real gate over a real plan file --------------------------------
N=0
drive() { # drive <first-line-of-plan>   -> sets RC and B (the build dir)
  N=$((N+1)); B="$T/build$N"; mkdir -p "$B"
  printf '%s\n## Scope\none task, fully specified.\n' "$1" > "$B/plan.md"
  BUILD="$B" bash -c '
    set -uo pipefail
    BB() { :; }
    RESULT() { echo "$*" > "$BUILD/RESULT"; }
    # shellcheck disable=SC1090
    . "$1"
    # shellcheck disable=SC1090
    . "$2"
  ' _ "$T/marker.sh" "$T/gate.sh" >/dev/null 2>&1
  RC=$?
}

accepts() { # accepts <first-line> — the plan flows on to the rest of PLAN
  drive "$1"
  if [ "$RC" -ne 0 ]; then
    bad "refused a plan it must accept (rc=$RC): $1"
  elif [ -e "$B/RESULT" ]; then
    bad "refused a plan it must accept (wrote RESULT '$(cat "$B/RESULT")'): $1"
  else
    ok
  fi
}

refuses() { # refuses <first-line> — the plan is parked as PLAN_BLOCKED
  drive "$1"
  if [ "$RC" -ne 4 ]; then
    bad "accepted a parked plan (rc=$RC, want 4): $1"
  elif [ ! -e "$B/RESULT" ]; then
    bad "accepted a parked plan (no RESULT written): $1"
  else
    local r; r=$(cat "$B/RESULT")
    if [ "$(awk '{print $1}' <<<"$r")" != "PLAN_BLOCKED" ]; then
      bad "parked plan wrote the wrong terminal '$r': $1"
    elif [ "$(awk '{print $2}' <<<"$r")" != "$B/plan.md" ]; then
      bad "PLAN_BLOCKED did not name the plan path ('$r'): $1"
    else
      ok
    fi
  fi
}

# ---------- 1. a ticket TITLE that merely contains the word is not a park -----
# Every word in the harness's own blocked vocabulary appears here, because these
# are the titles that actually burned builds.
accepts '# BH-1 — sticky BLOCKED_HUMAN park'
accepts '# BH-387 — run-build PLAN_BLOCKED gate matches the ticket title: any plan whose first line contains BLOCKED is refused'
accepts '# BH-292 — conductor: sticky BLOCKED_HUMAN per (PR, head): #490 oscillates'
accepts '# BH-5 — REVIEW_BLOCKED / SECURITY_BLOCKED rows in the console'
accepts '# BLOCKED_HUMAN must be sticky per (PR, head)'
accepts '# BH-9 — merge sweep: a BLOCKED PR must not oscillate'
# Adversarial, not a real title: the marker word must END where it starts. A
# line-start BLOCKED followed by another letter or digit is a different word.
accepts '# BLOCKEDSTATE rows in the console'
accepts 'BLOCKED2 is a status name, not a park'
accepts ''   # blank first line, ordinary plan underneath

# ---------- 2. a plan that declares itself parked is still refused ------------
# These are the literal first lines the planner prompts ask for
# (run-build.sh "write BLOCKED / BLOCKED-NEEDS-CLARIFICATION as the first line",
# run-preplan.sh:107) plus the decorated forms a model actually emits.
refuses '# BLOCKED: two readings'
refuses 'BLOCKED-NEEDS-CLARIFICATION'
refuses 'BLOCKED-NEEDS-CLARIFICATION: the client has not answered how the rep sets the discount'
refuses 'BLOCKED'
refuses "BLOCKED: the thread's latest comment says on hold"
refuses 'PLAN_BLOCKED the thread says on hold'
refuses '**BLOCKED** — the newest comment puts this on hold'
refuses "## BLOCKED — awaiting the client's answer"
# Heading AND bold together, and the punctuation a model actually writes after the
# word. The first anchored regex admitted only one run of decoration and only
# `- : *` or a space after BLOCKED, so each of these parked plans flowed on to
# plan-gate.sh, failed it for having no VALIDATE lines, and was thrown away as
# PLAN_MALFORMED — the park reason lost, no open-questions comment on the ticket.
refuses '# **BLOCKED**'
refuses '### **BLOCKED** on hold'
refuses 'BLOCKED. The thread says on hold'
refuses 'BLOCKED; two readings'
refuses 'BLOCKED—awaiting the client'

# ---------- 3. absence is not a park -----------------------------------------
# The checkpoint-reuse branch keeps its own `-s` guard, but the predicate must
# not call a missing or empty plan "parked" on its own account either.
pred() { # pred <path> -> rc of PLAN_IS_BLOCKED on that path
  bash -c 'set -uo pipefail
    # shellcheck disable=SC1090
    . "$1"; PLAN_IS_BLOCKED "$2"' _ "$T/marker.sh" "$1" >/dev/null 2>&1
}
: > "$T/empty.md"
pred "$T/does-not-exist.md" && bad "PLAN_IS_BLOCKED called a MISSING plan parked" || ok
pred "$T/empty.md"          && bad "PLAN_IS_BLOCKED called an EMPTY plan parked"   || ok

# ---------- 4. both production call sites go through the predicate -----------
# D3: guarded source pin. The extracted-gate cases above prove the gate itself;
# this is the only way to pin the checkpoint-reuse condition at the other end of
# the script, so it asserts an exact count in both directions — a renamed
# predicate or a reverted line fails here instead of silently matching zero.
# Three since BH-5799: the plan thread gate judges only a plan the checkpoint
# would reuse, so it asks the same predicate right before the checkpoint.
CALLS=$(grep -c 'PLAN_IS_BLOCKED "$BUILD/plan.md"' "$SCRIPT")
[ "$CALLS" = 3 ] && ok \
  || bad "expected 3 PLAN_IS_BLOCKED call sites in bin/run-build.sh (plan thread gate + checkpoint reuse + plan gate), found $CALLS"
LEGACY=$(grep -c 'head -1 "$BUILD/plan.md" | grep -q BLOCKED' "$SCRIPT")
[ "$LEGACY" = 0 ] && ok \
  || bad "bin/run-build.sh still judges a plan by an unanchored first-line grep ($LEGACY site(s))"

echo "PASS $PASS  FAIL $FAIL"
exit $((FAIL>0))
