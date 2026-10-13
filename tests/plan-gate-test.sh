#!/bin/bash
# tests/plan-gate-test.sh — SDLC item 5: does every TASK in the plan carry the
# command that proves it and the criterion it delivers, and what happens when
# one does not?
#
# The hole this closes: the 2026-08-14 template check asked whether the FILE
# contained a VALIDATE line and a SATISFIES line anywhere. One traced task in a
# ten-task plan passed it. A plan that failed it bought one repair pass and then
# went to EXECUTE regardless, with a warning in a log nobody reads — so an
# untraced plan still cost a full execute session and a paid review. A resumed
# build skipped both that check and the thread stale-gate, by design comment.
#
# WHY DRIVEN AND NOT GREPPED. `grep -q plan-gate bin/run-build.sh` passes on a
# parser that calls every bullet a task, on a refusal wired to the wrong
# default, and on a requeue that holds the first time it fires. What is under
# test is the classification (against the shapes real plans on this box use),
# the refusal, requeued-once-then-held, the resume stale re-arm, and that the
# verdict reaches the ledger row in the shape its reader expects.
#
# The run-build blocks are extracted VERBATIM by their markers, so a regression
# in the shipped lines fails here rather than in a paraphrase. No network, no
# model call, no secrets: markdown fixtures on disk, the model call and the
# ledger stubbed. Run from anywhere: tests/plan-gate-test.sh (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
. "$DIR/tests/lib/rb-all.sh" || exit 1
RB_ALL=$(rb_all "$DIR" "$T/run-build.all.sh")
mkdir -p "$T/h/bin" "$T/h/state" "$T/h/logs"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null 2>&1 || { echo "jq missing — skipping"; exit 0; }

GATE="$DIR/bin/plan-gate.sh"
[ -x "$GATE" ] && ok || bad "bin/plan-gate.sh is missing or not executable"
# A fake HARNESS root so nothing here writes into the checkout: the requeue
# ledger's file fallback lives under $HARNESS/state.
cp "$GATE" "$T/h/bin/plan-gate.sh"

# ============================================================================
# 1. bin/plan-gate.sh — the parser, against the shapes real plans use
# ============================================================================
plan() { printf '%s\n' "$1" > "$T/plan.md"; }
run()  { G=$("$GATE" "${1:-$T/plan.md}" 2>&1); GRC=$?; }
verdict() { sed -n 's/^PLAN_TRACE:[[:space:]]*//p' <<<"$G" | tail -1; }
field()   { sed -n "s/^$1:[[:space:]]*//p" <<<"$G" | tail -1; }

# 1a. the shape the plan prompt asks for: a heading per task, both lines under
#     it, and the four contract sections at the end.
plan '# WD-9

## Tasks

### Task 1 — add the column
- Edit prisma/schema.prisma
- VALIDATE: `npm run test:db`
- SATISFIES: "clients need a status field"

### Task 2 — surface it
- VALIDATE: `npm run build`
- SATISFIES: "show it on the client page"

## Acceptance tests
- tests/x.test.ts

SIZE: S'
run
[ "$GRC" = 0 ] && ok || bad "a fully traced plan must be rc 0 (got $GRC: $G)"
[ "$(verdict)" = ok ] && ok || bad "a fully traced plan must read ok (got: $G)"
[ "$(field PLAN_TASKS)" = 2 ] && ok || bad "expected 2 tasks, got $(field PLAN_TASKS): $G"

# 1b. THE DEFECT THE OLD CHECK COULD NOT SEE: one task traced, one not. The
#     whole-file grep passed this plan; the per-task gate names the offender.
plan '# WD-9
### Task 1 — add the column
- VALIDATE: `npm run test:db`
- SATISFIES: "clients need a status field"

### Task 2 — surface it
- VALIDATE: `npm run build`

