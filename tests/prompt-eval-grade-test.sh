#!/bin/bash
# tests/prompt-eval-grade-test.sh — the grader of bin/prompt-eval.sh, extracted
# verbatim and driven WITHOUT a single LLM call.
#
# WHY THE GRADER IS PULLED OUT AND TESTED ALONE. An eval whose grading is wrong
# is worse than no eval: it reports a pass rate, the rate looks stable, and the
# prompt regressions it exists to catch sail past. The expensive half (running
# the scenarios) costs real tokens and cannot live in CI; the half that decides
# what the answers MEAN costs nothing and must be provably right. So the grade
# block is a pure function over two text files, and everything below drives it
# directly.
#
# THE FAILURE THIS SUITE IS BUILT AROUND: a MISSING decision must FAIL, not be
# silently skipped. A session that says nothing about a ticket has not passed
# that ticket — but a grader written as "for each DECISION line, check it" reads
# silence as a clean sheet, and the quieter the model gets the greener the eval
# looks. The dead-feed smell, wearing an eval's clothes.
# Run from anywhere: tests/prompt-eval-grade-test.sh   (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

# --- extraction (same convention as tests/cost-append-test.sh) ----------------
awk '/^# >>> prompt_eval_grade/{f=1;next} /^# <<< prompt_eval_grade/{exit} f' \
  "$DIR/bin/prompt-eval.sh" > "$T/grade.sh" 2>/dev/null
[ -s "$T/grade.sh" ] && ok || bad "could not extract the grade block from bin/prompt-eval.sh — markers missing?"
grep -q 'grade_scenario()' "$T/grade.sh" && ok || bad "extraction did not capture grade_scenario"
grep -q 'baseline_verdict()' "$T/grade.sh" && ok || bad "extraction did not capture baseline_verdict"
# The block must be PURE: no HARNESS paths, no agent-call, no network. A grader
# that reaches outside its two arguments cannot be trusted to mean the same
# thing in CI and on the hub.
grep -qE 'agent-call|curl |HARNESS' "$T/grade.sh" \
  && bad "the grade block reaches outside its arguments (agent-call/curl/HARNESS)" || ok

grade() { # grade <expected-file> <decisions-file>  -> stdout, rc
  ( bash -c '. "$0"; grade_scenario "$1" "$2"' "$T/grade.sh" "$1" "$2" )
}
verdict() { # verdict <observed> <baseline|-> <maxdrop>
  ( bash -c '. "$0"; baseline_verdict "$1" "$2" "$3"' "$T/grade.sh" "$1" "$2" "$3" )
}
coverage() { # coverage <scored> <baseline-expected|->
  ( bash -c '. "$0"; coverage_verdict "$1" "$2"' "$T/grade.sh" "$1" "$2" )
}
scrub() { # scrub  (env var NAMES on stdin -> the ones to unset)
  ( bash -c '. "$0"; scrub_env_names' "$T/grade.sh" )
}
grep -q 'coverage_verdict()' "$T/grade.sh" && ok || bad "extraction did not capture coverage_verdict"
grep -q 'scrub_env_names()' "$T/grade.sh" && ok || bad "extraction did not capture scrub_env_names"

# --- 1. full pass -------------------------------------------------------------
cat > "$T/exp1" <<'EOF'
# comments and blank lines are ignored

TK-12 :: launch
TK-40 :: skip
TK-51 :: comment
EOF
cat > "$T/dec1" <<'EOF'
Worked the board this tick.
DECISION: TK-12 :: launch :: client answered, mechanism confirmed
DECISION: TK-40 :: skip :: waitingOn=client, triage questions unanswered
DECISION: TK-51 :: comment :: posted the close-out with prod links
tickets=3 built=1
EOF
OUT=$(grade "$T/exp1" "$T/dec1"); RC=$?
[ "$RC" = 0 ] && ok || bad "full pass returned rc=$RC ($OUT)"
grep -q '^TOTAL 3 3' <<<"$OUT" && ok || bad "full pass total wrong ($OUT)"

