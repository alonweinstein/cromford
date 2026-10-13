#!/bin/bash
# SCALE-PLAN wave 5 — cap-loss detector. Daily HUB cron: measures how much
# time each box lost yesterday to claude cap/limit failures (failovers +
# STUCK), and when any box crosses 2h/day (the operator's threshold, 2026-07-28)
# beats the economics: stock a discounted usage BUNDLE first (10-30% below
# API rates per support docs, 2026-07-28), API-key flip as the operational
# fallback. Detection only — the flip/purchase stays human.
#
# THE MEASURE IS cost_rows FIELDS (BH-2527). No box is scp'd for its
# failovers.log or cost.csv any more: the day's rows come from the harness-jobs
# cost_rows table (bin/lib/cost-rows-read.sh), grouped by their `host` column.
# A failover is a claude row that failed (runner=claude, rc not 0) — the event
# that sends a call down the ladder; deferred time is the duration of the rows a
# fallback runner served. When the table cannot be read the day is logged as
# NOT measured and ALERTed — never "0 failovers".
set -uo pipefail
HARNESS="${HARNESS:-/root/harness}"
. "${HARNESS:-/root/harness}/bin/lib/env-path.sh" 2>/dev/null || . "$(dirname "${BASH_SOURCE[0]}")/lib/env-path.sh" 2>/dev/null || harness_env_dir() { printf '%s\n' "${1:-${HARNESS:-/root/harness}}/env"; }; HENV=$(harness_env_dir "$HARNESS")
set -a; . "$HENV/global.env" 2>/dev/null; set +a

# >>> lane gate (BH-1165) — one off-switch and one source of numbers for this
# lane. lane_gate_or_exit exits 0 when flags/all-off, flags/lane-off-cap-loss-detector
# (or a pause_flags row driving either) is set; lane_env_apply then puts this
# lane's settings rows into the environment its own ${KNOB:-default} reads use.
# Both fail OPEN: an unreachable worker leaves the lane exactly as it is today.
# Registry: catalog/lanes.json. Operator: bin/harness-ctl.sh off cap-loss-detector.
# shellcheck disable=SC1091
. "${HARNESS:-/root/harness}/bin/lib/lane-gate.sh" 2>/dev/null || true
command -v lane_gate_or_exit >/dev/null 2>&1 && lane_gate_or_exit cap-loss-detector
command -v lane_env_apply    >/dev/null 2>&1 && lane_env_apply    cap-loss-detector
LOG="$HARNESS/logs/cap-loss.log"
DAY=$(date -u -d yesterday '+%Y-%m-%d')
TMP=$(mktemp -d)

for _P in "$(dirname "${BASH_SOURCE[0]}")/lib/cost-rows-read.sh" "$HARNESS/bin/lib/cost-rows-read.sh"; do
  # shellcheck source=/dev/null
  [ -r "$_P" ] && { . "$_P"; break; }
done
if ! command -v cost_rows_fetch >/dev/null 2>&1 \
   || ! cost_rows_fetch "$TMP/rows.csv" "${DAY}T00:00:00Z" "${DAY}T23:59:59Z"; then
  rm -rf "$TMP"
  echo "$(date -u '+%F %T')Z $DAY :: cost_rows unreadable — cap-loss NOT measured" >> "$LOG"
  echo "$(date -u '+%F %T')Z [cap-loss-detector] cap-loss for $DAY was NOT measured: the cost_rows table could not be read (reason in logs/agent-rules.log [cost-rows-read]). No box is known to be under the 2h/day threshold; re-run bin/cap-loss-detector.sh once the harness-jobs worker answers." >> "$HARNESS/logs/ALERTS.log"
  exit 0
fi

SUMMARY=$(python3 - "$TMP/rows.csv" "$DAY" <<'EOF'
import csv, sys
path, day = sys.argv[1], sys.argv[2]
fails, secs = {}, {}
for r in csv.DictReader(open(path, errors="replace")):
    if (r.get("ts") or "")[:10] != day:
        continue
    host = (r.get("host") or "").strip() or "unknown"
    fails.setdefault(host, 0); secs.setdefault(host, 0.0)
    if r.get("runner") == "claude":
        if (r.get("rc") or "") not in ("", "0"):
            fails[host] += 1
    else:
        # deferred time ~= duration of the runs a fallback runner served
        try: secs[host] += float(r.get("duration_s") or 0)
        except ValueError: pass
out = [(h, fails[h], secs[h] / 3600) for h in sorted(fails)]
lines = [f"{b}: {n} failovers, {h:.1f}h deferred" for b, n, h in out]
worst = [b for b, n, h in out if h > 2.0]
print("|".join([";".join(lines), ",".join(worst)]))
EOF
)
rm -rf "$TMP"
LINES="${SUMMARY%%|*}"; WORST="${SUMMARY##*|}"
echo "$(date -u '+%F %T')Z $DAY :: $LINES" >> "$LOG"

if [ -n "$WORST" ]; then
  "$HARNESS/bin/beat.sh" "$(jq -nc --arg akey "caploss:$DAY" \
    --arg l "CAP-LOSS ($DAY): $LINES. Threshold crossed on: $WORST (>2h/day on fallback). Cheapest fix: buy a discounted usage bundle for that account (\$250 bundle = 20% below API rates, \$1000 = 30%); an API-key flip costs MORE per token and is only worth it for org-level billing controls." \
    '{kind:"fleet_alert",project:"",akey:$akey,line:$l}')" >/dev/null 2>&1
fi
exit 0
