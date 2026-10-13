#!/bin/bash
# bin/lib/triage-throttle.sh — two deterministic preconditions in front of a
# PAID triage tick, asked by bin/lib/rt/gate.sh:rt_gate after the cost gate
# has answered RUN, and the launch-time ledger write those preconditions count
# against (P2, 2026-09-25). Sourced, never executed; set -u safe; every
# function answers a question and the caller decides what it means.
#
# WHY (cost rows, 7 days to 2026-09-25). The gate answers "did the world
# change", and on a low-yield board it changes all day — queue restamps, result
# sweeps, comment bumps — so every change buys a session:
#   project-1          $637 of triage for 13 merges
#   project-7             $649 for 6
#   project-8  $238 for 4
#   project-9           $643 in total for 0 merges
# the operator's rule is VOLUME, not a dollar budget: no per-ticket $ caps; the lever is
# how many paid calls are made at all. So:
#
#   HEALTH   a project whose board or repo cannot produce a build does not buy
#            the ticks that need its board (triage_health_check). Free checks,
#            one re-probe.
#   THROTTLE a low-yield project gets its paid ticks at a CADENCE and under a
#            daily CEILING, both per-project settings rows (triage_throttle_check,
#            counted by triage_throttle_record at the paid launch). Default 0 =
#            off = today's behaviour exactly; which projects get a row is an
#            operator decision.
#
# THE KNOBS are run-triage lane knobs (catalog/lanes.d/run-triage.json), so a
# settings row `lane.run-triage.<project>.<env lowercased>` reaches this file
# through the lane_env_apply call at the top of bin/run-triage.sh — no second
# settings reader. Every number is validated here and an unreadable one reads
# as OFF: a knob nobody can read must never be the thing that stops triage.
#
# WHAT THE THROTTLE NEVER HOLDS, and why:
#   forced / forced-env  an operator asked for this tick (flags/force-triage-<p>,
#                        FORCE_TRIAGE=1, the console's run_triage).
#   daily-sweep          the safety net: a board is read at least once a day.
#   no-gate-state        first run.
#   event-wake           a webhook said the client moved. Exempt from the cadence
#                        AND the ceiling (#2294 review I4): bin/wake-loop.sh's own
#                        cooldown is its limiter, and a client reply must never
#                        wait out a 24h ceiling. Max added wait for a webhook-
#                        backed board: none from this lib (the next cron tick,
#                        <= 10 min). A board with no webhook waits for its board
#                        diff to be allowed: <= TRIAGE_MIN_INTERVAL_S, or until the
#                        ceiling window rolls (<= 24h) — the daily sweep is the
#                        backstop either way.

_tt_now() {
  local n="${TRIAGE_THROTTLE_NOW:-}"
  case "$n" in ''|*[!0-9]*) n=$(date -u +%s 2>/dev/null) ;; esac
  printf '%s' "${n:-0}"
}
_tt_num() { # _tt_num <value> <default> -> a non-negative integer, else the default
  case "${1:-}" in ''|*[!0-9]*) printf '%s' "$2" ;; *) printf '%s' "$1" ;; esac
}
_tt_reason() { local r="${1#RUN }"; printf '%s' "${r%% *}"; }

# ============================================================================
# HEALTH
# ============================================================================

# triage_health_on <harness> -> 1 | 0   (TRIAGE_HEALTH_GATE, default 1)
# Kill switch: the `switch.triage-health-off` settings row, or
# flags/triage-health-off when no row exists (BH-2437, read through lane_switch).
triage_health_on() {
  local h="${1:-${HARNESS:-${H:-}}}"
  command -v lane_switch >/dev/null 2>&1 || . "$(dirname "${BASH_SOURCE[0]}")/lane-switch.sh" 2>/dev/null \
    || lane_switch() { [ -n "${HARNESS:-${H:-}}" ] && [ -f "${HARNESS:-${H:-}}/flags/$1" ]; }
  [ -n "$h" ] && HARNESS="$h" lane_switch triage-health-off && { printf '0'; return 0; }
  case "${TRIAGE_HEALTH_GATE:-1}" in 0|no|off|false) printf '0' ;; *) printf '1' ;; esac
}

