#!/bin/bash
# transcript-push.sh — resolve one attempt's conversation, render it, scrub it,
# and push it to the harness-jobs ledger so Mission Control can show it.
#
# usage: transcript-push.sh <stage> <runner> <model> <outfile> [attempt]
#   <outfile> is bin/agent-call.sh's $OUT: the stage's captured text output.
#   The claude lane also leaves $OUT.json beside it, which carries session_id.
# Reads the ambient JOB_ID / JOB_PHASE_ID that bin/run-build.sh and
# bin/agent-call.sh already export. No JOB_ID means the lane is not enrolled in
# the coordination DB, and this exits 0 having done nothing.
#
# ── THE ARTIFACT OVERRIDE, TRANSCRIPT_SOURCE (BH-531) ────────────────────────
#   TRANSCRIPT_SOURCE=plan_md|review_md|decompose_run|lead_report
#     pushes <outfile> ITSELF as the body, with no session lookup and no
#     provenance header, on a reserved slot (no phase, attempt 100). This is how
#     a build that ended PLAN_BLOCKED / REVIEW_BLOCKED / DECOMPOSE_FAILED gets
#     the file its RESULT line names off the machine before the machine dies:
#     the owning box fetches it back and writes it beside the staged RESULT, so
#     the body has to be the file and nothing but the file.
#     The cap and the scrub are the same ones a session gets, deliberately.
#     lead_report is the whole lead review report: bin/lead-review.sh pushes it
#     when lr_detail cut the report at the worker's 4000-unit artifact cap, so
#     the hub can read it with `jobs-client.sh transcript-get <job> source=lead_report`.
#     bin/agent-call.sh never sets it, and with it unset every line below
#     behaves exactly as it always has.
#
# ── THIS SCRIPT ALWAYS EXITS 0 ───────────────────────────────────────────────
# It is a side channel on a stage that has already done its work. A transcript
# that fails to render, fails to scrub, fails to push or fails for a reason
# nobody anticipated must cost the build EXACTLY NOTHING — one line in
# logs/transcripts.log, and the stage's own rc reaches its caller untouched.
# Every step below is guarded and the final line is a bare `exit 0` on purpose.
#
# ── SOURCE PREFERENCE, and the honest gap ────────────────────────────────────
#   1. The claude session jsonl, when it is resolvable. This is the real thing:
#      every turn, every tool call, in order.
#   2. Otherwise the stage's captured output ($OUT) — the model's final answer
#      and nothing else. Recorded as source=stage_output so the console can say
#      which one a reader is looking at rather than implying a full session.
# codex / grok / gemini / openrouter / fireworks keep their own session ledgers
# in their own formats; this script does not pretend to read them, and a stage
# those lanes served lands as stage_output. That is a real gap, stated here
# rather than papered over.
set -uo pipefail

STAGE="${1:-}"; RUNNER="${2:-}"; MODEL="${3:-}"; OUT="${4:-}"; ATTEMPT="${5:-1}"
HARNESS="${HARNESS:-/root/harness}"
LOG="$HARNESS/logs/transcripts.log"
# Same number as TRANSCRIPT_MAX_BYTES in worker/jobs/src/index.js. Stated in two
# places because the box must not ship what the worker would only tail anyway,
# and the worker must not trust that every box in the fleet is running this
# version of bin/.
MAX_BYTES="${TRANSCRIPT_MAX_BYTES:-150000}"

_log() {
  mkdir -p "$HARNESS/logs" 2>/dev/null
  echo "$(date -u '+%Y-%m-%d %H:%M:%SZ') [transcript] ${STAGE:-?}/${RUNNER:-?} job=${JOB_ID:-none} phase=${JOB_PHASE_ID:-none} attempt=$ATTEMPT $*" \
    >> "$LOG" 2>/dev/null
  return 0
}

[ -n "${JOB_ID:-}" ] || exit 0            # lane not enrolled — nothing to attach to
case "$ATTEMPT" in ''|*[!0-9]*) ATTEMPT=1 ;; esac