# --- 2. an action OUTSIDE the allowed set fails that key ----------------------
cat > "$T/dec2" <<'EOF'
DECISION: TK-12 :: launch :: fine
DECISION: TK-40 :: launch :: built it anyway
DECISION: TK-51 :: comment :: fine
EOF
OUT=$(grade "$T/exp1" "$T/dec2"); RC=$?
[ "$RC" != 0 ] && ok || bad "an out-of-set action passed — the eval would never catch a regression"
grep -q '^FAIL TK-40 launch want=skip' <<<"$OUT" && ok || bad "out-of-set failure not named ($OUT)"
grep -q '^TOTAL 2 3' <<<"$OUT" && ok || bad "out-of-set total wrong ($OUT)"

# --- 3. a MISSING decision is a FAIL, never a silent skip --------------------
# The property this whole suite exists for.
cat > "$T/dec3" <<'EOF'
DECISION: TK-12 :: launch :: fine
DECISION: TK-51 :: comment :: fine
EOF
OUT=$(grade "$T/exp1" "$T/dec3"); RC=$?
[ "$RC" != 0 ] && ok || bad "a missing decision passed — silence read as a clean sheet"
grep -q '^FAIL TK-40 MISSING want=skip' <<<"$OUT" && ok || bad "missing key not reported as MISSING ($OUT)"

# --- 4. an EXTRA decision is warn-only ---------------------------------------
# A triage session may legitimately decide on more tickets than the fixture
# pins (it can touch a ticket a scoped thread depends on). That is information,
# not a failure.
cat > "$T/dec4" <<'EOF'
DECISION: TK-12 :: launch :: fine
DECISION: TK-40 :: skip :: fine
DECISION: TK-51 :: comment :: fine
DECISION: TK-77 :: comment :: referenced by TK-12's thread
EOF
OUT=$(grade "$T/exp1" "$T/dec4"); RC=$?
[ "$RC" = 0 ] && ok || bad "an extra decision failed the scenario — policy is warn-only (rc=$RC)"
grep -q '^WARN extra TK-77' <<<"$OUT" && ok || bad "extra decision not warned ($OUT)"

# --- 5. malformed DECISION lines: warned, never crash, never credited --------
cat > "$T/dec5" <<'EOF'
DECISION: TK-12 :: launch :: fine
DECISION: this line has no separators at all
DECISION:  ::  ::
DECISION: TK-40
DECISION: TK-51 :: comment :: fine
EOF
OUT=$(grade "$T/exp1" "$T/dec5"); RC=$?
[ "$RC" != 0 ] && ok || bad "malformed lines were credited as decisions (rc=$RC)"
grep -q 'malformed=3' <<<"$OUT" && ok || bad "malformed count wrong ($OUT)"
# and the key whose ONLY line was malformed is reported MISSING, not "malformed
# so we'll let it go"
grep -q '^FAIL TK-40 MISSING' <<<"$OUT" && ok || bad "a key whose only line was malformed must read MISSING ($OUT)"

# --- 6. allow-SETS, case, whitespace, duplicates -----------------------------
cat > "$T/exp6" <<'EOF'
TK-12 :: queue|launch
TK-40 :: skip | defer
EOF
cat > "$T/dec6" <<'EOF'
DECISION: TK-12 :: Queue :: WIP limit reached, queued behind the running build
DECISION: TK-40 :: defer :: HOLD comment from the operator on the thread
EOF
OUT=$(grade "$T/exp6" "$T/dec6"); RC=$?
[ "$RC" = 0 ] && ok || bad "allow-set / case / spacing handling broke (rc=$RC, $OUT)"
# EVERY emitted action must be allowed — DELIBERATE POLICY CHANGE, 2026-08-25
# (review finding I1). This case previously asserted the opposite: that a key
# passed if ANY of its actions matched. Under that rule `launch` + `comment`
# satisfied an expectation of `skip|defer|comment`, so a session that launched a
# duplicate build and then posted about it scored full marks on the very
# scenario written to catch duplicate launches. An action the SOP forbids is a
# failure whatever else the session also did.
cat > "$T/dec6b" <<'EOF'
DECISION: TK-12 :: comment :: posted a status note first
DECISION: TK-12 :: launch :: then launched it
DECISION: TK-40 :: skip :: waiting on client
EOF
OUT=$(grade "$T/exp6" "$T/dec6b"); RC=$?
[ "$RC" != 0 ] && ok || bad "a forbidden action alongside an allowed one must FAIL the key (rc=$RC, $OUT)"
grep -q '^FAIL TK-12 comment launch want=queue|launch' <<<"$OUT" \
  && ok || bad "the forbidden-action failure is not named with what was emitted ($OUT)"
