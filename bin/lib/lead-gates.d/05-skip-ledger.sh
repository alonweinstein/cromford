#!/bin/bash
# shellcheck shell=bash
# bin/lib/lead-gates.d/05-skip-ledger.sh — what the worklist gates share. It
# defines no gate. Sourced by bin/lib/lead-gates.sh, never run.
#   lgs_skip_once <slug> <n> <head> <class> <text>
#       logs `[skip <class>] <slug>#<n> @<h12> <text>` once per (slug, PR,
#       head12, class). The marker is state/lead-review/gate-skip/<safe>-<n>-
#       <h12>-<class>, written BEFORE the line. A marker that cannot be written
#       still logs, and says the line may log again. No harness root: logs
#       every time.
#   lgs_dir     prints this process's scratch dir, ${TMPDIR:-/tmp}/lead-gates.<pid>
#       as it was when the loader sourced this file (the tick's main shell). A
#       review worker is a fork with its own TMPDIR, so the path is fixed here
#       and the worker reads the same dir. rc 1 when it cannot be made.
#   lg_tick_skip_ledger <slug>   once a process: markers older than 7 days are
#       deleted, and so are other processes' scratch dirs older than 1 day.

declare -g _LGS_PRUNED="" _LGS_DIR="${TMPDIR:-/tmp}/lead-gates.$$"

lgs_dir() {
  [ -d "$_LGS_DIR" ] || mkdir -p "$_LGS_DIR" 2>/dev/null || return 1
  printf '%s\n' "$_LGS_DIR"
}

lgs_skip_once() {
  local slug="$1" n="$2" h12="${3:0:12}" class="$4" text="$5" root="${HARNESS:-${H:-}}" safe mark line
  line="[skip $class] $slug#$n @$h12 $text"
  if [ -z "$root" ]; then _lgt_log "$line"; return 0; fi
  safe=$(printf '%s' "${slug//\//_}" | tr -cd 'A-Za-z0-9._-')
  mark="$root/state/lead-review/gate-skip/$safe-$n-$h12-$class"
  [ -e "$mark" ] && return 0
  if mkdir -p "${mark%/*}" 2>/dev/null && : > "$mark" 2>/dev/null; then
    _lgt_log "$line"
  else
    _lgt_log "$line (the skip marker could not be written; this may log again)"
  fi
  return 0
}

lg_tick_skip_ledger() {
  local root="${HARNESS:-${H:-}}"
  [ -n "$_LGS_PRUNED" ] && return 0
  _LGS_PRUNED=1
  [ -n "$root" ] && [ -d "$root/state/lead-review/gate-skip" ] \
    && find "$root/state/lead-review/gate-skip" -type f -mtime +7 -delete 2>/dev/null
  find "${_LGS_DIR%/*}" -maxdepth 1 -type d -name 'lead-gates.*' ! -name "${_LGS_DIR##*/}" -mmin +1440 \
    -exec rm -rf {} + 2>/dev/null
  return 0
}