ART_SOURCE="${TRANSCRIPT_SOURCE:-}"
if [ -n "$ART_SOURCE" ]; then
  # ALLOWLISTED, because `source` is a column the console renders a sentence
  # from: a value nobody taught it about reads as "provenance not recorded",
  # which would be a lie about a row whose provenance is exactly known.
  case "$ART_SOURCE" in
    plan_md|review_md|decompose_run|lead_report) ;;
    *) _log "ignored TRANSCRIPT_SOURCE=$ART_SOURCE — not one of plan_md|review_md|decompose_run|lead_report"; exit 0 ;;
  esac
  # THE SLOT IS THIS SCRIPT'S TO CHOOSE, never the caller's. The row's natural
  # key is (job, phase_id, attempt); bin/agent-call.sh numbers real attempts
  # 1..N against a real phase row, so (no phase, attempt 100) is a slot no
  # session can reach. A caller-passed $5 is IGNORED rather than honoured: the
  # one thing an artifact must never do is overwrite the execute transcript a
  # reviewer is about to read.
  ATTEMPT="${TRANSCRIPT_ARTIFACT_ATTEMPT:-100}"
  case "$ATTEMPT" in ''|*[!0-9]*) ATTEMPT=100 ;; esac
  JOB_PHASE_ID=""
fi

BIN=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=/dev/null
[ -r "$BIN/jobs-client.sh" ] && . "$BIN/jobs-client.sh" 2>/dev/null
command -v job_transcript_put >/dev/null 2>&1 || { _log "skipped: jobs-client has no job_transcript_put"; exit 0; }

TMP=$(mktemp -d "${TMPDIR:-/tmp}/tpush.XXXXXX") || exit 0
trap 'rm -rf "$TMP"' EXIT

# ── 1. resolve the source ────────────────────────────────────────────────────
SOURCE=""; RAW="$TMP/raw"; RENDER_NOTE=""
SID=""
if [ -n "$ART_SOURCE" ]; then
  # An artifact has no session to look for: the FILE is the body. An absent or
  # empty one is "nothing on file", never an empty row — the box on the other
  # end writes what it fetches straight to disk, and a 0-byte plan.md staged
  # beside a RESULT that points at it is worse than no file at all.
  if [ -s "${OUT:-/nonexistent}" ]; then
    cp "$OUT" "$RAW" 2>/dev/null || { _log "could not read artifact ${OUT:-unset}"; exit 0; }
    SOURCE="$ART_SOURCE"
  else
    _log "nothing to push (artifact missing or empty: ${OUT:-unset})"
    exit 0
  fi
fi
if [ -z "$SOURCE" ] && [ -s "${OUT:-/nonexistent}.json" ]; then
  SID=$(jq -r '.session_id // empty' "$OUT.json" 2>/dev/null)
fi
if [ -n "$SID" ]; then
  # Sessions live under a slug of the CWD the CLI ran in, and a build can run in
  # a worktree, a pool checkout or the repo itself. Searching by the session id
  # itself is the one lookup that does not have to know which — and -quit stops
  # at the first hit rather than walking every project dir on the box.
  JSONL=$(find "${CLAUDE_PROJECTS_DIR:-$HOME/.claude/projects}" -maxdepth 2 -name "$SID.jsonl" -print -quit 2>/dev/null)
  if [ -n "$JSONL" ] && [ -s "$JSONL" ]; then
    if bash "$BIN/transcript-render.sh" "$JSONL" > "$RAW" 2>"$TMP/render.err" && [ -s "$RAW" ]; then
      SOURCE=session_jsonl
      RENDER_NOTE=$(head -1 "$TMP/render.err" 2>/dev/null)
    else
      _log "render failed for session $SID — falling back to stage output"
    fi
  fi
fi
if [ -z "$SOURCE" ]; then
  if [ -s "${OUT:-/nonexistent}" ]; then
    cp "$OUT" "$RAW" 2>/dev/null || { _log "could not read stage output $OUT"; exit 0; }
    SOURCE=stage_output
  else
    # Nothing to push is NOT an error: a stage that died before the model
    # answered has no conversation, and inventing an empty one would put a row
    # on the job saying "there is a transcript" when there is not.
    _log "nothing to push (no session jsonl, no stage output)"
    exit 0
  fi
fi