# ...and several actions that are ALL allowed still pass: a sweep that comments
# and then moves the status has done exactly what the SOP asks.
cat > "$T/exp6c" <<'EOF'
TK-12 :: comment|status
EOF
cat > "$T/dec6c" <<'EOF'
DECISION: TK-12 :: comment :: posted the what-shipped comment with prod links
DECISION: TK-12 :: status :: moved to review
EOF
OUT=$(grade "$T/exp6c" "$T/dec6c"); RC=$?
[ "$RC" = 0 ] && ok || bad "two allowed actions on one key must pass (rc=$RC, $OUT)"

# --- 7. a BROKEN FIXTURE must not read as green ------------------------------
# An expected file whose lines do not parse has graded nothing. Reporting that
# as a pass is the same lie as an empty result set reported as success.
cat > "$T/exp7" <<'EOF'
TK-12 launch
EOF
OUT=$(grade "$T/exp7" "$T/dec1"); RC=$?
[ "$RC" != 0 ] && ok || bad "an unparseable expected.txt graded as a pass"
grep -q 'malformed-expected' <<<"$OUT" && ok || bad "unparseable expected line not named ($OUT)"
: > "$T/exp8"
OUT=$(grade "$T/exp8" "$T/dec1"); RC=$?
[ "$RC" != 0 ] && ok || bad "an EMPTY expected.txt graded as a pass (0 of 0 is not a green run)"
# A DUPLICATE key means one of the two lines is silently ignored, so the fixture
# grades something other than what it appears to say. Refuse it.
cat > "$T/exp8b" <<'EOF'
TK-12 :: launch
TK-12 :: skip
EOF
OUT=$(grade "$T/exp8b" "$T/dec1"); RC=$?
[ "$RC" != 0 ] && grep -q 'duplicate-expected TK-12' <<<"$OUT" \
  && ok || bad "a duplicate expected key was accepted — half the fixture would be invisible ($OUT)"

# --- 8. baseline arithmetic, including the exact boundary --------------------
# Rule: fail when the rate drops MORE than max-drop percentage points. Exactly
# max-drop is inside the band — a threshold written as ">2" and implemented as
# ">=2" fails a healthy fleet every week until someone re-baselines to shut it
# up, which is how a regression gate gets disabled.
OUT=$(verdict 87.5 87.5 2); RC=$?
[ "$RC" = 0 ] && grep -q '^OK' <<<"$OUT" && ok || bad "identical rate flagged ($OUT)"
OUT=$(verdict 85.5 87.5 2); RC=$?
[ "$RC" = 0 ] && grep -q '^OK' <<<"$OUT" && ok || bad "a drop of exactly 2.0pp must PASS (boundary) ($OUT)"
OUT=$(verdict 85.4 87.5 2); RC=$?
[ "$RC" != 0 ] && grep -q '^REGRESSION' <<<"$OUT" && ok || bad "a drop of 2.1pp must FAIL ($OUT)"
OUT=$(verdict 100 87.5 2); RC=$?
[ "$RC" = 0 ] && grep -q '^OK' <<<"$OUT" && ok || bad "an improvement flagged as a regression ($OUT)"
OUT=$(verdict 40 87.5 2); RC=$?
[ "$RC" != 0 ] && ok || bad "a collapse (47.5pp) passed ($OUT)"
# the threshold is a knob, and it must actually move
OUT=$(verdict 80 87.5 10); RC=$?
[ "$RC" = 0 ] && ok || bad "PROMPT_EVAL_MAX_DROP is not honoured ($OUT)"

# --- 9. ABSENT baseline = record-only, exit 0, and it SAYS so ----------------
# The first run on any box has no baseline. Exiting nonzero there trains
# everyone to ignore the exit code; exiting 0 silently lets "no baseline" hide
# behind "no regression".
OUT=$(verdict 62.5 - 2); RC=$?
[ "$RC" = 0 ] && grep -q '^NOBASELINE' <<<"$OUT" && ok || bad "absent baseline must be record-only and named ($OUT)"
OUT=$(verdict 62.5 "" 2); RC=$?
[ "$RC" = 0 ] && grep -q '^NOBASELINE' <<<"$OUT" && ok || bad "empty baseline must behave like absent ($OUT)"

