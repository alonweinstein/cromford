#!/bin/bash
# bin/lib/orc-turns.sh — parallel orchestrator turns (BH-5336). Functions only,
# sourced by bin/orchestrate.sh after bin/lib/orc-reply-ledger.sh; no side
# effects at source time.
#
# WHY. orchestrate.sh used to take one blocking flock on $ORC/.turn.lock for the
# whole turn. On 2026-10-07 one 46-minute turn (command 21346) held six messages
# behind it. Now every message gets its own turn, and these functions give the
# turns what the lock used to give them:
#
#   claim      one file per turn in $ORC/state/turns/<key>.json. The key is
#              c<command id> (or d<dedupe key>-<epoch>-<pid> with no id). A
#              second orchestrate.sh for a command that is in flight or already
#              answered exits before any model call (orct_claim rc 3 / rc 4).
#   heartbeat  a background subshell touches the claim while the turn's main
#              pid lives, or while anything else in its process group lives
#              (the claude child of a turn whose bash was SIGKILLed). A claim
#              not touched for ORC_TURN_STALE_S is stale and is reclaimed.
#   gate       up to ORC_TURN_CONCURRENCY turns run at once. A reply inside an
#              in-flight turn's thread waits for that turn; nothing else does.
#              While a turn waits, its command row says queued_behind:<id>.
#   state      each turn edits its own copies of STATE.md and facts.md, and
#              bin/orc-state-merge.py merges them back by section under a short
#              lock. A section another turn changed is never wiped.
#
# Every lock here is short: $ORCT_DIR/.lock around one claim or gate decision,
# $ORC/.state.lock around one merge. None is held across a model call.
#
# Knobs (lane orc-monitor, read through _orl_knob, so the DB settings row wins,
# then the env, then the default here): ORC_TURN_CONCURRENCY (0..32, default 4,
# 0 = sized from MemAvailable / ORC_TURN_WORKER_MEM_MB), ORC_TURN_WORKER_MEM_MB
# (128..16384, default 1024), ORC_TURN_STALE_S (5..3600, default 90).
# ORC_TURN_POLL_S (env only, default 1) is the gate's sleep between passes.

declare -F _orl_knob >/dev/null 2>&1 || {
  # shellcheck source=bin/lib/orc-reply-ledger.sh
  . "$(dirname "${BASH_SOURCE[0]}")/orc-reply-ledger.sh" 2>/dev/null || true
}

_orct_dir() { # the claim directory; rc 1 when ORC is not set
  [ -n "${ORCT_DIR:-}" ] && { printf '%s' "$ORCT_DIR"; return 0; }
  [ -n "${ORC:-}" ] || return 1
  printf '%s' "$ORC/state/turns"
}
_orct_now_ms() { date +%s%3N; }
_orct_stale() { _orl_knob ORC_TURN_STALE_S 5 3600 90; }
_orct_log() { # one line to logs/agent-rules.log, never fails
  local h="${HARNESS:-${H:-}}"
  [ -n "$h" ] || return 0
  echo "$(date -u '+%Y-%m-%d %H:%M:%SZ') [orchestrator] $*" >> "$h/logs/agent-rules.log" 2>/dev/null || true
}

# orct_continuation — rc 0 when -c continuation mode can run (orc_fresh false).
# It continues ONE shared claude conversation, so it can never run twice at once.
orct_continuation() {
  local h="${HARNESS:-${H:-}}"
  [ -n "$h" ] && [ -f "$h/flags/orchestrator-continue" ] && [ ! -f "$h/flags/orchestrator-v2" ]
}

