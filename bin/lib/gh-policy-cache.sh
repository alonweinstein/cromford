#!/bin/bash
# bin/lib/gh-policy-cache.sh — BH-1586: a per-repo TTL cache for the GitHub
# POLICY reads (rulesets, .mergify.yml, branch protection). Sourced, never run.
#
# WHY. The merge conductor asked GitHub for a repo's rulesets, its .mergify.yml
# and its branch protection on every tick, for every repo, with a bare `gh api`
# that no ledger saw (gh-reads audit, 2026-09-23: ~300-400 reads an hour across
# the conductor's raw sites). Policy is edited by a human a few times a month;
# it does not change between two five-minute ticks. ETag alone does not stop
# the spend here — a 304 still costs a request and a round trip per repo per
# tick — so these reads are answered from disk for GH_POLICY_TTL_SECS and only
# then asked again, through gh_rest (ledgered, ETag-cached).
#
# WHAT IS CACHED: ONLY A POSITIVE 2xx BODY. Two kinds of answer are never
# written:
#   - a 75 (rate limit, 403, 5xx, network) is UNVERIFIABLE (gh-rest.sh's rule,
#     docs/GH-REST.md section 7);
#   - a 404 is a NEGATIVE answer, and every negative here is the dangerous
#     direction (#1605 review, BLOCKING-1). "No .mergify.yml" makes the provider
#     `none`, and under Mergify `none` means every merger does a direct
#     `gh pr merge` AROUND the queue. So a cached 404 turned "Mergify was just
#     enabled" or one transient / token-blind 404 into up to an hour of
#     queue-bypass merges. "Unprotected" is token-dependent, because GitHub
#     answers 404 for what a token cannot see. A negative is therefore re-asked
#     every time; gh_rest's ETag makes that a 304, which is not charged.
# A cached POSITIVE fails safe: a removed .mergify.yml keeps the conductor
# labelling (a stall, never a bypass) until the TTL, or at once when the
# operator deletes the repo's provider file (mc_queue_provider drops this
# repo's entries then; docs/MERGIFY.md section 4).
#
# THE TTL IS A DB KNOB (catalog/lanes.d/_lib.json, libs id gh-policy-cache,
# required, default 3600): row > cached row > env > registry default. This
# file carries no literal for it. A TTL that still is not a number — no
# lane-gate on the box, a garbage env value — reads as 0, i.e. no cache: an
# unclear answer costs API budget, never a stale policy.
#
# The cache is a FILE per (repo, name) under $HARNESS/state/gh-policy-cache/,
# because the conductor, the sweeps and the box merge queue are separate
# processes asking the same question about the same repos. Line 1 is
# "<epoch> <rc>", the rest is the body; written tmp+mv so a reader never sees
# half an entry.
#
# gh-rest: no-graphql
#
# No `set -e`, no `exit`, no side effect at source time.
if [ -n "${GH_POLICY_CACHE_LIB:-}" ]; then return 0 2>/dev/null; fi
GH_POLICY_CACHE_LIB=1
command -v gh_rest >/dev/null 2>&1 \
  || { [ -r "${BASH_SOURCE[0]%/*}/gh-rest.sh" ] && . "${BASH_SOURCE[0]%/*}/gh-rest.sh"; }
_GHPC_LIBDIR="${BASH_SOURCE[0]%/*}"
_GHPC_APPLIED=0

_ghpc_dir() { printf '%s/state/gh-policy-cache' "${HARNESS:-/root/harness}"; }

_ghpc_file() { # _ghpc_file <slug> <name>
  printf '%s/%s/%s' "$(_ghpc_dir)" "$(printf '%s' "$1" | tr -c 'A-Za-z0-9._-' '_')" \
    "$(printf '%s' "$2" | tr -c 'A-Za-z0-9._-' '_')"
}

