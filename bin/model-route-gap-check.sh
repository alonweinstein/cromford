#!/bin/bash
# bin/model-route-gap-check.sh — HUB, daily: every (scope, role) in
# `model_routes` starts at rung 0, or ONE ALERTS line per gapped scope per day
# naming the role, the rungs it does have, what it costs and where to repair it.
# Read-only — this lane never writes a route, never deletes a row, and never
# touches anything but its own log and the shared alert reservoir.
#
# THE SILENCE THIS KILLS. A scope whose rows do not start at position 0 is a
# half-written ladder: two writes interleaved on a worker older than #1560's
# whole-scope replace. bin/lib/model-route.sh refuses to promote such a ladder's
# first surviving rung to primary (taking rung 2 as the primary would silently
# run a failover model as the main one), so a PROJECT scope like that falls back
# to the hub ladder and a HUB scope like that is treated as no route at all.
# That rule is right, and it is also what makes the rows INVISIBLE: the resolver
# steps over them, the console shows a ladder nobody resolves, and the operator
# who wrote them has no way to learn they are dead.
#
# AND THE LIB'S OWN ALERT CANNOT COVER IT. model_ladder() does page on this
# shape — but only from inside a resolve, for the one role being resolved, on a
# box that reads the route through this library. A legacy gapped scope is by
# definition one nobody resolves (the worker already resolved past the gap
# before the caller ever saw it), so its runtime branch never fires and the row
# sits there for ever. A detector that can only see the scopes somebody already
# looks at is not a detector. This lane asks the worker for ALL of them.
#
# ONE LINE PER SCOPE PER DAY, and it is the SAME reservoir the library uses:
# _mr_alert_once "<role>-norung0" "<project>" is exactly the key
# bin/lib/model-route.sh's runtime branch writes, so whichever path sees the gap
# first is the one that pages, and the other stays quiet for the rest of the
# UTC day. Two detectors, one line.
#
# usage: model-route-gap-check.sh [--quiet]
#   --quiet   no stdout; the log and the alerts still happen
#
# NO --strict, ON PURPOSE. The cron line is a daily sweep and a detector that
# can fail a tick is a detector people turn off; every path below exits 0.
#
# WHERE THE LINES LAND. ALERTS below resolves this box's alerts file (and makes
# sure its directory is there). The gap lines themselves are written by
# _mr_alert_once under $HARNESS/logs/ALERTS.log — the same file on every real
# box — because sharing the library's writer is what shares its reservoir.
#
# Overrides: none — this lane has no tunable. It reads one endpoint and reports
# what it says.
# Tests only: HARNESS, HARNESS_ALERTS, JOBS_URL.
set -uo pipefail
H="${HARNESS:-/root/harness}"

# >>> lane gate (BH-1165) — one off-switch and one source of numbers for this
# lane. lane_gate_or_exit exits 0 when flags/all-off, flags/lane-off-model-route-gap-check
# (or a pause_flags row driving either) is set; lane_env_apply then puts this
# lane's settings rows into the environment its own ${KNOB:-default} reads use.
# Both fail OPEN: an unreachable worker leaves the lane exactly as it is today.
# Registry: catalog/lanes.json. Operator: bin/harness-ctl.sh off model-route-gap-check.
# shellcheck disable=SC1091
. "${HARNESS:-/root/harness}/bin/lib/lane-gate.sh" 2>/dev/null || true
command -v lane_gate_or_exit >/dev/null 2>&1 && lane_gate_or_exit model-route-gap-check
command -v lane_env_apply    >/dev/null 2>&1 && lane_env_apply    model-route-gap-check
HERE="$(cd "$(dirname "$0")" && pwd)"
ALERTS="${HARNESS_ALERTS:-$H/logs/ALERTS.log}"
LOG="$H/logs/model-route-gap-check.log"
STAMP() { date -u '+%Y-%m-%d %H:%M:%SZ'; }
mkdir -p "$H/logs" "$H/flags" "$(dirname "$ALERTS")" 2>/dev/null

QUIET=0
while [ $# -gt 0 ]; do
  case "$1" in
    --quiet) QUIET=1; shift ;;
    *) echo "usage: model-route-gap-check.sh [--quiet]" >&2; exit 2 ;;
  esac
done
say() { [ "$QUIET" = 1 ] || printf '%s\n' "$*"; }

