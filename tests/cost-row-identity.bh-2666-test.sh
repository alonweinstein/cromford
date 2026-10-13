#!/bin/bash
# tests/cost-row-identity.bh-2666-test.sh — BH-2666 (BH-2537 writer slice): the
# row bin/agent-call.sh writes carries the call's ticket ($20), its PR ($22) and
# the K3 guard fingerprint ($26, guard_fp) — on a paid row AND on a refused one.
#
# WHY. agent-call.sh unsets AGENT_CALL_TICKET (and _FP) right after the call
# guard reads them, which is before the ladder runs and before the row is built,
# so the ticket bin/triage-shard.sh declares never landed: 8,331 hub triage rows
# with an empty ticket in 7 days. And the guard's fp was written to no column.
#
# Driven, not grepped: the REAL bin/agent-call.sh (and, for T9e, the REAL
# bin/triage-shard.sh) against a fake claude that records its env, and the
# fake worker of tests/agent-call-call-guard.k3-test.sh answering the guard.
#
#   T1   AGENT_CALL_TICKET=BH-1 AGENT_CALL_FP=work-1 -> NF=26, $20=BH-1, $26=work-1
#   T2   AGENT_CALL_PR=<url> -> $22 is the url
#   T3   no declared fp -> $26 is <ticket>:<head>:p<sha16>, guard on AND off;
#        a declared fp of a,b"c keeps the row 26 wide
#   T5   AGENT_CALL_TICKET / _PR / _FP never reach the vendor session
#   T6s  a box whose bin/lib/cost-row.sh has not synced: header ends
#        lane_id,guard_fp and the row is 26 wide
#   T7   a call-guard repeat refusal: refused row NF=26, $18=refused,
#        $20=BH-1, $26=the fp named in the refusal marker
#   T7b  a runner-not-allowed rung refusal (after the unset): NF=26, $20=BH-1,
#        $26 non-empty
#   T9e  bin/triage-shard.sh with a dispatcher stamp: $20=<KEY>,
#        $26=<KEY>:<stamped fp>
#
# MUTATION (D1), run by hand in the build: delete the ROW_TICKET= capture in
# bin/agent-call.sh -> T1 red; delete the cost_row_guard_fp append on the row
# -> T1 red.
#
# Run from anywhere: tests/cost-row-identity.bh-2666-test.sh (exit 0 = pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
. "$DIR/tests/lib/model-route-stub.sh" || exit 1
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }

mkdir -p "$T/bin/lib/jobs" "$T/fakebin" "$T/flags" "$T/locks" "$T/logs" "$T/state" "$T/noenv"
mrs_fixture "$T" testproj
cp "$DIR/bin/jobs-client.sh" "$T/bin/jobs-client.sh"
cp "$DIR/bin/lib/jobs/"*.sh "$T/bin/lib/jobs/"
cp "$DIR/bin/lib/env-path.sh" "$T/bin/lib/env-path.sh"
cp "$DIR/bin/billing-mode.sh" "$T/bin/billing-mode.sh"

# The vendor: records that it ran and the env it was handed.
cat > "$T/fakebin/claude" <<'EOF'
#!/bin/bash
echo claude >> "$ORDER_SINK"
env > "$ENV_SINK"
echo '{"result":"ok","usage":{"input_tokens":10,"output_tokens":2},"total_cost_usd":0.01}'
EOF
cat > "$T/fakebin/timeout" <<'EOF'
#!/bin/bash
[ "${1:-}" = "--kill-after" ] && shift 2
case "${1:-}" in --kill-after=*) shift ;; esac
shift
exec "$@"
EOF
# The fake worker, call-guard endpoints only (same shape as the K3 suite's).
# Rows: call_id<TAB>project<TAB>stage<TAB>fp<TAB>status.
cat > "$T/fakebin/curl" <<'EOF'
#!/bin/bash
url="" data=""
while [ $# -gt 0 ]; do
  case "$1" in
    --data-binary) data="$2"; shift 2 ;;
    -X|-m|--connect-timeout|-w|-H) shift 2 ;;
    -*) shift ;;
    *) url="$1"; shift ;;
  esac
