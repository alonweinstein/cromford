#!/bin/bash
# shellcheck shell=bash
# bin/lib/lead-gates.d/10-builder.sh — gate 1 of bin/lead-review-enqueue.sh
# (BH-3545, BH-5630), ported to the worklist: the builder's verdict on the PR
# (job_verdict, GET /api/verdict?pr=) decides.
#   BLOCK (any head)                      rc 10 [skip builder-block]: the fix round owns it.
#   APPROVE bound to this head            rc 0, approved.
#   APPROVE on an earlier head, and the
#     head-bound gate says reapproved@head rc 0, approved and rebound.
#   any other verdict word                rc 10 [skip no-approve].
#   no builder row (rc 2), or APPROVE on
#     an earlier head                     unapproved: with
#       LEAD_REVIEW_REQUIRE_BUILDER_APPROVE=1, rc 10 [skip no-approve]; else rc 0
#       when CI is green on this head (lr_ci_green, the base branch's
#       .mergify.yml), else rc 11.
#   ledger unreadable (rc 1)              rc 11.
# The enqueue skipped an unreadable ledger; here it is a hold (a failed read is
# a hold). Under REQB=1 the enqueue still tried its replay on an unapproved
# head before it skipped it; here the skip comes first, so no review starts.
# The CI base is the repo's default branch (GET repos/<slug>, one read per repo
# per process): a worklist item carries no PR base. The knob is the enqueue
# lane's registry row, read once per process (lane_env_apply in a subshell).
# Gate 50 reads LGB_KEY (<slug>#<n>@<head>), LGB_APPROVED, LGB_REBOUND, LGB_RSHA.
# Sourced by bin/lib/lead-gates.sh, never run.

declare -g _LGB_REQB=""
declare -gA _lgb_base=() _lgb_base_rc=()
declare -g LGB_APPROVED=0 LGB_REBOUND=0 LGB_RSHA=""
declare -g LGB_KEY=""

# _lgb_skip <slug> <n> <head> <class> <text> — lgs_skip_once (05-skip-ledger.sh);
#   without it the `[skip <class>]` line is logged on every tick.
_lgb_skip() {
  if command -v lgs_skip_once >/dev/null 2>&1; then lgs_skip_once "$@"
  else _lgt_log "[skip $4] $1#$2 @${3:0:12} $5"; fi
}

lg_tick_builder() {
  [ -n "$_LGB_REQB" ] && return 0
  _LGB_REQB=$(command -v lane_env_apply >/dev/null 2>&1 && lane_env_apply lead-review-enqueue >/dev/null 2>&1
    printf '%s' "${LEAD_REVIEW_REQUIRE_BUILDER_APPROVE:-0}")
  [ "$_LGB_REQB" = 1 ] || _LGB_REQB=0
  return 0
}

# _lgb_ci_green <slug> <n> <head> — rc 0 when lr_ci_green says CI is green on
#   <head>; else rc 1 and _LGB_WHY says why.
_lgb_ci_green() {
  local slug="$1" n="$2" head="$3" d f base mf
  _LGB_WHY=""
  command -v lr_ci_green >/dev/null 2>&1 || { _LGB_WHY="no lead ci green block in bin/lead-review.sh"; return 1; }
  d=$(lgs_dir 2>/dev/null) || { _LGB_WHY="no scratch dir"; return 1; }
  if [ -z "${_lgb_base_rc[$slug]+x}" ]; then
    gh_rest_var f GET "repos/$slug" || _lgb_base_rc[$slug]=$?
    _lgb_base_rc[$slug]="${_lgb_base_rc[$slug]:-0}"
    _lgb_base[$slug]=$(jq -r '.default_branch // empty' <<<"$f" 2>/dev/null)
  fi
  base="${_lgb_base[$slug]}"
  if [ "${_lgb_base_rc[$slug]}" != 0 ] || [ -z "$base" ]; then
    _LGB_WHY="default branch of $slug unreadable (rc ${_lgb_base_rc[$slug]})"; return 1
  fi
  # One .mergify.yml read per (repo, base) per process, named by a hash as in the enqueue.
  mf="$d/mergify-$(printf '%s\n%s' "$slug" "$base" | { sha256sum 2>/dev/null || shasum -a 256; } | cut -c1-32)"
  if [ ! -e "$mf.read" ]; then
    : > "$mf"; : > "$mf.read"
    gh_rest GET "repos/$slug/contents/.mergify.yml?ref=$(jq -rn --arg b "$base" '$b|@uri')" > "$mf.json" 2>/dev/null \
      && jq -r '.content // empty' "$mf.json" 2>/dev/null | tr -d '\n' | base64 -d > "$mf" 2>/dev/null
  fi
  # shellcheck disable=SC2034  # read by lr_ci_fetch: one check-run read per head
  LR_CI_SHA=""
  lr_ci_green "$slug" "$head" "$mf" "$d/checks-$n" && return 0
  _LGB_WHY="${LR_CI_WHY:-unknown}"; return 1
}

lg_gate_builder() {
  local slug="$1" n="$2" head h12="${3:0:12}" url jv jrc=0 v="" rsha="" hb
  head=$(printf '%s' "$3" | tr 'A-F' 'a-f')
  url="https://github.com/$slug/pull/$n"
  [ -n "$_LGB_REQB" ] || lg_tick_builder "$slug"
  LGB_KEY=""; LGB_APPROVED=0; LGB_REBOUND=0; LGB_RSHA=""
  jv=$(job_verdict "$url" 2>/dev/null) || jrc=$?
  case "$jrc" in
    0) IFS=$'\t' read -r v _ _ _ _ rsha <<<"$jv"; rsha=$(printf '%s' "$rsha" | tr 'A-F' 'a-f') ;;
    2) ;;
    *) _lgt_log "$slug#$n @$h12: builder verdict unreadable (rc $jrc); held"; return 11 ;;
  esac
  LGB_KEY="$slug#$n@$head"; LGB_RSHA="$rsha"
  if [ "$v" = BLOCK ]; then
    _lgb_skip "$slug" "$n" "$head" builder-block "builder BLOCK; the fix round owns it"; return 10
  fi
  if [ "$jrc" = 0 ]; then
    if [ "$v" != APPROVE ]; then
      _lgb_skip "$slug" "$n" "$head" no-approve "builder verdict '$v' is not APPROVE"; return 10
    fi
    if [ "$rsha" = "$head" ]; then LGB_APPROVED=1; return 0; fi
    hb=$(job_verdict_headbound "$url" 2>/dev/null | tr 'A-F' 'a-f')
    if [ "$hb" = "reapproved@$head" ]; then LGB_APPROVED=1; LGB_REBOUND=1; return 0; fi
  fi
  # Unapproved: no builder row, or the APPROVE is on an earlier head.
  if [ "$_LGB_REQB" = 1 ]; then
    _lgb_skip "$slug" "$n" "$head" no-approve \
      "no builder APPROVE on this head${rsha:+ (it is on ${rsha:0:12})}, and LEAD_REVIEW_REQUIRE_BUILDER_APPROVE=1"
    return 10
  fi
  _lgb_ci_green "$slug" "$n" "$head" && return 0
  _lgt_log "$slug#$n @$h12: no builder APPROVE on this head and CI not known green ($_LGB_WHY); held"
  return 11
}
