#!/bin/bash
# bin/fly-machine-state.sh <project> <machine-id> — print one pool machine's Fly
# state on stdout (started|stopped|destroyed|purged|...), exit 0. Exit 1 with
# "unknown" when Fly could not be asked or did not answer with a state.
#
# Extracted from bin/pipeline-health.sh 2026-08-25 so the hung-machine
# remediation handler asks the question the SAME way the alert does, rather than
# growing a second, drifting copy. Two facts live here because both were learned
# the hard way:
#   - a machine destroyed hours ago is PURGED from the API, so `machine status`
#     answers "was not found in app" and never state=destroyed (the ghost that
#     paged for a day). Purged is gone too.
#   - the "was not found in app" match is machine-scoped on purpose: an app or
#     token error must fall through to unknown/exit 1 so the caller fails loud.
# Read-only: this script never starts, stops or destroys anything.
set -uo pipefail
H="${HARNESS:-/root/harness}"
. "${HARNESS:-/root/harness}/bin/lib/env-path.sh" 2>/dev/null || . "$(dirname "${BASH_SOURCE[0]}")/lib/env-path.sh" 2>/dev/null || harness_env_dir() { printf '%s\n' "${1:-${HARNESS:-/root/harness}}/env"; }; HENV=$(harness_env_dir "$H")
# shellcheck source=bin/lib/flag-on.sh
. "$H/bin/lib/flag-on.sh" 2>/dev/null || . "$(dirname "${BASH_SOURCE[0]}")/lib/flag-on.sh" 2>/dev/null || flag_on() { [ -f "$H/flags/$1-$2" ]; }
PROJ="${1:?usage: fly-machine-state.sh <project> <machine-id>}"
MID="${2:?usage: fly-machine-state.sh <project> <machine-id>}"

# shellcheck source=bin/jobs-client.sh
[ -r "$H/bin/jobs-client.sh" ] && [ -d "$H/bin/lib/jobs" ] && . "$H/bin/jobs-client.sh" 2>/dev/null
command -v routing_sync_all >/dev/null 2>&1 && { routing_sync_all >/dev/null 2>&1 || true; }
if command -v routing_pool_app >/dev/null 2>&1; then
  APP=$(routing_pool_app "$PROJ" 2>/dev/null) || { echo unknown; exit 1; }
else
  flag_on fly-pool-app "$PROJ" || { echo unknown; exit 1; }
  APP=$(cat "$H/flags/fly-pool-app-$PROJ")
fi
[ -n "$APP" ] || { echo unknown; exit 1; }
TV="FLY_API_TOKEN_$(echo "$PROJ" | tr '[:lower:].-' '[:upper:]__')"
OUT=$( set -a; . "$HENV/fly.env" 2>/dev/null; set +a; \
  FLY_ACCESS_TOKEN="${!TV:-}" PATH="/root/.fly/bin:$PATH" \
  timeout 45 flyctl machine status "$MID" -a "$APP" 2>&1 )
STATE=$(awk -F': *' '/^State:/{print $2}' <<<"$OUT" | tr -d '[:space:]')
case "$OUT" in *"was not found in app"*) STATE=purged ;; esac
[ -n "$STATE" ] || { echo unknown; exit 1; }
echo "$STATE"
