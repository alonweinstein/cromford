#!/bin/bash
# shellcheck shell=bash
# bin/lib/archie-fm-queue/enqueue.sh — BH-4584 (BH-4574.2): queue-enqueue, an
# approved, green, clean PR that nobody enqueued goes into the Mergify queue
# ONCE, through the conductor's own mc_enqueue_mergify (its lead-authority gate,
# its lead-verdict status, its label and its per-head ask ledger). Sourced by
# bin/archie-fm-queue.sh, never run.
#
# afq_enqueue <project> <slug> <mode> <open-list-json>. Only on a Mergify repo
# (anything else is no action: with no queue an enqueue is a merge), and only
# while the conductor itself would enqueue (afq_merges_on). A PR qualifies when
# ALL of these hold, cheapest first:
#   1 not a draft; base is the project base; head ref not mergify/* or train/*
#   2 no merge-queue / queued / checking / dequeued label
#   3 the conductor does not own it: no row and not a harness PR (an external
#     author's), or a READY row older than archie.queue.ready_unqueued_s with no
#     Mergify ask on this head and no hold the conductor recorded on this head
#     (its ready-why note: dep-hold, ticket-hold, prequeue-pending, lead-held,
#     ...; only merges-off is not a hold, since 5 re-checks the switch). Any
#     other row (WAIT_CI, a park, QUEUED), and a harness PR the conductor has
#     not classified yet, is left to the conductor
#   4 the tier-2 autoenqueue ledger has no enqueued/posting line for the head
#   5 the conductor READY arm's own gates, asked live, each failing closed
#     (afq_conductor_gates): to_lane_hold, pdg_hold, to_lane_lead_fence (a
#     cleared lead PR is never label-enqueued, BH-1606) and bg_scan (a human
#     BLOCK gates every merge path, BH-762); then no main-red freeze, and
#     Mergify does not already witness it
#   6 approved on THIS head: a standing head-bound MERGE / MERGE-WITH-NOTES
#     verdict (vd_standing), the precondition every mc_enqueue_mergify caller
#     has, and no reviewer's latest CHANGES_REQUESTED. A GitHub APPROVED is
#     NOT an approval: mc_enqueue_mergify publishes lead-verdict success, and
#     any login can submit one. A standing BLOCK refuses
#   7 green: each check _ae_required_checks names is green on the head
#   8 a fresh pulls read: open, same head, mergeable_state clean
# External authors are included: there is no author test, but they need the
# same head-bound verdict as anyone else.
# gh-rest: no-graphql

