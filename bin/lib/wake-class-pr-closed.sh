#!/bin/bash
# bin/lib/wake-class-pr-closed.sh — BH-1034 wake class `pr-closed`.
#
# ARMED BY the class flag `wake-lanes-pr-closed` (`bin/jobs-client.sh flag-set
# wake-lanes-pr-closed on`), and by nothing else. Without that flag
# bin/wake-loop.sh's CLASS_ON is 0 for this class and neither hook below is
# ever called, so the loop behaves exactly as it does today. flags/wake-lanes-off
# beats the class flag.
#
# WHAT A CLOSURE MEANS HERE. A PR closing (merged or abandoned) is the moment
# three hub-wide lanes have new work and would otherwise sit on their crons:
#   bin/reconcile-prs.sh        */10 — the console's "unmerged" rows are now wrong
#   bin/check-migration-prs.sh  */30 — a merged PR may carry unapplied SQL
#   bin/alerts-groom.sh         every 2h — alerts naming that PR are now settled
# All three are FLEET-WIDE: each walks every repo in fleet.conf on its own, so
# one launch answers every closure in the drain whatever repo it came from.
# That is why the cooldowns below are taken under the literal project "fleet".
#
# BH-3997: a closure, and Mergify's `queued` label (the one label the worker
# stores, as pull_request.labeled), are also the moment pipeline-health's merge
# alerts become false. Both go to bin/alerts-merge-resolve.sh in ONE launch per
# drain (--closed … --queued …), which settles those rows with no GitHub call.
# A label is NOT a closure: it launches that resolver, and none of the three
# closure lanes above.
#
# BH-4055: a close, the `queued` label and GitHub's merge-queue `enqueued` /
# `dequeued` also re-judge pipeline-health's PR checks, so the ph-stalepr_* and
# ph-leadunqueued_* rows retract in this drain instead of on the */10 cron:
# `pipeline-health.sh --sections stalepr,leadunqueued`, launched LAST (after
# the resolvers that ask GitHub nothing), at most once per loop invocation and
# under `cooled pipeline-health fleet` (hub only, WAKE_COOLDOWN_S). A launch the
# cap or the cooldown holds is not owed: the cron run covers it. `enqueued`
# also counts as queued for bin/alerts-merge-resolve.sh; `dequeued` does not.
#
# A11: bin/alerts-groom.sh exits 0 quietly until the console ships
# /api/alerts/open + /api/alerts/resolve, so launching it early costs one curl
# that gets a non-JSON answer, never a wrong write.
#
# SOURCE-TIME RULE. wake-loop.sh sources this file BEFORE it defines cooled(),
# launch() and say(), so nothing here may call them at source time — only from
# the dispatch function, which runs inside drain().
# shellcheck shell=bash

# Accumulator, initialised at source time: the loop runs under `set -u`, and an
# unset accumulator would make the dispatch raise, which the loop's `|| true`
# would swallow into a silently dead class.
WC_PR_CLOSED=0
# V1 alert hygiene: the closed PRs themselves, "<owner/repo>#<N>" space-separated,
# for bin/alerts-resolve-closed-prs.sh (the webhook IS the evidence it closed).
WC_PR_CLOSED_PRS=""
# BH-3997: PRs that just got the `queued` label, "<owner/repo>#<N>" space-separated.
WC_PR_QUEUED_PRS=""
# BH-4055: a row that should re-judge pipeline-health's PR checks this drain,
# and how many such runs this loop invocation already launched.
WC_PR_PH=0
WC_PR_PH_LAUNCHED=0

