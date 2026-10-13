#!/bin/bash
# bin/lib/conf-row.sh — BH-2411 (BH-2320.C5): a flags/ CONFIG FILE is read
# through settings rows before the file. Sourced, never executed. No side effect
# at source time beyond defining functions; bin/lib/lane-gate.sh is sourced
# lazily, inside the first call, and only when this shell does not have it.
#
# WHY. Nine config files under flags/ (scheduler.conf, cost-caps.conf,
# lane-caps.conf, ledger-ttl.conf, slo.conf, alerts.conf, dora-digest.conf,
# determinism-lint.conf, readiness-levels.json) could only be changed by ssh,
# died with their box, and nobody could see from one place what a box ran on.
# lane_switch (bin/lib/lane-switch.sh) made the kill switches rows; this is the
# same move for the files.
#
# THE KEYS. `conf.<file>.<key>` for the fleet, `conf.<file>.<key>.<box>` for
# one box (box = _lg_box, lowercased), box row first. <file> is the basename
# without its extension; <key> is the resolver's own lookup key, lowercased
# (`conf.scheduler.overlap_threshold`), or `<directive>.<name>` in a directive
# file (`conf.cost-caps.budget.project-5` = `100 5`). readiness-levels.json is
# ONE document row, `conf.readiness-levels[.<box>]`, read with conf_row and an
# empty key. The VALUE is the rest of the line the file would carry; each
# resolver feeds it through its own validator, so a row never gets a looser
# parse than the file, and a row the validator refuses never overrides.
#
#   conf_rows <file> [harness]        `key<TAB>value` for every row under
#                                     conf.<file>., this box's rows applied over
#                                     the fleet's, sorted by key
#   conf_rows_seeded <file> [harness] `key<TAB>value` for every REGISTRY-SEED
#                                     row under conf.<file>. (the cache's
#                                     `seeded` map, never `values`), fleet keys
#                                     as written, sorted by key (BH-4155). Only
#                                     cost-budget.sh and lane-caps.sh read it:
#                                     those rows are the DB copy of their
#                                     catalog file, layered above it
#   conf_row <file> <key> [harness]   one value, rc 1 for no row; an empty key
#                                     reads the document row. Sets CONF_ROW_SRC
#                                     = box-row|fleet-row|none (in the calling
#                                     shell only: not through `$( )`)
#   conf_row_note_file <file> <flagsfile> <key...>
#                                     one throttled logs/lane-gate.log line when
#                                     rows answered and flags/<file> exists, so a
#                                     box-local edit that no longer decides is
#                                     visible
#   conf_row_refused <file> <key> <value> <flagsfile> [harness]
#                                     one throttled line naming a row the
#                                     resolver's validator refused (BH-2478): the
#                                     resolver then reads it as no row, so the
#                                     file answers
#   conf_rows_preload <file> [harness]
#                                     loads lane-gate and the rows of <file> into
#                                     the CALLING shell (BH-2478). A resolver that
#                                     is called as `$(…)` loses conf_row's memo
#                                     with the subshell; after one preload every
#                                     later `$(…)` inherits it and runs no jq.
#                                     Always rc 0, prints nothing
#
# WHAT A ROW CANNOT DO:
#   - hold a newline or a tab (logged, read as no row: it would split a line);
#   - be another box's row: keys ending in another box's name are not stripped,
#     so they reach the resolver as a key with one segment too many, which each
#     resolver's shape check drops (a ledger-ttl class `kind.stage` is the one
#     shape a box suffix can alias, and box names are not stage names);
#   - answer under LANE_GATE_DISABLE=1 (the same escape hatch as the gate).
#
# THE WORKER DOWN. The rows come from state/settings-cache.json after
# _lg_settings_refresh, the cache lane_knob and lane_switch already fill (one
# GET per 60 s per box, whoever reads first). An outage keeps the last cache at
# any age; no cache at all means no rows, i.e. the file, exactly as before a
# row existed. A harness with no bin/jobs-client.sh (a fixture tree) is never
# asked to refresh: its cache, if any, is read as it stands.
#
# A resolver whose fixture path is set ($COST_CAPS_CONF, $LANE_CAPS_CONF,
# $LEDGER_TTL_CONF, $SLO_CONF, $ALERTS_CONF, $DETERMINISM_LINT_CONF,
# $READINESS_LEVELS) reads no row: those mean "this file, as given".

_CR_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)"
declare -gA _CR_MEMO 2>/dev/null || true
declare -gA _CR_BOX_MEMO 2>/dev/null || true

