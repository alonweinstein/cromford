#!/bin/bash
# tests/transcript-push-artifact.bh-531-test.sh — bin/transcript-push.sh under
# TRANSCRIPT_SOURCE, the artifact-body override added by BH-531.
#
# WHAT THE OVERRIDE IS FOR. A build that ends PLAN_BLOCKED has to get the BODY of
# plan.md off the machine before the machine dies. The ledger already has a table
# for large scrubbed text (job_transcripts) and this script already owns the cap
# and the scrub, so the body rides that path with source=plan_md instead of a new
# table nobody else reads.
#
# WHAT HAS TO BE TRUE, and none of it is visible in a grep:
#   1. the row is addressed to a RESERVED slot (phase 0, attempt 100) that no
#      real session can reach, and a caller passing an explicit attempt cannot
#      steer it onto one — an artifact overwriting an execute transcript is a
#      silent loss of the evidence a reviewer needs;
#   2. the body is the FILE, byte-for-byte after the scrub, with NO provenance
#      header: the watcher box writes this back to disk as plan.md and a session
#      quotes it to a client, so five lines the planner never wrote must not be
#      in it;
#   3. the scrub still fails CLOSED and the cap still applies — an artifact is
#      not a reason to relax either;
#   4. with the override UNSET this script is byte-identical to what
#      bin/agent-call.sh has always called (the header is still there).
# Run from anywhere: tests/transcript-push-artifact.bh-531-test.sh (exit 0 = pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null 2>&1 || { echo "transcript-push-artifact.bh-531-test: SKIPPED — jq is not installed"; exit 0; }

mkdir -p "$T/h/bin" "$T/h/logs" "$T/h/env" "$T/fakebin" "$T/b"
cp "$DIR/bin/transcript-push.sh" "$DIR/bin/transcript-scrub.sh" \
   "$DIR/bin/transcript-render.sh" "$DIR/bin/jobs-client.sh" "$T/h/bin/"
