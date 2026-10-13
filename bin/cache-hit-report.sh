#!/bin/bash
# bin/cache-hit-report.sh — daily cache-hit-rate readout over per-PR cost data.
#
# Why (token-economics research, 2026-08-22): 62% of per-PR build cost is cache
# READS and 19% cache writes — the transcript re-read project-2 dwarfs fresh input.
# Anthropic's own Claude Code team alerts on cache-hit-rate drops; we had no
# measurement at all. A stage-prompt change that breaks prefix stability shows
# up here as cache_write exploding long before anyone reads a bill.
#
# Reads state/cost/cost-per-pr.csv (cost-rollup.sh output; rows carry the build
# dir whose suffix timestamps the PR). Compares the trailing 20 PRs against the
# 20 before them; appends one row/day to logs/cache-hit.csv and ALERTS when the
# trailing hit rate is under 90% or fell more than 3 points vs the prior window.
# Runs on the hub only (cron 05:00, after the 04:45 cost rollup).
set -uo pipefail
H="${HARNESS:-/root/harness}"

# >>> lane gate (BH-1165) — one off-switch and one source of numbers for this
# lane. lane_gate_or_exit exits 0 when flags/all-off, flags/lane-off-cache-hit-report
# (or a pause_flags row driving either) is set; lane_env_apply then puts this
# lane's settings rows into the environment its own ${KNOB:-default} reads use.
# Both fail OPEN: an unreachable worker leaves the lane exactly as it is today.
# Registry: catalog/lanes.json. Operator: bin/harness-ctl.sh off cache-hit-report.
# shellcheck disable=SC1091
. "${HARNESS:-/root/harness}/bin/lib/lane-gate.sh" 2>/dev/null || true
command -v lane_gate_or_exit >/dev/null 2>&1 && lane_gate_or_exit cache-hit-report
command -v lane_env_apply    >/dev/null 2>&1 && lane_env_apply    cache-hit-report
CSV="$H/state/cost/cost-per-pr.csv"
OUT="$H/logs/cache-hit.csv"
STAMP() { date -u '+%Y-%m-%d %H:%M:%SZ'; }
# >>> alert emit cap (BH-2364)
# Every [cache-hit] line goes through bin/alert-line.sh, which notes the alerts
# row at emit time. The per-lane loop fires one per catalog stage (31 today),
# so past ALERT_LINE_TICK_MAX (the alerts conf row, default 20) a tick's
# remaining lines are plain appends, which the poll-commands re-beat notes a
# minute later exactly as it did before. Read in a subshell so
# alert-state.sh's globals stay out of this lane's scope.
ALQ_MAX=$( HARNESS="$H"; . "$H/bin/lib/alert-state.sh" 2>/dev/null; alert_cfg ALERT_LINE_TICK_MAX 20 2>/dev/null )
case "$ALQ_MAX" in ''|*[!0-9]*) ALQ_MAX=20 ;; esac
ALQ_N=0
alert_emit() { # alert_emit <text> — one alert line, through the helper up to the cap
  ALQ_N=$((ALQ_N + 1))
  if [ "$ALQ_N" -le "$ALQ_MAX" ]; then
    HARNESS="$H" "$H/bin/alert-line.sh" "$1"
  else
    # alert-writer overflow (BH-2364): past ALERT_LINE_TICK_MAX this tick the line rides the poll-commands re-beat, as before
    echo "$(STAMP) $1" >> "$H/logs/ALERTS.log"
  fi
}
# <<< alert emit cap

