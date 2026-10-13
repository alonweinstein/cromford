#!/bin/bash
# bin/lib/preplan-cadence.sh — per-project pre-plan cadence, cut when adoption
# stays low (BH-2543). Sourced only; safe under `set -u`.
#
# A speculative pre-plan is a paid session. When fewer than FLOOR percent of at
# least MIN_SAMPLES bought pre-plans (adopted + stale) over WINDOW days were
# adopted, the project is CUT: `ahead`, `blocked` and `child` candidates get at
# most one launch per CUT_INTERVAL seconds. `queued` and `hotfix` are never held.
# The call site is `# >>> preplan cadence (BH-2543)` in bin/preplan-tick.sh,
# just before the launch line; a deny there only `continue`s, it never spends a
# PREPLAN_PARALLEL slot.
#
# UNKNOWN IS TODAY'S CADENCE. Any answer this lib cannot read (no transport, a
# non-zero `_jobs_req`, a 404 while the route is undeployed, non-JSON, the
# project missing, a non-integer count) is UNKNOWN: nothing printed, no cut.
# Never 0/0.
#
# STATE, per project, under state/preplan/:
#   adoption-<p>.json  the last answer, reused for CACHE_S. A failed read is
#                      cached too, as {"unknown":true}, so an undeployed route
#                      is asked once per window, not once per tick.
#   cadence-<p>.last   mtime = the last launch allowed under a cut. It is
#                      stamped BEFORE allow returns rc 0; a stamp that cannot
#                      be written denies (fail closed toward not spending).
#   cadence-<p>.mode   `cut` or `normal`. A change writes ONE line to
#                      logs/preplan.log: PREPLAN_CADENCE_CUT / _RESTORED.
#
# KNOBS (catalog/lanes.d/preplan-tick.json), each read per project through
# `lane_knob preplan-tick <ENV> <project>` when lane-gate.sh is loaded, else from
# the environment; empty or non-integer falls back to the default:
#   PREPLAN_ADOPT_FLOOR_PCT    adopt rate (percent) under which cadence is cut (50; 0 = never cut)
#   PREPLAN_ADOPT_MIN_SAMPLES  bought pre-plans needed before the rate counts (10)
#   PREPLAN_ADOPT_WINDOW_DAYS  window the rate is measured over (7, 1-30)
#   PREPLAN_CUT_INTERVAL_S     launch interval for a project whose cadence is cut (1800)
#   PREPLAN_ADOPT_CACHE_S      how long one adoption answer is reused (900)
#
# THE ROUTE (documented here, built by the worker child, read by the cadence and
# console children):
#   GET /api/preplans/adoption?project=<p>&days=<1-30>
#   -> {window_days, since,
#       projects:[{project, adopted, stale, miss, off, bought, rate}],
#       days:[{project, day, adopted, stale, miss, off, rate}],
#       recent:[{job_id, ticket_id, project, verdict, detail, created_at}],
#       recent_truncated, as_of}
#   bought = adopted + stale. rate = adopted/bought, null when bought = 0,
#   never 0. `days` outside 1-30 or non-integer is a 400. `recent` is capped at
#   50 (recent_truncated says whether it was). It reads stage_events rows with
#   stage='preplan' and verdict ADOPTED|STALE|MISS|OFF.

# _ppc_knob <project> <ENV> <default> — the knob's integer value.
_ppc_knob() {
  local v
  if command -v lane_knob >/dev/null 2>&1; then
    v=$(lane_knob preplan-tick "$2" "$1")
  else
    v=${!2:-}
  fi
  case "$v" in ''|*[!0-9]*) v=$3 ;; esac
  printf '%s' "$v"
}

# _ppc_age <file> — seconds since the file's mtime; rc 1 when it is missing.
_ppc_age() {
  local m
  m=$(stat -c %Y "$1" 2>/dev/null) || return 1
  printf '%s' "$(( $(date -u +%s) - m ))"
}

# _ppc_window <project> — WINDOW_DAYS clamped to the route's 1-30.
_ppc_window() {
  local w
  w=$(_ppc_knob "$1" PREPLAN_ADOPT_WINDOW_DAYS 7)
  [ "$w" -ge 1 ] || w=1
  [ "$w" -le 30 ] || w=30
  printf '%s' "$w"
}

