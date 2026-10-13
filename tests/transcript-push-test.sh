#!/bin/bash
# tests/transcript-push-test.sh — bin/transcript-push.sh and its wiring into
# bin/agent-call.sh, driven for real.
#
# THREE CLAIMS, all of them about control flow, none of them greppable:
#   1. a stage that ran a model pushes ONE transcript per ATTEMPT, addressed to
#      the right job and phase — the survival ladder can call the same stage on
#      five vendors and each overwrites $OUT, so a push that ran once at the end
#      would silently keep only the lane that happened to answer last;
#   2. NOTHING is pushed unscrubbed. If the scrubber is missing or fails, the
#      push does not happen at all. This is the one place in the feature that
#      fails CLOSED, and a test that only checked the happy path would not know;
#   3. it is FAIL-OPEN in every other direction. An unreachable worker, a 500, a
#      lane with no claim, a stage with no output — none of them may change the
#      stage's rc by one digit.
# `grep -q transcript-push bin/agent-call.sh` passes on a version that hard-fails
# a build when the worker blinks, which is the failure this whole layer exists to
# avoid, reintroduced one level down.
# Run from anywhere: tests/transcript-push-test.sh   (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
# BH-1510.1: agent-call reads its ladders from model_routes; this worker-less box carries the resolver's cache of #1507's table.
. "$DIR/tests/lib/model-route-stub.sh" || exit 1
mrs_fixture "$T" testproj
mkdir -p "$T/logs" "$T/flags" "$T/state" "$T/bin" "$T/env" "$T/fakebin" "$T/builds/b1" "$T/projects/slot1"
cp "$DIR/bin/jobs-client.sh" "$DIR/bin/transcript-push.sh" "$DIR/bin/transcript-scrub.sh" \
   "$DIR/bin/transcript-render.sh" "$T/bin/"
mkdir -p "$T/bin/lib/jobs" && cp "$DIR"/bin/lib/jobs/*.sh "$T/bin/lib/jobs/"
chmod +x "$T/bin/"*
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null 2>&1 || { echo "transcript-push-test: SKIPPED — jq is not installed on this box"; exit 0; }

printf 'HARNESS_SECRET=FleetSecretValue999\n' > "$T/env/global.env"

# Fake curl. Records METHOD + URL, and — because a transcript body rides as
# `--data-binary @file` and never as an argv element — copies the BODY FILE
# aside so the assertions can read what was actually sent.
cat > "$T/fakebin/curl" <<'EOF'
#!/bin/bash
URL="${!#}"; BODY=""; METHOD=GET
while [ $# -gt 0 ]; do
  case "$1" in -X) METHOD="$2"; shift 2;; --data-binary) BODY="$2"; shift 2;; *) shift;; esac
done
[ -n "${REQ_SINK:-}" ] && printf '%s %s\n' "$METHOD" "$URL" >> "$REQ_SINK"
case "$BODY" in
  @*) F="${BODY#@}"
      case "$URL" in */transcript) N=$(ls "${BODY_DIR:-/tmp}" | grep -c '^tbody' || true)
                     cp "$F" "${BODY_DIR:-/tmp}/tbody$((N+1)).json" ;; esac ;;
esac
case "${CURL_MODE:-ok}" in
  down)   exit 7 ;;
  err500) printf 'boom\n500\n'; exit 0 ;;