# wc_pr_closed_row <project> <kind> <key> <event> <repo> <id>
# Only a pr row whose event carries the `.closed` action counts as a closure,
# and `.labeled` (worker-side, only ever the `queued` label) as a queued PR. A
# bare `pull_request` (an old row the worker stored without an action), a `-`,
# any other action, and any other kind all set nothing.
wc_pr_closed_row() {
  local kind="${2:-}" key="${3:-}" event="${4:-}" repo="${5:-}"
  case "$kind/$event" in
    pr/pull_request.labeled|pr/pull_request.enqueued|pr/pull_request.dequeued|pr/pull_request.closed)
      WC_PR_PH=1 ;;
  esac
  case "$kind/$event" in
    pr/pull_request.labeled|pr/pull_request.enqueued)
      case "$key" in ''|*[!0-9]*) ;; *)
        case "$repo" in */*)
          case " $WC_PR_QUEUED_PRS " in
            *" $repo#$key "*) ;;
            *) WC_PR_QUEUED_PRS="${WC_PR_QUEUED_PRS:+$WC_PR_QUEUED_PRS }$repo#$key" ;;
          esac ;;
        esac ;;
      esac ;;
    pr/pull_request.closed)
      WC_PR_CLOSED=1
      case "$key" in ''|*[!0-9]*) ;; *)
        case "$repo" in */*)
          case " $WC_PR_CLOSED_PRS " in
            *" $repo#$key "*) ;;
            *) WC_PR_CLOSED_PRS="${WC_PR_CLOSED_PRS:+$WC_PR_CLOSED_PRS }$repo#$key" ;;
          esac ;;
        esac ;;
      esac ;;
  esac
  return 0
}

# wc_pr_closed_dispatch — once per non-empty drain. Each launch is guarded on
# its own so a cooldown that refuses, or a lane script that is not executable,
# does not stop the next one.
wc_pr_closed_dispatch() {
  [ "${WC_PR_CLOSED:-0}" = 1 ] || [ -n "${WC_PR_QUEUED_PRS:-}" ] || [ "${WC_PR_PH:-0}" = 1 ] || return 0
  if [ "${WC_PR_CLOSED:-0}" = 1 ]; then
    cooled reconcile fleet 120       && launch "pr-closed" "$SELF/reconcile-prs.sh" || true
    cooled check-migration fleet 120 && launch "pr-closed" "$SELF/check-migration-prs.sh" || true
    cooled alerts-groom fleet 300    && launch "pr-closed" "$SELF/alerts-groom.sh" || true
  fi
  # NOT cooled: it asks GitHub nothing and closes only rows about exactly these
  # PRs; a cooldown would leave the next drain's closures open until the
  # groomer's 2h cron. One launch per drain, every closed PR as an argument.
  # shellcheck disable=SC2086
  if [ -n "${WC_PR_CLOSED_PRS:-}" ]; then
    launch "pr-closed" "$SELF/alerts-resolve-closed-prs.sh" $WC_PR_CLOSED_PRS || true
  fi
  # BH-3997: NOT cooled either, for the same reason (no GitHub call, only rows
  # about exactly these PRs).
  # shellcheck disable=SC2086
  if [ -n "${WC_PR_CLOSED_PRS:-}" ] || [ -n "${WC_PR_QUEUED_PRS:-}" ]; then
    launch "pr-closed" "$SELF/alerts-merge-resolve.sh" \
      ${WC_PR_CLOSED_PRS:+--closed $WC_PR_CLOSED_PRS} ${WC_PR_QUEUED_PRS:+--queued $WC_PR_QUEUED_PRS} || true
  fi
  # BH-4055: last, so the GitHub-free resolvers above go first. The run reads
  # GitHub, so it is cooled and capped at one per loop invocation.
  if [ "${WC_PR_PH:-0}" = 1 ]; then
    if [ "${WC_PR_PH_LAUNCHED:-0}" -ge 1 ]; then
      say "pr-closed: pipeline-health sections run held, per-tick cap; cron */10 covers it"
    elif cooled pipeline-health fleet "${COOLDOWN:-120}"; then
      launch "pr-closed" "$SELF/pipeline-health.sh" --sections stalepr,leadunqueued \
        && WC_PR_PH_LAUNCHED=$((WC_PR_PH_LAUNCHED + 1))
    fi
  fi
  WC_PR_CLOSED_PRS=""
  WC_PR_QUEUED_PRS=""
  WC_PR_CLOSED=0
  WC_PR_PH=0
  return 0
}
