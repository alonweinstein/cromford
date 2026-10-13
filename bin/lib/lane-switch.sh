#!/bin/bash
# bin/lib/lane-switch.sh — BH-2320: a kill switch is a SETTINGS ROW, with an
# optional box dimension, before it is a file. Sourced, never executed. No side
# effect at source time beyond defining functions (and sourcing lane-gate.sh
# when this shell does not have it yet).
#
# WHY. The `flags/<x>-off` / `flags/<x>-disabled` kill switches are read as
# bare `[ -f flags/<x> ]` (100 such reads in bin/ after BH-2320's pilot), so
# the only way to flip one was ssh, a box that died took its switches with it,
# and a local `touch` silently beat whatever the database said (bin/lib/jobs/flags.sh reconciles last-writer-wins on
# mtime). A switch read through lane_switch is settled by a row instead.
#
# lane_switch <name> [file|flag] — rc 0 when the switch is ON (the thing it
# names is turned off), rc 1 when it is not. The mode picks the no-row step
# (step 3) and nothing else; it defaults to flag. Any other mode is logged once
# per throttle window and read as flag, never as off. A name outside
# [a-z0-9_-] is refused before any step (rc 1, src=none). First hit wins:
#   1. LANE_GATE_DISABLE=1 -> step 3 straight away, with no row read and no
#      settings refresh: the hatch turns the rows off, not the switch, so a
#      kill file still stops the thing (BH-2407; it used to answer rc 1).
#   2. settings `switch.<name>.<box>` (box = _lg_box, lowercased), then
#      `switch.<name>`, from state/settings-cache.json after
#      _lg_settings_refresh — the cache lane_knob already fills, so this costs
#      no extra request. 1|on|true = ON, 0|off|false = OFF. When a row answers,
#      flags/<name> is NOT read for the decision; a file that contradicts an
#      OFF row writes one throttled logs/lane-gate.log line. Any other value is
#      logged and treated as no row: an unreadable row is never a guess.
#   3. No row: _ls_legacy, READ-ONLY (BH-2412). In `file` mode
#      `[ -f flags/<name> ]` only, with no /api/flags request and no sighting.
#      In `flag` mode it gives the answer flag_active gave before, without
#      flag_sync's reconcile: with the jobs client, the pause_flags row is read
#      (GET /api/flags/<name>) and judged by flag_sync's own last-writer-wins
#      rule against the file's mtime, but flags/<name> is never created or
#      removed. No row there, an outage, an unreadable row, or no client at
#      all: `[ -f flags/<name> ]` decides. With no row written, a switch answers
#      what its file answered before.
#      In `flag` mode a file that decides ON with no row behind it (no
#      pause_flags row, or one saying 0 that is older than the file) is
#      SIGHTED: _lg_flag_seen posts it to lane_flag_sightings, once per state
#      change plus the hourly refresh. An answer decided without a file clears
#      an old sighting. An outage, an unreadable row and no client post nothing.
#   4. Worker down: _lg_settings_refresh leaves the last cache at any age, so a
#      row written before the outage keeps answering; with no cache at all,
#      step 3 decides.
# LANE_SWITCH_SRC says where the answer came from:
# box-row|fleet-row|legacy-row (a pause_flags row)|legacy-file (the file)|none
# (and noclient, from ls_isolated below).
#
# Every switch read this way has catalog/switches.d/<name>.json, which is what
# bin/switch-migrate.sh walks and tests/switch-ratchet.bh-2320-test.sh checks.
# A row is written with `bin/switch-migrate.sh` (from the file on this box) or
# `PUT /api/settings` directly.

if ! command -v _lg_settings_refresh >/dev/null 2>&1; then
  # shellcheck source=lane-gate.sh
  . "$(dirname "${BASH_SOURCE[0]}")/lane-gate.sh" || return 1
fi

