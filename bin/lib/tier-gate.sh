#!/bin/bash
# bin/lib/tier-gate.sh — BH-4572: the tier no longer decides who merges.
# Sourced (by the APPROVE hand-off blocks in bin/lib/rb/pr.sh and
# bin/lib/rb/result.sh), never executed.
#
# THE RULE. A review's TIER is still computed and recorded as a risk class. It
# decides who merges only when an operator sets the settings row
# tier_gate_mode.<project> (else the global tier_gate_mode) to `human`:
#   off    (the default: neither row exists) — an approved PR of any tier goes
#          on the merge queue.
#   human  the run-build hand-off below does not enqueue a tier ≠1 APPROVE;
#          tier 1 is unaffected. That hand-off is ALL it holds: bin/merge-sweep.sh
#          and the conductor's ae_project (bin/lib/autoenqueue.sh) do not ask
#          yet and can still land the PR, until #5035 (BH-4572.4).
#   An unreadable row, or a value other than off|human after trimming and
#   lowercasing, HOLDS (fail closed) and pages once per (project, UTC day).
#   Set it: bin/jobs-client.sh setting-set tier_gate_mode[.<project>] off|human
# There is no file flag.
#
# tg_mode <project>         TG_MODE (off|human, or the raw value) and TG_MODE_SRC
#                           (the key read, or `no row`); rc 2 unreadable/garbage.
# tg_holds <project> <tier> rc 0 hold, rc 1 proceed. An unreadable row holds
#                           EVERY tier, tier 1 included: the hand-off never asks
#                           for tier 1, but a direct caller gets fail-closed.
#                           A page failure never turns a hold into a proceed.
# TG_PAGE_DAY pins the UTC day of the page dedupe (tests only).

tg_mode() {
  local p="${1:-}" v rc=0
  TG_MODE=""; TG_MODE_SRC=""
  [ -n "$p" ] || return 2
  command -v setting_get >/dev/null 2>&1 || return 2
  v=$(setting_get "tier_gate_mode.$p") || rc=$?
  case "$rc" in
    0) TG_MODE_SRC="tier_gate_mode.$p" ;;
    2) rc=0; v=$(setting_get tier_gate_mode) || rc=$?
       case "$rc" in
         0) TG_MODE_SRC=tier_gate_mode ;;
         2) v=off; TG_MODE_SRC="no row" ;;
         *) return 2 ;;
       esac ;;
    *) return 2 ;;
  esac
  TG_MODE=$(printf '%s' "$v" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//' | tr 'A-Z' 'a-z')
  case "$TG_MODE" in off|human) return 0 ;; *) return 2 ;; esac
}

tg_holds() {
  if ! tg_mode "${1:-}"; then
    _tg_page "${1:-}" || true
    return 0
  fi
  [ "$TG_MODE" = human ] && [ "${2:-}" != 1 ] && return 0
  return 1
}

# _tg_page <project> — one alert-line.sh page per (project, UTC day). The stamp
# is written only after the page was sent, so an unconfigured pager retries.
_tg_page() {
  local root="${HARNESS:-${H:-}}" p="${1:-}" day stamp
  [ -n "$root" ] || return 0
  day=${TG_PAGE_DAY:-$(date -u +%F)}
  stamp="$root/state/tier-gate/page-$p-$day"
  [ -e "$stamp" ] && return 0
  [ -x "$root/bin/alert-line.sh" ] || return 0
  HARNESS="$root" "$root/bin/alert-line.sh" --id "tier-gate:$p:$day" --project "$p" \
    "[tier-gate] $p: tier_gate_mode row unreadable or not off|human (value '$TG_MODE', ${TG_MODE_SRC:-unreadable}) — tier ≠1 APPROVEs are held until it reads. Fix: bin/jobs-client.sh setting-set tier_gate_mode.$p off|human" \
    >/dev/null 2>&1
  mkdir -p "$root/state/tier-gate" && touch "$stamp"
}
