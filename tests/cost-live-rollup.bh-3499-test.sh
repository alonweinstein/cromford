#!/bin/bash
# tests/cost-live-rollup.bh-3499-test.sh — COST-ROLLUP CARRIES A `live` BLOCK
# (BH-3499, BH-3481.2).
#
# bin/cost-rollup.sh reads GET /api/cost/live?hours=24 and writes an additive
# `live` object into state/cost/summary.json. A read that fails, 404s, or
# answers the wrong shape writes {"unreadable": true} and no numbers at all,
# plus one agent-rules.log line: unknown must never read as zero. The final-row
# CSVs never change because of it.
#
# Runs the REAL bin/cost-rollup.sh (WINDOWS_ONLY=1) in a scratch $HARNESS with
# the real libs. Stubs are the edges only: bin/jobs-client.sh's _jobs_req
# answers /api/metrics/cost-rows from a fixture and /api/cost/live per case
# ($FIX/live.mode), and gh/curl/ssh on PATH fail.
#
#   R1 a good answer -> .live carries the numbers, the row COUNT and as_of,
#      and the request path was /api/cost/live?hours=24
#   R2 rc 1 / JOBS_HTTP=500 -> .live == {"unreadable":true}, no numbers,
#      exactly one "/api/cost/live unreadable" log line
#   R3 a wrong-shape body, and rc 2 (404) -> unreadable
#   R4 fleet-cost.csv and cost-per-pr.csv are byte-identical between R1 and
#      R2, and so is summary.json minus .live and generated_at
#   R5 the route the rollup reads (worker/jobs/src/routes/cost-live.js): its
#      node suite, run through the real worker.fetch, when node is here. It
#      renders catalog/lanes.json first: that file is generated and git-ignored,
#      and worker/jobs/src/lib/core.js imports it statically
#
# Run from anywhere: HARNESS_TEST_SANDBOX=1 bash tests/cost-live-rollup.bh-3499-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
"$DIR/bin/llm-sites-build.sh" --compose --repo "$DIR" >/dev/null || { echo "FAIL: cannot compose catalog/llm-sites.json"; exit 1; }

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); printf 'FAIL: %s\n' "$*"; }

NOW=$(date +%s)
NOWTS=$(date -u -d "@$NOW" '+%Y-%m-%dT%H:%M:%SZ')

mkdir -p "$T/fakebin"
printf '#!/bin/bash\nexit 1\n' > "$T/fakebin/ssh"
printf '#!/bin/bash\nexit 1\n' > "$T/fakebin/gh"
printf '#!/bin/bash\nexit 7\n' > "$T/fakebin/curl"
chmod +x "$T/fakebin/ssh" "$T/fakebin/gh" "$T/fakebin/curl"

# setup <name> <live-mode> — a fresh scratch harness; sets H, FIX.
setup() {
  H="$T/$1/h"; FIX="$T/$1/fix"
  mkdir -p "$H/bin/lib" "$H/logs" "$H/builds" "$H/state/cost" "$H/env" "$FIX"
  cp "$DIR/bin/cost-rollup.sh" "$H/bin/cost-rollup.sh"
  cp "$DIR/bin/lib/env-path.sh" "$H/bin/lib/env-path.sh"
  cp "$DIR/bin/lib/builds-of-record.sh" "$H/bin/lib/builds-of-record.sh"
  cp "$DIR/bin/lib/cost-rows-read.sh" "$H/bin/lib/cost-rows-read.sh"
  cat > "$H/bin/jobs-client.sh" <<'JC'
# stub ledger client
job_artifact_feed() { return 0; }
_jobs_req() {
  JOBS_HTTP=""
  case "$2" in
    /api/metrics/cost-rows*) cat "$FIX/cost-rows.json" ;;
    /api/cost/live*)
      printf '%s\n' "$2" >> "$FIX/live.calls"
      case "$(cat "$FIX/live.mode")" in
        good)  JOBS_HTTP=200; cat "$FIX/live.json" ;;
        e500)  JOBS_HTTP=500; return 1 ;;
        e404)  JOBS_HTTP=404; return 2 ;;
        shape) JOBS_HTTP=200; printf '{"oops":1}' ;;
      esac ;;
    *) return 1 ;;
  esac
}
JC
  printf '# project slug\nproject-1 -\n' > "$H/fleet.conf"
  printf '{"ts":"%s","box":"project-1","host":"box","project":"project-1","stage":"execute","runner":"claude","model":"claude-opus-5","rc":0,"duration_s":60,"input_toks":10,"output_toks":20,"cache_read":0,"cache_write":0,"cost_usd":1.25,"billing_mode":"subscription","auth_fp":"fp1","auth_account":"acct","run_id":"project-1-BH-1-x","row_hash":"r1"}\n' "$NOWTS" \
    | jq -sc '{cost_rows: .}' > "$FIX/cost-rows.json"
  jq -nc --arg a "$NOWTS" '{rows:[{session_id:"a"},{session_id:"b"}], in_flight_usd:3.25, unsettled_usd:0.5,
    settled_sessions:0, unpriced_rows:0, truncated:false, as_of:$a}' > "$FIX/live.json"
  printf '%s' "$2" > "$FIX/live.mode"
}

# run — the real script, as the hourly cron runs it, against $H.
run() {
  env PATH="$T/fakebin:$PATH" HARNESS="$H" HARNESS_ENV_DIR="$H/env" FIX="$FIX" \
      COST_ROLLUP_TIMEBOXED=1 LANE_GATE_DISABLE=1 WINDOWS_ONLY=1 STAMP_DRY=1 \
      HARNESS_SECRET= bash "$H/bin/cost-rollup.sh" > "$H/run.out" 2>&1
  echo $? > "$H/run.rc"
}
S() { printf '%s\n' "$H/state/cost/summary.json"; }
unreadable_lines() { grep -c '/api/cost/live unreadable' "$H/logs/agent-rules.log" 2>/dev/null || true; }