# ── 2. cap to the tail ───────────────────────────────────────────────────────
# THE TAIL, not the head: the end of a session is where the verdict, the failure
# and the last thing the model did all live. Cut on a line boundary (`tail -n
# +2` drops the partial first line) so the render does not open mid-word.
# Capping BEFORE the scrub is deliberate — the scrub then runs over exactly the
# bytes that get stored, so "this text was scrubbed" is a statement about the
# row rather than about something larger that was thrown away afterwards.
TRUNCATED=0
BODY="$TMP/body"
if [ "$(wc -c < "$RAW" 2>/dev/null || echo 0)" -gt "$MAX_BYTES" ]; then
  tail -c "$MAX_BYTES" "$RAW" 2>/dev/null | tail -n +2 > "$BODY" || cp "$RAW" "$BODY"
  TRUNCATED=1
else
  cp "$RAW" "$BODY"
fi

# ── 3. scrub ─────────────────────────────────────────────────────────────────
# NON-NEGOTIABLE. If the scrubber is missing or fails, NOTHING is pushed: an
# unscrubbed transcript in a database the console reads is the one failure mode
# that is worse than having no feature at all. This is the single place in this
# script that fails CLOSED, and it does so loudly enough to find in the log.
[ -x "$BIN/transcript-scrub.sh" ] || [ -r "$BIN/transcript-scrub.sh" ] || {
  _log "REFUSING to push: bin/transcript-scrub.sh is missing — an unscrubbed transcript is never pushed"; exit 0; }
CLEAN="$TMP/clean"
if ! TRANSCRIPT_SCRUB_COUNT_FILE="$TMP/count" bash "$BIN/transcript-scrub.sh" < "$BODY" > "$CLEAN" 2>/dev/null || [ ! -s "$CLEAN" ]; then
  _log "REFUSING to push: the scrubber failed — an unscrubbed transcript is never pushed"
  exit 0
fi
REDACTIONS=$(cat "$TMP/count" 2>/dev/null || echo 0)
case "$REDACTIONS" in ''|*[!0-9]*) REDACTIONS=0 ;; esac

# ── 4. header ────────────────────────────────────────────────────────────────
# Prepended AFTER the cap so it cannot be the thing that gets cut, and it states
# the provenance in the transcript itself — a reader who copies the text out of
# the console still knows what they are holding.
#
# AN ARTIFACT GETS NO HEADER. The owning box writes this body back to disk under
# the file name the RESULT line points at, and a session quotes that file to a
# client. Five lines of provenance the planner never wrote would be quoted with
# it. The row's own `source` and `truncated` columns carry the provenance, which
# is where a reader who needs it is already looking.
FINAL="$TMP/final"
if [ -n "$ART_SOURCE" ]; then
  cp "$CLEAN" "$FINAL" 2>/dev/null || { _log "could not stage the artifact body for push"; exit 0; }
else
{
  echo "── transcript · ${STAGE:-?} · attempt $ATTEMPT ──"
  echo "runner: ${RUNNER:-?}   model: ${MODEL:-?}   source: $SOURCE"
  [ -n "$SID" ] && [ "$SOURCE" = session_jsonl ] && echo "session: $SID"
  [ -n "$RENDER_NOTE" ] && echo "$RENDER_NOTE"
  [ "$SOURCE" = stage_output ] && echo "NOTE: no claude session file was resolvable for this attempt, so this is the stage's final OUTPUT, not the turn-by-turn session."
  [ "$TRUNCATED" = 1 ] && echo "NOTE: TAIL ONLY — this attempt ran past the ${MAX_BYTES}B cap and the head was dropped."
  echo "redactions: $REDACTIONS (bin/transcript-scrub.sh)"
  echo "────────────────────────────────────────────────"
  cat "$CLEAN"
} > "$FINAL" 2>/dev/null
fi

# ── 5. push, fail-open ───────────────────────────────────────────────────────
if job_transcript_put "$FINAL" "$STAGE" "$RUNNER" "$MODEL" "$SOURCE" "$ATTEMPT" "$TRUNCATED" "$REDACTIONS" "$JOB_ID"; then
  _log "pushed $(wc -c < "$FINAL" | tr -d ' ')B source=$SOURCE truncated=$TRUNCATED redactions=$REDACTIONS"
else
  _log "push failed (http=${JOBS_HTTP:-?}) — the stage is unaffected"
fi
exit 0
