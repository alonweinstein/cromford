#!/bin/bash
# tests/budget-defaults.bh-4489-test.sh — bin/budget-defaults.sh, the generator
# of the seeded budget.* defaults (BH-4489): p99 x 2 of the window's cost rows.
#
#   B1  100 build runs of plan with 1..100 calls -> max_calls 198; usd up to
#       cents, tokens integers
#   B2  refused / settled rows excluded; a duplicated line counts once
#   B3  thresholds: <20 build runs -> no stage row (but _default); <14 days ->
#       no project row; a lane run id is not a build run
#   B4  the output is ONE INSERT OR IGNORE statement, sorted, legal keys, actor
#       seed, every note BH-4489
#   B5  a failed read exits 1 and prints nothing
#
# Run from anywhere: tests/budget-defaults.bh-4489-test.sh   (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
GEN="$DIR/bin/budget-defaults.sh"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
NOW=2026-10-04T12:00:00Z

HDR="ts,host,project,stage,runner,model,rc,duration_s,input_toks,output_toks,cache_read,cache_write,cost_usd,billing_mode,auth_fp,auth_account,session_id,row_source,result_usd,ticket,job_id,pr,run_id,note,lane_id,guard_fp"
# r <ts> <project> <stage> <cost> <run_id> [row_source] [tokens in,out,cr,cw]
# Every call gets its own session id, as real rows do; only a re-pushed row is
# byte-identical to another.
SEQN=0
r() { SEQN=$((SEQN + 1)); printf '%s,box,%s,%s,claude,m,0,1,%s,%s,subscription,fp,acct,sid-%d,%s,,,,,%s,,,\n' "$1" "$2" "$3" "${7:-100,10,0,0}" "$4" "$SEQN" "${6:-envelope}" "$5"; }
gen() { "$GEN" --now "$NOW" --rows "$1" > "$T/out.sql" 2> "$T/err"; echo $?; }
val() { grep -o "('$1','[^']*'" "$T/out.sql" | sed "s/.*,'//; s/'\$//"; }

[ -x "$GEN" ] && ok || bad "B0 $GEN is not an executable file"
"$GEN" -h > "$T/help" 2>&1; [ "$?" = 0 ] && grep -q 'budget-defaults.sh' "$T/help" && ok || bad "B0 -h: $(head -3 "$T/help")"

# =============================================================================
# B1 — 100 build runs of plan, the i-th with i calls of $0.011 and 1000 tokens each
# =============================================================================
F1="$T/b1.csv"
{ echo "$HDR"
  for i in $(seq 1 100); do
    for _ in $(seq 1 "$i"); do r "2026-10-0$(( (i % 3) + 1 ))T01:00:00Z" testproj plan 0.011 "testproj-TP-$i-202610010000"; done
  done
  # a lane-only stage with exactly enough days (30) for a stage-day row
  for d in $(seq -w 1 30); do r "2026-09-${d}T05:00:00Z" testproj triage 1.005 "triage-lane-$d"; done
} > "$F1"
R=$(gen "$F1")
[ "$R" = 0 ] && ok || bad "B1 rc=$R: $(head -3 "$T/err")"
[ "$(val budget.stage.plan.max_calls)" = 198 ] && ok || bad "B1 plan.max_calls '$(val budget.stage.plan.max_calls)', want 198"
# per-run usd: 99 calls x 0.011 = 1.089 -> x2 = 2.178 -> up to cents 2.18
[ "$(val budget.stage.plan.max_usd)" = 2.18 ] && ok || bad "B1 plan.max_usd '$(val budget.stage.plan.max_usd)', want 2.18"
# per-run tokens: 99 x 110 = 10890 -> x2 = 21780
[ "$(val budget.stage.plan.max_tokens)" = 21780 ] && ok || bad "B1 plan.max_tokens '$(val budget.stage.plan.max_tokens)', want 21780"
[ "$(val budget.stage._default.max_calls)" = 198 ] && ok || bad "B1 _default.max_calls '$(val budget.stage._default.max_calls)'"
# triage: 30 days of 1.005 -> p99 1.005 -> x2 2.01
[ "$(val budget.stage.triage.day_usd)" = 2.01 ] && ok || bad "B1 triage.day_usd '$(val budget.stage.triage.day_usd)', want 2.01"
[ "$(val budget.stage.triage.day_calls)" = 2 ] && ok || bad "B1 triage.day_calls '$(val budget.stage.triage.day_calls)', want 2"
grep -q "'budget.stage.triage.max_calls'" "$T/out.sql" && bad "B1 a lane run id counted as a build run (triage.max_calls)" || ok
[ -n "$(val budget.project.testproj.day_usd)" ] && ok || bad "B1 no project row for a 33-day project"