# ── R1 ───────────────────────────────────────────────────────────────────────
setup r1 good; run; R1H="$H"
[ "$(cat "$H/run.rc")" = 0 ] && ok || bad "R1: rollup exited $(cat "$H/run.rc"): $(tail -5 "$H/run.out")"
[ "$(jq '.live.in_flight_usd' "$(S)" 2>/dev/null)" = 3.25 ] && ok || bad "R1: .live.in_flight_usd should be 3.25, got $(jq -c .live "$(S)" 2>/dev/null)"
[ "$(jq '.live.unsettled_usd' "$(S)" 2>/dev/null)" = 0.5 ] && ok || bad "R1: .live.unsettled_usd should be 0.5"
[ "$(jq '.live.rows' "$(S)" 2>/dev/null)" = 2 ] && ok || bad "R1: .live.rows should be the count 2"
[ "$(jq '.live.truncated' "$(S)" 2>/dev/null)" = false ] && ok || bad "R1: .live.truncated should be false"
[ "$(jq -r '.live.as_of' "$(S)" 2>/dev/null)" = "$NOWTS" ] && ok || bad "R1: .live.as_of should echo the route's as_of"
[ "$(jq '.live | has("unreadable")' "$(S)" 2>/dev/null)" = false ] && ok || bad "R1: a good read must not carry unreadable"
[ "$(cat "$FIX/live.calls" 2>/dev/null)" = "/api/cost/live?hours=24" ] && ok || bad "R1: expected one GET /api/cost/live?hours=24, got '$(cat "$FIX/live.calls" 2>/dev/null)'"
[ "$(unreadable_lines)" = 0 ] && ok || bad "R1: a good read logged an unreadable line"

# ── R2 ───────────────────────────────────────────────────────────────────────
setup r2 e500; run; R2H="$H"
[ "$(cat "$H/run.rc")" = 0 ] && ok || bad "R2: rollup exited $(cat "$H/run.rc"): $(tail -5 "$H/run.out")"
[ "$(jq -c '.live' "$(S)" 2>/dev/null)" = '{"unreadable":true}' ] && ok || bad "R2: .live should be exactly {\"unreadable\":true}, got $(jq -c .live "$(S)" 2>/dev/null)"
[ "$(jq '[.live[]|numbers]|length' "$(S)" 2>/dev/null)" = 0 ] && ok || bad "R2: an unreadable live block must carry no numbers"
[ "$(unreadable_lines)" = 1 ] && ok || bad "R2: expected exactly one unreadable log line, got $(unreadable_lines)"
grep -qE '/api/cost/live unreadable.*http=500' "$H/logs/agent-rules.log" 2>/dev/null && ok || bad "R2: the log line should name http=500"

# ── R3 ───────────────────────────────────────────────────────────────────────
for m in shape e404; do
  setup "r3-$m" "$m"; run
  [ "$(cat "$H/run.rc")" = 0 ] && ok || bad "R3 $m: rollup exited $(cat "$H/run.rc")"
  [ "$(jq -c '.live' "$(S)" 2>/dev/null)" = '{"unreadable":true}' ] && ok || bad "R3 $m: .live should be unreadable, got $(jq -c .live "$(S)" 2>/dev/null)"
  [ "$(unreadable_lines)" = 1 ] && ok || bad "R3 $m: expected one unreadable log line, got $(unreadable_lines)"
done

# ── R4 ───────────────────────────────────────────────────────────────────────
for f in fleet-cost.csv cost-per-pr.csv; do
  if [ -f "$R1H/state/cost/$f" ] || [ -f "$R2H/state/cost/$f" ]; then
    cmp -s "$R1H/state/cost/$f" "$R2H/state/cost/$f" && ok || bad "R4: $f differs between a good and a failed live read"
  else
    bad "R4: $f was written by neither run"
  fi
done
strip='del(.live, .generated_at)'
if [ "$(jq -S "$strip" "$R1H/state/cost/summary.json" 2>/dev/null)" = "$(jq -S "$strip" "$R2H/state/cost/summary.json" 2>/dev/null)" ] \
   && [ -n "$(jq -S "$strip" "$R1H/state/cost/summary.json" 2>/dev/null)" ]; then ok
else bad "R4: summary.json minus .live/generated_at differs between R1 and R2"; fi

# ── R5 ───────────────────────────────────────────────────────────────────────
ROUTE="$DIR/worker/jobs/src/routes/cost-live.js"
[ -f "$ROUTE" ] && ok || bad "R5: $ROUTE is missing"
if command -v node >/dev/null 2>&1; then
  if [ -x "$DIR/bin/lanes-build.sh" ] && [ -d "$DIR/catalog/lanes.d" ]; then
    "$DIR/bin/lanes-build.sh" --root "$DIR" --write >"$T/lanes-build.out" 2>&1 \
      || bad "R5: catalog/lanes.json could not be composed from catalog/lanes.d (worker/jobs/src/lib/core.js imports it statically): $(tail -3 "$T/lanes-build.out")"
  fi
  if (cd "$DIR/worker/jobs" && node --test test/cost-live.bh-3499.test.js > "$T/node.out" 2>&1); then ok
  else
    bad "R5: worker/jobs/test/cost-live.bh-3499.test.js is red: $(grep -E '^not ok' "$T/node.out" | head -5)"
    grep -E 'Error|ERR_' "$T/node.out" | head -5
  fi
else
  echo "R5: node not on PATH, route suite not run here"
fi

echo "cost-live-rollup.bh-3499: PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
