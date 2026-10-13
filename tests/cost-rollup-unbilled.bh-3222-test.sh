#!/bin/bash
# tests/cost-rollup-unbilled.bh-3222-test.sh — BH-3222: a canary row that
# failed and bought nothing (row_source=unbilled, written by agent-call) is not
# an unpriced call. Runs the REAL bin/cost-rollup.sh against a scratch
# logs/cost.csv, the S2/S3 pattern of tests/triage-signal.bh-2604-test.sh.
#
#  U1 one unbilled canary row → fleet_unpriced_calls_24h 0.
#  U2 the same row with row_source=none → 1 (so U1 is the tag, not the shape).
#
# Mutation (run by hand once): drop "unbilled" from the agg() tuple in
# cost-rollup.sh and U1 goes red.
# Run: HARNESS_TEST_SANDBOX=1 bash tests/cost-rollup-unbilled.bh-3222-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

# rollup <row_source> — one rollup over a single dead-login canary row; prints
# fleet_unpriced_calls_24h.
rollup() {
  local C="$T/$1"
  mkdir -p "$C/bin/lib" "$C/logs" "$C/flags" "$C/state/cost"
  cp "$DIR/bin/cost-rollup.sh" "$C/bin/cost-rollup.sh"; chmod +x "$C/bin/cost-rollup.sh"
  cp "$DIR/bin/lib/cost-rows-read.sh" "$C/bin/lib/"
  : > "$C/fleet.conf"
  echo '{"per_token":{"claude-opus-5":{"prompt":0.000005,"completion":0.000025}}}' > "$C/state/model-prices.json"
  printf 'job_ledger_get() { return 2; }\njob_ledger_put() { return 0; }\n' > "$C/bin/jobs-client.sh"
  printf '_jobs_req() { case "$2" in /api/metrics/cost-rows*) echo %s ;; *) return 1 ;; esac; }\n' "'{\"cost_rows\":[]}'" >> "$C/bin/jobs-client.sh"
  local now; now=$(date -u '+%Y-%m-%dT%H:%M:%SZ')
  { echo "ts,host,project,stage,runner,model,rc,duration_s,input_toks,output_toks,cache_read,cache_write,cost_usd,billing_mode,auth_fp,auth_account,session_id,row_source,result_usd,ticket,job_id,pr,run_id,note,lane_id"
    # the row agent-call writes for a dead login's oauth-refresh canary
    echo "$now,hub,fleet,canary,claude,<synthetic>,1,1,,,,,,subscription,login:0123456789ab,unknown,,$1,,,,,,,oauth-refresh"
  } > "$C/logs/cost.csv"
  ( export HARNESS="$C" WINDOWS_ONLY=1 COST_ROLLUP_TIMEBOXED=1
    bash "$C/bin/cost-rollup.sh" >"$T/$1.out" 2>"$T/$1.err" ) || { echo "rc=$?"; return; }
  jq -r '.fleet_unpriced_calls_24h' "$C/state/cost/summary.json" 2>/dev/null
}

U=$(rollup unbilled)
[ "$U" = 0 ] && ok || bad "U1 an unbilled canary row must not count as unpriced (fleet_unpriced_calls_24h=$U) $(tail -3 "$T/unbilled.err")"
U=$(rollup none)
[ "$U" = 1 ] && ok || bad "U2 the same row with row_source=none still counts (fleet_unpriced_calls_24h=$U) $(tail -3 "$T/none.err")"

echo "cost-rollup-unbilled: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