# ── PER-LANE CACHE EFFICIENCY (P1, headless session profile) ─────────────────
# The per-PR window above cannot see WHICH lane broke its prefix, and most lanes
# (triage, review, preplan) never produce a PR at all. This reads the fleet's
# cost rows (state/cost/fleet-cost.csv, written by bin/cost-rollup.sh), takes
# each stage's last CACHE_WRITE_SHARE_CALLS claude rows, and computes:
#   write_share  cache-write dollars / total dollars over those calls. The write
#                is priced at the TTL the row's note says it used (cache_ttl=1h
#                -> the 1h rate; untagged -> the table's 5m rate, which UNDER-
#                states a subscription row, so the share errs low, never high);
#   hit_ratio    cache_read / (cache_read + cache_write + input) tokens.
# One CSV row per stage per run in logs/cache-lane.csv, and ONE ALERTS line per
# stage per UTC day when write_share > CACHE_WRITE_SHARE_MAX over a full window —
# Anthropic runs cache-hit drops as incidents; a lane whose writes dominate is
# re-buying its prefix on every call. Deterministic: no LLM reads anything here.
# CACHE_WRITE_SHARE_MAX=0 turns the alert off; the CSV is still written.
lane_cache_efficiency() {
  local fc="$H/state/cost/fleet-cost.csv" lcsv="$H/logs/cache-lane.csv" out st n ws hr flag
  local llog="$H/logs/cache-hit-report.log" win="${CACHE_WRITE_SHARE_CALLS:-20}" perr
  mkdir -p "$H/logs" "$H/flags" 2>/dev/null
  # Yesterday's once-a-day markers are dead weight: prune everything of THIS
  # lane's family that is not today's.
  find "$H/flags" -maxdepth 1 -type f -name 'alerted-cache-lane-*' ! -name "*-$(date -u +%Y%m%d)" -delete 2>/dev/null
  [ -f "$fc" ] || return 0
  # A window that is not a positive integer is a bad row: said, never swallowed,
  # and the registry default (20) is used rather than skipping the lane.
  case "$win" in ''|*[!0-9]*|0)
    echo "$(STAMP) [cache-hit] CACHE_WRITE_SHARE_CALLS='$win' is not a positive integer — using 20" >> "$llog"
    win=20 ;;
  esac
  local prices=""
  for prices in "$H/state/model-prices.json" /root/harness-checkout/catalog/model-prices.json \
                "$H/catalog/model-prices.json" "$(dirname "$0")/../catalog/model-prices.json"; do
    [ -r "$prices" ] && break
  done
  perr="$H/logs/.cache-lane.err.$$"
  out=$(python3 - "$fc" "$prices" "$win" 2>"$perr" <<'PYEOF'
import csv, json, sys
fc, pp, n = sys.argv[1], sys.argv[2], int(sys.argv[3] or 20)
try:
    prices = json.load(open(pp)).get("per_token", {})
except Exception:
    prices = {}
def f(x):
    try: return float(x or 0)
    except ValueError: return 0.0
by = {}
for r in csv.DictReader(open(fc, errors="ignore")):
    if (r.get("runner") or "") != "claude":
        continue
    if f(r.get("cache_read")) <= 0 and f(r.get("cache_write")) <= 0:
        continue
    by.setdefault(r.get("stage") or "?", []).append(r)
for st, rows in sorted(by.items()):
    rows.sort(key=lambda r: r.get("ts") or "")
    win = rows[-n:]
    wusd = tusd = cr = cw = inp = 0.0
    for r in win:
        p = prices.get(r.get("model") or "") or {}
        rate = p.get("cache_write") or 0
        if ";cache_ttl=1h;" in ";" + (r.get("note") or "") + ";":
            rate = p.get("cache_write_1h") or ((p.get("prompt") or 0) * 2.0) or rate * 1.6
        c = f(r.get("cost_usd"))
        if c <= 0:
            c = (f(r.get("input_toks")) * (p.get("prompt") or 0) + f(r.get("output_toks")) * (p.get("completion") or 0)
                 + f(r.get("cache_read")) * (p.get("cache_read") or 0) + f(r.get("cache_write")) * rate)
        wusd += f(r.get("cache_write")) * rate
        tusd += c
        cr += f(r.get("cache_read")); cw += f(r.get("cache_write")); inp += f(r.get("input_toks"))
    ws = wusd / tusd if tusd > 0 else 0.0
    tot = cr + cw + inp
    hr = cr / tot if tot > 0 else 0.0
    print(f"{st},{len(win)},{min(ws, 1.0):.4f},{hr:.4f},{tusd:.2f}")
PYEOF
)
  local prc=$?
  if [ "$prc" -ne 0 ]; then
    # The reader failing is a fact an operator needs, not a quiet skip.
    echo "$(STAMP) [cache-hit] per-lane reader failed rc=$prc: $(tail -3 "$perr" 2>/dev/null | tr '\n' ' ')" >> "$llog"
    rm -f "$perr"; return 0
  fi
  rm -f "$perr"
  [ -n "$out" ] || return 0
  [ -f "$lcsv" ] || echo "date,stage,calls,write_share,hit_ratio,window_usd" > "$lcsv"
  while IFS=, read -r st n ws hr _usd; do
    [ -n "$st" ] || continue
    echo "$(date -u +%F),$st,$n,$ws,$hr,$_usd" >> "$lcsv"
    [ "$n" -ge "$win" ] 2>/dev/null || continue
    awk -v w="$ws" -v m="${CACHE_WRITE_SHARE_MAX:-0.85}" 'BEGIN{exit !(m+0 > 0 && w+0 > m+0)}' || continue
    flag="$H/flags/alerted-cache-lane-$(printf '%s' "$st" | tr -c 'A-Za-z0-9._-' '_')-$(date -u +%Y%m%d)"
    [ -f "$flag" ] && continue
    mkdir -p "$H/flags" 2>/dev/null
    alert_emit "[cache-hit] lane $st: cache WRITES are $ws of the cost of its last $n claude calls (hit ratio $hr, over CACHE_WRITE_SHARE_MAX ${CACHE_WRITE_SHARE_MAX:-0.85}) — the lane is re-buying its prompt prefix; check a stage-prompt, tool-set, plugin/MCP or TTL change (docs/SESSION-PROFILE.md). Per-lane history: logs/cache-lane.csv"
    touch "$flag" 2>/dev/null
  done <<<"$out"
  return 0
}
lane_cache_efficiency
[ -f "$CSV" ] || exit 0
[ -f "$OUT" ] || echo "date,window_prs,hit_rate,prior_hit_rate,avg_cache_write_k,avg_cost_usd" > "$OUT"

