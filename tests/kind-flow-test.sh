#!/bin/bash
# tests/kind-flow-test.sh — SDLC item 7: what KIND of work is this build, and
# does a bug fix have to prove the bug?
#
# The hole this closes: one workflow served every ticket. A copy tweak, a schema
# migration and a DEFECT all got the same "implement the acceptance tests first"
# execute prompt and the same lens routing. The defect is the one that suffered —
# what proves a bug fix is a reproduction that fails on the code as it stands,
# and no stage asked for one. TK-44 shipped a replacement route over a
# fail-closed one that was working as designed; TK-113 blamed five pre-existing
# failures on a PR that did not cause them. Both are "nobody proved the bug
# first".
#
# WHY DRIVEN AND NOT GREPPED. `grep -q kind-gate bin/run-build.sh` passes on a
# classifier that reads "Fix the header copy" as a defect, on a hint that loses
# to the model's own opinion, on a reproduction check that accepts a heading with
# nothing under it, and on a demoter wired to the wrong default. What is under
# test is the classification (including the negatives), the precedence between
# the board and the plan, the five-fact bug contract, the warn-first switch, and
# that the kind reaches the executor, the reviewer, the tier note and the ledger
# row in the shape each reader expects.
#
# The run-build blocks are extracted VERBATIM by their markers, so a regression
# in the shipped lines fails here rather than in a paraphrase. No network, no
# model call, no secrets: JSON and markdown fixtures on disk, the ledger stubbed.
# Run from anywhere: tests/kind-flow-test.sh   (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
. "$DIR/tests/lib/rb-all.sh" || exit 1
RB_ALL=$(rb_all "$DIR" "$T/run-build.all.sh")
mkdir -p "$T/h/bin" "$T/h/logs" "$T/b"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null 2>&1 || { echo "jq missing — skipping"; exit 0; }

GATE="$DIR/bin/kind-gate.sh"
[ -x "$GATE" ] && ok || bad "bin/kind-gate.sh is missing or not executable"
cp "$GATE" "$T/h/bin/kind-gate.sh"

B="$T/b"
meta()  { printf '%s\n' "$1" > "$B/ticket-meta.json"; }
plan()  { printf '%s\n' "$1" > "$B/plan.md"; }
reset() { rm -f "$B/ticket-meta.json" "$B/plan.md" "$B/kind.txt"; }
run()   { G=$("$GATE" "$B" 2>&1); GRC=$?; }
field() { sed -n "s/^$1:[[:space:]]*//p" <<<"$G" | tail -1; }

# ============================================================================
# 1. bin/kind-gate.sh — the deterministic classifier
# ============================================================================
# 1a. a board type field is the strongest evidence and needs no model.
reset; meta '{"title":"Header overlaps","type":"Bug","labels":[]}'
run
[ "$(field KIND)" = bug ] && ok || bad "a type field of Bug must classify as bug (got: $G)"
[ "$(field KIND_SOURCE)" = "hint(type=Bug)" ] \
  && ok || bad "the source must name the evidence, not just the answer (got: $(field KIND_SOURCE))"

# A type carried as an object ({name:...}) is the shape some boards return.
reset; meta '{"title":"x","type":{"name":"defect"}}'
run
[ "$(field KIND)" = bug ] && ok || bad "an object-shaped type field must still classify (got: $G)"

# 1b. GitHub label objects — the whole deterministic signal on issue-backed
#     projects, which have no board type field at all.
reset; meta '{"title":"Something is broken","labels":[{"name":"needs-triage"},{"name":"bug"}]}'
run
[ "$(field KIND)" = bug ] && ok || bad "a GitHub bug label must classify as bug (got: $G)"
[ "$(field KIND_HINT_SOURCE)" = "label=bug" ] || bad "the label evidence must be named (got: $G)"
ok
# Plain-string labels are the other shape an API can hand back.
reset; meta '{"title":"x","labels":["documentation"]}'
run
[ "$(field KIND)" = copy ] && ok || bad "a documentation label must classify as copy (got: $G)"

