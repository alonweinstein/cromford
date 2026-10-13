#!/bin/bash
# bin/lib/failover-drill-proofs.sh — the four proofs of the failover drill
# (BH-2746 contract, BH-2747 bodies, parent #402). Sourced by
# bin/failover-drill.sh after bin/lib/failover-drill-common.sh (it needs
# fd_proof_set), never run.
#
# Signatures are fixed; the drill script calls exactly these. Each records its
# verdict through fd_proof_set <n> exactly once and returns 0.
#   fd_proof_poll_commands <run> <standby_ip>                          proof 1
#   fd_proof_chat <run> <standby_ip>                                   proof 2
#   fd_proof_pool <run>                                                proof 3
#   fd_proof_ledger <run> <hub> <standby> <t_promote> <t_back> <settle_s>  proof 4
#
# Knobs (env):
#   FAILOVER_DRILL_PROOF_DEADLINE_S (600) / FAILOVER_DRILL_POLL_S (30): every
#     wait is ceil(deadline/poll) polls with `sleep poll` between them, counted,
#     never timed against fd_now. A value that is not a positive integer is its
#     default.
#   CONSOLE_URL + HARNESS_SECRET: the console; either empty makes proofs 1 and
#     2 UNPROVEN "console not configured" with nothing sent.
#   FAILOVER_DRILL_CONSOLE_ENQUEUE_PATH (/api/dash/action),
#   FAILOVER_DRILL_CONSOLE_STATUS_PATH (/api/dash/commands?limit=50; a `{id}`
#     in it becomes the command id).
#   FAILOVER_DRILL_POOL_PROJECT: no default; unset makes proof 3 UNPROVEN
#     "not configured" with nothing enqueued.
#
# Verdicts: OK is set only once the positive evidence is in hand. An unread,
# empty, unparseable or truncated answer is UNPROVEN. FAIL is evidence of the
# wrong thing: a different ack result, a stale orchestrator reply, a
# `duplicate` queue key, a promote count other than one each way, a merge
# ledger row or an alert claim written by the demoted hub in the window.
# Enqueues are sent once and never retried.

_fdp_int() { if [[ "${1:-}" =~ ^[1-9][0-9]*$ ]]; then printf '%s' "$1"; else printf '%s' "$2"; fi; }
_fdp_deadline() { _fdp_int "${FAILOVER_DRILL_PROOF_DEADLINE_S:-}" 600; }
_fdp_poll_s() { _fdp_int "${FAILOVER_DRILL_POLL_S:-}" 30; }

# _fdp_poll <cmd...>: runs cmd up to ceil(deadline/poll) times, sleeping the
# poll interval between runs (never after the last). rc 0 as soon as cmd is.
_fdp_poll() {
  local d p i=1 n
  d=$(_fdp_deadline); p=$(_fdp_poll_s); n=$(( (d + p - 1) / p ))
  while :; do
    "$@" && return 0
    [ "$i" -ge "$n" ] && return 1
    i=$((i+1)); sleep "$p"
  done
}

# jq: an ISO time (with or without milliseconds) as epoch seconds, else null.
_fdp_epoch='def ep: try (tostring | sub("\\.[0-9]+Z$"; "Z") | fromdateiso8601) catch null;'

# _fdp_console <METHOD> <path> [json]: rc 0 only on a 2xx with a non-empty
# body; rc 3 (nothing sent) when the console is not configured. Sets FDP_BODY
# and FDP_HTTP (the status, empty when nothing answered) in the caller's shell.
_fdp_console() {
  local out rc
  FDP_HTTP=""; FDP_BODY=""
  [ -n "${CONSOLE_URL:-}" ] && [ -n "${HARNESS_SECRET:-}" ] || return 3
  if [ -n "${3:-}" ]; then
    out=$(curl -sS -m 20 --connect-timeout 5 -w $'\n%{http_code}' -X "$1" \
      -H "authorization: Bearer $HARNESS_SECRET" -H "content-type: application/json" \
      --data-binary "$3" "$CONSOLE_URL$2" 2>/dev/null)
  else
    out=$(curl -sS -m 20 --connect-timeout 5 -w $'\n%{http_code}' -X "$1" \
      -H "authorization: Bearer $HARNESS_SECRET" "$CONSOLE_URL$2" 2>/dev/null)
  fi
  rc=$?
  [ "$rc" = 0 ] || return 1
  FDP_HTTP="${out##*$'\n'}"; FDP_BODY="${out%$'\n'*}"
  case "$FDP_HTTP" in 2??) [ -n "$FDP_BODY" ] ;; *) return 1 ;; esac
}