LINE=$(python3 - "$CSV" <<'PYEOF'
import csv, re, sys
rows = list(csv.DictReader(open(sys.argv[1])))
def when(r):
    m = re.search(r'(20[0-9]{10})$', r.get('build_dirs', '') or '')
    return m.group(1) if m else ''
def num(r, key):
    try:
        return float(r.get(key) or 0)
    except (TypeError, ValueError):
        return 0.0
# Codex-backed OpenRouter/Fireworks failovers expose token usage but no cache
# accounting. Their cache_read=cache_write=0 means "not measured", not "cache
# miss". Excluding those rows keeps this signal about prefix-cache stability;
# their tokens and metered dollars remain fully counted by cost-rollup.sh.
rows = [r for r in rows if when(r) and (num(r, 'cache_read') > 0 or num(r, 'cache_write') > 0)]
rows.sort(key=when)
def rate(win):
    cr = sum(float(r['cache_read'] or 0) for r in win)
    cw = sum(float(r['cache_write'] or 0) for r in win)
    inp = sum(float(r['input_toks'] or 0) for r in win)
    tot = cr + cw + inp
    return (cr / tot if tot else 0.0, cw / len(win) / 1e3,
            sum(float(r['cost_usd'] or 0) for r in win) / len(win))
cur = rows[-20:]
prev = rows[-40:-20]
if len(cur) < 5:
    sys.exit(0)
ch, cwk, cavg = rate(cur)
ph = rate(prev)[0] if len(prev) >= 5 else -1
print(f"{len(cur)},{ch:.4f},{ph:.4f},{cwk:.0f},{cavg:.2f}")
PYEOF
) || exit 0
[ -n "$LINE" ] || exit 0

echo "$(date -u +%F),$LINE" >> "$OUT"
IFS=, read -r _N HIT PRIOR _CW _COST <<<"$LINE"
LOW=$(awk -v h="$HIT" -v m="${CACHE_HIT_RATE_MIN:-0.9}" 'BEGIN{print (h < m+0) ? 1 : 0}')
DROP=$(awk -v h="$HIT" -v p="$PRIOR" -v d="${CACHE_HIT_DROP_MAX:-0.03}" 'BEGIN{print (p > 0 && p - h > d+0) ? 1 : 0}')
if [ "$LOW" = 1 ] || [ "$DROP" = 1 ]; then
  alert_emit "[cache-hit] trailing-20-PR cache-hit rate $HIT (prior $PRIOR) — a stage prompt or tool-set change is likely breaking prefix stability; diff recent bin/prompts changes against the window in logs/cache-hit.csv"
fi
exit 0