# gh_policy_ttl_resolve — sets GH_POLICY_TTL in THIS shell (never call it in a
# `$( )`: the knob's export would die with the subshell). Resolves the knob
# through lib_env_apply once per process when the env does not already hold a
# number.
gh_policy_ttl_resolve() {
  local v="${GH_POLICY_TTL_SECS:-}"
  if { [ -z "$v" ] || [ -n "${v//[0-9]/}" ]; } && [ "$_GHPC_APPLIED" = 0 ]; then
    _GHPC_APPLIED=1
    if ! command -v lib_env_apply >/dev/null 2>&1; then
      # shellcheck source=bin/lib/lane-gate.sh
      [ -r "$_GHPC_LIBDIR/lane-gate.sh" ] && . "$_GHPC_LIBDIR/lane-gate.sh"
    fi
    command -v lib_env_apply >/dev/null 2>&1 && lib_env_apply gh-policy-cache
    v="${GH_POLICY_TTL_SECS:-}"
  fi
  case "$v" in ''|*[!0-9]*) v=0 ;; esac
  GH_POLICY_TTL="$v"
}

# gh_policy_cache_drop <slug> — forget every cached policy answer for one repo.
#   mc_queue_provider calls it when the repo's provider file is gone, so
#   deleting `tmp/merge-queue-<slug>.provider` still means "ask GitHub now".
gh_policy_cache_drop() {
  local d
  [ -n "${1:-}" ] || return 0
  d=$(_ghpc_file "$1" x); d="${d%/*}"
  rm -rf "$d" 2>/dev/null
  return 0
}

# gh_policy_cache_get <slug> <name> <outfile> -> rc 0 (fresh: body in outfile),
#   1 (no fresh entry). Needs GH_POLICY_TTL set. An entry written by an older
#   build with rc 44 is not served (a negative is never an answer from disk).
gh_policy_cache_get() {
  local f at rc now age
  [ "${GH_POLICY_TTL:-0}" -gt 0 ] 2>/dev/null || return 1
  f=$(_ghpc_file "$1" "$2")
  [ -r "$f" ] || return 1
  read -r at rc < "$f" 2>/dev/null || return 1
  case "$at" in ''|*[!0-9]*) return 1 ;; esac
  [ "$rc" = 0 ] || return 1
  now=$(date +%s); age=$(( now - at ))
  [ "$age" -ge 0 ] && [ "$age" -lt "$GH_POLICY_TTL" ] || return 1
  tail -n +2 "$f" > "$3" 2>/dev/null || return 1
  [ -s "$3" ] || return 1
  return 0
}

# gh_policy_cache_put <slug> <name> <rc> <bodyfile> — best effort; writes ONLY
#   rc 0 with a non-empty body. A failed write costs the next tick one read.
gh_policy_cache_put() {
  local f tmp
  [ "${GH_POLICY_TTL:-0}" -gt 0 ] 2>/dev/null || return 0
  [ "${3:-}" = 0 ] && [ -s "${4:-}" ] || return 0
  f=$(_ghpc_file "$1" "$2")
  mkdir -p "${f%/*}" 2>/dev/null || return 0
  tmp="$f.$BASHPID.tmp"
  { printf '%s %s\n' "$(date +%s)" "$3"; cat "$4" 2>/dev/null; } > "$tmp" 2>/dev/null \
    && mv -f "$tmp" "$f" 2>/dev/null || rm -f "$tmp" 2>/dev/null
  return 0
}

# gh_policy_read <slug> <name> <api path> — one policy GET, cached per repo.
#   stdout: the body on rc 0. rc: gh_rest's own 0 / 44 / 75 — a 44 always comes
#   from GitHub this call, never from disk. A cache hit sets GH_REST_REASON=cached
#   and GH_REST_STATUS=200 in the CALLING shell, so call it with `> file`, never
#   inside `$( )`, when the status matters.
gh_policy_read() {
  local slug="${1:-}" name="${2:-}" path="${3:-}" t rc=0
  if [ -z "$slug" ] || [ -z "$name" ] || [ -z "$path" ]; then
    GH_REST_STATUS=000; GH_REST_REASON=bad-args; return 75
  fi
  gh_policy_ttl_resolve
  t=$(mktemp "${TMPDIR:-/tmp}/gh-policy.XXXXXX") || return 75
  if gh_policy_cache_get "$slug" "$name" "$t"; then
    GH_REST_REASON=cached; GH_REST_STATUS=200
    cat "$t"; rm -f "$t"; return 0
  fi
  gh_rest GET "$path" > "$t" || rc=$?
  gh_policy_cache_put "$slug" "$name" "$rc" "$t"
  [ "$rc" = 0 ] && cat "$t"
  rm -f "$t"
  return "$rc"
}