# orct_cap — print the number of turns that may run at once.
orct_cap() { _orct_cap_set; printf '%s' "$ORCT_CAP"; }
# _orct_cap_set — the same, into ORCT_CAP, with the reason (when it is not the
# configured number) in ORCT_CAP_WHY. No subshell, so the caller sees both.
_orct_cap_set() {
  local c mem per
  ORCT_CAP_WHY=""
  if orct_continuation; then
    ORCT_CAP_WHY="flags/orchestrator-continue is active (one shared claude conversation)"
    ORCT_CAP=1; return 0
  fi
  c=$(_orl_knob ORC_TURN_CONCURRENCY 0 32 4)
  if [ "$c" = 0 ]; then
    per=$(_orl_knob ORC_TURN_WORKER_MEM_MB 128 16384 1024)
    mem=$(awk '/^MemAvailable:/ { print int($2 / 1024); exit }' "${ORC_TURN_MEMINFO:-/proc/meminfo}" 2>/dev/null)
    case "$mem" in
      ''|*[!0-9]*) c=32; ORCT_CAP_WHY="no cap configured and MemAvailable unreadable" ;;
      *) c=$(( mem / per )); ORCT_CAP_WHY="no cap configured: ${mem} MB available / ${per} MB a turn" ;;
    esac
    [ "$c" -ge 1 ] || c=1
    [ "$c" -le 32 ] || c=32
  fi
  ORCT_CAP="$c"
}

# orct_key — the claim key for this turn (reads CMD_ID and _DKEY).
orct_key() {
  if [ -n "${CMD_ID:-}" ]; then printf 'c%s' "$CMD_ID"
  else printf 'd%s-%s-%s' "${_DKEY:-x}" "$(date +%s)" "$$"; fi
}

# orct_head <text> — the first non-blank line after a [telegram: …]/[slack: …]
# attribution line, 80 characters max.
orct_head() {
  printf '%s\n' "${1:-}" | awk '
    /^[[:space:]]*$/ { next }
    !seen && /^\[(telegram|slack): / { seen = 1; next }
    { print; exit }' | cut -c1-80
}

# orct_live <claim-file> [stale-s] — rc 0 when the claim was touched inside
# ORC_TURN_STALE_S (or the given seconds).
orct_live() {
  local m now
  m=$(stat -c %Y "$1" 2>/dev/null) || return 1
  now=$(date +%s)
  [ $(( now - m )) -lt "${2:-$(_orct_stale)}" ]
}

# orct_claim <key> <head> <chat> <thread> <msg_id> <msg_ts> <reply_to>
#   rc 0 claimed (state waiting), 3 in flight in another process, 4 already
#   answered, 1 the claim directory is unusable (the caller runs ungated).
orct_claim() {
  local key="$1" d
  d=$(_orct_dir) || return 1
  mkdir -p "$d" 2>/dev/null && [ -w "$d" ] || return 1
  # The claim's own token: orct_release drops a claim only when it is this one.
  ORCT_TOKEN="$$.$(date +%s%N)"
  (
    flock -w 30 9 || exit 1
    [ -e "$d/$key.done" ] && exit 4
    [ -e "$d/$key.json" ] && orct_live "$d/$key.json" && exit 3
    # A claim for this key that is not live is stale: it is taken over here.
    [ -e "$d/$key.json" ] && _orct_log "turn claim $key was stale; reclaimed by pid $$"
    umask 077
    jq -nc --arg key "$key" --arg cmd "${CMD_ID:-}" --argjson pid "$$" \
      --arg pgid "$(ps -o pgid= -p "$$" 2>/dev/null | tr -d ' ')" \
      --argjson at "$(_orct_now_ms)" --arg chat "${3:-}" --arg thread "${4:-}" \
      --arg mid "${5:-}" --arg mts "${6:-}" --arg rto "${7:-}" --arg head "${2:-}" --arg tok "$ORCT_TOKEN" \
      '{key:$key, command_id:$cmd, pid:$pid, pgid:$pgid, token:$tok, state:"waiting", arrived_at:$at,
        chat_id:$chat, thread_id:$thread, message_id:$mid, message_ts:$mts,
        reply_to:$rto, head:$head}' > "$d/$key.json.$$" || exit 1
    mv -f "$d/$key.json.$$" "$d/$key.json" || exit 1
    exit 0
  ) 9>"$d/.lock"
}

# _orct_group_alive <pgid> <heartbeat pid> — rc 0 when a process other than the
# heartbeat and its own children is still in the process group.
_orct_group_alive() {
  ps -eo pid=,ppid=,pgid= 2>/dev/null | awk -v g="$1" -v hb="$2" '
    { pid[NR] = $1; par[$1] = $2; grp[$1] = $3 }
    END {
      for (i = 1; i <= NR; i++) {
        p = pid[i]; if (grp[p] != g) continue
        q = p; mine = 0
        for (n = 0; n < 64 && q != "" && q > 1; n++) { if (q == hb) { mine = 1; break }; q = par[q] }
        if (!mine) { found = 1; exit }
      }
      exit !found
    }'
}

