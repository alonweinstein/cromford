#!/bin/bash
# bin/lib/lane-down.sh — BH-1674 lane-down state, shared by the auth canary and
# the re-probe lane so both mark, clear and announce a runner lane identically.
# Sourced, never executed: functions only, no side effects on source. One knob,
# LANE_DOWN_TTL_S, read by ld_mark (BH-2359).
#
# ID is <box>-<lane>, lane = the last dash field (bin/fleet-status-push.sh:334).
# Record state/lane-down/<ID>, key=value, always written tmp+mv:
#   box lane addr since last_probe last_error standing_at  (epoch s, but last_error)
# Every edit of state/claude-auth-down.txt holds flock -w 10 on
# locks/lane-down-state.lock for the grep/mv only, never across a probe.
#
# BH-2359: ld_mark also puts the fleet row `lane <lane> <box>` (until now +
# LANE_DOWN_TTL_S, default 7200) and ld_clear clears it before the local files
# go, through bin/lib/fleet-cooldown.sh. Absent contract = today's behaviour.
#
# BH-4153: the daily lanedown-<ID>-<YYYYMMDD> marks are harness_flags rows
# scoped to THIS box (JOBS_BOX), written and read through bin/lib/jobs/flags.sh
# when a worker is configured (_ld_db); a write the worker cannot take is a
# local hold, so the mark still stands on this box. No client, no worker
# configured, or no box name: the flags/ files, as before.

# shellcheck source=bin/lib/fleet-cooldown.sh
[ ! -r "$(dirname "${BASH_SOURCE[0]}")/fleet-cooldown.sh" ] || . "$(dirname "${BASH_SOURCE[0]}")/fleet-cooldown.sh"