done
case "$data" in @*) data=$(cat "${data#@}") ;; esac
case "$url" in */api/call-guard/*) ;; *) exit 7 ;; esac
touch "$CG_ROWS"
case "$url" in
  */claim)
    id=$(jq -r .call_id <<<"$data"); p=$(jq -r .project <<<"$data"); s=$(jq -r .stage <<<"$data")
    f=$(jq -r .fp <<<"$data"); m=$(jq -r .max <<<"$data")
    n=$(awk -F'\t' -v p="$p" -v s="$s" -v f="$f" '$2==p && $3==s && $4==f && $5!="refused"{c++} END{print c+0}' "$CG_ROWS")
    if [ "$n" -lt "$m" ]; then
      printf '%s\t%s\t%s\t%s\tclaimed\n' "$id" "$p" "$s" "$f" >> "$CG_ROWS"
      printf '{"allowed":true,"count":%s,"max":%s,"call_id":"%s"}\n200' "$((n+1))" "$m" "$id"
    else
      printf '%s\t%s\t%s\t%s\trefused\n' "$id" "$p" "$s" "$f" >> "$CG_ROWS"
      printf '{"allowed":false,"count":%s,"max":%s,"call_id":"%s","top":[]}\n200' "$n" "$m" "$id"
    fi ;;
  */settle) printf '{"settled":true}\n200' ;;
  *) printf '{"error":"unknown endpoint"}\n404' ;;
esac
EOF
printf '#!/bin/bash\nexit 0\n' > "$T/bin/beat.sh"
printf '#!/bin/bash\necho "test rules"\n' > "$T/bin/sync-agent-rules.sh"
chmod +x "$T/fakebin/"* "$T/bin/"*.sh

reset() { : > "$T/order"; : > "$T/claude-env"; : > "$T/cg.rows"; rm -f "$T/logs/cost.csv"; }

# call <out-name> [VAR=VAL ...] -> prints the rc. The real agent-call, stage
# triage, a subscription claude, a live fake worker.
call() {
  local out="$1"; shift
  ( unset AGENT_CALL_FP AGENT_CALL_GUARD_STAGE AGENT_CALL_TICKET AGENT_CALL_GUARD_FORCE AGENT_CALL_PR \
          HARNESS_TICKET COST_KEY COST_PR COST_JOB JOB_ID COST_RUN_ID CG_FP CALL_GUARD CALL_GUARD_STAGES CALL_GUARD_MAX_MAP
    export ORDER_SINK="$T/order" ENV_SINK="$T/claude-env" CG_ROWS="$T/cg.rows" \
           PATH="$T/fakebin:$PATH" HARNESS="${CALL_HARNESS:-$T}" HOME="$T" HARNESS_ENV_DIR="$T/noenv" \
           JOBS_URL="https://jobs.test" HARNESS_SECRET="test-secret" JOBS_RETRIES=0 JOBS_BOX=testbox \
           CLAUDE_CODE_OAUTH_TOKEN=tok ANTHROPIC_API_KEY= \
           OPENROUTER_API_KEY= FIREWORKS_API_KEY= CODEX_API_KEY= OPENAI_API_KEY= XAI_API_KEY= ACCOUNT_ROUTING=0 \
           LADDER_TIER2_GROK=0 LADDER_BACKOFF_SECS=0 LADDER_SAME_RETRIES=0 \
           AGENT_CALL_RUNNERS= AGENT_CALL_LEDGER=0 RUNNER_TRIAGE=claude RUNNER_TRIAGE_FALLBACK= \
           LANE_GATE_DISABLE=1 LLM_GATE_DISABLE=1 BEAT_LOG=/dev/null \
           CONTEXT_BUDGETS="$DIR/catalog/context-budgets.json" "$@"
    cd "$T" && bash "${CALL_SCRIPT:-$DIR/bin/agent-call.sh}" triage testproj claude-fable-5-1 60 "$T/$out" "triage BH-1 please" \
      >/dev/null 2>&1 )
  echo $?
}
# f <n> — field n of the last row of logs/cost.csv; nf — its field count.
f()  { tail -1 "$T/logs/cost.csv" 2>/dev/null | awk -F, -v n="$1" '{print $n}'; }
nf() { tail -1 "$T/logs/cost.csv" 2>/dev/null | awk -F, '{print NF}'; }
last() { tail -1 "$T/logs/cost.csv" 2>/dev/null; }