# --- 9b. COVERAGE: the denominator is a claim too ----------------------------
# A rate is a fraction and nobody reads the denominator. Six of eight scenarios
# erroring leaves two that pass and a headline of 100% — an IMPROVEMENT over the
# baseline, so the rate gate stays quiet on a run that graded a quarter of the
# policy. Coverage is therefore checked separately from the rate.
OUT=$(coverage 8 8); RC=$?
[ "$RC" = 0 ] && grep -q '^COVERAGE-OK' <<<"$OUT" && ok || bad "equal coverage flagged ($OUT)"
OUT=$(coverage 9 8); RC=$?
[ "$RC" = 0 ] && ok || bad "growing coverage flagged as a shrink ($OUT)"
OUT=$(coverage 2 8); RC=$?
[ "$RC" != 0 ] && grep -q '^COVERAGE-SHRANK' <<<"$OUT" && ok \
  || bad "a run that graded 2 of 8 expected decisions passed the coverage check ($OUT)"
grep -q 'NOT comparable' <<<"$OUT" && ok || bad "the shrink message does not say the rate is not comparable ($OUT)"
OUT=$(coverage 2 -); RC=$?
[ "$RC" = 0 ] && grep -q '^COVERAGE-UNKNOWN' <<<"$OUT" && ok \
  || bad "no baseline count must be record-only, not a failure ($OUT)"

# --- 9c. the env scrub (layer 2 of side-effect freedom) ----------------------
# The tool ban is the control; this is what stands if the ban is ever inert.
# Both directions matter: a board credential that survives is a hole, and a
# runner credential that gets scrubbed makes the call impossible.
SCRUBBED=$(printf '%s\n' GH_TOKEN GITHUB_TOKEN PROJECT_2_INTERNAL_API_TOKEN LOCKS_TOKEN \
  PROJECT_2_DATABASE_URL VERCEL_TOKEN SLACK_WEBHOOK_URL JIRA_API_KEY CRON_SECRET GITHUB_PAT \
  ANTHROPIC_API_KEY CLAUDE_CODE_OAUTH_TOKEN PATH HOME HARNESS PROMPT_EVAL_MAX_DROP | scrub)
for MUST in GH_TOKEN GITHUB_TOKEN PROJECT_2_INTERNAL_API_TOKEN LOCKS_TOKEN PROJECT_2_DATABASE_URL \
            VERCEL_TOKEN SLACK_WEBHOOK_URL JIRA_API_KEY CRON_SECRET GITHUB_PAT; do
  grep -qx "$MUST" <<<"$SCRUBBED" && ok || bad "env scrub misses $MUST — an eval session would inherit it"
done
for KEEP in ANTHROPIC_API_KEY CLAUDE_CODE_OAUTH_TOKEN PATH HOME HARNESS PROMPT_EVAL_MAX_DROP; do
  grep -qx "$KEEP" <<<"$SCRUBBED" && bad "env scrub removes $KEEP — the runner could not authenticate" || ok
done

