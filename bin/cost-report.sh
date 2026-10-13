#!/bin/bash
# One-shot fleet cost report (scheduled for Aug 3 per the operator, 2026-07-28).
# Reads the report window from the harness-jobs cost_rows table
# (bin/lib/cost-rows-read.sh — no box is scp'd, BH-2527), computes the
# API-equivalent spend per host/day + cap-failover counts, and beats the
# headline to Telegram. Self-removes from cron after firing. When the table
# cannot be read it exits 75 with no beat and KEEPS its cron line, so a report
# that never read data never unschedules itself.
set -uo pipefail
HARNESS="${HARNESS:-/root/harness}"
. "${HARNESS:-/root/harness}/bin/lib/env-path.sh" 2>/dev/null || . "$(dirname "${BASH_SOURCE[0]}")/lib/env-path.sh" 2>/dev/null || harness_env_dir() { printf '%s\n' "${1:-${HARNESS:-/root/harness}}/env"; }; HENV=$(harness_env_dir "$HARNESS")
set -a; . "$HENV/global.env" 2>/dev/null; set +a
SINCE="2026-07-29"   # start of the clean window (post-buildout, post-cap-fixes)
TMP=$(mktemp -d)

for _P in "$(dirname "${BASH_SOURCE[0]}")/lib/cost-rows-read.sh" "$HARNESS/bin/lib/cost-rows-read.sh"; do
  # shellcheck source=/dev/null
  [ -r "$_P" ] && { . "$_P"; break; }
done
if ! command -v cost_rows_fetch >/dev/null 2>&1 || ! cost_rows_fetch "$TMP/rows.csv" "${SINCE}T00:00:00Z"; then
  rm -rf "$TMP"
  echo "cost-report: cost_rows could not be read (logs/agent-rules.log [cost-rows-read]) — no report, cron line kept" >&2
  exit 75
fi

REPORT=$(python3 - "$TMP/rows.csv" "$SINCE" <<'EOF'
import csv, sys
path, since = sys.argv[1], sys.argv[2]
tot = {}
days = {}
fail = {}
for row in csv.reader(open(path)):
    # ts,host,project,stage,runner,model,rc,duration_s,in,out,cr,cw,cost
    if len(row) < 13 or row[0] == "ts" or row[0][:10] < since: continue
    box = row[1].strip() or "unknown"
    try: c = float(row[12])
    except: c = 0.0
    tot[box] = tot.get(box, 0) + c
    days.setdefault(box, set()).add(row[0][:10])
    if row[4] == "claude" and row[6] not in ("0",""):
        fail[box] = fail.get(box, 0) + 1
lines = []
for box in sorted(tot):
    d = max(len(days.get(box, [])), 1)
    lines.append(f"{box}: ${tot[box]:.0f} total, ${tot[box]/d:.0f}/day over {d}d, {fail.get(box,0)} claude failures")
print("; ".join(lines) if lines else "no cost data in window")
EOF
)

"$HARNESS/bin/beat.sh" "$(jq -nc --arg akey "cost-report-aug3" \
  --arg l "COST REPORT (API-equivalent, since $SINCE): $REPORT. Compare per-box vs \$100-200/mo subscription+extra-usage actuals in the Anthropic dashboards to decide the wave-5 API flip. Ask the orchestrator for the per-stage breakdown." \
  '{kind:"fleet_alert",project:"",akey:$akey,line:$l}')"
rm -rf "$TMP"
(crontab -l | grep -v cost-report.sh) | crontab -
echo "$(date -u '+%F %T')Z cost report fired, cron removed" >> "$HARNESS/logs/cost-report.log"
exit 0
