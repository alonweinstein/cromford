#!/bin/bash
# bin/lib/fleet-cooldown.sh — BH-2352 (BH-2319.0): the fleet cooldown seam.
# Sourced, never executed. Defines functions only: sourcing reads, writes and
# prints nothing, and every function is safe to call under set -euo pipefail.
#
#   fcd_put   <kind> <vendor> <subject> <until-epoch> [since-epoch] [reason]
#             always rc 0 (routing is never fatal), whether or not it wrote
#   fcd_clear <kind> <vendor> <subject>
#             rc 0 a row was removed (an expired row counts), 1 none existed, 2 unknown
#   fcd_live  <kind> <vendor> <subject>
#             rc 0 a live row (until > now), 1 none, 2 unknown
#   fcd_list  <kind>
#             prints vendor<TAB>subject<TAB>until<TAB>since<TAB>reason<TAB>box per live row
#
# Keys (matched exactly on all three fields, never as a prefix):
#   account  vendor = runner (claude, codex, ...), subject = account
#   model    vendor = claude, subject = <model> or <model>/<account>
#            (default means no suffix, the same rule the cooldown file name uses)
#   lane     vendor = lane (claude, openrouter, ...), subject = box
# Upsert, which every backend implements: account and model keep the later
# until (BH-1853), lane takes the new until, since keeps the first-seen value,
# reason/box/set_at take the new values.
# Bad input (unknown kind, empty or tab/newline vendor or subject, non-numeric
# until or since) is unknown: put writes nothing, live and clear return 2.
#
# Knobs (BH-2498): FLEET_COOLDOWN_DB, FLEET_COOLDOWN_CACHE_S and
# FLEET_COOLDOWN_CLEAR_GUARD_S resolve as operator row (settings key
# lib.fleet-cooldown.<env lowercased>) > the same row from the box settings
# cache when the worker does not answer > env > the code default, through
# lane-gate.sh's lib_env_apply in a subshell on the first fcd_* call, never at
# source time. Anything that fails in there (no lane-gate, no registry, no jq)
# leaves the env value, so a settings outage never changes behaviour and never
# reaches the caller. With no root (neither HARNESS nor H) there is no settings
# read: env, then default. FLEET_COOLDOWN_STORE is a path and is only ever env.
#
# Backend, first match wins:
#   FLEET_COOLDOWN_DB=0          every function is a no-op (put 0, live/clear 2, list empty)
#   FLEET_COOLDOWN_STORE=<path>  a TSV file, one row per key:
#                                kind vendor subject until since reason box set_at
#   otherwise                    the worker (BH-2353): the cooldown_* verbs of
#                                bin/jobs-client.sh, loaded on the first call. One
#                                GET per kind per process answers every live/list
#                                call; a put or clear drops that kind's memo. No
#                                client, no worker or a truncated list is unknown
#                                (live/clear 2, list prints what it has). A put the
#                                worker did not record leaves one line in
#                                logs/agent-rules.log under $HARNESS (else $H)
#                                and is still rc 0.
#
# The cache and the guard below live in $HARNESS/state/fleet-cooldown (else
# $H/state/...). With neither set there is no cache and no guard: every call
# reads the backend, as before them, and no file is written or removed.
#
# The box cache (worker backend, #2464): a complete answer (rc 0 or 1) is kept
# in state/fleet-cooldown/cache.<kind>.tsv for FLEET_COOLDOWN_CACHE_S seconds
# (0 = no cache), so every process on the box in one pick cycle shares ONE GET
# per kind; a flock on cache.<kind>.lock makes the processes that miss together
# wait for the one that reads. It is only a cache, never state: an unknown
# answer is never written, a stale file is never served, so an outage reads as
# unknown (live 2, list empty) and the caller falls back to its local file. A
# put or clear on this box drops the file of its kind.
#
# The reprobe reseed guard (lane only): fcd_clear lane writes
# state/fleet-cooldown/cleared.lane.<vendor>.<subject> holding the latest until
# the fleet showed for that lane, or now + the guard when that is later. Until
# then fcd_list/fcd_live hide a row for that lane whose until is not past it, so
# a clear the worker did not record is not handed back by the next good list
# read (a second "recovered"). A later until is a real re-down and shows; a put
# of the lane from this box lifts the guard. The guard is
# min(FLEET_COOLDOWN_CLEAR_GUARD_S, LANE_DOWN_TTL_S) (BH-2498), so a re-down
# after the lane TTL always shows; LANE_DOWN_TTL_S unset, 0 or not a number is
# 7200, the fallback BH-2359 (#2472) gives it. 0 = no guard. Each lane clear
# first removes the tombs older than 2x the guard whose hide mark is past, in
# the same state dir only (no root, no GC).

