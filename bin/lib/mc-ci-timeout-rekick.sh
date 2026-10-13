#!/bin/bash
# bin/lib/mc-ci-timeout-rekick.sh — A RERUN NEVER SEES THE FIXED WORKFLOW
# (BH-3787, slice 4 of BH-3775). Sourced by bin/lib/mc-ci-timeout.sh after its
# fail-open stubs, so cit_rekick_step below replaces the stub. Never executed.
#
# THE CASE. A required check dies at its `timeout-minutes`, the repo fixes the
# workflow file on the base branch, and the BH-636 ladder re-runs the dead run.
# A rerun keeps the run's old merge ref AND its old workflow file, so it dies
# the same way, the ladder pages CI_FLAKE_TWICE and the PR sits in WAIT_CI for
# a fix that has already landed. Only a fresh `pull_request` event reads the new
# file, and a close/reopen (mc_kick_ci) is the event this conductor can fire.
#
# ONCE PER HEAD. The `citkick <key> <head>` mark is written BEFORE the kick, so
# a crash, a HOLD or a refused close never buys a second one on the same head.
# A new head is a new key and may be kicked once more.
#
# FAIL OPEN. A read that fails, a date that does not parse or a mark already
# spent leaves the ladder exactly as BH-636 runs it. Only a kick that landed
# sets CIT_SKIP_RUNG=1. No raw gh here: the read is gh_rest, the write is
# mc_kick_ci.

# _cit_epoch <iso> — the epoch of an ISO time, GNU date then BSD date; rc 1 and
#   nothing printed when neither parses it (an empty date is never epoch 0).
_cit_epoch() {
  local e
  [ -n "${1:-}" ] || return 1
  e=$(date -u -d "$1" +%s 2>/dev/null) || e=""
  [ -n "$e" ] || e=$(date -u -j -f "%Y-%m-%dT%H:%M:%SZ" "$1" +%s 2>/dev/null) || e=""
  case "$e" in ''|*[!0-9]*) return 1 ;; esac
  printf '%s' "$e"
}

# _cit_wf_read <slug> <base> <wfpath> — prints the epoch of the newest commit on
#   <base> touching <wfpath>, or `-` for a failed, empty or unparseable read.
_cit_wf_read() {
  local out="" d e
  mc_rest_var out gh_rest GET "repos/$1/commits?sha=$2&path=$3&per_page=1" </dev/null || { printf -; return 0; }
  d=$(printf '%s' "$out" | jq -r '.[0].commit.committer.date // empty' 2>/dev/null)
  e=$(_cit_epoch "$d") || { printf -; return 0; }
  printf '%s' "$e"
}

# cit_wf_changed_since <slug> <base> <wfpath> <since-iso> — rc 0 when <base>
#   has a commit touching <wfpath> strictly AFTER <since-iso>; rc 1 otherwise,
#   and on any read or parse failure. One read per (slug, base, path) per tick:
#   the answer (a failure too, as `-`) is cached in the tick's own file under a
#   flock, so parallel pr_workers of one repo share it. The tick id is in the
#   name because MC_TICK_DIR outlives the tick (mc_tick_gc prunes after a day),
#   and a base fix must be seen on the very next tick. No MC_TICK_ID, no cache.
cit_wf_changed_since() {
  local slug="${1:-}" base="${2:-}" wf="${3:-}" since_e wf_e f
  [ -n "$slug" ] && [ -n "$base" ] && [ -n "$wf" ] || return 1
  # Everything below goes into a URL unencoded; anything unusual is not read.
  case "$slug$base$wf" in *[!A-Za-z0-9._/-]*) return 1 ;; esac
  since_e=$(_cit_epoch "${4:-}") || return 1
  if [ -n "${MC_TICK_ID:-}" ] && [ -n "${MC_TICK_DIR:-}" ] && mkdir -p "$MC_TICK_DIR" 2>/dev/null; then
    f="$MC_TICK_DIR/$(mc_safe_name "$MC_TICK_ID").cit-wfhead-$(mc_safe_name "$slug")-$(mc_safe_name "$base")-$(mc_safe_name "$wf")"
    wf_e=$( ( flock 9 || exit 1
              [ -s "$f" ] || _cit_wf_read "$slug" "$base" "$wf" > "$f"
              cat "$f" ) 9>>"$f.lock" 2>/dev/null )
  else
    wf_e=$(_cit_wf_read "$slug" "$base" "$wf")
  fi
  case "$wf_e" in ''|*[!0-9]*) return 1 ;; esac
  [ "$wf_e" -gt "$since_e" ]
}

# cit_rekick_step <slug> <key> <head> <base> <num> <flake-runs> — the contract
#   hook. Sets CIT_REKICK=1 when a CIT_TIMEOUTS line's workflow changed on base
#   after its run started, and CIT_SKIP_RUNG=1 only when the close/reopen
#   landed. Always rc 0 once it has decided: a non-0 would make cit_assess reset
#   the globals over a kick that already happened.
# shellcheck disable=SC2034  # CIT_REKICK / CIT_SKIP_RUNG are cit_assess's answer
cit_rekick_step() {
  local slug="${1:-}" key="${2:-}" head="${3:-}" base="${4:-}" num="${5:-}"
  local rid check wf t started hit_check="" hit_wf="" why
  [ -n "$slug" ] && [ -n "$key" ] && [ -n "$head" ] && [ -n "$num" ] || return 0
  command -v mc_kick_ci >/dev/null 2>&1 && command -v mc_attempt_put >/dev/null 2>&1 || return 0
  # shellcheck disable=SC2034  # rid and t are fields of the line, not used here
  while IFS=$'\t' read -r rid check wf t started; do
    [ -n "$wf" ] || continue
    if cit_wf_changed_since "$slug" "$base" "$wf" "$started"; then hit_check=$check; hit_wf=$wf; break; fi
  done <<<"$CIT_TIMEOUTS"
  [ -n "$hit_wf" ] || return 0
  CIT_REKICK=1
  mc_attempt_has "citkick $key $head" 2>/dev/null && return 0
  why="($hit_check: $hit_wf changed on $base after the run)"
  if [ "${ACTIONS:-0}" != 1 ]; then
    mc_log "$key would kick ${head:0:8} $why — observe mode: nothing written"
    return 0
  fi
  mc_attempt_put "citkick $key $head"
  if mc_kick_ci "$slug" "$num"; then
    mc_log "CI_TIMEOUT_REKICK $key $head $why — close/reopen for a fresh pull_request run on the new workflow file; a rerun would reuse the old merge ref"
    CIT_SKIP_RUNG=1
  elif [ "${MC_KICK_CLOSED:-0}" = 1 ]; then
    mc_log "CI_TIMEOUT_REKICK failed $key $head — close landed, reopen failed (MC_KICK_CLOSED=1, already paged)"
  else
    mc_log "CI_TIMEOUT_REKICK failed $key $head — held or refused, PR kept (MC_KICK_CLOSED=0)"
  fi
  return 0
}