# _fdp_enqueue <json>: sends ONE console action. rc 0 sets FDP_CMD_ID; rc 1
# sets FDP_WHY (the UNPROVEN detail).
_fdp_enqueue() {
  local rc
  FDP_CMD_ID=""; FDP_WHY=""
  _fdp_console POST "${FAILOVER_DRILL_CONSOLE_ENQUEUE_PATH:-/api/dash/action}" "$1"; rc=$?
  if [ "$rc" = 3 ]; then FDP_WHY="console not configured"; return 1; fi
  if [ "$rc" != 0 ]; then
    case "$FDP_HTTP" in
      2??) FDP_WHY="enqueue answered with no command id" ;;
      "") FDP_WHY="enqueue unreachable" ;;
      *) FDP_WHY="enqueue http=$FDP_HTTP" ;;
    esac
    return 1
  fi
  FDP_CMD_ID=$(printf '%s' "$FDP_BODY" | jq -r '(.command_id // .id // empty) | tostring' 2>/dev/null)
  [[ "$FDP_CMD_ID" =~ ^[A-Za-z0-9_-]+$ ]] || { FDP_CMD_ID=""; FDP_WHY="enqueue answered with no command id"; return 1; }
}

# _fdp_ack <cmd_id>: sets FDP_RES to that command's result. rc 1 unreadable,
# rc 2 not acked yet (no row with that id, or an empty result).
_fdp_ack() {
  local path
  FDP_RES=""
  path="${FAILOVER_DRILL_CONSOLE_STATUS_PATH:-/api/dash/commands?limit=50}"
  path="${path//\{id\}/$1}"
  _fdp_console GET "$path" || return 1
  FDP_RES=$(printf '%s' "$FDP_BODY" | jq -r --arg id "$1" '
    (if type == "array" then . elif (.commands | type) == "array" then .commands
     elif (.command | type) == "object" then [.command] else [] end)
    | map(select(type == "object" and (.id | tostring) == $id)) | .[0].result // empty
    | tostring | gsub("\n"; " ")' 2>/dev/null) || return 1
  [ -n "$FDP_RES" ] || return 2
}

# One poll of proof 1: stops on any ack.
_fdp_p1_step() { _fdp_ack "$FDP_CMD_ID"; }

fd_proof_poll_commands() {
  local run="${1:-}" body
  body=$(jq -nc --arg r "$run" '{type:"failover_drill_ping",run:$r}')
  _fdp_enqueue "$body" || { fd_proof_set 1 UNPROVEN "$FDP_WHY"; return 0; }
  FDP_RES=""
  if ! _fdp_poll _fdp_p1_step; then
    fd_proof_set 1 UNPROVEN "command $FDP_CMD_ID not acked within $(_fdp_deadline)s"
  elif [ "$FDP_RES" = "unknown command type failover_drill_ping" ]; then
    fd_proof_set 1 OK "command $FDP_CMD_ID acked by poll-commands"
  else
    fd_proof_set 1 FAIL "command $FDP_CMD_ID acked with: ${FDP_RES:0:200}"
  fi
  return 0
}

# One poll of proof 2. FDP_P2 is where it stands: ack (not acked yet),
# badack (terminal), ssh-fail, stale, ok. rc 0 ends the wait.
_fdp_p2_step() {
  local out rc
  if [ "$FDP_P2" = ack ]; then
    _fdp_ack "$FDP_CMD_ID" || return 1
    [ "$FDP_RES" = "handed to orchestrator" ] || { FDP_P2=badack; return 0; }
    FDP_P2=ssh-fail
  fi
  out=$(fd_ssh "$FDP_IP" 'f=/root/orchestrator/last-reply.txt; if [ -s "$f" ]; then stat -c %Y "$f"; else echo none; fi' 2>/dev/null); rc=$?
  if [ "$rc" != 0 ]; then
    [ "$FDP_P2" = stale ] || { FDP_P2=ssh-fail; FDP_SSH_RC=$rc; }
    return 1
  fi
  if [[ "$out" =~ ^[0-9]+$ ]] && [ "$out" -gt "$FDP_T_ENQ" ]; then FDP_P2=ok; return 0; fi
  FDP_P2=stale; return 1
}

fd_proof_chat() {
  local run="${1:-}" body
  FDP_IP="${2:-}"
  [ -n "$FDP_IP" ] || { fd_proof_set 2 UNPROVEN "no standby ip"; return 0; }
  FDP_T_ENQ=$(fd_now) || { fd_proof_set 2 UNPROVEN "clock unreadable"; return 0; }
  body=$(jq -nc --arg t "failover drill $run: reply with the single word ok" \
    '{type:"chat",project:"orchestrator",text:$t}')
  _fdp_enqueue "$body" || { fd_proof_set 2 UNPROVEN "$FDP_WHY"; return 0; }
  FDP_P2=ack; FDP_RES=""; FDP_SSH_RC=""
  _fdp_poll _fdp_p2_step
  case "$FDP_P2" in
    ok) fd_proof_set 2 OK "command $FDP_CMD_ID handed to orchestrator; reply written after enqueue" ;;
    badack) fd_proof_set 2 FAIL "command $FDP_CMD_ID acked with: ${FDP_RES:0:200}" ;;
    stale) fd_proof_set 2 FAIL "command $FDP_CMD_ID acked; no orchestrator reply since enqueue" ;;
    ssh-fail) fd_proof_set 2 UNPROVEN "command $FDP_CMD_ID acked; ssh to $FDP_IP failed (rc $FDP_SSH_RC)" ;;
    *) fd_proof_set 2 UNPROVEN "command $FDP_CMD_ID not acked within $(_fdp_deadline)s" ;;
  esac
  return 0
}

