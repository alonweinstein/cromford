#!/bin/bash
# bin/board-fetch.sh <url> [--full] [--last N] — fetch a board ticket with its
# comment thread TRIMMED before the model ever sees it.
#
# WHY. Hub triage measured ~480K input tokens per call against a composed
# prompt of ~17KB. The gap is the agent's own reads during the run — and the
# biggest single read is a changed ticket's full record, comment history and
# all. project-1 has 247 tickets with long threads. medic, which fetches almost
# nothing, runs at 30K/call: that is what triage should cost.
#
# Trimming at FETCH time is the point. A cap on the composed prompt does
# nothing here, because these bytes enter the context as tool results, and once
# in they ride every remaining call of the turn.
#
# WHAT IS KEPT, and why this is not blind truncation:
#   * every decision field (status, waitingOn, triageVerdict, turn, title)
#   * the FIRST comment — the client's original ask, which the decision table
#     needs to judge whether a mechanism was ever confirmed
#   * the LAST N comments (default 10) — the recent exchange, which is where
#     "client answered, turn flipped back" lives
#   * an explicit note saying how many were omitted and how to get them
#
# The standing rule is "read the whole thread before deciding" (project-2
# #25: a ticket looked obvious, triage had asked an unanswered question, and
# the build went ahead on an unconfirmed mechanism). That rule is about not
# deciding from the title — it is satisfied by first+last+a visible omission
# count, and NOT satisfied by a silent trim. Hence the note: a thread that was
# cut says so, so the agent can re-fetch whole when the decision turns on the
# middle.
#
# FAIL OPEN, ALWAYS. Board APIs differ per project (some return the ticket at
# the top level, some under .ticket, comment arrays are named differently). If
# this cannot find a comment array it recognises, it prints the payload
# UNCHANGED. An unrecognised shape must cost tokens, never lose a client's
# answer — the expensive failure is recoverable and the silent one is not.
set -uo pipefail
URL="${1:?url}"; shift || true
TMPBODY=$(mktemp); trap 'rm -f "$TMPBODY"' EXIT
FULL=0; LAST="${BOARD_FETCH_LAST:-10}"; SINCE=""
while [ $# -gt 0 ]; do
  case "$1" in
    --full) FULL=1 ;;
    --last) shift; LAST="${1:-10}" ;;
    # --since-file <path>: every comment newer than this file's MTIME survives
    # whole, on top of first + last N. The path is the consumed-fingerprint
    # file, so "newer than the last consumed tick" IS the changed-comment set.
    --since-file) shift; [ -n "${1:-}" ] && [ -e "$1" ] && SINCE=$(date -u -r "$1" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || true) ;;
  esac
  shift || true
done

# AN HTTP FAILURE IS NOT A SHAPE PROBLEM, and conflating them is the trap this
# helper could otherwise walk into. Fail-open is correct for an unrecognised
# JSON shape: pass it through, cost tokens, lose nothing. It is WRONG for a 401
# or a 500 — that body is an error page, and handing it to the agent as though
# it were a ticket means the agent judges a client's request from an error
# message. It would look like a working fetch of an empty thread.
#
# So the status code is checked, and a refusal says so in words the agent will
# not mistake for data.
HTTP=$(curl -sS -m 60 -o "$TMPBODY" -w '%{http_code}' \
  -H "Authorization: Bearer ${INTERNAL_TOKEN:-${HARNESS_SECRET:-}}" \
  -H "User-Agent: curl/8" "$URL" 2>/dev/null) || HTTP=000
RAW=$(cat "$TMPBODY" 2>/dev/null)
rm -f "$TMPBODY"
case "$HTTP" in
  2*) : ;;
  *) printf 'BOARD-FETCH FAILED: HTTP %s for %s — this is NOT a ticket. Do not judge anything from it; retry or fetch directly, and if it is a 401 the token in INTERNAL_TOKEN is wrong for this board.\n' "$HTTP" "$URL"
     exit 0 ;;
esac
[ -n "$RAW" ] || exit 0
[ "$FULL" = 1 ] && { printf '%s' "$RAW"; exit 0; }

# INSTRUMENT THE CHANGE ITSELF. Without this, a fall in grok input cannot be
# attributed to the trim rather than to the two other commits in the same
# window that move the same number — and a fall that does NOT happen cannot be
# told apart from "the agent used a bare curl and never called this at all".
# One line makes "did the lane obey" a grep instead of an inference.
_bf_log() {
  printf '%s board-fetch %s http=%s in=%s out=%s omitted=%s since=%s\n' \
    "$(date -u +%FT%TZ)" "$URL" "${HTTP:-?}" "${1:-0}" "${2:-0}" "${3:-0}" "${SINCE:-none}" \
    >> "${HARNESS:-/root/harness}/logs/agent-rules.log" 2>/dev/null || true
}

