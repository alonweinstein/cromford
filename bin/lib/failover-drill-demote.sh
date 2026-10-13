#!/bin/bash
# bin/lib/failover-drill-demote.sh — hand the lease back to the hub and check
# the standby went quiet (BH-2746, parent #402). Sourced by
# bin/failover-drill.sh, never run.
#
# fd_promote_back <run> <hub>
#   On success sets FD_T_BACK (epoch seconds) and returns 0; on failure sets
#   FD_DEMOTE_DETAIL (one line) and returns 1.
# fd_standby_quiet <standby> <standby_ip> <t_back>
#   Sets FD_DEMOTE_VERDICT (OK|FAIL|UNPROVEN), FD_DEMOTE_DETAIL and
#   FD_DEMOTE_UNOBSERVABLE (space-separated names of lanes that log to
#   /dev/null); returns 0 only on OK.
#
# Knobs (env + code default on purpose, like bin/hub-lease.sh's: the drill runs
# while the lease and its database are being failed over, so a settings-table
# read would lean on the thing under test; a non-integer falls back):
#   FAILOVER_DRILL_DEMOTE_SETTLE_S  180  how long the hub's `check` may take to
#                                        answer held after the promote-back,
#                                        polled every 10 s by COUNT, never by
#                                        fd_now (a pinned clock never moves)
#   FAILOVER_DRILL_OBSERVE_S        600  how long the standby's lane logs are
#                                        watched for growth
#
# BH-2748. fd_promote_back never promotes anything on a failure path: a
# refused promote is the worker's words in FD_DEMOTE_DETAIL, a settle timeout is
# one fd_alert line; the drill script owns failback messaging.
#
# fd_standby_quiet reads the standby's /etc/cron.d/harness-standby (rendered by
# bin/standby-install.sh). Every `hub-lease.sh check && ` line is a hub lane;
# its `>> <log>` targets, minus standby-stream.log and hub-lease.log, are sized
# before and after the window, and any growth is a lane that ran on the
# standby. A lane with no such target (`>/dev/null`, or no redirect at all) is
# named in FD_DEMOTE_UNOBSERVABLE and never counted clean. A trailing shell
# comment is stripped first, so a log it mentions is not read. Every path that
# cannot see (ssh, an unreadable file, a failed read, a rotated log, no
# observable log at all) is UNPROVEN, never OK.

_fd_int_or() { [[ "${1:-}" =~ ^[1-9][0-9]*$ ]] && printf '%s' "$1" || printf '%s' "$2"; }

fd_promote_back() {
  local run="${1:-}" hub="${2:-}" hl out rc settle polls i
  FD_DEMOTE_DETAIL=""
  unset FD_T_BACK
  [ -n "$hub" ] || { FD_DEMOTE_DETAIL="promote-back: no hub named"; return 1; }
  hl="${HARNESS:-/root/harness}/bin/hub-lease.sh"
  out=$("$hl" promote --holder "$hub" --reason "failover drill $run: promote back" --override-live-lease 2>&1); rc=$?
  if [ "$rc" != 0 ]; then
    FD_DEMOTE_DETAIL=$(printf '%s\n' "$out" | grep '^hub-lease: ' | tail -n 1 | tr '\n' ' ' | cut -c1-300)
    FD_DEMOTE_DETAIL="${FD_DEMOTE_DETAIL% }"
    [ -n "$FD_DEMOTE_DETAIL" ] || FD_DEMOTE_DETAIL="hub-lease.sh promote rc=$rc"
    return 1
  fi
  FD_T_BACK=$(fd_now) || { unset FD_T_BACK; FD_DEMOTE_DETAIL="promote-back: clock unreadable"; return 1; }
  settle=$(_fd_int_or "${FAILOVER_DRILL_DEMOTE_SETTLE_S:-}" 180)
  polls=$(( (settle + 9) / 10 ))
  for (( i = 1; i <= polls; i++ )); do
    "$hl" check >/dev/null 2>&1 && return 0
    [ "$i" -lt "$polls" ] && sleep 10
  done
  FD_DEMOTE_DETAIL="hub not holding the lease after promote-back"
  fd_alert "run $run: hub $hub not holding the lease ${settle}s after promote-back"
  return 1
}

