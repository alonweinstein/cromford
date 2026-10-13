#!/bin/bash
# gh-identity: app-token
# bin/cost-local-brake.sh — every box that owns a project, every 10 minutes:
# while harness-jobs is unreachable, judge this box's own projects against the
# cost breaker and hold the new builds of the ones that trip it, HERE (BH-2599).
#
# WHY. The breaker (bin/pipeline-health.sh `cost budget`) runs on the hub, and
# every fleet.conf project lives on a remote box. The hub's hold reaches that
# box only as a pause_flags ROW, which the box's flag_active reads. With the
# worker down the row cannot be written, so a runaway kept spending on its own
# box for as long as the outage lasted. No ssh (the operator, 2026-09-25): the box
# evaluates its own breaker from its own cost rows.
#
# ONLY DURING AN OUTAGE. Per owned project, `flag_sync spend-hold-<p>` first:
#   rc 0 / 2  the worker answered, so the hub is the one judge. Nothing is
#             evaluated here. A hold this lane took during the outage and could
#             not write as a row (state/cost-local-brake/<p>.pending) is
#             published now: flag_set spend-hold-<p> on "<reason>", and the
#             marker goes only when that PUT lands. If flags/spend-hold-<p> is
#             gone (an operator removed it on the box), the marker goes and
#             nothing is published.
#   rc 1      outage (or an unreadable row). Skip when already held, or paused
#             by a human (paused-<p>, read with flag_has --cached: a
#             harness_flags row since BH-4153), when the kill switches say off
#             (flags/cost-autohalt-off, or the settings row
#             lane.pipeline-health.cost_autohalt = 0, the two the hub honours)
#             or inside the re-arm window of this lane's own last halt.
#             Otherwise take the verdict.
#
# THE VERDICT is the hub's arithmetic on this box's numbers, with the same
# settings rows (lane.pipeline-health[.<p>].<knob>) and cost_budget_for:
#   spend   logs/cost.csv, rows for <p>, numeric cost_usd, product stages
#           (ideate prd mockup signals synth) excluded, 24h and 7d. Fly pool
#           builds write their rows on the pool machine, not here, so this
#           UNDER-counts: the local brake is weaker than the hub's, never
#           stronger.
#   merged  the rollup's search (bin/cost-rollup.sh `merged pr counts`). A count
#           that cannot be taken is unknown, never 0: no hold, one
#           costlocalnoeval alert a day.
#   rules   cost_local_verdict below: the $/PR autohalt and the zero-merge
#           breaker exactly as pipeline-health applies them.
# A project whose 7d spend is under every threshold that could trip is
# skipped before any GitHub call, so a healthy box makes none.
#
# A TRIP writes flags/spend-hold-<p> on THIS box through flag_set (the PUT
# first, then the file, which is written even when the PUT fails, BH-5004), so
# the build launch gate (bin/lib/rb/gates.sh) starts no new build of <p>
# (BH-5526). Merges, reviews, migration applies, triage and builds already
# admitted continue. The reason ends in "(cost autohalt)" or
# "(zero-merge breaker)", the suffixes the console's COST BREAKER card reads.
# It pages costlocalhalt:<p> once a day with the numbers and the lift command.
#
# State: state/cost-local-brake/<p> (epoch of the last local halt: re-arm and
# the since-halt windows), <p>.pending (the reason still owed as a row).
# Log: logs/cost-local-brake.log, one line per tick that did something.
# Switch: flags/lane-off-cost-local-brake (bin/harness-ctl.sh off cost-local-brake).
# Tests: tests/cost-local-brake.bh-2599-test.sh.
set -uo pipefail
H="${HARNESS:-/root/harness}"
SD="$H/state/cost-local-brake"
LOG="$H/logs/cost-local-brake.log"
PRODUCT_STAGES="ideate prd mockup signals synth"