# ── T1: declared ticket and fp land, the fp verbatim ─────────────────────────
reset
RC=$(call t1 AGENT_CALL_TICKET=BH-1 AGENT_CALL_FP=work-1)
[ "$RC" = 0 ] && [ -s "$T/order" ] && ok || bad "T1: the call did not run (rc $RC)"
[ "$(nf)" = 26 ] && ok || bad "T1: the row is $(nf) fields wide, want 26: $(last)"
[ "$(f 20)" = BH-1 ] && ok || bad "T1: ticket (\$20) is '$(f 20)', want BH-1: $(last)"
[ "$(f 26)" = work-1 ] && ok || bad "T1: guard_fp (\$26) is '$(f 26)', want work-1 (verbatim, not hashed): $(last)"
[ "$(head -1 "$T/logs/cost.csv" | awk -F, '{print NF, $26}')" = "26 guard_fp" ] && ok \
  || bad "T1: the header does not end in guard_fp: $(head -1 "$T/logs/cost.csv")"

# ── T5: none of the per-call identity reaches the vendor ─────────────────────
[ -s "$T/claude-env" ] && ok || bad "T5: the fake claude recorded no env"
LEAK=$(grep -E '^AGENT_CALL_(TICKET|PR|FP)=' "$T/claude-env")
[ -z "$LEAK" ] && ok || bad "T5: the vendor session inherited: $LEAK"

# ── T2: the PR lands in $22 (and still never reaches the vendor) ─────────────
reset
PRURL="https://github.com/o/r/pull/5"
RC=$(call t2 AGENT_CALL_TICKET=BH-1 AGENT_CALL_FP=work-1 AGENT_CALL_PR="$PRURL")
[ "$(f 22)" = "$PRURL" ] && ok || bad "T2: pr (\$22) is '$(f 22)', want $PRURL: $(last)"
grep -qE '^AGENT_CALL_PR=' "$T/claude-env" && bad "T5: AGENT_CALL_PR reached the vendor session" || ok

# ── T3: no declared fp -> the guard's derived fp, guard on and guard off ─────
FPRE='^BH-1:[0-9a-f-]*:p[0-9a-f]{16}$'
reset
RC=$(call t3 AGENT_CALL_TICKET=BH-1)
f 26 | grep -qE "$FPRE" && ok || bad "T3: guard on, derived guard_fp '$(f 26)' does not match $FPRE: $(last)"
reset
RC=$(call t3b AGENT_CALL_TICKET=BH-1 CALL_GUARD=0)
f 26 | grep -qE "$FPRE" && ok || bad "T3: guard OFF, derived guard_fp '$(f 26)' does not match $FPRE (written even when the guard is off): $(last)"
[ "$(f 20)" = BH-1 ] && ok || bad "T3: guard OFF, ticket (\$20) is '$(f 20)': $(last)"
reset
RC=$(call t3c AGENT_CALL_TICKET=BH-1 AGENT_CALL_FP='a,b"c')
[ "$(nf)" = 26 ] && ok || bad "T3: a comma/quote fp widened the row to $(nf) fields: $(last)"
[ "$(f 26)" = a_b_c ] && ok || bad "T3: fp a,b\"c should land sanitized as a_b_c, got '$(f 26)'"

