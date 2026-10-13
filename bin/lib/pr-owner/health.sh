#!/bin/bash
# bin/lib/pr-owner/health.sh — BH-3936 (BH-3929 ask 6): the per-repo PR-health
# rollup of bin/pr-owner-sweep.sh. Sourced, never executed.
#
# ph_age_bucket <created-epoch> <now> — lt1d | 1to3d | 3to7d | gt7d. A
#   non-number argument is rc 1 and prints nothing.
# po_health_add — called once per open PR, last. Takes no args; reads the
#   sweep's per-PR context (PO_SLUG PO_NUM PO_HEAD PO_CREATED PO_OWNED
#   PO_MC_STATE) and PO_TICK_NOW. rc 0 = counted, rc 2 = no PR context.
# po_health_flush <project> <slug> — called once per repo the sweep read,
#   after its summary line. Writes one ledgers row kind=pr_health key=<project>
#   (the slug when the project is `-`) and resets. Adds that came from another
#   repo are dropped, never attributed here. rc 0.
# The day buckets are the ticket's display buckets, not knobs.

_ph_health_reset() {
  _PH_SLUG=""; _PH_OPEN=0; _PH_LT1D=0; _PH_1TO3D=0; _PH_3TO7D=0; _PH_GT7D=0
  _PH_OWNERLESS=0; _PH_APPROVED=0; _PH_CI_ONLY=0
}
_ph_health_reset

ph_age_bucket() {
  local c="${1:-}" n="${2:-}" a
  [[ "$c" =~ ^[0-9]+$ ]] && [[ "$n" =~ ^[0-9]+$ ]] || return 1
  a=$(( n - c ))
  if   [ "$a" -lt 86400 ];  then echo lt1d
  elif [ "$a" -lt 259200 ]; then echo 1to3d
  elif [ "$a" -lt 604800 ]; then echo 3to7d
  else echo gt7d; fi
}

# _ph_ci_only_block — rc 0 when the PR's standing BLOCK says only "CI did not
#   run". Only READY PRs: that is the conductor arm that consults the gate, and
#   it bounds the reads. bg_scan_read, never bg_scan: no streak file is touched.
_ph_ci_only_block() {
  local ans rc=0 id rest path tf line US=$'\037' fid fat flogin furl b64
  [ "${PO_MC_STATE:--}" = READY ] || return 1
  if ! command -v bg_scan_read >/dev/null 2>&1; then
    # shellcheck source=bin/lib/block-gate.sh
    [ -r "${BASH_SOURCE[0]%/*}/../block-gate.sh" ] && . "${BASH_SOURCE[0]%/*}/../block-gate.sh"
    command -v bg_scan_read >/dev/null 2>&1 || return 1
  fi
  ans=$(bg_scan_read "$PO_SLUG" "$PO_NUM" "https://github.com/$PO_SLUG/pull/$PO_NUM" "${PO_HEAD:-}" </dev/null 2>/dev/null) || rc=$?
  [ "$rc" = 1 ] || return 1
  IFS=$'\t' read -r _ _ _ id rest <<<"$ans"
  [[ "${id:-}" =~ ^[0-9]+$ ]] || return 1
  for path in "issues/$PO_NUM/comments created_at" "pulls/$PO_NUM/reviews submitted_at"; do
    tf="${path##* }"
    while IFS="$US" read -r fid fat flogin furl b64; do
      [ "$fid" = "$id" ] || continue
      ph_ci_only_body "$(printf '%s' "$b64" | base64 -d 2>/dev/null)"
      return
    done < <(bg_read "repos/$PO_SLUG/${path% *}" "$tf" 2>/dev/null </dev/null)
  done
  return 1
}

po_health_add() {
  local c b
  [ -n "${PO_SLUG:-}" ] && [ -n "${PO_NUM:-}" ] || return 2
  _PH_SLUG="$PO_SLUG"
  _PH_OPEN=$((_PH_OPEN + 1))
  if [ -n "${PO_CREATED:-}" ] && c=$(date -u -d "$PO_CREATED" +%s 2>/dev/null) && b=$(ph_age_bucket "$c" "${PO_TICK_NOW:-}"); then
    case "$b" in
      lt1d)  _PH_LT1D=$((_PH_LT1D + 1)) ;;
      1to3d) _PH_1TO3D=$((_PH_1TO3D + 1)) ;;
      3to7d) _PH_3TO7D=$((_PH_3TO7D + 1)) ;;
      gt7d)  _PH_GT7D=$((_PH_GT7D + 1)) ;;
    esac
  else
    echo "pr-health: $PO_SLUG#$PO_NUM created '${PO_CREATED:-}' is not a date — counted open, in no age bucket" >&2
  fi
  [ "${PO_OWNED:-0}" = 1 ] || _PH_OWNERLESS=$((_PH_OWNERLESS + 1))
  if [ "${PO_HEAD:--}" != - ] && ph_review_covered "$PO_SLUG" "$PO_NUM" "$PO_HEAD" APPROVE </dev/null 2>/dev/null; then
    _PH_APPROVED=$((_PH_APPROVED + 1))
  fi
  _ph_ci_only_block && _PH_CI_ONLY=$((_PH_CI_ONLY + 1))
  return 0
}

po_health_flush() {
  local p="${1:-}" slug="${2:-}" key day detail
  if [ -n "$_PH_SLUG" ] && [ "$_PH_SLUG" != "$slug" ]; then
    echo "pr-health: counts for $_PH_SLUG reached the flush for $slug — dropped" >&2
    _ph_health_reset; return 0
  fi
  key="$p"; { [ -z "$key" ] || [ "$key" = - ]; } && key="$slug"
  if [ -z "$key" ] || ! day=$(date -u -d "@${PO_TICK_NOW:-x}" +%F 2>/dev/null); then
    echo "pr-health: no tick clock or no key for $slug — nothing written" >&2
    _ph_health_reset; return 0
  fi
  detail=$(jq -nc --arg day "$day" --argjson open "$_PH_OPEN" \
    --argjson a "$_PH_LT1D" --argjson b "$_PH_1TO3D" --argjson c "$_PH_3TO7D" --argjson d "$_PH_GT7D" \
    --argjson o "$_PH_OWNERLESS" --argjson ap "$_PH_APPROVED" --argjson ci "$_PH_CI_ONLY" \
    '{day:$day,open:$open,age:{lt1d:$a,"1to3d":$b,"3to7d":$c,gt7d:$d},ownerless:$o,approved_not_merged:$ap,blocked_ci_only:$ci}')
  if ! command -v job_ledger_put >/dev/null 2>&1 || ! job_ledger_put pr_health "$key" ok "$detail" </dev/null >/dev/null 2>&1; then
    echo "pr-health: pr_health row for $key not written — the digest shows the last one with its day" >&2
  fi
  _ph_health_reset
  return 0
}
