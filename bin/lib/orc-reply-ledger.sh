#!/bin/bash
# bin/lib/orc-reply-ledger.sh — the orchestrator's reply ledger (BH-4995.0).
# Sourced by bin/orchestrate.sh, never executed. Only defines functions and
# defaults, so sourcing it has no side effects.
#
# Every orchestrator turn that carries a console command id (CMD_ID, from the
# .meta sidecar) ends with exactly one chat_reply beat keyed rkey chat:<id>,
# posted with BEAT_STRICT=1 and retried, whatever the transport. A turn with no
# command id (cron, ALERT-driven, hand-run) gets nothing from this file.
#
#   ledger_payload <text> [error]  the chat_reply JSON; the text goes to jq on stdin
#   ledger_post <payload>          strict beat, TRIES attempts; rc 0 = it landed
#   ledger_reply <text> [error]    drain, then payload + post; rc 1 after a spool
#                                  write and one ALERTS line
#   ledger_drain                   re-post the spool: oldest first, 20 a call, stop at a failure
#   cmd_status <result>            acks the command row (fail-open, silent)
#
# Console outage (BH-4995.2): a reply whose beat fails every try is written to
# $REPLY_SPOOL/<id>.json (id folded to [A-Za-z0-9_-], relay keys dropped so a
# late re-post never sends a second Telegram copy) and named in ONE ALERTS line.
# RELAY=1 spools without the line, because the relay branch writes its own. The
# next ledger_reply that has a command id drains the spool first: one strict
# try per file, the file removed when it lands, never alerting, and the drain
# stops at the first failed try so an outage costs a turn one beat, not 20 (it
# runs inside the turn); a file that is not a chat_reply with
# a command_id is renamed <f>.bad and never posted.
# A text over ORC_REPLY_LEDGER_MAX_CHARS is cut at MAX-120 characters inside
# jq (never a split UTF-8 sequence, never the full text on an argv) and ends
# with a cut marker naming last-reply.txt. The text is read with --rawfile,
# not -Rs: jq 1.7's -R turns a character that straddles a 4096-byte read into
# U+FFFD, so any non-ASCII reply over 4 KB was corrupted.
#
# Knobs (catalog/lanes.d/orc-monitor.json), read through bin/lib/lane-gate.sh's
# lane_knob orc-monitor (settings row lane.orc-monitor.<env>, then the env,
# then the registry default); a garbage value is the default below:
#   ORC_REPLY_LEDGER_TRIES 1..10 (3), ORC_REPLY_LEDGER_BACKOFF_S 0..30 (2),
#   ORC_REPLY_LEDGER_MAX_CHARS 1000..14000 (14000), ORC_CMD_STATUS 0..1 (1).
# Tests: tests/orchestrate-reply-ledger.bh-4995-test.sh,
# tests/orchestrate-reply-spool.bh-4995-test.sh.
ORC="${ORC:-/root/orchestrator}"
CMD_ID="${CMD_ID:-}"
RELAY="${RELAY:-0}"
ORIGIN="${ORIGIN:-}"
META_TRANSPORT="${META_TRANSPORT:-telegram}"
_LEDGER_DONE="${_LEDGER_DONE:-0}"
REPLY_SPOOL="${ORC}/state/chat-reply-spool"

