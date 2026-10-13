#!/bin/bash
# shellcheck shell=bash
# bin/lib/flag-on.sh — BH-5635.0: the one flag reader. The pause_flags row is
# asked first; on a failed read the answer is FAIL-CLOSED from the last good
# row (state/flags-cache/<name>.json) or the flags/ file. Sourced, never run.
#
# CONTRACT
#   flag_on <flag> [<project>]      rc 0 ON, 1 OFF, 2 bad name or no root (no read)
#   flag_value <flag> [<project>]   prints the value when ON (file content, or the
#                                   cached value in an outage); same rc as flag_on
#   flag_file_on <flag> [<project>] the flags/ file only, never a request; rc 0/1/2
# <flag> is one of: paused wip-limit fly-pool fly-pool-app builder-fly
# automerge-disabled. The name is <flag>-<project>; only automerge-disabled may
# omit the project (the fleet flag `automerge-disabled`).
#
# READ ORDER (paused, wip-limit, automerge-disabled)
#   1. JOBS_URL empty -> the file.
#   1b. A ported name (paused-*, automerge-disabled*, BH-4153) with a worker
#      configured -> flag_active (bin/lib/jobs/flags.sh): the harness_flags row,
#      DB-first, its own last-good cache, fail-closed (unknown = ON). Steps 2-4
#      below are for wip-limit-* (a pause_flags row).
#   2. GET /api/flags/<name>. A readable row (active 0|1, worker-shaped
#      updated_at, value empty or in the alphabet): reconcile flags/ with
#      _flag_apply_row, write the cache (tmp + mv), clear state/flags-cache/.outage
#      with one logs/flags.log line, answer from the file. If the reconcile
#      fails (flags/ unwritable), the answer is ON iff the row says active 1 OR
#      the file exists; the value is the row's when set, else the file's.
#   3. 404 -> the file. The cache and the marker are not touched.
#   4. Anything else is an OUTAGE: the first caller creates .outage (noclobber)
#      and writes ONE ALERTS line through bin/alert-line.sh. The answer is ON iff
#      the cache says active 1 OR the file exists. The cache is never written.
# READ ORDER (builder-fly, fly-pool, fly-pool-app)
#   1. routing_sync (no request while the routing_rows switch is off).
#   2. BH-5960: a ported name (BH-4154) with a worker configured -> flag_active,
#      the harness_flags row and its last-good cache. Unknown (worker down,
#      nothing cached) reads OFF: a routing flag is not a stop switch.
#   3. Otherwise the file.
#
# The root is ${HARNESS:-${H:-}} and nothing else (D43): no root is rc 2. The
# client is sourced from that root, and a client already bound to another root
# is not used (file only).

# _flag_on_name <flag> <project> -> prints the flag name; rc 2 when refused.
_flag_on_name() {
  local flag="${1:-}" p="${2:-}"
  case "$flag" in
    paused|wip-limit|fly-pool|fly-pool-app|builder-fly|automerge-disabled) ;;
    *) return 2 ;;
  esac
  if [ -z "$p" ]; then
    [ "$flag" = automerge-disabled ] || return 2
    printf '%s' "$flag"; return 0
  fi
  case "$p" in .|..|*[!A-Za-z0-9._-]*) return 2 ;; esac
  printf '%s-%s' "$flag" "$p"
}

# _flag_on_bind <root> — rc 0 when the jobs client is bound to <root>.
_flag_on_bind() {
  local root="$1"
  if ! declare -F flag_sync >/dev/null; then
    # The client exits (not returns) when bin/lib/jobs/ is missing, which would
    # end the caller; the callers guard their own source the same way.
    [ -d "$root/bin/lib/jobs" ] || return 1
    HARNESS="$root"
    # shellcheck source=/dev/null
    . "$root/bin/jobs-client.sh" 2>/dev/null || return 1
  fi
  declare -F _flag_apply_row >/dev/null && [ "${JOBS_HARNESS:-}" = "$root" ]
}

# _flag_on_file <file> — sets _FO_RC and _FO_VAL from the file alone.
_flag_on_file() {
  if [ -f "$1" ]; then _FO_RC=0; _FO_VAL=$(cat "$1" 2>/dev/null); else _FO_RC=1; _FO_VAL=""; fi
}