# The transport is bin/jobs-client.sh's (_jobs_req), and the alert writer is
# bin/lib/model-route.sh's (_mr_alert_once). Both are resolved off THIS script's
# directory rather than off $HARNESS, the idiom bin/doorbell-coverage-check.sh
# uses, so a copy of bin/ in a scratch tree finds its own libraries.
#
# ORDER MATTERS: the client first, so model-route.sh's guarded bootstrap finds
# _jobs_req already defined and does not source a second copy.
# shellcheck source=/dev/null
[ -r "$HERE/jobs-client.sh" ] && . "$HERE/jobs-client.sh" >/dev/null 2>&1
# shellcheck source=bin/lib/model-route.sh
[ -r "$HERE/lib/model-route.sh" ] && . "$HERE/lib/model-route.sh" 2>/dev/null

RESP=$(_jobs_req GET /api/model-routes); RC=$?
if [ "$RC" -ne 0 ]; then
  # NO ALERTS LINE FROM HERE. bin/lib/jobs/req.sh already pages a worker outage
  # once a day, and a detector that pages on its own transport turns one outage
  # into two lines in a channel whose whole contract is one actionable line per
  # thing per day. The log says it, and the next tick checks again.
  echo "$(STAMP) worker unreachable (GET /api/model-routes rc=$RC) — no scope was checked this tick; bin/jobs-client.sh's own daily reservoir carries the outage" >> "$LOG"
  say "worker unreachable (rc=$RC) — nothing checked"
  exit 0
fi

# The role count is the response's own, so "checked" means what the worker
# actually answered for and not what this box hoped it would. A malformed or
# missing `roles` is 0, never an empty string in the summary line.
SEEN=$(printf '%s' "$RESP" | jq -r '(.roles // []) | length' 2>/dev/null)
case "$SEEN" in ''|*[!0-9]*) SEEN=0 ;; esac

# NO FIELD IS EVER EMPTY ON THE WIRE, and that is not cosmetic: a TAB is IFS
# whitespace, so `IFS=$'\t' read` strips a LEADING empty field and collapses two
# adjacent tabs into one delimiter. A hub gap (project null) would arrive as
# role-in-PROJECT, positions-in-ROLE and page for a role that does not exist.
# So the worker's null project rides as `-`, the placeholder this fleet already
# uses for "no project" (lane_project_held, the doorbell's RING_LAST), and it is
# turned back into the empty string the library's key wants, below.
GAPPED=0
while IFS=$'\t' read -r PROJECT ROLE POSITIONS; do
  [ -n "$ROLE" ] || continue
  case "$PROJECT" in -) PROJECT="" ;; esac
  [ -n "$POSITIONS" ] || POSITIONS="unknown"
  GAPPED=$((GAPPED+1))
  if [ -n "$PROJECT" ]; then
    MSG="model route for role '$ROLE' (project=$PROJECT) has rows at rung(s) $POSITIONS and none at rung 0, so every resolver ignores it: $PROJECT falls back to the hub ladder. Repair it in Mission Control /models/$ROLE?project=$PROJECT — RESET TO HUB drops the orphan rows, SAVE LADDER replaces the whole scope."
    say "$ROLE (project=$PROJECT): rungs $POSITIONS, no rung 0 — ignored, falls back to the hub ladder"
  else
    MSG="model route for role '$ROLE' (hub scope) has rows at rung(s) $POSITIONS and none at rung 0, so every resolver ignores it: the role has no route at all and a caller fails closed (rc 75). Repair it in Mission Control /models/$ROLE — SAVE LADDER replaces the whole scope."
    say "$ROLE (hub): rungs $POSITIONS, no rung 0 — the role has no route at all"
  fi
  # The library's key, deliberately: "<role>-norung0" + project is what
  # model_ladder() passes, so the two paths share one line per scope per day.
  _mr_alert_once "$ROLE-norung0" "$PROJECT" "$MSG"
done < <(printf '%s' "$RESP" | jq -r '.gaps[]? | [(.project // "-"), .role, ((.positions // []) | join(","))] | @tsv' 2>/dev/null)

echo "$(STAMP) checked=$SEEN gapped=$GAPPED" >> "$LOG"
say "checked=$SEEN gapped=$GAPPED"
exit 0
