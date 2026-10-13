#!/bin/bash
# bin/lib/conductor-verdict.sh — every merge lane asks the merge conductor's
# per-head verdict before it merges (BH-5914). Sourced, never executed.
#
#   cv_hold <slug> <num> <head> <log> <prefix>
#     <prefix> starts each log line: the caller's own stamp and tag, e.g.
#     "$(STAMP) [$PROJECT] #$NUM", so the line reads like the rest of its log.
#     rc 0  HOLD: the conductor's row for this PR holds THIS head. One line is
#           written to <log>: "<prefix> MERGE_REFUSED conductor-verdict: ...".
#           The caller does not merge.
#     rc 1  no objection: no row (404), a `clear` row, a hold on another head,
#           a worker outage (logged), no ledger client, or no head to compare.
#
# THE INCIDENT (example-org/project-6 #27, 2026-10-10). The conductor on the hub
# refused head 1d1e4640 at 08:06:01Z: GitHub would not serve the diff (HTTP
# 406), so the iron-law scan did not run. At 08:06:21Z bin/merge-queue.sh on
# box-project-6-os-1 merged that head. The refusal lived only in the hub's
# state dir and log. The conductor now writes its verdict for every READY head
# it scans to the jobs ledger (kind mc-merge-verdict, key <slug>#<n>, status
# hold|clear, detail "<head> <reason>", mc_merge_verdict_put in
# bin/lib/mc/classify.sh), and each lane that merges asks it here:
# bin/merge-queue.sh (mq_land), bin/review-prs.sh (merge_step) and the
# bin/run-build.sh tier-1 merge (bin/lib/rb/result.sh).
#
# A HOLD BINDS TO ITS HEAD. A push after the refusal is a head the conductor has
# not judged yet, and the conductor's own tick judges it. Heads compare by
# prefix both ways with a 7-char floor, so an 8-char head in the row matches the
# 40-char head and a stray short string matches nothing.
#
# A WORKER OUTAGE FAILS OPEN, logged. The lanes that call this fail open on an
# unreachable worker (tests/main-red-box-freeze.bh-945-test.sh Q3 pins it for
# the box queue), and the conductor could not have published a refusal through
# the same outage. A box with no ledger client lands as before too.
[ -n "${_CV_LOADED:-}" ] && return 0
_CV_LOADED=1

cv_hold() {
  local slug="$1" num="$2" head="${3:-}" log="${4:-/dev/null}" prefix="${5:-}" row rc status detail vhead reason
  command -v job_ledger_row >/dev/null 2>&1 || return 1
  [ -n "$slug" ] && [ -n "$num" ] || return 1
  [ "${#head}" -ge 7 ] || return 1
  row=$(job_ledger_row mc-merge-verdict "$slug#$num"); rc=$?
  [ "$rc" = 2 ] && return 1
  if [ "$rc" != 0 ]; then
    printf '%s conductor verdict could not be read (ledger rc %s) — merging as before: this lane fails open on a worker outage\n' \
      "$prefix" "$rc" >> "$log"
    return 1
  fi
  status=$(jq -r '.status // ""' <<<"$row" 2>/dev/null)
  detail=$(jq -r '.detail // ""' <<<"$row" 2>/dev/null)
  [ "$status" = hold ] || return 1
  vhead="${detail%% *}"; reason="${detail#"$vhead"}"; reason="${reason# }"
  [ "${#vhead}" -ge 7 ] || return 1
  case "$head" in "$vhead"*) ;; *) case "$vhead" in "$head"*) ;; *) return 1 ;; esac ;; esac
  printf '%s MERGE_REFUSED conductor-verdict: the merge conductor holds head %s: %s — not merged here; it merges when the conductor clears this head\n' \
    "$prefix" "${head:0:8}" "${reason:-no reason recorded}" >> "$log"
  return 0
}