# _fd_cron_parse — the standby cron file on stdin; prints `LOG <path>` for each
# observable lane log (first seen order, de-duplicated) and `UNOBS <lane>` for
# each gated lane with no log target.
_fd_cron_parse() {
  awk '
    /^[ \t]*#/ { next }
    {
      g = index($0, "/root/harness/bin/hub-lease.sh check && ")
      if (!g) next
      cmd = substr($0, g + length("/root/harness/bin/hub-lease.sh check && "))
      sub(/[ \t]#.*$/, "", cmd)
      rest = cmd; found = 0
      while (match(rest, />>[ \t]*[^ \t;|&)]+/)) {
        t = substr(rest, RSTART, RLENGTH); sub(/^>>[ \t]*/, "", t)
        rest = substr(rest, RSTART + RLENGTH)
        if (t == "/dev/null") continue
        b = t; sub(/.*\//, "", b)
        if (b == "standby-stream.log" || b == "hub-lease.log") continue
        found = 1
        if (!(t in seen)) { seen[t] = 1; print "LOG " t }
      }
      if (found) next
      n = split(cmd, w, /[ \t]+/); lane = ""
      for (i = 1; i <= n; i++) if (w[i] ~ /^\/.*[^\/]$/) { lane = w[i]; break }
      if (lane == "") for (i = 1; i <= n; i++) if (w[i] != "" && w[i] !~ /^[{(]$/ && w[i] !~ /=/) { lane = w[i]; break }
      sub(/.*\//, "", lane)
      if (lane != "" && !(lane in named)) { named[lane] = 1; print "UNOBS " lane }
    }'
}

# _fd_sizes <standby> <ip> <array-name> <path...> — one ssh read of every path's
# byte size into the named associative array; a missing file reads as 0. rc 1
# (detail set) unless every path came back exactly once with an integer.
_fd_sizes() {
  local sb="$1" ip="$2" arr="$3"; shift 3
  local q="" p out rc sz path n=0
  for p in "$@"; do q="$q $(printf '%q' "$p")"; done
  out=$(fd_ssh "$ip" "for f in$q; do s=\$(stat -c %s -- \"\$f\" 2>/dev/null) || s=0; printf '%s %s\\n' \"\$s\" \"\$f\"; done"); rc=$?
  declare -gA "$arr=()"
  local -n _sz="$arr"
  if [ "$rc" = 0 ]; then
    while read -r sz path; do
      [ -n "$path" ] || continue
      [[ "$sz" =~ ^[0-9]+$ ]] && [ -z "${_sz[$path]+x}" ] || { rc=1; break; }
      _sz[$path]=$sz; n=$((n + 1))
    done <<<"$out"
    for p in "$@"; do [ -n "${_sz[$p]+x}" ] || rc=1; done
    [ "$n" = "$#" ] || rc=1
  fi
  [ "$rc" = 0 ] && return 0
  FD_DEMOTE_DETAIL="size read failed on $sb (rc $rc)"
  return 1
}

fd_standby_quiet() {
  local sb="${1:-}" ip="${2:-}" t_back="${3:-}" rc cron parsed observe iso l
  local -a logs=() unobs=() grew=()
  local -A _fd_s1 _fd_s2
  FD_DEMOTE_VERDICT=UNPROVEN
  FD_DEMOTE_DETAIL=""
  FD_DEMOTE_UNOBSERVABLE=""
  [[ "$t_back" =~ ^[0-9]+$ ]] || { FD_DEMOTE_DETAIL="no promote-back time"; return 1; }
  iso=$(fd_iso "$t_back")

  fd_ssh "$ip" /root/harness/bin/hub-lease.sh check >/dev/null 2>&1; rc=$?
  case "$rc" in
    1) ;;
    0) FD_DEMOTE_VERDICT=FAIL
       FD_DEMOTE_DETAIL="$sb still holds the hub lease after demotion"
       fd_alert "$sb still holds the hub lease after the promote-back at $iso"
       return 1 ;;
    *) FD_DEMOTE_DETAIL="ssh to $sb failed (rc $rc) running hub-lease.sh check"; return 1 ;;
  esac

  cron=$(fd_ssh "$ip" cat /etc/cron.d/harness-standby 2>/dev/null); rc=$?
  if [ "$rc" != 0 ] || [ -z "$cron" ]; then
    FD_DEMOTE_DETAIL="cannot read /etc/cron.d/harness-standby on $sb (rc $rc)"; return 1
  fi
  parsed=$(printf '%s\n' "$cron" | _fd_cron_parse)
  while read -r kind l; do
    case "$kind" in LOG) logs+=("$l") ;; UNOBS) unobs+=("$l") ;; esac
  done <<<"$parsed"
  FD_DEMOTE_UNOBSERVABLE="${unobs[*]}"
  if [ "${#logs[@]}" = 0 ]; then
    FD_DEMOTE_DETAIL="no observable hub lane logs in harness-standby"
    [ -z "$FD_DEMOTE_UNOBSERVABLE" ] || FD_DEMOTE_DETAIL="$FD_DEMOTE_DETAIL; unobservable: $FD_DEMOTE_UNOBSERVABLE"
    return 1
  fi

  observe=$(_fd_int_or "${FAILOVER_DRILL_OBSERVE_S:-}" 600)
  _fd_sizes "$sb" "$ip" _fd_s1 "${logs[@]}" || return 1
  sleep "$observe"
  _fd_sizes "$sb" "$ip" _fd_s2 "${logs[@]}" || return 1

  local shrunk=""
  for l in "${logs[@]}"; do
    if [ "${_fd_s2[$l]}" -gt "${_fd_s1[$l]}" ]; then grew+=("$l")
    elif [ "${_fd_s2[$l]}" -lt "${_fd_s1[$l]}" ] && [ -z "$shrunk" ]; then shrunk="$l"; fi
  done
  if [ "${#grew[@]}" -gt 0 ]; then
    FD_DEMOTE_VERDICT=FAIL
    FD_DEMOTE_DETAIL="hub lane ${grew[0]} ran on $sb after demotion"
    [ "${#grew[@]}" = 1 ] || FD_DEMOTE_DETAIL="$FD_DEMOTE_DETAIL (+$(( ${#grew[@]} - 1 )) more: ${grew[*]:1})"
    fd_alert "$sb ran hub lanes within ${observe}s after the promote-back at $iso: ${grew[*]}"
    return 1
  fi
  if [ -n "$shrunk" ]; then
    FD_DEMOTE_DETAIL="$shrunk shrank on $sb (rotated?)"; return 1
  fi
  FD_DEMOTE_VERDICT=OK
  FD_DEMOTE_DETAIL="${#logs[@]} hub lane logs unchanged on $sb for ${observe}s after demotion at $iso"
  [ -z "$FD_DEMOTE_UNOBSERVABLE" ] || FD_DEMOTE_DETAIL="$FD_DEMOTE_DETAIL; unobservable: $FD_DEMOTE_UNOBSERVABLE"
  return 0
}