# cost_local_verdict S24 S7 M24 M7 BUD MIN MULT Z24 Z7 ZMIN HALT_AGE
# Pure. HALT_AGE is seconds since this lane's last halt, empty for none. Prints
#   unknown                                   a merged count is not a number
#   rate<TAB><win><TAB><$/PR><TAB><spend><TAB><prs>
#   zm<TAB><win><TAB><spend><TAB><merged><TAB><threshold>
#   ok
cost_local_verdict() {
  local s24="$1" s7="$2" m24="$3" m7="$4" bud="$5" min="$6" mult="$7" z24="$8" z7="$9" zmin="${10}" age="${11:-}"
  local win="" spend=0 prs=0 rate ok24=1 ok7=1
  case "$m24" in ''|*[!0-9]*) echo unknown; return 0 ;; esac
  case "$m7"  in ''|*[!0-9]*) echo unknown; return 0 ;; esac
  # Rate: 24h first, 7d as the fallback, one $/PR budget for both.
  if [ "$m24" -ge "$min" ] 2>/dev/null; then win=24h; spend="$s24"; prs="$m24"
  elif [ "$m7" -ge "$min" ] 2>/dev/null; then win=7d; spend="$s7"; prs="$m7"
  fi
  if [ -n "$win" ]; then
    rate=$(awk -v s="$spend" -v n="$prs" 'BEGIN{ printf "%.2f", (n>0)? s/n : 0 }')
    if awk -v r="$rate" -v b="$bud" -v m="$mult" 'BEGIN{ exit !(r+0 >= m*b) }'; then
      printf 'rate\t%s\t%s\t%s\t%s\n' "$win" "$rate" "$spend" "$prs"; return 0
    fi
  fi
  # Zero-merge: M7 is max(M7, M24); each window is judged only once it lies
  # wholly after the last halt.
  [ "$m24" -gt "$m7" ] && m7="$m24"
  if [ -n "$age" ]; then
    [ "$age" -ge 86400 ] || ok24=0
    [ "$age" -ge 604800 ] || ok7=0
  fi
  if [ "$ok7" = 1 ] && awk -v s="$s7" -v z="$z7" -v n="$m7" -v m="$zmin" \
       'BEGIN{ exit !(z+0 > 0 && s+0 >= z+0 && n+0 < m+0) }'; then
    printf 'zm\t7d\t%s\t%s\t%s\n' "$s7" "$m7" "$z7"; return 0
  fi
  # 24h holds only when the week is empty too: a project that merged this week
  # and not today is what a fleet-wide merge stop looks like.
  if [ "$ok24" = 1 ] && awk -v s="$s24" -v z="$z24" -v n="$m24" -v m="$zmin" -v w="$m7" \
       'BEGIN{ exit !(z+0 > 0 && s+0 >= z+0 && n+0 < m+0 && w+0 < m+0) }'; then
    printf 'zm\t24h\t%s\t%s\t%s\n' "$s24" "$m24" "$z24"; return 0
  fi
  echo ok
}

# clb_knob <ENV> <default> [project] — pipeline-health's cb_knob, read here: the
# settings row (per project first), then the environment, then the default.
clb_knob() {
  local v=""
  if command -v lane_knob >/dev/null 2>&1; then
    v=$(lane_knob pipeline-health "$1" "${3:-}" 2>/dev/null) || v=""
  fi
  [ -n "$v" ] || v="${!1:-}"
  case "$v" in ''|*[!0-9.]*) v="$2" ;; esac
  printf '%s' "$v"
}

# clb_spend <csv> <cut24> <cut7> <project>... -> "<p> <s24> <s7>" per project,
# one pass over the file. Header-indexed, so a column added later moves nothing.
clb_spend() {
  python3 - "$@" "$PRODUCT_STAGES" <<'PY'
import csv, math, sys
path, c24, c7 = sys.argv[1:4]
projects, product = sys.argv[4:-1], set(sys.argv[-1].split())
tot = {p: [0.0, 0.0] for p in projects}
try:
    rows = csv.DictReader(open(path, newline=""))
    for r in rows:
        p = r.get("project")
        if p not in tot or r.get("stage") in product:
            continue
        ts = r.get("ts") or ""
        if ts < c7:
            continue
        try:
            c = float(r.get("cost_usd") or "")
        except ValueError:
            continue  # unpriced: adds nothing, which under-counts (the safe side)
        if math.isnan(c) or math.isinf(c) or c < 0:
            continue
        tot[p][1] += c
        if ts >= c24:
            tot[p][0] += c
except OSError:
    pass
for p in projects:
    print("%s %.2f %.2f" % (p, tot[p][0], tot[p][1]))
PY
}

