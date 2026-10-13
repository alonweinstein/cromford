#!/bin/bash
# tests/agent-call-advisor-envelope.bh-3602-test.sh — BH-3602: on the ENVELOPE
# path (no transcript) of a claude call that ran with --advisor, the executor
# row and the `<stage>-advisor` row together carry the envelope's
# total_cost_usd exactly once, and row_source says how the split was made.
#
#   E1  total includes the advisor (a fable key in modelUsage): executor row
#       nets it out (result-net-advisor), advisor row carries the modelUsage
#       share (result-modelusage), the two sum to total_cost_usd
#   E2  total excludes it (no fable key): both rows as before, row_source result
#   E3  same family (Fable main, fable advisor): the committed
#       _ADV_ENV_SAME_FAMILY arm, plus the `includes` arm driven on a copy
#   E4  the envelope does not add up / has no modelUsage: executor keeps the
#       total, result-adv-unverified, one cost-source-delta.log line
#   E5  the build's cost.csv tee sums to the envelope total once
#   E6  the transcript path is untouched
#   E7  no advisor = no split; a transient retry inside one call does not
#       inherit the first attempt's split
#
# DRIVEN, NOT GREPPED: bin/agent-call.sh runs for real against a scratch HARNESS
# with a fake claude; the rows are read back from the ledger.
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
. "$DIR/tests/lib/model-route-stub.sh" || exit 1
mrs_fixture "$T" project-3
mkdir -p "$T/bin" "$T/fakebin" "$T/flags" "$T/locks" "$T/logs" "$T/state" "$T/env" "$T/wt" "$T/builds/b1"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
NOW=$(date -u +%s)
REG="$T/lanes.json"
"$DIR/bin/lanes-build.sh" --root "$DIR" --to "$REG" >/dev/null 2>&1 || bad "setup: lanes-build.sh could not compose the registry"

# ---------- fakes -----------------------------------------------------------
# claude: argv to $SINK, then the envelope FAKE_ENVELOPE names. FAKE_TRANSCRIPT=adv
# writes the BH-3491 transcript (executor 300/30, advisor fable 1000/100).
# FAKE_ENVELOPE=flaky: the FIRST invocation answers an overloaded error that
# still carries the incl envelope (rc 1, a transient), every later one writes
# the transcript and answers incl.
cat > "$T/fakebin/claude" <<'EOF'
#!/bin/bash
case " $* " in *" --help "*) printf -- '  --session-id <uuid>\n'; exit 0 ;; esac
n=$(( $(wc -l < "$SINK" 2>/dev/null || echo 0) + 1 ))
printf '%q ' "$@" >> "$SINK"; printf '\n' >> "$SINK"
sid=""; prev=""
for a in "$@"; do case "$prev" in --session-id|--resume) sid="$a" ;; esac; prev="$a"; done
env_mode="${FAKE_ENVELOPE:-incl}"; tr_mode="${FAKE_TRANSCRIPT:-}"; rc=0; res=ok
if [ "$env_mode" = flaky ]; then
  env_mode=incl
  if [ "$n" = 1 ]; then rc=1; res="API Error: 529 overloaded"; echo "API Error: 529 overloaded_error" >&2
  else tr_mode=adv; fi
fi
if [ -n "$sid" ] && [ -n "$tr_mode" ]; then
  d="$HOME/.claude/projects/$(pwd | tr / -)"; mkdir -p "$d"
  {
    printf '{"type":"assistant","message":{"id":"m1","model":"claude-opus-5-5","usage":{"input_tokens":100,"output_tokens":10,"cache_read_input_tokens":0,"cache_creation_input_tokens":0}}}\n'
    printf '{"type":"assistant","message":{"id":"m2","model":"claude-opus-5-5","usage":{"input_tokens":200,"output_tokens":20,"cache_read_input_tokens":0,"cache_creation_input_tokens":0,"iterations":[{"type":"message","input_tokens":200,"output_tokens":20},{"type":"advisor_message","model":"claude-fable-5-1","input_tokens":1000,"output_tokens":100,"cache_read_input_tokens":0,"cache_creation_input_tokens":0}]}}}\n'
  } > "$d/$sid.jsonl"
