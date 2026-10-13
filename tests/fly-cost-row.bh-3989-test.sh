#!/bin/bash
# tests/fly-cost-row.bh-3989-test.sh — BH-4019 (split child 2 of #3989): the
# Fly infra cost row written when bin/fly-pool.sh reaps a LIVE pool machine's
# RESULT. A-cases drive fly_cost_row_once in bin/lib/fly-cost-row.sh; B-cases
# drive pool_fly_cost_row extracted from the real bin/fly-pool.sh and pin its
# one call site. Assertions read CSV fields with python's csv module.
DIR="$(cd "$(dirname "$0")/.." && pwd)"
. "$(dirname "$0")/lib/scratch.sh" || exit 1
LIB="$DIR/bin/lib/fly-cost-row.sh"
POOLSH="$DIR/bin/fly-pool.sh"
DISPATCH="$DIR/bin/fly-dispatch.sh"
. "$DIR/bin/lib/cost-row.sh" || exit 1
. "$LIB" || exit 1

pass=0; fail=0
ok()  { pass=$((pass+1)); }
bad() { fail=$((fail+1)); echo "FAIL: $*"; }
eq()  { if [ "$2" = "$3" ]; then ok; else bad "$1: want [$2] got [$3]"; fi; }

# Count of fly-machine rows, and a named column of the last one.
nrows() { python3 - "$1" <<'PY'
import csv, sys, os
p = sys.argv[1]
if not os.path.exists(p): print(0); sys.exit()
r = list(csv.DictReader(open(p)))
print(sum(1 for x in r if x.get("row_source") == "fly-machine"))
PY
}
col() { python3 - "$1" "$2" <<'PY'
import csv, sys
r = [x for x in csv.DictReader(open(sys.argv[1])) if x.get("row_source") == "fly-machine"]
print(r[-1].get(sys.argv[2], "<nocol>") if r else "<norow>")
PY
}
nfields() { python3 - "$1" <<'PY'
import csv, sys
r = list(csv.reader(open(sys.argv[1])))
print(len(r[-1]) if len(r) > 1 else 0)
PY
}
lines() { if [ -f "$1" ]; then wc -l < "$1" | tr -d ' '; else echo 0; fi; }

if ! command -v fly_cost_row_once >/dev/null 2>&1; then
  echo "FAIL: fly_cost_row_once not defined after sourcing $LIB"
  echo "fly-cost-row: 0 passed, 1 failed"; exit 1
fi

cat > "$T/prices.json" <<'JSON'
{"seconds_per_month": 2628000,
 "cpu_usd_per_core_month": {"shared": 2.0, "performance": 31.0},
 "memory_usd_per_gb_month": 5.0, "volume_usd_per_gb_month": 0.15}
JSON
PR="$T/prices.json"
S0="2026-10-03 10:00:00Z"; E0=$(( $(date -u -d "$S0" +%s) + 3600 ))

# ---- A2: one priced row, 26 columns, every specified field.
CSV="$T/a/cost.csv"; LED="$T/a/state/ledger.tsv"; mkdir -p "$T/a"
out=$(fly_cost_row_once "$CSV" "$LED" proj pool-proj-m1 m1 BH-1 J9 run-1 "$S0" "$E0" performance 8 16384 "$PR"); rc=$?
eq "A2 rc" 0 "$rc"
eq "A2 rows" 1 "$(nrows "$CSV")"
eq "A2 header" "$COST_ROW_HDR" "$(head -1 "$CSV")"
eq "A2 width" 26 "$(nfields "$CSV")"
rate=$(fly_price_per_s "$PR" performance 8 16384); rate=${rate%% *}
want=$(awk -v s=3600 -v r="$rate" 'BEGIN{printf "%.6f", s*r}')
eq "A2 cost_usd" "$want" "$(col "$CSV" cost_usd)"
eq "A2 stdout" "3600 $want" "$out"
eq "A2 stage" infra "$(col "$CSV" stage)"
eq "A2 runner" fly "$(col "$CSV" runner)"
eq "A2 duration" 3600 "$(col "$CSV" duration_s)"
eq "A2 model" performance-8x-16384mb "$(col "$CSV" model)"
eq "A2 project" proj "$(col "$CSV" project)"
eq "A2 host" pool-proj-m1 "$(col "$CSV" host)"
eq "A2 ticket" BH-1 "$(col "$CSV" ticket)"
eq "A2 job_id" J9 "$(col "$CSV" job_id)"
eq "A2 run_id" run-1 "$(col "$CSV" run_id)"
eq "A2 billing" metered "$(col "$CSV" billing_mode)"
eq "A2 lane_id" "" "$(col "$CSV" lane_id)"
eq "A2 rc col" 0 "$(col "$CSV" rc)"
eq "A2 ts" 2026-10-03T11:00:00Z "$(col "$CSV" ts)"
case "$(col "$CSV" note)" in "fly:m1:prices=catalog") ok ;; *) bad "A2 note: $(col "$CSV" note)" ;; esac
eq "A2 ledger" 1 "$(lines "$LED")"

