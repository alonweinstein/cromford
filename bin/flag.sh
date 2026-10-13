#!/bin/bash
# bin/flag.sh — BH-5635.1: the operator CLI for the pause_flags rows, and the
# one-time seed that copies a box's flags/ files into them.
#
# USAGE
#   bin/flag.sh on  <flag> [<project>] [--value V] [--reason R]
#   bin/flag.sh off <flag> [<project>] [--reason R]
#   bin/flag.sh list [<project>]
#   bin/flag.sh history <flag> [<project>]
#   bin/flag.sh seed
# <flag> is one of: paused wip-limit fly-pool fly-pool-app builder-fly
# automerge-disabled. The row name is <flag>-<project>; only automerge-disabled
# may omit the project. Names are checked by _flag_on_name (bin/lib/flag-on.sh).
#
# on / off send ONE `PUT /api/flags {name, active, value?, actor: $JOBS_BOX,
# reason?}`. The row is written first and flags/ is changed only by flag_sync,
# only after a 2xx whose flag.name and flag.active match the request:
#   rc 0  row written, flags/<name> synced
#   rc 1  row not written (non-2xx, no secret, no URL, unconfirmed answer); no
#         file is changed
#   rc 2  bad usage, bad flag or project, a routing flag, --value where none
#         applies; no request is sent
#   rc 3  row written, but this box does not read it back (a newer local file
#         wins, or flags/ is not writable)
# The BH-4153 families (paused-*, automerge-disabled, automerge-disabled-*) are
# harness_flags rows: no flags/ file is written for them. For those, the
# read-back is the cache that flag_sync fills, read with `flag_has --cached`.
# `off` also removes a legacy flags/<name> that is not newer than the row, as
# the import does (kept-row). A newer one stays a local hold, and that is rc 3.
# On success the line says "cache synced" for these and "flags/<name> synced"
# for wip-limit.
# `on wip-limit` needs --value <positive integer>. The routing families
# (builder-fly, fly-pool, fly-pool-app) belong to `bin/jobs-client.sh
# routing-set`; this CLI refuses both on and off for them.
#
# list: GET /api/flags, one tab-separated line per row in the six families:
# name, active, value (- when empty), actor, updated_at. The worker returns at
# most 500 rows; a full page is said on stderr.
# history: GET /api/flag-changes?name=<name>, one line per change.
#
# seed: the hub lane `flag` (cron/lanes/727-flag.cron) runs it
# hourly. A no-op once state/flags-seeded exists. Otherwise, under a `flock -n`
# dedupe and the lane gate, it first reads the fleet-wide marker, the settings
# row `flags.seeded`. A row there means another hub (the standby before a lease
# move, or the primary) already seeded: the local stamp is written and nothing
# else is sent. With no row, for each regular file flags/wip-limit-*:
# GET /api/flags/<name>; 200 skips (a row is never overwritten), 404 PUTs an
# active row (actor seed, value = the trimmed first line when it is 1-64 chars
# of A-Za-z0-9._-). Then it PUTs `flags.seeded` and writes the local stamp. Any
# other answer stops the pass with rc 1, one logs/flags.log line and no stamp;
# the next hour tries again.
# Only wip-limit-* is seeded. paused-*, automerge-disabled and
# automerge-disabled-* belong to bin/flags-import.sh (BH-4153), which publishes
# only the flags this box owns and keeps the rest as local holds.
# Off: flags/lane-off-flag, or bin/harness-ctl.sh off flag (the lane gate is read by seed only).
set -uo pipefail

H="${HARNESS:-/root/harness}"
export HARNESS="$H"
# shellcheck source=bin/jobs-client.sh
. "$H/bin/jobs-client.sh" || { echo "flag.sh: cannot load $H/bin/jobs-client.sh" >&2; exit 1; }
# shellcheck source=bin/lib/flag-on.sh
. "$H/bin/lib/flag-on.sh" || { echo "flag.sh: cannot load $H/bin/lib/flag-on.sh" >&2; exit 1; }

usage() {
  sed -n '6,10p' "$0" | sed 's/^# //' >&2
  exit 2
}