# _flag_cache_get <cache-file> — sets c_active and c_value; rc 1 (both empty)
# when the cache is absent or unreadable. A garbage cache is no cache.
_flag_cache_get() {
  c_active=""; c_value=""
  [ -s "$1" ] || return 1
  c_active=$(jq -er 'if (.active == 0 or .active == 1) then .active else error("bad") end' "$1" 2>/dev/null) \
    || { c_active=""; return 1; }
  c_value=$(jq -r '.value // empty | strings' "$1" 2>/dev/null)
  [[ "$c_value" =~ ^[A-Za-z0-9._-]{1,64}$ ]] || c_value=""
  return 0
}

# _flag_on_ported_ok <name> — rc 0 when <name> is a harness_flags row (BH-4153)
# and a worker is configured (JOBS_URL and HARNESS_SECRET).
_flag_on_ported_ok() {
  declare -F _flag_ported >/dev/null && declare -F _flag_db_configured >/dev/null \
    && _flag_ported "$1" && _flag_db_configured
}

# _flag_on_from_row <name> <unknown-rc> — sets _FO_RC and _FO_VAL from flag_active.
# <unknown-rc> is the answer when flag_active cannot tell (rc 2: worker down,
# nothing cached). The value is read from the cache of the scope that answered.
_flag_on_from_row() {
  local name="$1" unknown="$2" rc value scope
  _FO_VAL=""
  FLAG_ROW_SCOPE=""
  flag_active "$name"; rc=$?
  if [ "$rc" = 1 ]; then _FO_RC=1; return 0; fi
  if [ "$rc" = 2 ] && [ "$unknown" = 1 ]; then _FO_RC=1; return 0; fi
  _FO_RC=0
  if declare -F _flag_cache_read >/dev/null && declare -F _flag_scope_for >/dev/null; then
    if [ "${FLAG_ROW_SCOPE:-}" = fleet ]; then scope=fleet; else scope=$(_flag_scope_for "$name"); fi
    value=$(_flag_cache_read "$scope" "$name" 2>/dev/null | jq -r '.value // empty | strings' 2>/dev/null)
    [[ "$value" =~ ^[A-Za-z0-9._-]{1,64}$ ]] && _FO_VAL="$value"
  fi
  return 0
}