# _fcd_knobs: resolve the settable knobs into _FCD_DB, _FCD_CACHE_S and
# _FCD_GUARD_S (see the header). Once per process per env value, so every
# public fcd_* calls it in the caller's shell before any $( ... ) that reads
# the result. Exports nothing into the caller and always rc 0.
_FCD_LIB="$(dirname "${BASH_SOURCE[0]}")"
_FCD_KNOB_KEY=none; _FCD_DB=""; _FCD_CACHE_S=""; _FCD_GUARD_S=""
_fcd_knobs() {
  local k="${FLEET_COOLDOWN_DB-}|${FLEET_COOLDOWN_DB+set}|${FLEET_COOLDOWN_CACHE_S-}|${FLEET_COOLDOWN_CACHE_S+set}|${FLEET_COOLDOWN_CLEAR_GUARD_S-}|${FLEET_COOLDOWN_CLEAR_GUARD_S+set}" r
  [ "$k" = "$_FCD_KNOB_KEY" ] && return 0
  _FCD_KNOB_KEY=$k
  r="${FLEET_COOLDOWN_DB:-}|${FLEET_COOLDOWN_CACHE_S:-}|${FLEET_COOLDOWN_CLEAR_GUARD_S:-}"
  # No root (neither HARNESS nor H): env only. lane-gate would fall back to
  # /root/harness for its settings cache, a path outside the caller's root.
  [ -n "$(_fcd_root)" ] && r=$(
    command -v lib_env_apply >/dev/null 2>&1 \
      || { [ -r "$_FCD_LIB/lane-gate.sh" ] && . "$_FCD_LIB/lane-gate.sh" >/dev/null 2>&1; }
    command -v lib_env_apply >/dev/null 2>&1 && lib_env_apply fleet-cooldown >/dev/null 2>&1
    printf '%s|%s|%s' "${FLEET_COOLDOWN_DB:-}" "${FLEET_COOLDOWN_CACHE_S:-}" "${FLEET_COOLDOWN_CLEAR_GUARD_S:-}"
  ) 2>/dev/null || true
  [ -n "$r" ] || r="${FLEET_COOLDOWN_DB:-}|${FLEET_COOLDOWN_CACHE_S:-}|${FLEET_COOLDOWN_CLEAR_GUARD_S:-}"
  IFS='|' read -r _FCD_DB _FCD_CACHE_S _FCD_GUARD_S <<<"$r" || true
  # A row that is not a number falls through to env (then to the code default).
  case "$_FCD_CACHE_S" in *[!0-9]*) _FCD_CACHE_S=${FLEET_COOLDOWN_CACHE_S:-} ;; esac
  case "$_FCD_GUARD_S" in *[!0-9]*) _FCD_GUARD_S=${FLEET_COOLDOWN_CLEAR_GUARD_S:-} ;; esac
  return 0
}

_fcd_backend() {
  _fcd_knobs
  if [ "$_FCD_DB" = 0 ]; then echo off
  elif [ -n "${FLEET_COOLDOWN_STORE:-}" ]; then echo store
  else echo worker; fi
}

# _fcd_key <kind> <vendor> <subject>: rc 0 when the key is well formed.
_fcd_key() {
  case "$1" in account|model|lane) ;; *) return 1 ;; esac
  local f
  for f in "$2" "$3"; do
    case "$f" in ''|*$'\t'*|*$'\n'*) return 1 ;; esac
  done
  return 0
}

