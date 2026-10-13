#!/bin/bash
# Untriaged-ticket sweep (the operator request, 2026-07-29, after the project-2 thinking-param
# outage): app-side triage can fail SILENTLY (budget cap Jul 24, API 400 Jul 29),
# and box watchers' no-change gates skip their own 1h null-verdict check. This
# hub-side sweep asks each board directly: any client-filed ticket >1h old with
# no triage verdict? One beat + one ALERTS line per ticket, ever (state-deduped).
# Cron: */30 on the hub.
set -uo pipefail
# HARNESS is overridable for the same reason bin/fly-pool-tick.sh took that
# seam: a suite that cannot point this lane at a scratch tree cannot drive the
# SHIPPED script at all, and tests/untriaged-sweep-gate-test.sh is what proves
# a stopped switch really stops all four board sweeps. Cron sets it nowhere, so
# the hub resolves the same /root/harness it always did.
H="${HARNESS:-/root/harness}"
. "${HARNESS:-/root/harness}/bin/lib/env-path.sh" 2>/dev/null || . "$(dirname "${BASH_SOURCE[0]}")/lib/env-path.sh" 2>/dev/null || harness_env_dir() { printf '%s\n' "${1:-${HARNESS:-/root/harness}}/env"; }; HENV=$(harness_env_dir "$H")
STATE=$H/state/untriaged-alerted.txt; touch "$STATE"
STAMP() { date -u '+%Y-%m-%d %H:%M:%SZ'; }
sweep() { # project base token prefix — the read is bin/lib/untriaged-board-read.sh
  local P=$1 BASE=$2 TOK=$3 PFX=$4 TICKETS
  TICKETS=$(ut_inapp_untriaged "$P" "$BASE" "$TOK" "$PFX" 3600) || return 0
  [ -n "$TICKETS" ] || return 0
  while IFS=$'\t' read -r TID NUM _TS TITLE; do
    [ -n "$TID" ] || continue
    grep -q "^$P:$TID$" "$STATE" && continue
    echo "$(STAMP) [$P] ticket #$NUM untriaged >1h (app triage may be silently failing): $TITLE" >> "$H/logs/ALERTS.log"
    "$H/bin/beat.sh" "$(jq -nc --arg p "$P" --arg akey "untriaged:$P:$TID" \
      --arg l "UNTRIAGED >1h: $P #$NUM — $TITLE. App triage may be silently failing; check runtime logs / re-trigger." \
      '{kind:"fleet_alert",project:$p,akey:$akey,line:$l}')" >/dev/null 2>&1
    echo "$P:$TID" >> "$STATE"
  done <<< "$TICKETS"
}

# EVERY ENV FILE FIRST, THEN THE GATE, THEN THE FOUR SWEEPS (BH-1165 review).
# The four env files were interleaved with the sweeps and the gate header sat
# after the third of them, so `harness-ctl all-off` stopped a QUARTER of this
# lane: the hub still curled project-1, project-2 and project-3 with each client's
# internal API token, wrote their ALERTS lines and beat for them, and only then
# logged `untriaged-sweep SKIPPED`. The four files set disjoint, project-
# prefixed names (PROJECT_1_*, PROJECT_2_*, PROJECT_3_*, PROJECT_4_*), so loading them together
# hands each sweep exactly the values it had before.
set -a; . "$HENV/global.env" 2>/dev/null; set +a
set -a; . "$HENV/project-1.env" 2>/dev/null; set +a
set -a; . "$HENV/project-2.env" 2>/dev/null; set +a
set -a; . "$HENV/project-3.env" 2>/dev/null; set +a
set -a; . "$HENV/project-4.env" 2>/dev/null; set +a

# >>> lane gate (BH-1165) — one off-switch and one source of numbers for this
# lane. lane_gate_or_exit exits 0 when flags/all-off, flags/lane-off-untriaged-sweep
# (or a pause_flags row driving either) is set; lane_env_apply then puts this
# lane's settings rows into the environment its own ${KNOB:-default} reads use.
# Both fail OPEN: an unreachable worker leaves the lane exactly as it is today.
# It sits BELOW the env load (lane_env_apply's row would otherwise lose to
# global.env) and ABOVE every sweep (a stop must stop all four boards):
# sections 16 and 19 of tests/lanes-registry-test.sh hold both ends.
# Registry: catalog/lanes.json. Operator: bin/harness-ctl.sh off untriaged-sweep.
# shellcheck disable=SC1091
. "${HARNESS:-/root/harness}/bin/lib/lane-gate.sh" 2>/dev/null || true
command -v lane_gate_or_exit >/dev/null 2>&1 && lane_gate_or_exit untriaged-sweep
command -v lane_env_apply    >/dev/null 2>&1 && lane_env_apply    untriaged-sweep

# The board read (BH-2756), shared with bin/untriaged-digest.sh. Below the gate
# so a stopped switch stops before anything else loads.
# shellcheck source=bin/lib/untriaged-board-read.sh
. "${HARNESS:-/root/harness}/bin/lib/untriaged-board-read.sh" 2>/dev/null || . "$(dirname "${BASH_SOURCE[0]}")/lib/untriaged-board-read.sh" 2>/dev/null \
  || { echo "$(STAMP) [untriaged-sweep] cannot load bin/lib/untriaged-board-read.sh, no board swept" >> "$H/logs/ALERTS.log"; exit 0; }

sweep project-1   "$PROJECT_1_API_BASE" "$PROJECT_1_INTERNAL_API_TOKEN" /api/board
sweep project-2 "$PROJECT_2_APP_BASE"       "$PROJECT_2_INTERNAL_API_TOKEN"       /api/board
sweep project-3       "$PROJECT_3_APP_BASE"     "$PROJECT_3_INTERNAL_API_TOKEN"     /api/feature-board
sweep project-4       "$PROJECT_4_API_BASE"     "$PROJECT_4_INTERNAL_API_TOKEN"     /api/accounting/requests-board
exit 0
