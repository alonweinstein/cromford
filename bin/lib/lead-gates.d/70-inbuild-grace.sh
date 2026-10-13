#!/bin/bash
# shellcheck shell=bash
# bin/lib/lead-gates.d/70-inbuild-grace.sh — gate 5 of bin/lead-review-enqueue.sh
# (the in-build grace, BH-5023), ported to the worklist. A head 60-risk.sh
# classified medium under enforce (LG_RISK_KEY/TIER/MODE, set for this head
# in this call) waits for the in-build lead-grade review the build runs
# (bin/inbuild-lead-review.sh): the marker state/lead-review-enqueue/
# inbuild-wait-<slug_>-<n>-<sha12> (the enqueue's, same path) is written on
# first sight, and while it is younger than rt_inbuild_grace
# (risk_tier.inbuild_grace_s, fallback 3600 s) the head is held, rc 11. Past
# it, rc 0: the review starts, so a head no build reviews is never stranded.
# Never held: a head in the enqueue's requested.tsv, a rebound head
# (job_verdict_headbound reapproved@<head>: no build settled on it), a grace of
# 0, or a marker that cannot be written or read. An unreadable builder verdict
# is rc 11. Sourced by bin/lib/lead-gates.sh.

lg_gate_inbuild_grace() {
  local slug="$1" n="$2" head="$3" h12="${3:0:12}" root="${HARNESS:-${H:-}}" st url jv jrc=0 rsha grace waitf wt0 wnow safe
  [ "${LG_RISK_KEY:-}" = "$slug#$n@$head" ] && [ "${LG_RISK_TIER:-}" = medium ] && [ "${LG_RISK_MODE:-}" = enforce ] || return 0
  command -v rt_inbuild_grace >/dev/null 2>&1 || return 0
  if [ -z "$root" ]; then _lgt_log "no harness root; $slug#$n @$h12 held"; return 11; fi
  st="$root/state/lead-review-enqueue"
  awk -F'\t' -v s="$slug" -v n="$n" -v h="$head" '$2 == s && $3 == n && tolower($4) == h {f=1} END {exit !f}' "$st/requested.tsv" 2>/dev/null && return 0
  url="https://github.com/$slug/pull/$n"
  jv=$(job_verdict "$url" 2>/dev/null) || jrc=$?
  case "$jrc" in
    0) IFS=$'\t' read -r _ _ _ _ _ rsha <<<"$jv"
       rsha=$(printf '%s' "$rsha" | tr 'A-F' 'a-f')
       [ "$rsha" != "$head" ] && [ "$(job_verdict_headbound "$url" 2>/dev/null)" = "reapproved@$head" ] && return 0 ;;
    2) ;;
    *) _lgt_log "$slug#$n @$h12: builder verdict unreadable (rc $jrc); held"; return 11 ;;
  esac
  grace=$(rt_inbuild_grace)
  safe=$(printf '%s' "${slug//\//_}" | tr -cd 'A-Za-z0-9._-')
  waitf="$st/inbuild-wait-$safe-$n-$h12"
  mkdir -p "$st" 2>/dev/null
  [ -e "$waitf" ] || : > "$waitf" 2>/dev/null
  wt0=$(stat -c %Y "$waitf" 2>/dev/null)
  # The age against the clock NOW (the enqueue's negative-age fix).
  wnow=$(date +%s)
  if [[ "$wt0" =~ ^[0-9]+$ ]] && [[ "$grace" =~ ^[0-9]+$ ]] && [ "$grace" -gt 0 ] && [ $((wnow - wt0)) -lt "$grace" ]; then
    _lgt_log "$slug#$n @$h12: awaiting the in-build lead-grade review ($((grace - (wnow - wt0)))s left)"
    return 11
  fi
  if [[ "$wt0" =~ ^[0-9]+$ ]]; then _lgt_log "$slug#$n @$h12: in-build grace spent ($grace s, no in-build lead verdict); starting a lead review"
  else _lgt_log "$slug#$n @$h12: in-build grace marker $waitf unusable; starting a lead review"; fi
  return 0
}