# _fcd_store_ok: rc 0 when the store can answer (absent file in an existing dir is fine).
_fcd_store_ok() {
  local s=$FLEET_COOLDOWN_STORE
  [ -d "$(dirname "$s")" ] || return 1
  [ ! -e "$s" ] && return 0
  [ -f "$s" ] && [ -r "$s" ]
}

# Values reach awk through ENVIRON (FCD_K FCD_V FCD_S ...), never -v, which
# would expand a backslash escape in a reason into a tab.
# _fcd_rewrite <awk program>: runs the program over the store
# into a temp file in the same dir and moves it over the store, under a short
# flock on <store>.lock. rc 0 written, 1 failed (the old store is untouched).
_fcd_rewrite() {
  local s=$FLEET_COOLDOWN_STORE prog=$1 tmp rc=1
  tmp=$(mktemp "$s.XXXXXX" 2>/dev/null) || return 1
  {
    if flock -w 5 9; then
      if { [ -e "$s" ] || : > "$s"; } && awk -F'\t' -v OFS='\t' "$prog" "$s" > "$tmp" \
         && mv -f "$tmp" "$s"; then rc=0; fi
    fi
  } 9>>"$s.lock" 2>/dev/null || rc=1
  rm -f "$tmp" 2>/dev/null || true
  return "$rc"
}

# _fcd_client: rc 0 when the cooldown_* verbs are callable. Loads the jobs
# client beside this file on first use, only after checking every module on its
# literal JC_MODULES line is there (the client `exit`s on a missing one, which
# would take the caller with it), and restores the caller's shell options after
# (the client sets -uo pipefail). Memoized per process in _FCD_CLIENT.
_fcd_client() {
  case "${_FCD_CLIENT:-}" in ok) return 0 ;; none) return 1 ;; esac
  _FCD_CLIENT=none
  if ! command -v _jobs_req >/dev/null 2>&1 || ! command -v cooldown_list >/dev/null 2>&1; then
    local _fcd_c _fcd_m _fcd_mods _fcd_opts _fcd_rc=0
    _fcd_c="$(dirname "${BASH_SOURCE[0]}")/../jobs-client.sh"
    [ -r "$_fcd_c" ] || return 1
    _fcd_mods=$(sed -n 's/^JC_MODULES="\(.*\)"$/\1/p' "$_fcd_c" 2>/dev/null)
    [ -n "$_fcd_mods" ] || return 1
    for _fcd_m in $_fcd_mods; do
      [ -r "$(dirname "$_fcd_c")/lib/jobs/$_fcd_m.sh" ] || return 1
    done
    _fcd_opts=$(set +o)
    # shellcheck source=/dev/null
    . "$_fcd_c" >/dev/null 2>&1 || _fcd_rc=1
    eval "$_fcd_opts"
    [ "$_fcd_rc" = 0 ] || return 1
    command -v _jobs_req >/dev/null 2>&1 && command -v cooldown_list >/dev/null 2>&1 || return 1
  fi
  _FCD_CLIENT=ok
}

# _fcd_state: the box's cache and guard dir, under $HARNESS (else $H). Created on
# the first write only. rc 1 and nothing printed when neither is set: then there
# is no cache and no guard, and no path outside the caller's root is touched.
_fcd_root() { printf '%s' "${HARNESS:-${H:-}}"; }
_fcd_state() {
  [ -n "$(_fcd_root)" ] || return 1
  printf '%s/state/fleet-cooldown' "$(_fcd_root)"
}

# _fcd_int <value> <fallback>: a non-negative integer, else the fallback.
_fcd_int() { case "$1" in ''|*[!0-9]*) echo "$2" ;; *) echo "$1" ;; esac; }

# _fcd_forget <kind>: drop the kind's memo and the box cache of that kind, so
# this process and the next ones on the box read its own write.
_fcd_forget() {
  local d
  unset "_FCD_ROWS_$1" "_FCD_RC_$1"
  d=$(_fcd_state) || return 0
  rm -f "$d/cache.$1.tsv" 2>/dev/null || true
}