# _cr_ready — lane-gate.sh's functions, sourced once, the caller's shell options
# kept: lane-gate's client loader sources bin/jobs-client.sh, which sets
# `-uo pipefail` at its top level, and alert-state.sh's callers run -u alone.
_cr_ready() {
  command -v _lg_settings_refresh >/dev/null 2>&1 && return 0
  local opts rc=0
  opts=$(set +o)
  # shellcheck source=lane-gate.sh
  . "$_CR_DIR/lane-gate.sh" >/dev/null 2>&1 || rc=1
  eval "$opts" 2>/dev/null
  [ "$rc" = 0 ] && command -v _lg_settings_refresh >/dev/null 2>&1
}

_cr_refresh() {
  local opts
  command -v _jobs_req >/dev/null 2>&1 || [ -r "$(_lg_h)/bin/jobs-client.sh" ] || return 0
  opts=$(set +o)
  _lg_settings_refresh
  eval "$opts" 2>/dev/null
  return 0
}

_cr_box() { _lg_box | tr '[:upper:]' '[:lower:]'; }

# _cr_load <file> — fills _CR_MEMO["<harness>|<file>"] with `key<TAB>src<TAB>value`
# lines. ONE jq over the cache per file per shell.
_cr_load() {
  local file="$1" mk box pfx f out
  mk="$(_lg_h)|$file"
  [ -n "${_CR_MEMO[$mk]+x}" ] && return 0
  _CR_MEMO[$mk]=""
  [ -n "${_CR_BOX_MEMO["$(_lg_h)"]+x}" ] || _CR_BOX_MEMO["$(_lg_h)"]=$(_cr_box)
  box="${_CR_BOX_MEMO["$(_lg_h)"]}"
  _cr_refresh
  f=$(_lg_settings_file)
  [ -r "$f" ] || return 0
  case "$box" in ''|*[!a-z0-9_-]*)
    _lg_log_throttled "conf-box" "conf: box '$(_lg_box)' is not a settings key segment, fleet rows only"
    box="" ;;
  esac
  pfx="conf.$file."
  out=$(jq -r --arg p "$pfx" --arg b "$box" '
    [ .values // {} | to_entries[] | select(.key | startswith($p))
      | {k: (.key | ltrimstr($p)), n: (.key | length), v: (.value | tostring)} ]
    | map(if $b != "" and .n <= 64 and (.k | endswith("." + $b)) and (.k | length) > ($b | length) + 1
          then .k |= .[0:(length - ($b | length) - 1)] | .s = "box-row" else .s = "fleet-row" end)
    | map(select(.k != ""))
    | group_by(.k)[] | (map(select(.s == "box-row")) + map(select(.s == "fleet-row")))[0]
    | if (.v | test("[\n\t]")) then "bad\t\(.k)\t\(.s)" else "ok\t\(.k)\t\(.s)\t\(.v)" end' "$f" 2>/dev/null) || return 0
  local tag k s v keep=""
  while IFS=$'\t' read -r tag k s v; do
    case "$tag" in
      ok)  keep+="$k"$'\t'"$s"$'\t'"$v"$'\n' ;;
      bad) _lg_log_throttled "conf-$file-value" "conf $file: row conf.$file.$k holds a newline or tab, treated as no row" ;;
    esac
  done <<<"$out"
  _CR_MEMO[$mk]="$keep"
}

# [harness] on both readers is the resolver's own harness root when it is not
# $HARNESS (scheduler-conf's third argument, cost-budget's _CB_H).
conf_rows() {
  local file="${1:-}"
  [ -n "$file" ] || return 1
  [ "${LANE_GATE_DISABLE:-}" = 1 ] && return 0
  local HARNESS="${2:-${HARNESS:-${H:-}}}"
  [ -n "$HARNESS" ] || return 0
  _cr_ready || return 0
  _cr_load "$file"
  local k s v
  while IFS=$'\t' read -r k s v; do
    [ -n "$k" ] && printf '%s\t%s\n' "$k" "$v"
  done <<<"${_CR_MEMO["$(_lg_h)|$file"]}"
  return 0
}