# afq_approved <slug> <n> <head> -> rc 0 a standing MERGE / MERGE-WITH-NOTES
#   verdict on the head and no reviewer whose latest decisive review is
#   CHANGES_REQUESTED, 1 not, 2 a read failed, 3 a standing BLOCK. The reviews
#   can only refuse: a GitHub APPROVED is never the approval.
afq_approved() {
  local slug="$1" n="$2" head="$3" line rc=0 j ans
  line=$(vd_standing "$slug" "$n" "$head") || rc=$?
  case "$rc" in
    0) case "$(cut -f1 <<<"$line")" in
         MERGE|MERGE-WITH-NOTES) ;;
         BLOCK) return 3 ;;
         *) return 1 ;;
       esac ;;
    1) return 1 ;;
    *) return 2 ;;
  esac
  gh_rest_var j GET "repos/$slug/pulls/$n/reviews?per_page=100" || return 2
  ans=$(jq -r '[.[] | select((.state // "") | IN("APPROVED", "CHANGES_REQUESTED", "DISMISSED"))]
    | group_by(.user.login // "") | map(last)
    | if any(.[]; .state == "CHANGES_REQUESTED") then "changes" else "ok" end' <<<"$j" 2>/dev/null) || return 2
  [ "$ans" = ok ]
}

# afq_ready_held <key> <head> -> rc 0 when the conductor recorded a hold on this
#   READY row's head (mc_ready_why's note), rc 1 when it recorded none or only
#   merges-off. A note that outlives its hold costs a tick of the conductor's
#   own enqueue, never a merge.
afq_ready_held() {
  local f h k
  f="${MC_STATE_DIR:-}/ready-why/$(mc_handoff_id "$1")"
  [ -n "${MC_STATE_DIR:-}" ] && [ -r "$f" ] || return 1
  IFS=$'\t' read -r _ h k _ < "$f" 2>/dev/null || return 1
  [ "$h" = "$2" ] && [ "$k" != merges-off ]
}

# afq_conductor_gates <project> <slug> <n> <url> <head> <author> <ref> -> rc 0
#   when every gate the conductor's READY arm asks before its enqueue passes on
#   this head, rc 1 held or unreadable. AFQ_GATE names the gate that held.
afq_conductor_gates() {
  local p="$1" slug="$2" n="$3" url="$4" head="$5" login="$6" ref="$7" rc issue="" r
  AFQ_GATE=""
  if to_lane_hold "$p" "$slug" "$n" "$AFM_LOG"; then AFQ_GATE="a HOLD (to_lane_hold)"; return 1; fi
  rc=0; pdg_hold "$slug" "$n" "$url" "" >/dev/null || rc=$?
  [ "$rc" = 1 ] || { AFQ_GATE="the PR-dependency gate (pdg_hold rc $rc)"; return 1; }
  rc=0; TO_LEAD_CLEARED=0; to_lane_lead_fence "$p" "$slug" "$n" "$head" "$login" "$AFM_LOG" || rc=$?
  [ "$rc" = 1 ] || { AFQ_GATE="the lead fence (rc $rc)"; return 1; }
  [ "${TO_LEAD_CLEARED:-0}" = 1 ] && { AFQ_GATE="a cleared lead PR, which a Mergify label cannot pin (BH-1606)"; return 1; }
  r=$(afq_root)
  if [ -n "$r" ] && [ "$("$r/bin/fleet-conf.sh" "$p" board_prefix 2>/dev/null)" = "-" ] && command -v mc_issue_of >/dev/null 2>&1; then
    issue=$(mc_issue_of "$(mc_record_for "$url" || true)" "$ref" 2>/dev/null) || issue=""
  fi
  rc=0; bg_scan "$slug" "$n" "$url" "$head" "$issue" >/dev/null || rc=$?
  [ "$rc" = 0 ] || { AFQ_GATE="the block gate (bg_scan rc $rc)"; return 1; }
  return 0
}

# afq_enq_one <project> <slug> <mode> <pr-json> <pbase> <ready-s> <required-checks>
afq_enq_one() {
  local p="$1" slug="$2" mode="$3" pr="$4" pbase="$5" ready_s="$6" req="$7"
  local n head ref draft base labels url key row st since askf r rc ev ck out erc left wait
  IFS=$'\x1f' read -r n head ref draft base labels <<<"$(jq -r '[(.number // "" | tostring), (.head.sha // ""), (.head.ref // ""),
     (.draft // false | tostring), (.base.ref // ""), ([.labels[]?.name] | join(","))] | join("\u001f")' <<<"$pr")"
  [[ $n =~ ^[0-9]+$ ]] && [[ $head =~ ^[0-9a-f]{40}$ ]] || return 0
  key="$slug#$n"; url="https://github.com/$slug/pull/$n"
  [ -z "${ONLY_PR:-}" ] || [ "$ONLY_PR" = "$key" ] || return 0
  # 1, 2
  [ "$draft" = false ] && [ "$base" = "$pbase" ] || return 0
  case "$ref" in mergify/*|train/*) return 0 ;; esac
  case ",$labels," in *,merge-queue,*|*,"${MC_MERGIFY_LABEL:-merge-queue}",*|*,queued,*|*,checking,*|*,dequeued,*) return 0 ;; esac
  # 3
  row=$(mc_row_get "$key"); st=$(cut -f2 <<<"$row"); since=$(cut -f3 <<<"$row")
  case "$st" in
    # No row on a harness PR is a PR the conductor has not classified yet; its
    # parks (provenance, iron laws, the dependency gate) come first.
    "") mc_is_harness_pr "$ref" "$(mc_record_for "$url" || true)" && return 0 ;;
    READY)
      [[ $since =~ ^[0-9]+$ ]] && [ $((NOW - since)) -ge "$ready_s" ] || return 0
      askf=$(mc_mergify_ask_file "$slug" "$url")
      if [ -n "$askf" ] && [ -f "$askf" ] && [ "$(head -1 "$askf" | cut -f1)" = "$head" ]; then return 0; fi
      afq_ready_held "$key" "$head" && return 0 ;;
    *) return 0 ;;
  esac
  # 4
  r=$(afq_root)
  if [ -n "$r" ] && awk -v u="$url" -v h="$head" '$1 == u && $2 == h && ($3 == "enqueued" || $3 == "posting") { f = 1 } END { exit !f }' \
       "$r/state/tier2-autoenqueue.txt" 2>/dev/null; then
    return 0
  fi
  # 5, under the conductor's PR lock (-n: it is working this PR, so skip it).
  afq_pr_lock "$p" "$n" || { afq_log "$key: the conductor holds its PR lock; skipped this tick"; AFQ_N_SKIPPED=$((AFQ_N_SKIPPED + 1)); return 0; }
  if ! afq_conductor_gates "$p" "$slug" "$n" "$url" "$head" "$(jq -r '.user.login // ""' <<<"$pr")" "$ref"; then
    afq_log "$key: held by $AFQ_GATE on ${head:0:8}; not enqueued"; afq_pr_unlock; return 0
  fi
  if command -v main_red_hold >/dev/null 2>&1 && main_red_hold "$p" "$slug" "$n" "$url" "$head" "${labels:-none}"; then
    afq_log "$key: main is red (${MRG_FLAG:-freeze}); not enqueued"; afq_pr_unlock; return 0
  fi
  rc=0; mc_mergify_witness "$slug" "$url" "$head" || rc=$?
  [ "$rc" = 1 ] || { afq_pr_unlock; return 0; }
  # 6
  rc=0; afq_approved "$slug" "$n" "$head" || rc=$?
  case "$rc" in
    0) ;;
    2) afq_log "$key: the approval could not be read; not enqueued this tick"; afq_pr_unlock; return 0 ;;
    *) afq_pr_unlock; return 0 ;;
  esac
  # 7
  rc=0; afq_checks_green "$slug" "$head" "$req" || rc=$?
  [ "$rc" = 2 ] && afq_log "$key: the check-runs could not be read; not enqueued this tick"
  [ "$rc" = 0 ] || { afq_pr_unlock; return 0; }
  # 8
  if ! afq_pr_fresh "$slug" "$n"; then afq_log "$key: the pulls read failed (HTTP ${GH_REST_STATUS:-000}); not enqueued this tick"; afq_pr_unlock; return 0; fi
  [ "$AFQ_PR_STATE" = open ] && [ "$AFQ_PR_HEAD" = "$head" ] && [ "$AFQ_PR_MS" = clean ] && [ "$AFQ_PR_DRAFT" = false ] \
    || { afq_pr_unlock; return 0; }
  wait=${MC_MERGIFY_WAIT_S:-90}; [[ $wait =~ ^[0-9]+$ ]] || wait=0
  left=$(afq_time_left)
  if [ "$mode" = on ] && [ "$left" -lt $((wait + 60)) ]; then
    afq_log "$key: ${left}s left in this tick, under an enqueue's wait; waits for the next tick"; AFQ_N_SKIPPED=$((AFQ_N_SKIPPED + 1)); afq_pr_unlock; return 0
  fi
  if [ "$mode" = on ] && ! afq_cap_ok queue-enqueue "$p"; then AFQ_N_CAPPED=$((AFQ_N_CAPPED + 1)); afq_pr_unlock; return 0; fi
  ev=$(jq -nc --arg h "$head" --arg a "$AFQ_PR_USER" --arg st "${st:--}" --arg c "$req" \
    '{head: $h, author: $a, conductor_state: $st, required_checks: ($c | split("\n") | map(select(length > 0)))}')
  ck="queue-enqueue:$slug#$n:$head:$mode"
  if [ "$mode" != on ]; then
    afq_claim queue-enqueue "$ck" "$p" "$slug" "$n" observe would_enqueue "would enqueue: approved on ${head:0:12}, green and clean, and nobody enqueued it" "$ev" \
      || { afq_pr_unlock; return 0; }
    afq_log "$key: would enqueue ${head:0:8} (approved, green, clean, nobody enqueued it); observe mode, nothing written"
    AFQ_N_WOULD=$((AFQ_N_WOULD + 1)); afq_pr_unlock; return 0
  fi
  afq_claim queue-enqueue "$ck" "$p" "$slug" "$n" on enqueue "approved on ${head:0:12}, green and clean, and nobody enqueued it" "$ev" \
    || { afq_pr_unlock; return 0; }
  erc=0; out=$(mc_enqueue_mergify "$slug" "$url" "$head" 2>&1) || erc=$?
  out=$(printf '%s' "$out" | tr '\n' ' ' | cut -c1-400)
  case "$erc" in
    0|2)
      afq_close queue-enqueue done enqueue "enqueued through mc_enqueue_mergify (rc $erc)" "$(jq -c --argjson rc "$erc" '. + {enqueue_rc: $rc}' <<<"$ev")" || true
      afq_log "$key: enqueued ${head:0:8} (mc_enqueue_mergify rc $erc)"
      AFQ_N_ENQUEUED=$((AFQ_N_ENQUEUED + 1)) ;;
    *)
      afq_close queue-enqueue failed "" "mc_enqueue_mergify rc $erc: ${out:-no reason given}" \
        "$(jq -c --argjson rc "$erc" --arg o "$out" '. + {enqueue_rc: $rc, answer: $o}' <<<"$ev")" || true
      afq_log "$key: not enqueued, mc_enqueue_mergify rc $erc: ${out:-no reason given}; not retried on ${head:0:8}"
      AFQ_N_FAILED=$((AFQ_N_FAILED + 1)) ;;
  esac
  afq_pr_unlock
  return 0
}

# afq_enqueue <project> <slug> <mode> <open-list-json> — the playbook.
afq_enqueue() {
  local p="$1" slug="$2" mode="$3" list="$4" ready_s pbase req pr
  local f
  [ "$(afq_provider "$slug")" = mergify ] || return 0
  if ! afq_merges_on "$p"; then afq_log "$p: merges are off or paused; queue-enqueue waits"; return 0; fi
  # The conductor's gates are not optional here: one missing is no enqueue.
  for f in to_lane_hold pdg_hold to_lane_lead_fence bg_scan mc_handoff_id; do
    command -v "$f" >/dev/null 2>&1 || { afq_log "$p: $f is not loaded on this box; queue-enqueue does nothing"; return 0; }
  done
  ready_s=$(afq_setting_secs archie.queue.ready_unqueued_s 1800) || return 0
  pbase=$(mc_project_base "$p")
  req=$(_ae_required_checks "$slug") || { afq_log "$p: the required checks of $slug could not be read; queue-enqueue waits"; return 0; }
  while IFS= read -r pr; do
    [ "$AFM_ROUTE_ABSENT" = 1 ] && return 0
    afq_enq_one "$p" "$slug" "$mode" "$pr" "$pbase" "$ready_s" "$req"
  done < <(jq -c '.[]' <<<"$list")
  return 0
}
