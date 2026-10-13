#!/bin/bash
# shellcheck shell=bash
# bin/lib/br/opt/extfix.sh — BH-4664.1 (BH-4668): the FIX ROUND on an EXTERNAL PR.
#
# Fills external.sh's `br_xpr_fix` hook: an external-changes-requested row that
# passed the shared gates (knob, push right, author-quiet window) gets ONE
# harness fix round per head, run by the lane's own br_fix_round with
# BR_XPR_ACTIVE=1 — pushed as the harness identity under a lease on the head the
# round read, and answered on the PR with br_xpr_round_comment's template.
#
# It never closes the PR and never re-reviews it: the terminals are external.sh's
# and the lane's belt, and the pushed head is bin/review-prs.sh's to judge on the
# project box's next review tick.
#
# Functions only. Nothing runs on source (bin/lib/br/opt/README.md).

# br_xpr_fix <p> <rkey> <reason> <url> <rec> <tkey> — rc 0 the round ran (or
# ended in br_fix_round's own exits), rc 3 nothing spent. Reached only from
# br_opt_external_rung after the gates, so BR_XPR_HEAD/SLUG/NUM are exported.
br_xpr_fix() {
  local p="$1" rkey="$2" url="$4" ck rc hrepo
  local tag="external $BR_XPR_SLUG#$BR_XPR_NUM"
  ck=$(br_cap_key "$p" "$rkey" -)
  # 1. A head the park ledger holds for the author is not ours to work, and a
  #    ledger that would not answer is never "not parked" (D11).
  rc=1
  command -v pr_attempt_has >/dev/null 2>&1 \
    && { rc=0; pr_attempt_has "$BR_XPR_SLUG" "$BR_XPR_NUM" ext-park "$BR_XPR_HEAD" || rc=$?; }
  case "$rc" in
    0) say "$tag: head ${BR_XPR_HEAD:0:8} is parked for the author — no fix round"; return 3 ;;
    2) ;;
    *) say "$tag: the park ledger would not read — no fix round, retried next tick"; return 3 ;;
  esac
  # 2. One round per head, asked BEFORE br_fix_round so a worked head costs no
  #    PER_TICK slot either (br_fix_round's own dedupe returns 0).
  if br_has_field_value "$(br_load "$p" "$ck")" review_fix_heads "$BR_XPR_HEAD"; then
    say "$tag: fix round already ran on ${BR_XPR_HEAD:0:8} — nothing spent"
    return 3
  fi
  # 3. A fork head: br_fix_round fetches origin/<head.ref> and pushes to origin,
  #    which for a fork is the BASE repo's branch of that name. Refused.
  hrepo=$(br_pr_field "$url" '.head.repo.full_name' 'head repo') || hrepo=""
  if [ -z "$hrepo" ]; then
    say "$tag: the head repo would not read — no fix round, retried next tick"
    return 3
  fi
  if [ "$hrepo" != "$BR_XPR_SLUG" ]; then
    say "$tag: head lives in $hrepo — a fix round pushes to origin only; left for the author"
    return 3
  fi
  br_set_flag "$p" "$ck" external \
    || say "$tag: the external flag was not written on $ck — the rung's stamp and the close belt still hold"
  BR_XPR_ACTIVE=1 br_fix_round "$p" "$rkey" review-changes-requested "$url" - -
  return 0
}

# br_xpr_round_comment <url> <old-sha> <new-sha> <findings> <wt> <lease> — the
# one PR comment a pushed external round posts. rc is br_pr_comment's.
br_xpr_round_comment() {
  local url="$1" old="$2" new="$3" findings="$4" wt="$5" lease="$6" asked subjects
  # The first 10 lines of what the review said: the brief's framing (the lead
  # header and its "(CHANGES_REQUESTED by … on …)" line) is not a finding.
  asked=$(printf '%s\n' "$findings" | awk -v hdr="${BR_LEAD_HDR:-}" '
    /^[[:space:]]*$/ { next }
    hdr != "" && $0 == hdr { next }
    /^\(CHANGES_REQUESTED by [^ ]+ on [0-9a-f]+\)$/ { next }
    { print; if (++n == 10) exit }')
  subjects=$(git -C "$wt" log --no-merges --format='- %s' HEAD --not "$lease" origin/main 2>/dev/null)
  [ -n "$subjects" ] || subjects='- (no commit subjects could be read)'
  br_pr_comment "$url" "I pushed a fix round to this branch for the changes the review asked for.

Head: \`${old:0:12}\` → \`${new:0:12}\`

What the review asked for (first 10 lines):
$asked

Commits in this round:
$subjects

The review lane re-reviews the new head on its next tick. Nothing was merged or closed."
}
