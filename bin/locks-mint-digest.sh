#!/bin/bash
# bin/locks-mint-digest.sh — hub cron (daily). Deterministic visibility on the
# lock service's token activity (minter lane, 2026-08-21): if any token was
# minted or revoked in the last 24h, beat ONE consolidated line to the operator.
# Delegated minting (partner-minter-*) without a digest would be invisible
# credential sprawl; with it, the operator reads one Telegram line a day at most.
set -uo pipefail
H=/root/harness
. "${HARNESS:-/root/harness}/bin/lib/env-path.sh" 2>/dev/null || . "$(dirname "${BASH_SOURCE[0]}")/lib/env-path.sh" 2>/dev/null || harness_env_dir() { printf '%s\n' "${1:-${HARNESS:-/root/harness}}/env"; }; HENV=$(harness_env_dir "$H")
set -a; . "$HENV/global.env" 2>/dev/null; set +a

# >>> lane gate (BH-1165) — one off-switch and one source of numbers for this
# lane. lane_gate_or_exit exits 0 when flags/all-off, flags/lane-off-locks-mint-digest
# (or a pause_flags row driving either) is set; lane_env_apply then puts this
# lane's settings rows into the environment its own ${KNOB:-default} reads use.
# Both fail OPEN: an unreachable worker leaves the lane exactly as it is today.
# Registry: catalog/lanes.json. Operator: bin/harness-ctl.sh off locks-mint-digest.
# shellcheck disable=SC1091
. "${HARNESS:-/root/harness}/bin/lib/lane-gate.sh" 2>/dev/null || true
command -v lane_gate_or_exit >/dev/null 2>&1 && lane_gate_or_exit locks-mint-digest
command -v lane_env_apply    >/dev/null 2>&1 && lane_env_apply    locks-mint-digest
[ -n "${LOCKS_ADMIN_TOKEN:-}" ] || exit 0
# BH-4080: the fallback worker host is built from HARNESS_WORKERS_SUBDOMAIN.
# shellcheck source=bin/lib/deployment.sh
. "${HARNESS_DEPLOYMENT_FILE-$(dirname "${BASH_SOURCE[0]}")/lib/deployment.sh}" || exit 1
B="${LOCKS_URL:-https://harness-locks.$HARNESS_WORKERS_SUBDOMAIN.workers.dev}"
STAMP() { date -u '+%Y-%m-%d %H:%M:%SZ'; }

T=$(mktemp); trap 'rm -f "$T"' EXIT
curl -s -m 20 -o "$T" -H "Authorization: Bearer $LOCKS_ADMIN_TOKEN" "$B/v1/admin/log?since=$(( $(date +%s) - 86400 ))" || exit 0
LINES=$(python3 - "$T" <<'PYEOF'
import json, sys, datetime
try:
    d = json.load(open(sys.argv[1]))
except Exception:
    raise SystemExit
rows = [r for r in d.get("log", []) if r.get("action") in ("token-mint", "token-revoke")]
for r in rows:
    ts = datetime.datetime.fromtimestamp(r["at"], datetime.timezone.utc).strftime("%H:%MZ")
    print(f'{ts} {r["action"].replace("token-","")} {r["key"]} by {r["holder"]}')
PYEOF
)
[ -n "$LINES" ] || exit 0
N=$(grep -c . <<<"$LINES")
"$H/bin/beat.sh" "$(jq -nc --arg akey "locks-mint-digest:$(date -u +%Y%m%d)" \
  --arg l "lock-service token activity (24h, $N event(s)): $(tr '\n' '; ' <<<"$LINES" | head -c 800)" \
  '{kind:"fleet_alert",project:"fleet",akey:$akey,line:$l}')" >/dev/null 2>&1 || true
echo "$(STAMP) digest sent: $N event(s)" >> "$H/logs/locks-mint-digest.log"
