#!/bin/bash
# shellcheck shell=bash
# bin/lib/lead-gates-compare.sh — the compare read the lead review worklist
# gates share (bin/lib/lead-gates.d/30-silence.sh and 60-risk.sh). The
# enqueue's rt_compare (bin/lead-review-enqueue.sh), with the least change:
#
#   lgc_compare <slug> <n> <head>
#       GET repos/<slug>/compare/<pr base>...<head> ONCE per (head, dispatcher
#       process) into $root/state/lead-review-gates/cmp-<slug_>-<n>.json. Its
#       sidecar .key holds `<pid> <head> <rc>`; a new tick is a new pid, so it
#       reads again (the base branch moves). Sets:
#         LGC_FILE  the compare answer
#         LGC_RC    0 read whole; else the gh rc, or 1 for a scratch write
#                   that failed or a PR base that could not be read
#         LGC_SELF  true|false|unreadable|truncated (the rt_compare jq: a
#                   non-merge commit with a line starting `Lead-Lane:`)
#       rc 0 when LGC_RC is 0, else 1. The caller holds on rc 1.
#   The base is the PR's own base (.base.ref of GET repos/<slug>/pulls/<n>), the
#   same base gate 15 compares against since #6023 (a stacked PR's compare then
#   lists only its own commits). It is read once per (PR, dispatcher process).
# Root: ${HARNESS:-${H:-}} only; an empty root returns 1 and builds no path.
# Needs gh_rest (bin/lib/gh-rest.sh) and jq. Sourced, never run.

declare -gA _lgc_base=() _lgc_base_rc=()

lgc_compare() {
  local slug="$1" n="$2" head="$3" root="${HARNESS:-${H:-}}" dir f key base out rc=0
  LGC_FILE=""; LGC_RC=1; LGC_SELF=unreadable
  [ -n "$root" ] || return 1
  dir="$root/state/lead-review-gates"
  f="$dir/cmp-$(printf '%s' "${slug//\//_}" | tr -cd 'A-Za-z0-9._-')-$n.json"
  LGC_FILE="$f"
  key=$(cat "$f.key" 2>/dev/null)
  if [ "${key% *}" != "$$ $head" ]; then
    if [ -z "${_lgc_base_rc[$slug#$n]+x}" ]; then
      gh_rest_var out GET "repos/$slug/pulls/$n" || _lgc_base_rc[$slug#$n]=$?
      _lgc_base_rc[$slug#$n]="${_lgc_base_rc[$slug#$n]:-0}"
      _lgc_base[$slug#$n]=$(jq -r '.base.ref // empty' <<<"$out" 2>/dev/null)
    fi
    base="${_lgc_base[$slug#$n]:-}"
    [ "${_lgc_base_rc[$slug#$n]}" = 0 ] && [ -n "$base" ] || return 1
    mkdir -p "$dir" 2>/dev/null || return 1
    gh_rest GET "repos/$slug/compare/$(jq -rn --arg b "$base" '$b|@uri')...$head" > "$f" 2>/dev/null || rc=$?
    # A sidecar that cannot be written is a read that cannot be trusted.
    printf '%s %s %s' "$$" "$head" "$rc" > "$f.key" 2>/dev/null || return 1
    key="$$ $head $rc"
  fi
  LGC_RC="${key##* }"
  LGC_SELF=$(jq -r 'if (.commits|type) != "array" or (.total_commits|type) != "number" then "unreadable"
    elif .total_commits > (.commits|length) then "truncated"
    else ([.commits[] | select((.parents|length) < 2) | .commit.message // "" | split("\n")[] | select(test("^Lead-Lane:"))] | length > 0) end' \
    "$f" 2>/dev/null)
  [ "$LGC_RC" = 0 ] || { LGC_SELF=unreadable; return 1; }
  return 0
}
