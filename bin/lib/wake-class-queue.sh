#!/bin/bash
# bin/lib/wake-class-queue.sh — BH-1034 wake class `queue` (BH-4059, slice BH-4169).
#
# ARMED BY the class flag `wake-lanes-queue` (`bin/jobs-client.sh flag-set
# wake-lanes-queue on "<why>"`), and by nothing else. Without that flag
# bin/wake-loop.sh's CLASS_ON is 0 for this class: the hub's claim does not ask
# for `queue` rows and nothing below is called. flags/wake-lanes-off beats the
# class flag. HUB ONLY: the loop adds `queue` to the claim on the hub alone.
#
# WHAT RINGS IT. The worker writes one `queue` wake (repo `harness/build-queue`,
# a synthetic slug no fleet repo can equal) when POST /api/queue lands a
# `queued` fly build. That is the only source. bin/wake-loop.sh hands those rows
# here BEFORE its fleet-repo mapping, which would otherwise drop them as "not a
# fleet repo".
#
# WHAT IT LAUNCHES. bin/fly-dispatch.sh (single-machine projects) and
# bin/fly-pool-tick.sh (pool projects), the two lanes that claim a `target=fly`
# row. Their cron entries are unchanged: a wake only starts them sooner. NOT
# bin/fly-results-ingest.sh: that sweep holds no flock, so a wake-launched copy
# racing its cron copy could ingest one RESULT twice.
#
# WHY NO COOLDOWN ROW. Every other class that spends takes a wake_cooldowns
# row; this one does not need to. The loop is single-copy under its flock, both
# lanes take their own `flock -n`, and both CLAIM the build_queue row (CAS)
# before a machine is spent — so a surplus launch costs one list read, never a
# machine. What bounds it is coalescing (one launch per drain, however many
# wakes) and the per-invocation cap WAKE_QUEUE_PER_TICK (default 1, 0 =
# unlimited, a non-number is 1 with one log line). A launch the cap holds back
# writes state/wake-queue-owed, and the next invocation's first drain pays it,
# even an empty drain (the conductor's owed shape). The marker clears only when
# a lane actually started. The lanes' own cron still covers a held launch.
#
# SOURCE-TIME RULE. wake-loop.sh sources this file BEFORE it defines say() and
# launch(), so nothing here calls them at source time — the cap is validated on
# first use, inside drain().
# shellcheck shell=bash

# Accumulators, initialised at source time (the loop runs under `set -u`).
WC_QUEUE_PENDING=0
WC_QUEUE_LAUNCHED=0
WC_QUEUE_HELD=0
WC_QUEUE_CAP=""

# wc_queue_cap — sets WC_QUEUE_CAP, the per-invocation cap, validated once per
# invocation (never call it in a subshell, or the "once" is lost). A typo is
# not a cap of zero (which means unlimited): it is the default 1, said once.
wc_queue_cap() {
  [ -z "$WC_QUEUE_CAP" ] || return 0
  WC_QUEUE_CAP="${WAKE_QUEUE_PER_TICK:-1}"
  case "$WC_QUEUE_CAP" in
    ''|*[!0-9]*) say "WAKE_QUEUE_PER_TICK='$WC_QUEUE_CAP' is not a number — using 1"; WC_QUEUE_CAP=1 ;;
  esac
}

# wc_queue_row <project> <kind> <key> <event> <repo> <id>
# The loop's generic hook calls this for every fleet row of every kind, so the
# kind is checked here; the loop's own `queue)` arm is what hands over a queue row.
wc_queue_row() {
  [ "${2:-}" = queue ] || return 0
  WC_QUEUE_PENDING=$((WC_QUEUE_PENDING+1))
  return 0
}

# wc_queue_fire <why> — one launch of each fly lane, inside the cap; over it,
# the owed marker and one held line per invocation. The debt clears only when
# a lane actually started.
wc_queue_fire() {
  local why="${1:-}" owed="$H/state/wake-queue-owed" n=0
  [ "$IS_HUB" = 1 ] || return 0
  wc_queue_cap
  if [ "$WC_QUEUE_CAP" != 0 ] && [ "$WC_QUEUE_LAUNCHED" -ge "$WC_QUEUE_CAP" ]; then
    touch "$owed" 2>/dev/null || say "queue: owed marker write failed — the cron covers it"
    if [ "$WC_QUEUE_HELD" = 0 ]; then
      say "queue: fly launch held — per-tick cap $WC_QUEUE_CAP reached (owed; the cron still covers it)"
      WC_QUEUE_HELD=1
    fi
    return 0
  fi
  WC_QUEUE_LAUNCHED=$((WC_QUEUE_LAUNCHED+1))
  launch "queue[fleet] ($why)" "$SELF/fly-dispatch.sh" && n=$((n+1))
  launch "queue[fleet] ($why)" "$SELF/fly-pool-tick.sh" && n=$((n+1))
  if [ "$n" -gt 0 ]; then rm -f "$owed"; else touch "$owed" 2>/dev/null || true; fi
  return 0
}

# wc_queue_dispatch — once per non-empty drain: the drain's queue wakes become
# ONE launch, then the accumulator resets.
wc_queue_dispatch() {
  local n="$WC_QUEUE_PENDING"
  WC_QUEUE_PENDING=0
  [ "$n" -gt 0 ] || return 0
  wc_queue_fire "$n wake(s)"
}

# wc_queue_owed_pay — every drain, empty or not, right after the conductor's
# own owed pay: a launch an earlier invocation held is paid, inside the cap.
wc_queue_owed_pay() {
  [ -e "$H/state/wake-queue-owed" ] || return 0
  wc_queue_fire owed
}
