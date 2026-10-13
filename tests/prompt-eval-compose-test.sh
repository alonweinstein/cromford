#!/bin/bash
# tests/prompt-eval-compose-test.sh — drives bin/prompt-eval.sh end to end with
# a RECORDER in place of agent-call.sh, so what the eval would actually send —
# argv, environment, composed prompt — is read back off disk and asserted. No
# LLM calls, no network, no spend.
#
# THE THREE THINGS THIS EXISTS TO PIN:
#   1. side-effect freedom is MECHANICAL. Every call carries
#      AGENT_CALL_NO_TOOLS=1 and carries NO board/gh/db credential. The prompt
#      envelope is defense-in-depth and is deliberately not counted here.
#   2. the composed prompt does not inherit the live "discard the scope and run
#      the full SOP" escape hatch — against a fixture, which is inconsistent by
#      construction and names a real repo slug, that sentence is an instruction
#      to go fetch a real client's board.
#   3. the eval measures the prompt/model pair PRODUCTION runs — sweep ticks on
#      the light model, judgment ticks on the strong one.
# Run from anywhere: tests/prompt-eval-compose-test.sh   (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
_P1=$("$DIR"/bin/fleet-conf.sh --projects 2>/dev/null | head -1)
if [ -z "$_P1" ] || [ ! -f "$DIR/prompts/$_P1.md" ]; then
  echo "SKIP prompt-eval-compose: no per-project prompt to compose through"
  exit 0
fi
mkdir -p "$T/logs" "$T/state" "$T/rec/answers"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }

GOLD="$DIR/catalog/fixtures/golden"

# The recorder stands in for agent-call.sh: same argv contract, records
# everything, answers from a canned file per scenario.
cat > "$T/rec/agent-call-recorder.sh" <<'EOF'
#!/bin/bash
S=$(basename "$5" .out)
printf 'stage=%s project=%s model=%s scenario=%s\n' "$1" "$2" "$3" "$S" >> "$REC/calls.txt"
env | sed 's/=.*//' | sort > "$REC/env-$S.txt"
cp "${6#@}" "$REC/prompt-$S.txt" 2>/dev/null
[ -f "$REC/answers/$S" ] && cp "$REC/answers/$S" "$5"
exit 0
EOF
chmod +x "$T/rec/agent-call-recorder.sh"

# Perfect answers: for each scenario, emit the FIRST allowed action per key.
answer_perfectly() {
  rm -f "$T/rec/answers"/*
  for S in "$GOLD"/*/; do
    N=$(basename "$S")
    awk '/^[ \t]*(#|$)/{next} { i=index($0,"::"); k=$0; sub(/[ \t]*::.*/,"",k)
          a=substr($0,i+2); gsub(/[ \t]/,"",a); split(a,p,"|")
          printf "DECISION: %s :: %s :: canned\n", k, p[1] }' "$S/expected.txt" \
      > "$T/rec/answers/$N"
  done
}
run_eval() { # run_eval <project> [flags...]
  ( export REC="$T/rec" HARNESS="$T" \
           PROMPT_EVAL_FIXTURES="$GOLD" \
           PROMPT_EVAL_AGENT_CALL="$T/rec/agent-call-recorder.sh" \
           PROMPT_EVAL_BASELINE="$T/state/baseline.json" \
           GH_TOKEN=secret-gh GITHUB_TOKEN=secret-gh2 PROJECT_2_INTERNAL_API_TOKEN=secret-ta \
           LOCKS_TOKEN=secret-locks PROJECT_2_DATABASE_URL=postgres://secret \
           CRON_SECRET=secret-cron ANTHROPIC_API_KEY=keep-me \
           TRIAGE_MODEL=claude-fable-5 TRIAGE_MODEL_LIGHT=claude-sonnet-5
    bash "$DIR/bin/prompt-eval.sh" "$@" > "$T/run.out" 2>&1 )
  echo $?
}