fi
IT='{"type":"message","input_tokens":5,"output_tokens":1},{"type":"advisor_message","model":"claude-fable-5-1","input_tokens":1000,"output_tokens":100,"cache_read_input_tokens":0,"cache_creation_input_tokens":0}'
OPUS='"claude-opus-5-5":{"inputTokens":50,"outputTokens":10,"cacheReadInputTokens":0,"cacheCreationInputTokens":0,"costUSD":0.03}'
FABLE='"claude-fable-5-1":{"inputTokens":1000,"outputTokens":100,"cacheReadInputTokens":0,"cacheCreationInputTokens":0,"costUSD":0.02}'
case "$env_mode" in
  incl) TOT=0.05; MU="{$OPUS,$FABLE}" ;;
  excl) TOT=0.03; MU="{$OPUS}" ;;
  same) TOT=0.05; MU='{"claude-fable-5-1":{"inputTokens":1050,"outputTokens":110,"cacheReadInputTokens":0,"cacheCreationInputTokens":0,"costUSD":0.05}}' ;;
  bad)  TOT=0.05; MU='{"claude-opus-5-5":{"inputTokens":50,"outputTokens":10,"costUSD":0.02},"claude-fable-5-1":{"inputTokens":1000,"outputTokens":100,"costUSD":0.02}}' ;;
  nomu) TOT=0.05; MU="" ;;
esac
MUF=""; [ -n "$MU" ] && MUF=",\"modelUsage\":$MU"
printf '{"type":"result","is_error":%s,"result":"%s","session_id":"%s","num_turns":2,"usage":{"input_tokens":5,"output_tokens":1,"iterations":[%s]},"total_cost_usd":%s%s}\n' \
  "$([ "$rc" = 0 ] && echo false || echo true)" "$res" "$sid" "$IT" "$TOT" "$MUF"
exit "$rc"
EOF
cat > "$T/fakebin/timeout" <<'EOF'
#!/bin/bash
[ "${1:-}" = "--kill-after" ] && shift 2
case "${1:-}" in --kill-after=*) shift ;; esac
shift
exec "$@"
EOF
printf '#!/bin/bash\necho subscription\n' > "$T/bin/billing-mode.sh"
printf '#!/bin/bash\nexit 0\n' > "$T/bin/beat.sh"
printf '#!/bin/bash\nexec bash "%s/bin/alert-line.sh" "$@"\n' "$DIR" > "$T/bin/alert-line.sh"
printf '#!/bin/bash\necho "test rules"\n' > "$T/bin/sync-agent-rules.sh"
printf '#!/bin/bash\nexit 0\n' > "$T/bin/iron-law-guard.sh"
chmod +x "$T/fakebin/"* "$T/bin/"*.sh
echo '{}' > "$T/catalog.json"
# fable 1e-5 prompt / 1e-4 completion; opus 1e-6 / 1e-5 (BH-3491's fixture).
cat > "$T/prices.json" <<'EOF'
{"per_token":{"claude-fable-5-1":{"prompt":0.00001,"completion":0.0001,"cache_read":0.000001,"cache_write":0.0000125},
 "claude-opus-5-5":{"prompt":0.000001,"completion":0.00001,"cache_read":0.0000001,"cache_write":0.00000125}}}
EOF

cache() { jq -n --argjson fa "$NOW" --argjson v "$1" '{fetched_at:$fa,values:$v,seeded:{}}' > "$T/state/settings-cache.json"; }

# The `includes` arm of the same-family constant, whatever Task 0 committed:
# the same bin/ with the constant flipped, everything else linked back.
mkdir -p "$T/alt"; cp -a "$DIR/bin" "$T/alt/bin"
for e in "$DIR"/*; do [ "$(basename "$e")" = bin ] || ln -s "$e" "$T/alt/$(basename "$e")"; done
sed -i 's/^_ADV_ENV_SAME_FAMILY=.*/_ADV_ENV_SAME_FAMILY=includes/' "$T/alt/bin/agent-call.sh"
grep -q '^_ADV_ENV_SAME_FAMILY=includes$' "$T/alt/bin/agent-call.sh" && ok || bad "setup: could not flip _ADV_ENV_SAME_FAMILY in the copy"

