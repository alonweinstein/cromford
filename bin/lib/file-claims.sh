#!/bin/bash
# bin/lib/file-claims.sh — FLEET FILE CLAIMS (BH-2627 contract, BH-2628 behaviour; BH-2524).
# Sourced, never executed; defines functions only, and nothing runs at source
# time.
#
# Build claims and overlap-defer are box-local today (state/claims,
# state/overlap-defer), so overlap serialisation cannot see other boxes. This lib
# is the fleet side, held on the build's job_claims row. It is ADDED next to the
# box-local files and never replaces them, so a worker outage degrades to
# today's behaviour.
#
# The worker side is worker/jobs/src/routes/file-claims.js (PUT
# /api/jobs/:id/file-claim, GET /api/file-claims, BH-2628). Nothing in the
# pipeline calls these functions yet; the callers land in the later slices of
# BH-2524. The caller must already have sourced bin/jobs-client.sh: this lib
# uses its _jobs_req and never loads it, so with no _jobs_req in scope every
# function fails open. The interface:
#
# fclaim_put <planned-files.txt> [job_id=$JOB_ID]
# fclaim_not_before_put <secs> [job_id=$JOB_ID]
#   rc 0 written, rc != 0 not written (outage, no JOBS_URL, no job id, empty
#   list). The claim's ttl is the knob FILE_CLAIM_TTL_S (lib.file-claims).
#
# fclaim_list_dir <project> <outdir>
#   rc 0 = the worker answered; writes <outdir>/<KEY> (newline file list, one per
#   claiming key, first row per key wins, the caller's own key included) and
#   <outdir>/.claimed_at (TSV KEY<TAB>files_claimed_at). rc 1 = outage, dir left
#   empty, caller must NOT read it as "nobody claims". Truncated -> stderr
#   `FILE_CLAIMS_INCOMPLETE <project>: >200 live claims, remainder not judged`.
#   Keys failing ^[A-Za-z0-9._-]{1,64}$ are skipped, never written as paths.
#
# fclaim_not_before_left <project> <key>
#   Prints left_s when a live window exists, nothing otherwise.
#
# All four fail open: rc != 0 and no stdout on any failure.

# Keys become file names and query values: ^[A-Za-z0-9._-]{1,64}$ or nothing.
fclaim__key() {
  [[ "${1-}" =~ ^[A-Za-z0-9._-]{1,64}$ ]] && printf '%s' "$1"
}

fclaim__ready() {
  command -v _jobs_req >/dev/null 2>&1
}

# The claim ttl: the lib.file-claims knob through lane-gate's lib_env_apply (in
# a subshell, only when the caller has a harness root), then env, then 14400,
# the registry default in catalog/lanes.d/_lib.file-claims.json. Never clamped:
# an out-of-range value gets the worker's 400 and fclaim_put fails open.
fclaim__ttl() {
  local v="" lib
  lib=$(dirname "${BASH_SOURCE[0]}")
  if [ -n "${HARNESS:-${H:-}}" ]; then
    v=$(
      command -v lib_env_apply >/dev/null 2>&1 || . "$lib/lane-gate.sh" >/dev/null 2>&1
      lib_env_apply file-claims >/dev/null 2>&1
      printf '%s' "${FILE_CLAIM_TTL_S:-}"
    ) 2>/dev/null
  fi
  [[ "$v" =~ ^[0-9]+$ ]] || v=${FILE_CLAIM_TTL_S:-}
  [[ "$v" =~ ^[0-9]+$ ]] || v=14400
  printf '%s' "$v"
}

# fclaim__send <job_id> <json-body>: the PUT; rc 0 only on a 2xx, never prints.
fclaim__send() {
  [[ "$1" =~ ^[A-Za-z0-9._-]+$ ]] || return 1
  fclaim__ready || return 1
  _jobs_req PUT "/api/jobs/$1/file-claim" "$2" >/dev/null 2>&1 || return 1
}

