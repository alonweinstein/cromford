#!/bin/bash
# shellcheck shell=bash
# bin/lib/br/opt/untouched.sh — BH-5913: a park no run has looked at for
# BR_UNTOUCHED_ALERT_MIN pages once, naming its project.
#
# WHY. From 2026-10-09 18:44Z the hub's ticks ran 55-58 minutes and every one
# logged `visited=[cromford] skipped=[<9 projects>] reason=tick-budget`,
# oldest_untouched=3903m. The tick line said so for 65 hours and nothing paged.
# The cron entry is now a dispatcher with one run per project
# (bin/lib/project-lanes.sh), so one project no longer starves the others; this
# page is the backstop for a project whose own run cannot reach its parks.
#
# TWO HOOKS (bin/lib/br/opt/README.md):
#   br_untouched_note   called by br_note_untouched with <project> <epoch>; keeps
#                       the oldest untouched park per project.
#   br_untouched_alert  called once per tick after the dispatch loop. One
#                       lane-alert line per project episode.
#
# Defines functions only. Nothing runs on source.

declare -gA BR_UNTOUCHED_OLDEST=()

br_untouched_note() {
  local p="${1:--}" e="${2:--}"
  case "$e" in ''|-|*[!0-9]*) return 0 ;; esac
  if [ -z "${BR_UNTOUCHED_OLDEST[$p]:-}" ] || [ "$e" -lt "${BR_UNTOUCHED_OLDEST[$p]}" ]; then
    BR_UNTOUCHED_OLDEST[$p]="$e"
  fi
  return 0
}

# br_untouched_alert <now-epoch> — for each project whose oldest untouched
# park is older than BR_UNTOUCHED_ALERT_MIN, one alert per episode. The episode
# marker is $ST/.untouched-<project>; it goes when the project has no park over
# the line, so the next episode pages again. Held projects never reach the
# ledger (their rows are noted under "-").
br_untouched_alert() {
  local now="$1" knob="${BR_UNTOUCHED_ALERT_MIN:-120}" p e age mk line f
  case "$knob" in
    ''|*[!0-9]*) say "BR_UNTOUCHED_ALERT_MIN=$knob is not a number of minutes — using 120"; knob=120 ;;
  esac
  [ "$knob" -gt 0 ] || return 0
  for p in "${!BR_UNTOUCHED_OLDEST[@]}"; do
    [ "$p" != "-" ] || continue
    case "$p" in *[!A-Za-z0-9._-]*|.*) continue ;; esac
    e="${BR_UNTOUCHED_OLDEST[$p]}"; age=$(( now - e ))
    [ "$age" -ge $(( knob * 60 )) ] || continue
    mk="$ST/.untouched-$p"
    [ -e "$mk" ] && continue
    line="[blocked-resolver] UNTOUCHED $p: a park has waited $((age / 60)) min and no tick has looked at it (BR_UNTOUCHED_ALERT_MIN=$knob). Read the tick lines in logs/blocked-resolver.log: visited=, skipped=, reason=."
    "$H/bin/lane-alert.sh" --id "br-untouched-$p" blocked-resolver "$line" >/dev/null 2>&1 || true
    printf '%s\n' "$e" > "$mk" 2>/dev/null || true
    say "$p: UNTOUCHED for $((age / 60)) min — one ALERTS line written"
  done
  for f in "$ST"/.untouched-*; do
    [ -e "$f" ] || continue
    p="${f##*/.untouched-}"
    # A one-project run saw only its own project: it ends no other episode.
    [ -z "${ONLY:-}" ] || [ "$ONLY" = "$p" ] || continue
    # A one-PR run (BH-6000, br_only_pr_run set by bin/blocked-resolver.sh) saw one PR's rows only: it ends no
    # episode, because the project's other parks were not looked at.
    [ -z "${br_only_pr_run:-}" ] || continue
    e="${BR_UNTOUCHED_OLDEST[$p]:-}"
    if [ -z "$e" ] || [ $(( now - e )) -lt $(( knob * 60 )) ]; then rm -f "$f"; fi
  done
  return 0
}