# --- 1. every call is made under the no-tools contract -----------------------
answer_perfectly
: > "$T/rec/calls.txt"
RC=$(run_eval project-2)
[ "$RC" = 0 ] && ok || bad "a perfectly-answered run did not pass (rc=$RC): $(tail -5 "$T/run.out")"
NCALLS=$(grep -c 'scenario=' "$T/rec/calls.txt" 2>/dev/null || echo 0)
[ "$NCALLS" -ge 6 ] && ok || bad "only $NCALLS scenarios were run for project-2"
MISSING_FLAG=0
for F in "$T/rec"/env-*.txt; do grep -qx 'AGENT_CALL_NO_TOOLS' "$F" || MISSING_FLAG=1; done
[ "$MISSING_FLAG" = 0 ] && ok || bad "a call was made WITHOUT AGENT_CALL_NO_TOOLS — that session would have tools"

# --- 2. and with no credential to act with (layer 2) -------------------------
LEAKED=""
for F in "$T/rec"/env-*.txt; do
  for V in GH_TOKEN GITHUB_TOKEN PROJECT_2_INTERNAL_API_TOKEN LOCKS_TOKEN PROJECT_2_DATABASE_URL CRON_SECRET; do
    grep -qx "$V" "$F" && LEAKED="$LEAKED $V"
  done
done
[ -z "$LEAKED" ] && ok || bad "board/gh/db credentials reached an eval session:$(echo "$LEAKED" | tr ' ' '\n' | sort -u | tr '\n' ' ')"
# ...while the runner's own auth survives, or the call could not happen at all
grep -qx 'ANTHROPIC_API_KEY' "$(ls "$T/rec"/env-*.txt | head -1)" \
  && ok || bad "the scrub removed the runner's auth — every eval call would fail"

# --- 3. the composed prompt drops the live discard-scope escape hatch --------
FOUND=""
for F in "$T/rec"/prompt-*.txt; do
  grep -qF 'discard the scope and run the full SOP instead' "$F" && FOUND="$FOUND $(basename "$F")"
  grep -qF 'discard this scope and run the full SOP instead' "$F" && FOUND="$FOUND $(basename "$F")"
done
[ -z "$FOUND" ] && ok || bad "composed eval prompts still tell the session to enumerate a real board:$FOUND"
# the replacement is present in the scoped ones
grep -qF 'the BOARD STATE above is the entire world for this tick' \
  "$T/rec/prompt-board-changed-ready-launch.txt" \
  && ok || bad "the eval-specific scope tail is missing from a composed prompt"
# and the SOP itself is still there — the divergence must be surgical
grep -qF 'THE PRIME RULE' "$T/rec/prompt-board-changed-ready-launch.txt" \
  || grep -qF 'You are the board watcher' "$T/rec/prompt-board-changed-ready-launch.txt" \
  && ok || bad "the project SOP is missing from the composed prompt"

# --- 4. model fidelity: sweep ticks run the light model ----------------------
grep -q 'scenario=results-sweep-pr-merged model=claude-sonnet-5' \
  <(sed 's/\(model=[^ ]*\).*\(scenario=[^ ]*\)/\2 \1/' "$T/rec/calls.txt") \
  || grep -q 'model=claude-sonnet-5 scenario=results-sweep-pr-merged' "$T/rec/calls.txt" \
  && ok || bad "a results-sweep scenario did not run on TRIAGE_MODEL_LIGHT — the eval would measure a pair production never runs ($(grep results-sweep "$T/rec/calls.txt"))"
grep -q 'model=claude-fable-5 scenario=board-changed-ready-launch' "$T/rec/calls.txt" \
  && ok || bad "a judgment scenario did not run on the strong model"

# --- 5. scenarios are scoped to the project they were recorded against ------
# A fixture's board text names a real repo slug, prod domain and key prefix, so
# grading another project's SOP against it measures the mismatch, not the
# prompt. A project with no fixtures is a COVERAGE GAP and must say so — not
# quietly score 100% on someone else's scenarios.
: > "$T/rec/calls.txt"
RC=$(run_eval project-9)
[ "$RC" = 2 ] && ok || bad "project-9 (no fixtures of its own) returned rc=$RC instead of 2"
grep -q 'NO SCENARIOS' "$T/run.out" && ok || bad "a project with no fixtures did not say so: $(cat "$T/run.out")"
[ ! -s "$T/rec/calls.txt" ] && ok || bad "project-2 fixtures were run against the project-9 SOP"
: > "$T/rec/calls.txt"
RC=$(run_eval project-5)
grep -q 'scenario=gh-board-changed-ready-launch' "$T/rec/calls.txt" \
  && ok || bad "the GitHub-Issues scenarios did not run for project-5"