# 1c. title PREFIXES, and the negative that motivates the rule. "Fix the header
#     copy" is a request ABOUT copy; a keyword-anywhere matcher routes it
#     through the bug flow and asks a planner to reproduce a defect that does
#     not exist.
reset; meta '{"title":"fix: header overlaps at 375px"}'
run
[ "$(field KIND)" = bug ] && ok || bad "'fix:' must classify as bug (got: $G)"
reset; meta '{"title":"[Bug] totals are wrong on the invoice"}'
run
[ "$(field KIND)" = bug ] && ok || bad "a [Bug] bracket prefix must classify as bug (got: $G)"
# "Fix - header copy" is the summary's own negative example typed with a dash;
# "Build:"/"Data:" are ordinary English about the work, not kind vocabulary.
for TITLE in "Fix the header copy" "Add a bug report form" "Refactor the fixer service" \
             "Fix - header copy" "fix/header copy" "Build: new client dashboard" \
             "Data: import the Q3 leads"; do
  reset; meta "$(jq -nc --arg t "$TITLE" '{title:$t}')"
  run
  [ "$(field KIND)" = unknown ] \
    || bad "'$TITLE' is not a defect but classified as $(field KIND) — the prefix rule leaked"
done
ok
reset; meta '{"title":"chore: bump the pinned CLI"}'
run
[ "$(field KIND)" = infra ] && ok || bad "'chore:' must classify as infra (got: $G)"

# 1d. NOTHING is a real answer. `unknown` is not-measured, and it must never be
#     rounded up to feature — every consequence downstream keys on that.
reset
run
[ "$(field KIND)" = unknown ] && ok || bad "no evidence must classify as unknown (got: $G)"
[ "$(field KIND_SOURCE)" = none ] && ok || bad "an unclassified build must say it has no source"
[ "$GRC" = 3 ] && ok || bad "a pre-PLAN probe (no plan.md) must be rc 3 (got $GRC)"
[ "$(field KIND_REPRO)" = "n/a" ] && ok || bad "no plan means no reproduction verdict (got: $G)"

# 1e. a malformed / empty meta file must not crash the gate or invent a kind.
for BADMETA in '' 'not json at all' '{"labels":"bug"}' '[]'; do
  reset; printf '%s' "$BADMETA" > "$B/ticket-meta.json"
  run
  [ "$(field KIND)" = unknown ] || bad "malformed meta ('$BADMETA') invented $(field KIND)"
done
ok

# ============================================================================
# 2. the plan's own KIND line, and who wins
# ============================================================================
TASKS='## Tasks
### Task 1 — do it
- VALIDATE: `npm test`
- SATISFIES: "the client asked for it"'

# 2a. with no board evidence, the plan is the answer.
reset; plan "# T
$TASKS

KIND: migration
SIZE: M"
run
[ "$(field KIND)" = migration ] && ok || bad "the plan's KIND must settle it when the board is silent (got: $G)"
[ "$(field KIND_SOURCE)" = plan ] && ok || bad "the source must say the plan decided it"

# 2b. bullet and bold forms, because plans are markdown written by a model.
for LINE in '- KIND: copy' '**KIND:** copy' 'KIND:  copy  '; do
  reset; plan "# T
$TASKS

$LINE
SIZE: S"
  run
  [ "$(field KIND)" = copy ] || bad "the plan line '$LINE' was not read (got: $(field KIND))"
done
ok

# 2c. THE PRECEDENCE THAT MATTERS: the board outranks the plan, and the
#     disagreement is printed. A model must not be able to reclassify its way
#     out of the bug flow, and a reviewer needs to see that it tried.
reset; meta '{"title":"x","labels":[{"name":"bug"}]}'
plan "# T
$TASKS

KIND: feature
SIZE: S"
run
[ "$(field KIND)" = bug ] && ok || bad "the board's label must outrank the plan's KIND (got: $G)"
grep -q '^KIND_DISAGREE:' <<<"$G" && ok || bad "a disagreement must be printed, not resolved silently"
grep -q 'KIND_DISAGREE' <<<"$G" && grep -q 'feature' <<<"$G" \
  && ok || bad "the disagreement must name what the plan said"

# 2d. a KIND the vocabulary does not know is silence, not a new kind.
reset; plan "# T
$TASKS

KIND: refactor-everything
SIZE: S"
run
[ "$(field KIND)" = unknown ] && ok || bad "an unknown KIND word must not become a kind (got: $G)"

# ============================================================================
# 3. the bug contract — `## Reproduction`, five facts
# ============================================================================
REPRO='## Reproduction
- REPRO: `npm test -- src/invoice.test.ts`
- OBSERVED: the total double-counts a refunded line
- EXPECTED: refunds subtract once
- ROOT CAUSE: src/lib/invoice/total.ts:88 adds the refund back
- BLAST RADIUS: 4 callers (InvoicePage, PdfRender, the nightly cron, the API)'