_orl_int() { # _orl_int <value> <min> <max> <default> — the value if it is an int in range, else the default
  local v="${1:-}"
  case "$v" in ''|*[!0-9]*) printf '%s\n' "$4"; return 0 ;; esac
  [ "${#v}" -le 9 ] || { printf '%s\n' "$4"; return 0; }
  if (( 10#$v >= $2 && 10#$v <= $3 )); then printf '%s\n' "$((10#$v))"; else printf '%s\n' "$4"; fi
}

_orl_knob() { # _orl_knob <ENV> <min> <max> <default> — the knob through lane_knob, else the env
  local f h="${HARNESS:-${H:-}}"
  if ! command -v lane_knob >/dev/null 2>&1; then
    for f in "$(dirname "${BASH_SOURCE[0]}")/lane-gate.sh" ${h:+"$h/bin/lib/lane-gate.sh"}; do
      # shellcheck source=bin/lib/lane-gate.sh
      [ -r "$f" ] && { . "$f"; break; }
    done
  fi
  if command -v lane_knob >/dev/null 2>&1; then
    _orl_int "$(lane_knob orc-monitor "$1" 2>/dev/null)" "$2" "$3" "$4"
  else
    _orl_int "${!1:-}" "$2" "$3" "$4"
  fi
}

ledger_payload() { # ledger_payload <text> [error]
  local max
  max=$(_orl_knob ORC_REPLY_LEDGER_MAX_CHARS 1000 14000 14000)
  printf '%s' "$1" | jq -nc --rawfile raw /dev/stdin --argjson max "$max" --arg id "$CMD_ID" --arg o "${ORIGIN:-$META_TRANSPORT}" \
    --arg tr "$META_TRANSPORT" --arg ts "$(date -u '+%Y-%m-%d %H:%M:%SZ')" --arg relay "$RELAY" \
    --arg c "${META_CHAT:-}" --arg th "${META_THREAD:-}" --arg e "${2:-}" \
    '($raw | if length > $max then .[0:$max-120] + "\n\n[reply cut at \($max-120) chars here; the full text went to Telegram and is in last-reply.txt]" else . end) as $t
     | {kind:"chat_reply",rkey:("chat:"+$id),command_id:$id,project:"orchestrator",text:$t,ts:$ts,origin:$o,transport:$tr}
     + (if $relay == "1" then {relay:true,chat_id:$c} + (if $th == "" then {} else {thread_id:$th} end) else {} end)
     + (if $e == "" then {} else {error:$e} end)'
}

ledger_post() { # ledger_post <payload> — rc 0 on the first try the console takes, 1 when none does
  local h="${HARNESS:-${H:-}}" tries backoff i=1
  [ -n "$h" ] && [ -n "${1:-}" ] || return 1
  tries=$(_orl_knob ORC_REPLY_LEDGER_TRIES 1 10 3)
  backoff=$(_orl_knob ORC_REPLY_LEDGER_BACKOFF_S 0 30 2)
  while :; do
    BEAT_STRICT=1 "$h/bin/beat.sh" "$1" >/dev/null 2>&1 && return 0
    [ "$i" -lt "$tries" ] || return 1
    i=$((i + 1))
    [ "$backoff" -gt 0 ] && sleep "$backoff"
  done
}

_orl_spool() { # _orl_spool <payload> — $REPLY_SPOOL/<id>.json via tmp + mv; prints the path, rc 1 (nothing printed) on any failure
  local id="${CMD_ID//[^A-Za-z0-9_-]/_}" tmp
  [ -n "${1:-}" ] || return 1
  tmp="$REPLY_SPOOL/.$id.tmp.$$"
  mkdir -p "$REPLY_SPOOL" 2>/dev/null || return 1
  if { printf '%s\n' "$1" | jq -c 'del(.relay,.chat_id,.thread_id)' > "$tmp" && mv -f "$tmp" "$REPLY_SPOOL/$id.json"; } 2>/dev/null; then
    printf '%s\n' "$REPLY_SPOOL/$id.json"; return 0
  fi
  rm -f "$tmp"; return 1
}

ledger_drain() { # ledger_drain — one strict try per spooled reply, oldest first, 20 a call, stops at the first failed try; never alerts, rc 0
  local h="${HARNESS:-${H:-}}" f
  [ -n "$h" ] && [ -d "$REPLY_SPOOL" ] || return 0
  set -- "$REPLY_SPOOL"/*.json
  [ -e "$1" ] || return 0
  while IFS= read -r f; do
    if jq -e '.kind == "chat_reply" and (.command_id | type == "string" and length > 0)' "$f" >/dev/null 2>&1; then
      # Stop at the first failure: the console is still down, and every further
      # 15 s try would sit inside the turn. The rest wait.
      BEAT_STRICT=1 "$h/bin/beat.sh" "$(cat "$f")" >/dev/null 2>&1 || break
      rm -f "$f"
    else
      mv -f "$f" "$f.bad" 2>/dev/null
    fi
  done < <(ls -1tr -- "$@" 2>/dev/null | head -n 20)
  return 0
}

ledger_reply() { # ledger_reply <text> [error] — no command id: rc 0, nothing drained or posted
  local h="${HARNESS:-${H:-}}" payload sp tries
  [ -n "$CMD_ID" ] || return 0
  _LEDGER_DONE=1
  ledger_drain
  payload=$(ledger_payload "$1" "${2:-}")
  ledger_post "$payload" && return 0
  sp=$(_orl_spool "$payload")
  # RELAY=1: the relay branch of deliver_reply writes its own line.
  [ -n "$h" ] && [ "$RELAY" != 1 ] || return 1
  tries=$(_orl_knob ORC_REPLY_LEDGER_TRIES 1 10 3)
  if [ -n "$sp" ]; then
    HARNESS="$h" "$h/bin/alert-line.sh" "[orchestrator] chat_reply for command $CMD_ID did not reach the console after $tries tries — spooled at $sp, next turn retries it"
  else
    HARNESS="$h" "$h/bin/alert-line.sh" "[orchestrator] chat_reply for command $CMD_ID did not reach the console after $tries tries and could not be spooled — the reply is in $ORC/last-reply.txt"
  fi
  return 1
}

cmd_status() { # cmd_status <result> — ack the console command row; never fails, never alerts
  [ -n "$CMD_ID" ] && [ -n "${CONSOLE_URL:-}" ] && [ -n "${HARNESS_SECRET:-}" ] || return 0
  [ "$(_orl_knob ORC_CMD_STATUS 0 1 1)" = 1 ] || return 0
  jq -nc --arg r "$1" '{ok:true,result:$r}' | curl -s --max-time 10 -o /dev/null -X POST \
    -H 'Content-Type: application/json' -H "Authorization: Bearer $HARNESS_SECRET" \
    --data-binary @- "$CONSOLE_URL/api/commands/$CMD_ID/ack" || true
  return 0
}
