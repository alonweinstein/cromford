#!/bin/bash
# bin/orc-context.sh — the orchestrator's vendor-neutral conversation memory.
#
# Why this exists (the operator, 2026-08-14): the Telegram lane can be answered by
# Claude (rungs 1-2), codex or grok (rungs 3-4). Only Claude has `-c`, so the
# other vendors used to answer with no history at all. Worse, a survival-lane
# turn NEVER lands in the Claude transcript — so during a long Claude outage the
# Claude-side history freezes and the only record of what was actually said is
# this log. That makes it the source of truth for continuity, not a convenience.
#
# Deterministic on purpose: plain append, no model call, so it cannot fail for
# want of credits — the exact property the survival ladder is built on.
#
# Parallel turns (BH-5336) append at the same time. Each record is built in a
# temp file first, then appended and trimmed under one short flock on
# <log>.lock, so two records never interleave and a trim never drops an append.
# render takes no lock: it reads whole records only.
#
# usage:
#   orc-context.sh append <lane> <msg-file> <reply-file>   record one turn
#   orc-context.sh render [turns]                          plain-text recent history
set -uo pipefail
ORC=/root/orchestrator
LOG="${ORC_CONTEXT_LOG:-$ORC/conversation-log.md}"
MAX_BYTES="${ORC_CONTEXT_MAX_BYTES:-400000}"   # rolling cap, oldest turns drop
RENDER_TURNS="${ORC_CONTEXT_TURNS:-12}"
MSG_CAP="${ORC_CONTEXT_MSG_CAP:-1200}"         # per-message char cap in render
REPLY_CAP="${ORC_CONTEXT_REPLY_CAP:-1800}"

case "${1:-}" in
  append)
    LANE="${2:?lane}"; MSGF="${3:?msg file}"; REPF="${4:?reply file}"
    [ -f "$MSGF" ] && [ -f "$REPF" ] || exit 0
    touch "$LOG"; chmod 600 "$LOG" 2>/dev/null
    REC=$(mktemp) || exit 1
    {
      printf '\n### %s · %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$LANE"
      printf 'OPERATOR: '; cat "$MSGF"
      printf '\nREPLY: '; cat "$REPF"
      printf '\n'
    } > "$REC"
    (
      # A lock that cannot be had in 60 s still appends: a record is never dropped.
      flock -w 60 9 || true
      cat "$REC" >> "$LOG"
      # Trim from the FRONT on whole-record boundaries so the file never grows
      # without bound and never ends up starting mid-turn.
      SZ=$(stat -c %s "$LOG" 2>/dev/null || echo 0)
      if [ "$SZ" -gt "$MAX_BYTES" ]; then
        TMP=$(mktemp)
        # keep the tail, then drop everything before the first full record header
        tail -c "$MAX_BYTES" "$LOG" | awk 'f{print} /^### /{if(!f){f=1;print}}' > "$TMP"
        [ -s "$TMP" ] && { cat "$TMP" > "$LOG"; chmod 600 "$LOG"; }
        rm -f "$TMP"
      fi
    ) 9>"$LOG.lock"
    rm -f "$REC"
    ;;
  render)
    N="${2:-$RENDER_TURNS}"
    [ -s "$LOG" ] || { echo "(no recorded conversation history yet)"; exit 0; }
    awk -v n="$N" -v mc="$MSG_CAP" -v rc="$REPLY_CAP" '
      /^### /{ nrec++ }
      { rec[nrec] = rec[nrec] $0 "\n" }
      END{
        start = (nrec > n) ? nrec - n + 1 : 1
        for (i = start; i <= nrec; i++) {
          # cap each half independently so one huge reply cannot crowd out the
          # rest of the history
          body = rec[i]
          li = index(body, "\nOPERATOR: "); ri = index(body, "\nREPLY: ")
          if (li && ri && ri > li) {
            head = substr(body, 1, li)
            msg  = substr(body, li + 7, ri - li - 7)
            rep  = substr(body, ri + 8)
            if (length(msg) > mc) msg = substr(msg, 1, mc) "\n[...truncated]"
            if (length(rep) > rc) rep = substr(rep, 1, rc) "\n[...truncated]"
            printf "%sOPERATOR: %s\nREPLY: %s\n", head, msg, rep
          } else print body
        }
      }' "$LOG"
    ;;
  *)
    echo "usage: orc-context.sh append <lane> <msg-file> <reply-file> | render [turns]" >&2
    exit 2 ;;
esac
