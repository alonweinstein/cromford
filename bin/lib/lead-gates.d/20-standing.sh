#!/bin/bash
# shellcheck shell=bash
# bin/lib/lead-gates.d/20-standing.sh — gate 2 of bin/lead-review-enqueue.sh,
# ported to the worklist: a lead, human or risk-tier verdict that stands on the
# head (vd_standing) means no review.
#   nothing stands (rc 1)   rc 0.
#   a verdict stands        rc 10 [skip verdict]. When it is a risk-tier row
#                           and the enqueue's marker state/lead-review-enqueue/
#                           risk-pub-<safe>-<n>-<h12> exists (its status post
#                           failed), vs_publish posts the status again; the
#                           marker goes only when that post succeeds.
#   unreadable, or no vd_standing   rc 11.
# Sourced by bin/lib/lead-gates.sh, never run.

# shellcheck source=bin/lib/verdict-status.sh
command -v vs_publish >/dev/null 2>&1 || . "${BASH_SOURCE[0]%/*}/../verdict-status.sh" 2>/dev/null || true

# _lgst_skip <slug> <n> <head> <class> <text> — lgs_skip_once (05-skip-ledger.sh);
#   without it the `[skip <class>]` line is logged on every tick.
_lgst_skip() {
  if command -v lgs_skip_once >/dev/null 2>&1; then lgs_skip_once "$@"
  else _lgt_log "[skip $4] $1#$2 @${3:0:12} $5"; fi
}

lg_gate_standing() {
  local slug="$1" n="$2" head h12="${3:0:12}" line vrc=0 src root="${HARNESS:-${H:-}}" safe rpub
  head=$(printf '%s' "$3" | tr 'A-F' 'a-f')
  if ! command -v vd_standing >/dev/null 2>&1; then
    _lgt_log "$slug#$n @$h12: no vd_standing (bin/lib/verdicts.sh not loaded); held"; return 11
  fi
  line=$(vd_standing "$slug" "$n" "$head" 2>/dev/null) || vrc=$?
  case "$vrc" in
    1) return 0 ;;
    0) ;;
    *) _lgt_log "$slug#$n @$h12: standing verdict unreadable (rc $vrc); held"; return 11 ;;
  esac
  src=$(cut -f2 <<<"$line")
  safe=$(printf '%s' "${slug//\//_}" | tr -cd 'A-Za-z0-9._-')
  rpub="${root:+$root/state/lead-review-enqueue/risk-pub-$safe-$n-$h12}"
  if [ "$src" = risk-tier ] && [ -n "$rpub" ] && [ -f "$rpub" ] && command -v vs_publish >/dev/null 2>&1; then
    if vs_publish "$slug" "$head" success "$(head -c 140 "$rpub")" "https://github.com/$slug/pull/$n" >/dev/null 2>&1; then
      rm -f "$rpub"; _lgt_log "$slug#$n @$h12: risk-tier lead-verdict status published on retry"
    else
      _lgt_log "$slug#$n @$h12: risk-tier lead-verdict status still not published; next tick retries"
    fi
  fi
  _lgst_skip "$slug" "$n" "$head" verdict "a ${src:-?} verdict stands on this head"
  return 10
}
