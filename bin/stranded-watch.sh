#!/bin/bash
# bin/stranded-watch.sh — BH-5967 part 3: the stranded-ticket watch, one run per
# project on the shared per-project lane runner (bin/lib/project-lanes.sh,
# BH-5913).
#
# WHY. On 2026-10-10, 39 of 95 open cromford tickets had no open PR, no
# blocker, no hold and no build, and nothing re-offered them for hours. The
# triage-tick reconcile (bin/orphan-reconcile.sh) found them every tick and
# launched none: a QUEUED_FLY routing stub held each one as awaiting-closeout.
# That guard is fixed, and this lane is the backstop that runs from the hub
# whatever a project's triage box is doing.
#
# WHAT IT DOES. Cron runs this script. It scans nothing itself: pl_dispatch
# starts `bin/orphan-reconcile.sh --stranded <project>` once per project that is
# not held, each on locks/stranded-watch-<project>.lock, at a stable offset
# inside STRANDED_WATCH_SPREAD_SECS, with the project's own GitHub credential.
# That run is the reconcile's own owner rule with a 60-minute idle window, a
# fresh queue row as its launch, and a re-offer count that writes NEEDS_HUMAN on
# the fourth re-offer in 24 h (the knobs are in catalog/lanes.d/stranded-watch.json).
#
# Off: flags/lane-off-stranded-watch (or the lane's switch row), or
# ORPHAN_RECONCILE=0, which stops the reconcile in both modes.
set -uo pipefail
H="${HARNESS:-/root/harness}"
export HARNESS="$H"
LOG="$H/logs/stranded-watch.log"
mkdir -p "$H/logs" 2>/dev/null
STAMP() { date -u '+%Y-%m-%d %H:%M:%SZ'; }
say() { echo "$(STAMP) [stranded-watch] $*" >> "$LOG"; }

# shellcheck disable=SC1091
. "$H/bin/lib/lane-gate.sh" 2>/dev/null || true
command -v lane_gate_or_exit >/dev/null 2>&1 && lane_gate_or_exit stranded-watch
command -v lane_env_apply    >/dev/null 2>&1 && lane_env_apply    stranded-watch

# shellcheck source=bin/lib/project-lanes.sh
if ! . "$H/bin/lib/project-lanes.sh" 2>/dev/null; then
  say "bin/lib/project-lanes.sh is missing — no project run started"
  exit 1
fi
SPREAD="${STRANDED_WATCH_SPREAD_SECS:-1500}"
case "$SPREAD" in ''|*[!0-9]*) say "STRANDED_WATCH_SPREAD_SECS='$SPREAD' is not a number of seconds — using 1500"; SPREAD=1500 ;; esac
say "$(pl_dispatch stranded-watch "$SPREAD" "$H/bin/orphan-reconcile.sh" --stranded)"
exit 0
