#!/bin/bash
# bin/lib/main-red-label.sh — BH-1770: ONE knob names the main-red label.
#
# THE DEFECT (#1142 item 6). Two names for one label, both defaulting to
# `fix-main-red`: every merge lane read MC_MAIN_RED_LABEL from its process env
# (bin/lib/main-red-gate.sh), and the build priority rank read MAIN_RED_LABEL
# from the env or env/global.env (main_red_label, bin/lib/hotfix-lib.sh). Set one
# without the other and a build ranks one PR as the main-red fix while every
# merge lane exempts a different one from the freeze; bin/lib/mc/train.sh had to
# guess which of the two somebody meant.
#
# THE CONTRACT. MC_MAIN_RED_LABEL is the one registered knob: the
# `main-red-label` lib in catalog/lanes.d/_lib.json, settings row
# `lib.main-red-label.mc_main_red_label`. MAIN_RED_LABEL is a DEPRECATED ALIAS,
# still honoured so no box that set it changes behaviour, and logged. Every
# reader asks main_red_label_resolve and nothing else:
#   1. the settings row, through bin/lib/lane-gate.sh's lib_env_apply — only
#      when the harness carries lane-gate.sh (a scratch tree that does not has
#      no row to read);
#   2. MC_MAIN_RED_LABEL in the process env;
#   3. MAIN_RED_LABEL in the process env              (alias, logged);
#   4. MC_MAIN_RED_LABEL in env/global.env;
#   5. MAIN_RED_LABEL in env/global.env               (alias, logged);
#   6. fix-main-red.
# The env beats the file because a lane that sourced env/global.env with
# `set -a` already has the file's values in its env; the file tier is for the
# readers that never source it (a build, a sourced predicate).
#
# THE LOG. When the alias decides the answer, or is set and disagrees with the
# canonical name that did, ONE line goes to logs/lane-gate.log through
# _lg_log_throttled (once an hour per box) — the log every other settings
# anomaly already goes to. Without lane-gate.sh there is nowhere shared to log
# it, and the answer is the same either way.
#
# THE COST. The row read is a lib_env_apply (lane-gate, the settings cache, jq
# over the registry). main_red_label_prime does it ONCE in the calling shell and
# keeps the row in _MRL_ROW_*, which every later $(...) inherits, so a lane that
# ranks a queue pays one read. The env and file tiers are read on every call:
# they are cheap, and a caller that changes the env between two calls must see
# the change.
#
# Sourced, never executed. Nothing runs on source. Safe under `set -u`.
# shellcheck shell=bash

MRL_DEFAULT=fix-main-red
_MRL_ROW_H="${_MRL_ROW_H:-}"
_MRL_ROW_V="${_MRL_ROW_V:-}"

# _mrl_home [harness] — the harness root this call answers for.
_mrl_home() { printf '%s' "${1:-${HARNESS:-${H:-/root/harness}}}"; }

# _mrl_file <harness> <VAR> — the value of VAR in env/global.env, READ and never
# sourced (hotfix-lib's _hotfix_env reason: a predicate must not inherit a
# box's secrets to answer a yes/no question). Quotes and blanks are stripped;
# the last assignment wins, as it would for the shell.
_mrl_file() {
  local f="$1/env/global.env"
  [ -r "$f" ] || return 0
  sed -n "s/^[[:space:]]*\(export[[:space:]]\{1,\}\)\{0,1\}$2=//p" "$f" 2>/dev/null \
    | tr -d '"'"'"' \t' | tail -1
}

# _mrl_row_read <harness> — the settings row, or nothing. In a subshell with the
# canonical name UNSET, so what comes back can only be a row lib_env_apply
# exported (the knob is not required, so with no row nothing is exported).
_mrl_row_read() {
  local h="$1" lg="$1/bin/lib/lane-gate.sh"
  [ -r "$lg" ] || return 0
  (
    unset MC_MAIN_RED_LABEL
    export HARNESS="$h"
    command -v lib_env_apply >/dev/null 2>&1 || . "$lg" >/dev/null 2>&1
    command -v lib_env_apply >/dev/null 2>&1 && lib_env_apply main-red-label >/dev/null 2>&1
    printf '%s' "${MC_MAIN_RED_LABEL:-}"
  )
}

# _mrl_row <harness> — the row, from the primed memo when it is this harness's.
_mrl_row() {
  if [ -n "$_MRL_ROW_H" ] && [ "$_MRL_ROW_H" = "$1" ]; then
    printf '%s' "$_MRL_ROW_V"; return 0
  fi
  _mrl_row_read "$1"
}

# _mrl_log <harness> <id> <line> — once an hour per box, through lane-gate.
_mrl_log() {
  local h="$1" lg="$1/bin/lib/lane-gate.sh"
  [ -r "$lg" ] || return 0
  (
    export HARNESS="$h"
    command -v _lg_log_throttled >/dev/null 2>&1 || . "$lg" >/dev/null 2>&1
    command -v _lg_log_throttled >/dev/null 2>&1 && _lg_log_throttled "$2" "$3"
  ) >/dev/null 2>&1
  return 0
}

# main_red_label_prime [harness] — read the settings row ONCE, in THIS shell.
# Always rc 0.
main_red_label_prime() {
  local h; h=$(_mrl_home "${1:-}")
  _MRL_ROW_V=$(_mrl_row_read "$h")
  _MRL_ROW_H="$h"
  return 0
}

# main_red_label_resolve [harness] -> the label, one line. Always prints a
# non-empty name and returns 0.
main_red_label_resolve() {
  local h v canon alias src
  h=$(_mrl_home "${1:-}")
  v=$(_mrl_row "$h")
  if [ -n "$v" ]; then printf '%s\n' "$v"; return 0; fi
  canon="${MC_MAIN_RED_LABEL:-}"; alias="${MAIN_RED_LABEL:-}"; src=env
  if [ -z "$canon" ] && [ -z "$alias" ]; then
    canon=$(_mrl_file "$h" MC_MAIN_RED_LABEL); alias=$(_mrl_file "$h" MAIN_RED_LABEL); src=env/global.env
  fi
  if [ -n "$canon" ]; then
    if [ -n "$alias" ] && [ "$alias" != "$canon" ]; then
      _mrl_log "$h" main-red-label-alias-conflict \
        "[main-red-label] MAIN_RED_LABEL=$alias ($src) is a deprecated alias and disagrees with MC_MAIN_RED_LABEL=$canon — MC_MAIN_RED_LABEL wins everywhere; delete the alias (BH-1770)"
    fi
    printf '%s\n' "$canon"; return 0
  fi
  if [ -n "$alias" ]; then
    _mrl_log "$h" main-red-label-alias \
      "[main-red-label] MAIN_RED_LABEL=$alias ($src) is a deprecated alias of MC_MAIN_RED_LABEL — honoured; rename it, or set the settings row lib.main-red-label.mc_main_red_label (BH-1770)"
    printf '%s\n' "$alias"; return 0
  fi
  printf '%s\n' "$MRL_DEFAULT"
}
