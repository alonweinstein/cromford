#!/bin/bash
# shellcheck shell=bash
# bin/lib/br/opt/stale.sh — BH-3935 (BH-3929.3): the re-plan rung of the
# PR-owner age ladder.
#
# bin/lib/pr-owner/stale.sh parks a PR nobody moved (no new commit, no new
# verdict) for pr_stale.replan_days as BLOCKED_HUMAN `stale-replan: no head or
# verdict change for <d>d`. That reason is resolver-owned (bin/lib/mc/
# classify.sh), so the park reaches this lane, and this module is its only rung.
#
# THE RE-PLAN is the CI park's (bin/lib/br/opt/cirepair.sh), with its own note:
# state/build-notes/<p>/<key>.md, first line `KIND: stale-replan` (the plan
# stage reads it as a fresh re-plan, bin/lib/rb/plan.sh), then ONE fresh build
# of the ticket through br_enqueue_fresh. The PR is NOT closed. The cap is the
# CI park's own: BR_CI_REPLAN_MAX re-plans per ticket, counted on `ci_replans`
# with br_ci_replan_floor (which counts both KINDs) under it, so the two
# ladders together never re-plan one ticket more than that. With the cap spent,
# no key, or the knob at 0, nothing is enqueued; the age ladder's rung 3 closes
# the PR at pr_stale.close_days.
#
# THE SUPERSEDE. Once the re-plan's own PR exists (br_ci_replan_successor), the
# stale PR is closed as superseded by it, but only on the head it was parked
# on: a push since then is somebody's work, so both PRs are left open and that
# is said once per head. Not br_ci_supersede_parked: that one also demands a
# head one of this lane's CI repair rounds pushed, which a stale PR never has.
#
# THE HOOK is br_opt_stale_rung, called by br_one right after
# br_opt_ci_cap_rung (bin/lib/br/opt/README.md): rc 0 = acted this tick (a
# re-plan enqueued, the stale PR superseded, or an OBSERVE line), rc 3 = a
# terminal for this tick (waiting for the re-plan's PR, nothing to re-plan,
# a close to retry): no rung, no slot, rc 1 = not a stale park. br_one never
# lets a stale park reach the ladder, so BR_OPT_OFF=stale leaves it parked.
#
# Record fields (br_cap_key, the ticket's): stale_replan_url, stale_replan_at,
# stale_parked_head, stale_supersede_left, stale_superseded_by, ci_replans.
# Tests: tests/pr-stale-ladder.bh-3929-test.sh.

# br_stale_days <url> — the <d> out of the conductor row's raw reason, or "".
br_stale_days() {
  local slug num raw
  case "${1:-}" in https://github.com/*/*/pull/*) ;; *) return 0 ;; esac
  command -v mc_row_field >/dev/null 2>&1 || return 0
  slug=$(mc_slug_of_url "$1"); num=$(mc_num_of_url "$1")
  raw=$(mc_row_field "$slug#$num" 7 2>/dev/null)
  printf '%s' "$raw" | sed -nE 's/.*for ([0-9]+)d.*/\1/p' | head -1
}

# br_stale_replan_note <project> <ticket-key> <pr-url> <days>
#   The re-plan's evidence, in the resolver's carried-note channel. The first
#   line `KIND: stale-replan` is what makes the plan stage read it as a re-plan
#   rather than an adjudication ruling, and what br_ci_replan_floor counts.
br_stale_replan_note() {
  local p="$1" tkey="$2" url="$3" days="$4" d span
  [ -n "$tkey" ] && [ "$tkey" != "-" ] || return 1
  d="${NOTES:-$H/state/build-notes}/$p"; mkdir -p "$d" 2>/dev/null || return 1
  span="${days:+for $days days}"; span="${span:-past pr_stale.replan_days}"
  {
    printf 'KIND: stale-replan\n'
    printf 'PRIOR PR: %s (parked OPEN, no head or verdict movement %s)\n' "${url:--}" "$span"
    printf 'RE-PLAN: the prior PR of this ticket sat with no new commit and no new review %s, so it was parked and this ticket is re-planned. Re-read the ticket thread, plan it fresh against current main, and do not assume the prior PR'"'"'s approach was right. The prior PR stays open until this build opens its own, then it is closed as superseded.\n' "$span"
  } > "$d/$tkey.md.tmp" && mv -f "$d/$tkey.md.tmp" "$d/$tkey.md"
}

