#!/bin/bash
# bin/lib/inapp-deps.sh — BH-3946: in-app boards hold and release tickets on
# their `Blocked by` text lines. Sourced, never executed. Defines functions
# only, then sources the two part files below: no `set -e`, nothing runs on
# source, safe under the caller's `set -u`.
#
# THIS IS THE CONTRACT SLICE (BH-3962). Every work function in the part files
# is a STUB with its final signature and a no-op answer, so after this lands
# every gate answer, tick reason and scope line is byte-for-byte what it was.
# The sibling slices of BH-3946 fill bin/lib/inapp-deps/core.sh and
# bin/lib/inapp-deps/release.sh and touch nothing else.
#
# WHY. An in-app board has no dependency primitive (no board serves `blocked`
# yet, BH-815), so a ticket whose description says `Blocked by TK-201` is
# buildable to bin/triage-gate.sh --buildable, and nothing wakes the tick when
# TK-201 merges. bin/unblocked-children.sh covers only GitHub-Issues boards.
#
# THE THREE HOOK POINTS (each checks the function is defined and the switch is
# not held, so a box mid-sync without this lib is today exactly):
#   bin/triage-gate.sh buildable_gate — when the board served no `blocked`
#     boolean, the raw ticket (in a temp file) goes to inapp_deps_buildable;
#     a non-empty first line is the answer.
#   bin/triage-gate.sh step 1e — inapp_deps_gate printing anything answers
#     `RUN inapp-deps-ready`.
#   bin/lib/rt/scope.sh inapp_released_lines — inapp_deps_take_lines output is
#     appended after the gate-release lines.
#
# STATE (box-local; nothing in this slice writes any of it):
#   state/inapp-deps/<p>/          inapp_deps_state_dir — the siblings' watermarks
#   state/inapp-deps-ready-<p>     inapp_deps_ready_file — one-shot, consumed by
#     the tick scope; step 1e deletes it unread once older than
#     INAPP_DEPS_REMIND_S.
#
# KNOBS (catalog/lanes.d/_lib.inapp-deps.json `inapp-deps`, resolved through
# lib_env_apply; the numbers below are the documented fallback only):
#   INAPP_DEPS_REMIND_S (21600)  INAPP_DEPS_MAX_LOOKUPS (10) — by-id reads per pass
# KILL SWITCH: inapp-deps-off, read by lane_switch (bin/lib/lane-switch.sh): a
# settings row switch.inapp-deps-off[.<box>] answers first, and
# flags/inapp-deps-off only when there is no row. ON = all three hooks inert.
#
# ROOT. inapp_deps_on, inapp_deps_state_dir and inapp_deps_ready_file take the
# harness root as their first argument, else $HARNESS, else $H. With none they
# build no path: the two path functions return 1 and inapp_deps_on prints 0
# (BH-2613).
# shellcheck shell=bash

_ID_LIBDIR=$(dirname "${BASH_SOURCE[0]}")
_ID_APPLIED=0

# _inapp_deps_knobs — sets INAPP_DEPS_REMIND_S/INAPP_DEPS_MAX_LOOKUPS in THIS
# shell. The settings contract is applied once per process (the _sc_knobs idiom).
_inapp_deps_knobs() {
  if [ "$_ID_APPLIED" = 0 ]; then
    _ID_APPLIED=1
    if ! command -v lib_env_apply >/dev/null 2>&1; then
      # shellcheck source=bin/lib/lane-gate.sh
      [ -r "$_ID_LIBDIR/lane-gate.sh" ] && . "$_ID_LIBDIR/lane-gate.sh"
    fi
    command -v lib_env_apply >/dev/null 2>&1 && lib_env_apply inapp-deps
  fi
  INAPP_DEPS_REMIND_S="${INAPP_DEPS_REMIND_S:-21600}"
  INAPP_DEPS_MAX_LOOKUPS="${INAPP_DEPS_MAX_LOOKUPS:-10}"
  case "$INAPP_DEPS_REMIND_S" in ''|*[!0-9]*) INAPP_DEPS_REMIND_S=21600 ;; esac
  case "$INAPP_DEPS_MAX_LOOKUPS" in ''|*[!0-9]*) INAPP_DEPS_MAX_LOOKUPS=10 ;; esac
  return 0
}

# inapp_deps_on <harness> -> prints 1 (feature on) or 0 (switch held, or no
# root: off is today's behaviour, so it is the answer, rc 0)
inapp_deps_on() {
  local root="${1:-${HARNESS:-${H:-}}}"
  [ -n "$root" ] || { echo 0; return 0; }
  command -v lane_switch >/dev/null 2>&1 || . "$_ID_LIBDIR/lane-switch.sh" 2>/dev/null \
    || lane_switch() { [ -f "${HARNESS:-}/flags/$1" ]; }
  if HARNESS="$root" lane_switch inapp-deps-off file; then echo 0; else echo 1; fi
}

# inapp_deps_state_dir <harness> <project> -> prints state/inapp-deps/<p>
inapp_deps_state_dir() {
  local h="${1:-${HARNESS:-${H:-}}}" p="${2:-}"
  [ -n "$h" ] && [ -n "$p" ] || return 1
  printf '%s\n' "$h/state/inapp-deps/$p"
}

# inapp_deps_ready_file <harness> <project> -> prints state/inapp-deps-ready-<p>
inapp_deps_ready_file() {
  local h="${1:-${HARNESS:-${H:-}}}" p="${2:-}"
  [ -n "$h" ] && [ -n "$p" ] || return 1
  printf '%s\n' "$h/state/inapp-deps-ready-$p"
}

# The part files, wherever this lib is sourced. A missing one leaves its
# functions undefined, which every hook reads as "no lib".
# shellcheck source=bin/lib/inapp-deps/core.sh
[ -r "$_ID_LIBDIR/inapp-deps/core.sh" ] && . "$_ID_LIBDIR/inapp-deps/core.sh"
# shellcheck source=bin/lib/inapp-deps/release.sh
[ -r "$_ID_LIBDIR/inapp-deps/release.sh" ] && . "$_ID_LIBDIR/inapp-deps/release.sh"
