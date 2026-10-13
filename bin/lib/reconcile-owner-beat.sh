#!/bin/bash
# shellcheck shell=bash
# bin/lib/reconcile-owner-beat.sh — the reconcile-prs owner heartbeat hook
# (BH-1607 contract, BH-1608 body). Sourced, never executed.
#
# bin/reconcile-prs.sh calls rcr_owner_beat once per tick, only on the owner
# box, immediately after it takes the reconcile flock. It must fail open and
# silent: no stdout, no stderr, always rc 0, because a heartbeat that can stop
# a reconcile is worse than no heartbeat. No jobs-client or no JOBS_URL means
# nothing is sent; a non-2xx means nothing was written and the tick goes on.
# bin/jobs-watchdog.sh (bin/lib/reconcile-owner-watch.sh) reads the beat back.
rcr_owner_beat() {
  command -v _jobs_req >/dev/null 2>&1 && [ -n "${JOBS_URL:-}" ] || return 0
  _jobs_req POST /api/reconcile-prs/beat \
    "$(jq -nc --arg b "${JOBS_BOX:-$(hostname)}" '{box:$b}' 2>/dev/null)" >/dev/null 2>&1
  return 0
}