# _fcd_cache_load <kind>: rc 0 and the memo set from a box cache younger than
# FLEET_COOLDOWN_CACHE_S; rc 1 when there is none, it is stale, or unreadable.
_fcd_cache_load() {
  local f ttl at rc now d
  _fcd_knobs
  ttl=$(_fcd_int "$_FCD_CACHE_S" 20)
  [ "$ttl" -gt 0 ] || return 1
  d=$(_fcd_state) || return 1
  f="$d/cache.$1.tsv"
  [ -f "$f" ] && [ -r "$f" ] || return 1
  IFS=$'\t' read -r at rc < "$f" 2>/dev/null || return 1
  case "$at" in ''|*[!0-9]*) return 1 ;; esac
  case "$rc" in 0|1) ;; *) return 1 ;; esac
  now=$(date +%s)
  [ "$at" -le "$now" ] && [ $(( now - at )) -lt "$ttl" ] || return 1
  printf -v "_FCD_ROWS_$1" '%s' "$(tail -n +2 "$f" 2>/dev/null)"
  printf -v "_FCD_RC_$1" '%s' "$rc"
}

# _fcd_get <kind>: one cooldown_list into the memo; a complete answer (rc 0 or
# 1) is also written to the box cache (temp file + mv). Always rc 0.
_fcd_get() {
  local k=$1 rows="" rc=0 d tmp
  rows=$(cooldown_list "$k") || rc=$?
  case "$rc" in 0|1) ;; *) rc=2 ;; esac
  printf -v "_FCD_ROWS_$k" '%s' "$rows"
  printf -v "_FCD_RC_$k" '%s' "$rc"
  [ "$rc" = 2 ] && return 0
  _fcd_knobs
  [ "$(_fcd_int "$_FCD_CACHE_S" 20)" -gt 0 ] || return 0
  d=$(_fcd_state) || return 0
  mkdir -p "$d" 2>/dev/null && tmp=$(mktemp "$d/cache.$k.XXXXXX" 2>/dev/null) || return 0
  if printf '%s\t%s\n%s\n' "$(date +%s)" "$rc" "$rows" 2>/dev/null > "$tmp"; then
    mv -f "$tmp" "$d/cache.$k.tsv" 2>/dev/null || rm -f "$tmp" 2>/dev/null || true
  else
    rm -f "$tmp" 2>/dev/null || true
  fi
  return 0
}

# _fcd_fetch <kind>: the kind's rows into _FCD_ROWS_<kind> (the TSV) and
# _FCD_RC_<kind> (0 rows, 1 none, 2 unknown): the process memo, else a fresh box
# cache, else one GET under the kind's lock (re-checking the cache once the lock
# is held, so the processes that queued behind the reader use its answer). A
# lock not had within 10 s reads anyway: a slow box costs a GET, never an answer.
_fcd_fetch() {
  local k=$1 have="_FCD_RC_$1" d
  [ -n "${!have:-}" ] && return 0
  _fcd_cache_load "$k" && return 0
  if ! _fcd_client; then
    printf -v "_FCD_ROWS_$k" '%s' ""; printf -v "_FCD_RC_$k" '%s' 2; return 0
  fi
  # The lock file is opened in the condition first, so a root this caller cannot
  # write skips the lock instead of failing the redirection (fatal under set -e).
  _fcd_knobs
  if d=$(_fcd_state) && [ "$(_fcd_int "$_FCD_CACHE_S" 20)" -gt 0 ] && command -v flock >/dev/null 2>&1 \
     && mkdir -p "$d" 2>/dev/null && { : >> "$d/cache.$k.lock"; } 2>/dev/null; then
    { flock -w 10 8 || true
      _fcd_cache_load "$k" || _fcd_get "$k"; } 8>>"$d/cache.$k.lock" || true
  fi
  [ -n "${!have:-}" ] || _fcd_get "$k"
  return 0
}