# orct_heartbeat_start <key> — sets ORCT_HB to the heartbeat pid.
orct_heartbeat_start() {
  local key="$1" d me="$$" pg stale iv
  d=$(_orct_dir) || return 1
  stale=$(_orct_stale); iv=$(( stale / 6 )); [ "$iv" -ge 1 ] || iv=1
  pg=$(ps -o pgid= -p "$me" 2>/dev/null | tr -d ' ')
  (
    # Close every inherited fd above 2, so the heartbeat can never pin a lock
    # or a pipe that belongs to the turn.
    for fd in /proc/"$BASHPID"/fd/*; do
      fd="${fd##*/}"
      case "$fd" in ''|*[!0-9]*) continue ;; esac
      [ "$fd" -gt 2 ] && exec {fd}>&-
    done
    while :; do
      sleep "$iv"
      [ -e "$d/$key.json" ] && [ ! -e "$d/$key.done" ] || exit 0
      if kill -0 "$me" 2>/dev/null; then touch "$d/$key.json"; continue; fi
      # The main bash is gone. A setsid spawn leads its own group, so a claude
      # child still running there means the turn is still working.
      if [ "$pg" = "$me" ] && _orct_group_alive "$pg" "$BASHPID"; then touch "$d/$key.json"; continue; fi
      exit 0
    done
  ) </dev/null >/dev/null 2>&1 &
  ORCT_HB=$!
}