bugplan() { plan "# T

$1

$TASKS

KIND: bug
SIZE: S"; }

# 3a. the complete shape passes, and rc 0 means nothing is owed.
reset; bugplan "$REPRO"
run
[ "$(field KIND_REPRO)" = ok ] && ok || bad "a complete reproduction must read ok (got: $G)"
[ "$GRC" = 0 ] && ok || bad "a complete reproduction must be rc 0 (got $GRC)"

# 3b. no section at all — the case the whole item exists for.
reset; bugplan "## Approach
Just fix it."
run
[ "$(field KIND_REPRO)" = missing ] && ok || bad "a bug plan with no Reproduction must read missing (got: $G)"
[ "$GRC" = 2 ] && ok || bad "a missing reproduction must be rc 2 (got $GRC)"
grep -q 'REPRO:' <<<"$G" && ok || bad "the report must say what a Reproduction has to carry"

# 3c. a HEADING WITH NOTHING UNDER IT is the shape a checklist-following model
#     produces, and it must not pass. This is why the check is per-fact.
reset; bugplan "## Reproduction

## Approach
Fix it."
run
[ "$(field KIND_REPRO)" = missing ] && ok || bad "an empty Reproduction section must not pass (got: $G)"

# 3d. each missing fact is named, one at a time.
for DROP in REPRO OBSERVED EXPECTED 'ROOT CAUSE' 'BLAST RADIUS'; do
  reset; bugplan "$(grep -v "^- $DROP:" <<<"$REPRO")"
  run
  [ "$(field KIND_REPRO)" = incomplete ] \
    || bad "dropping $DROP must read incomplete (got: $(field KIND_REPRO))"
  grep -qi "$(cut -d' ' -f1 <<<"$DROP")" <<<"$(field KIND_REPRO_MISSING)" \
    || bad "the missing list must name $DROP (got: $(field KIND_REPRO_MISSING))"
  [ "$GRC" = 2 ] || bad "an incomplete reproduction must be rc 2 (dropped $DROP, got $GRC)"
done
ok

# 3e. a ROOT CAUSE with no file:line is where "fix the symptom at the call site"
#     comes from — the label alone is not the fact.
reset; bugplan "$(sed 's|^- ROOT CAUSE:.*|- ROOT CAUSE: somewhere in the invoice module|' <<<"$REPRO")"
run
[ "$(field KIND_REPRO)" = incomplete ] && ok || bad "a ROOT CAUSE with no file:line must not pass (got: $G)"
grep -q 'file:line' <<<"$(field KIND_REPRO_MISSING)" \
  && ok || bad "the report must say the file:line is what is missing"
# The leak the section-wide scan had: `vitest run src/x.test.ts:12` is the
# commonest shape a REPRO takes, and it carries a file:line of its own. If the
# check reads the whole section, that borrowed line number satisfies a ROOT
# CAUSE nobody ever located — the exact bypass this fact exists to stop.
reset; bugplan '## Reproduction
- REPRO: `npx vitest run src/invoice.test.ts:12`
- OBSERVED: the total double-counts a refunded line
- EXPECTED: refunds subtract once
- ROOT CAUSE: somewhere in the invoice module
- BLAST RADIUS: 4 callers'
run
[ "$(field KIND_REPRO)" = incomplete ] \
  && ok || bad "a file:line in the REPRO command must not satisfy ROOT CAUSE (got: $G)"
grep -q 'file:line' <<<"$(field KIND_REPRO_MISSING)" \
  && ok || bad "the vitest-line-filter case must still name the file:line as missing"

# 3f. forgiving where it should be: bold, numbered, mixed case, a fenced repro
#     command, and a deeper sub-heading inside the section.
reset; bugplan '## Reproduction
1. **Repro command:** run the suite:
```
npm test -- src/invoice.test.ts
```
2. Observed: the total double-counts a refunded line
3. expected: refunds subtract once
### Cause
- Root cause: src/lib/invoice/total.ts:88 adds the refund back
- blast radius: 4 callers'
run
[ "$(field KIND_REPRO)" = ok ] \
  && ok || bad "the forgiving forms must pass (got: $G / $(field KIND_REPRO_MISSING))"

# 3g. the section ENDS at the next same-level heading: facts borrowed from a
#     later section are not this section's facts.
reset; bugplan '## Reproduction
- REPRO: `npm test`
- OBSERVED: wrong total

## Notes
- EXPECTED: refunds subtract once
- ROOT CAUSE: src/lib/invoice/total.ts:88
- BLAST RADIUS: 4 callers'
run
[ "$(field KIND_REPRO)" = incomplete ] \
  && ok || bad "facts outside the section must not count (got: $G)"

# 3h. a non-bug plan is never asked for a reproduction.
reset; plan "# T
$TASKS

KIND: copy
SIZE: S"
run
[ "$(field KIND_REPRO)" = "n/a" ] && ok || bad "a copy plan must not be asked for a reproduction"
[ "$GRC" = 0 ] && ok || bad "a copy plan must be rc 0 (got $GRC)"

# 3i. THE INTERACTION WITH THE PLAN GATE. The five labels are deliberately not
#     VALIDATE:/SATISFIES:, because bin/plan-gate.sh scores any block carrying
#     those as a task — a reproduction written that way would be refused as an
#     untraced task, which is the two gates fighting each other.
reset; bugplan "$REPRO"
"$DIR/bin/plan-gate.sh" "$B/plan.md" >/dev/null 2>&1
[ "$?" = 0 ] && ok || bad "a complete bug plan must still pass the plan gate"

# ============================================================================
# 4. bin/run-build.sh — the kind-flow block settles it and records it
# ============================================================================
awk '/^# >>> kind flow/{f=1;next} /^# <<< kind flow/{exit} f' \
  "$RB_ALL" > "$T/flow.sh"
[ -s "$T/flow.sh" ] && ok || bad "could not extract the kind-flow block — markers missing?"

flow() { # flow [env...] -> prints "KIND|REPRO|SKIP_E2E|SKIP_SEC|<exec-note-head>"
  rm -f "$T/artifact.json"
  ( env HARNESS="$T/h" BUILD="$B" ALERTS="$T/h/logs/ALERTS.log" PROJECT=p KEY=K \
        SINK="$T/artifact.json" "$@" \
    bash -c 'set -uo pipefail; STAMP() { echo TS; }
             job_artifact_put() { printf "%s\t%s\n" "$2" "$3" > "$SINK"; }
             . "$0"
             printf "%s|%s|%s|%s|%s\n" "$KIND" "$KIND_REPRO" "$KIND_SKIP_E2E" \
               "$KIND_SKIP_SECLENS" "$(printf "%.60s" "$KIND_EXEC_NOTE")"' "$T/flow.sh" 2>/dev/null )
}

# 4a. a classified bug with a complete reproduction: the executor is told, and
#     nothing is skipped.
reset; meta '{"title":"fix: totals","labels":[{"name":"bug"}]}'; bugplan "$REPRO"
OUT=$(flow)
[ "$(cut -d'|' -f1 <<<"$OUT")" = bug ] && ok || bad "the flow block must settle KIND=bug (got: $OUT)"
[ "$(cut -d'|' -f2 <<<"$OUT")" = ok ] && ok || bad "the flow block must carry the repro verdict (got: $OUT)"
grep -q 'BUG FLOW' <<<"$OUT" && ok || bad "a bug must get the bug-flow execute note (got: $OUT)"
[ -s "$B/kind.txt" ] && ok || bad "the flow block must write the kind.txt fallback"

# 4b. the bug-flow note is the whole point: it must name the reproduction, the
#     red proof and the root cause, or EXECUTE learns nothing new.
NOTE=$( reset; meta '{"labels":[{"name":"bug"}]}'; bugplan "$REPRO"
        env HARNESS="$T/h" BUILD="$B" ALERTS="$T/h/logs/ALERTS.log" PROJECT=p KEY=K \
        bash -c 'set -uo pipefail; STAMP() { echo TS; }; . "$0"; printf "%s" "$KIND_EXEC_NOTE"' "$T/flow.sh" 2>/dev/null )
for W in 'Reproduction' 'red.txt' 'ROOT CAUSE' 'before you change'; do
  grep -q "$W" <<<"$NOTE" || bad "the bug-flow note never mentions '$W'"
done
ok
# ...and it names the REAL path. The note is a double-quoted string in
# run-build.sh, so an escaped \$BUILD reaches the executing session as the
# literal text, which in its own shell is an unset variable and a write to
# /red.txt. The execute prompt's own red.txt sentence uses the expanded path, so
# an escaped one here would put two different files in one prompt — and red.txt
# is the artifact this whole item hangs on.
grep -qF "$B/red.txt" <<<"$NOTE" \
  && ok || bad "the bug-flow note must name the expanded red.txt path (got: $(grep -oF -m1 'BUILD/red.txt' <<<"$NOTE"))"
grep -qF '$BUILD/red.txt' <<<"$NOTE" \
  && bad "the bug-flow note ships a literal \$BUILD — the executor cannot expand it" || ok
# ...and a bug whose reproduction is incomplete is told so, rather than being
# left to invent one that looks complete.
NOTE2=$( reset; meta '{"labels":[{"name":"bug"}]}'; bugplan "## Approach
fix it"
         env HARNESS="$T/h" BUILD="$B" ALERTS="$T/h/logs/ALERTS.log" PROJECT=p KEY=K \
         bash -c 'set -uo pipefail; STAMP() { echo TS; }; . "$0"; printf "%s" "$KIND_EXEC_NOTE"' "$T/flow.sh" 2>/dev/null )
grep -qi 'INCOMPLETE' <<<"$NOTE2" && ok || bad "an incomplete reproduction must be declared to the executor"
grep -qi 'Do not invent' <<<"$NOTE2" && ok || bad "the executor must be told not to fabricate a reproduction"

# 4c. every OTHER kind keeps a byte-identical execute prompt.
for K in feature copy migration infra; do
  reset; plan "# T
$TASKS

KIND: $K
SIZE: S"
  OUT=$(flow)
  [ -z "$(cut -d'|' -f5 <<<"$OUT")" ] || bad "KIND=$K must not change the execute prompt (got: $OUT)"
done
ok

# 4d. WARN-FIRST: the copy skips are off by default and on only with the flag.
reset; plan "# T
$TASKS

KIND: copy
SIZE: S"
OUT=$(flow)
[ "$(cut -d'|' -f3 <<<"$OUT")" = 0 ] && ok || bad "copy must NOT skip the E2E smoke by default (got: $OUT)"
[ "$(cut -d'|' -f4 <<<"$OUT")" = 0 ] && ok || bad "copy must NOT skip the extra lens by default (got: $OUT)"
OUT=$(flow KIND_GATE_ENFORCE=1)
[ "$(cut -d'|' -f3 <<<"$OUT")" = 1 ] && ok || bad "KIND_GATE_ENFORCE=1 must arm the E2E skip (got: $OUT)"
[ "$(cut -d'|' -f4 <<<"$OUT")" = 1 ] && ok || bad "KIND_GATE_ENFORCE=1 must arm the lens skip (got: $OUT)"
# ...and only for copy. A bug or a feature never loses its browser evidence.
for K in bug feature migration infra unknown; do
  reset
  [ "$K" = unknown ] || plan "# T
$TASKS

KIND: $K
SIZE: S"
  [ "$K" = bug ] && bugplan "$REPRO"
  OUT=$(flow KIND_GATE_ENFORCE=1)
  [ "$(cut -d'|' -f3 <<<"$OUT")" = 0 ] || bad "KIND=$K must never skip the E2E smoke (got: $OUT)"
done
ok
# An unrecognised flag value is OFF and says so — a `true` that silently means
# off is the never-fires shape this repo keeps finding.
reset; plan "# T
$TASKS

KIND: copy
SIZE: S"
OUT=$(flow KIND_GATE_ENFORCE=maybe)
[ "$(cut -d'|' -f3 <<<"$OUT")" = 0 ] && ok || bad "an unrecognised enforce value must be OFF (got: $OUT)"
grep -q 'KIND_GATE_ENFORCE' "$T/h/logs/ALERTS.log" 2>/dev/null \
  && ok || bad "an unrecognised enforce value must alert rather than pass silently"

# 4e. the ledger row: written for EVERY build with a job row, including a
#     `unknown` one, because a row written only for bugs makes "no row" mean
#     both "not a bug" and "old box".
reset; meta '{"labels":[{"name":"bug"}]}'; bugplan "$REPRO"
flow JOB_ID=job-1 >/dev/null
[ -s "$T/artifact.json" ] && ok || bad "no build_kind artifact was written"
[ "$(cut -f1 "$T/artifact.json")" = bug ] && ok || bad "the artifact ref must be the kind"
AD=$(cut -f2 "$T/artifact.json")
[ "$(jq -r .repro <<<"$AD")" = ok ] && ok || bad "the artifact must carry the repro verdict (got: $AD)"
[ "$(jq -r .source <<<"$AD")" != null ] && ok || bad "the artifact must name the classifier's evidence"
reset
flow JOB_ID=job-1 >/dev/null
[ "$(cut -f1 "$T/artifact.json")" = unknown ] \
  && ok || bad "an unclassified build must still record a row saying so"
# No job row, no artifact — and no failure either.
reset; bugplan "$REPRO"
rm -f "$T/artifact.json"
OUT=$(flow)
[ ! -f "$T/artifact.json" ] && ok || bad "a build with no JOB_ID must not write an artifact"
[ "$(cut -d'|' -f1 <<<"$OUT")" = bug ] && ok || bad "a ledger-less build must still classify (got: $OUT)"

# 4f. THE ROLLOUT CASE: harness-sync lands bin/ on its own schedule, so a box
#     can carry this run-build.sh with no kind-gate.sh for a window. The build
#     must continue, unclassified, rather than dying on a missing helper.
mv "$T/h/bin/kind-gate.sh" "$T/h/bin/kind-gate.off"
reset; meta '{"labels":[{"name":"bug"}]}'; bugplan "$REPRO"
OUT=$(flow)
[ "$(cut -d'|' -f1 <<<"$OUT")" = unknown ] \
  && ok || bad "a missing kind gate must classify as unknown, not crash (got: $OUT)"
[ -z "$(cut -d'|' -f5 <<<"$OUT")" ] && ok || bad "a missing gate must not produce a bug-flow note"
mv "$T/h/bin/kind-gate.off" "$T/h/bin/kind-gate.sh"

# ============================================================================
# 5. bin/run-build.sh — the demoter, and its warn-first default
# ============================================================================
awk '/^# >>> kind demoter/{f=1;next} /^# <<< kind demoter/{exit} f' \
  "$RB_ALL" > "$T/demote.sh"
[ -s "$T/demote.sh" ] && ok || bad "could not extract the kind demoter — markers missing?"

kindtxt() { # kindtxt <kind> <repro> [missing]
  { echo "KIND: $1"; echo "KIND_REPRO: $2"
    [ -n "${3:-}" ] && echo "KIND_REPRO_MISSING: $3"; } > "$B/kind.txt"
}
demote() { # demote <tier> [env...] -> "TIER=<n>|NOTE=<...>"
  local tier="$1"; shift
  ( env HARNESS="$DIR" BUILD="$B" PROJECT=p KEY=K TIER="$tier" QA_NOTE="" \
        ALERTS="$T/h/logs/ALERTS.log" "$@" \
    bash -c 'set -uo pipefail; STAMP() { echo TS; }; . "$0"
             printf "TIER=%s|NOTE=%s\n" "$TIER" "$QA_NOTE"' "$T/demote.sh" 2>/dev/null )
}

# 5a. warn-first is the SHIPPED default: the tier stands, the reason is recorded.
kindtxt bug missing "the whole '## Reproduction' section"
D=$(demote 1)
grep -q 'TIER=1' <<<"$D" && ok || bad "warn-first must not demote (got: $D)"
grep -q 'KIND: bug' <<<"$D" && ok || bad "the note must still be written (got: $D)"
grep -q 'warn only' <<<"$D" && ok || bad "the note must say the demotion was not applied (got: $D)"

# 5b. armed, it demotes — and says which facts were missing.
D=$(demote 1 KIND_GATE_ENFORCE=1)
grep -q 'TIER=2' <<<"$D" && ok || bad "KIND_GATE_ENFORCE=1 must demote a bug with no reproduction (got: $D)"
# TEST-CHANGE(BH-4581): wording only, tier logic unchanged
grep -q 'recorded tier-2 (risk signal)' <<<"$D" && ok || bad "the note must name the demotion (got: $D)"

# 5c. a build already at tier 2 keeps the note. The merge sweep's reader needs
#     the reason even when the tier was already settled by something else.
D=$(demote 2 KIND_GATE_ENFORCE=1)
grep -q 'TIER=2' <<<"$D" && ok || bad "an already-tier-2 build must stay tier 2"
grep -q 'already tier-2' <<<"$D" && ok || bad "the note must ride on a build already at tier 2 (got: $D)"

# 5d. the cases that must NEVER demote: a proven bug, any other kind, and an
#     unclassified build. Demoting on `unknown` would punish every ticket on a
#     board with no type field.
for CASE in "bug ok" "feature n/a" "copy n/a" "migration n/a" "unknown n/a"; do
  # shellcheck disable=SC2086  # a deliberate two-word case
  kindtxt $CASE
  D=$(demote 1 KIND_GATE_ENFORCE=1)
  grep -q 'TIER=1' <<<"$D" || bad "'$CASE' must not demote (got: $D)"
done
ok
# ...including a record from before this shipped, which has no kind.txt at all.
rm -f "$B/kind.txt"
D=$(demote 1 KIND_GATE_ENFORCE=1)
grep -q 'TIER=1' <<<"$D" && ok || bad "a record with no kind.txt must behave exactly as before (got: $D)"
grep -q 'NOTE=$' <<<"$D" && ok || bad "an unmeasured build must add no note (got: $D)"

# 5e. the note is bounded: QA_NOTE is shared with every other demoter and
#     bin/evidence-summary.sh caps the whole string at 400 chars, so a long
#     missing-list must not push the other reasons off the end.
kindtxt bug incomplete "$(printf 'X%.0s' $(seq 1 300))"
D=$(demote 1)
[ "${#D}" -lt 260 ] && ok || bad "the kind note is unbounded (${#D} chars)"

# ============================================================================
# 6. the reviewer, the E2E router, and the verdict row
# ============================================================================
# 6a. the reviewer is TOLD the kind, and a bug with no reproduction reads
#     differently from one with a proof. The gates block is driven whole.
awk '/^# >>> mechanical gates/{f=1;next} /^# <<< mechanical gates/{exit} f' \
  "$RB_ALL" > "$T/gates.sh"
[ -s "$T/gates.sh" ] && ok || bad "could not extract the mechanical-gates block"
mkdir -p "$T/h/bin"
for S in test-tamper-scan repro-gate intent-gate scope-gate; do
  printf '#!/bin/bash\necho "STUB"\nexit 0\n' > "$T/h/bin/$S.sh"; chmod +x "$T/h/bin/$S.sh"
done
gates_note() { # gates_note  (reads $B/kind.txt)
  rm -rf "$T/gb"; mkdir -p "$T/gb"; cp "$B/kind.txt" "$T/gb/" 2>/dev/null
  ( env HARNESS="$T/h" BUILD="$T/gb" ALERTS="$T/h/logs/ALERTS.log" PROJECT=p KEY=K BASE=main \
    bash -c 'set -uo pipefail; STAMP() { echo TS; }; RESULT() { echo "$*" > "$BUILD/RESULT"; }; . "$0"
             printf "%s" "$GATES_NOTE"' "$T/gates.sh" 2>/dev/null )
}
kindtxt bug ok
N=$(gates_note)
grep -q 'KIND: bug' <<<"$N" && ok || bad "the reviewer is never told the kind (got: $N)"
grep -q 'red.txt' <<<"$N" && ok || bad "a bug's note must point the reviewer at the red proof"
kindtxt bug missing "the whole section"
N=$(gates_note)
grep -qi 'unproven' <<<"$N" && ok || bad "an unproven bug must read differently to the reviewer (got: $N)"
rm -f "$B/kind.txt"
N=$(gates_note)
grep -qi 'not classified' <<<"$N" && ok || bad "an unclassified build must say so to the reviewer (got: $N)"
grep -qi 'unmeasured' <<<"$N" && ok || bad "the reviewer must be told not to read unknown as feature"

# 6b. the E2E router: the copy skip is the FIRST branch of the chain, and it
#     says WHY it skipped. Asserted structurally — the stage itself pushes a
#     branch and drives a preview, which no offline fixture can stand in for.
E2ECHAIN=$(grep -a -A2 '^E2E_VERDICT="not-run"' "$RB_ALL")
grep -q 'KIND_SKIP_E2E' <<<"$E2ECHAIN" \
  && ok || bad "the copy skip is not the first branch of the E2E chain — a copy diff still smokes"
grep -a -q 'skipped by routing, not by absence of UI' "$RB_ALL" \
  && ok || bad "the E2E skip does not say WHY — a reader cannot tell it from 'no UI in the diff'"
# ...and the security lens the DIFF earns is never skipped by a classification.
LENS=$(grep -a -B1 -A1 'REOPEN_EXTRA_LENS:-0' "$RB_ALL")
grep -q 'KIND_SKIP_SECLENS' <<<"$LENS" \
  && ok || bad "the copy skip is not wired into the reopen-armed lens"
grep -a -q 'the security lens stands' "$RB_ALL" \
  && ok || bad "a copy diff touching risky files must keep its security lens, and say so"

# 6c. the verdict row carries the kind — including `unknown`, which a reader
#     must never confuse with feature.
awk '/^# >>> verdict artifact/{f=1;next} /^# <<< verdict artifact/{exit} f' \
  "$RB_ALL" > "$T/verdict.sh"
[ -s "$T/verdict.sh" ] && ok || bad "could not extract the verdict-artifact block"
verdict_detail() { # verdict_detail [env...]
  local b="$T/vb"; scratch_rm "$b"; mkdir -p "$b"
  printf 'findings\nTIER: 1\nVERDICT: APPROVE\n' > "$b/review.md"
  ( env BUILD="$b" PR_URL=https://github.com/x/y/pull/1 JOB_ID=job-1 TIER=1 QA_NOTE="" \
        HEADBOUND_SHA=abc REPAIRS=0 REPAIR_ROUNDS=- SINK="$T/vartifact.json" "$@" \
    bash -c 'set -uo pipefail
             job_artifact_put() { printf "%s" "$3" > "$SINK"; }
             . "$0"' "$T/verdict.sh" 2>/dev/null )
  cat "$T/vartifact.json" 2>/dev/null
}
D=$(verdict_detail KIND_D=bug KIND_D_REPRO=incomplete)
[ "$(jq -r .kind <<<"$D")" = bug ] && ok || bad "the verdict row lost the kind (detail: $D)"
[ "$(jq -r .kind_repro <<<"$D")" = incomplete ] \
  && ok || bad "the verdict row lost the reproduction verdict (detail: $D)"
D=$(verdict_detail)
[ "$(jq -r .kind <<<"$D")" = unknown ] \
  && ok || bad "an unclassified build must record 'unknown' on the row (detail: $D)"
# ...and the fields items 1, 3 and 4 put there still ride along untouched.
[ "$(jq -r .reviewed_sha <<<"$D")" = abc ] && ok || bad "the reviewed sha was dropped (detail: $D)"
[ "$(jq -r .repairs <<<"$D")" = 0 ] && ok || bad "the repair count was dropped (detail: $D)"
[ "$(jq -r .scope <<<"$D")" = not-recorded ] && ok || bad "the scope verdict was dropped (detail: $D)"

# ============================================================================
# 7. bin/findings-log.sh — the kind rides on the findings, from ONE definition
# ============================================================================
FL="$DIR/bin/findings-log.sh"
[ -x "$FL" ] && ok || bad "bin/findings-log.sh is missing"
grep -q 'kind-gate.sh' "$FL" \
  && ok || bad "findings-log re-implements the kind instead of importing the gate"
FH="$T/fh"; scratch_rm "$FH"; mkdir -p "$FH/bin" "$FH/logs"
cp "$DIR/bin/findings-log.sh" "$DIR/bin/kind-gate.sh" "$DIR/bin/repair-count.sh" "$FH/bin/"
cp "$DIR/bin/alert_family.py" "$FH/bin/" 2>/dev/null
reset; meta '{"labels":[{"name":"bug"}]}'; bugplan "$REPRO"
printf 'findings\n- the totals path double-counts a refunded invoice line, D9\nVERDICT: APPROVE\n' \
  > "$B/review.md"
HARNESS="$FH" "$FH/bin/findings-log.sh" "$B" proj T-1 >/dev/null 2>&1
grep -q 'kind=bug' "$FH/logs/findings.log" 2>/dev/null \
  && ok || bad "a bug build's findings carry no kind= field: $(cat "$FH/logs/findings.log" 2>/dev/null)"
# family= stays the LAST field before `::` — two other scripts anchor on that.
grep -qE 'kind=bug family=[^ ]+ :: ' "$FH/logs/findings.log" 2>/dev/null \
  && ok || bad "kind= broke the field order consumers walk: $(cat "$FH/logs/findings.log")"
# An unclassified build writes NO field rather than kind=unknown on every row.
rm -f "$FH/logs/findings.log" "$B/.findings-general"
reset; plan "# T
$TASKS

SIZE: S"
printf 'findings\n- the totals path double-counts a refunded invoice line, D9\nVERDICT: APPROVE\n' \
  > "$B/review.md"
HARNESS="$FH" "$FH/bin/findings-log.sh" "$B" proj T-1 >/dev/null 2>&1
grep -q 'kind=' "$FH/logs/findings.log" 2>/dev/null \
  && bad "an unclassified build wrote a kind= field: $(cat "$FH/logs/findings.log")" || ok
grep -q 'family=' "$FH/logs/findings.log" 2>/dev/null \
  && ok || bad "the findings row itself went missing: $(cat "$FH/logs/findings.log" 2>/dev/null)"

# ============================================================================
# 8. the contract is written down where a planner will read it
# ============================================================================
grep -q 'KIND' "$DIR/prompts/plan-contract.md" \
  && ok || bad "prompts/plan-contract.md does not carry the KIND contract"
grep -q 'Reproduction' "$DIR/prompts/plan-contract.md" \
  && ok || bad "the plan contract does not describe the bug flow's Reproduction section"
grep -a -q 'Reproduction' "$RB_ALL" \
  && ok || bad "the plan prompt never asks for a Reproduction section"

echo "kind-flow-test: $PASS pass, $FAIL fail"
[ "$FAIL" -eq 0 ]