# clb_merged <owner/repo> <qualifier> -> a number, or rc 1 (unknown, never 0)
clb_merged() {
  local out
  out=$(timeout 30 gh api "search/issues?q=repo:$1+type:pr+$CLB_AUTHOR_Q+is:merged+$2" </dev/null 2>/dev/null) || return 1
  printf '%s' "$out" | jq -e -r '.total_count' 2>/dev/null
}

clb_page() { # clb_page <ttl> <key> <line> [project]
  if command -v page_critical >/dev/null 2>&1; then PAGE_LANE=cost-local-brake page_critical "$@"
  else echo "$(date -u '+%Y-%m-%d %H:%M:%SZ') [cost-local-brake] $2 — $3" >> "$H/logs/ALERTS.log"; fi
}
clb_alert() { # clb_alert <ttl> <key> <line> — one ALERTS line per key per ttl
  local f="$SD/alerted-${2//[^A-Za-z0-9._-]/_}" last
  last=$(tr -dc '0-9' < "$f" 2>/dev/null); last="${last:-0}"
  [ $(( NOW - last )) -lt "$1" ] && return 0
  echo "$NOW" > "$f"
  echo "$(date -u '+%Y-%m-%d %H:%M:%SZ') [cost-local-brake] $2 — $3" >> "$H/logs/ALERTS.log"
}
clb_log() { echo "$(date -u '+%Y-%m-%d %H:%M:%SZ') [$BOX] $*" >> "$LOG"; }

