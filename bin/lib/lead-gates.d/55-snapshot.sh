#!/bin/bash
# shellcheck shell=bash
# bin/lib/lead-gates.d/55-snapshot.sh — gate 16 of bin/lead-review-enqueue.sh
# (BH-4658), ported to the worklist: the PR body is read through prs_pr_get
# (bin/lib/pr-snapshot.sh), so a head that did not change since the last read
# costs no pulls/<n> call. It logs one line `PR-SNAPSHOT <slug>#<n> hit|miss`
# and keeps the body for this process (lgs_pr_body_file: the head ref the
# authors field reads).
#   The list row (head, updated_at, base) that keys a hit comes from
#   prs_open_list, read once per repo per process and only when the snapshot is
#   on: with it off, prs_pr_get reads live whatever the key, and the worklist
#   reads no open-PR list (tests/lead-review-worklist.bh-4956-test.sh W1).
#   A PR missing from the list keys with `-`, which is always a live read.
# An unreadable body, or a body head that is not the worklist head, is a hold
# (rc 11, one log line), as the gate contract says: a failed read is never a
# pass, and a moved head is never reviewed on the stale head (lead BLOCK at
# 19019cf2e). The next tick reads again. Without bin/lib/pr-snapshot.sh the body
# is a live gh_rest read, as in the enqueue. Sourced by bin/lib/lead-gates.sh, never run.

declare -gA _lgs_list=()

# lgs_pr_body_file <slug> <n> — the path of the body this process read for the
#   PR, or nothing (rc 1).
lgs_pr_body_file() {
  local d f safe
  d=$(lgs_dir 2>/dev/null) || return 1
  safe=$(printf '%s' "${1//\//_}" | tr -cd 'A-Za-z0-9._-')
  f="$d/pr-$safe-$2.json"
  [ -s "$f" ] || return 1
  printf '%s\n' "$f"
}

# lgs_pr_body <slug> <n> — read the PR body ONCE per process (the snapshot when
#   it is on), log one `PR-SNAPSHOT <slug>#<n> hit|miss` line, and set
#   LGS_BODY_FILE to the path of the body file. rc is the read's rc (0 = a
#   body). Call it directly, never in $(...): its per-process memory
#   (_lgs_rc, _lgs_list) must live in the gates' own shell. Gate 15 reads the
#   PR's base through it too, so one item costs one pulls/<n> read (or none on
#   a snapshot hit), not one per gate.
declare -gA _lgs_rc=()
lgs_pr_body() {
  local slug="$1" n="$2" d safe lf out cf lh="-" lu="-" lb="-" rc=0 how="miss"
  LGS_BODY_FILE=""
  d=$(lgs_dir 2>/dev/null) || return 75
  safe=$(printf '%s' "${slug//\//_}" | tr -cd 'A-Za-z0-9._-')
  out="$d/pr-$safe-$n.json"; LGS_BODY_FILE="$out"
  if [ -n "${_lgs_rc[$slug#$n]+x}" ]; then return "${_lgs_rc[$slug#$n]}"; fi
  cf="$d/count-$safe-$n"
  rm -f "$out" "$cf"
  if command -v prs_pr_get >/dev/null 2>&1; then
    if command -v _prs_on >/dev/null 2>&1 && _prs_on && command -v prs_open_list >/dev/null 2>&1; then
      lf="$d/open-$safe.json"
      if [ -z "${_lgs_list[$slug]+x}" ]; then
        _lgs_list[$slug]=0
        prs_open_list "$slug" "$lf" 2>/dev/null || _lgs_list[$slug]=$?
        [ "${_lgs_list[$slug]}" = 0 ] || { rm -f "$lf"; _lgt_log "open-PR list of $slug unreadable (rc ${_lgs_list[$slug]}); every PR body is a live read"; }
      fi
      if [ -s "$lf" ]; then
        IFS=$'\t' read -r lh lu lb < <(jq -r --argjson n "$n" '[.[]? | select(.number == $n)][0] // {}
          | [(.head.sha // "-"), (.updated_at // "-"), (.base.ref // "-")] | @tsv' "$lf" 2>/dev/null)
      fi
    fi
    PRS_COUNT_FILE="$cf" prs_pr_get "$slug" "$n" "${lh:--}" "${lu:--}" "${lb:--}" "$out" 2>/dev/null || rc=$?
    grep -q '^HIT ' "$cf" 2>/dev/null && how=hit
  else
    gh_rest GET "repos/$slug/pulls/$n" > "$out" 2>/dev/null || rc=$?
  fi
  rm -f "$cf"
  _lgt_log "PR-SNAPSHOT $slug#$n $how"
  [ "$rc" = 0 ] || rm -f "$out"
  _lgs_rc[$slug#$n]=$rc
  return "$rc"
}

lg_gate_snapshot() {
  local slug="$1" n="$2" head h12="${3:0:12}" out rc=0 bh
  head=$(printf '%s' "$3" | tr 'A-F' 'a-f')
  lgs_pr_body "$slug" "$n" || rc=$?
  out="${LGS_BODY_FILE:-}"
  bh=$(jq -r '.head.sha // empty' "$out" 2>/dev/null | tr 'A-F' 'a-f')
  # A failed read is a hold, never a pass (the gate contract, D9/D11; lead
  # BLOCK at 19019cf2e), and a moved head is never reviewed on the stale head.
  # The next tick reads again; the worklist then lists the moved head itself.
  if [ "$rc" != 0 ] || ! [[ "$bh" =~ ^[0-9a-f]{40}$ ]]; then
    rm -f "$out"
    _lgt_log "$slug#$n @$h12: PR body unreadable (rc $rc, HTTP ${GH_REST_STATUS:-000}); held"
    return 11
  fi
  if [ "$bh" != "$head" ]; then
    _lgt_log "$slug#$n @$h12: the PR body names head ${bh:0:12}, not the worklist head; held"
    return 11
  fi
  return 0
}
