#!/bin/bash
# tests/cache-lane-efficiency-test.sh — the PER-LANE cache-efficiency signal in
# bin/cache-hit-report.sh (P1, headless session profile).
#
# Per stage, over its last CACHE_WRITE_SHARE_CALLS claude cost rows: the share
# of dollars spent on cache WRITES and the cache-read hit ratio, one CSV row per
# stage in logs/cache-lane.csv, and ONE ALERTS line per stage per day when the
# write share exceeds CACHE_WRITE_SHARE_MAX over a full window.
#   1  a write-heavy lane with a full window alerts, once
#   2  a read-heavy lane does not
#   3  a lane with fewer rows than the window is recorded, never alerts
#   4  non-claude rows and rows with no cache counts are not in any window
#   5  a second run the same day does not repeat the alert
#   6  CACHE_WRITE_SHARE_MAX=0 turns the alert off and keeps the CSV
#   7  a cache_ttl=1h row prices its write at the 1h rate (share goes UP)
#   8  the per-PR report still runs when there is no fleet-cost.csv
# Run from anywhere: tests/cache-lane-efficiency-test.sh   (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v python3 >/dev/null 2>&1 || { echo "python3 missing — skipping"; exit 0; }

setup() {
  rm -rf "$T/h"; mkdir -p "$T/h/state/cost" "$T/h/logs" "$T/h/flags" "$T/h/bin"
  cp "$DIR/bin/alert-line.sh" "$DIR/bin/alert_family.py" "$T/h/bin/"
  cat > "$T/h/state/model-prices.json" <<'EOF'
{"per_token":{"claude-opus-5-5":{"prompt":0.000004,"completion":0.00002,"cache_read":2e-7,"cache_write":0.000005}}}
EOF
  local H="ts,host,project,stage,runner,model,rc,duration_s,input_toks,output_toks,cache_read,cache_write,cost_usd,billing_mode,auth_fp,auth_account,session_id,row_source,result_usd,ticket,job_id,pr,run_id,note"
  { echo "$H"
    for i in $(seq -w 1 20); do
      # triage: 100K written, 10K read — the pre-profile shape
      echo "2026-09-24T10:$i:00Z,b,p,triage,claude,claude-opus-5-5,0,9,10,500,10000,100000,,subscription,,,,transcript,,,,,,${NOTE_TRIAGE:-}"
      # review: 5K written, 400K read — a warm prefix
      echo "2026-09-24T10:$i:00Z,b,p,review,claude,claude-opus-5-5,0,9,10,500,400000,5000,,subscription,,,,transcript,,,,,,"
      # grok rows are not claude rows and never enter a window
      echo "2026-09-24T10:$i:00Z,b,p,review,grok,grok-4.6,0,9,10,500,0,900000,5.00,metered,,,,result,,,,,,"
    done
    for i in 1 2 3; do
      echo "2026-09-24T11:0$i:00Z,b,p,execute,claude,claude-opus-5-5,0,9,10,500,10000,100000,,subscription,,,,transcript,,,,,,"
    done
    # a claude row with no cache counts (a codex-backed failover shape)
    echo "2026-09-24T12:00:00Z,b,p,review,claude,claude-opus-5-5,0,9,1000,500,0,0,0.10,subscription,,,,result,,,,,,"
  } > "$T/h/state/cost/fleet-cost.csv"
}
run() { ( cd "$T" && env HARNESS="$T/h" "$@" bash "$DIR/bin/cache-hit-report.sh" >/dev/null 2>&1 ); }
col() { awk -F, -v s="$1" -v c="$2" '$2==s{v=$c} END{print v}' "$T/h/logs/cache-lane.csv" 2>/dev/null; }

# --- 1-4 ---------------------------------------------------------------------
setup; run env
[ -f "$T/h/logs/cache-lane.csv" ] && ok || bad "1 no logs/cache-lane.csv written"
[ "$(grep -c 'lane triage' "$T/h/logs/ALERTS.log" 2>/dev/null)" = 1 ] && ok \
  || bad "1 write-heavy triage should alert once: $(cat "$T/h/logs/ALERTS.log" 2>/dev/null)"
