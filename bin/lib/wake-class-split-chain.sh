#!/bin/bash
# bin/lib/wake-class-split-chain.sh — BH-1034 wake class `split-chain` (BH-1655).
#
# ARMED BY the class flag `wake-lanes-split-chain` (`bin/jobs-client.sh flag-set
# wake-lanes-split-chain on`), and by nothing else. Without that flag
# bin/wake-loop.sh's CLASS_ON is 0 for this class and neither hook below is
# ever called. flags/wake-lanes-off beats the class flag.
#
# WHAT IT DOES. A split child's PR merging is a push to its repo's main, which
# lands in the D1 `wakes` table whichever lane merged it (tier-1, merge sweep,
# conductor, a hand merge). For an IN-APP board project that push asks the
# owning box to run its own triage tick now, rather than at the next cron tick.
# That tick's gate decides: step 1c of bin/triage-gate.sh answers
# `RUN split-ready` when bin/lib/split-chain.sh finds a sibling due, and
# otherwise the gate's ordinary brakes answer what the cron tick would have. So
# a push that released nothing costs one gate run, not a session.
#
# It does NOT touch state/wake-<p>: that un-brake would pre-empt the gate's own
# brakes and buy a session on every push. GitHub-Issues projects (board_prefix
# `-`) are left to the loop's own push arm and bin/unblocked-children.sh.
#
# SOURCE-TIME RULE. wake-loop.sh sources this file BEFORE it defines cooled(),
# remote_launch() and say(), so nothing here calls them at source time — only
# the dispatch function does, inside drain().
# shellcheck shell=bash

# Accumulator, initialised at source time (the loop runs under `set -u`).
WC_SPLIT_CHAIN_PROJECTS=""

# wc_split_chain_row <project> <kind> <key> <event> <repo> <id>
# Only a push for a project whose board is an in-app board counts.
wc_split_chain_row() {
  local p="${1:-}" kind="${2:-}" bp
  [ "$kind" = push ] && [ -n "$p" ] || return 0
  bp=$("$SELF/fleet-conf.sh" "$p" board_prefix 2>/dev/null) || bp=""
  [ -n "$bp" ] && [ "$bp" != "-" ] || return 0
  case " $WC_SPLIT_CHAIN_PROJECTS " in
    *" $p "*) ;;
    *) WC_SPLIT_CHAIN_PROJECTS="${WC_SPLIT_CHAIN_PROJECTS:+$WC_SPLIT_CHAIN_PROJECTS }$p" ;;
  esac
  return 0
}

# wc_split_chain_dispatch — once per non-empty drain. One owning-box triage
# tick per project, at most once per 120 s; run-triage.sh's own per-project
# flock collapses it into a tick that is already running.
wc_split_chain_dispatch() {
  local p
  for p in $WC_SPLIT_CHAIN_PROJECTS; do
    cooled split-chain "$p" 120 && remote_launch "split-chain[$p]" "$p" run-triage.sh "$p" || true
  done
  WC_SPLIT_CHAIN_PROJECTS=""
  return 0
}