SIZE: S'
run
[ "$GRC" = 2 ] && ok || bad "a half-traced plan must be rc 2 (got $GRC: $G)"
[ "$(field PLAN_UNTRACED)" = 1 ] && ok || bad "expected exactly 1 untraced task: $G"
grep -q 'UNTRACED: Task 2' <<<"$G" && ok || bad "the report must NAME the untraced task: $G"
grep -q 'no SATISFIES' <<<"$G" && ok || bad "the report must say WHICH line is missing: $G"

# 1c. tasks as numbered list items under a "## Tasks" heading — the other shape
#     plans use. "Tasks" is a section, not a task: scoring it as one block would
#     collapse the whole plan and hide the untraced item.
plan '# WD-9
## Tasks
1. Add the column. VALIDATE: `npm test`. SATISFIES: criterion 1
2. Render it. VALIDATE: `npm run build`
SIZE: S'
run
[ "$GRC" = 2 ] && ok || bad "a numbered-list plan must still be scored per item (got $GRC: $G)"
[ "$(field PLAN_TASKS)" = 2 ] && ok || bad "the ## Tasks heading must not collapse the list: $G"

# 1d. NESTING: a task heading with its own detail bullets is ONE task, and the
#     traces under those bullets are the heading's. Splitting on every bullet
#     orphans them and refuses a correct plan.
plan '# WD-9
### Task 1 — add the column
- Edit prisma/schema.prisma
- Regenerate the client
- VALIDATE: `npm run test:db`
- SATISFIES: criterion 1
SIZE: S'
run
[ "$GRC" = 0 ] && ok || bad "detail bullets under a task must not become tasks (got $GRC: $G)"
[ "$(field PLAN_TASKS)" = 1 ] && ok || bad "a task with detail bullets is ONE task: $G"

# 1d-bis. ...and a DEEPER heading inside a task block is part of that task too.
#     "#### Steps" under "### Task 1" used to flush Task 1 as untraced and score
#     the sub-heading instead, refusing a plan whose traces were right there.
plan '# WD-9
### Task 1 — add the column
#### Steps
- Edit prisma/schema.prisma
- VALIDATE: `npm run test:db`
- SATISFIES: criterion 1

### Task 2 — surface it
- VALIDATE: `npm run build`
- SATISFIES: criterion 2
SIZE: S'
run
[ "$GRC" = 0 ] && ok || bad "a sub-heading must not steal its task-s traces (got $GRC: $G)"
[ "$(field PLAN_TASKS)" = 2 ] && ok || bad "a sub-heading is not a third task: $G"
#     ...and the sibling task after it is still scored on its own.
plan '# WD-9
### Task 1 — add the column
#### Steps
- VALIDATE: `npm run test:db`
- SATISFIES: criterion 1

### Task 2 — surface it
- VALIDATE: `npm run build`
SIZE: S'
run
[ "$GRC" = 2 ] && ok || bad "nesting must not make the NEXT task pass for free (got $GRC: $G)"
grep -q 'UNTRACED: Task 2' <<<"$G" && ok || bad "the untraced sibling must still be named: $G"

# 1e. a fenced code block is not a task and its VALIDATE: is not a trace.
plan '# WD-9
### Task 1 — add the column
```bash
# VALIDATE: this is a sample, not this task-s proof
```
- VALIDATE: `npm test`
- SATISFIES: criterion 1
SIZE: S'
run
[ "$GRC" = 0 ] && ok || bad "a fenced sample must not affect the verdict (got $GRC: $G)"
[ "$(field PLAN_TASKS)" = 1 ] && ok || bad "a fence must not open a task: $G"

# 1f. the contract's OWN sections are not tasks. Every plan ends with them, they
#     name both keywords, and scoring them refuses every plan on the box.
plan '# WD-9
### Task 1 — add the column
- VALIDATE: `npm test`
- SATISFIES: criterion 1

## Requirements coverage
| requirement | task | test |
| the column | Task 1 | VALIDATE: npm test |