# _fcd_tomb <vendor> <subject>: the reseed-guard file of one lane; rc 1 when
# there is no state dir (no guard).
_fcd_tomb() {
  local d
  d=$(_fcd_state) || return 1
  printf '%s/cleared.lane.%s' "$d" "$(printf '%s.%s' "$1" "$2" | tr -c 'A-Za-z0-9._-' _)"
}

# _fcd_guard_s: the guard in seconds, min(CLEAR_GUARD_S, LANE_DOWN_TTL_S).
_fcd_guard_s() {
  local g t
  _fcd_knobs
  g=$(_fcd_int "$_FCD_GUARD_S" 600)
  t=$(_fcd_int "${LANE_DOWN_TTL_S:-}" 7200)
  [ "$t" -gt 0 ] || t=7200
  [ "$t" -lt "$g" ] && g=$t
  echo "$g"
}

# _fcd_tomb_gc <guard>: remove each tomb in the state dir whose file is older
# than 2x the guard and whose hide mark is past (or unreadable). A tomb still
# hiding stays, and one whose age cannot be read stays. No state dir (neither
# HARNESS nor H set) = nothing is globbed or removed. Always rc 0.
_fcd_tomb_gc() {
  local f m h now old d
  d=$(_fcd_state) || return 0
  [ -d "$d" ] || return 0
  now=$(date +%s)
  old=$(( now - 2 * $1 ))
  for f in "$d"/cleared.lane.*; do
    [ -f "$f" ] || continue
    m=$(stat -c %Y "$f" 2>/dev/null) || continue
    case "$m" in ''|*[!0-9]*) continue ;; esac
    [ "$m" -lt "$old" ] || continue
    h=$(cut -f3 "$f" 2>/dev/null | head -n 1) || h=""
    case "$h" in ''|*[!0-9]*) ;; *) [ "$h" -le "$now" ] || continue ;; esac
    rm -f "$f" 2>/dev/null || true
  done
  return 0
}

# _fcd_tomb_write <vendor> <subject>: arm the guard before a lane clear. The
# hide mark is the latest until the fleet shows for the lane right now, or
# now + the guard (_fcd_guard_s) when that is later. Old tombs go first.
_fcd_tomb_write() {
  local g now seen hide d
  g=$(_fcd_guard_s)
  _fcd_tomb_gc "$g" || true
  [ "$g" -gt 0 ] || return 0
  d=$(_fcd_state) || return 0
  now=$(date +%s)
  # shellcheck disable=SC2016
  seen=$(_fcd_list_raw lane | FCD_V=$1 FCD_S=$2 awk -F'\t' \
    '$1==ENVIRON["FCD_V"] && $2==ENVIRON["FCD_S"] && $3+0 > m { m=$3+0 } END { printf "%d", m }' 2>/dev/null) || seen=0
  hide=$(( now + g ))
  [ "$(_fcd_int "$seen" 0)" -gt "$hide" ] && hide=$seen
  mkdir -p "$d" 2>/dev/null || return 0
  printf '%s\t%s\t%s\n' "$1" "$2" "$hide" 2>/dev/null > "$(_fcd_tomb "$1" "$2")" || true
  return 0
}

# _fcd_unseed: filter lane rows on stdin, dropping each row of a guarded lane
# whose until is not past the guard's hide mark. An expired guard is ignored.
_fcd_unseed() {
  local tombs d
  if ! d=$(_fcd_state); then cat; return 0; fi
  tombs=$(cat "$d"/cleared.lane.* 2>/dev/null) || true
  if [ -z "$tombs" ]; then cat; return 0; fi
  # shellcheck disable=SC2016
  FCD_TOMBS=$tombs FCD_NOW=$(date +%s) awk -F'\t' '
    BEGIN { n = split(ENVIRON["FCD_TOMBS"], L, "\n")
            for (i = 1; i <= n; i++) { split(L[i], f, "\t")
              if (f[3] + 0 > ENVIRON["FCD_NOW"] + 0) h[f[1] SUBSEP f[2]] = f[3] + 0 } }
    !((($1 SUBSEP $2) in h) && $3 + 0 <= h[$1 SUBSEP $2])'
  return 0
}