# _ls_name_ok <name> — dots are refused as well as anything outside the worker's
# key charset: `switch.a.b` would be both the fleet row of switch `a.b` and the
# box row of switch `a` on box `b`.
_ls_name_ok() { case "${1:-}" in ''|*[!a-z0-9_-]*) return 1 ;; esac; return 0; }

_ls_fleet_key() { printf 'switch.%s' "$1"; }

# _ls_box_key <name> — rc 1 when the key cannot exist (box outside the charset,
# or longer than the worker's 64 characters).
_ls_box_key() {
  local box key
  box=$(_lg_box | tr '[:upper:]' '[:lower:]')
  key="switch.$1.$box"
  case "$box" in ''|*[!a-z0-9_-]*) return 1 ;; esac
  [ "${#key}" -le 64 ] || return 1
  printf '%s' "$key"
}

# _ls_row <name> <key> — prints 1 or 0 for a readable row, rc 1 for no row. An
# unreadable value is logged and answers "no row".
_ls_row() {
  local v
  v=$(_lg_setting_lookup "$2") || return 1
  case "$(printf '%s' "$v" | tr '[:upper:]' '[:lower:]')" in
    1|on|true) printf 1 ;;
    0|off|false) printf 0 ;;
    *) _lg_log_throttled "switch-$1-value" "switch $1: row $2='$v' is not 1/on/true or 0/off/false, treated as no row"
       return 1 ;;
  esac
}

# _ls_legacy <name> <file|flag> <path> — step 3, the no-row answer. Never writes flags/: a read that deleted a
# file on an inactive row, or made one from an active row, is the reconcile
# the settings row replaces, and an unconverted bare reader of the same name
# would see the write.
_ls_legacy() {
  local name="$1" f="$3" resp rc active upd row_epoch file_epoch
  LANE_SWITCH_SRC=legacy-file
  case "$2" in
    file) [ -f "$3" ]; return $? ;;
  esac
  # The pause_flags row is consulted only when the caller already has the jobs
  # client loaded, exactly as flag_active was before BH-2412: this step never
  # loads the client itself, so a run whose settings answer came from a fresh
  # cache still costs the worker nothing (tests/pr-url-reconcile.bh-858 (a)).
  if ! command -v _jobs_req >/dev/null 2>&1 || ! command -v _flag_epoch >/dev/null 2>&1; then
    [ -f "$f" ]; return $?
  fi
  resp=$(_jobs_req GET "/api/flags/$name" 2>/dev/null); rc=$?
  if [ "$rc" -eq 2 ]; then
    if [ -f "$f" ]; then _lg_flag_seen "$name" "" "" 1; return 0; fi
    _lg_flag_seen "$name" "" "" 0; return 1
  fi
  # An outage cannot tell a row-driven file from a hand-touched one: the file
  # decides and nothing is claimed about it.
  [ "$rc" -eq 0 ] || { [ -f "$f" ]; return $?; }
  # `// empty`, never `// 0`: a row with no active must not read as inactive.
  active=$(printf '%s' "$resp" | jq -r '.flag.active // empty' 2>/dev/null)
  upd=$(printf '%s' "$resp" | jq -r '.flag.updated_at // empty' 2>/dev/null)
  case "$active" in
    0|1) ;;
    *) _lg_log_throttled "switch-$name-flagrow" "switch $name: pause_flags row without a readable active ('$active'), flags/$name decides"
       [ -f "$f" ]; return $? ;;
  esac
  if ! row_epoch=$(_flag_epoch "$upd"); then
    _lg_log_throttled "switch-$name-flagrow" "switch $name: pause_flags updated_at '$upd' unreadable, flags/$name decides"
    [ -f "$f" ]; return $?
  fi
  LANE_SWITCH_SRC=legacy-row
  if [ "$active" = 1 ]; then _lg_flag_seen "$name" "" "" 0; return 0; fi
  if [ ! -e "$f" ]; then _lg_flag_seen "$name" "" "" 0; return 1; fi
  file_epoch=$(stat -c %Y "$f" 2>/dev/null) || { LANE_SWITCH_SRC=legacy-file; return 0; }
  if [ "$row_epoch" -ge "$file_epoch" ]; then _lg_flag_seen "$name" "" "" 0; return 1; fi
  # A local touch after the row: the file decides, with no row behind it.
  LANE_SWITCH_SRC=legacy-file
  _lg_flag_seen "$name" "" "" 1
  return 0
}