## Acceptance tests
- tests/x.test.ts asserts the column renders

## Verification checklist (pre-PR, in order)
1. `npx tsc --noEmit` — VALIDATE: exit 0, unpiped.
2. `npm run build` — VALIDATE: exit 0.

## QA screens
- /clients
SIZE: S'
run
[ "$GRC" = 0 ] && ok || bad "the contract sections must not be scored as tasks (got $GRC: $G)"
[ "$(field PLAN_TASKS)" = 1 ] && ok || bad "only the real task should be counted: $G"

# 1f-bis. A SKIPPED SECTION MUST DISARM THE TASK BLOCK IT FOLLOWS. `## Acceptance
#     tests` is the one section the plan prompt asks to fill with concrete test
#     commands, so its first bullet is often a `- VALIDATE:` line. If closing a
#     task block leaves the "a task heading is open" flag set, that bullet opens
#     a phantom block and a correct plan is refused (`(before the first
#     heading) — no SATISFIES`). Armed, that is a repair session and a requeue.
plan '# WD-9
### Task 1 — add the column
- VALIDATE: `npm test`
- SATISFIES: criterion 1

## Verification checklist
1. `npx tsc --noEmit`

## Acceptance tests
- VALIDATE: `npm test -- tests/x.test.ts` asserts the column renders
SIZE: S'
run
[ "$GRC" = 0 ] && ok || bad "a trace bullet under ## Acceptance tests must not open a task (got $GRC: $G)"
[ "$(field PLAN_TASKS)" = 1 ] && ok || bad "only the real task should be counted: $G"
grep -q 'before the first heading' <<<"$G" && bad "the phantom pre-heading block is back: $G" || ok

# 1f-ter. THE OTHER HALF OF THE SAME BUG, and the dangerous one: a real task
#     heading AFTER a skipped section must still be scored. Folded into the
#     closed block instead, an untraced Task 2 is swallowed and the plan passes.
plan '# WD-9
### Task 1 — add the column
- VALIDATE: `npm test`
- SATISFIES: criterion 1

## Verification checklist
1. `npx tsc --noEmit`

## Task 2 — render it
- Edit the page
SIZE: S'
run
[ "$(field PLAN_TASKS)" = 2 ] && ok || bad "a task heading after a skipped section must still be a task: $G"
[ "$GRC" = 2 ] && ok || bad "the untraced Task 2 must be caught, not swallowed (got $GRC: $G)"
grep -q 'UNTRACED: Task 2' <<<"$G" && ok || bad "Task 2 must be named as the offender: $G"

# 1g. A MENTION IS NOT A TRACE LINE. Thirty plans on this box open a discipline
#     bullet with "D6: every VALIDATE command runs unpiped" — reading that as a
#     task made every one of them untraced.
plan '# WD-9
### Task 1 — add the column
- VALIDATE: `npm test`
- SATISFIES: criterion 1

## Build-discipline rules that bite
- **D6** every VALIDATE command runs unpiped and records its true exit code.
- **Mobile**: the panel stays a grid; Task 1 VALIDATE covers 375px.
SIZE: S'
run
[ "$GRC" = 0 ] && ok || bad "a prose mention of the keywords must not open a task (got $GRC: $G)"

# 1h. ...and prose ABOUT a task is not a task label. project-1 TK-232 opens a
#     dependency bullet with "Task 0 below gates the build on the helper".
plan '# WD-9
## Dependency
- Task 0 below gates the build on the helper existing after a fresh pull of main.

### Task 1 — add the column
- VALIDATE: `npm test`
- SATISFIES: criterion 1
SIZE: S'
run
[ "$GRC" = 0 ] && ok || bad "a sentence starting 'Task 0 below ...' is not a task block (got $GRC: $G)"

