#!/bin/bash
# bin/lib/wake-class-deploy.sh — BH-1062 deploy wake class (BH-1034 child D).
# Sourced by bin/wake-loop.sh; defines wc_deploy_row and wc_deploy_dispatch.
# Fires only when flags/wake-lanes-deploy is on (enforced by class_on in the loop).
#
# WHAT A DEPLOY WAKE MEANS. The worker only stores a `deploy` row for a
# deployment_status whose state is `success`, so the row IS "production is now
# serving <key>". Three lanes were waiting on exactly that fact and learned it
# from a clock instead: bin/deploy-train.sh was asleep in a poll interval,
# bin/migration-autopilot.sh and bin/apply-migrations.sh were waiting for their
# next */15 tick to find out the bundle that carries their SQL is live.
#
# SOURCE-TIME RULE. Nothing here may call cooled/launch/remote_launch/say at
# source time: the loop sources every class file BEFORE those functions exist.
# They are only ever called from inside wc_deploy_dispatch.
# shellcheck shell=bash

# Accumulated by wc_deploy_row, consumed by wc_deploy_dispatch.
WC_DEPLOY_PROJECTS=""
declare -gA WC_DEPLOY_SHA=()

# wc_deploy_row <project> <kind> <key> <event> <repo> <id>
wc_deploy_row() {
  local project="${1:-}" kind="${2:-}" key="${3:-}"
  [ "$kind" = "deploy" ] && [ -n "$project" ] || return 0
  # Last row wins: the key is the deployment sha, and the sha production is
  # serving NOW is the last one this drain read for the project.
  WC_DEPLOY_SHA["$project"]="$key"
  case " $WC_DEPLOY_PROJECTS " in
    *" $project "*) ;;
    *) WC_DEPLOY_PROJECTS="${WC_DEPLOY_PROJECTS:+$WC_DEPLOY_PROJECTS }$project" ;;
  esac
  return 0
}

# wc_deploy_dispatch — run once per non-empty drain, after the legacy lanes.
wc_deploy_dispatch() {
  local p sha H="${H:-${HARNESS:-/root/harness}}"
  for p in $WC_DEPLOY_PROJECTS; do
    sha="${WC_DEPLOY_SHA[$p]:-}"
    # A FILE, not a launch: deploy-train.sh is already running and sleeping, so
    # the only thing it can be told is "stop sleeping". Unconditional and
    # uncooled — a one-shot the train consumes, so a stale one costs the next
    # train exactly one early curl.
    mkdir -p "$H/state" 2>/dev/null
    printf '%s\n' "$sha" > "$H/state/deploy-wake-$p" 2>/dev/null || true
    # remote_launch owns the placement: it resolves the box with box-for.sh,
    # runs the lane here when the box is `local` or this box's own crontab
    # already drives it (migration-autopilot, cron/lanes/430 on the hub), ssh's
    # to the owner otherwise (apply-migrations, which needs the box's own
    # /root/repos/<p> and env), and fails CLOSED with a log line for a project
    # fleet.conf cannot place. Same idiom as the push class — never re-derive
    # box/lane_runs_here here.
    cooled migration-autopilot "$p" 120 && remote_launch "migration-autopilot[$p]" "$p" migration-autopilot.sh "$p" || true
    cooled apply-migrations    "$p" 120 && remote_launch "apply-migrations[$p]"    "$p" apply-migrations.sh    "$p" || true
  done
  # drain() calls EVERY armed class's dispatch on every non-empty poll, so a
  # list that survives its own dispatch re-fires every stale project forever.
  WC_DEPLOY_PROJECTS=""
  WC_DEPLOY_SHA=()
  return 0
}