# triage_health_needs_board <gate-reason> -> rc 0 when this tick's work is
#   reading the board, which is what an unhealthy board/repo makes worthless
#   (#2294 review S1). A queue, split-chain, results or remote-results tick
#   works from local records the gate already fired on, and proceeds.
triage_health_needs_board() {
  case "$(_tt_reason "${1:-}")" in
    board-changed|daily-sweep|event-wake|no-gate-state|gate-fetch-failed|gate-error|unknown-project) return 0 ;;
  esac
  return 1
}

_th_dir() { local d="${1:-}/state/triage-health"; mkdir -p "$d" 2>/dev/null || return 1; printf '%s' "$d"; }

# triage_health_note <harness> <project> <gate-decision>
#   Feeds the gate's own answer into the board-fetch streak. ONLY a real fetch
#   failure (`RUN gate-fetch-failed`) bumps it — `RUN gate-error` is the gate
#   script itself dying, which says nothing about the board (#2294 review S4).
#   An answer that could only come from a board read that WORKED resets it;
#   everything else never fetched and is neutral.
triage_health_note() {
  local h="${1:-}" p="${2:-}" dec="${3:-}" d f n
  [ -n "$h" ] && [ -n "$p" ] || return 0
  d=$(_th_dir "$h") || return 0
  f="$d/$p.fetchfail"
  case "$dec" in
    "RUN gate-fetch-failed"*)
      n=$(head -1 "$f" 2>/dev/null); n=$(_tt_num "$n" 0)
      printf '%s\n%s\n' "$((n + 1))" "$(_tt_now)" > "$f" 2>/dev/null ;;
    "RUN board-changed"*|"SKIP no-change"*|"SKIP self-writes-only"*|"SKIP sweep-unchanged"*)
      rm -f "$f" 2>/dev/null ;;
  esac
  return 0
}

# triage_health_check <harness> <project>
#   rc 0 -> healthy (or the gate is off, or the facts could not be read — FAIL
#           OPEN: a check that cannot see must never be the thing that stops a
#           lane). rc 1 + one line of reason -> unhealthy.
#
#   has_repo  fleet.conf names a repo — and, with TRIAGE_HEALTH_NEED_CLONE=1,
#             its checkout is on this box. The checkout half ships OFF (default
#             0): bin/run-triage.sh documents that triage runs without a
#             checkout (WORKDIR falls back to $HARNESS), and a box that relies
#             on that must not lose its triage to a default nobody verified on
#             it. Turn it on per project once the checkout is confirmed.
#   has_board fleet.conf names a board: an in-app prefix WITH a base URL, or
#             `-` (the GitHub-Issues board, which is the repo's issues).
#   fetch     the gate's board fetch failed TRIAGE_HEALTH_FETCH_FAILS (default
#             3, 0 = off) consecutive times. The gate fails OPEN on that — it
#             prints RUN and buys a session — so a dead board is exactly the
#             one that pays every tick. ONE re-probe (bin/triage-gate.sh
#             --pending, a board read, no model) is spent before the verdict,
#             and an answer heals the project at once.
#   down      state/triage-health/<p>.down: an operator (or any future probe)
#             writes the reason into it. There is deliberately NO read of
#             state/claude-auth-down.txt (#2294 review I2): that file holds
#             short labels (`small`, `hub`, `<box>-openrouter`) and lives only on
#             the hub, so it could never match a box. Carrying the hub's auth
#             verdict to the boxes as a per-project .down marker is follow-up
#             work in the auth lane.
triage_health_check() {
  local h="${1:-}" p="${2:-}" fc repo bp prod need n cap d f
  [ -n "$h" ] && [ -n "$p" ] || return 0
  [ "$(triage_health_on "$h")" = 1 ] || return 0
  fc="$h/bin/fleet-conf.sh"
  if [ -x "$fc" ] && "$fc" --projects >/dev/null 2>&1; then
    if ! "$fc" --projects 2>/dev/null | grep -qxF -- "$p"; then
      printf 'has_repo=false has_board=false: %s is not in fleet.conf\n' "$p"; return 1
    fi
    repo=$("$fc" "$p" repo 2>/dev/null); bp=$("$fc" "$p" board_prefix 2>/dev/null); prod=$("$fc" "$p" prod 2>/dev/null)
    case "$repo" in ''|-) printf 'has_repo=false: fleet.conf names no repo for %s\n' "$p"; return 1 ;; esac
    if [ -z "$bp" ]; then
      printf 'has_board=false: fleet.conf names no board for %s\n' "$p"; return 1
    fi
    if [ "$bp" != - ]; then
      case "$prod" in ''|-) printf 'has_board=false: %s has board prefix %s but no base URL in fleet.conf\n' "$p" "$bp"; return 1 ;; esac
    fi
    case "${TRIAGE_HEALTH_NEED_CLONE:-0}" in 1|yes|on|true) need=1 ;; *) need=0 ;; esac
    if [ "$need" = 1 ] && [ ! -e "${REPOS_ROOT:-/root/repos}/$p/.git" ]; then
      printf 'has_repo=false: no checkout of %s at %s on this box\n' "$repo" "${REPOS_ROOT:-/root/repos}/$p"; return 1
    fi
  fi
  if d=$(_th_dir "$h"); then
    f="$d/$p.down"
    if [ -s "$f" ]; then
      printf 'marked down: %s\n' "$(head -1 "$f" | cut -c1-200)"; return 1
    fi
    cap=$(_tt_num "${TRIAGE_HEALTH_FETCH_FAILS:-3}" 3)
    n=$(head -1 "$d/$p.fetchfail" 2>/dev/null); n=$(_tt_num "$n" 0)
    if [ "$cap" -gt 0 ] && [ "$n" -ge "$cap" ]; then
      if [ -x "$h/bin/triage-gate.sh" ] && "$h/bin/triage-gate.sh" "$p" --pending >/dev/null 2>&1; then
        rm -f "$d/$p.fetchfail" 2>/dev/null
      else
        printf 'board fetch failed on %s consecutive gate ticks and the re-probe did not answer\n' "$n"; return 1
      fi
    fi
  fi
  return 0
}

