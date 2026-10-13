#!/bin/bash
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1

ROOT=$(cd "$(dirname "$0")/.." && pwd)
PASS=0 FAIL=0
ok() { PASS=$((PASS+1)); }
bad() { echo "FAIL: $*"; FAIL=$((FAIL+1)); }

mkdir -p "$T/h/state/cost" "$T/h/logs"
cp "$ROOT/bin/cache-hit-report.sh" "$T/cache-hit-report.sh"

{
  echo 'pr_url,cost_usd,input_toks,output_toks,cache_read,cache_write,stage_breakdown,build_dirs'
  for n in $(seq -w 1 10); do
    echo "https://example.test/pr/$n,1.00,0,10,100,0,plan:1.00,build-2026082600$n"
  done
  # These are real token/cost rows from a provider that exposes no cache
  # counters. Before the fix they entered the current window as five cache
  # misses and falsely drove the rate below 90%.
  for n in $(seq -w 11 15); do
    echo "https://example.test/pr/$n,10.00,100,10,0,0,execute:10.00,build-2026082600$n"
  done
} > "$T/h/state/cost/cost-per-pr.csv"

HARNESS="$T/h" bash "$T/cache-hit-report.sh"

line=$(tail -1 "$T/h/logs/cache-hit.csv")
if grep -q ',10,1.0000,-1.0000,' <<<"$line"; then
  ok
else
  bad "zero-cache failover rows polluted the cache window: $line"
fi
if [ ! -s "$T/h/logs/ALERTS.log" ]; then
  ok
else
  bad "a healthy cache window emitted an alert"
fi

echo "$PASS pass, $FAIL fail"
[ "$FAIL" -eq 0 ]
