#!/bin/bash
# alert-warn-flush.sh — cron entry point for the alert-warn-flush lane. EVERY
# box, */30 (cron/lanes/665-alert-warn-flush.cron): drain THIS box's warn spool
# (state/alert-warn-batch.jsonl) into one Telegram message by running
# `bin/alert-digest.sh --warn-batch`, the same command the inline dead-man in
# bin/lib/alert-state.sh runs, under the same spool flock. An empty spool sends
# nothing. Its own file so the registry's one-script-per-lane rule holds
# (tests/lanes-registry-test.sh §4/§5): alert-digest.sh stays the hub-only
# daily digest lane.
#
# OFF-SWITCH CAVEAT: flags/lane-off-alert-warn-flush (or flags/all-off) is also
# honoured by alert-digest.sh --warn-batch itself, so it stops the inline
# dead-man too. While it is set this box delivers NO warn and the spool trims
# oldest-first at ALERT_WARN_BATCH_MAX. docs/ALERTS-STATE-MACHINE.md.
set -uo pipefail
HARNESS="${HARNESS:-/root/harness}"

# >>> lane gate (BH-1165). Operator: bin/harness-ctl.sh off alert-warn-flush.
# shellcheck disable=SC1091
. "${HARNESS:-/root/harness}/bin/lib/lane-gate.sh" 2>/dev/null || true
command -v lane_gate_or_exit >/dev/null 2>&1 && lane_gate_or_exit alert-warn-flush
command -v lane_env_apply    >/dev/null 2>&1 && lane_env_apply    alert-warn-flush

BIN="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)"
[ -n "$BIN" ] || BIN="$HARNESS/bin"
exec "$BIN/alert-digest.sh" --warn-batch
