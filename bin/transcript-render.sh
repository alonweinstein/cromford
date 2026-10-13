#!/bin/bash
# transcript-render.sh <session.jsonl> — a claude session log, rendered to text
# a person can read.
#
# THE CONSOLE NEVER PARSES RAW JSONL. That is the rule this script exists to
# keep. A session file is an append-only stream of a dozen record types, half of
# them internal bookkeeping (queue-operation, ai-title, mode, pr-link,
# attachment), and its shape belongs to the CLI, not to us — teaching Mission
# Control to read it would put a browser on the far side of an ocean in the
# business of tracking a format we do not own. So the box renders, once, and the
# database stores prose.
#
# WHAT SURVIVES THE RENDER, and why each choice:
#   * user text and assistant text, in full (clipped only at absurd lengths) —
#     this is the conversation, and it is the whole point.
#   * tool calls as ONE line each: the tool name plus its most telling argument
#     (the command for Bash, the path for Read/Write/Edit). A build session runs
#     hundreds of these; rendering their full inputs would bury the reasoning
#     under its own scaffolding.
#   * tool results as ONE line each, clipped, with errors marked. A file read
#     returns the file; the transcript needs to say that it did, not to repeat it.
#   * thinking blocks as a length marker, not as text. They are the model's
#     scratch space, they are enormous, and they are not what a reader clicking
#     a job is trying to find.
#
# Unparseable lines are DROPPED and COUNTED, and the count is reported on stderr
# so the caller can put it in the header rather than have the loss be silent.
#
# usage: transcript-render.sh <path-to-session.jsonl>   (renders to stdout)
set -uo pipefail

SRC="${1:?usage: transcript-render.sh <session.jsonl>}"
[ -r "$SRC" ] || { echo "transcript-render: cannot read $SRC" >&2; exit 1; }
command -v jq >/dev/null 2>&1 || { echo "transcript-render: jq is not installed" >&2; exit 1; }

TOTAL=$(wc -l < "$SRC" 2>/dev/null | tr -d ' ')
PARSED=$(jq -R 'fromjson? | 1' "$SRC" 2>/dev/null | wc -l | tr -d ' ')
echo "transcript-render: $PARSED of ${TOTAL:-0} lines parsed" >&2

jq -rR '
  # ── helpers ────────────────────────────────────────────────────────────────
  def clip($n): tostring | if (length > $n) then (.[0:$n] + " …[clipped]") else . end;
  def oneline: tostring | gsub("[\r\n]+"; " ⏎ ");
  def at: (.timestamp // "") | if (type == "string" and length >= 19) then .[11:19] else "--:--:--" end;

  # The single most telling argument of a tool call. Ordered by how much it
  # tells a reader: a shell command IS the action, a path is the object, and
  # the compact-JSON fallback is there so an unknown tool still renders
  # something rather than a bare name.
  def toolarg:
    (.input // {}) as $i
    | if   ($i | type) != "object"          then ($i | oneline | clip(200))
      elif ($i.command? // null) != null     then ($i.command | oneline | clip(220))
      elif ($i.file_path? // null) != null   then ($i.file_path | oneline | clip(180))
      elif ($i.path? // null) != null        then ($i.path | oneline | clip(180))
      elif ($i.pattern? // null) != null     then ($i.pattern | oneline | clip(180))
      elif ($i.query? // null) != null       then ($i.query | oneline | clip(180))
      elif ($i.url? // null) != null         then ($i.url | oneline | clip(180))
      elif ($i.description? // null) != null then ($i.description | oneline | clip(180))
      elif ($i.prompt? // null) != null      then ($i.prompt | oneline | clip(180))
      else ($i | tojson | clip(200)) end;

  def resulttext:
    (.content // "")
    | if type == "string" then .
      elif type == "array" then ([ .[]? | if type == "object" then (.text // .content // (.type // "")) else tostring end ] | join(" "))
      else tojson end;

  # ── records ────────────────────────────────────────────────────────────────
  # Everything not named here (queue-operation, ai-title, mode, pr-link,
  # last-prompt, attachment) is CLI bookkeeping and is dropped on purpose.
  fromjson? // empty
  | . as $e
  | ($e.message // {}) as $m
  | ($m.content // null) as $c
  | if $e.type == "user" then
      ( if ($c | type) == "string" then
          "\n[" + ($e | at) + "] USER\n" + ($c | clip(8000))
        elif ($c | type) == "array" then
          ( [ $c[]?
              | if .type == "tool_result" then
                  "  ← " + (if (.is_error // false) then "ERROR: " else "" end) + (resulttext | oneline | clip(300))
                elif .type == "text" then
                  "\n[" + ($e | at) + "] USER\n" + (.text | clip(8000))
                else empty end ] | join("\n") )
        else empty end )
    elif $e.type == "assistant" then
      ( ( [ $c[]?
            | if .type == "text" then (.text | clip(12000))
              # The CLI does not persist thinking text in every session (the
              # block lands with an empty string and only its signature), so the
              # length is stated only when there IS one. "[thinking, 0 chars]"
              # on every turn reads like a bug in this renderer rather than like
              # a choice the CLI made.
              elif .type == "thinking" then
                (((.thinking // "") | length) as $n
                 | if $n > 0 then "  · [thinking, " + ($n | tostring) + " chars]" else "  · [thinking]" end)
              elif .type == "tool_use" then "  → " + (.name // "tool") + ": " + toolarg
              else "  · [" + (.type // "?") + "]" end ] | join("\n") ) as $rendered
        | if ($rendered | length) == 0 then empty
          else "\n[" + ($e | at) + "] ASSISTANT"
               + (if (($m.model // "") | length) > 0 then " (" + $m.model + ")" else "" end)
               + "\n" + $rendered
          end )
    elif $e.type == "system" then
      "\n[" + ($e | at) + "] SYSTEM  " + (($e.content // $e.subtype // "") | oneline | clip(400))
    else empty end
  | select(length > 0)
' "$SRC" 2>/dev/null
