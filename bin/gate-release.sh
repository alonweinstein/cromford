#!/bin/bash
# bin/gate-release.sh <project> — BH-3825: release work gated on another
# ticket's merge. Called from rt_gate (bin/lib/rt/gate.sh) on every triage
# tick, before the cost gate: free, deterministic, no model call.
#
# Thin on purpose. The contract is bin/lib/gate-release.sh; the work functions
# gr_release_queue and gr_reoffer_scan come from its part files under
# bin/lib/gate-release/ and are called only when defined. With no part files
# this exits 0 having done nothing.
#
# Kill switch gate-release-off (lane_switch): on = exit 0 before anything else
# is read. The hub runs no gate-release (bin/lib/hub-box.sh). One summary line
# on stdout, only when a work function reported an action. Always exit 0.
set -uo pipefail
P="${1:-}"
[ -n "$P" ] || exit 0
H="${HARNESS:-/root/harness}"
export HARNESS="$H"

. "$H/bin/lib/env-path.sh" 2>/dev/null || harness_env_dir() { printf '%s\n' "${1:-$H}/env"; }
HENV=$(harness_env_dir "$H")
set -a; . "$HENV/global.env" 2>/dev/null; set +a

# shellcheck source=bin/lib/lane-switch.sh
. "$H/bin/lib/lane-switch.sh" 2>/dev/null || lane_switch() { [ -f "$H/flags/$1" ]; }
lane_switch gate-release-off file && exit 0

# shellcheck source=bin/lib/hub-box.sh
. "$H/bin/lib/hub-box.sh" 2>/dev/null || exit 0
is_hub_box "$(local_box_name)" && exit 0

# shellcheck source=bin/lib/gate-release.sh
. "$H/bin/lib/gate-release.sh" 2>/dev/null || exit 0
# jobs-client.sh exits its caller on a missing module, so it is probed in a
# subshell first; without it the ledger tier of gr_key_merged is skipped.
if ( . "$H/bin/jobs-client.sh" ) >/dev/null 2>&1; then
  # shellcheck source=bin/jobs-client.sh
  . "$H/bin/jobs-client.sh" >/dev/null 2>&1
fi

out=""
for fn in gr_release_queue gr_reoffer_scan; do
  declare -F "$fn" >/dev/null 2>&1 || continue
  out+=$("$fn" "$H" "$P" 2>/dev/null || true)$'\n'
done
n=$(printf '%s' "$out" | grep -c .)
[ "$n" -gt 0 ] 2>/dev/null && printf 'gate-release %s: %s action(s)\n' "$P" "$n"
exit 0
