#!/bin/bash
# shellcheck shell=bash
# bin/lib/conductor-mode.sh — BH-1201: the one reader of the merge conductor's mode.
# Source of truth is the D1 settings row merge-conductor.mode, never a flag file.
# `unknown` holds (fail closed on spend); a hold is re-offered next tick.

# conductor_mode — prints merge|actions|observe|kill-switch|unknown; always rc 0.
conductor_mode() {
  local v=""
  if command -v _lg_settings_refresh >/dev/null 2>&1; then
    _lg_settings_refresh
    v=$(_lg_setting_lookup merge-conductor.mode 2>/dev/null) || v=""
  elif command -v setting_get >/dev/null 2>&1; then
    v=$(setting_get merge-conductor.mode 2>/dev/null) || v=""
  fi
  case "$v" in
    merge|actions|observe|kill-switch) printf '%s' "$v" ;;
    *) printf 'unknown' ;;
  esac
}

# conductor_hold_active <lane-id> <KNOB_ENV> — rc 0 = hold, rc 1 = go; prints the mode.
# An explicit knob 0 opts the lane out, even under kill-switch; anything else reads as 1.
conductor_hold_active() {
  local id="${1:-}" env="${2:-}" m knob=""
  m=$(conductor_mode)
  printf '%s' "$m"
  if [ -n "$env" ]; then
    if command -v lane_knob >/dev/null 2>&1 && [ -n "$id" ]; then
      knob=$(lane_knob "$id" "$env" 2>/dev/null)
    else
      knob="${!env:-}"
    fi
  fi
  [ "$knob" = 0 ] && return 1
  case "$m" in
    kill-switch|observe|unknown) return 0 ;;
    *) return 1 ;;
  esac
}