# 1i. ONCE a block is a task, the keyword counts however it is written. project-4
#     TK-1040 wrote "VALIDATE (each run unpiped, D6): npm run ...".
plan '# WD-9
### Task 1 — add the column
- VALIDATE (each run unpiped, true exit codes — D6): `npm test`
- SATISFIES: criterion 1

### Task 2 — render it
- VALIDATE: `npm run build`
- SATISFIES: criterion 2
SIZE: S'
run
[ "$GRC" = 0 ] && ok || bad "a parenthetical before the colon is still a trace (got $GRC: $G)"

# 1j. THE FLOOR, AND THE BUG IN THE OLD ONE. run-build.sh grepped
#     '^[[:space:]]*VALIDATE:', which does not match '- VALIDATE:' — the bullet
#     form 27 of the last 150 plans use. Every one of them bought a repair
#     session, and as a refusal it would have blocked them all.
plan '# WD-9
### Task 1 — add the column
- VALIDATE: `npm test`
- SATISFIES: criterion 1
SIZE: S'
run
grep -q 'PLAN_TRACE_LINES: validate=1 satisfies=1' <<<"$G" \
  && ok || bad "the floor must count the '- VALIDATE:' bullet form: $G"
grep -q '^[[:space:]]*VALIDATE:' "$T/plan.md" \
  && bad "the fixture stopped exercising the bullet form the old grep missed" || ok

# 1k. a plan with none of the lines at all is the wish list the floor exists for
#     — untraced, not "no tasks found".
plan '# WD-9
Prose about the change. No commands, no criteria.
## QA screens
- /clients
SIZE: S'
run
[ "$GRC" = 2 ] && ok || bad "a plan with no trace lines anywhere must be rc 2 (got $GRC: $G)"
grep -q 'UNTRACED: the whole plan' <<<"$G" && ok || bad "the floor failure must say so plainly: $G"

# 1l. a TRACED plan whose tasks this parser cannot see is `unavailable`, never a
#     refusal. A gate that cannot run says so — the rule every other gate here
#     learned the expensive way.
plan '# WD-9
Prose describing the change, with no task blocks this parser can see.

## Acceptance tests
- tests/x.test.ts — VALIDATE: `npm test`, SATISFIES: criterion 1
SIZE: S'
run
[ "$GRC" = 3 ] && ok || bad "a traced plan with no recognizable task blocks must be rc 3 (got $GRC: $G)"
[ "$(verdict)" = unavailable ] && ok || bad "rc 3 must read unavailable (got: $G)"

# 1m. no file at all is rc 3, not a crash and not a refusal.
run "$T/nope.md"
[ "$GRC" = 3 ] && ok || bad "a missing plan must be rc 3 (got $GRC: $G)"

# 1n. the listing is bounded, the counts are not.
{ echo '# WD-9'; for i in $(seq 1 12); do printf '### Task %s\n- VALIDATE: x\n\n' "$i"; done; } > "$T/plan.md"
G=$(PLAN_GATE_MAX_LIST=3 "$GATE" "$T/plan.md" 2>&1); GRC=$?
[ "$(field PLAN_UNTRACED)" = 12 ] && ok || bad "PLAN_GATE_MAX_LIST must not truncate the COUNT: $G"
[ "$(grep -c 'UNTRACED: Task' <<<"$G")" = 3 ] && ok || bad "PLAN_GATE_MAX_LIST=3 must bound the listing: $G"
grep -q 'and 9 more' <<<"$G" && ok || bad "a truncated listing must say how many it dropped: $G"

# ============================================================================
# 2. bin/run-build.sh — the refusal, the requeue, and the kill switch
# ============================================================================
awk '/^# >>> plan gate/{f=1;next} /^# <<< plan gate/{exit} f' \
  "$RB_ALL" > "$T/gate.sh"
[ -s "$T/gate.sh" ] && ok || bad "could not extract the plan-gate block — markers missing?"

