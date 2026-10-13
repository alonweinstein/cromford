#!/bin/bash
# bin/lib/wake-class-pr-ci.sh — BH-1034 wake class `pr-ci`.
#
# ARMED BY the class flag `wake-lanes-pr-ci` (`bin/jobs-client.sh flag-set
# wake-lanes-pr-ci on`), and by nothing else. Without that flag
# bin/wake-loop.sh's CLASS_ON is 0 for this class and neither hook below is ever
# called. flags/wake-lanes-off beats the class flag.
#
# WHAT CI ACTIVITY MEANS HERE. A PR that opened, got a push, was reopened or
# came out of draft, and every finished check suite, are the moments
# bin/review-prs.sh has something new to read. That lane is PER PROJECT and it
# runs on the box that owns the project, so it always travels through
# remote_launch with the box bin/box-for.sh names — never a local run for a
# remote box, and no launch at all for a project the registry cannot place.
# bin/review-autopilot.sh is hub-wide and fires at most once per drain.
#
# A3: bin/review-prs.sh's own CI debounce (:385-:455) is untouched by this
# class. The wake only makes that lane's FIRST read happen sooner; what it
# decides once it reads is unchanged, including its reviewed-sha ledger.
#
# A5: bin/tickets-snapshot-push.sh stays HUB-SIDE. It holds the board tokens
# and pushes one snapshot for every board, so it is launched with launch(),
# never shipped to a project box.
#
# SOURCE-TIME RULE. wake-loop.sh sources this file BEFORE it defines cooled(),
# launch(), say() and remote_launch(), so nothing here may call them at source time — only from the dispatch function, inside drain().
# shellcheck shell=bash

# Accumulators, initialised at source time (see the pr-closed class for why).
WC_CI_PROJECTS=""
WC_SNAPSHOT=0

# wc_pr_ci_row <project> <kind> <key> <event> <repo> <id>
wc_pr_ci_row() {
  local p="${1:-}" kind="${2:-}" event="${4:-}" add=0
  case "$kind" in
    # BH-1292 (I3): a completed check SUITE is one row per CI run per sha; a
    # `check_run.completed` is one per JOB, deduped by the receiver only per
    # (repo, kind, key, minute), so a run whose jobs finish in different
    # minutes stored N rows for one sha and launched review-prs once per 120s
    # cooldown. Only the suite counts here, exactly as wake-class-flaky.sh:14.
    checks) [ "$event" = "check_suite.completed" ] && add=1 ;;
    pr)
      case "$event" in
        pull_request.opened|pull_request.synchronize|pull_request.reopened|pull_request.ready_for_review) add=1 ;;
      esac
      ;;
  esac
  if [ "$add" = 1 ] && [ -n "$p" ]; then
    # Same dedupe idiom the loop uses for push_projects.
    case " $WC_CI_PROJECTS " in *" $p "*) ;; *) WC_CI_PROJECTS="$WC_CI_PROJECTS $p" ;; esac
  fi
  # The kanban snapshot is about tickets and PRs moving at all, so it keys off
  # the KIND, not the action: pull_request.closed sets only this bit.
  case "$kind" in pr|issue) WC_SNAPSHOT=1 ;; esac
  return 0
}

# wc_pr_ci_dispatch — once per non-empty drain.
wc_pr_ci_dispatch() {
  local p
  for p in $WC_CI_PROJECTS; do
    cooled review-prs "$p" 120 || continue
    # remote_launch owns the placement: it resolves the box with box-for.sh,
    # runs the lane here when the box is `local` or this box's own crontab
    # already drives it, ssh's to the owner otherwise, and fails CLOSED with a
    # log line for a project fleet.conf cannot place — never a hub run against
    # the wrong repo checkout. The script is passed by BARE NAME: the far side
    # prefixes /root/harness/bin itself.
    remote_launch "review-prs[$p]" "$p" review-prs.sh "$p" || true
  done
  # Hub-wide, and only on a drain that actually carried CI/PR-open activity.
  [ -n "$WC_CI_PROJECTS" ] && cooled review-autopilot fleet 3600 && launch "pr-ci" "$SELF/review-autopilot.sh" || true
  [ "${WC_SNAPSHOT:-0}" = 1 ] && cooled snapshot fleet 300 && launch "pr-ci" "$SELF/tickets-snapshot-push.sh" || true
  WC_CI_PROJECTS=""
  WC_SNAPSHOT=0
  return 0
}