# ---- A4: same (mid,key,start) again is a no-op; a new start is a new row.
fly_cost_row_once "$CSV" "$LED" proj pool-proj-m1 m1 BH-1 J9 run-1 "$S0" "$E0" performance 8 16384 "$PR" >/dev/null; rc=$?
eq "A4 dup rc" 3 "$rc"
eq "A4 dup rows" 1 "$(nrows "$CSV")"
eq "A4 dup ledger" 1 "$(lines "$LED")"
S1="2026-10-03 12:00:00Z"; E1=$(( $(date -u -d "$S1" +%s) + 600 ))
fly_cost_row_once "$CSV" "$LED" proj pool-proj-m1 m1 BH-1 J10 run-2 "$S1" "$E1" performance 8 16384 "$PR" >/dev/null; rc=$?
eq "A4 next rc" 0 "$rc"
eq "A4 next rows" 2 "$(nrows "$CSV")"
eq "A4 next ledger" 2 "$(lines "$LED")"
eq "A4 next duration" 600 "$(col "$CSV" duration_s)"

# ---- A5a: unknown size -> empty cost, UNPRICED note, never $0.
CSV="$T/a5/cost.csv"; LED="$T/a5/ledger.tsv"; mkdir -p "$T/a5"
out=$(fly_cost_row_once "$CSV" "$LED" proj pool-proj-m2 m2 BH-2 "" run-3 "$S0" "$E0" performance "" 16384 "$PR"); rc=$?
eq "A5a rc" 0 "$rc"
eq "A5a rows" 1 "$(nrows "$CSV")"
eq "A5a cost" "" "$(col "$CSV" cost_usd)"
eq "A5a note" "UNPRICED:fly-size-unknown:m2" "$(col "$CSV" note)"
eq "A5a stdout" "3600 unpriced" "$out"

# ---- A5b: end before start, and an unparseable start -> rc 2, nothing written.
CSV="$T/a5b/cost.csv"; LED="$T/a5b/ledger.tsv"; mkdir -p "$T/a5b"
fly_cost_row_once "$CSV" "$LED" proj pool-proj-m3 m3 BH-3 "" run-4 "$S0" $(( E0 - 7200 )) performance 8 16384 "$PR" >/dev/null; rc=$?
eq "A5b rc" 2 "$rc"
eq "A5b csv absent" no "$( [ -e "$CSV" ] && echo yes || echo no)"
eq "A5b ledger" 0 "$(lines "$LED")"
fly_cost_row_once "$CSV" "$LED" proj pool-proj-m3 m3 BH-3 "" run-4 "not a date" "$E0" performance 8 16384 "$PR" >/dev/null; rc=$?
eq "A5b bad start rc" 2 "$rc"
eq "A5b bad start csv" no "$( [ -e "$CSV" ] && echo yes || echo no)"

# ---- B: pool_fly_cost_row from the real bin/fly-pool.sh.
FN=$(sed -n '/^pool_fly_cost_row()/,/^}/p' "$POOLSH")
if [ -z "$FN" ]; then
  bad "B: pool_fly_cost_row() not found in $POOLSH"