# _fcd_rows <kind>: the memo rows whose until is still ahead of now.
_fcd_rows() {
  local v="_FCD_ROWS_$1"
  # shellcheck disable=SC2016
  FCD_NOW=$(date +%s) awk -F'\t' '$3+0 > ENVIRON["FCD_NOW"]+0' <<< "${!v:-}" 2>/dev/null || true
}

_fcd_worker_put() {
  local rc=0
  if _fcd_client; then cooldown_put "$@" || rc=$?; else rc=2; fi
  if [ "$rc" = 0 ]; then
    _fcd_forget "$1"
  elif [ -n "$(_fcd_root)" ]; then
    printf '%s fleet-cooldown: put %s/%s/%s not recorded (rc %s)\n' \
      "$(date -u '+%Y-%m-%d %H:%M:%SZ')" "$1" "$2" "$3" "$rc" \
      2>/dev/null >> "$(_fcd_root)/logs/agent-rules.log" || true
  fi
  return 0
}

fcd_put() {
  _fcd_knobs
  local kind=${1:-} vendor=${2:-} subject=${3:-} until=${4:-} since=${5:-} reason=${6:-} tomb
  _fcd_key "$kind" "$vendor" "$subject" || return 0
  case "$until" in ''|*[!0-9]*) return 0 ;; esac
  case "$since" in *[!0-9]*) return 0 ;; esac
  # Never a bare && ending in rm: under set -e a failed rm (EACCES) killed the
  # caller (ld_mark, #2552 review). A guard that cannot be lifted is left alone.
  if [ "$kind" = lane ] && tomb=$(_fcd_tomb "$vendor" "$subject"); then
    rm -f "$tomb" 2>/dev/null || true
  fi
  case "$(_fcd_backend)" in
    worker) _fcd_worker_put "$kind" "$vendor" "$subject" "$until" "$since" "$reason"; return 0 ;;
    store) ;;
    *) return 0 ;;
  esac
  _fcd_store_ok || return 0
  reason=${reason//$'\t'/ }; reason=${reason//$'\n'/ }; reason=${reason//$'\r'/ }
  local box now
  box=$(hostname 2>/dev/null) || box=unknown
  now=$(date +%s)
  # shellcheck disable=SC2016
  FCD_K=$kind FCD_V=$vendor FCD_S=$subject FCD_U=$until FCD_SI=$since \
  FCD_R=$reason FCD_B=$box FCD_T=$now _fcd_rewrite '
    BEGIN { k=ENVIRON["FCD_K"]; v=ENVIRON["FCD_V"]; s=ENVIRON["FCD_S"]; u=ENVIRON["FCD_U"]
            si=ENVIRON["FCD_SI"]; r=ENVIRON["FCD_R"]; b=ENVIRON["FCD_B"]; t=ENVIRON["FCD_T"] }
    $1==k && $2==v && $3==s { found=1
      if (k != "lane" && $4+0 > u+0) u=$4
      if ($5 != "") si=$5
      print k, v, s, u, si, r, b, t; next }
    { print }
    END { if (!found) print k, v, s, u, si, r, b, t }' || true
  return 0
}

fcd_clear() {
  _fcd_knobs
  local kind=${1:-} vendor=${2:-} subject=${3:-}
  _fcd_key "$kind" "$vendor" "$subject" || return 2
  if [ "$kind" = lane ] && [ "$(_fcd_backend)" != off ]; then
    _fcd_tomb_write "$vendor" "$subject" || true
  fi
  case "$(_fcd_backend)" in
    worker)
      _fcd_client || return 2
      local wrc=0
      cooldown_clear "$kind" "$vendor" "$subject" || wrc=$?
      _fcd_forget "$kind"
      case "$wrc" in 0|1) return "$wrc" ;; *) return 2 ;; esac ;;
    store) ;;
    *) return 2 ;;
  esac
  _fcd_store_ok || return 2
  [ -e "$FLEET_COOLDOWN_STORE" ] || return 1
  # One marker per call: $$ is the parent pid in every ( ... ) & subshell, so a
  # pid-keyed name let concurrent clears eat each other's answer.
  local marker rc=1
  marker=$(mktemp "$FLEET_COOLDOWN_STORE.cleared.XXXXXX" 2>/dev/null) || return 2
  # shellcheck disable=SC2016
  if FCD_K=$kind FCD_V=$vendor FCD_S=$subject FCD_M=$marker _fcd_rewrite '
    BEGIN { k=ENVIRON["FCD_K"]; v=ENVIRON["FCD_V"]; s=ENVIRON["FCD_S"] }
    $1==k && $2==v && $3==s { hit=1; next } { print }
    END { if (hit) print "1" > ENVIRON["FCD_M"] }'; then
    [ -s "$marker" ] && rc=0
  else
    rc=2
  fi
  rm -f "$marker" 2>/dev/null || true
  return "$rc"
}