main() {
  [ -r "$H/bin/jobs-client.sh" ] || exit 0
  # shellcheck source=/dev/null
  . "$H/bin/jobs-client.sh" || exit 0
  command -v flag_sync >/dev/null 2>&1 && command -v flag_set >/dev/null 2>&1 || exit 0
  # shellcheck source=/dev/null
  . "$H/bin/lib/hub-box.sh" 2>/dev/null || exit 0
  BOX=$(local_box_name)
  [ -n "$BOX" ] || exit 0
  # fleet-conf.sh looks at /root/harness/fleet.conf before its own tree; the
  # registry this lane judges by is the one beside it.
  export FLEET_CONF="${FLEET_CONF:-$H/fleet.conf}"
  PROJECTS=$("$H/bin/fleet-conf.sh" --projects-on-box "$BOX" 2>/dev/null)
  [ -n "$PROJECTS" ] || exit 0
  # BH-4080: HARNESS_OPERATOR_LOGIN, the author fallback below.
  # shellcheck source=bin/lib/deployment.sh
  . "${HARNESS_DEPLOYMENT_FILE-$H/bin/lib/deployment.sh}" || exit 1
  for _L in cost-budget.sh page-critical.sh gh-pr-list.sh gh-repo-token.sh gh-app-auth.sh; do
    # shellcheck source=/dev/null
    [ -r "$H/bin/lib/$_L" ] && . "$H/bin/lib/$_L" 2>/dev/null
  done
  # cost-autohalt-off is read by lane_switch (BH-2320): its settings row first,
  # the flags/ file when there is no row. A brake that cannot read its own kill
  # switch does not brake.
  # shellcheck source=lib/lane-switch.sh
  . "$H/bin/lib/lane-switch.sh" 2>/dev/null || exit 0
  NOW=$(date +%s)
  mkdir -p "$SD" "$H/logs"

  local p frc reason EVAL=""
  for p in $PROJECTS; do
    flag_sync "spend-hold-$p" >/dev/null 2>&1; frc=$?
    if [ "$frc" != 1 ]; then # <outage-gate>
      # The worker answered: the hub judges. Settle a hold this lane owes as a row.
      [ -e "$SD/$p.pending" ] || continue
      if [ -e "$H/flags/spend-hold-$p" ]; then
        reason=$(cat "$SD/$p.pending" 2>/dev/null)
        if flag_set "spend-hold-$p" on "$reason" >/dev/null 2>&1; then
          rm -f "$SD/$p.pending"; clb_log "$p: worker back, box-local hold published as the spend-hold-$p row"
        else
          clb_log "$p: worker answered but refused the spend-hold-$p row; still owed, retrying next tick"
        fi
      else
        rm -f "$SD/$p.pending"; clb_log "$p: worker back, the box-local hold was already removed on this box; nothing published"
      fi
      continue
    fi
    # Already held, or paused by a human: nothing to add. paused-<p> is a
    # harness_flags row (BH-4153), read from the last good answer.
    { [ -e "$H/flags/spend-hold-$p" ] || flag_has --cached "paused-$p" >/dev/null 2>&1; } && continue
    lane_switch cost-autohalt-off && continue
    [ "$(clb_knob COST_AUTOHALT 1)" = 0 ] && continue
    EVAL="$EVAL $p"
  done
  [ -n "$EVAL" ] || exit 0

  local cut24 cut7 s24 s7 bud min mult z24 z7 zmin rearm at age floor slug m24 m7 v kind win why suffix
  cut24=$(date -u -d "@$(( NOW - 86400 ))" '+%Y-%m-%dT%H:%M:%SZ')
  cut7=$(date -u -d "@$(( NOW - 604800 ))" '+%Y-%m-%dT%H:%M:%SZ')
  CLB_AUTHOR_Q=$(for A in $(command -v harness_pr_authors >/dev/null 2>&1 && harness_pr_authors); do printf 'author:%s+' "$A"; done)
  CLB_AUTHOR_Q="${CLB_AUTHOR_Q%+}"; CLB_AUTHOR_Q="${CLB_AUTHOR_Q:-author:$HARNESS_OPERATOR_LOGIN}"
  # shellcheck disable=SC2086
  while read -r p s24 s7; do
    [ -n "$p" ] || continue
    rearm=$(clb_knob COST_AUTOHALT_REARM_S 86400)
    at=$(tr -dc '0-9' < "$SD/$p" 2>/dev/null); at="${at:-0}"
    age=""; [ "$at" -gt 0 ] && age=$(( NOW - at ))
    [ -n "$age" ] && [ "$age" -lt "${rearm%.*}" ] && continue
    read -r bud min <<<"$(command -v cost_budget_for >/dev/null 2>&1 && cost_budget_for "$p")"
    case "$bud" in ''|*[!0-9.]*) continue ;; esac
    case "$min" in ''|*[!0-9]*) continue ;; esac
    mult=$(clb_knob COST_AUTOHALT_MULTIPLE 2)
    z24=$(clb_knob COST_ZM_24H_USD 300 "$p"); z7=$(clb_knob COST_ZM_7D_USD 400 "$p")
    zmin=$(clb_knob COST_ZM_MIN_MERGES 1 "$p")
    # Nothing could trip below the smallest live threshold: no GitHub call.
    floor=$(awk -v a="$mult" -v b="$bud" -v m="$min" -v z1="$z24" -v z2="$z7" 'BEGIN{
      f = a*b*m; if (z1+0 > 0 && z1+0 < f) f = z1; if (z2+0 > 0 && z2+0 < f) f = z2; print f }')
    awk -v s="$s7" -v f="$floor" 'BEGIN{ exit !(s+0 < f+0) }' && continue
    slug=$("$H/bin/fleet-conf.sh" "$p" repo 2>/dev/null)
    [ -n "$slug" ] && [ "$slug" != - ] || continue
    # The repo's App token when this box mints one, else the PAT that can see it.
    command -v gh_default_auth_for_slug >/dev/null 2>&1 && { gh_default_auth_for_slug "$slug" >/dev/null 2>&1 || true; }
    m24=$(clb_merged "$slug" "merged:>=$cut24") || m24=""
    m7=$(clb_merged "$slug" "merged:>=${cut7%%T*}") || m7=""
    command -v gh_default_auth_reset >/dev/null 2>&1 && gh_default_auth_reset
    v=$(cost_local_verdict "$s24" "$s7" "$m24" "$m7" "$bud" "$min" "$mult" "$z24" "$z7" "$zmin" "$age")
    case "$v" in
      unknown)
        clb_alert 86400 "costlocalnoeval:$p" "$p on $BOX: harness-jobs is unreachable and the merged-PR count for $slug could not be taken (gh search failed), so this box cannot judge the cost breaker for it. \$$s24 spent in 24h, \$$s7 in 7d on this box. Nothing was held."
        continue ;;
      ok) continue ;;
    esac
    IFS=$'\t' read -r kind win _a _b _c <<<"$v"
    if [ "$kind" = rate ]; then
      why="\$$_a/PR over $win (\$$_b / $_c merged PRs)"; suffix="cost autohalt"
    else
      why="\$$_a spend with $_b merged PR(s) over $win"; suffix="zero-merge breaker"
    fi
    reason="$why, box-local: harness-jobs unreachable ($suffix)"
    if flag_set "spend-hold-$p" on "$reason" >/dev/null 2>&1; then
      rm -f "$SD/$p.pending"
      ROW="The hold row is written too, so the console lists it."
      UNDO="Lift it with bin/jobs-client.sh flag_set spend-hold-$p off (resume_board clears paused-$p only)."
    else
      echo "$reason" > "$SD/$p.pending"
      ROW="The hold row is not written yet (the worker is down); this box writes it on the first tick the worker answers."
      UNDO="Until then, lift it on $BOX by removing $H/flags/spend-hold-$p and $SD/$p.pending; once the row is written, flag_set spend-hold-$p off."
    fi
    if [ ! -e "$H/flags/spend-hold-$p" ]; then
      rm -f "$SD/$p.pending"
      clb_log "$p: verdict $kind $win but flags/spend-hold-$p could not be written"
      clb_alert 3600 "costlocalhaltfail:$p" "$p on $BOX tripped the $suffix ($why) while harness-jobs is unreachable, but flags/spend-hold-$p could not be written. New builds are NOT held."
      continue
    fi
    echo "$NOW" > "$SD/$p"
    clb_log "$p: HELD box-local, $reason"
    clb_page 86400 "costlocalhalt:$p" \
      "$p NEW BUILDS HELD on $BOX by the box-local $suffix: $why. Merges, reviews, migration applies and builds already running continue. harness-jobs was unreachable, so the hub could not hold it and this box judged it from its own logs/cost.csv (Fly pool rows are not in it, so the spend is a floor). $ROW $UNDO This box will not hold it again for ${rearm}s." "$p"
  done <<EOF
$(clb_spend "$H/logs/cost.csv" "$cut24" "$cut7" $EVAL)
EOF
}

# Sourced (the suite's verdict cases): the functions above, nothing run.
if [ "${BASH_SOURCE[0]}" != "$0" ]; then return 0; fi

. "$H/bin/lib/env-path.sh" 2>/dev/null || harness_env_dir() { printf '%s\n' "${1:-$H}/env"; }
HENV=$(harness_env_dir "$H")
set -a +u; . "$HENV/global.env" 2>/dev/null; set +a -u
# >>> lane gate (BH-1165): flags/all-off, flags/lane-off-cost-local-brake or a
# pause_flags row driving either exits 0 here. Fails OPEN on an unreachable
# worker, which is the only time this lane has work.
# shellcheck disable=SC1091
. "$H/bin/lib/lane-gate.sh" 2>/dev/null || true
command -v lane_gate_or_exit >/dev/null 2>&1 && lane_gate_or_exit cost-local-brake
command -v lane_env_apply    >/dev/null 2>&1 && lane_env_apply    cost-local-brake
main "$@"