# triage_health_warn_once <harness> <project> <reason> <alerts-file>
#   The hold goes to the WARN DIGEST through bin/lane-alert.sh
#   --id triage-health:<p> (#2294 review S3) — a batched line, not a triaged
#   page — and only once per project per UTC day (the flag spares a lane-alert
#   spawn on every held tick). A box without lane-alert.sh, or one whose call
#   fails, writes the raw ALERTS.log line instead, so the hold is never silent.
#   An empty <harness> stamps no flag and runs no lane-alert.sh; the raw line
#   still goes to <alerts-file> when one is given, on every held tick (BH-2650).
triage_health_warn_once() {
  local h="${1:-}" p="${2:-}" r="${3:-}" a="${4:-}" flag msg
  if [ -n "$h" ]; then
    flag="$h/flags/alerted-triage-health-$p-$(date -u +%Y%m%d)"
    [ -e "$flag" ] && return 0
    mkdir -p "$h/flags" 2>/dev/null; : > "$flag" 2>/dev/null
  fi
  msg="[$p] paid triage held: $r. Ticks that need the board skip until this clears (queue, results and forced ticks still run). Fix the board/repo, or set TRIAGE_HEALTH_GATE=0 (lane.run-triage.$p.triage_health_gate)."
  if [ -n "$h" ] && [ -x "$h/bin/lane-alert.sh" ] \
     && "$h/bin/lane-alert.sh" --id "triage-health:$p" --severity warn triage "$msg" >/dev/null 2>&1; then
    return 0
  fi
  [ -n "$h" ] || [ -n "$a" ] || return 0
  mkdir -p "$(dirname "$a")" 2>/dev/null
  printf '%s WARN [triage-health] %s (bin/lane-alert.sh did not run)\n' "$(date -u '+%Y-%m-%d %H:%M:%SZ')" "$msg" >> "$a"
}

# ============================================================================
# THROTTLE
# ============================================================================

_tt_ledger() { printf '%s/state/triage-throttle/%s.runs' "${1:-}" "${2:-}"; }
_tt_on() { # rc 0 when either knob is set for this project
  [ "$(_tt_num "${TRIAGE_MIN_INTERVAL_S:-0}" 0)" -gt 0 ] || [ "$(_tt_num "${TRIAGE_MAX_RUNS_DAY:-0}" 0)" -gt 0 ]
}