grep -q 'scenario=board-changed-ready-launch ' "$T/rec/calls.txt" \
  && bad "an in-app-board fixture was graded against a GitHub-Issues SOP" || ok

# --- 6. baseline friction (review I3) ----------------------------------------
answer_perfectly
RC=$(run_eval project-2 --baseline)
[ "$RC" = 0 ] && ok || bad "recording a first baseline failed (rc=$RC): $(tail -3 "$T/run.out")"
BASE_RATE=$(jq -r '.projects["project-2"].pass_rate' "$T/state/baseline.json")
[ "$BASE_RATE" = "100.0" ] && ok || bad "baseline recorded $BASE_RATE, expected 100.0"
grep -q 'BASELINE REWRITTEN' "$T/logs/ALERTS.log" \
  && ok || bad "a baseline overwrite left no trace in ALERTS.log"

# now break one answer and try to re-baseline over the regression
sed -i.bak 's/:: skip ::/:: launch ::/' "$T/rec/answers/board-changed-waiting-on-client"
RC=$(run_eval project-2 --baseline)
[ "$RC" != 0 ] && ok || bad "re-baselining over a regression exited 0"
grep -q 'BASELINE REFUSED' "$T/run.out" && ok || bad "the refusal was not explained: $(tail -3 "$T/run.out")"
STILL=$(jq -r '.projects["project-2"].pass_rate' "$T/state/baseline.json")
[ "$STILL" = "100.0" ] && ok || bad "the baseline was overwritten despite the refusal (now $STILL)"
# ...and --force-baseline records it, loudly
: > "$T/logs/ALERTS.log"
RC=$(run_eval project-2 --force-baseline)
NEW=$(jq -r '.projects["project-2"].pass_rate' "$T/state/baseline.json")
[ "$NEW" != "100.0" ] && ok || bad "--force-baseline did not record the new (worse) rate"
grep -q "BASELINE REWRITTEN: pass_rate 100.0 -> $NEW" "$T/logs/ALERTS.log" \
  && ok || bad "the forced overwrite did not log old -> new ($(cat "$T/logs/ALERTS.log"))"
# --baseline is refused outright in a cron run
RC=$(run_eval --cron --baseline)
[ "$RC" = 2 ] && ok || bad "--baseline with --cron was accepted (rc=$RC)"

# --- 7. coverage: a shrunken run must not read as an improvement (I2) -------
# THE FAILURE THIS CATCHES: six of eight scenarios error, the two that ran pass,
# the headline reads 100% — better than baseline — and the gate stays quiet on a
# run that graded a quarter of the policy.
answer_perfectly
RC=$(run_eval project-2 --force-baseline)   # baseline at full coverage
FULL_EXP=$(jq -r '.projects["project-2"].expected' "$T/state/baseline.json")
[ "$FULL_EXP" -ge 6 ] && ok || bad "baseline expected-count looks wrong ($FULL_EXP)"
# now make all but one scenario produce nothing at all
for F in "$T/rec/answers"/*; do
  [ "$(basename "$F")" = "board-changed-ready-launch" ] || rm -f "$F"
done
RC=$(run_eval project-2)
[ "$RC" = 2 ] && ok || bad "a run that graded 1 of $FULL_EXP expected decisions returned rc=$RC, not 2"
grep -q 'COVERAGE-SHRANK' "$T/run.out" && ok || bad "the shrunken run did not report COVERAGE-SHRANK: $(tail -4 "$T/run.out")"
grep -qE 'scenario\(s\) errored' "$T/run.out" && ok || bad "errored scenarios were not counted in the readout"
# and it must not be recordable as the new baseline without --force
RC=$(run_eval project-2 --baseline)
[ "$RC" != 0 ] && grep -q 'BASELINE REFUSED' "$T/run.out" \
  && ok || bad "a coverage-shrunk run could be recorded as the new baseline"

echo "prompt-eval-compose-test: $PASS pass, $FAIL fail"
[ "$FAIL" -eq 0 ]