# ── T7: a call-guard repeat refusal carries ticket and fp ────────────────────
reset
r1=$(call t7a AGENT_CALL_TICKET=BH-1 AGENT_CALL_FP=work-7 CALL_GUARD_MAX_MAP="triage=1")
r2=$(call t7b AGENT_CALL_TICKET=BH-1 AGENT_CALL_FP=work-7 CALL_GUARD_MAX_MAP="triage=1")
[ "$r1" = 0 ] && [ "$r2" = 74 ] && ok || bad "T7: want rcs 0 then 74 (repeat refused), got $r1 $r2"
MARK_FP=$(head -1 "$T/t7b" 2>/dev/null | sed -nE 's/^AGENT_CALL_REFUSED call-guard repeat .* fp=([^ ]*)$/\1/p')
[ -n "$MARK_FP" ] && ok || bad "T7: no call-guard repeat marker: $(head -1 "$T/t7b" 2>/dev/null)"
[ "$(nf)" = 26 ] && ok || bad "T7: the refused row is $(nf) fields wide, want 26: $(last)"
[ "$(f 18)" = refused ] && ok || bad "T7: \$18 is '$(f 18)', want refused: $(last)"
[ "$(f 20)" = BH-1 ] && ok || bad "T7: refused row ticket (\$20) is '$(f 20)': $(last)"
[ -n "$MARK_FP" ] && [ "$(f 26)" = "$MARK_FP" ] && ok || bad "T7: refused row guard_fp '$(f 26)' is not the marker's fp '$MARK_FP'"

# ── T7b: a rung refusal inside the ladder (after the unset) ──────────────────
reset
RC=$(call t7c AGENT_CALL_TICKET=BH-1 AGENT_CALL_FP=work-7b LLM_GATE_DISABLE=0 LLM_RUNNER_ALLOWED=grok)
[ -s "$T/order" ] && bad "T7b: claude ran although the lane allows grok only" || ok
ROW=$(grep 'refused:runner-not-allowed' "$T/logs/cost.csv" 2>/dev/null | tail -1)
[ -n "$ROW" ] && ok || bad "T7b: no runner-not-allowed refused row (rc $RC): $(cat "$T/logs/cost.csv" 2>/dev/null)"
[ "$(awk -F, '{print NF}' <<<"$ROW")" = 26 ] && ok || bad "T7b: the rung refusal row is not 26 wide: $ROW"
[ "$(awk -F, '{print $20}' <<<"$ROW")" = BH-1 ] && ok || bad "T7b: the rung refusal row has no ticket: $ROW"
[ "$(awk -F, '{print $26}' <<<"$ROW")" = work-7b ] && ok || bad "T7b: the rung refusal row guard_fp is not work-7b: $ROW"

# ── T6s: a box whose lib sync lags (no bin/lib/cost-row.sh) ─────────────────
S="$T/stale"; mkdir -p "$S"
cp -r "$DIR/bin" "$S/bin"; rm -f "$S/bin/lib/cost-row.sh"
cp "$T/bin/beat.sh" "$T/bin/sync-agent-rules.sh" "$S/bin/"
mkdir -p "$S/logs" "$S/locks" "$S/flags" "$S/state"; cp -r "$T/state/model-routes" "$S/state/" 2>/dev/null
rm -f "$S/logs/cost.csv"
RC=$(CALL_HARNESS="$S" CALL_SCRIPT="$S/bin/agent-call.sh" call t6 AGENT_CALL_TICKET=BH-1 AGENT_CALL_FP=work-6 COST_ROW_HDR=)
case "$(head -1 "$S/logs/cost.csv" 2>/dev/null)" in
  *,lane_id,guard_fp) ok ;;
  *) bad "T6s: stale-lib header does not end lane_id,guard_fp (rc $RC): $(head -1 "$S/logs/cost.csv" 2>/dev/null)" ;;
esac
[ "$(tail -1 "$S/logs/cost.csv" 2>/dev/null | awk -F, '{print NF}')" = 26 ] && ok \
  || bad "T6s: stale-lib row is not 26 wide: $(tail -1 "$S/logs/cost.csv" 2>/dev/null)"