# _flag_on_eval <flag> <project> — sets _FO_RC (0/1/2) and _FO_VAL.
_flag_on_eval() {
  local flag="${1:-}" p="${2:-}" root name f cdir resp rc active upd value why c_active c_value box
  _FO_RC=2; _FO_VAL=""
  name=$(_flag_on_name "$flag" "$p") || return 0
  root="${HARNESS:-${H:-}}"
  [ -n "$root" ] || { echo "flag-on: HARNESS and H are unset — no root to read $name from" >&2; return 0; }
  f="$root/flags/$name"
  if ! _flag_on_bind "$root"; then _flag_on_file "$f"; return 0; fi
  case "$flag" in
    builder-fly|fly-pool|fly-pool-app)
      routing_sync "$p" >/dev/null 2>&1 || true
      if _flag_on_ported_ok "$name"; then _flag_on_from_row "$name" 1; return 0; fi
      _flag_on_file "$f"; return 0 ;;
  esac
  if ! jobs_configured; then _flag_on_file "$f"; return 0; fi
  # BH-4153 (the operator, 2026-10-09): paused-* and automerge-disabled* are harness_flags
  # ROWS, read DB-first by flag_has with its own last-good cache and no flags/
  # file. flag_active already fails closed for them (unknown = ON). flag_on
  # answers from it, so this reader never writes a file for a ported name.
  if _flag_on_ported_ok "$name"; then _flag_on_from_row "$name" 0; return 0; fi

  cdir="$root/state/flags-cache"
  resp=$(JOBS_ALERT=0 _jobs_req GET "/api/flags/$name"); rc=$?
  if [ "$rc" -eq 2 ]; then _flag_on_file "$f"; return 0; fi
  why="request failed rc=$rc"
  if [ "$rc" -eq 0 ]; then
    why="unreadable row"
    active=$(printf '%s' "$resp" | jq -r '.flag.active // empty' 2>/dev/null)
    upd=$(printf '%s' "$resp" | jq -r '.flag.updated_at // empty' 2>/dev/null)
    value=$(printf '%s' "$resp" | jq -r '.flag.value // empty' 2>/dev/null)
    if { [ "$active" = 0 ] || [ "$active" = 1 ]; } && _flag_epoch "$upd" >/dev/null \
       && { [ -z "$value" ] || [[ "$value" =~ ^[A-Za-z0-9._-]{1,64}$ ]]; }; then
      local applied=0
      _flag_apply_row "$name" "$resp" >/dev/null 2>&1 || applied=1
      mkdir -p "$cdir" 2>/dev/null
      jq -nc --argjson a "$active" --arg v "$value" --arg u "$upd" --arg fa "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
        '{active:$a, value:(if $v == "" then null else $v end), updated_at:$u, fetched_at:$fa}' \
        > "$cdir/.$name.json.tmp.$$" 2>/dev/null \
        && mv -f "$cdir/.$name.json.tmp.$$" "$cdir/$name.json" 2>/dev/null \
        || rm -f "$cdir/.$name.json.tmp.$$" 2>/dev/null
      if [ -e "$cdir/.outage" ]; then
        rm -f "$cdir/.outage"
        mkdir -p "$root/logs" 2>/dev/null
        { echo "$(date -u '+%Y-%m-%d %H:%M:%SZ') [flags] outage ended ($name read ok)" >> "$root/logs/flags.log"; } 2>/dev/null
      fi
      if [ "$applied" = 0 ]; then _flag_on_file "$f"; return 0; fi
      # The reconcile failed (flags/ unwritable, disk full): the file may be
      # stale, so the row just read decides too. ON iff the row OR the file.
      _flag_on_file "$f"
      if [ "$active" = 1 ]; then
        _FO_RC=0
        [ -n "$value" ] && _FO_VAL="$value"
      fi
      return 0
    fi
  fi

  # OUTAGE. The marker first, so a concurrent caller cannot write a second line.
  mkdir -p "$cdir" 2>/dev/null
  if ( set -C; : > "$cdir/.outage" ) 2>/dev/null; then
    box="${JOBS_BOX:-$(hostname 2>/dev/null)}"
    local text="[flags] harness-jobs flag read failed for $name on $box ($why): pause, automerge and WIP gates now answer from state/flags-cache and flags/, fail-closed. Check the worker/jobs deploy and HARNESS_SECRET."
    if [ -x "$root/bin/alert-line.sh" ]; then
      HARNESS="$root" "$root/bin/alert-line.sh" --id flags-outage "$text" >/dev/null 2>&1
    else
      mkdir -p "$root/logs" 2>/dev/null
      { echo "$(date -u '+%Y-%m-%d %H:%M:%SZ') $text (bin/alert-line.sh missing)" >> "$root/logs/flags.log"; } 2>/dev/null
    fi
  fi
  _flag_cache_get "$cdir/$name.json"
  if [ "$c_active" = 1 ] || [ -f "$f" ]; then
    _FO_RC=0
    if [ "$c_active" = 1 ] && [ -n "$c_value" ]; then _FO_VAL="$c_value"; else _FO_VAL=$(cat "$f" 2>/dev/null); fi
  else
    _FO_RC=1; _FO_VAL=""
  fi
  return 0
}

flag_on() { _flag_on_eval "$@"; return "$_FO_RC"; }

flag_value() {
  _flag_on_eval "$@"
  if [ "$_FO_RC" = 0 ] && [ -n "$_FO_VAL" ]; then printf '%s\n' "$_FO_VAL"; fi
  return "$_FO_RC"
}

flag_file_on() {
  local name root
  name=$(_flag_on_name "${1:-}" "${2:-}") || return 2
  root="${HARNESS:-${H:-}}"
  [ -n "$root" ] || { echo "flag-on: HARNESS and H are unset — no root to read $name from" >&2; return 2; }
  [ -f "$root/flags/$name" ]
}