# --- 10. the shipped fixtures are well formed --------------------------------
# The grader being right is worthless if the golden scenarios rot. Both
# directions: every scenario parses, and the set still covers the gate reasons
# the plan named.
GOLD="$DIR/catalog/fixtures/golden"
[ -d "$GOLD" ] && ok || bad "catalog/fixtures/golden is missing"
NSC=0
for S in "$GOLD"/*/; do
  [ -d "$S" ] || continue
  NSC=$((NSC+1))
  N=$(basename "$S")
  [ -s "$S/expected.txt" ] || bad "$N: no expected.txt"
  [ -s "$S/inputs.md" ]    || bad "$N: no inputs.md (the board state the tick would see)"
  [ -s "$S/meta.json" ]    || bad "$N: no meta.json"
  if command -v jq >/dev/null; then
    jq -e '.gate and .project and .note' "$S/meta.json" >/dev/null 2>&1 \
      || bad "$N: meta.json must carry gate, project and note"
  fi
  # every expected line parses, and every action is a real DECISION verb
  awk -v n="$N" '
    /^[ \t]*(#|$)/ { next }
    { i = index($0, "::")
      if (i == 0) { print n ": unparseable expected line: " $0; bad=1; next }
      a = tolower(substr($0, i+2)); gsub(/[ \t]/, "", a)
      m = split(a, parts, /\|/)
      for (x = 1; x <= m; x++)
        if (parts[x] !~ /^(launch|queue|comment|status|skip|defer|close|escalate)$/) {
          print n ": unknown action " parts[x]; bad=1 }
    }
    END { exit bad ? 1 : 0 }' "$S/expected.txt" || bad "$N: expected.txt is not gradeable"
done
[ "$NSC" -ge 6 ] && ok || bad "only $NSC golden scenarios — the plan calls for 6-10 covering the gate reasons"
for NEED in board-changed queue-pending results-sweep; do
  grep -rslq "\"gate\"" "$GOLD" >/dev/null 2>&1
  if command -v jq >/dev/null; then
    jq -e --arg g "$NEED" -s 'map(.gate) | index($g)' "$GOLD"/*/meta.json >/dev/null 2>&1 \
      && ok || bad "no golden scenario covers gate reason '$NEED'"
  else
    ok
  fi