_ld_id_ok() { [[ $1 =~ ^[a-z0-9_.-]+-[a-z0-9_.]+$ && $1 != */* ]]; }
_ld_stamp() { date -u -d "@$1" '+%Y-%m-%d %H:%M:%SZ'; }
_ld_day()   { date -u -d "@$(($1 - $2 * 86400))" +%Y%m%d; }
_ld_ttl() {
  local t=${LANE_DOWN_TTL_S:-7200}
  case "$t" in ''|0|*[!0-9]*) t=7200 ;; esac
  echo "$t"
}

# _ld_db — rc 0 when the lanedown marks are rows: the client is loaded (or
# fleet-cooldown's loader can load it), a worker is configured, and this box
# has a name to scope them by.
_ld_db() {
  command -v flag_set >/dev/null 2>&1 || { command -v _fcd_client >/dev/null 2>&1 && _fcd_client; } || return 1
  command -v flag_set >/dev/null 2>&1 && _flag_db_configured && _flag_default_scope lanedown-x >/dev/null 2>&1
}

# 00:00Z of the oldest day in the contiguous flag run ending today or yesterday.
# From rows, one flag_list for the lane; an unknown list (rc 2) is no run, the
# first-time path.
_ld_since_from_flags() {
  local H=$1 ID=$2 now=$3 k=0 d oldest="" names=""
  if _ld_db; then
    names=$(flag_list --scope "$JOBS_BOX" "lanedown-$ID-" 2>/dev/null) || names=""
    _ld_has() { grep -qxF "lanedown-$ID-$1" <<<"$names"; }
  else
    _ld_has() { [ -e "$H/flags/lanedown-$ID-$1" ]; }
  fi
  _ld_has "$(_ld_day "$now" 0)" || k=1
  while [ "$k" -le 400 ]; do
    d=$(_ld_day "$now" "$k")
    _ld_has "$d" || break
    oldest=$d; k=$((k + 1))
  done
  [ -z "$oldest" ] || date -u -d "$oldest" +%s
  return 0   # no run is the first-time path, not a failure: set -e callers survive it
}

ld_record_path() { echo "$1/state/lane-down/$2"; }
ld_get() { awk -v k="$2" 'index($0, k "=") == 1 { print substr($0, length(k) + 2); exit }' "$1" 2>/dev/null; return 0; }
ld_probe_ok() { grep -qiE '\bok\b' <<<"$1"; }

ld_fmt_dur() {
  local s=$1
  [[ $s =~ ^[0-9]+$ ]] || s=0
  if [ "$s" -ge 86400 ]; then echo "$((s / 86400))d $((s % 86400 / 3600))h"
  elif [ "$s" -ge 3600 ]; then echo "$((s / 3600))h $((s % 3600 / 60))m"
  else echo "$((s / 60))m"; fi
}

_ld_state_edit() {
  local H=$1 op=$2 line=$3 f=$1/state/claude-auth-down.txt
  mkdir -p "$H/locks" "$H/state" || return 1
  (
    flock -w 10 9 || exit 1
    if [ "$op" = add ]; then
      grep -qxF -- "$line" "$f" 2>/dev/null || echo "$line" >> "$f"
    elif [ -f "$f" ]; then
      { grep -vxF -- "$line" "$f" > "$f.tmp.$$" 2>/dev/null || [ $? -eq 1 ]; } && mv "$f.tmp.$$" "$f"
    fi
  ) 9>"$H/locks/lane-down-state.lock"
}

_ld_write() {
  local r=$1
  mkdir -p "${r%/*}" || return 1
  printf 'box=%s\nlane=%s\naddr=%s\nsince=%s\nlast_probe=%s\nlast_error=%s\nstanding_at=%s\n' \
    "$2" "$3" "$4" "$5" "$6" "$7" "$8" > "$r.tmp.$$" && mv "$r.tmp.$$" "$r"
}

# ld_mark <H> <ID> <addr> <out> <now> [since_hint]: since_hint (a fleet row's
# since, lane-reprobe's reseed) is used only when the record has none.
ld_mark() {
  local H=$1 ID=$2 addr=$3 out=$4 now=$5 hint=${6:-} r since e fe
  _ld_id_ok "$ID" || return 2
  r=$(ld_record_path "$H" "$ID")
  since=$(ld_get "$r" since)
  [ -n "$since" ] || since=$hint
  [ -n "$since" ] || since=$(_ld_since_from_flags "$H" "$ID" "$now")
  [ -n "$addr" ] || addr=$(ld_get "$r" addr)
  e=$(tr '\n' ' ' <<<"$out")
  # The fleet row goes first, so a local write that fails still leaves it.
  fe=${e:0:160}; fe=${fe%"${fe##*[! ]}"}
  ! command -v fcd_put >/dev/null 2>&1 \
    || fcd_put lane "${ID##*-}" "${ID%-*}" "$((now + $(_ld_ttl)))" "${since:-$now}" "$fe"
  _ld_write "$r" "${ID%-*}" "${ID##*-}" "$addr" "${since:-$now}" "$now" "${e:0:160}" "$(ld_get "$r" standing_at)" || return 1
  _ld_state_edit "$H" add "$ID" || return 1
  local day; day=$(_ld_day "$now" 0)
  if _ld_db; then
    flag_set --scope "$JOBS_BOX" --hold-local "lanedown-$ID-$day" on "lane down" >/dev/null 2>&1 \
      || flag_has --cached --scope "$JOBS_BOX" "lanedown-$ID-$day" >/dev/null 2>&1
    return
  fi
  if command -v flag_set >/dev/null 2>&1 && _flag_db_configured; then
    mkdir -p "$H/logs" && echo "$(_ld_stamp "$now") [lane-down] lanedown-$ID-$day: this box has no usable JOBS_BOX, so the mark is the flags/ file, not a row" >> "$H/logs/agent-rules.log"
  fi
  mkdir -p "$H/flags" && touch "$H/flags/lanedown-$ID-$day"   # no client / no worker / no box: the legacy file
}

# ld_flag_on <H> <ID> <YYYYMMDD> — rc 0 the day's mark is on, 1 off, 2 unknown
# (rows only: the worker is down and nothing is cached).
ld_flag_on() {
  if _ld_db; then flag_has --scope "$JOBS_BOX" "lanedown-$2-$3" >/dev/null 2>&1; return; fi
  [ -e "$1/flags/lanedown-$2-$3" ]
}

ld_clear() {
  local H=$1 ID=$2 now=$3 r since frc=0
  _ld_id_ok "$ID" || return 2
  r=$(ld_record_path "$H" "$ID")
  since=$(ld_get "$r" since)
  [ -n "$since" ] || since=$(_ld_since_from_flags "$H" "$ID" "$now")
  # Fleet row before the local files, fail-open: rc 0 removed, 1 no row; any
  # other rc is logged and the row expires by its TTL.
  if command -v fcd_clear >/dev/null 2>&1; then
    fcd_clear lane "${ID##*-}" "${ID%-*}" >/dev/null 2>&1 || frc=$?
    if [ "$frc" -ge 2 ]; then
      mkdir -p "$H/logs" && echo "$(_ld_stamp "$(date +%s)") [lane-down] fcd_clear lane ${ID##*-} ${ID%-*} rc $frc; local state removed, row expires by TTL" \
        >> "$H/logs/agent-rules.log"
    fi
  fi
  _ld_state_edit "$H" del "$ID" || return 1
  _ld_db && flag_clear --scope "$JOBS_BOX" "lanedown-$ID-$(_ld_day "$now" 0)" "lane back" >/dev/null 2>&1
  rm -f "$H/flags/lanedown-$ID-$(_ld_day "$now" 0)" "$r"
  ld_fmt_dur $((now - ${since:-$now}))
}

ld_recovered() {
  local H=$1 ID=$2 now=$3 dur msg ts
  dur=$(ld_clear "$H" "$ID" "$now") || return 1
  msg="lane ${ID##*-} back on ${ID%-*} after $dur"; ts=$(_ld_stamp "$now")
  mkdir -p "$H/logs"
  echo "$ts $msg" >> "$H/logs/lane-reprobe.log"
  echo "$ts [auth] $ID RECOVERED" >> "$H/logs/ALERTS.log"
  if [ -x "$H/bin/lane-alert.sh" ]; then
    "$H/bin/lane-alert.sh" --resolve --id "lanedown-$ID" auth "$msg" >/dev/null 2>&1 || true
    "$H/bin/lane-alert.sh" --resolve --id "lanedown-stale-$ID" auth "$msg" >/dev/null 2>&1 || true
  fi
}