mkdir -p "$T/h/bin/lib/jobs" && cp "$DIR"/bin/lib/jobs/*.sh "$T/h/bin/lib/jobs/"
chmod +x "$T/h/bin/"*
printf 'HARNESS_SECRET=FleetSecretValue999\n' > "$T/h/env/global.env"

# Records the request and copies the body FILE aside — a transcript rides as
# `--data-binary @file` and never as an argv element.
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
printf '{"transcript":{"bytes":10}}\n200\n'
EOF
chmod +x "$T/fakebin/curl"

push() { # push <env-assignments...> -- <args to transcript-push.sh>
  rm -f "$T/req.log" "$T"/tbody*.json "$T/h/logs/transcripts.log"
  local envs=() ; while [ $# -gt 0 ] && [ "$1" != "--" ]; do envs+=("$1"); shift; done; shift
  ( export PATH="$T/fakebin:$PATH" HARNESS="$T/h" HARNESS_ENV_DIR="$T/h/env" \
           REQ_SINK="$T/req.log" BODY_DIR="$T" HARNESS_SECRET=FleetSecretValue999 \
           JOBS_URL=https://jobs.invalid JOBS_BOX=pool-machine-1 JOB_ID=build-project-3-TK-77-1
    env "${envs[@]}" bash "$T/h/bin/transcript-push.sh" "$@" >/dev/null 2>&1 )
  echo $?
}
bodies() { ls "$T"/tbody*.json 2>/dev/null | wc -l | tr -d ' '; }
B="$T/tbody1.json"

printf 'Q1: which fee does the rep set?\nQ2: per invoice or per client?\n' > "$T/b/plan.md"

# ══ 1. THE HAPPY PATH: a plan body lands on the reserved slot ═══════════════
RC=$(push TRANSCRIPT_SOURCE=plan_md -- plan pipeline "" "$T/b/plan.md")
[ "$RC" = 0 ] && ok || bad "an artifact push exited $RC"
[ "$(bodies)" = 1 ] && ok || bad "expected exactly 1 pushed body, got $(bodies): $(cat "$T/req.log" 2>/dev/null)"
if [ "$(bodies)" = 1 ]; then
  [ "$(jq -r '.source' "$B")" = plan_md ] && ok || bad "source must be plan_md, got '$(jq -r '.source' "$B")'"
  [ "$(jq -r '.attempt' "$B")" = 100 ] && ok || bad "the artifact must land on the reserved attempt 100, got '$(jq -r '.attempt' "$B")'"
  [ "$(jq -r 'has("phase_id")' "$B")" = false ] && ok || bad "an artifact must carry NO phase_id: $(jq -c . "$B" | head -c 200)"
  [ "$(jq -r '.stage' "$B")" = plan ] && ok || bad "stage must survive, got '$(jq -r '.stage' "$B")'"
  [ "$(jq -r '.runner' "$B")" = pipeline ] && ok || bad "runner must survive, got '$(jq -r '.runner' "$B")'"
  [ "$(jq -r '.truncated' "$B")" = 0 ] && ok || bad "a short body must not be marked truncated"
  # BYTE-FOR-BYTE. The box writes this back as plan.md and a session quotes it.
  jq -j '.body' "$B" > "$T/got.txt"
  cmp -s "$T/got.txt" "$T/b/plan.md" \
    && ok || bad "the pushed body must be the file itself: $(head -3 "$T/got.txt")"
  grep -q '── transcript' "$T/got.txt" \
    && bad "an artifact body must carry NO provenance header — the box writes it back as the file" || ok
else
  bad "skipped: source"; bad "skipped: attempt"; bad "skipped: phase_id"; bad "skipped: stage"
  bad "skipped: runner"; bad "skipped: truncated"; bad "skipped: body"; bad "skipped: header"
fi
grep -q 'POST https://jobs.invalid/api/jobs/build-project-3-TK-77-1/transcript' "$T/req.log" \
  && ok || bad "the push did not address the job's transcript route: $(cat "$T/req.log" 2>/dev/null)"

# ══ 2. AN EXPLICIT ATTEMPT IS IGNORED under an artifact source ══════════════
# #725 review finding 3: a caller passing 5 would drop the artifact onto a real
# session slot (0,5) and overwrite it. The slot is the code's to choose.
RC=$(push TRANSCRIPT_SOURCE=plan_md -- plan pipeline "" "$T/b/plan.md" 5)
[ "$(bodies)" = 1 ] && [ "$(jq -r '.attempt' "$B" 2>/dev/null)" = 100 ] \
  && ok || bad "an explicit \$5 must not steer the artifact off the reserved slot, got '$(jq -r '.attempt' "$B" 2>/dev/null)'"

# ...and an ambient JOB_PHASE_ID cannot attach it to a phase either.
RC=$(push TRANSCRIPT_SOURCE=plan_md JOB_PHASE_ID=77 -- plan pipeline "" "$T/b/plan.md")
[ "$(jq -r 'has("phase_id")' "$B" 2>/dev/null)" = false ] \
  && ok || bad "an ambient JOB_PHASE_ID reached the payload: $(jq -c . "$B" 2>/dev/null | head -c 200)"

# ══ 3. THE CAP STILL APPLIES ════════════════════════════════════════════════
{ printf 'HEADHEADHEAD\n'; head -c 6000 /dev/zero | tr '\0' 'x'; printf '\nTAILTAILTAIL\n'; } > "$T/b/big.md"
RC=$(push TRANSCRIPT_SOURCE=plan_md TRANSCRIPT_MAX_BYTES=2000 -- plan pipeline "" "$T/b/big.md")
if [ "$(bodies)" = 1 ]; then
  [ "$(jq -r '.truncated' "$B")" = 1 ] && ok || bad "an over-cap artifact was not marked truncated"
  [ "$(jq -j '.body' "$B" | wc -c | tr -d ' ')" -le 2000 ] \
    && ok || bad "the capped body is $(jq -j '.body' "$B" | wc -c | tr -d ' ')B, over the 2000B cap"
  jq -r '.body' "$B" | grep -q 'TAILTAILTAIL' && ok || bad "the cap kept the head instead of the tail"
  grep -q 'HEADHEADHEAD' <<<"$(jq -r '.body' "$B")" && bad "the head survived a cap that should have dropped it" || ok
else
  bad "the over-cap push did not happen"; bad "skipped"; bad "skipped"; bad "skipped"
fi

# ══ 4. THE SCRUB IS STILL NON-NEGOTIABLE ════════════════════════════════════
# A plan can quote an env file as easily as a session can.
printf 'Q1: the token is FleetSecretValue999, is that the one?\n' > "$T/b/secret.md"
RC=$(push TRANSCRIPT_SOURCE=plan_md -- plan pipeline "" "$T/b/secret.md")
if [ "$(bodies)" = 1 ]; then
  grep -q 'FleetSecretValue999' <<<"$(jq -r '.body' "$B")" \
    && bad "A LIVE SECRET WAS PUSHED TO THE LEDGER in an artifact body" || ok
  jq -r '.body' "$B" | grep -q 'REDACTED' && ok || bad "the artifact body was pushed with nothing redacted"
  [ "$(jq -r '.redactions' "$B")" -ge 1 ] && ok || bad "the row claims 0 redactions on a body that had one"
  grep -q FleetSecretValue999 "$B" \
    && bad "the secret survived somewhere else in the payload" || ok
else
  bad "the secret-body push did not happen"; bad "skipped"; bad "skipped"; bad "skipped"
fi

mkdir -p "$T/noscrub"
cp "$T/h/bin/transcript-push.sh" "$T/h/bin/jobs-client.sh" "$T/h/bin/transcript-render.sh" "$T/noscrub/"
mkdir -p "$T/noscrub/lib/jobs" && cp "$T/h"/bin/lib/jobs/*.sh "$T/noscrub/lib/jobs/"
rm -f "$T/req.log" "$T"/tbody*.json "$T/h/logs/transcripts.log"
( export PATH="$T/fakebin:$PATH" HARNESS="$T/h" HARNESS_ENV_DIR="$T/h/env" \
         REQ_SINK="$T/req.log" BODY_DIR="$T" HARNESS_SECRET=FleetSecretValue999 \
         JOBS_URL=https://jobs.invalid JOB_ID=build-project-3-TK-77-1 TRANSCRIPT_SOURCE=plan_md
  bash "$T/noscrub/transcript-push.sh" plan pipeline "" "$T/b/plan.md" >/dev/null 2>&1 )
RC=$?
[ "$RC" = 0 ] && ok || bad "a missing scrubber made the artifact push exit $RC instead of 0"
[ "$(bodies)" = 0 ] && ok || bad "an artifact was pushed with NO SCRUBBER PRESENT"
grep -q 'REFUSING to push' "$T/h/logs/transcripts.log" \
  && ok || bad "the refusal was silent: $(cat "$T/h/logs/transcripts.log" 2>/dev/null)"

# ══ 5. THE NEGATIVES ════════════════════════════════════════════════════════
RC=$(push TRANSCRIPT_SOURCE=evil -- plan pipeline "" "$T/b/plan.md")
[ "$RC" = 0 ] && ok || bad "an unknown TRANSCRIPT_SOURCE made the push exit $RC instead of 0"
[ "$(bodies)" = 0 ] && ok || bad "an unallowlisted source reached the ledger: $(jq -r '.source' "$B" 2>/dev/null)"

: > "$T/b/empty.md"
RC=$(push TRANSCRIPT_SOURCE=plan_md -- plan pipeline "" "$T/b/empty.md")
[ "$RC" = 0 ] && ok || bad "an empty artifact made the push exit $RC"
[ "$(bodies)" = 0 ] && ok || bad "an EMPTY artifact was pushed — the box would stage a 0-byte plan.md"

RC=$(push TRANSCRIPT_SOURCE=plan_md -- plan pipeline "" "$T/b/nonexistent.md")
[ "$RC" = 0 ] && ok || bad "a missing artifact made the push exit $RC"
[ "$(bodies)" = 0 ] && ok || bad "a MISSING artifact was pushed"

# No job, no push: the same contract every other path here keeps.
rm -f "$T/req.log" "$T"/tbody*.json
( export PATH="$T/fakebin:$PATH" HARNESS="$T/h" HARNESS_ENV_DIR="$T/h/env" \
         REQ_SINK="$T/req.log" BODY_DIR="$T" HARNESS_SECRET=FleetSecretValue999 \
         JOBS_URL=https://jobs.invalid TRANSCRIPT_SOURCE=plan_md
  # A build that runs this suite has its OWN JOB_ID exported; inheriting it
  # would make this case push to a real job and pass for the wrong reason.
  unset JOB_ID
  bash "$T/h/bin/transcript-push.sh" plan pipeline "" "$T/b/plan.md" >/dev/null 2>&1 )
[ "$?" = 0 ] && [ "$(bodies)" = 0 ] \
  && ok || bad "an unclaimed lane pushed an artifact anyway: $(cat "$T/req.log" 2>/dev/null)"

# ══ 6. REGRESSION PIN: with the override unset, nothing changed ═════════════
# bin/agent-call.sh is the only production caller and it never sets the override.
printf 'the stage said this\n' > "$T/b/out.txt"
RC=$(push JOB_PHASE_ID=77 -- execute claude some-model "$T/b/out.txt" 2)
if [ "$(bodies)" = 1 ]; then
  [ "$(jq -r '.source' "$B")" = stage_output ] && ok || bad "a plain push changed its source: $(jq -r '.source' "$B")"
  [ "$(jq -r '.attempt' "$B")" = 2 ] && ok || bad "a plain push lost its attempt number: $(jq -r '.attempt' "$B")"
  [ "$(jq -r '.phase_id' "$B")" = 77 ] && ok || bad "a plain push lost its phase id: $(jq -r '.phase_id' "$B")"
  jq -r '.body' "$B" | head -1 | grep -q '── transcript · execute · attempt 2' \
    && ok || bad "a plain push lost its provenance header: $(jq -r '.body' "$B" | head -1)"
else
  bad "the regression push did not happen"; bad "skipped"; bad "skipped"; bad "skipped"
fi

echo "transcript-push-artifact.bh-531-test: $PASS pass, $FAIL fail"
[ "$FAIL" -eq 0 ]