fcd_live() {
  _fcd_knobs
  local rc=0
  _fcd_live_raw "$@" || rc=$?
  local tomb
  [ "$rc" = 0 ] && [ "${1:-}" = lane ] && tomb=$(_fcd_tomb "${2:-}" "${3:-}") && [ -f "$tomb" ] || return "$rc"
  # A live row for a lane this box cleared: live only if a row outlasts the guard.
  # shellcheck disable=SC2016
  _fcd_list_raw lane | _fcd_unseed | FCD_V=${2:-} FCD_S=${3:-} awk -F'\t' \
    '$1==ENVIRON["FCD_V"] && $2==ENVIRON["FCD_S"] { hit=1 } END { exit hit ? 0 : 1 }'
}

_fcd_live_raw() {
  local kind=${1:-} vendor=${2:-} subject=${3:-}
  _fcd_key "$kind" "$vendor" "$subject" || return 2
  case "$(_fcd_backend)" in
    worker)
      _fcd_fetch "$kind"
      local memo="_FCD_RC_$kind"
      # shellcheck disable=SC2016
      _fcd_rows "$kind" | FCD_V=$vendor FCD_S=$subject awk -F'\t' \
        '$1==ENVIRON["FCD_V"] && $2==ENVIRON["FCD_S"] { hit=1 } END { exit hit ? 0 : 1 }' && return 0
      [ "${!memo}" = 2 ] && return 2
      return 1 ;;
    store) ;;
    *) return 2 ;;
  esac
  _fcd_store_ok || return 2
  [ -e "$FLEET_COOLDOWN_STORE" ] || return 1
  local rc=0
  # shellcheck disable=SC2016
  FCD_K=$kind FCD_V=$vendor FCD_S=$subject FCD_NOW=$(date +%s) awk -F'\t' '
    $1==ENVIRON["FCD_K"] && $2==ENVIRON["FCD_V"] && $3==ENVIRON["FCD_S"] && $4+0 > ENVIRON["FCD_NOW"]+0 { hit=1 }
    END { exit hit ? 0 : 1 }' "$FLEET_COOLDOWN_STORE" 2>/dev/null || rc=$?
  case "$rc" in 0|1) return "$rc" ;; *) return 2 ;; esac
}

fcd_list() {
  _fcd_knobs
  if [ "${1:-}" = lane ]; then _fcd_list_raw lane | _fcd_unseed || true; else _fcd_list_raw "${1:-}" || true; fi
  return 0
}

_fcd_list_raw() {
  local kind=${1:-}
  case "$kind" in account|model|lane) ;; *) return 0 ;; esac
  case "$(_fcd_backend)" in
    worker) _fcd_fetch "$kind"; _fcd_rows "$kind"; return 0 ;;
    store) ;;
    *) return 0 ;;
  esac
  _fcd_store_ok || return 0
  [ -e "$FLEET_COOLDOWN_STORE" ] || return 0
  # shellcheck disable=SC2016
  FCD_K=$kind FCD_NOW=$(date +%s) awk -F'\t' -v OFS='\t' \
    '$1==ENVIRON["FCD_K"] && $4+0 > ENVIRON["FCD_NOW"]+0 { print $2, $3, $4, $5, $6, $7 }' \
    "$FLEET_COOLDOWN_STORE" 2>/dev/null || true
  return 0
}