# _orct_live_claims <dir> [ro] — the live claim files, one per line. A stale
# claim is renamed <key>.stale and logged once, so it is never counted or
# reported. The rename needs $ORCT_DIR/.lock held (the gate holds it); a caller
# without the lock passes `ro`, and then nothing is renamed: a rename there could
# land between a reclaim's liveness check and its mv, and strip a fresh claim.
_orct_live_claims() {
  local d="$1" ro="${2:-}" f stale
  stale=$(_orct_stale)
  for f in "$d"/*.json; do
    [ -e "$f" ] || continue
    if orct_live "$f" "$stale"; then printf '%s\n' "$f"
    elif [ "$ro" = ro ]; then :
    else
      mv -f "$f" "${f%.json}.stale" 2>/dev/null \
        && _orct_log "turn claim $(basename "${f%.json}") is stale (no heartbeat for ${stale}s); ignored by the gate"
    fi
  done
}

# The gate decision, in jq. Input: the live claims (one array). Output: a
# status string, or "admit".
# shellcheck disable=SC2016
_ORCT_GATE_JQ='
  def before($a; $b): ($a.arrived_at < $b.arrived_at) or ($a.arrived_at == $b.arrived_at and $a.key < $b.key);
  def same_thread($m; $o):
    ($m.chat_id // "") != "" and $m.chat_id == $o.chat_id and (
      (($m.thread_id // "") != "" and $m.thread_id == $o.thread_id
        and ($m.message_ts // "") != "" and $m.message_ts != $m.thread_id)
      or (($m.reply_to // "") != "" and $m.reply_to == $o.message_id));
  def preds($m; $all): [ $all[] | select(.key != $m.key and before(.; $m) and same_thread($m; .)) ];
  . as $all
  | ($all | map(select(.key == $me)) | .[0]) as $m
  | if $m == null then "admit"
    elif $m.state == "running" then "admit"
    else
      preds($m; $all) as $p
      | if ($p | length) > 0 then
          "queued_behind:" + (($p | sort_by(.arrived_at, .key) | last) | (if (.command_id // "") != "" then .command_id else "unknown" end))
        else
          ($all | map(select(.state == "running")) | length) as $run
          | [ $all[] | select(.state == "waiting") | . as $w | select((preds($w; $all) | length) == 0) ]
            | sort_by(.arrived_at, .key) | map(.key) | index($me) as $rank
          | if $run < $cap and $rank != null and $rank < ($cap - $run) then "admit"
            else
              ($all | map(select(.state == "running")) | sort_by(.arrived_at, .key) | .[0]) as $old
              | "queued_behind:" + (if $old != null and ($old.command_id // "") != "" then $old.command_id else "unknown" end)
            end
        end
    end'

# _orct_gate_pass <key> <cap> — one gate decision under the short lock. Prints
# the status; rc 0 admitted (the claim now says running), 1 not admitted.
_orct_gate_pass() {
  local key="$1" cap="$2" d st
  d=$(_orct_dir) || return 0
  (
    flock -w 30 9 || exit 0      # lock trouble: fail open, a message is never held by the gate
    [ -e "$d/$key.json" ] || exit 0
    st=$(_orct_live_claims "$d" | xargs -r -d '\n' jq -s . 2>/dev/null \
      | jq -r --arg me "$key" --argjson cap "$cap" "$_ORCT_GATE_JQ" 2>/dev/null) || st=admit
    [ -n "$st" ] || st=admit
    if [ "$st" = admit ]; then
      jq -c --argjson t "$(_orct_now_ms)" '.state = "running" | .started_at = $t' "$d/$key.json" > "$d/$key.json.$$" 2>/dev/null \
        && mv -f "$d/$key.json.$$" "$d/$key.json"
      exit 0
    fi
    printf '%s' "$st"
    exit 1
  ) 9>"$d/.lock"
}

# orct_gate <key> — wait until this turn is admitted. The first pass runs at
# once; the command row is acked only when the status string changes.
orct_gate() {
  local key="$1" st last="" poll
  poll="${ORC_TURN_POLL_S:-1}"
  case "$poll" in ''|*[!0-9.]*|.|*.*.*) poll=1 ;; esac
  _orct_cap_set
  [ -n "$ORCT_CAP_WHY" ] && _orct_log "turn ${CMD_ID:-$key}: concurrency cap $ORCT_CAP ($ORCT_CAP_WHY)"
  while :; do
    st=$(_orct_gate_pass "$key" "$ORCT_CAP") && return 0
    if [ "$st" != "$last" ]; then
      declare -F cmd_status >/dev/null && cmd_status "$st"
      last="$st"
    fi
    sleep "$poll"
    _orct_cap_set
  done
}

# orct_inflight_render <key> — one line per OTHER live turn, empty when none.
orct_inflight_render() {
  local key="$1" d
  d=$(_orct_dir) || return 0
  _orct_live_claims "$d" ro | xargs -r -d '\n' jq -s . 2>/dev/null \
    | jq -r --arg me "$key" --argjson now "$(_orct_now_ms)" '
        sort_by(.arrived_at, .key)[] | select(.key != $me)
        | "- turn \(if (.command_id // "") != "" then .command_id else .key end) (\(.state), \((($now - .arrived_at) / 60000) | floor)m): \(.head // "")"' 2>/dev/null
}

# orct_state_begin <key> — the turn's own copies of STATE.md and facts.md.
# Exports ORC_TURN_STATE, ORC_TURN_FACTS, ORC_TURN_ERR and ORC_TURN_TMP.
orct_state_begin() {
  local key="$1" d t live
  d=$(_orct_dir) || return 1
  t="$d/$key"
  # A command that runs again (its first turn stopped and released the claim)
  # starts clean: a leftover .merged would make this turn's merge a silent no-op
  # (lead BLOCK at cecc227a6). A leftover .merge-failed copy is the operator's
  # recovery file, so it is moved aside, never overwritten.
  if [ -e "$t/.merge-failed" ]; then
    mv -- "$t" "$t.failed-$(date +%s)" 2>/dev/null \
      && _orct_log "turn ${CMD_ID:-$key}: the earlier turn's unmerged copy is kept at $t.failed-* (its merge had failed)"
  fi
  rm -f "$t/.merged" 2>/dev/null
  mkdir -p "$t" 2>/dev/null && chmod 700 "$t" 2>/dev/null || return 1
  for live in "$ORC/STATE.md" "${ARCHIE_ORC_DIR:-$ORC}/facts.md"; do
    [ -f "$live" ] || continue
    cp -p "$live" "$t/$(basename "$live")" && cp -p "$live" "$t/$(basename "$live").base"
  done
  export ORC_TURN_STATE="$t/STATE.md" ORC_TURN_FACTS="$t/facts.md" ORC_TURN_ERR="$t/last-error.txt" ORC_TURN_TMP="$t"
}

# orct_state_merge <key> — merge the turn's copies back into the live files.
# Idempotent. A copy that is missing or unchanged takes no lock. A failed
# merge keeps the live file as it is and writes one ALERTS line naming the copy.
orct_state_merge() {
  local key="$1" d t pair live name mine base out h="${HARNESS:-${H:-}}" py
  d=$(_orct_dir) || return 0
  t="$d/$key"
  [ -d "$t" ] && [ ! -e "$t/.merged" ] || return 0
  py="$h/bin/orc-state-merge.py"
  [ -n "$h" ] && [ -r "$py" ] || py="$(dirname "${BASH_SOURCE[0]}")/../orc-state-merge.py"
  for pair in "$ORC/STATE.md" "${ARCHIE_ORC_DIR:-$ORC}/facts.md"; do
    live="$pair"; name=$(basename "$live"); mine="$t/$name"; base="$t/$name.base"
    [ -f "$mine" ] || continue
    [ -e "$base" ] && cmp -s "$mine" "$base" && continue
    (
      flock -w 60 9 || exit 1
      out="$live.merge.$$"
      if python3 -I "$py" "$live" "$base" "$mine" "$key" > "$out" 2>/dev/null; then
        chmod 600 "$out" 2>/dev/null; mv -f "$out" "$live" || exit 1
      else
        rm -f "$out"; exit 1
      fi
    ) 9>"$ORC/.state.lock" && continue
    : > "$t/.merge-failed"
    [ -n "$h" ] && [ -x "$h/bin/alert-line.sh" ] \
      && HARNESS="$h" "$h/bin/alert-line.sh" "[orchestrator] turn ${CMD_ID:-$key}: the $name merge failed; $live was kept unchanged and this turn's copy is at $mine" >/dev/null 2>&1
  done
  : > "$t/.merged"
  return 0
}

# orct_release <key> — a turn that stops before it answers drops its own claim
# (no .done: it is not answered), so a re-delivered copy runs at once instead of
# exiting rc 3 until the claim goes stale. Only the claim this process made
# (its ORCT_TOKEN) is dropped; anyone else's claim is left alone.
orct_release() {
  local key="$1" d
  d=$(_orct_dir) || return 0
  [ -n "${ORCT_TOKEN:-}" ] && [ -e "$d/$key.json" ] || return 0
  ( flock -w 30 9 || exit 0
    [ "$(jq -r '.token // ""' "$d/$key.json" 2>/dev/null)" = "$ORCT_TOKEN" ] && rm -f "$d/$key.json"
    exit 0 ) 9>"$d/.lock"
  return 0
}

# orct_done <key> — the command is answered: mark it, drop the claim. Markers,
# stale claims and turn directories older than 24 h are pruned here.
orct_done() {
  local key="$1" d
  d=$(_orct_dir) || return 0
  [ -d "$d" ] || return 0
  ( flock -w 30 9; : > "$d/$key.done"; rm -f "$d/$key.json" ) 9>"$d/.lock"
  [ -d "$d/$key" ] && [ ! -e "$d/$key/.merge-failed" ] && rm -rf -- "${d:?}/$key"
  find "$d" -mindepth 1 -maxdepth 1 \( -name '*.done' -o -name '*.stale' \) -mmin +1440 -exec rm -f -- {} + 2>/dev/null
  # A turn directory goes after 24 h only when nothing needs it: never one with
  # a .merge-failed copy (an ALERT points to it), a moved-aside failed copy, or a
  # live claim (a turn has no time limit).
  local t
  for t in "$d"/*/; do
    t="${t%/}"; [ -d "$t" ] || continue
    [ -e "$t/.merge-failed" ] && continue
    case "$t" in *.failed-*) continue ;; esac
    [ -e "$t.json" ] && continue
    [ -n "$(find "$t" -maxdepth 0 -mmin +1440 2>/dev/null)" ] && rm -rf -- "$t"
  done
  return 0
}