# run_call <model> [ENV=...] — drives agent-call.sh (AC, default the repo's) for
# the execute stage of project-3 with a fresh ledger.
OUTF="$T/builds/b1/out.txt"
run_call() {
  local m="$1"; shift
  : > "$T/sink"; rm -f "$OUTF"* "$T/builds/b1/cost.csv"; rm -rf "$T/state/lane-gate" "$T/.claude"
  rm -f "$T/state/model-cooldown-"*; rm -f "$T/logs/cost.csv"; : > "$T/logs/cost-source-delta.log"
  ( cd "$T/wt" || exit 1
    export SINK="$T/sink" PATH="$T/fakebin:$PATH" HARNESS="$T" HOME="$T" LANE_REGISTRY="$REG" \
           LADDER_BACKOFF_SECS=0 HUB_BUILD_OK=1 MODEL_PRICES="$T/prices.json" \
           CONTEXT_BUDGETS="$DIR/catalog/context-budgets.json" AUTH_ACCOUNTS_CATALOG="$T/catalog.json" \
           JOBS_URL='' RUNNER_EXECUTE=claude LADDER_TIER2_GROK=0 RUNNER_EXECUTE_FALLBACK=none
    env -u ACCOUNT_ROUTING -u OPENROUTER_API_KEY -u FIREWORKS_API_KEY -u CLAUDE_CODE_OAUTH_TOKEN \
        -u ANTHROPIC_API_KEY -u AGENT_ADVISOR_MODEL -u AGENT_ADVISOR_STAGES -u AGENT_SYSTEM_APPEND \
        -u LANE_GATE_DISABLE -u CLAUDE_CONFIG_DIR -u AGENT_CALL_NO_TOOLS \
        "$@" bash "${AC:-$DIR/bin/agent-call.sh}" execute project-3 "$m" 600 "$OUTF" "hello" >/dev/null 2>&1 )
  echo $?
}
# row <stage> <cols...> — the named columns of the row for that stage, | joined.
row() { local st="$1"; shift; awk -F, -v s="$st" -v c="$*" '$4==s{n=split(c,a," "); o=""; for(i=1;i<=n;i++) o=o (i>1?"|":"") $(a[i]); print o}' "$T/logs/cost.csv"; }
# data rows only: cost_append writes the header into a fresh ledger, and the
# build tee copies it from there.
drows() { awk -F, '$1 != "ts" && NF > 1' "$1" 2>/dev/null | grep -c . || true; }
nrows() { drows "$T/logs/cost.csv"; }
near() { awk -v a="$1" -v b="$2" 'BEGIN{d=a-b; if(d<0)d=-d; exit !(a!="" && d<1e-6)}'; }
sum13() { awk -F, 'NF>13 && $13 ~ /^[0-9.]+$/ {s+=$13} END{printf "%.6f", s}' "$1" 2>/dev/null; }

cache '{"advisor.project-3":"fable"}'