else
  eval "$FN"
  export HARNESS="$T/h"; mkdir -p "$HARNESS/catalog"
  cp "$PR" "$HARNESS/catalog/fly-prices.json"
  LOG="$T/pool.log"; : > "$LOG"
  say() { echo "$*" >> "$LOG"; }
  P=proj; MID=m1; KEY=BH-42
  LISTING="$T/listing.json"
  echo '[{"id":"m1","config":{"guest":{"cpu_kind":"performance","cpus":8,"memory_mb":16384}}}]' > "$LISTING"
  LIST_OK=1
  SPAT=$(date -u -d '30 minutes ago' '+%Y-%m-%d %H:%M:%SZ')
  LOCAL="$T/builds/pool-proj-BH-42-202610031000"; mkdir -p "$LOCAL"
  { echo "$COST_ROW_HDR"
    echo "2026-10-03T10:05:00Z,pool-proj-m1,proj,plan,claude,opus,0,12,1,2,0,0,0.5,metered,,,,llm,,BH-42,J42,,run,,,"
  } > "$LOCAL/cost.csv"

  # B1: one infra row, job_id read from the build's own csv.
  pool_fly_cost_row; rc=$?
  eq "B1 rc" 0 "$rc"
  eq "B1 rows" 1 "$(nrows "$LOCAL/cost.csv")"
  eq "B1 job_id" J42 "$(col "$LOCAL/cost.csv" job_id)"
  eq "B1 host" pool-proj-m1 "$(col "$LOCAL/cost.csv" host)"
  eq "B1 run_id" "$(basename "$LOCAL")" "$(col "$LOCAL/cost.csv" run_id)"
  eq "B1 ticket" BH-42 "$(col "$LOCAL/cost.csv" ticket)"
  d=$(col "$LOCAL/cost.csv" duration_s)
  if [ "$d" -ge 1795 ] 2>/dev/null && [ "$d" -le 1810 ]; then ok; else bad "B1 duration: $d"; fi
  c=$(col "$LOCAL/cost.csv" cost_usd)
  [ -n "$c" ] && awk -v c="$c" 'BEGIN{exit !(c>0)}' && ok || bad "B1 cost: [$c]"
  grep -q 'fly cost row: written m1 BH-42' "$LOG" && ok || bad "B1 log: $(cat "$LOG")"
  eq "B1 ledger" 1 "$(lines "$HARNESS/state/fly-cost/ledger.tsv")"

  # B2: the next tick re-reaps the same job: no second row.
  pool_fly_cost_row; rc=$?
  eq "B2 rc" 0 "$rc"
  eq "B2 rows" 1 "$(nrows "$LOCAL/cost.csv")"
  grep -q 'fly cost row: already m1 BH-42' "$LOG" && ok || bad "B2 log: $(cat "$LOG")"

  # B4: unusable listing -> unpriced row, never $0.
  MID=m4; KEY=BH-44; LIST_OK=0
  LOCAL="$T/builds/b4"; mkdir -p "$LOCAL"
  pool_fly_cost_row; rc=$?
  eq "B4 rc" 0 "$rc"
  eq "B4 rows" 1 "$(nrows "$LOCAL/cost.csv")"
  eq "B4 cost" "" "$(col "$LOCAL/cost.csv" cost_usd)"
  eq "B4 note" "UNPRICED:fly-size-unknown:m4" "$(col "$LOCAL/cost.csv" note)"
  eq "B4 job_id" "" "$(col "$LOCAL/cost.csv" job_id)"
  grep -q 'fly cost row: written m4 BH-44 .* \$unpriced' "$LOG" && ok || bad "B4 log: $(cat "$LOG")"

  # B5: no spawned_at -> no row, one skip line.
  MID=m5; KEY=BH-45; LIST_OK=1; SPAT=""
  LOCAL="$T/builds/b5"; mkdir -p "$LOCAL"
  pool_fly_cost_row; rc=$?
  eq "B5 rc" 0 "$rc"
  eq "B5 csv absent" no "$( [ -e "$LOCAL/cost.csv" ] && echo yes || echo no)"
  grep -q 'fly cost row: skipped:no-spawned-at m5 BH-45' "$LOG" && ok || bad "B5 log: $(cat "$LOG")"

  # B3b: the lib is not loaded -> return 0, nothing written.
  MID=m6; KEY=BH-46; SPAT=$(date -u -d '5 minutes ago' '+%Y-%m-%d %H:%M:%SZ')
  LOCAL="$T/builds/b3b"; mkdir -p "$LOCAL"
  echo "$COST_ROW_HDR" > "$LOCAL/cost.csv"; before=$(md5sum < "$LOCAL/cost.csv")
  ( unset -f fly_cost_row_once; pool_fly_cost_row ); rc=$?
  eq "B3b rc" 0 "$rc"
  eq "B3b csv unchanged" "$before" "$(md5sum < "$LOCAL/cost.csv")"
fi

# B3a: the call sits directly above the live-machine push of the build's rows.
prev=$(grep -B1 'push_pool_cost_rows "\$LOCAL" "pool-\$P-\$MID"' "$POOLSH" | head -1 | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
if [ -z "$prev" ]; then bad "B3a: push_pool_cost_rows call not found in $POOLSH"
else eq "B3a line above push" pool_fly_cost_row "$prev"; fi
# B3c: exactly one call in the pool, none in the dispatcher.
eq "B3c pool calls" 1 "$(grep -c '^[[:space:]]*pool_fly_cost_row[[:space:]]*$' "$POOLSH")"
eq "B3c dispatch calls" 0 "$(grep -c 'pool_fly_cost_row' "$DISPATCH")"

echo "fly-cost-row: $pass passed, $fail failed"
[ "$fail" = 0 ]