# ── T9e: the production producer — bin/triage-shard.sh with a stamp ──────────
printf '#!/bin/bash\nexec bash "%s/bin/agent-call.sh" "$@"\n' "$DIR" > "$T/bin/agent-call.sh"
printf '#!/bin/sh\necho "CONTRACT: end with DECISION lines."\n' > "$T/bin/triage-contract.sh"
printf '#!/bin/bash\nexit 0\n' > "$T/bin/decision-log.sh"
chmod +x "$T/bin/agent-call.sh" "$T/bin/triage-contract.sh" "$T/bin/decision-log.sh"
cp "$DIR/bin/lib/lock-hygiene.sh" "$T/bin/lib/"
# Exactly the real lib's stamp-path function, so the shard reads the stamp the
# dispatcher writes (the context-kill-lanes suite's shape).
sed -n '/^triage_shard_fp_file()/p' "$DIR/bin/lib/triage-shards-lib.sh" > "$T/bin/lib/triage-shards-lib.sh"
grep -q '^triage_shard_fp_file()' "$T/bin/lib/triage-shards-lib.sh" && ok \
  || bad "T9e: could not extract triage_shard_fp_file from bin/lib/triage-shards-lib.sh"
KEY=BH-9; STAMPFP=$(printf '%s' "stamp-$KEY" | sha256sum | cut -c1-40)
mkdir -p "$T/state/triage-shards/testproj"
printf '%s\n%s\n' "$STAMPFP" "$(date +%s)" > "$T/state/triage-shards/testproj/$KEY.fp"
printf 'Triage ticket %s on testproj.\n' "$KEY" > "$T/prompt.txt"
reset
( unset AGENT_CALL_FP AGENT_CALL_GUARD_STAGE AGENT_CALL_TICKET AGENT_CALL_PR HARNESS_TICKET COST_KEY CG_FP JOB_ID COST_JOB \
        CALL_GUARD CALL_GUARD_STAGES CALL_GUARD_MAX_MAP
  export ORDER_SINK="$T/order" ENV_SINK="$T/claude-env" CG_ROWS="$T/cg.rows" \
         PATH="$T/fakebin:$PATH" HARNESS="$T" HOME="$T" HARNESS_ENV_DIR="$T/noenv" \
         JOBS_URL="https://jobs.test" HARNESS_SECRET="test-secret" JOBS_RETRIES=0 JOBS_BOX=testbox \
         CLAUDE_CODE_OAUTH_TOKEN=tok ANTHROPIC_API_KEY= ACCOUNT_ROUTING=0 LADDER_TIER2_GROK=0 \
         LADDER_BACKOFF_SECS=0 LADDER_SAME_RETRIES=0 AGENT_CALL_LEDGER=0 RUNNER_TRIAGE_FALLBACK= \
         LANE_GATE_DISABLE=1 LLM_GATE_DISABLE=1 BEAT_LOG=/dev/null \
         TSH_RUNNER=claude TSH_MODEL=claude-fable-5-1 CONTEXT_BUDGETS="$DIR/catalog/context-budgets.json"
  cd "$T" && bash "$DIR/bin/triage-shard.sh" testproj "$KEY" "$T/prompt.txt" >/dev/null 2>&1 )
[ -s "$T/order" ] && ok || bad "T9e: the shard never reached the vendor: $(tail -3 "$T/logs/testproj.log" 2>/dev/null)"
SROW=$(grep ',testproj,triage,claude,' "$T/logs/cost.csv" 2>/dev/null | tail -1)
[ "$(awk -F, '{print NF}' <<<"$SROW")" = 26 ] && ok || bad "T9e: the shard's row is not 26 wide: $SROW"
[ "$(awk -F, '{print $20}' <<<"$SROW")" = "$KEY" ] && ok || bad "T9e: the shard's row ticket (\$20) is not $KEY: $SROW"
[ "$(awk -F, '{print $26}' <<<"$SROW")" = "$KEY:$STAMPFP" ] && ok \
  || bad "T9e: the shard's row guard_fp (\$26) is not $KEY:$STAMPFP: $SROW"

echo "cost-row-identity.bh-2666: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