# Drive the shipped lines with everything they touch stubbed: the model call
# (CC), the beat, the ledger, and RESULT/exit. REPAIRED=<text> makes the stubbed
# repair session rewrite the plan, which is what a real one does.
drive() { # drive <plan-text> [env...]
  local body="$1"; shift
  rm -rf "$T/b"; mkdir -p "$T/b"
  printf '%s\n' "$body" > "$T/b/plan.md"
  ( env HARNESS="$T/h" BUILD="$T/b" PROJECT=widget-os KEY=WD-9 PLAN_MODEL=stub-model \
        ALERTS="$T/h/logs/ALERTS.log" CCLOG="$T/cc.log" JOB_ID=job-1 "$@" \
    bash -c 'set -uo pipefail
             STAMP() { echo TS; }
             RESULT() { echo "RESULT=$*"; echo "$*" > "$BUILD/RESULT"; }
             BB() { echo "BB=$1"; }
             CC() { echo "$*" >> "$CCLOG"; [ -n "${REPAIRED:-}" ] && printf "%s\n" "$REPAIRED" > "$BUILD/plan.md"; return 0; }
             job_artifact_put() { printf "%s\t%s\n" "$1" "$3" >> "$SINK"; }
             . "$0"; echo "CONTINUED"' "$T/gate.sh" 2>&1 )
}
TRACED='### Task 1 — add the column
- VALIDATE: `npm test`
- SATISFIES: criterion 1'
UNTRACED='### Task 1 — add the column
- VALIDATE: `npm test`'

# 2a. a traced plan costs nothing: no repair session, no RESULT, the pipeline
#     continues into the SIZE check exactly as before.
: > "$T/cc.log"
OUT=$(drive "$TRACED" SINK=/dev/null)
grep -q CONTINUED <<<"$OUT" && ok || bad "a traced plan must not stop the build (got: $OUT)"
[ ! -s "$T/cc.log" ] && ok || bad "a traced plan must not spend a repair session (got: $(cat "$T/cc.log"))"

# 2b. an untraced plan buys exactly ONE repair pass, and a repaired plan carries
#     on — the 2026-08-14 behaviour, kept.
: > "$T/cc.log"
OUT=$(drive "$UNTRACED" SINK=/dev/null REPAIRED="$TRACED")
grep -q CONTINUED <<<"$OUT" && ok || bad "a REPAIRED plan must carry on (got: $OUT)"
[ "$(grep -c . "$T/cc.log")" = 1 ] && ok || bad "exactly one repair pass, got $(grep -c . "$T/cc.log")"
grep -q 'Task 1' "$T/cc.log" && ok || bad "the repair prompt must NAME the untraced blocks: $(cat "$T/cc.log")"

# 2c. still untraced after the repair: PLAN_MALFORMED, requeued once. This is
#     the refusal — the point of the whole item.
rm -f "$T/h/state/plan-malformed.txt"
OUT=$(drive "$UNTRACED" SINK=/dev/null)
grep -q CONTINUED <<<"$OUT" && bad "an untraced plan must NOT reach EXECUTE (got: $OUT)" || ok
grep -q 'RESULT=PLAN_MALFORMED' <<<"$OUT" && ok || bad "the terminal must be PLAN_MALFORMED (got: $OUT)"
grep -q 'requeued once' <<<"$OUT" && ok || bad "the first refusal must requeue (got: $OUT)"
grep -q 'BB=plan_malformed' <<<"$OUT" && ok || bad "the refusal must beat its own stage (got: $OUT)"
[ -s "$T/b/plan-gate.txt" ] && ok || bad "the gate report must be left in the build dir for the sweep"

# 2d. the SECOND time the same ticket comes back untraced, a human gets it. The
#     counter is per TICKET and outlives the build dir, which is the only reason
#     "once" can mean anything: the requeue is a NEW build in a NEW dir.
OUT=$(drive "$UNTRACED" SINK=/dev/null)
grep -q 'held here, handed to the blocked-resolver' <<<"$OUT" && ok || bad "the second refusal must hold, not requeue (got: $OUT)"
grep -q 'PLAN_MALFORMED twice' "$T/h/logs/ALERTS.log" \
  && ok || bad "holding for a human must raise ONE ALERTS line (got: $(cat "$T/h/logs/ALERTS.log" 2>/dev/null))"
[ "$(grep -c '^widget-os WD-9 ' "$T/h/state/plan-malformed.txt")" = 2 ] \
  && ok || bad "the file fallback must record both attempts: $(cat "$T/h/state/plan-malformed.txt")"
grep -q '^widget-os WD-9 requeued' "$T/h/state/plan-malformed.txt" \
  && ok || bad "the first attempt must be recorded as requeued"
# A DIFFERENT ticket is not held by its neighbour's history.
OUT=$(drive "$UNTRACED" SINK=/dev/null KEY=WD-10)
grep -q 'requeued once' <<<"$OUT" && ok || bad "another ticket must get its own first chance (got: $OUT)"

# 2e. the DB is the real ledger; the file is the fallback. A hub whose state dir
#     was rebuilt must still hold a ticket the ledger already knows about.
rm -f "$T/h/state/plan-malformed.txt"
rm -rf "$T/b"; mkdir -p "$T/b"; printf '%s\n' "$UNTRACED" > "$T/b/plan.md"
OUT=$( env HARNESS="$T/h" BUILD="$T/b" PROJECT=widget-os KEY=WD-9 PLAN_MODEL=stub-model \
        ALERTS="$T/h/logs/ALERTS.log" JOB_ID=job-1 LSINK="$T/ledger.txt" \
     bash -c 'set -uo pipefail
              STAMP() { echo TS; }
              RESULT() { echo "RESULT=$*"; }
              BB() { :; }
              CC() { return 0; }
              job_ledger_get() { [ "$1" = plan_malformed ] && return 0; return 1; }
              job_ledger_put() { echo "LEDGER=$1|$2|$3" > "$LSINK"; }
              job_artifact_put() { :; }
              . "$0"' "$T/gate.sh" 2>&1 )
grep -q 'held here, handed to the blocked-resolver' <<<"$OUT" \
  && ok || bad "a ledger row with no local file must still hold the ticket (got: $OUT)"
grep -q 'LEDGER=plan_malformed|widget-os WD-9|held' "$T/ledger.txt" \
  && ok || bad "the hold must be written back to the D1 ledger (got: $(cat "$T/ledger.txt" 2>/dev/null))"

# 2f. the kill switch. PLAN_GATE_ENFORCE=0 restores the old logged warning.
rm -f "$T/h/state/plan-malformed.txt"
OUT=$(drive "$UNTRACED" SINK=/dev/null PLAN_GATE_ENFORCE=0)
grep -q CONTINUED <<<"$OUT" && ok || bad "PLAN_GATE_ENFORCE=0 must let the build through (got: $OUT)"
grep -q 'RESULT=' <<<"$OUT" && bad "the kill switch must write no terminal (got: $OUT)" || ok
grep -q 'PLAN_GATE_ENFORCE=0' "$T/b/pipeline.log" \
  && ok || bad "a warn-only run must say so in the pipeline log: $(cat "$T/b/pipeline.log")"

# 2g. an unrecognised switch value is ON (this gate refuses; a typo must not
#     silently disarm it) and SAYS SO — the mirror of the scope gate, whose
#     default is the other way round.
: > "$T/h/logs/ALERTS.log"; rm -f "$T/h/state/plan-malformed.txt"
OUT=$(drive "$UNTRACED" SINK=/dev/null PLAN_GATE_ENFORCE=maybe)
grep -q 'RESULT=PLAN_MALFORMED' <<<"$OUT" && ok || bad "a junk switch value must leave the gate armed (got: $OUT)"
grep -q "PLAN_GATE_ENFORCE='maybe' is not a recognized" "$T/h/logs/ALERTS.log" \
  && ok || bad "a junk switch value must raise an ALERTS line"

# 2h. the ledger row: written on EVERY build, including the clean ones, so that
#     an absent row means "not measured" and never "clean". A PLAN_MALFORMED
#     build never reaches the verdict artifact, so this is the only row it gets.
: > "$T/artifacts.tsv"
drive "$TRACED" SINK="$T/artifacts.tsv" >/dev/null
[ "$(cut -f1 "$T/artifacts.tsv" | head -1)" = plan_gate ] \
  && ok || bad "a clean plan must still record its plan_gate row: $(cat "$T/artifacts.tsv")"
D=$(cut -f2 "$T/artifacts.tsv" | head -1)
[ "$(jq -r '.verdict' <<<"$D")" = ok ] && ok || bad "the row lost the verdict: $D"
[ "$(jq -r '.tasks' <<<"$D")" = 1 ] && ok || bad "the row lost the task count: $D"
[ "$(jq -r '.untraced' <<<"$D")" = 0 ] && ok || bad "the row lost the untraced count: $D"
: > "$T/artifacts.tsv"; rm -f "$T/h/state/plan-malformed.txt"
drive "$UNTRACED" SINK="$T/artifacts.tsv" >/dev/null
D=$(cut -f2 "$T/artifacts.tsv" | head -1)
[ "$(jq -r '.verdict' <<<"$D")" = untraced ] && ok || bad "a refused build must record untraced: $D"
jq -e '.detail | test("Task 1")' <<<"$D" >/dev/null \
  && ok || bad "the row must carry WHICH blocks were untraced: $D"

# ============================================================================
# 3. the resume half: a reused plan is re-checked against the thread
# ============================================================================
awk '/^# >>> ticket fingerprint$/{f=1;next} /^# <<< ticket fingerprint$/{exit} f' \
  "$RB_ALL" > "$T/fp.sh"
awk '/^# >>> ticket fingerprint write/{f=1;next} /^# <<< ticket fingerprint write/{exit} f' \
  "$RB_ALL" > "$T/fpw.sh"
awk '/# >>> resume stale gate/{f=1;next} /# <<< resume stale gate/{exit} f' \
  "$RB_ALL" > "$T/stale.sh"
[ -s "$T/fp.sh" ] && ok || bad "could not extract the ticket-fp block"
[ -s "$T/fpw.sh" ] && ok || bad "could not extract the ticket-fp write block"
[ -s "$T/stale.sh" ] && ok || bad "could not extract the resume stale gate"

snap() { # snap <fingerprint-now> [stored] ; the FRESH path: read, then plan
  rm -rf "$T/rb"; mkdir -p "$T/rb"
  [ -n "${2:-}" ] && printf '%s\n' "$2" > "$T/rb/ticket-fp"
  ( env BUILD="$T/rb" FP_BEFORE="$1" \
    bash -c 'set -uo pipefail; . "$0"; printf "FP_PLAN=%s\n" "$FP_PLAN"; . "$1"' \
      "$T/fp.sh" "$T/fpw.sh" 2>&1 )
}
reuse() { # reuse <fingerprint-now> [stored] ; the REUSE path: read only, no planner
  rm -rf "$T/rb"; mkdir -p "$T/rb"
  [ -n "${2:-}" ] && printf '%s\n' "$2" > "$T/rb/ticket-fp"
  ( env BUILD="$T/rb" FP_BEFORE="$1" \
    bash -c 'set -uo pipefail; . "$0"; printf "FP_PLAN=%s\n" "$FP_PLAN"' "$T/fp.sh" 2>&1 )
}
resume() { # resume <fp-now> <fp-stored>
  rm -rf "$T/rb"; mkdir -p "$T/rb"
  [ -n "$2" ] && printf '%s\n' "$2" > "$T/rb/ticket-fp"
  ( env BUILD="$T/rb" PROJECT=widget-os KEY=WD-9 FP_BEFORE="$1" \
    bash -c 'set -uo pipefail
             STAMP() { echo TS; }
             RESULT() { echo "RESULT=$*"; }
             BB() { echo "BB=$1"; }
             FP_PLAN=$(cat "$BUILD/ticket-fp" 2>/dev/null)
             . "$0"; echo REUSED' "$T/stale.sh" 2>&1 )
}

# 3a. a fresh build takes the snapshot and writes it down. This is the whole
#     mechanism: without a file, a resume has nothing to compare against.
OUT=$(snap "A|B|C|4")
[ "$(cat "$T/rb/ticket-fp")" = "A|B|C|4" ] && ok || bad "the pre-PLAN snapshot was not persisted (got: $OUT)"

# 3b. ...and a REUSE never rewrites it. A resume must compare against the thread
#     as it was when the reused plan was written, not against five minutes ago.
OUT=$(reuse "A|B|C|9" "A|B|C|4")
[ "$(cat "$T/rb/ticket-fp")" = "A|B|C|4" ] && ok || bad "a resume overwrote the original snapshot (got: $OUT)"
grep -q 'FP_PLAN=A|B|C|4' <<<"$OUT" && ok || bad "the stored snapshot must be what the gate reads (got: $OUT)"

# 3b-bis. A RE-PLAN does rewrite it: a build that died mid-PLAN has a snapshot
#     from the dead attempt, and the new plan is written against the thread NOW.
#     Keeping the old one would fail the next resume as stale against a thread
#     that never moved (the snapshot describes the plan, not the directory).
OUT=$(snap "A|B|C|9" "A|B|C|4")
[ "$(cat "$T/rb/ticket-fp")" = "A|B|C|9" ] && ok || bad "a re-plan must re-snapshot the thread (got: $OUT)"
grep -q 'FP_PLAN=A|B|C|4' <<<"$OUT" && ok || bad "the read still happens BEFORE the write (got: $OUT)"

# 3c-bis. no fingerprint now (boardless project, board outage): no snapshot at
#     all. Absence fails open below; a leftover file would not.
OUT=$(snap "" "A|B|C|4")
[ -e "$T/rb/ticket-fp" ] && bad "a re-plan with no fingerprint must drop the stale snapshot (got: $OUT)" || ok

# 3c. the thread moved while the build was dead: PLAN_STALE, not a resumed build
#     against a superseded comment (TK-143 #517, widened).
OUT=$(resume "A|B|C|9" "A|B|C|4")
grep -q 'RESULT=PLAN_STALE' <<<"$OUT" && ok || bad "a moved thread must stop the resume (got: $OUT)"
grep -q 'BB=plan_stale' <<<"$OUT" && ok || bad "the resumed stale path must beat plan_stale (got: $OUT)"
grep -q REUSED <<<"$OUT" && bad "PLAN_STALE must exit, not fall through (got: $OUT)" || ok

# 3d. unchanged thread: the resume proceeds, which is the point of resuming.
OUT=$(resume "A|B|C|4" "A|B|C|4")
grep -q REUSED <<<"$OUT" && ok || bad "an unchanged thread must reuse the plan (got: $OUT)"

# 3e. ABSENCE IS NEVER A MISMATCH. A record from before this shipped has no
#     ticket-fp; a boardless project and a board outage give no fingerprint now.
#     All three behave exactly as they did before item 5.
OUT=$(resume "A|B|C|9" "")
grep -q REUSED <<<"$OUT" && ok || bad "a record with no stored snapshot must fail open (got: $OUT)"
OUT=$(resume "" "A|B|C|4")
grep -q REUSED <<<"$OUT" && ok || bad "a board outage must fail open, not block the resume (got: $OUT)"

echo "plan-gate-test: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