# triage_throttle_check <harness> <project> <gate-reason>
#   rc 0 -> allowed. NOTHING is recorded here (#2294 review I3): a tick the
#           gate lets through can still end without buying anything (scope.sh's
#           "event-wake named no board object", a shard pass that dispatched
#           nothing), and a ceiling slot must only ever be a paid launch.
#   rc 1 + one line -> held.
triage_throttle_check() {
  local h="${1:-}" p="${2:-}" r ivl max now kept n last
  r=$(_tt_reason "${3:-}")
  [ -n "$h" ] && [ -n "$p" ] || return 0
  case "$r" in forced|forced-env|daily-sweep|no-gate-state|event-wake) return 0 ;; esac
  ivl=$(_tt_num "${TRIAGE_MIN_INTERVAL_S:-0}" 0)
  max=$(_tt_num "${TRIAGE_MAX_RUNS_DAY:-0}" 0)
  [ "$ivl" -gt 0 ] || [ "$max" -gt 0 ] || return 0
  now=$(_tt_now)
  kept=$(awk -v c="$((now - 86400))" '/^[0-9]+$/ && $1 > c {print $1}' "$(_tt_ledger "$h" "$p")" 2>/dev/null)
  n=$(printf '%s' "$kept" | grep -c .)
  last=$(printf '%s\n' "$kept" | sort -n | tail -1); last=$(_tt_num "$last" 0)
  if [ "$max" -gt 0 ] && [ "$n" -ge "$max" ]; then
    printf 'throttle ceiling: %s paid triage ticks in 24h (TRIAGE_MAX_RUNS_DAY=%s)\n' "$n" "$max"
    return 1
  fi
  if [ "$ivl" -gt 0 ] && [ "$last" -gt 0 ] && [ $((now - last)) -lt "$ivl" ]; then
    printf 'throttle cadence: last paid tick %sm ago, interval %sm (TRIAGE_MIN_INTERVAL_S=%s); next at +%sm\n' \
      "$(( (now - last) / 60 ))" "$(( ivl / 60 ))" "$ivl" "$(( (ivl - now + last + 59) / 60 ))"
    return 1
  fi
  return 0
}

# triage_throttle_record <harness> <project>
#   The ledger write, at the PAID LAUNCH: bin/lib/rt/launch.sh:rt_launch
#   immediately before the agent call, and bin/lib/rt/shards.sh when a tick
#   dispatched at least one shard. One row per paid tick, persisted BEFORE the
#   spend (a session that dies still counted). Pruned to 24h on every write.
#   Only a throttled project keeps a ledger: with both knobs off there is
#   nothing to decide later, and a file per project per tick is noise.
triage_throttle_record() {
  local h="${1:-}" p="${2:-}" f now kept
  [ -n "$h" ] && [ -n "$p" ] || return 0
  _tt_on || return 0
  f=$(_tt_ledger "$h" "$p"); now=$(_tt_now)
  kept=$(awk -v c="$((now - 86400))" '/^[0-9]+$/ && $1 > c {print $1}' "$f" 2>/dev/null)
  mkdir -p "$(dirname "$f")" 2>/dev/null || return 0
  { [ -n "$kept" ] && printf '%s\n' "$kept"; printf '%s\n' "$now"; } > "$f" 2>/dev/null
  return 0
}

# triage_precondition <harness> <project> <gate-decision>
#   The one call rt_gate makes after the gate said RUN. rc 0 -> go on to the
#   launch. rc 1 + "health: <why>" / "throttle …" -> hold it. Health first, so a
#   project that cannot build never spends its throttle budget, and only on the
#   reasons that need the board (S1).
triage_precondition() {
  local h="${1:-}" p="${2:-}" dec="${3:-}" r why
  r=$(_tt_reason "$dec")
  case "$r" in forced|forced-env) return 0 ;; esac
  if triage_health_needs_board "$dec" && ! why=$(triage_health_check "$h" "$p"); then
    printf 'health: %s\n' "$why"; return 1
  fi
  why=$(triage_throttle_check "$h" "$p" "$dec") || { printf '%s\n' "$why"; return 1; }
  return 0
}