done
# the guard classes the SOP is most expensive to get wrong
for NEED in dup-launch waiting-on-client hold; do
  ls -d "$GOLD"/*"$NEED"* >/dev/null 2>&1 \
    && ok || bad "no golden scenario named for the '$NEED' guard"
done

# --- 11. the eval must ride agent-call.sh, or its spend is invisible ---------
grep -q 'agent-call.sh' "$DIR/bin/prompt-eval.sh" \
  && ok || bad "prompt-eval.sh does not call agent-call.sh — a metered lane with no cost row"
grep -qE 'agent-call\.sh"? +eval|EVAL_STAGE' "$DIR/bin/prompt-eval.sh" \
  && ok || bad "the eval does not run under its own named stage — its spend would land on the triage lane"
if command -v jq >/dev/null; then
  jq -e '[.lanes[] | select(.stage == "eval")] | length == 1' \
    "$DIR/catalog/context-budgets.json" >/dev/null 2>&1 \
    && ok || bad "the eval stage has no declared lane in catalog/context-budgets.json"
fi

# --- 12. the replicated TICK SCOPE preambles must not drift ------------------
# prompt-eval.sh rebuilds run-triage.sh's scope preambles rather than sharing
# them (Wave B held that file this round). A preamble that drifts between the
# tick and its eval makes the eval measure a prompt nobody runs — and it would
# drift silently, because both files stay perfectly valid. So a distinctive
# sentence from each gate's preamble has to appear in BOTH files.
#
# If this goes red: the two copies disagree. Re-sync prompt-eval.sh to
# run-triage.sh (the tick is the source of truth), or better, factor the
# preambles into one file both source — see the TODO(dedup) in prompt-eval.sh.
#
# The queue sentence is quoted THROUGH its slot clause (2026-09-11): the clause
# that names the launch gate is the half that actually drifted — it said
# "slots free per count-builds.sh" for a year, which counted processes and knew
# nothing about Fly routing — and the old truncated fixture stopped just short
# of it, so this guard would have watched that drift happen.
# THE TICK IS THE DRIVER PLUS ITS STAGES (BH-479). run-triage.sh is a sequence
# of calls into bin/lib/rt/*.sh now, and the sentences this section guards are
# assembled in scope.sh and shards.sh — so "the tick's text" is the
# concatenation, and every check below reads it. Pointing these at the driver
# alone would have turned the whole drift guard into a test of where a block
# happens to live rather than of what the fleet ships.
RT="$T/rt-all.sh"; cat "$DIR/bin/run-triage.sh" "$DIR"/bin/lib/rt/*.sh > "$RT"
PE="$DIR/bin/prompt-eval.sh"
while IFS= read -r LINE; do
  [ -z "$LINE" ] && continue
  if grep -qF "$LINE" "$RT" && grep -qF "$LINE" "$PE"; then ok
  else bad "TICK SCOPE preamble drift — this sentence is not in both run-triage.sh and prompt-eval.sh: ${LINE:0:70}..."; fi
done <<'EOF'
Work ONLY the tickets listed above this tick: fetch each one's full comment thread and act on it per the SOP below.
Work ONLY the queue this tick, per the SOP's queue and launch rules: for each line, verify its gating condition against reality (blocking PR merged? in-flight build finished? free slots per free-slots.sh
Handle ONLY these result dirs this tick, per the SOP's sweep rules
EOF

# --- 11c. the system append is SHARED, not replicated (2026-08-31) ----------
# The BUILD DEDUPE + DECISION LOG contract used to be two hand-copied literals,
# and prompt-eval.sh's carried a comment citing a run-triage.sh line number that
# had already moved. That is the drift this whole section guards against, in the
# one place where it costs money: the eval exists to catch the live SOP moving,
# so an eval grading a DIFFERENT contract reports drift that is really its own
# staleness — and every such report is a page nobody can act on.
#
# Checked by RESOLUTION, not by matching text in both files: asserting that the
# same sentence appears twice is the duplication this replaced.
# Matched against the ASSIGNMENT, not against any mention of the filename. Both
# files carry comment blocks naming triage-contract.sh, so a bare
# `grep -q 'triage-contract.sh'` passes on the prose alone — verified by swapping
# the assignment for a hardcoded literal and leaving the comment: the guard still
# went green. A drift guard its own failure message cannot detect is decoration.
grep -qE '^[[:space:]]*TRIAGE_APPEND=.*triage-contract\.sh' "$RT" \
  && ok || bad "run-triage.sh must take its system append from the shared contract, not a literal"
grep -qE '^[[:space:]]*SYS_APPEND=.*triage-contract\.sh' "$PE" \
  && ok || bad "prompt-eval.sh must grade the SAME shared contract the fleet ships"
CONTRACT=$(HARNESS="$DIR" bash "$DIR/bin/triage-contract.sh" 2>/dev/null)
[ -n "$CONTRACT" ] && ok || bad "the shared contract must resolve to something — an empty append silently drops the DECISION LOG request"
grep -qF 'DECISION LOG: end your final message with one line per ticket' <<<"$CONTRACT" \
  && ok || bad "the shared contract must still ask for the DECISION lines"
# ...and it must ask for DEDUPE, never for a turn in a queue (the operator, 2026-09-13).
# The rule this replaced told the tick to take /root/harness/locks/build.lock with
# `flock -w 3600` before a build wave, so a second wave sat behind the first for up
# to an hour. A contract that reintroduced that would be invisible here otherwise.
grep -qF 'BUILD DEDUPE' <<<"$CONTRACT" \
  && ok || bad "the shared contract must carry the BUILD DEDUPE rule"
grep -qE 'build\.lock|flock -w' <<<"$CONTRACT" \
  && bad "the contract asks the tick to WAIT on a lock again — nothing may queue behind another build" || ok
# The verb pin (2026-08-31). A tick that comments AND closes logs ONE verb, and
# the grader is code-based, so an unpinned choice reads as a regression forever:
# the project-2 gate paged six times over `close` vs `comment|status` when the
# behaviour was correct and only the vocabulary was unstated.
grep -qF 'launch > queue > escalate > comment > status > defer > close > skip' <<<"$CONTRACT" \
  && ok || bad "the contract must pin WHICH verb a multi-action tick logs, or the eval and the lane disagree forever"
# The pin has to be a total order over the declared vocabulary. An earlier draft
# stated it as "log the CLIENT-FACING act" and then gave two examples that
# violate it — `launch` and `escalate` are internal, and `escalate` beating
# `comment` inverts the client-facing test outright. A rule whose own examples
# contradict it is not a pin; it just moves the ambiguity.
for V in launch queue comment status skip defer close escalate; do
  grep -qF "$V" <<<"$(sed -n 's/.*highest first: \(.*\)\. Read it as.*/\1/p' <<<"$CONTRACT")" \
    || bad "verb '$V' is in the declared vocabulary but absent from the precedence order"
done
ok
# Loud, not empty: a missing contract file must fail, never yield "". Run from a
# copy in an isolated tree — pointing HARNESS elsewhere proves nothing, because
# the last fallback is the script's OWN ../catalog and would still find the repo.
mkdir -p "$T/isolated/bin"
cp "$DIR/bin/triage-contract.sh" "$T/isolated/bin/"
MISSING=$(HARNESS="$T/isolated" bash "$T/isolated/bin/triage-contract.sh" 2>/dev/null); MRC=$?
[ "$MRC" -ne 0 ] && [ -z "$MISSING" ] \
  && ok || bad "a missing contract file must exit nonzero and print nothing, not hand back an empty append as success (rc=$MRC)"

