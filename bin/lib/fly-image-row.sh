#!/bin/bash
# bin/lib/fly-image-row.sh — BH-2523: the fly_images row seam. The Fly builder
# image a project's pool dispatches from, what it baked and when, as a row on
# the jobs worker (worker/jobs/src/routes/fly-images.js), so a fresh hub reads
# the live digest instead of rebuilding it.
# Sourced, never executed. Defines functions only: sourcing reads, writes and
# prints nothing, and every function is safe to call under set -euo pipefail.
#
#   fir_put      <project> <app> <digest> [bake-file] [cli-file] [baked_at] [active] [state]
#                rc 0 recorded, or nothing to record against (off, no client,
#                no HARNESS_SECRET or JOBS_URL on this box: it can read no row
#                either). rc 3 NOT recorded: refused here (bad project, app or
#                digest, a digest not under registry.fly.io/<app>:, a baked_at
#                that is not an epoch, a state other than baked or
#                smoke_failed, a state together with active=1) or by the
#                worker, or no answer from it.
#                state (BH-2743) records a row WITHOUT activating it: `baked`
#                is a candidate the rollout has not smoke-tested, `smoke_failed`
#                one whose smoke did not pass. The worker sets `active` and
#                `demoted` itself on an activating put.
#                A caller never lets rc 3 fail its build or rollout.
#                An empty or missing file, an empty baked_at, an empty state
#                and an active that is not 1 are left out of the body, so the worker keeps what it
#                stored. A put not recorded leaves one line in
#                logs/fly-image-build.log under $HARNESS (else $H).
#   The stale marker: rc 3 also writes state/fly/<project>.row-stale (the time
#                and the digest that did not land). While it exists every read
#                for that project is rc 2, so THIS hub's readers use their
#                state/fly files, which were written first and are right: a
#                lost put must never leave the row, and not the file, deciding
#                what this hub boots (BH-666 — the row could still name bits
#                whose smoke failed). The next recorded put with active=1 for
#                the project removes it.
#   fir_load     <project>   the one GET, memoized in the CALLING shell. Call it
#                in the main shell before reading through $( ... ), or every
#                subshell pays its own GET. rc as fir_active.
#   fir_active   <project>   prints digest<TAB>app<TAB>baked_at
#   fir_digest   <project>   prints the active digest
#   fir_baked_at <project>   prints baked_at when it is a non-negative integer
#   fir_bake_to  <project> <file>   writes the row's bake manifest into <file>
#                (one name=version per line, as state/fly/<p>.bake)
# Read rcs: 0 an answer was printed (or written), 1 the worker said there is
# none (no active row, or that field is empty), 2 unknown (off, no client, no
# worker, an answer that does not parse, names another project or carries a
# digest that is not a registry.fly.io/<app>: ref, or the stale marker is
# there). Every reader falls back to its state/fly file on anything but 0.
#
# Knob: FLY_IMAGES_DB (catalog/lanes.d/_lib.fly-image-row.json). 0 turns every
# function into a no-op: put rc 0 and sends nothing, reads rc 2. Resolved as
# operator row (settings key lib.fly-image-row.fly_images_db) > cached row > env
# > on, through lane-gate.sh's lib_env_apply in a subshell on the first fir_*
# call, never at source time; anything failing in there leaves the env value.
# With no root (neither HARNESS nor H) there is no settings read.
#
# The client: _jobs_req from bin/jobs-client.sh beside this lib, loaded on the
# first call when the caller has not already sourced it, only after every
# module on its literal JC_MODULES line is present (the client `exit`s on a
# missing one), restoring the caller's shell options after.
# Requests go out with JOBS_ALERT=0: this row is optional evidence with a
# documented answer for "no answer" (the state/fly file), so an outage here is
# the client's log line plus this seam's own, and the ALERTS page stays with
# the lanes that depend on the worker.

_FIR_LIB="$(dirname "${BASH_SOURCE[0]}")"
_FIR_DIGEST_RE='^registry\.fly\.io/[A-Za-z0-9._-]+:[A-Za-z0-9._-]+$'
_FIR_NAME_RE='^[A-Za-z0-9._-]{1,64}$'
_FIR_KNOB_KEY=none; _FIR_DB=""; _FIR_CLIENT=""
declare -gA _FIR_ROW=() _FIR_RC=()

_fir_root() { printf '%s' "${HARNESS:-${H:-}}"; }