# ── E1 ──────────────────────────────────────────────────────────────────────
echo "--- E1"
RC=$(run_call claude-opus-5-5 FAKE_ENVELOPE=incl)
[ "$RC" = 0 ] && ok || bad "E1 rc=$RC"
grep -q -- '--advisor fable' "$T/sink" && ok || bad "E1 setup: the call did not carry --advisor: $(cat "$T/sink")"
[ "$(nrows)" = 2 ] && ok || bad "E1 want 2 rows: $(cat "$T/logs/cost.csv")"
EX=$(row execute 13 18 19); AD=$(row execute-advisor 6 9 10 11 12 13 18)
near "${EX%%|*}" 0.03 && ok || bad "E1 executor cost_usd must be 0.03 (total 0.05 minus the advisor's 0.02): $EX"
[ "$(cut -d'|' -f2- <<<"$EX")" = "result-net-advisor|0.05" ] && ok || bad "E1 executor row_source|result_usd: $EX"
[ "$(cut -d'|' -f1-5 <<<"$AD")" = "claude-fable-5-1|1000|100|0|0" ] && ok || bad "E1 advisor model/tokens: $AD"
near "$(cut -d'|' -f6 <<<"$AD")" 0.02 && ok || bad "E1 advisor cost_usd must be 0.02: $AD"
[ "$(cut -d'|' -f7 <<<"$AD")" = result-modelusage ] && ok || bad "E1 advisor row_source: $AD"
near "$(sum13 "$T/logs/cost.csv")" 0.05 && ok || bad "E1 executor + advisor must be the envelope total 0.05 once, got $(sum13 "$T/logs/cost.csv")"

# ── E5 ──────────────────────────────────────────────────────────────────────
echo "--- E5"
[ "$(drows "$T/builds/b1/cost.csv")" = 2 ] && ok || bad "E5 the build tee must carry both rows: $(cat "$T/builds/b1/cost.csv" 2>/dev/null)"
near "$(sum13 "$T/builds/b1/cost.csv")" 0.05 && ok || bad "E5 the build cost.csv must sum to 0.05, got $(sum13 "$T/builds/b1/cost.csv")"

# ── E2 ──────────────────────────────────────────────────────────────────────
echo "--- E2"
RC=$(run_call claude-opus-5-5 FAKE_ENVELOPE=excl)
[ "$(nrows)" = 2 ] && ok || bad "E2 want 2 rows: $(cat "$T/logs/cost.csv")"
EX=$(row execute 13 18); AD=$(row execute-advisor 13 18)
near "${EX%%|*}" 0.03 && [ "${EX#*|}" = result ] && ok || bad "E2 executor must stay 0.03 / result: $EX"
near "${AD%%|*}" 0.02 && [ "${AD#*|}" = result ] && ok || bad "E2 advisor must be 0.02 from the iterations / result: $AD"
near "$(sum13 "$T/logs/cost.csv")" 0.05 && ok || bad "E2 each amount once: want 0.05, got $(sum13 "$T/logs/cost.csv")"

# ── E3 ──────────────────────────────────────────────────────────────────────
echo "--- E3"
SAME=$(sed -n 's/^_ADV_ENV_SAME_FAMILY=//p' "$DIR/bin/agent-call.sh")
case "$SAME" in includes|excludes|unverified) ok ;; *) bad "E3 _ADV_ENV_SAME_FAMILY must be includes|excludes|unverified, got '$SAME'" ;; esac
RC=$(run_call claude-fable-5-1 FAKE_ENVELOPE=same)
grep -q -- '--advisor fable' "$T/sink" && ok || bad "E3 setup: Fable main must carry --advisor fable: $(cat "$T/sink")"
EX=$(row execute 13 18); AD=$(row execute-advisor 13 18)
case "$SAME" in
  includes)
    [ "$(nrows)" = 1 ] && near "${EX%%|*}" 0.05 && [ "${EX#*|}" = result-incl-advisor ] && ok \
      || bad "E3 includes: want 1 row 0.05 result-incl-advisor: $(cat "$T/logs/cost.csv")" ;;
  excludes)
    [ "$(nrows)" = 2 ] && near "${EX%%|*}" 0.05 && [ "${EX#*|}" = result ] && [ "${AD#*|}" = result ] && ok \
      || bad "E3 excludes: want today's 2 rows, executor result: $(cat "$T/logs/cost.csv")" ;;
  unverified)
    [ "$(nrows)" = 2 ] && near "${EX%%|*}" 0.05 && [ "${EX#*|}" = result-adv-unverified ] && [ "${AD#*|}" = result ] && ok \
      || bad "E3 unverified: want 2 rows, executor 0.05 result-adv-unverified: $(cat "$T/logs/cost.csv")" ;;