# ...and the CALLERS must act on that, which is a separate thing from the script
# being correct. `VAR="$(cmd)" prog` swallows cmd's exit status, and neither file
# runs under `set -e`, so without an explicit emptiness check a missing contract
# is not an error anywhere — it is a tick that quietly runs with no DECISION LOG
# rule and a benchmark that quietly grades a prompt the fleet never ships.
grep -q 'TRIAGE CONTRACT MISSING' "$RT" \
  && ok || bad "run-triage.sh must refuse the tick (and alert) when the contract resolves empty, not run without it"
grep -qE 'die "triage-contract.sh returned nothing' "$PE" \
  && ok || bad "prompt-eval.sh must refuse to grade when the contract resolves empty"

# --- 11d. no comment may sit inside a line continuation ---------------------
# A `\` at end of line joins the NEXT line to it. If that next line is a comment,
# everything after the `#` — including the rest of a multi-line command — is
# commented out. `bash -n` sees nothing wrong, the script still runs, and only
# the behaviour changes. This exact shape was introduced here while extracting
# the contract and silently dropped GROK_EFFORT's export from the triage call.
for f in "$RT" "$PE" "$DIR/bin/alerts-medic.sh" "$DIR/bin/alert-triage.sh" "$DIR/bin/triage-contract.sh"; do
  BADLINE=$(awk 'prev ~ /\\$/ && $0 ~ /^[[:space:]]*#/ { print NR": "$0; exit } { prev=$0 }' "$f")
  [ -z "$BADLINE" ] && ok \
    || bad "$(basename "$f"): a comment follows a line continuation — the rest of that command is commented out ($BADLINE)"
done

# --- 12b. THE ONE DELIBERATE DIVERGENCE, pinned in both directions -----------
# The live preambles end by telling the session that if the scope looks
# inconsistent it should "discard the scope and run the full SOP instead" — go
# enumerate the whole board. A fixture is inconsistent BY CONSTRUCTION (three
# tickets exist, one is scoped), and the fixture names a real repo slug and real
# /root/harness paths, so inherited verbatim that sentence is an instruction to
# go fetch a real client's board with the hub's credentials.
#
# It is REPLACED, not contradicted later by the envelope. Asserted both ways so
# neither half can rot: the live text must still be in run-triage.sh (if it is
# gone, this divergence is stale and the replication comment is lying), and it
# must be absent from prompt-eval.sh.
grep -vE '^[[:space:]]*#' "$PE" > "$T/pe-nocomments.txt"
while IFS= read -r LINE; do
  [ -z "$LINE" ] && continue
  grep -qF "$LINE" "$RT" \
    || bad "the live discard-scope text is gone from run-triage.sh — this divergence is now describing a prompt that no longer exists: ${LINE:0:60}..."
  # Comment lines are excluded on purpose: the divergence is EXPLAINED in a
  # comment right where it happens, and the thing that matters is whether the
  # sentence can reach a composed prompt. tests/prompt-eval-compose-test.sh
  # asserts the same property against real composed output.
  #
  # Via a file, NOT a pipe: `grep file | grep -q` flakes under pipefail when the
  # downstream grep exits early and SIGPIPEs the upstream one — the hazard
  # tests/rollup-crash-loud-test.sh lints the whole suite for, and which caught
  # this line the first time it was written.
  grep -qF "$LINE" "$T/pe-nocomments.txt" \
    && bad "prompt-eval.sh still composes the live discard-scope escape hatch — an eval session is being told to go enumerate a real board: ${LINE:0:60}..." || ok
done <<'EOF'
discard the scope and run the full SOP instead
discard this scope and run the full SOP instead
EOF
grep -q 'the BOARD STATE above is the entire world for this tick' "$PE" \
  && ok || bad "the eval-side replacement tail is missing — the preamble would just end mid-instruction"

echo "prompt-eval-grade-test: $PASS pass, $FAIL fail"
[ "$FAIL" -eq 0 ]