# =============================================================================
# B2 — refused / settled excluded; a duplicated line counts once
# =============================================================================
F2="$T/b2.csv"
{ head -1 "$F1"; tail -n +2 "$F1"
  for i in $(seq 1 50); do r 2026-10-02T02:00:00Z testproj plan 0 testproj-TP-100-202610010000 refused; done
  for i in $(seq 1 50); do r 2026-10-02T02:00:00Z testproj plan 0 testproj-TP-100-202610010000 settled; done
  grep 'TP-100-' "$F1"
} > "$F2"
R=$(gen "$F2")
[ "$R" = 0 ] && [ "$(val budget.stage.plan.max_calls)" = 198 ] && ok || bad "B2 refused/settled/duplicates moved the cap: rc=$R '$(val budget.stage.plan.max_calls)'"

# =============================================================================
# B3 — thresholds
# =============================================================================
F3="$T/b3.csv"
{ echo "$HDR"
  for i in $(seq 1 19); do r 2026-10-01T01:00:00Z shortproj fix 1 "shortproj-SP-$i-202610010000"; done
  for i in $(seq 1 12); do r "2026-09-$(printf %02d "$i")T01:00:00Z" shortproj fix 1 "lane-xyz"; done
} > "$F3"
R=$(gen "$F3")
[ "$R" = 0 ] && ok || bad "B3 rc=$R $(head -3 "$T/err")"
grep -q "'budget.stage.fix.max_calls'" "$T/out.sql" && bad "B3 a stage with 19 build runs got a row" || ok
[ -n "$(val budget.stage._default.max_calls)" ] && ok || bad "B3 no _default.max_calls"
grep -q "'budget.project.shortproj.day_usd'" "$T/out.sql" && bad "B3 a 14-day-short project got a row" || ok
# 13 stage-days of fix (12 lane days + the build day): under the 30 stage-day
# minimum, so no row of its own; the pooled _default caps it instead
grep -q "'budget.stage.fix.day_" "$T/out.sql" && bad "B3 a 13-stage-day stage got a day row: $(grep 'stage.fix.day_' "$T/out.sql")" || ok
[ -n "$(val budget.stage._default.day_calls)" ] && ok || bad "B3 no stage-day _default"
F3C="$T/b3c.csv"
{ echo "$HDR"; for d in $(seq -w 1 29); do r "2026-09-${d}T05:00:00Z" p synth 0.1 "synth-lane-$d"; done; } > "$F3C"
R=$(gen "$F3C")
[ "$R" = 0 ] && ok || bad "B3 29 days rc=$R"
grep -q "'budget.stage.synth.day_" "$T/out.sql" && bad "B3 29 stage-days (one short) got a day row" || ok
[ -n "$(val budget.project._default.day_usd)" ] && ok || bad "B3 no project _default"