# One poll of proof 3: a machines row with exactly our key in state spawned.
_fdp_p3_step() {
  local body
  body=$(fd_api_get "/api/machines?project=$FDP_PROJ&key=$FDP_KEY") || return 1
  printf '%s' "$body" | jq -e --arg k "$FDP_KEY" \
    'any(.machines[]?; .key == $k and .state == "spawned")' >/dev/null 2>&1
}

fd_proof_pool() {
  local out rc
  FDP_PROJ="${FAILOVER_DRILL_POOL_PROJECT:-}"
  [ -n "$FDP_PROJ" ] || { fd_proof_set 3 UNPROVEN "not configured"; return 0; }
  FDP_KEY="FAILOVER-DRILL-${1:-}"
  if ! [[ "$FDP_KEY" =~ ^[A-Za-z0-9._-]{1,64}$ && "$FDP_PROJ" =~ ^[A-Za-z0-9._-]{1,64}$ ]]; then
    fd_proof_set 3 UNPROVEN "invalid project or key $FDP_KEY"; return 0
  fi
  out=$(declare -F queue_put >/dev/null \
      || . "${HARNESS:-/root/harness}/bin/jobs-client.sh" >/dev/null 2>&1 || exit 1
    queue_put "$FDP_PROJ" "$FDP_KEY" "" fly); rc=$?
  if [ "$rc" != 0 ] || [ -z "$out" ]; then fd_proof_set 3 UNPROVEN "queue unreachable"
  elif [ "$out" = duplicate ]; then fd_proof_set 3 FAIL "$FDP_KEY already queued or claimed"
  elif _fdp_poll _fdp_p3_step; then fd_proof_set 3 OK "$FDP_KEY spawned a machine"
  else fd_proof_set 3 UNPROVEN "no spawned machine for $FDP_KEY within $(_fdp_deadline)s"
  fi
  return 0
}