br_opt_stale_rung() {
  local p="$1" rkey="$2" reason="$3" url="$4" rec="$5" tkey="${6:--}"
  command -v br_ladder_class >/dev/null 2>&1 && [ "$(br_ladder_class "$reason")" = stale-replan ] || return 1
  local ck st days at since new nn ph cur hrc crc=0 ckey
  ck=$(br_cap_key "$p" "$rkey" "$tkey"); st=$(br_load "$p" "$ck")
  days=$(br_stale_days "$url")
  # ALREADY RE-PLANNED (or refused) FOR THIS PR: the supersede, or nothing.
  if [ "$(printf '%s' "$st" | jq -r '.stale_replan_url // ""' 2>/dev/null)" = "$url" ]; then
    [ -n "$(printf '%s' "$st" | jq -r '.stale_superseded_by // ""' 2>/dev/null)" ] && return 3
    at=$(printf '%s' "$st" | jq -r '.stale_replan_at // ""' 2>/dev/null)
    [ -n "$at" ] && [ "$at" != - ] || return 3
    since=$(date -u -d "$at" +%s 2>/dev/null) || return 3
    new=$(br_ci_replan_successor "$p" "$tkey" "$url" "$since") || return 3
    nn="${new##*/}"
    ph=$(printf '%s' "$st" | jq -r '.stale_parked_head // ""' 2>/dev/null)
    cur=$(br_pr_field "$url" '.head.sha' "pr head" 2>/dev/null); hrc=$?
    cur=$(printf '%s' "$cur" | tr 'A-F' 'a-f')
    if [ "$hrc" != 0 ] || [ -z "$cur" ]; then
      say "$p/$rkey [$reason]: the re-plan's PR $new exists but the stale PR's head could not be read — nothing closed, asked again next tick"
      return 3
    fi
    if [ -z "$ph" ] || [ "$ph" = "-" ] || [ "$cur" != "$ph" ]; then
      [ "$(printf '%s' "$st" | jq -r '.stale_supersede_left // ""' 2>/dev/null)" = "$cur" ] && return 3
      br_set_field "$p" "$ck" stale_supersede_left "$cur" >/dev/null 2>&1 || true
      say "$p/$rkey [$reason]: NOT superseded: its head moved since the stale park (${ph:0:12} -> ${cur:0:12}) — someone pushed to it, so it is left OPEN beside the re-plan's $new"
      return 3
    fi
    if [ "${OBSERVE:-0}" = 1 ]; then say "$p/$rkey [$reason]: WOULD close the stale PR — superseded by #$nn (re-plan after no movement) — observe mode"; return 0; fi
    br_close_pr "$url" "Superseded by #$nn (re-plan after no movement): $new. Nothing moved on this PR for days, so the ticket was re-planned, and the re-plan now has its own PR. This one is closed unmerged. The branch is left in place." || crc=$?
    if [ "$crc" != 0 ]; then
      say "$p/$rkey [$reason]: the re-plan's PR $new exists but the stale PR could not be closed this tick — retried next tick"
      return 3
    fi
    [ -n "$rec" ] && [ "$rec" != "-" ] && [ -d "$rec" ] && : > "$rec/.blocked-resolver-superseded"
    br_set_field "$p" "$ck" stale_superseded_by "$new" >/dev/null 2>&1 || true
    br_record "$p" "$ck" stale-park-superseded "$reason" "closed unmerged: superseded by $new (re-plan after no movement)"
    ckey=$(mc_slug_of_url "$url" 2>/dev/null)
    [ -n "$ckey" ] && command -v mc_transition >/dev/null 2>&1 \
      && mc_transition "$ckey#$(mc_num_of_url "$url")" CLOSED "blocked-resolver: superseded by $new (re-plan after no movement)" "-" "-" "$url" "-" "-" "${rec:--}" >/dev/null 2>&1
    say "$p/$rkey [$reason]: stale park SUPERSEDED — closed $url, superseded by $new (re-plan after no movement)"
    return 0
  fi
  # THE RE-PLAN, ONCE PER PR, under the CI park's shared cap.
  local rmax used floor why="" erc phead
  rmax=$(br_ci_replan_max)
  used=$(printf '%s' "$st" | jq -r '(.ci_replans // "0") | tostring | tonumber? // 0' 2>/dev/null); case "$used" in ''|*[!0-9]*) used=0 ;; esac
  floor=$(br_ci_replan_floor "$p" "$tkey"); [ "${floor:-0}" -gt "$used" ] && used=$floor
  if [ -z "$tkey" ] || [ "$tkey" = "-" ]; then why="no ticket key could be derived for this PR"
  elif [ "$rmax" -eq 0 ]; then why="automatic re-plan is off (BR_CI_REPLAN_MAX=0)"
  elif [ "$used" -ge "$rmax" ]; then why="the ticket already had $used automatic re-plan(s) (BR_CI_REPLAN_MAX=$rmax)"
  fi
  if [ -n "$why" ]; then
    if [ "${OBSERVE:-0}" = 1 ]; then say "$p/$rkey [$reason]: WOULD skip the re-plan — $why — observe mode"; return 0; fi
    br_set_field "$p" "$ck" stale_replan_url "$url" >/dev/null 2>&1 || true
    br_record "$p" "$ck" stale-replan-skipped "$reason" "no re-plan: $why; the PR stays open and the age ladder closes it at pr_stale.close_days"
    say "$p/$rkey [$reason]: stale park NOT re-planned — $why; left open for the age ladder's close"
    return 3
  fi
  if [ "${OBSERVE:-0}" = 1 ]; then say "$p/$rkey [$reason]: WOULD re-plan the ticket (re-plan $((used + 1)) of $rmax) — observe mode"; return 0; fi
  br_stale_replan_note "$p" "$tkey" "$url" "$days" \
    || { say "$p/$rkey [$reason]: the re-plan note could not be written — nothing enqueued, retried next tick"; return 0; }
  erc=0
  br_enqueue_fresh "$p" "$tkey" "$(br_num "$st" rebuilds)" "stale-replan: no head or verdict change${days:+ for ${days}d} on ${url:--}" "$rec" "$rkey" "$url" || erc=$?
  case "$erc" in
    0|3)
      phead=$(br_pr_field "$url" '.head.sha' "pr head" 2>/dev/null) || phead=""
      br_set_field "$p" "$ck" stale_replan_url "$url" >/dev/null 2>&1 || true
      br_set_field "$p" "$ck" stale_replan_at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >/dev/null 2>&1 || true
      br_set_field "$p" "$ck" stale_parked_head "$(printf '%s' "${phead:--}" | tr 'A-F' 'a-f')" >/dev/null 2>&1 || true
      br_set_field "$p" "$ck" ci_replans "$((used + 1))" >/dev/null 2>&1 || true
      br_record "$p" "$ck" stale-replan "$reason" "re-plan $((used + 1)) of $rmax enqueued (job ${BR_JOB_ID:-already queued}) for ${url:--}, parked OPEN with no head or verdict movement${days:+ for ${days}d}"
      say "$p/$rkey [$reason]: stale park RE-PLANNED — $tkey enqueued fresh (re-plan $((used + 1)) of $rmax); $url stays open until the re-plan's PR supersedes it"
      return 0 ;;
    2|4)
      br_set_field "$p" "$ck" stale_replan_url "$url" >/dev/null 2>&1 || true
      br_record "$p" "$ck" stale-replan-skipped "$reason" "no re-plan: it could not be enqueued (${BR_ENQUEUE_WHY:-rc $erc}); the age ladder closes the PR at pr_stale.close_days"
      say "$p/$rkey [$reason]: stale park NOT re-planned — the enqueue was refused (${BR_ENQUEUE_WHY:-rc $erc}); left open for the age ladder's close"
      return 3 ;;
    *)
      say "$p/$rkey [$reason]: the re-plan could not be enqueued this tick (${BR_ENQUEUE_WHY:-rc $erc}) — retried next tick"
      return 0 ;;
  esac
}