esac
case "$URL" in
  */transcript)   printf '{"transcript":{"bytes":10}}\n200\n' ;;
  */phases/close) printf '{"job_id":"j","closed":1,"phases":[]}\n200\n' ;;
  */phases)       printf '{"phase":{"id":77,"job_id":"j","phase":"execute","status":"running"}}\n201\n' ;;
  */api/phases/*) printf '{"phase":{"id":77,"status":"done"}}\n200\n' ;;
  */heartbeat)    printf '{"job_id":"j"}\n200\n' ;;
  */api/catalog/*) printf '{"lane":"x","matched":null,"budget_usd":3,"source":"tier"}\n200\n' ;;
  *)              printf '{}\n404\n' ;;
esac
EOF

# Fake claude: writes a session jsonl the way the real CLI does (under a
# cwd-slug dir) and hands back a result carrying that session's id. When the
# FAIL_SENTINEL is present it fails, so the failover ladder engages and the
# stage runs a SECOND attempt — which is what proves attempts do not collapse.
cat > "$T/fakebin/claude" <<'EOF'
#!/bin/bash
OUTF=""
SID="sess-$(cat "$ATTEMPT_COUNTER" 2>/dev/null || echo 0)"
N=$(( $(cat "$ATTEMPT_COUNTER" 2>/dev/null || echo 0) + 1 )); echo "$N" > "$ATTEMPT_COUNTER"
SID="sess-$N"
cat > "$SESSION_DIR/$SID.jsonl" <<JSONL
{"type":"user","timestamp":"2026-08-29T10:00:01.000Z","message":{"role":"user","content":"do the thing with FleetSecretValue999"}}
{"type":"assistant","timestamp":"2026-08-29T10:00:02.000Z","message":{"role":"assistant","model":"m","content":[{"type":"text","text":"attempt $N speaking"}]}}
JSONL
# A real claude that dies mid-run prints its error and emits no result JSON;
# agent-call.sh then makes $OUT the error text. That text is exactly the
# evidence for why a second attempt happened, so the fake reproduces it.
if [ -f "$FAIL_SENTINEL" ] && [ "$N" = 1 ]; then
  printf 'claude: the vendor refused this attempt\n' >&2
  exit 1
fi
printf '{"result":"ok","session_id":"%s","usage":{"input_tokens":10,"output_tokens":2},"total_cost_usd":0.01}\n' "$SID"
EOF
cat > "$T/fakebin/codex" <<'EOF'
#!/bin/bash
printf 'codex answered\n'
EOF
cat > "$T/fakebin/timeout" <<'EOF'
#!/bin/bash
[ "${1:-}" = "--kill-after" ] && shift 2
case "${1:-}" in --kill-after=*) shift ;; esac
shift
exec "$@"
EOF
printf '#!/bin/bash\necho subscription\n' > "$T/fakebin/billing-mode.sh"
printf '#!/bin/bash\nexit 0\n' > "$T/bin/beat.sh"
chmod +x "$T/fakebin/"* "$T/bin/beat.sh"
# HOME is $T in these runs, so codex counts as "ready" only if its auth file is
# there. Without it the failover ladder skips codex and falls through to
# whichever survival lane the REAL environment happens to have a key for, which
# would make this suite's result depend on the box it runs on.
mkdir -p "$T/.codex"; echo '{}' > "$T/.codex/auth.json"

run_stage() { # run_stage [env assignments...] — one agent-call.sh stage under a claim
  rm -f "$T/req.log" "$T"/tbody*.json "$T/logs/transcripts.log" "$T/attempts"
  rm -f "$T/projects/slot1/"*.jsonl
  ( export PATH="$T/fakebin:$PATH" HARNESS="$T" HOME="$T" \
           REQ_SINK="$T/req.log" BODY_DIR="$T" ATTEMPT_COUNTER="$T/attempts" \
           SESSION_DIR="$T/projects/slot1" FAIL_SENTINEL="$T/failonce" \
           CLAUDE_PROJECTS_DIR="$T/projects" HARNESS_ENV_DIR="$T/env" \
           CONTEXT_BUDGETS="$DIR/catalog/context-budgets.json" \
           HARNESS_SECRET=FleetSecretValue999 JOBS_URL=https://jobs.invalid \
           JOB_ID=build-p-T1-1
    # The survival lanes are keyed off ambient env on a real box; a hub running
    # this suite would otherwise hand attempt 2 to OpenRouter and the assertions
    # below would be about that box rather than about this code.
    unset OPENROUTER_API_KEY FIREWORKS_API_KEY GEMINI_API_KEY OPENAI_API_KEY XAI_API_KEY
    "$@" bash "$DIR/bin/agent-call.sh" execute testproj some-model 600 "$T/builds/b1/out.txt" "hello" \
      >/dev/null 2>&1 )
  echo $?
}
bodies() { ls "$T"/tbody*.json 2>/dev/null | wc -l | tr -d ' '; }

# --- 1. a model stage pushes its conversation, addressed correctly ------------
rm -f "$T/failonce"
RC=$(run_stage env)
[ "$RC" = 0 ] && ok || bad "a healthy stage exited $RC"
grep -q 'POST https://jobs.invalid/api/jobs/build-p-T1-1/transcript' "$T/req.log" \
  && ok || bad "no transcript was pushed: $(cat "$T/req.log")"
[ "$(bodies)" = 1 ] && ok || bad "expected 1 transcript body, got $(bodies)"
B="$T/tbody1.json"
[ "$(jq -r '.phase_id' "$B")" = 77 ] && ok || bad "the transcript is not attached to the phase row: $(jq -c '{phase_id,attempt}' "$B")"
[ "$(jq -r '.attempt' "$B")" = 1 ] && ok || bad "the first attempt is not numbered 1"
[ "$(jq -r '.source' "$B")" = session_jsonl ] && ok || bad "the claude session file was not used as the source: $(jq -r '.source' "$B")"
[ "$(jq -r '.stage' "$B")" = execute ] && ok || bad "the transcript does not name its stage"
jq -r '.body' "$B" | grep -q 'attempt 1 speaking' \
  && ok || bad "the pushed body is not the rendered session: $(jq -r '.body' "$B" | head -5)"
jq -r '.body' "$B" | grep -q 'transcript · execute · attempt 1' \
  && ok || bad "the pushed body carries no provenance header"

# THE SECRET. The fixture session says the fleet secret out loud, exactly as a
# real session would after reading an env file. It must not reach the ledger.
grep -q 'FleetSecretValue999' <<<"$(jq -r '.body' "$B")" \
  && bad "A LIVE SECRET WAS PUSHED TO THE LEDGER" || ok
jq -r '.body' "$B" | grep -q 'REDACTED' \
  && ok || bad "the body was pushed with nothing redacted at all"
[ "$(jq -r '.redactions' "$B")" -ge 1 ] && ok || bad "the row claims 0 redactions on a body that had one"

# --- 2. ONE TRANSCRIPT PER ATTEMPT -------------------------------------------
# The failover ladder runs the stage again on codex. Each attempt overwrites
# $OUT and $OUT.json, so a push that ran once at the end would keep only the
# lane that answered last — and the transcript of the attempt that FAILED is
# precisely the evidence for why there was a second one.
touch "$T/failonce"
RC=$(run_stage env RUNNER_EXECUTE_FALLBACK=codex)
rm -f "$T/failonce"
[ "$(bodies)" = 2 ] && ok || bad "expected 2 transcripts across a failover, got $(bodies)"
if [ "$(bodies)" = 2 ]; then
  [ "$(jq -r '.attempt' "$T/tbody1.json")" = 1 ] && [ "$(jq -r '.attempt' "$T/tbody2.json")" = 2 ] \
    && ok || bad "attempts were not numbered 1 then 2"
  [ "$(jq -r '.runner' "$T/tbody2.json")" = codex ] \
    && ok || bad "the second attempt did not record the lane that actually served it: $(jq -r '.runner' "$T/tbody2.json")"
  # The FAILED attempt's transcript is the whole reason attempts are kept apart:
  # it carries why there had to be a second one.
  jq -r '.body' "$T/tbody1.json" | grep -q 'the vendor refused this attempt' \
    && ok || bad "the failed attempt's transcript does not carry its error"
  # The codex lane has no claude session file, so it is stage_output — and it
  # SAYS so rather than implying a full session.
  [ "$(jq -r '.source' "$T/tbody2.json")" = stage_output ] \
    && ok || bad "a non-claude lane claimed a session source: $(jq -r '.source' "$T/tbody2.json")"
  jq -r '.body' "$T/tbody2.json" | grep -q 'not the turn-by-turn session' \
    && ok || bad "the stage_output body does not say what it is"
else
  bad "skipped attempt assertions"; bad "skipped"; bad "skipped"; bad "skipped"; bad "skipped"
fi

# --- 3. THE SCRUBBER IS NON-NEGOTIABLE ---------------------------------------
# Missing or broken, nothing is pushed. An unscrubbed transcript in a database
# the console renders is worse than having no feature at all, so this is the one
# path in the whole feature that fails closed.
push_only() { # push_only <bin-dir>
  rm -f "$T/req.log" "$T"/tbody*.json "$T/logs/transcripts.log"
  cat > "$T/builds/b1/out.txt" <<<'final answer'
  ( export PATH="$T/fakebin:$PATH" HARNESS="$T" REQ_SINK="$T/req.log" BODY_DIR="$T" \
           HARNESS_ENV_DIR="$T/env" HARNESS_SECRET=FleetSecretValue999 \
           JOBS_URL=https://jobs.invalid JOB_ID=build-p-T1-1 JOB_PHASE_ID=77
    bash "$1/transcript-push.sh" execute claude m "$T/builds/b1/out.txt" 1 >/dev/null 2>&1 )
  echo $?
}
mkdir -p "$T/noscrub"; cp "$T/bin/transcript-push.sh" "$T/bin/jobs-client.sh" "$T/bin/transcript-render.sh" "$T/noscrub/"
mkdir -p "$T/noscrub/lib/jobs" && cp "$T/bin/lib/jobs"/*.sh "$T/noscrub/lib/jobs/"
RC=$(push_only "$T/noscrub")
[ "$RC" = 0 ] && ok || bad "a missing scrubber made the pusher exit $RC instead of 0"
[ "$(bodies)" = 0 ] && ok || bad "a transcript was pushed with NO SCRUBBER PRESENT"
grep -q 'REFUSING to push' "$T/logs/transcripts.log" \
  && ok || bad "the refusal was silent — nothing in logs/transcripts.log says why"

mkdir -p "$T/brokenscrub"; cp "$T/noscrub/"*.sh "$T/brokenscrub/"
mkdir -p "$T/brokenscrub/lib/jobs" && cp "$T/noscrub/lib/jobs"/*.sh "$T/brokenscrub/lib/jobs/"
printf '#!/bin/bash\nexit 3\n' > "$T/brokenscrub/transcript-scrub.sh"; chmod +x "$T/brokenscrub/transcript-scrub.sh"
RC=$(push_only "$T/brokenscrub")
[ "$RC" = 0 ] && ok || bad "a failing scrubber made the pusher exit $RC instead of 0"
[ "$(bodies)" = 0 ] && ok || bad "a transcript was pushed after the SCRUBBER FAILED"

# --- 4. fail-open everywhere else --------------------------------------------
# The stage has already done its work. A transcript is a side channel on it, and
# a side channel that can change an exit code is not a side channel.
RC=$(run_stage env CURL_MODE=down)
[ "$RC" = 0 ] && ok || bad "an unreachable worker changed the stage's rc to $RC"
RC=$(run_stage env CURL_MODE=err500)
[ "$RC" = 0 ] && ok || bad "a 500 from the worker changed the stage's rc to $RC"
grep -q 'push failed' "$T/logs/transcripts.log" \
  && ok || bad "a failed push left no line in logs/transcripts.log"

# An UNCLAIMED lane (no JOB_ID) has nothing to attach a transcript to, and must
# not try: this is the shape every hand-run agent-call.sh has.
rm -f "$T/req.log" "$T"/tbody*.json
( export PATH="$T/fakebin:$PATH" HARNESS="$T" REQ_SINK="$T/req.log" BODY_DIR="$T" \
         HARNESS_ENV_DIR="$T/env" HARNESS_SECRET=FleetSecretValue999 JOBS_URL=https://jobs.invalid
  bash "$T/bin/transcript-push.sh" execute claude m "$T/builds/b1/out.txt" 1 >/dev/null 2>&1 )
[ "$?" = 0 ] && [ ! -s "$T/req.log" ] \
  && ok || bad "an unclaimed lane still called the ledger: $(cat "$T/req.log" 2>/dev/null)"

# A stage that died before the model answered has NO conversation. Pushing an
# empty one would put a row on the job saying "there is a transcript" when there
# is not.
rm -f "$T/req.log" "$T"/tbody*.json "$T/logs/transcripts.log"
: > "$T/builds/b1/empty.txt"
( export PATH="$T/fakebin:$PATH" HARNESS="$T" REQ_SINK="$T/req.log" BODY_DIR="$T" \
         HARNESS_ENV_DIR="$T/env" HARNESS_SECRET=FleetSecretValue999 \
         JOBS_URL=https://jobs.invalid JOB_ID=build-p-T1-1
  bash "$T/bin/transcript-push.sh" execute claude m "$T/builds/b1/empty.txt" 1 >/dev/null 2>&1 )
[ "$(bodies)" = 0 ] && ok || bad "an empty stage pushed a transcript anyway"
grep -q 'nothing to push' "$T/logs/transcripts.log" \
  && ok || bad "the no-conversation case left no explanation in the log"

# --- 5. the tail cap ---------------------------------------------------------
# A runaway session must not put megabytes in D1, and the piece that is kept has
# to be the END — where the verdict, the failure and the last thing the model
# did all live.
rm -f "$T/req.log" "$T"/tbody*.json
{ printf 'HEADHEADHEAD\n'; head -c 6000 /dev/zero | tr '\0' 'x'; printf '\nTAILTAILTAIL\n'; } > "$T/builds/b1/big.txt"
( export PATH="$T/fakebin:$PATH" HARNESS="$T" REQ_SINK="$T/req.log" BODY_DIR="$T" \
         HARNESS_ENV_DIR="$T/env" HARNESS_SECRET=FleetSecretValue999 \
         JOBS_URL=https://jobs.invalid JOB_ID=build-p-T1-1 TRANSCRIPT_MAX_BYTES=2000
  bash "$T/bin/transcript-push.sh" execute claude m "$T/builds/b1/big.txt" 1 >/dev/null 2>&1 )
if [ "$(bodies)" = 1 ]; then
  [ "$(jq -r '.truncated' "$T/tbody1.json")" = 1 ] && ok || bad "an over-cap body was not marked truncated"
  jq -r '.body' "$T/tbody1.json" | grep -q 'TAILTAILTAIL' && ok || bad "the cap kept the head instead of the tail"
  grep -q 'HEADHEADHEAD' <<<"$(jq -r '.body' "$T/tbody1.json")" && bad "the head survived a cap that should have dropped it" || ok
  jq -r '.body' "$T/tbody1.json" | grep -q 'TAIL ONLY' && ok || bad "the truncated body does not say it is a tail"
else
  bad "the over-cap push did not happen at all"; bad "skipped"; bad "skipped"; bad "skipped"
fi

echo "transcript-push-test: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
