#!/bin/bash
# shellcheck shell=bash
# bin/lib/box-ops-fly.sh — BH-2518/BH-2661: the Fly machine ops a box_commands
# row asks for. Sourced, never executed; sourcing defines functions and nothing
# else. Each verb prints exactly one detail line on stdout and returns 0 for ok,
# 1 for fail or refused.
#
#   box_ops_fly_stop    <machine_id> <project> <app>
#   box_ops_fly_destroy <machine_id> <project> <app>
#
# Before any `fly` call both verbs refuse unless: the id matches
# ^[0-9a-z]{8,32}$, the project is an exact line of `bin/fleet-conf.sh
# --projects`, the app is the project's builder app (state/fly/<p>.json .app)
# or pool app (flags/fly-pool-app-<p>), and FLY_API_TOKEN_<P> is set in the
# environment or in env/fly.env. The token rides each flyctl call as a
# FLY_ACCESS_TOKEN prefix; the caller's environment is never changed.
#
# The root is HARNESS, then the caller's H, else none (BH-2613,
# docs/notes/2026-09-26-BH-2613-lib-root-resolution.md): bin/box-ops.sh owns
# the /root/harness default and exports HARNESS. With no root both verbs answer
# "refused: no harness root" before any call; no path is built from it.
#
# stop reads the state with bin/fly-machine-state.sh, which only asks the pool
# app, so stop is refused for the builder app. Already stopped is ok with no
# call; otherwise it is ok only when the read-back after `machine stop` says
# stopped. destroy refuses the builder machine and any machine a pool job
# record in state/fly-pool/<p>/ names; it is ok on rc 0 or on flyctl's
# not-found answer (the same match as destroy_machine in bin/fly-pool.sh).

_box_ops_fly_trim() { # stdin → one line, at most 300 chars
  tr '\n\r\t' '   ' | cut -c1-300
}

# _box_ops_fly_check <mid> <project> <app> — rc 0 sets _BOF_H _BOF_TOKEN
# _BOF_FLY _BOF_POOL_APP; rc 1 has printed the refused/not configured line.
_box_ops_fly_check() {
  # The root is read before the locals: a `local H` would hide the caller's H.
  local root="${HARNESS:-${H:-}}"
  local mid="${1:-}" p="${2:-}" app="${3:-}" H projects state_app pool_app tv tok fly
  H="$root"
  [[ "$mid" =~ ^[0-9a-z]{8,32}$ ]] || { echo "refused: bad machine id"; return 1; }
  [ -n "$p" ] || { echo "refused: unknown project"; return 1; }
  [ -n "$H" ] || { echo "refused: no harness root"; return 1; }
  projects=$("$H/bin/fleet-conf.sh" --projects 2>/dev/null) || { echo "refused: unknown project $p"; return 1; }
  grep -Fxq -- "$p" <<<"$projects" || { echo "refused: unknown project $p"; return 1; }
  state_app=$(jq -r '.app // ""' "$H/state/fly/$p.json" 2>/dev/null) || state_app=""
  if declare -F routing_pool_app >/dev/null; then
    pool_app=$(routing_pool_app "$p" 2>/dev/null) || pool_app=""
  else
    pool_app=$(cat "$H/flags/fly-pool-app-$p" 2>/dev/null) || pool_app=""
  fi
  if [ -z "$app" ] || { [ "$app" != "$state_app" ] && [ "$app" != "$pool_app" ]; }; then
    echo "refused: app $app is not an app of $p"; return 1
  fi
  tv="FLY_API_TOKEN_$(printf '%s' "$p" | tr '[:lower:].-' '[:upper:]__')"
  [[ "$tv" =~ ^[A-Z0-9_]+$ ]] || { echo "refused: unknown project $p"; return 1; }
  tok="${!tv:-}"
  if [ -z "$tok" ]; then # fly.env, read in a subshell so the caller's env is untouched
    # shellcheck disable=SC1090,SC1091
    tok=$( . "$H/bin/lib/env-path.sh" 2>/dev/null || . "${BASH_SOURCE[0]%/*}/env-path.sh" 2>/dev/null || exit 0
           set -a; . "$(harness_env_dir "$H")/fly.env" >/dev/null 2>&1; printf '%s' "${!tv:-}" )
  fi
  [ -n "$tok" ] || { echo "not configured: $tv"; return 1; }
  fly=$(PATH="$PATH:/root/.fly/bin"; command -v fly || command -v flyctl) || fly=""
  [ -n "$fly" ] || { echo "not configured: flyctl"; return 1; }
  _BOF_H="$H"; _BOF_TOKEN="$tok"; _BOF_FLY="$fly"; _BOF_POOL_APP="$pool_app"
}

box_ops_fly_stop() {
  local mid="${1:-}" p="${2:-}" app="${3:-}" state out rc
  _box_ops_fly_check "$mid" "$p" "$app" || return 1
  [ "$app" = "$_BOF_POOL_APP" ] || { echo "refused: stop read-back only covers the pool app"; return 1; }
  state=$("$_BOF_H/bin/fly-machine-state.sh" "$p" "$mid" 2>/dev/null)
  [ "$state" = stopped ] && { echo "already stopped"; return 0; }
  out=$(FLY_ACCESS_TOKEN="$_BOF_TOKEN" timeout 60 "$_BOF_FLY" machine stop "$mid" -a "$app" 2>&1); rc=$?
  [ "$rc" = 124 ] && out="timeout after 60s"
  state=$("$_BOF_H/bin/fly-machine-state.sh" "$p" "$mid" 2>/dev/null)
  [ "$state" = stopped ] && { echo stopped; return 0; }
  echo "fail: state=$(printf '%s' "${state:-unknown}" | _box_ops_fly_trim) rc=$rc: $(printf '%s' "$out" | _box_ops_fly_trim)"
  return 1
}

box_ops_fly_destroy() {
  local mid="${1:-}" p="${2:-}" app="${3:-}" builder f m out rc
  _box_ops_fly_check "$mid" "$p" "$app" || return 1
  if [ -f "$_BOF_H/state/fly/$p.json" ]; then
    builder=$(jq -r '.machine_id // ""' "$_BOF_H/state/fly/$p.json" 2>/dev/null) \
      || { echo "refused: cannot read builder state"; return 1; }
    [ "$mid" = "$builder" ] && { echo "refused: $p builder machine"; return 1; }
  fi
  for f in "$_BOF_H/state/fly-pool/$p"/*.json; do
    case "${f##*/}" in .*) continue ;; esac   # .sweep.json even under dotglob
    [ -f "$f" ] || continue
    m=$(jq -r '.machine // ""' "$f" 2>/dev/null) || { echo "refused: cannot read pool record $f"; return 1; }
    if [ "${f##*/}" = "$mid.json" ] || [ "$m" = "$mid" ]; then
      echo "refused: live pool job $f"; return 1
    fi
  done
  out=$(FLY_ACCESS_TOKEN="$_BOF_TOKEN" timeout 60 "$_BOF_FLY" machine destroy "$mid" -a "$app" --force 2>&1); rc=$?
  [ "$rc" = 0 ] && { echo destroyed; return 0; }
  case "$out" in
    *"was not found in app"*|*"not found"*|*"Could not find"*) echo "already gone"; return 0 ;;
  esac
  [ "$rc" = 124 ] && out="timeout after 60s"
  echo "fail: rc=$rc: $(printf '%s' "$out" | _box_ops_fly_trim)"
  return 1
}