esac
RC=$(AC="$T/alt/bin/agent-call.sh" run_call claude-fable-5-1 FAKE_ENVELOPE=same)
EX=$(row execute 13 18)
[ "$(nrows)" = 1 ] && ok || bad "E3 includes arm: the advisor row must be skipped: $(cat "$T/logs/cost.csv")"
near "${EX%%|*}" 0.05 && [ "${EX#*|}" = result-incl-advisor ] && ok || bad "E3 includes arm: executor 0.05 result-incl-advisor: $EX"

# ── E4 ──────────────────────────────────────────────────────────────────────
echo "--- E4"
for mode in bad nomu; do
  RC=$(run_call claude-opus-5-5 FAKE_ENVELOPE=$mode)
  [ "$RC" = 0 ] && ok || bad "E4 $mode rc=$RC"
  EX=$(row execute 13 18); AD=$(row execute-advisor 13 18)
  near "${EX%%|*}" 0.05 && [ "${EX#*|}" = result-adv-unverified ] && ok || bad "E4 $mode: executor keeps 0.05, result-adv-unverified: $EX"
  near "${AD%%|*}" 0.02 && [ "${AD#*|}" = result ] && ok || bad "E4 $mode: advisor row as before (0.02 result): $AD"
  [ "$(grep -c 'advisor split unreadable' "$T/logs/cost-source-delta.log")" = 1 ] && ok \
    || bad "E4 $mode: want one 'advisor split unreadable' line: $(cat "$T/logs/cost-source-delta.log")"
done

# ── E6 ──────────────────────────────────────────────────────────────────────
echo "--- E6"
RC=$(run_call claude-opus-5-5 FAKE_ENVELOPE=incl FAKE_TRANSCRIPT=adv)
[ "$(nrows)" = 2 ] && ok || bad "E6 want 2 rows: $(cat "$T/logs/cost.csv")"
[ "$(row execute 9 10 18)" = "300|30|transcript" ] && ok || bad "E6 executor from the transcript: $(row execute 9 10 18)"
AD=$(row execute-advisor 13 18)
near "${AD%%|*}" 0.02 && [ "${AD#*|}" = transcript ] && ok || bad "E6 advisor from the transcript 0.02: $AD"
grep -q . <<<"$(awk -F, '$18 ~ /^result/' "$T/logs/cost.csv")" && bad "E6 a result-* row_source appeared: $(cat "$T/logs/cost.csv")" || ok

# ── E7 ──────────────────────────────────────────────────────────────────────
echo "--- E7"
cache '{}'
RC=$(run_call claude-opus-5-5 FAKE_ENVELOPE=incl)
grep -q -- '--advisor' "$T/sink" && bad "E7 setup: advisor off must pass no flag: $(cat "$T/sink")" || ok
[ "$(nrows)" = 1 ] && ok || bad "E7 no advisor: want 1 row: $(cat "$T/logs/cost.csv")"
EX=$(row execute 13 18)
near "${EX%%|*}" 0.05 && [ "${EX#*|}" = result ] && ok || bad "E7 no advisor: executor 0.05 result, no split: $EX"
cache '{"advisor.project-3":"fable"}'
RC=$(run_call claude-opus-5-5 FAKE_ENVELOPE=flaky)
[ "$(grep -c . "$T/sink")" = 2 ] && ok || bad "E7 setup: want the transient retried once in the same call, got $(grep -c . "$T/sink"): $(cat "$T/sink")"
AD2=$(awk -F, '$4=="execute-advisor"' "$T/logs/cost.csv" | tail -1 | awk -F, '{print $13"|"$18}')
[ "${AD2#*|}" = transcript ] && near "${AD2%%|*}" 0.02 && ok \
  || bad "E7 the retry's advisor row must come from its own transcript, not the first attempt's split: $(cat "$T/logs/cost.csv")"

echo "agent-call-advisor-envelope.bh-3602: $PASS pass, $FAIL fail"
[ "$FAIL" = 0 ]