lane_switch() {
  local name="${1:-}" mode="${2:-flag}" key v f
  LANE_SWITCH_SRC=none; export LANE_SWITCH_SRC
  if ! _ls_name_ok "$name"; then
    _lg_log_throttled "switch-bad-name" "switch '$name': not a switch name ([a-z0-9_-]), read as off"
    return 1
  fi
  case "$mode" in
    file|flag) ;;
    *) _lg_log_throttled "switch-$name-mode" "switch $name: mode '$mode' is not file|flag, read as flag"
       mode=flag ;;
  esac
  f="$(_lg_h)/flags/$name"
  if [ "${LANE_GATE_DISABLE:-}" = 1 ]; then
    _ls_legacy "$name" "$mode" "$f"
    return $?
  fi
  _lg_settings_refresh
  if key=$(_ls_box_key "$name"); then
    v=$(_ls_row "$name" "$key") && LANE_SWITCH_SRC=box-row
  else
    _lg_log_throttled "switch-$name-key" "switch $name: box row for '$(_lg_box)' cannot be a settings key (charset or >64 chars), fleet row only"
    v=""
  fi
  if [ -z "$v" ]; then
    key=$(_ls_fleet_key "$name")
    v=$(_ls_row "$name" "$key") && LANE_SWITCH_SRC=fleet-row
  fi
  if [ -n "$v" ]; then
    # A row decides, so no file does: clear a sighting a file left (a no-op,
    # and no request, without a marker).
    _lg_flag_seen "$name" "" "" 0
    [ "$v" = 1 ] && return 0
    [ -f "$f" ] && _lg_log_throttled "switch-$name" "switch $name: row says 0 ($key), flags/$name ignored"
    return 1
  fi
  _ls_legacy "$name" "$mode" "$f"
}

# lane_switch_src <name> — where the last lane_switch <name> answer came from,
# in the words a status line uses (BH-2435): `settings switch.<name>[.<box>]`
# for a row, `flags/<name>` otherwise.
lane_switch_src() {
  case "${LANE_SWITCH_SRC:-}" in
    box-row)   printf 'settings %s' "$(_ls_box_key "$1")" ;;
    fleet-row) printf 'settings %s' "$(_ls_fleet_key "$1")" ;;
    *)         printf 'flags/%s' "$1" ;;
  esac
}

# ls_isolated lane_switch <name> [file|flag] — the same answer, read in a
# subshell (BH-2435). _lg_settings_refresh sources bin/jobs-client.sh, and a
# client with no bin/lib/jobs/ beside it (a half-synced bin/) `exit 1`s the
# shell it was sourced into. Here that ends only the subshell, with an rc that is
# neither answer, and the switch then answers from flags/<name> exactly as it did
# before it was converted: never fail-open, and never taking the caller down.
# LANE_SWITCH_SRC comes back out; `noclient` names that fallback.
ls_isolated() {
  local out rc name="${2:-}"
  out=$("$@" >/dev/null; r=$?; printf '%s' "${LANE_SWITCH_SRC:-none}"; exit $(( r ? 10 : 0 )))
  rc=$?
  export LANE_SWITCH_SRC
  case "$rc" in
    0)  LANE_SWITCH_SRC=$out; return 0 ;;
    10) LANE_SWITCH_SRC=$out; return 1 ;;
  esac
  LANE_SWITCH_SRC=noclient
  _ls_name_ok "$name" || return 1
  [ -f "$(_lg_h)/flags/$name" ]
}