fd_proof_ledger() {
  local hub="${2:-}" sb="${3:-}" tp="${4:-}" tb="${5:-}" settle="${6:-}"
  local body rc lb now r a b c n1 n2 v x
  if ! [[ "$tp" =~ ^[0-9]+$ && "$tb" =~ ^[0-9]+$ && "$settle" =~ ^[0-9]+$ ]] \
     || [ "$tp" -gt "$tb" ] || [ -z "$hub" ] || [ -z "$sb" ] || [ "$hub" = "$sb" ]; then
    fd_proof_set 4 UNPROVEN "bad window"; return 0
  fi
  # The drill takes t_promote when it OBSERVES the promote, one poll after the
  # watchdog wrote its row, so (a) looks back one poll interval.
  lb=$((tp - $(_fdp_poll_s)))

  # (a) exactly one promote to the standby (by the watchdog), one back to the hub.
  a="U a: recovery unreadable"
  body=$(fd_api_get /api/hub/recovery); rc=$?
  if [ "$rc" = 0 ]; then
    r=$(printf '%s' "$body" | jq -r --arg sb "$sb" --arg hub "$hub" --argjson lb "$lb" --argjson tb "$tb" "$_fdp_epoch"'
      if (.recent_changes | type) != "array" then "unreadable"
      else ([.recent_changes[] | .at | ep | select(. != null)] | min) as $old
      | if .truncated == true and ($old == null or $old >= $lb) then "truncated"
        else [.recent_changes[] | select(type == "object" and .action == "promote"
               and ((.outcome // "") | tostring | startswith("ok")))
               | (.at | ep) as $e | select($e != null and $e >= $lb and $e <= $tb)] as $w
        | "\([$w[] | select(.after_holder == $sb)] | length) \([$w[] | select(.after_holder == $sb and .actor == "watchdog")] | length) \([$w[] | select(.after_holder == $hub)] | length)"
        end end' 2>/dev/null)
    case "$r" in
      truncated) a="U a: recent_changes truncated inside the window" ;;
      [0-9]*)
        read -r n1 x n2 <<<"$r"
        if [ "$n1" = 1 ] && [ "$x" = 1 ] && [ "$n2" = 1 ]; then a="O a: one promote to $sb by watchdog, one back to $hub"
        else a="F a: $n1 promotes to $sb / $n2 back to $hub in window ($x by watchdog)"; fi ;;
    esac
  fi

  # (b) no merge ledger row in the window written by the hub; one by the standby.
  b="U b: ledger unreadable"
  v=$(fd_iso $((tb + 1))) && body=$(fd_api_get "/api/ledger?kind=merge&limit=1000&before=$v"); rc=$?
  if [ "$rc" = 0 ]; then
    r=$(printf '%s' "$body" | jq -r --arg sb "$sb" --arg hub "$hub" --argjson tp "$tp" --argjson tb "$tb" "$_fdp_epoch"'
      if (.ledgers | type) != "array" then "U\tunreadable"
      elif .truncated == true then "U\ttruncated"
      elif (.ledgers | length) >= 1000 and (((.ledgers[-1].updated_at | ep) // $tp) >= $tp) then "U\tpage"
      else [.ledgers[] | select(type == "object") | (.updated_at | ep) as $e
             | select($e != null and $e >= $tp and $e <= $tb)] as $w
      | ([$w[] | select(.actor == $hub)] | first) as $h
      | if $h != null then "F\t\($h.key)\t\($h.updated_at)"
        elif any($w[]; .actor == $sb) then "O\t\([$w[] | select(.actor == $sb)] | length)"
        else "U\tnone" end
      end' 2>/dev/null)
    case "$r" in
      U$'\t'truncated) b="U b: ledger truncated" ;;
      U$'\t'page) b="U b: window not covered by one page" ;;
      U$'\t'none) b="U b: merge ledger rows carry no writer box" ;;
      F$'\t'*) IFS=$'\t' read -r _ n1 n2 <<<"$r"; b="F b: merge ledger $n1 written by $hub at $n2" ;;
      O$'\t'*) b="O b: ${r#O$'\t'} merge rows by $sb, none by $hub" ;;
    esac
  fi

  # (c) no alert claimed by the hub in (t_promote + settle, t_back).
  c="U c: alerts unreadable"
  now=$(fd_now) && body=$(fd_api_get "/api/alerts?claimed_since_s=$(( now - tp + 1 > 0 ? now - tp + 1 : 1 ))&limit=500"); rc=$?
  if [ "$rc" = 0 ]; then
    r=$(printf '%s' "$body" | jq -r --arg hub "$hub" --argjson lo "$((tp + settle))" --argjson tb "$tb" "$_fdp_epoch"'
      if (.alerts | type) != "array" then "U\tunreadable"
      elif .truncated == true then "U\ttruncated"
      else ([.alerts[] | select(type == "object" and ((.claimed_by // "") | tostring | endswith("@" + $hub)))
              | (.claimed_at | ep) as $e | select($e != null and $e > $lo and $e < $tb)] | first) as $h
      | if $h != null then "F\t\($h.id)\t\($h.claimed_by)\t\($h.claimed_at)" else "O" end
      end' 2>/dev/null)
    case "$r" in
      O) c="O c: no alert claimed by $hub after settle" ;;
      U$'\t'truncated) c="U c: alerts truncated" ;;
      F$'\t'*) IFS=$'\t' read -r _ n1 n2 x <<<"$r"; c="F c: alert $n1 claimed by $n2 at $x" ;;
    esac
  fi

  v=OK
  case "${a:0:1}${b:0:1}${c:0:1}" in *F*) v=FAIL ;; *U*) v=UNPROVEN ;; esac
  fd_proof_set 4 "$v" "${a:2}; ${b:2}; ${c:2}"
  return 0
}