# _fs_req <method> <path> [body] — _jobs_req with its status kept. Sets _FS_BODY
# (the 2xx payload) and _FS_STATUS (401, 500, no-secret, no-url, curl_rc=7).
_FS_BODY=""; _FS_STATUS=""
_fs_req() {
  local sf rc
  _FS_BODY=""; _FS_STATUS=""
  sf=$(mktemp "${TMPDIR:-/tmp}/flag-sh.XXXXXX" 2>/dev/null) || { _FS_STATUS="mktemp failed"; return 1; }
  _FS_BODY=$(JOBS_STATUS_FILE="$sf" _jobs_req "$@"); rc=$?
  _FS_STATUS=$(cat "$sf" 2>/dev/null); _FS_STATUS="${_FS_STATUS#http=}"
  [ -n "$_FS_STATUS" ] || _FS_STATUS="rc=$rc"
  rm -f "$sf"
  return "$rc"
}

_fs_log() {
  mkdir -p "$H/logs" 2>/dev/null
  { echo "$(date -u '+%Y-%m-%d %H:%M:%SZ') [flag-seed] $*" >> "$H/logs/flags.log"; } 2>/dev/null
}

cmd_set() {
  local verb="$1"; shift
  local flag="" p="" value="" reason="" have_value=0 npos=0 name active body got f why src
  while [ $# -gt 0 ]; do
    case "$1" in
      --value)  [ $# -ge 2 ] || usage; value="$2"; have_value=1; shift 2 ;;
      --reason) [ $# -ge 2 ] || usage; reason="$2"; shift 2 ;;
      -*) usage ;;
      *) npos=$((npos+1))
         case "$npos" in 1) flag="$1" ;; 2) p="$1" ;; *) usage ;; esac
         shift ;;
    esac
  done
  name=$(_flag_on_name "$flag" "$p") || { echo "flag.sh: bad flag or project" >&2; return 2; }
  case "$flag" in
    builder-fly|fly-pool|fly-pool-app)
      echo "flag.sh: $flag is a routing flag; use bin/jobs-client.sh routing-set" >&2; return 2 ;;
  esac
  if [ "$have_value" = 1 ] && { [ "$verb" != on ] || [ "$flag" != wip-limit ]; }; then
    echo "flag.sh: --value applies only to 'on wip-limit'" >&2; return 2
  fi
  if [ "$verb" = on ] && [ "$flag" = wip-limit ] && ! [[ "$value" =~ ^[1-9][0-9]{0,5}$ ]]; then
    echo "flag.sh: wip-limit needs --value <positive integer>" >&2; return 1
  fi
  active=0; [ "$verb" = on ] && active=1
  body=$(jq -nc --arg n "$name" --argjson a "$active" --arg act "$JOBS_BOX" --arg v "$value" --arg r "$reason" \
    '{name:$n, active:$a, actor:$act} + (if $v == "" then {} else {value:$v} end) + (if $r == "" then {} else {reason:$r} end)') \
    || { echo "flag.sh: row not written (cannot build the request body)" >&2; return 1; }
  if ! _fs_req PUT /api/flags "$body"; then
    echo "flag.sh: row not written ($_FS_STATUS)" >&2; return 1
  fi
  got=$(printf '%s' "$_FS_BODY" | jq -r '[.flag.name, (.flag.active|tostring)] | join(" ")' 2>/dev/null)
  if [ "$got" != "$name $active" ]; then
    echo "flag.sh: row not confirmed (bad response)" >&2; return 1
  fi
  f="$H/flags/$name"
  flag_sync "$name" >/dev/null 2>&1; src=$?
  why=""
  case "$src" in
    0) ;;
    2) why="the read-back found no row" ;;
    *) why="the read-back failed (rc $src)" ;;
  esac
  if [ -z "$why" ] && _flag_ported "$name"; then
    # BH-4153: a row, never a file. An older legacy file goes on `off`; a newer
    # one is a local hold that flag_has honours, so the read-back below says so.
    if [ "$active" = 0 ] && [ -f "$f" ]; then
      local scope rt mt
      scope=$(_flag_scope_for "$name" 2>/dev/null) \
        && rt=$(_flag_row_epoch "$(_flag_cache_read "$scope" "$name")" 2>/dev/null) \
        && mt=$(stat -c %Y "$f" 2>/dev/null) \
        && [ "${rt%.*}" -ge "$mt" ] 2>/dev/null && rm -f "$f"
    fi
    flag_has --cached "$name" >/dev/null 2>&1; src=$?
    if [ "$active" = 1 ] && [ "$src" != 0 ]; then why="this box reads $name as off (flag_has rc $src)"
    elif [ "$active" = 0 ] && [ "$src" = 0 ]; then
      if [ -f "$f" ]; then why="a newer local flags/$name is a local hold"; else why="this box reads $name as on"; fi
    elif [ "$active" = 0 ] && [ "$src" != 1 ]; then why="this box cannot read $name (flag_has rc $src)"
    fi
    if [ -n "$why" ]; then
      echo "flag.sh: row written; $name not synced on this box ($why)" >&2; return 3
    fi
    echo "flag.sh: $name $verb (row written, cache synced)"
    return 0
  fi
  if [ -z "$why" ]; then
    if [ "$active" = 1 ]; then
      if [ ! -f "$f" ]; then why="flags/$name is absent"
      elif [ -n "$value" ] && [ "$(cat "$f" 2>/dev/null)" != "$value" ]; then why="a newer local flags/$name was kept"; fi
    elif [ -e "$f" ]; then why="a newer local flags/$name was kept"
    fi
  fi
  if [ -n "$why" ]; then
    echo "flag.sh: row written; flags/$name not synced ($why)" >&2; return 3
  fi
  echo "flag.sh: $name $verb (row written, flags/$name synced)"
  return 0
}