# _fir_on: rc 0 unless FLY_IMAGES_DB resolves to 0. Once per process per env value.
_fir_on() {
  local k="${FLY_IMAGES_DB-}|${FLY_IMAGES_DB+set}" r=""
  if [ "$k" != "$_FIR_KNOB_KEY" ]; then
    _FIR_KNOB_KEY=$k
    [ -n "$(_fir_root)" ] && r=$(
      command -v lib_env_apply >/dev/null 2>&1 \
        || { [ -r "$_FIR_LIB/lane-gate.sh" ] && . "$_FIR_LIB/lane-gate.sh" >/dev/null 2>&1; }
      command -v lib_env_apply >/dev/null 2>&1 && lib_env_apply fly-image-row >/dev/null 2>&1
      printf 'v=%s' "${FLY_IMAGES_DB:-}"
    ) 2>/dev/null || r=""
    case "$r" in v=*) _FIR_DB=${r#v=} ;; *) _FIR_DB=${FLY_IMAGES_DB:-} ;; esac
  fi
  [ "${_FIR_DB:-1}" != 0 ]
}

# _fir_client: rc 0 when _jobs_req is callable. Memoized per process.
_fir_client() {
  command -v _jobs_req >/dev/null 2>&1 && return 0
  [ "$_FIR_CLIENT" = none ] && return 1
  _FIR_CLIENT=none
  local c m mods opts e rc=0
  c="$_FIR_LIB/../jobs-client.sh"
  [ -r "$c" ] || return 1
  mods=$(sed -n 's/^JC_MODULES="\(.*\)"$/\1/p' "$c" 2>/dev/null)
  [ -n "$mods" ] || return 1
  for m in $mods; do [ -r "$_FIR_LIB/jobs/$m.sh" ] || return 1; done
  # $(set +o) runs where bash has already dropped errexit, so -e is kept by hand.
  opts=$(set +o); e=$-
  # shellcheck source=/dev/null
  . "$c" >/dev/null 2>&1 || rc=1
  eval "$opts"
  case "$e" in *e*) set -e ;; esac
  [ "$rc" = 0 ] && command -v _jobs_req >/dev/null 2>&1
}

# _fir_stale <project>: the stale marker's path, empty with no root.
_fir_stale() { local r; r=$(_fir_root); [ -z "$r" ] || printf '%s/state/fly/%s.row-stale' "$r" "$1"; }

# _fir_unrecorded <project> <digest> <why>: the log line and the marker. rc 0,
# so it is safe under a caller's set -e; fir_put returns the 3 itself.
_fir_unrecorded() {
  local m; m=$(_fir_stale "$1")
  _fir_log "fly_images PUT $1 $2 not recorded ($3) — state/fly files still hold it; this hub reads them until a put lands${m:+ ($m)}"
  if [ -n "$m" ]; then
    mkdir -p "${m%/*}" 2>/dev/null
    printf '%s %s\n' "$(date -u +%s)" "$2" > "$m" 2>/dev/null
  fi
  return 0
}

_fir_log() {
  local root; root=$(_fir_root)
  [ -n "$root" ] || return 0
  mkdir -p "$root/logs" 2>/dev/null
  printf '%s [fly-image-row] %s\n' "$(date -u '+%Y-%m-%d %H:%M:%SZ')" "$*" >> "$root/logs/fly-image-build.log" 2>/dev/null
  return 0
}

fir_put() {
  local p="${1:-}" app="${2:-}" d="${3:-}" bf="${4:-}" cf="${5:-}" at="${6:-}" act="${7:-}" st="${8:-}"
  local bake="" cli="" body resp rc=0 m
  _fir_on || return 0
  [[ "$p" =~ $_FIR_NAME_RE ]] || { _fir_log "fly_images PUT '$p' refused locally: bad project"; return 3; }
  if ! [[ "$app" =~ $_FIR_NAME_RE && "$d" =~ $_FIR_DIGEST_RE && "$d" == "registry.fly.io/$app:"* ]]; then
    _fir_unrecorded "$p" "$d" "refused locally: bad app, or digest not under registry.fly.io/$app:"; return 3
  fi
  case "$at" in *[!0-9]*) _fir_unrecorded "$p" "$d" "refused locally: baked_at '$at' is not an epoch"; return 3 ;; esac
  case "$st" in ''|baked|smoke_failed) ;; *) _fir_unrecorded "$p" "$d" "refused locally: state '$st' is not baked or smoke_failed"; return 3 ;; esac
  if [ -n "$st" ] && [ "$act" = 1 ]; then _fir_unrecorded "$p" "$d" "refused locally: state '$st' with active=1 (the worker sets state on activation)"; return 3; fi
  [ -n "$bf" ] && [ -s "$bf" ] && bake=$(cat "$bf" 2>/dev/null; printf x) && bake=${bake%x}
  [ -n "$cf" ] && [ -s "$cf" ] && cli=$(cat "$cf" 2>/dev/null; printf x) && cli=${cli%x}
  body=$(jq -nc --arg p "$p" --arg a "$app" --arg d "$d" --arg bk "$bake" --arg cl "$cli" \
                --arg at "$at" --arg act "$act" --arg st "$st" --arg box "${JOBS_BOX:-}" \
    '{project:$p,app:$a,digest:$d}
     + (if $bk == "" then {} else {bake:$bk} end)
     + (if $cl == "" then {} else {cli:$cl} end)
     + (if $at == "" then {} else {baked_at:($at|tonumber)} end)
     + (if $act == "1" then {active:1} else {} end)
     + (if $st == "" then {} else {state:$st} end)
     + (if $box == "" then {} else {box:$box} end)' 2>/dev/null) || { _fir_unrecorded "$p" "$d" "not sent: jq failed"; return 3; }
  unset '_FIR_ROW[$p]' '_FIR_RC[$p]'
  # No client, or no worker this box can reach at all: nothing is recorded, and
  # nothing here reads the row either, so there is nothing to go stale.
  if ! _fir_client; then _fir_log "fly_images PUT $p $d not sent: no jobs client"; return 0; fi
  if [ -z "${HARNESS_SECRET:-}" ] || [ -z "${JOBS_URL:-}" ]; then
    _fir_log "fly_images PUT $p $d not sent: no HARNESS_SECRET or JOBS_URL on this box"; return 0
  fi
  resp=$(JOBS_ALERT=0 _jobs_req PUT /api/fly-images "$body") || rc=$?
  if [ "$rc" != 0 ] || ! printf '%s' "$resp" | jq -e '.ok == true' >/dev/null 2>&1; then
    _fir_unrecorded "$p" "$d" "rc=$rc http=${JOBS_HTTP:-none}"; return 3
  fi
  [ "$act" = 1 ] && { m=$(_fir_stale "$p"); [ -z "$m" ] || rm -f "$m" 2>/dev/null; }
  return 0
}