# a stage whose runs bill no tokens (infra) must not be seeded max_tokens 0:
# 0 is "refuse everything", so a zero p99 seeds no row on that axis
F3B="$T/b3b.csv"
{ echo "$HDR"; for i in $(seq 1 25); do r 2026-10-01T01:00:00Z p infra 0.5 "p-P-$i-202610010000" envelope 0,0,0,0; done; } > "$F3B"
R=$(gen "$F3B")
[ "$R" = 0 ] && [ -n "$(val budget.stage.infra.max_calls)" ] && ok || bad "B3 infra: rc=$R no max_calls row"
grep -q "'budget.stage.infra.max_tokens'" "$T/out.sql" && bad "B3 a zero p99 seeded a refuse-everything cap: $(grep infra.max_tokens "$T/out.sql")" || ok
grep -q "'budget.stage._default.max_tokens'" "$T/out.sql" && bad "B3 a zero pooled p99 seeded _default.max_tokens" || ok

# =============================================================================
# B4 — the statement's shape
# =============================================================================
gen "$F1" >/dev/null
[ "$(grep -c 'INSERT OR IGNORE INTO settings (key,value,note,actor,updated_at) VALUES' "$T/out.sql")" = 1 ] && ok || bad "B4 not exactly one INSERT OR IGNORE"
[ "$(grep -c ';' "$T/out.sql")" = 1 ] && tail -1 "$T/out.sql" | grep -q ';$' && ok || bad "B4 not one statement ending in ;"
grep -o "^  ('[^']*'" "$T/out.sql" | sed "s/^  ('//; s/'\$//" > "$T/keys"
[ -s "$T/keys" ] && ok || bad "B4 no rows"
sort -c "$T/keys" 2>/dev/null && ok || bad "B4 keys not sorted"
grep -vqE '^[a-z0-9_.-]{1,64}$' "$T/keys" && bad "B4 an illegal key: $(grep -vE '^[a-z0-9_.-]{1,64}$' "$T/keys")" || ok
[ "$(grep -c "^  ('" "$T/out.sql")" = "$(grep -c "'seed','$NOW')" "$T/out.sql")" ] && ok || bad "B4 a row without actor seed / updated_at"
[ "$(grep -c "^  ('" "$T/out.sql")" = "$(grep -c "BH-4489: p99x2 of " "$T/out.sql")" ] && ok || bad "B4 a note without BH-4489"
cp "$T/out.sql" "$T/first.sql"; gen "$F1" >/dev/null
cmp -s "$T/first.sql" "$T/out.sql" && ok || bad "B4 a re-run is not byte-identical"

# =============================================================================
# B5 — a failed read prints nothing
# =============================================================================
mkdir -p "$T/fakebin" "$T/h/bin/lib/jobs"
cp "$DIR/bin/jobs-client.sh" "$T/h/bin/"; cp "$DIR/bin/lib/jobs/"*.sh "$T/h/bin/lib/jobs/"
cat > "$T/fakebin/curl" <<'EOF'
#!/bin/bash
URL="${!#}"
n=$(( $(cat "$CNT" 2>/dev/null || echo 0) + 1 )); echo "$n" > "$CNT"
[ "$n" -ge 2 ] && exit 7
python3 - <<'PY'
import json
rows=[{"ts":"2026-10-04T00:00:%02dZ"%(i%60),"box":"b","row_hash":"h%d"%i,"project":"p","stage":"plan","cost_usd":1,"run_id":"p-P-1-202610010000","row_source":"envelope"} for i in range(2000)]
print(json.dumps({"cost_rows":rows}))
PY
printf '200\n'
EOF
chmod +x "$T/fakebin/curl"
OUT5=$(PATH="$T/fakebin:$PATH" HARNESS="$T/h" CNT="$T/cnt" HARNESS_SECRET=x JOBS_URL=https://jobs.invalid JOBS_RETRIES=0 \
  "$GEN" --now "$NOW" --days 30 2>"$T/err5"); R5=$?
[ "$R5" = 1 ] && ok || bad "B5 rc=$R5, want 1"
[ -z "$OUT5" ] && ok || bad "B5 printed a partial seed: $(head -3 <<<"$OUT5")"
[ "$(cat "$T/cnt")" -ge 2 ] && ok || bad "B5 the fake never reached page 2 ($(cat "$T/cnt")) — not paging"

echo "budget-defaults.bh-4489-test: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