# conf_rows_seeded — the registry-seed rows, kept apart from conf_rows so the
# seven resolvers that do not layer a seed keep ignoring them. No box-row
# stripping: a key with an extra segment reaches the resolver as-is and its
# shape check drops it, the same contract as conf_rows. Memo key
# `<harness>|seed|<file>`, one jq per file per shell.
conf_rows_seeded() {
  local file="${1:-}"
  [ -n "$file" ] || return 1
  [ "${LANE_GATE_DISABLE:-}" = 1 ] && return 0
  local HARNESS="${2:-${HARNESS:-${H:-}}}"
  [ -n "$HARNESS" ] || return 0
  _cr_ready || return 0
  local mk f out tag k v keep=""
  mk="$(_lg_h)|seed|$file"
  if [ -z "${_CR_MEMO[$mk]+x}" ]; then
    _CR_MEMO[$mk]=""
    _cr_refresh
    f=$(_lg_settings_file)
    if [ -r "$f" ]; then
      out=$(jq -r --arg p "conf.$file." '
        .seeded // {} | to_entries[] | select(.key | startswith($p))
        | {k: (.key | ltrimstr($p)), v: (.value | tostring)} | select(.k != "")
        | if (.v | test("[\n\t]")) then "bad\t\(.k)" else "ok\t\(.k)\t\(.v)" end' "$f" 2>/dev/null) || out=""
      while IFS=$'\t' read -r tag k v; do
        case "$tag" in
          ok)  keep+="$k"$'\t'"$v"$'\n' ;;
          bad) _lg_log_throttled "conf-$file-value" "conf $file: seed row conf.$file.$k holds a newline or tab, treated as no row" ;;
        esac
      done <<<"$out"
      _CR_MEMO[$mk]=$(printf '%s' "$keep" | LC_ALL=C sort)
    fi
  fi
  [ -n "${_CR_MEMO[$mk]}" ] && printf '%s\n' "${_CR_MEMO[$mk]}"
  return 0
}

conf_row() {
  local file="${1:-}" key="${2:-}"
  CONF_ROW_SRC=none
  [ -n "$file" ] || return 1
  [ "${LANE_GATE_DISABLE:-}" = 1 ] && return 1
  local HARNESS="${3:-${HARNESS:-${H:-}}}"
  [ -n "$HARNESS" ] || return 1
  _cr_ready || return 1
  local box bk fk v k s
  if [ -n "$key" ]; then
    _cr_load "$file"
    box="${_CR_BOX_MEMO["$(_lg_h)"]}"
  else
    box=$(_cr_box)
  fi
  if [ -z "$key" ]; then
    # The document row: conf.<file>.<box>, then conf.<file>. It sits outside
    # the conf.<file>. prefix, so it is two exact reads rather than the memo.
    _cr_refresh
    fk="conf.$file"; bk="$fk.$box"
    case "$box" in ''|*[!a-z0-9_-]*) bk="" ;; esac
    [ "${#bk}" -le 64 ] || bk=""
    for k in "$bk" "$fk"; do
      [ -n "$k" ] || continue
      v=$(_lg_setting_lookup "$k") || continue
      case "$v" in *$'\n'*|*$'\t'*)
        _lg_log_throttled "conf-$file-value" "conf $file: row $k holds a newline or tab, treated as no row"
        continue ;;
      esac
      if [ "$k" = "$bk" ]; then CONF_ROW_SRC=box-row; else CONF_ROW_SRC=fleet-row; fi
      printf '%s' "$v"; return 0
    done
    return 1
  fi
  bk="conf.$file.$key.$box"
  if [ "${#bk}" -gt 64 ]; then
    _lg_log_throttled "conf-$file-key" "conf $file: box row for $key cannot be a settings key (over 64 chars), fleet row only"
  fi
  while IFS=$'\t' read -r k s v; do
    [ "$k" = "$key" ] || continue
    CONF_ROW_SRC="$s"; printf '%s' "$v"; return 0
  done <<<"${_CR_MEMO["$(_lg_h)|$file"]}"
  return 1
}

conf_row_note_file() {
  local file="${1:-}" ff="${2:-}"
  shift 2 2>/dev/null || return 0
  [ $# -gt 0 ] && [ -f "$ff" ] || return 0
  [ -n "${HARNESS:-${H:-}}" ] || return 0
  _cr_ready || return 0
  _lg_log_throttled "conf-$file" "conf $file: settings rows override flags/$(basename "$ff") for: $*"
}

conf_row_refused() {
  local file="${1:-}" key="${2:-}" v="${3:-}" ff="${4:-}"
  local HARNESS="${5:-${HARNESS:-${H:-}}}"
  [ -n "$HARNESS" ] || return 0
  _cr_ready || return 0
  _lg_log_throttled "conf-$file-bad-$key" "conf $file: row conf.$file.$key='$v' refused, flags/$(basename "$ff") used"
}

conf_rows_preload() {
  local file="${1:-}"
  [ -n "$file" ] || return 0
  [ "${LANE_GATE_DISABLE:-}" = 1 ] && return 0
  local HARNESS="${2:-${HARNESS:-${H:-}}}"
  [ -n "$HARNESS" ] || return 0
  _cr_ready || return 0
  _cr_load "$file"
  return 0
}
