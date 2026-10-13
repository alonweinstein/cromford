#!/bin/bash
# bin/security-scan.sh <project> — weekly deep security audit via OpenAI
# codex-security (the operator, 2026-08-03). $20 cap per scan ("I want completeness").
# Complements semgrep (per-PR, free): this is the scheduled audit lane.
# New HIGH/CRITICAL findings -> ALERTS + beat; full export saved for triage.
# Auth: the box's codex credentials (~/.codex/auth.json). Lifecycle tracking is
# codex-security's own (new/persisting/reopened/resolved across scans).
set -uo pipefail
HARNESS=/root/harness
. "${HARNESS:-/root/harness}/bin/lib/env-path.sh" 2>/dev/null || . "$(dirname "${BASH_SOURCE[0]}")/lib/env-path.sh" 2>/dev/null || harness_env_dir() { printf '%s\n' "${1:-${HARNESS:-/root/harness}}/env"; }; HENV=$(harness_env_dir "$HARNESS")
PROJECT="${1:?project}"
REPO="/root/repos/$PROJECT"
[ -d "$REPO" ] || exit 0
set -a; . "$HENV/global.env" 2>/dev/null; set +a

# >>> lane gate (BH-1165) — one off-switch and one source of numbers for this
# lane. lane_gate_or_exit exits 0 when flags/all-off, flags/lane-off-security-scan
# (or its project row) is set; lane_env_apply then puts this
# lane's settings rows into the environment its own ${KNOB:-default} reads use.
# Both fail OPEN: an unreachable worker leaves the lane exactly as it is today.
# Registry: catalog/lanes.json. Operator: bin/harness-ctl.sh off security-scan <project>.
# shellcheck disable=SC1091
. "${HARNESS:-/root/harness}/bin/lib/lane-gate.sh" 2>/dev/null || true
command -v lane_gate_or_exit >/dev/null 2>&1 && lane_gate_or_exit security-scan "$PROJECT"
command -v lane_env_apply    >/dev/null 2>&1 && lane_env_apply    security-scan "$PROJECT"
STAMP() { date -u '+%Y-%m-%d %H:%M:%SZ'; }
LOG="$HARNESS/logs/security-scan.log"
OUTDIR="$HARNESS/state/security-scans/$PROJECT"; mkdir -p "$OUTDIR"

cd "$REPO"
echo "$(STAMP) [$PROJECT] codex-security scan starting (cap \$20)" >> "$LOG"
timeout 7200 npx -y @openai/codex-security@latest scan --max-cost 20.00 >> "$LOG" 2>&1
SCAN=$(timeout 120 npx -y @openai/codex-security@latest scans list --format json 2>/dev/null | jq -r '.[-1]')
COUNT=$(jq -r '.findingCount // 0' <<<"$SCAN")
SID=$(jq -r '.scanId // ""' <<<"$SCAN")
EXPORT="$OUTDIR/$(date -u +%Y%m%d)-findings.json"
[ -n "$SID" ] && timeout 120 npx -y @openai/codex-security@latest export "$SID" --format json > "$EXPORT" 2>/dev/null
HIGHS=$(jq -r '[.[] | select((.severity // "" | ascii_downcase) | test("high|critical"))] | length' "$EXPORT" 2>/dev/null || echo "?")
echo "$(STAMP) [$PROJECT] scan done: findings=$COUNT high/critical=$HIGHS export=$EXPORT" >> "$LOG"
if [ "$HIGHS" != "?" ] && [ "$HIGHS" -gt 0 ]; then
  echo "$(STAMP) [$PROJECT] SECURITY SCAN: $HIGHS high/critical findings — triage $EXPORT" >> "$HARNESS/logs/ALERTS.log"
  "$HARNESS/bin/beat.sh" "$(jq -nc --arg p "$PROJECT" --arg akey "secscan:$PROJECT:$(date -u +%Y%m%d)" \
    --arg l "SECURITY AUDIT: $HIGHS high/critical findings on $PROJECT (weekly codex-security scan) — evidence + proposed patches in $EXPORT; orchestrator will triage into tickets." \
    '{kind:"fleet_alert",project:$p,akey:$akey,line:$l}')" >/dev/null 2>&1
fi