OUT_JSON=$(printf '%s' "$RAW" | jq --argjson n "$LAST" --arg since "$SINCE" '
  # GUARD THE WHOLE PROGRAM ON type=="object" FIRST. `.comments?` against a
  # top-level ARRAY does not error into the fallback — `?` SUPPRESSES, so jq
  # emits an empty stream, exits 0, and the caller receives NOTHING. Fail-open
  # never fires because nothing failed. A bare top-level array is a real board
  # response shape, so this is the one input that could silently return an
  # empty ticket instead of a whole one.
  if type != "object" then . else
  # Locate the comment array wherever this project keeps it. Anything not
  # matched here falls through to the identity branch below untouched.
  # KEEP THE WHOLE COMMENT, drop only the known-heavy fields. The previous
  # version REBUILT each comment as {author,createdAt,body}, which silently
  # discarded everything else — and the verified shapes make that concrete:
  # `author` is an OBJECT {userId,name}, not a string, and comments also carry
  # `mentions[]` and `isInternal`. isInternal bears directly on the
  # early-engagement question ("did the CLIENT answer, or was that our own
  # note?"), so narrowing it away would remove the field the decision turns on.
  #
  # An allowlist rebuild drops whatever nobody thought of; a denylist of heavy
  # fields drops only what was named. Same reasoning as the omission marker:
  # what is removed has to be a decision, not a side effect.
  def trim_one:
    del(.html, .bodyHtml, .renderedBody, .attachments, .reactions, .rawPayload);
  # THE CHANGED SET SURVIVES STRUCTURALLY, not by the agent noticing a marker.
  #
  # last-N satisfied "a client answer always arrives whole" only because a new
  # answer is usually the newest comment. If more than N land between ticks then the
  # OLDEST of the NEW ones is trimmed, and the guarantee then rests on the agent
  # reading _omitted and choosing --full. That is not hypothetical: TK-88 posted
  # 213 comments in 5.5 hours, about 6 per tick.
  #
  # So anything newer than the last consumed tick is kept regardless of N. The
  # omission window respects the fingerprint, which is what the standing constraint
  # actually requires: the changed content is never trimmed, by construction.
  def is_new: ($since != "") and ((.createdAt // .created_at // "") >= $since);
  def trim_list($c):
    if ($c | length) <= ($n + 1) then $c
    elif ([ $c[] | select(is_new) ] | length) > 0 then
      # first + everything new + enough recent context to read them against
      ( [ $c[0] ]
        + [ { _omitted: (($c | length) - (([ $c[] | select(is_new) ] | length) + 1)),
              _note: "earlier comments omitted — re-fetch with --full if the decision turns on them",
              _narrowed: "kept comments have html/bodyHtml/renderedBody/attachments/reactions/rawPayload removed; all other fields (author object, mentions, isInternal) are intact",
              _window: "every comment newer than the last consumed tick is present in full" } ]
        + [ $c[] | select(is_new) ] )
    else [ $c[0] ]
         + [ { _omitted: (($c | length) - $n - 1),
               _note: "earlier comments omitted — re-fetch this ticket with --full if the decision turns on them",
               _narrowed: "kept comments have html/bodyHtml/renderedBody/attachments/reactions/rawPayload removed; all other fields (author object, mentions, isInternal) are intact" } ]
         + ($c[-$n:])
    end;
  def rebuild($c): trim_list($c) | map(if has("_omitted") then . else trim_one end);

  if (.comments? | type) == "array" then .comments = rebuild(.comments)
  elif (.ticket?.comments? | type) == "array" then .ticket.comments = rebuild(.ticket.comments)
  elif (.data?.comments? | type) == "array" then .data.comments = rebuild(.data.comments)
  else .          # unrecognised shape: hand back everything, cost be damned
  end
  end
' 2>/dev/null) || OUT_JSON=""
[ -n "$OUT_JSON" ] || OUT_JSON="$RAW"
_bf_log "$(printf '%s' "$RAW" | wc -c | tr -d ' ')" \
        "$(printf '%s' "$OUT_JSON" | wc -c | tr -d ' ')" \
        "$(printf '%s' "$OUT_JSON" | jq -r '[.. | objects | select(has("_omitted")) | ._omitted] | first // 0' 2>/dev/null || echo 0)"
printf '%s' "$OUT_JSON"