fclaim_put() {
  local file="${1-}" jid="${2:-${JOB_ID:-}}" ttl body
  [ -n "$file" ] && [ -r "$file" ] || return 1
  grep -q '[^[:space:]]' "$file" 2>/dev/null || return 1
  [[ "$jid" =~ ^[A-Za-z0-9._-]+$ ]] || return 1
  fclaim__ready || return 1
  ttl=$(fclaim__ttl)
  # Trailing newlines are dropped so fclaim_list_dir's printf '%s\n' writes the
  # list back byte for byte.
  body=$(jq -cn --rawfile f "$file" --argjson ttl "$ttl" '{files: ($f | sub("\n+$"; "")), ttl_s: $ttl}' 2>/dev/null) \
    || return 1
  fclaim__send "$jid" "$body"
}

fclaim_not_before_put() {
  local secs="${1-}" jid="${2:-${JOB_ID:-}}"
  [[ "$secs" =~ ^[0-9]+$ ]] || return 1
  fclaim__send "$jid" "{\"not_before_s\":$((10#$secs))}"
}

fclaim_list_dir() {
  local p out="${2-}" ans stage key at files moved=() f
  p=$(fclaim__key "${1-}") || return 1
  [ -n "$out" ] && [ -d "$out" ] || return 1
  fclaim__ready || return 1
  ans=$(_jobs_req GET "/api/file-claims?project=$p" 2>/dev/null) || return 1
  # A 200 that is not the contract is an outage, never "no claims".
  printf '%s' "$ans" | jq -e '(.claims | type) == "array"' >/dev/null 2>&1 || return 1
  stage=$(mktemp -d "$out/.fc.XXXXXX" 2>/dev/null) || return 1
  : >"$stage/.claimed_at" || { rm -rf "$stage"; return 1; }
  # Response order is files_claimed_at ascending, so the first row per key wins.
  # jq drops rows whose key is not key-shaped (tab is IFS whitespace, so an
  # empty field would shift the rest), and the shell checks the key again.
  while IFS=$'\t' read -r key at files; do
    key=$(fclaim__key "$key") || continue
    # A dot-led key ("." "..", ".claimed_at") would name this dir or its index.
    case "$key" in .*) continue ;; esac
    [ -e "$stage/$key" ] && continue
    { printf '%s\n' "$files" | base64 -d >"$stage/$key" \
        && printf '%s\t%s\n' "$key" "$at" >>"$stage/.claimed_at"; } 2>/dev/null \
      || { rm -rf "$stage"; return 1; }
  done < <(printf '%s' "$ans" | jq -r '.claims[]
      | select((.ticket_id | type) == "string" and (.ticket_id | test("^[A-Za-z0-9._-]{1,64}$")))
      | [.ticket_id, (.files_claimed_at // "-" | tostring),
         ((.planned_files // "" | tostring | sub("\n+$"; "")) + "\n" | @base64)] | @tsv' 2>/dev/null)
  for f in "$stage"/* "$stage/.claimed_at"; do
    [ -e "$f" ] || continue
    if mv -f "$f" "$out/" 2>/dev/null; then moved+=("$out/${f##*/}")
    else rm -rf "$stage" "${moved[@]}"; return 1; fi
  done
  rm -rf "$stage"
  if [ "$(printf '%s' "$ans" | jq -r '.truncated == true' 2>/dev/null)" = true ]; then
    echo "FILE_CLAIMS_INCOMPLETE $p: >200 live claims, remainder not judged" >&2
  fi
  return 0
}

fclaim_not_before_left() {
  local p k ans left
  p=$(fclaim__key "${1-}") || return 1
  k=$(fclaim__key "${2-}") || return 1
  fclaim__ready || return 1
  ans=$(_jobs_req GET "/api/file-claims?project=$p&ticket=$k" 2>/dev/null) || return 1
  left=$(printf '%s' "$ans" | jq -er 'if type == "object" and has("not_before") then
      (.not_before | if . == null then "" else (.left_s | tostring) end) else error("contract") end' 2>/dev/null) \
    || return 1
  [ -z "$left" ] && return 0
  [[ "$left" =~ ^[0-9]+$ ]] || return 1
  printf '%s\n' "$left"
}