# triage per call: write 100000*5e-6=0.50, total 0.50+10000*2e-7+10*4e-6+500*2e-5=0.51204 -> 0.9765
[ "$(col triage 4)" = 0.9765 ] && ok || bad "1 triage write_share should be 0.9765, got $(col triage 4)"
grep -q 'lane review' "$T/h/logs/ALERTS.log" 2>/dev/null && bad "2 read-heavy review alerted" || ok
[ "$(col review 3)" = 20 ] && ok || bad "4 review window should hold exactly its 20 claude cache rows, got $(col review 3)"
awk -v h="$(col review 5)" 'BEGIN{exit !(h > 0.98)}' && ok || bad "2 review hit ratio should be ~0.99, got $(col review 5)"
[ "$(col execute 3)" = 3 ] && ok || bad "3 execute should be recorded with 3 calls, got $(col execute 3)"
grep -q 'lane execute' "$T/h/logs/ALERTS.log" 2>/dev/null && bad "3 a short window alerted" || ok

# --- 5 -----------------------------------------------------------------------
run env
[ "$(grep -c 'lane triage' "$T/h/logs/ALERTS.log")" = 1 ] && ok || bad "5 the alert repeated on a second run the same day"

# --- 6 -----------------------------------------------------------------------
setup; run env CACHE_WRITE_SHARE_MAX=0
[ -s "$T/h/logs/ALERTS.log" ] && bad "6 CACHE_WRITE_SHARE_MAX=0 still alerted: $(cat "$T/h/logs/ALERTS.log")" || ok
[ -n "$(col triage 4)" ] && ok || bad "6 the CSV must still be written with the alert off"
setup; run env CACHE_WRITE_SHARE_MAX=0.99
[ -s "$T/h/logs/ALERTS.log" ] && bad "6 a 0.99 ceiling alerted on a 0.9765 share" || ok

# --- 7 -----------------------------------------------------------------------
NOTE_TRIAGE="cache_ttl=1h" setup; run env CACHE_WRITE_SHARE_MAX=0
# 1h: write 100000*8e-6=0.80, total 0.81204 -> 0.9852
[ "$(col triage 4)" = 0.9852 ] && ok || bad "7 a cache_ttl=1h row should price its write at 2x prompt (share 0.9852), got $(col triage 4)"

# --- 8 -----------------------------------------------------------------------
setup; rm -f "$T/h/state/cost/fleet-cost.csv"
{ echo 'pr_url,cost_usd,input_toks,output_toks,cache_read,cache_write,stage_breakdown,build_dirs'
  for n in $(seq -w 1 10); do echo "https://example.test/pr/$n,1.00,0,10,100,0,plan:1.00,build-2026082600$n"; done
} > "$T/h/state/cost/cost-per-pr.csv"
run env
[ -s "$T/h/logs/cache-hit.csv" ] && ok || bad "8 the per-PR report stopped running without a fleet-cost.csv"

# --- 9. the alert routes at WARN (digest), never the critical default ---------
# 0.85 sits close to the pre-profile baseline, so this line can fire daily; a
# built-in severity rule in bin/lib/alert-state.sh keeps it off the phone
# without putting an LLM triage lane in its path.
setup; run env
LINE=$(grep 'lane triage' "$T/h/logs/ALERTS.log" | head -1)
SEV=$( HARNESS="$T/h" ALERTS_CONF="$T/no-such-alerts.conf"; . "$DIR/bin/lib/alert-state.sh" || exit 1; alert_state_route "$LINE" "" )
[ -n "$LINE" ] && [ "$SEV" = warn ] && ok || bad "9 the cache-lane alert routes at '$SEV', want warn (line: $LINE)"

# --- 10. a non-integer window is LOGGED and the default used -------------------
setup; run env CACHE_WRITE_SHARE_CALLS=abc
grep -q 'CACHE_WRITE_SHARE_CALLS' "$T/h/logs/cache-hit-report.log" 2>/dev/null \
  && ok || bad "10 a non-integer CACHE_WRITE_SHARE_CALLS was swallowed silently"
[ "$(col triage 3)" = 20 ] && ok || bad "10 the default window of 20 was not used, got $(col triage 3)"

# --- 11. yesterday's alert markers are pruned ---------------------------------
setup; touch "$T/h/flags/alerted-cache-lane-triage-20000101" "$T/h/flags/alerted-other-20000101"
run env
[ -e "$T/h/flags/alerted-cache-lane-triage-20000101" ] && bad "11 an old cache-lane marker was not pruned" || ok
[ -e "$T/h/flags/alerted-other-20000101" ] && ok || bad "11 the prune removed a marker that is not this lane's"

echo "cache-lane-efficiency-test: $PASS pass, $FAIL fail"
[ "$FAIL" -eq 0 ]
