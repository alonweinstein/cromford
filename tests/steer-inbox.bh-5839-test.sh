#!/bin/bash
# tests/steer-inbox.bh-5839-test.sh — BH-5839: a note a person sends "now" from
# the ticket page is read by the running build at its next step boundary.
#
# The step boundary is bin/agent-call.sh: every model call of a build passes it,
# and the prompt is final at prompt_guard. Driven through the REAL extracted
# CC() -> the REAL bin/agent-call.sh -> a fake worker `curl` and a fake `claude`
# that writes the prompt it was handed to a file:
#   I1 a pending note is in the next stage's prompt, and the take was asked
#      for this job (the worker records the read: worker/jobs/test/steer.bh-5839)
#   I2 nothing pending: the prompt is the stage's own, byte for byte (the same
#      prompt-provenance sha as a run with no JOB_ID)
#   I3 the worker does not answer: the stage still runs (fail-open), no notes,
#      and logs/steer.log says the take was not answered
#   I4 no JOB_ID (a lane not enrolled in the coordination DB): no take is asked
#   I5 a hold note sent to this job: nothing is called or billed, the stage
#      answers rc 74 AGENT_CALL_REFUSED steer-hold, and CC() defers the build
#      (BUILD_DEFERRED, exit 3, $BUILD/BUDGET_DEFER), which is how it stops
#      after its current step
#   I5b a take that answers a hold AND a note: still refused, no vendor call,
#      and no settle marks the note read
#   I6 the vendor call fails: the taken notes are settled read:false, so the
#      worker gives them back as pending for the next step
#   I7 a job phase is open (the phase-close EXIT trap replaces the take's): the
#      phase closes with the real rc and the notes are still settled read:true
#   I8 a direct bin/agent-call.sh call inside a build (replan-check, the repro
#      drive, decompose: no AGENT_CALL_STEER=1) takes nothing, so a hold is not
#      claimed by a caller that does not stop on it
#
# Run from anywhere: tests/steer-inbox.bh-5839-test.sh (exit 0 = pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
. "$DIR/tests/lib/model-route-stub.sh" || exit 1
. "$DIR/tests/lib/rb-all.sh" || exit 1
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }
command -v python3 >/dev/null || { echo "python3 missing — skipping"; exit 0; }

[ -r "$DIR/bin/lib/steer.sh" ] && ok || bad "I0 bin/lib/steer.sh is missing"

RB_ALL=$(rb_all "$DIR" "$T/run-build.all.sh")
python3 - "$RB_ALL" "$T/cc.sh" <<'PY'
import sys
src = open(sys.argv[1]).read()
start = src.index("CC() { # CC <stage>")
end = src.index("\n}\n", start) + len("\n}\n")
open(sys.argv[2], "w").write(src[start:end])
PY
[ -s "$T/cc.sh" ] && ok || bad "I0 could not extract CC()"

mkdir -p "$T/bin/lib/jobs" "$T/fakebin" "$T/flags" "$T/locks" "$T/logs" "$T/state" "$T/w"
mrs_fixture "$T" testproj
scratch_install_closure bin/jobs-client.sh "$T" >/dev/null || exit 1
scratch_install_closure bin/billing-mode.sh "$T" >/dev/null || exit 1
printf '#!/bin/bash\nexec bash "%s/bin/agent-call.sh" "$@"\n' "$DIR" > "$T/bin/agent-call.sh"
# The fake vendor: one line in the call log, the prompt it was handed in a file.
cat > "$T/fakebin/claude" <<'EOF'
#!/bin/bash
echo claude >> "$CALLS"
cat > "$PROMPT_SINK"
[ -n "${CLAUDE_FAIL:-}" ] && { echo "fixture vendor failure" >&2; exit 1; }
echo '{"result":"the answer","usage":{"input_tokens":10,"output_tokens":2},"total_cost_usd":0.01}'
EOF
cat > "$T/fakebin/timeout" <<'EOF'
#!/bin/bash
[ "${1:-}" = "--kill-after" ] && shift 2
case "${1:-}" in --kill-after=*) shift ;; esac
shift
exec "$@"
EOF
# The fake worker answers POST /api/steer/take from $TAKE (a file) and logs the
# request; every other jobs call fails as an outage (curl rc 7), which the
# client treats as fail-open. With $TAKE_DOWN set, the take fails the same way.
cat > "$T/fakebin/curl" <<'EOF'
#!/bin/bash
url="" data=""
while [ $# -gt 0 ]; do
  case "$1" in
    --data-binary) data="$2"; shift 2 ;;
    -X|-m|--connect-timeout|-w|-H) shift 2 ;;
    -*) shift ;;
    *) url="$1"; shift ;;
  esac