fir_load() {
  local p="${1:-}" resp rc=0 row m
  _fir_on || return 2
  [[ "$p" =~ $_FIR_NAME_RE ]] || return 2
  m=$(_fir_stale "$p"); [ -n "$m" ] && [ -e "$m" ] && return 2
  if [ -n "${_FIR_RC[$p]+set}" ]; then return "${_FIR_RC[$p]}"; fi
  if ! _fir_client; then _FIR_RC[$p]=2; _FIR_ROW[$p]=""; return 2; fi
  resp=$(JOBS_ALERT=0 _jobs_req GET "/api/fly-images?project=$p") || rc=$?
  if [ "$rc" != 0 ]; then
    rc=2; row=""
  elif ! printf '%s' "$resp" | jq -e 'has("row")' >/dev/null 2>&1; then
    rc=2; row=""
  elif printf '%s' "$resp" | jq -e '.row == null' >/dev/null 2>&1; then
    rc=1; row=""
  else
    row=$(printf '%s' "$resp" | jq -c --arg p "$p" '.row | select(.project == $p)' 2>/dev/null)
    local d a
    d=$(printf '%s' "$row" | jq -r '.digest // ""' 2>/dev/null); a=$(printf '%s' "$row" | jq -r '.app // ""' 2>/dev/null)
    if [ -n "$row" ] && [[ "$d" =~ $_FIR_DIGEST_RE && "$a" =~ $_FIR_NAME_RE && "$d" == "registry.fly.io/$a:"* ]]; then rc=0
    else rc=2; row=""; fi
  fi
  _FIR_RC[$p]=$rc; _FIR_ROW[$p]=$row
  return "$rc"
}

# _fir_field <project> <jq-filter>: the field as text, rc 1 when it is empty.
_fir_field() {
  local rc=0 v
  fir_load "$1" || rc=$?
  [ "$rc" = 0 ] || return "$rc"
  v=$(printf '%s' "${_FIR_ROW[$1]}" | jq -r "$2 // \"\"" 2>/dev/null) || return 2
  [ -n "$v" ] || return 1
  printf '%s' "$v"
}

fir_active() {
  local rc=0 v
  fir_load "${1:-}" || rc=$?
  [ "$rc" = 0 ] || return "$rc"
  v=$(printf '%s' "${_FIR_ROW[$1]}" | jq -r '[.digest, .app, (.baked_at // "" | tostring)] | join("\t")' 2>/dev/null) || return 2
  printf '%s\n' "$v"
}

fir_digest() { _fir_field "${1:-}" .digest; }

fir_baked_at() {
  local rc=0 v
  fir_load "${1:-}" || rc=$?
  [ "$rc" = 0 ] || return "$rc"
  v=$(printf '%s' "${_FIR_ROW[$1]}" | jq -r '.baked_at // "" | tostring' 2>/dev/null) || return 2
  case "$v" in ''|*[!0-9]*) return 1 ;; esac
  printf '%s' "$v"
}

fir_bake_to() {
  local rc=0 v
  [ -n "${2:-}" ] || return 2
  fir_load "${1:-}" || rc=$?
  [ "$rc" = 0 ] || return "$rc"
  v=$(printf '%s' "${_FIR_ROW[$1]}" | jq -r '.bake // ""' 2>/dev/null) || return 2
  [ -n "$v" ] || return 1
  printf '%s\n' "$v" | sed '/^$/d' > "$2" 2>/dev/null || return 2
  return 0
}