# preplan_adopt_stats <harness> <project> — `adopted stale` on stdout, rc 0;
# rc 1 and nothing printed when UNKNOWN.
preplan_adopt_stats() {
  local h="$1" p="$2" d f ttl age body w pf tmp line a s
  d="$h/state/preplan"; f="$d/adoption-$p.json"
  ttl=$(_ppc_knob "$p" PREPLAN_ADOPT_CACHE_S 900)
  if ! { age=$(_ppc_age "$f") && [ "$age" -ge 0 ] && [ "$age" -lt "$ttl" ]; }; then
    if ! command -v _jobs_req >/dev/null 2>&1 && [ -r "$h/bin/jobs-client.sh" ]; then
      # jobs-client.sh turns pipefail on; the tick runs without it.
      pf=$(set -o 2>/dev/null | awk '$1=="pipefail"{print $2}')
      # shellcheck disable=SC1091
      . "$h/bin/jobs-client.sh" >/dev/null 2>&1
      [ "$pf" = off ] && set +o pipefail
    fi
    # No transport configured: UNKNOWN, and nothing is written.
    command -v _jobs_req >/dev/null 2>&1 || return 1
    w=$(_ppc_window "$p")
    body=$(_jobs_req GET "/api/preplans/adoption?project=$p&days=$w" 2>/dev/null) || body='{"unknown":true}'
    mkdir -p "$d" 2>/dev/null || return 1
    tmp=$(mktemp "$d/.adoption-$p.XXXXXX" 2>/dev/null) || return 1
    if printf '%s\n' "$body" > "$tmp" 2>/dev/null && mv -f "$tmp" "$f" 2>/dev/null; then :
    else rm -f "$tmp" 2>/dev/null; return 1; fi
  fi
  line=$(jq -r --arg p "$p" 'first(.projects[]? | select(.project == $p)) | "\(.adopted) \(.stale)"' "$f" 2>/dev/null) || return 1
  read -r a s <<< "$line"
  [[ "${a:-}" =~ ^[0-9]+$ && "${s:-}" =~ ^[0-9]+$ ]] || return 1
  printf '%s %s\n' "$a" "$s"
}

# preplan_cadence_cut <harness> <project> — rc 0 and the reason on stdout when
# the project's cadence is cut; rc 1, silent, when it is not or when UNKNOWN.
preplan_cadence_cut() {
  local h="$1" p="$2" st a s floor min bought
  st=$(preplan_adopt_stats "$h" "$p") || return 1
  read -r a s <<< "$st"
  # A floor of 0 never cuts: a * 100 < 0 cannot hold.
  floor=$(_ppc_knob "$p" PREPLAN_ADOPT_FLOOR_PCT 50)
  min=$(_ppc_knob "$p" PREPLAN_ADOPT_MIN_SAMPLES 10)
  bought=$((a + s))
  [ "$bought" -ge "$min" ] || return 1
  if (( a * 100 < floor * bought )); then
    printf 'adopt %s%% (%s/%s) under floor %s%% over %sd\n' \
      "$((a * 100 / bought))" "$a" "$bought" "$floor" "$(_ppc_window "$p")"
    return 0
  fi
  return 1
}

# preplan_cadence_allow <harness> <project> <class> — rc 0 to launch this
# candidate now, rc 1 to hold it back.
preplan_cadence_allow() {
  local h="$1" p="$2" class="${3:-}" d reason mode prev st iv last age why
  case "$class" in queued|hotfix) return 0 ;; esac
  d="$h/state/preplan"
  if reason=$(preplan_cadence_cut "$h" "$p"); then mode='cut'; else mode='normal'; fi
  iv=$(_ppc_knob "$p" PREPLAN_CUT_INTERVAL_S 1800)
  prev=$(cat "$d/cadence-$p.mode" 2>/dev/null) || prev=normal
  [ -n "$prev" ] || prev=normal
  if [ "$mode" != "$prev" ]; then
    # The mode file first, then its line: a crash between the two loses a line,
    # it never repeats one.
    mkdir -p "$d" 2>/dev/null
    if printf '%s\n' "$mode" > "$d/cadence-$p.mode" 2>/dev/null; then
      if [ "$mode" = cut ]; then
        why="PREPLAN_CADENCE_CUT $reason, one launch per ${iv}s"
      elif st=$(preplan_adopt_stats "$h" "$p"); then
        why="PREPLAN_CADENCE_RESTORED (adopt ${st% *}/$(( ${st% *} + ${st#* } )))"
      else
        why="PREPLAN_CADENCE_RESTORED (adoption unknown)"
      fi
      mkdir -p "$h/logs" 2>/dev/null
      echo "$(date -u '+%F %TZ') [$p] $why" >> "$h/logs/preplan.log" 2>/dev/null
    fi
  fi
  [ "$mode" = cut ] || return 0
  last="$d/cadence-$p.last"
  if age=$(_ppc_age "$last") && [ "$age" -ge 0 ] && [ "$age" -lt "$iv" ]; then
    return 1
  fi
  # Stamped BEFORE the allow: the tick launches only after rc 0.
  touch "$last" 2>/dev/null || return 1
  return 0
}