done
case "$data" in @*) data=$(cat "${data#@}") ;; esac
case "$url" in
  */api/steer/take)
    printf 'take %s\n' "$data" >> "$CALLS"
    [ -n "${TAKE_DOWN:-}" ] && exit 7
    printf '%s\n200' "$(cat "$TAKE")" ;;
  */api/steer/settle)
    printf 'settle %s\n' "$data" >> "$CALLS"
    printf '{"notes":[]}\n200' ;;
  */api/jobs/*/phases)
    [ -n "${PHASES_UP:-}" ] || exit 7
    printf '{"phase":{"id":7}}\n200' ;;
  */api/phases/*)
    printf 'phase-close %s\n' "$data" >> "$CALLS"
    printf '{}\n200' ;;
  *) exit 7 ;;
esac
EOF
printf '#!/bin/bash\nexit 0\n' > "$T/bin/beat.sh"
printf '#!/bin/bash\necho "test rules"\n' > "$T/bin/sync-agent-rules.sh"
chmod +x "$T/fakebin/"* "$T/bin/"*.sh

STAGE_PROMPT="execute for BH-5839. Write the code."
NOTE1='{"id":12,"mode":"now","text":"Check the 375px layout before the table.","actor":"operator@example.com","created_at":"2026-10-09T20:01:00Z"}'
NOTE2='{"id":13,"mode":"now","text":"Keep the old route.","actor":"operator@example.com","created_at":"2026-10-09T20:02:00Z"}'
HOLD='{"id":14,"mode":"hold","text":"Wait for the schema answer.","actor":"operator@example.com","created_at":"2026-10-09T20:03:00Z"}'
reset() { : > "$T/calls"; rm -f "$T/prompt" "$T/logs/"* 2>/dev/null; }
# cc <build-dir> [VAR=VAL ...] -> prints CC()'s rc
cc() {
  local b="$1"; shift
  mkdir -p "$b"
  ( unset AGENT_CALL_GUARD_STAGE AGENT_CALL_TICKET HARNESS_TICKET AGENT_CALL_FP CALL_GUARD JOB_ID JOB_PHASE_ID
    export CALLS="$T/calls" PROMPT_SINK="$T/prompt" TAKE="$T/take.json" \
           PATH="$T/fakebin:$PATH" HOME="$T" \
           JOBS_URL="https://jobs.test" HARNESS_SECRET="test-secret" JOBS_RETRIES=0 JOBS_BOX=testbox \
           CLAUDE_CODE_OAUTH_TOKEN=tok ANTHROPIC_API_KEY= \
           OPENROUTER_API_KEY= FIREWORKS_API_KEY= CODEX_API_KEY= OPENAI_API_KEY= ACCOUNT_ROUTING=0 \
           LADDER_TIER2_GROK=0 LADDER_BACKOFF_SECS=0 LADDER_SAME_RETRIES=0 \
           AGENT_CALL_RUNNERS= AGENT_CALL_LEDGER=0 RUNNER_EXECUTE=claude RUNNER_EXECUTE_FALLBACK= \
           LANE_GATE_DISABLE=1 LLM_GATE_DISABLE=1 CALL_GUARD=0 \
           CONTEXT_BUDGETS="$DIR/catalog/context-budgets.json" "$@"
    export HARNESS="$T"
    cd "$T/w" || exit 9
    HARNESS="$T"; PROJECT=testproj; KEY=BH-5839; BUILD="$b"; CG_ORIENT="CODEGRAPH NOT AVAILABLE"; VMAP_ORIENT="VMAP"
    RESULT() { printf '%s\n' "$*" > "$b/RESULT"; }
    . "$T/cc.sh"
    CC execute claude-fable-5-1 60 "$b/execute-run.txt" "$STAGE_PROMPT" >/dev/null 2>&1 )
  echo $?
}
takes() { grep -c '^take ' "$T/calls" 2>/dev/null || true; }
settles() { grep '^settle ' "$T/calls" 2>/dev/null | sed 's/^settle //'; }
vendor() { grep -c '^claude$' "$T/calls" 2>/dev/null || true; }

# I1 two pending notes: both are in the prompt, in order, after the stage's own text
reset; jq -nc --argjson a "$NOTE1" --argjson b "$NOTE2" '{notes:[$a,$b],hold:null}' > "$T/take.json"
r=$(cc "$T/b/n1" JOB_ID=job-41)
[ "$r" = 0 ] && ok || bad "I1 CC rc $r, want 0 ($(cat "$T/logs/"* 2>/dev/null | tail -3))"
[ "$(vendor)" = 1 ] && ok || bad "I1 vendor calls $(vendor), want 1"
grep -q '^take {"job_id":"job-41"}$' "$T/calls" && ok || bad "I1 the take was not asked for job-41: $(grep take "$T/calls")"
P=$(cat "$T/prompt" 2>/dev/null)
grep -qF "$STAGE_PROMPT" <<<"$P" && ok || bad "I1 the stage's own prompt is gone"
grep -qF 'Check the 375px layout before the table.' <<<"$P" && ok || bad "I1 note 12 is not in the prompt"
grep -qF 'Keep the old route.' <<<"$P" && ok || bad "I1 note 13 is not in the prompt"
a=$(grep -nF 'Check the 375px' <<<"$P" | cut -d: -f1); b=$(grep -nF 'Keep the old route' <<<"$P" | cut -d: -f1); s=$(grep -nF "$STAGE_PROMPT" <<<"$P" | head -1 | cut -d: -f1)
[ -n "$a" ] && [ -n "$b" ] && [ -n "$s" ] && [ "$s" -lt "$a" ] && [ "$a" -lt "$b" ] && ok \
  || bad "I1 order: stage line $s, note 12 line $a, note 13 line $b"
grep -qF 'operator@example.com' <<<"$P" && ok || bad "I1 the note does not say who sent it"
[ "$(settles | jq -c '[.job_id,.read,.ids]')" = '["job-41",true,[12,13]]' ] && ok \
  || bad "I1 the call ran, so the notes must settle read:true once: $(settles)"

# I2 nothing pending: the prompt carries no notes block
reset; echo '{"notes":[],"hold":null}' > "$T/take.json"
r=$(cc "$T/b/n2" JOB_ID=job-41)
[ "$r" = 0 ] && [ "$(vendor)" = 1 ] && [ "$(takes)" = 1 ] && ok || bad "I2 rc $r vendor $(vendor) takes $(takes)"
[ -z "$(settles)" ] && ok || bad "I2 nothing was taken, so nothing settles: $(settles)"
grep -q 'sent these notes' "$T/prompt" && bad "I2 an empty take added a notes block" || ok
cp "$T/prompt" "$T/prompt.i2" 2>/dev/null

# I3 the worker is down: the stage runs, no notes, a log line says so
reset; r=$(cc "$T/b/n3" JOB_ID=job-41 TAKE_DOWN=1)
[ "$r" = 0 ] && [ "$(vendor)" = 1 ] && ok || bad "I3 a dead worker stopped the stage: rc $r vendor $(vendor)"
grep -q 'sent these notes' "$T/prompt" && bad "I3 notes from nowhere" || ok
grep -q 'job job-41: take not answered' "$T/logs/steer.log" 2>/dev/null && ok || bad "I3 logs/steer.log has no 'take not answered' line"

# I4 no JOB_ID: no take at all
reset; echo '{"notes":[],"hold":null}' > "$T/take.json"
r=$(cc "$T/b/n4")
[ "$r" = 0 ] && [ "$(takes)" = 0 ] && [ "$(vendor)" = 1 ] && ok || bad "I4 rc $r takes $(takes) vendor $(vendor), want 0, 0 and 1"
# I2 again: an empty take leaves the prompt byte-equal to a run with no JOB_ID
[ -s "$T/prompt.i2" ] && cmp -s "$T/prompt.i2" "$T/prompt" && ok || bad "I2 the empty-take prompt differs from the no-JOB_ID prompt"

# I5 a hold note for this job: refused before the vendor, and CC() defers
reset; jq -nc --argjson h "$HOLD" '{notes:[],hold:$h}' > "$T/take.json"
r=$(cc "$T/b/h1" JOB_ID=job-41)
[ "$r" = 3 ] && ok || bad "I5 CC rc $r, want 3 (the build defers)"
[ "$(vendor)" = 0 ] && ok || bad "I5 the vendor was called $(vendor) time(s) on a hold"
head -1 "$T/b/h1/execute-run.txt" 2>/dev/null | grep -q '^AGENT_CALL_REFUSED steer-hold 14' && ok \
  || bad "I5 execute-run.txt line 1: '$(head -1 "$T/b/h1/execute-run.txt" 2>/dev/null)'"
grep -qx 'BUILD_DEFERRED steer-hold 14 Wait for the schema answer.' "$T/b/h1/RESULT" 2>/dev/null && ok || bad "I5 RESULT: '$(cat "$T/b/h1/RESULT" 2>/dev/null)'"
grep -qx 'steer-hold 14 Wait for the schema answer.' "$T/b/h1/BUDGET_DEFER" 2>/dev/null && ok \
  || bad "I5 BUDGET_DEFER: '$(cat "$T/b/h1/BUDGET_DEFER" 2>/dev/null)' (later CC() calls and the lenses read it)"
grep -q 'refused: hold note #14 for job job-41' "$T/logs/failovers.log" 2>/dev/null && ok || bad "I5 no failovers.log line for the refusal"

# I5b the take answers a hold and a note: the hold wins, nothing is read
reset; jq -nc --argjson h "$HOLD" --argjson a "$NOTE1" '{notes:[$a],hold:$h}' > "$T/take.json"
r=$(cc "$T/b/h2" JOB_ID=job-41)
[ "$r" = 3 ] && [ "$(vendor)" = 0 ] && ok || bad "I5b rc $r vendor $(vendor), want 3 and 0"
settles | jq -e 'select(.read == true)' >/dev/null 2>&1 && bad "I5b a note was settled read on a hold: $(settles)" || ok
grep -qF 'Check the 375px layout' "$T/prompt" 2>/dev/null && bad "I5b the note reached a prompt" || ok

# I6 the vendor fails: the notes go back as pending (read:false)
reset; jq -nc --argjson a "$NOTE1" '{notes:[$a],hold:null}' > "$T/take.json"
r=$(cc "$T/b/f1" JOB_ID=job-41 CLAUDE_FAIL=1)
[ "$r" != 0 ] && ok || bad "I6 a failed vendor call answered rc 0"
[ "$(settles | jq -c '[.read,.ids]')" = '[false,[12]]' ] && ok || bad "I6 settle after a failed call: '$(settles)', want read:false ids [12]"

# I7 a phase row is open: its EXIT trap replaces the take's and must settle too
reset; jq -nc --argjson a "$NOTE1" '{notes:[$a],hold:null}' > "$T/take.json"
r=$(cc "$T/b/p1" JOB_ID=job-41 PHASES_UP=1)
[ "$r" = 0 ] && ok || bad "I7 rc $r"
grep -q '^phase-close .*"status":"done"' "$T/calls" && ok || bad "I7 the phase did not close done: $(grep phase "$T/calls")"
[ "$(settles | jq -c '[.read,.ids]')" = '[true,[12]]' ] && ok || bad "I7 settle with a phase open: '$(settles)'"
reset; r=$(cc "$T/b/p2" JOB_ID=job-41 PHASES_UP=1 CLAUDE_FAIL=1)
grep -q '^phase-close .*"status":"failed"' "$T/calls" && ok || bad "I7 the failed phase did not close failed: $(grep phase "$T/calls")"
[ "$(settles | jq -c '.read')" = false ] && ok || bad "I7 a failed call with a phase open settled '$(settles)'"

# I8 a direct agent-call.sh call (no CC(), so no AGENT_CALL_STEER=1): no take
reset; jq -nc --argjson h "$HOLD" '{notes:[],hold:$h}' > "$T/take.json"
mkdir -p "$T/b/d1"
( unset AGENT_CALL_GUARD_STAGE AGENT_CALL_TICKET HARNESS_TICKET AGENT_CALL_FP JOB_PHASE_ID AGENT_CALL_STEER
  export CALLS="$T/calls" PROMPT_SINK="$T/prompt" TAKE="$T/take.json" PATH="$T/fakebin:$PATH" HOME="$T" HARNESS="$T" \
         JOBS_URL="https://jobs.test" HARNESS_SECRET="test-secret" JOBS_RETRIES=0 JOBS_BOX=testbox JOB_ID=job-41 \
         CLAUDE_CODE_OAUTH_TOKEN=tok ANTHROPIC_API_KEY= OPENROUTER_API_KEY= FIREWORKS_API_KEY= CODEX_API_KEY= OPENAI_API_KEY= \
         ACCOUNT_ROUTING=0 LADDER_TIER2_GROK=0 LADDER_BACKOFF_SECS=0 LADDER_SAME_RETRIES=0 AGENT_CALL_RUNNERS= AGENT_CALL_LEDGER=0 \
         RUNNER_EXECUTE=claude RUNNER_EXECUTE_FALLBACK= LANE_GATE_DISABLE=1 LLM_GATE_DISABLE=1 CALL_GUARD=0 \
         CONTEXT_BUDGETS="$DIR/catalog/context-budgets.json"
  cd "$T/w" && "$T/bin/agent-call.sh" execute testproj claude-fable-5-1 60 "$T/b/d1/out.txt" "$STAGE_PROMPT" ) >/dev/null 2>&1
r=$?
[ "$r" = 0 ] && [ "$(takes)" = 0 ] && [ "$(vendor)" = 1 ] && ok || bad "I8 rc $r takes $(takes) vendor $(vendor), want 0, 0 and 1"

echo "steer-inbox.bh-5839: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
