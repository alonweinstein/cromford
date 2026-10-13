#!/bin/bash
# bin/lib/wake-class-push.sh — BH-1061 push wake class.
# Sourced by bin/wake-loop.sh; defines wc_push_row and wc_push_dispatch.
# Fires only when flags/wake-lanes-push is on (enforced by class_on in the loop).
# shellcheck shell=bash

# Accumulated by wc_push_row, consumed by wc_push_dispatch.
WC_PUSH_PROJECTS=""
WC_PUSH_BH_SHA=""

# prompts_touched <sha> — rc 0 when <sha> in the harness checkout touched prompts/.
# Honest failure: missing checkout or unknown sha logs one line and returns nonzero.
prompts_touched() {
  local sha="${1:-}"
  local checkout="${HARNESS_CHECKOUT:-/root/harness-checkout}"
  if [ ! -d "$checkout/.git" ]; then
    echo "prompts_touched: no checkout at $checkout" >&2
    return 1
  fi
  if [ -z "$sha" ]; then
    echo "prompts_touched: unknown sha ''" >&2
    return 1
  fi
  if ! git -C "$checkout" cat-file -e "$sha^{commit}" 2>/dev/null; then
    # BH-1351: nothing fetches this sha before we are asked about it. A push
    # wake carries the push's own `after` and is drained within seconds, so on
    # the NORMAL path the commit is not in the hub checkout yet and this used to
    # answer "unknown sha" every time — the prompt-eval dispatch was inert.
    # Push wakes are main-only (worker/jobs/src/lib/core.js: "push" ->
    # refs/heads/main), so the sha is reachable at origin. Fetch the SHA
    # ITSELF: that writes objects and FETCH_HEAD only and never moves a
    # remote-tracking ref, so it cannot contend for refs/remotes/origin/main
    # with the fleet-propagate run launched two lines below. Bounded the way
    # fleet-propagate bounds its own fetch of this same checkout.
    timeout 60 git -C "$checkout" fetch -q origin "$sha" 2>/dev/null || true
    # The fetch's own rc is NOT the verdict — this second cat-file is. A sha
    # still missing returns 1 with one line, so a failed fetch never launches
    # the metered prompt-eval lane.
    if ! git -C "$checkout" cat-file -e "$sha^{commit}" 2>/dev/null; then
      echo "prompts_touched: sha '$sha' not local after fetch — prompt-eval not launched" >&2
      return 1
    fi
  fi
  # captured first: grep -qE exits at the first prompts/ path while git is still
  # writing the rest of the name list, and pipefail hands this function git's 141
  # — a prompts/ push then reads as "not a prompts push" (BH-1248).
  grep -qE '^prompts/' <<<"$(git -C "$checkout" diff-tree --no-commit-id --name-only -r "$sha" 2>/dev/null)"
}

# wc_push_row <project> <kind> <key> <event> <repo> <id>
wc_push_row() {
  local project="${1:-}" kind="${2:-}" key="${3:-}"
  [ "$kind" = "push" ] || return 0
  case " $WC_PUSH_PROJECTS " in
    *" $project "*) ;;
    *) WC_PUSH_PROJECTS="${WC_PUSH_PROJECTS:+$WC_PUSH_PROJECTS }$project" ;;
  esac
  [ "$project" = "cromford" ] && WC_PUSH_BH_SHA="$key"
  return 0
}

# wc_push_dispatch — run once per non-empty drain after legacy lanes.
wc_push_dispatch() {
  local p
  local projects="$WC_PUSH_PROJECTS"

  for p in $projects; do
    # remote_launch owns the placement: it resolves the box with box-for.sh,
    # runs the lane here when the box is `local` or this box's own crontab
    # already drives it, ssh's to the owner otherwise, and fails CLOSED with a
    # log line for a project fleet.conf cannot place. Same idiom as the pr-ci
    # class's review-prs dispatch — never re-derive box/lane_runs_here here.
    cooled rebase-train "$p" 300 && remote_launch "rebase-train[$p]" "$p" rebase-train.sh "$p" || true
  done

  if [ -n "$WC_PUSH_BH_SHA" ]; then
    cooled fleet-propagate fleet 60 && launch "push[cromford] fleet-propagate" "$SELF/fleet-propagate.sh" || true
    if prompts_touched "$WC_PUSH_BH_SHA" && cooled prompt-eval cromford "${WAKE_PROMPT_EVAL_COOLDOWN_S:-86400}"; then
      # --cron alone: bin/prompt-eval.sh's cron branch walks PROMPT_EVAL_PROJECTS
      # (or fleet.conf) and returns before it ever reads $PROJECT, so a
      # positional here was dead argv. The weekly cron line in
      # docs/PROMPT-EVALS.md is `prompt-eval.sh --cron` for the same reason.
      launch "push[cromford] prompt-eval" "$SELF/prompt-eval.sh" --cron
    fi
  fi
  WC_PUSH_PROJECTS=""
  WC_PUSH_BH_SHA=""
  return 0
}