cmd_list() {
  local p="${1:-}"
  [ $# -le 1 ] || usage
  if [ -n "$p" ]; then
    case "$p" in .|..|*[!A-Za-z0-9._-]*) echo "flag.sh: bad project" >&2; return 2 ;; esac
  fi
  if ! _fs_req GET /api/flags; then echo "flag.sh: list failed ($_FS_STATUS)" >&2; return 1; fi
  local n
  n=$(printf '%s' "$_FS_BODY" | jq -r '.flags | length' 2>/dev/null) \
    || { echo "flag.sh: list failed (bad response)" >&2; return 1; }
  [[ "$n" =~ ^[0-9]+$ ]] || { echo "flag.sh: list failed (bad response)" >&2; return 1; }
  [ "$n" -ge 500 ] && echo "flag.sh: list shows the first 500 rows (worker cap)" >&2
  printf '%s' "$_FS_BODY" | jq -r --arg p "$p" '
    ["paused","wip-limit","fly-pool","fly-pool-app","builder-fly","automerge-disabled"] as $fams
    | .flags[]
    | select(.name as $nm
        | if $p == "" then
            ($nm == "automerge-disabled") or any($fams[]; . as $f | $nm | startswith($f + "-"))
          else any($fams[]; . + "-" + $p == $nm) end)
    | [.name, (.active|tostring), (.value // "-"), (.actor // "-"), (.updated_at // "-")] | @tsv'
}

cmd_history() {
  local name
  [ $# -le 2 ] || usage
  name=$(_flag_on_name "${1:-}" "${2:-}") || { echo "flag.sh: bad flag or project" >&2; return 2; }
  if ! _fs_req GET "/api/flag-changes?name=$name"; then echo "flag.sh: history failed ($_FS_STATUS)" >&2; return 1; fi
  printf '%s' "$_FS_BODY" | jq -e '.changes | type == "array"' >/dev/null 2>&1 \
    || { echo "flag.sh: history failed (bad response)" >&2; return 1; }
  printf '%s' "$_FS_BODY" | jq -r '.changes[]
    | [(.at // "-"), (.actor // "-"), (.before_json // null | tostring), "->", (.after_json // null | tostring), (.reason // "")]
    | join(" ")'
  if [ "$(printf '%s' "$_FS_BODY" | jq -r '.truncated // false')" = true ]; then
    echo "flag.sh: history is truncated (the worker returned its newest changes only)" >&2
  fi
  return 0
}

cmd_seed() {
  local stamp="$H/state/flags-seeded" f n v first seeded=0 skipped=0 body got tmp
  local -a names=()
  [ -e "$stamp" ] && return 0
  mkdir -p "$H/locks" "$H/state" "$H/logs" 2>/dev/null
  exec 9>"$H/locks/flag-seed.lock" || return 1
  flock -n 9 || return 0
  [ -e "$stamp" ] && return 0
  # shellcheck disable=SC1091
  . "$H/bin/lib/lane-gate.sh" 2>/dev/null || true
  command -v lane_gate_or_exit >/dev/null 2>&1 && lane_gate_or_exit flag
  command -v lane_env_apply    >/dev/null 2>&1 && lane_env_apply    flag
  # The fleet-wide marker: a hub that took the lease after another hub seeded
  # has no local stamp, and must not seed its own flags/ a second time.
  if ! _fs_req GET /api/settings/flags.seeded; then
    _fs_log "seed stopped: GET settings flags.seeded answered $_FS_STATUS; no stamp, the next run retries"; return 1
  fi
  if ! printf '%s' "$_FS_BODY" | jq -e 'has("setting")' >/dev/null 2>&1; then
    _fs_log "seed stopped: GET settings flags.seeded gave a bad answer; no stamp, the next run retries"; return 1
  fi
  if printf '%s' "$_FS_BODY" | jq -e '.setting != null' >/dev/null 2>&1; then
    tmp="$stamp.tmp.$$"
    printf '%s seeded=0 skipped=0 box=%s marker=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$JOBS_BOX" \
      "$(printf '%s' "$_FS_BODY" | jq -r '.setting.value // "-"' | tr -s ' \t' '__')" > "$tmp" \
      && mv -f "$tmp" "$stamp" || { rm -f "$tmp"; _fs_log "the fleet is seeded but state/flags-seeded not written"; return 1; }
    _fs_log "seed skipped: settings flags.seeded says the fleet is seeded"
    return 0
  fi
  for f in "$H"/flags/wip-limit-*; do
    [ -f "$f" ] || continue
    n="${f##*/}"
    case "$n" in *.tmp.*) _fs_log "skip $n (a temp file)"; continue ;; esac
    [[ "$n" =~ ^[A-Za-z0-9._-]+$ ]] || { _fs_log "skip $n (name outside A-Za-z0-9._-)"; continue; }
    names+=("$n")
  done
  while IFS= read -r n; do
    [ -n "$n" ] || continue
    f="$H/flags/$n"
    [ -f "$f" ] || continue
    _fs_req GET "/api/flags/$n"
    case "$?" in
      0) skipped=$((skipped+1)); continue ;;
      2) ;;
      *) _fs_log "seed stopped at flags/$n: GET answered $_FS_STATUS; no stamp, the next run retries"; return 1 ;;
    esac
    first=$(head -n 1 "$f" 2>/dev/null)
    v=$(printf '%s' "$first" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')
    if [ -n "$v" ] && ! [[ "$v" =~ ^[A-Za-z0-9._-]{1,64}$ ]]; then
      _fs_log "flags/$n: content is not a flag value (1-64 chars of A-Za-z0-9._-); seeded with no value"
      v=""
    fi
    body=$(jq -nc --arg n "$n" --arg v "$v" --arg r "BH-5635 seed from $JOBS_BOX flags/" \
      '{name:$n, active:1, actor:"seed", reason:$r} + (if $v == "" then {} else {value:$v} end)') \
      || { _fs_log "seed stopped at flags/$n: cannot build the request body"; return 1; }
    if ! _fs_req PUT /api/flags "$body"; then
      _fs_log "seed stopped at flags/$n: PUT answered $_FS_STATUS; no stamp, the next run retries"; return 1
    fi
    got=$(printf '%s' "$_FS_BODY" | jq -r '.flag.name // empty' 2>/dev/null)
    if [ "$got" != "$n" ]; then
      _fs_log "seed stopped at flags/$n: PUT answer not confirmed (bad response); no stamp"; return 1
    fi
    seeded=$((seeded+1))
  done < <(printf '%s\n' "${names[@]+"${names[@]}"}" | LC_ALL=C sort -u)
  body=$(jq -nc --arg v "$(date -u +%Y-%m-%dT%H:%M:%SZ) box=$JOBS_BOX seeded=$seeded skipped=$skipped" --arg a "$JOBS_BOX" \
    '{key:"flags.seeded", value:$v, actor:$a, reason:"BH-5635 seed done", note:"bin/flag.sh seed ran; a later hub does not seed again"}') \
    || { _fs_log "seed done but the flags.seeded body could not be built; no stamp"; return 1; }
  if ! _fs_req PUT /api/settings "$body"; then
    _fs_log "seed done but PUT settings flags.seeded answered $_FS_STATUS; no stamp, the next run retries"; return 1
  fi
  tmp="$stamp.tmp.$$"
  printf '%s seeded=%d skipped=%d box=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$seeded" "$skipped" "$JOBS_BOX" > "$tmp" \
    && mv -f "$tmp" "$stamp" || { rm -f "$tmp"; _fs_log "seed done but state/flags-seeded not written"; return 1; }
  _fs_log "seed done: seeded=$seeded skipped=$skipped box=$JOBS_BOX"
  return 0
}

verb="${1:-}"
[ $# -gt 0 ] && shift
case "$verb" in
  on|off)  cmd_set "$verb" "$@"; exit $? ;;
  list)    cmd_list "$@"; exit $? ;;
  history) cmd_history "$@"; exit $? ;;
  seed)    [ $# -eq 0 ] || usage; cmd_seed; exit $? ;;
  *)       usage ;;
esac
