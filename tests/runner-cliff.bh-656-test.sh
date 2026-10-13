#!/bin/bash
# tests/runner-cliff.bh-656-test.sh — the xAI 200K cliff: warn at it, route
# below it, record it, and price it (BH-656).
#
# THE FAILURE. xAI bills the WHOLE request at 2x once it exceeds 200,000 tokens.
# The hub's alert-triage lane runs at a 676K median context, so the majority of
# its grok calls have been billed double while every cost view in this repo
# priced them flat — and nothing anywhere said the cliff had been crossed. Three
# separate holes, one ticket: no warning, no routing, no correction to the
# arithmetic.
#
# Everything here is DRIVEN, never grepped for source text:
#   A  bin/grok-usage.sh --calls against the ledger fixtures
#   B  cost_price_tokens / cost_model_cliff, extracted by their markers and run
#   C  bin/agent-call.sh ITSELF, with fake grok/claude/codex CLIs on PATH, a
#      scratch $HARNESS and a seeded logs/cost.csv — assertions on the order
#      sink, the cost row's fields, failovers.log, ALERTS.log and the lane log
#   D  bin/cost-rollup.sh's row_cost(), extracted the way unpriced-alert-test
#      extracts it
#   E  bin/update-model-prices.sh run whole against a scratch checkout
#
# Run from anywhere: tests/runner-cliff.bh-656-test.sh   (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
# BH-1941: the script under test resolves its vendor base URL through
# endpoint_url (env, else the registry default); this sandbox composes no
# registry, so the env carries today's URL — the registry default itself.
export ENDPOINT_OPENROUTER=https://openrouter.ai
DIR=$(cd "$(dirname "$0")/.." && pwd)
# BH-1510.1: agent-call reads its ladders from model_routes; this worker-less box carries the resolver's cache of #1507's table.
. "$DIR/tests/lib/model-route-stub.sh" || exit 1
mrs_fixture "$T" testproj otherlane alert-triage
FIX="$DIR/tests/fixtures"
GU="$DIR/bin/grok-usage.sh"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
# ONE clock read for the whole suite (the fixture ledgers are copied, so their
# mtimes are already "now"; this is the determinism pin).
NOW=$(date +%s)
mkdir -p "$T/bin" "$T/fakebin" "$T/logs" "$T/flags" "$T/locks" "$T/state" "$T/catalog"
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }

# The price table sections B and C price against: grok-4.6 at the rates
# catalog/model-prices.json carries today, plus the cliff; claude-opus-5 without
# one, because a runner with no cliff must never be warned about or routed.
cat > "$T/prices.json" <<'EOF'
{"per_token": {
  "grok-4.6": {"prompt": 0.000002, "completion": 0.000006, "cache_read": 5e-7,
               "cache_write": null, "cliff_tokens": 200000},
  "claude-opus-5": {"prompt": 0.000015, "completion": 0.000075,
                    "cache_read": 0.0000015, "cache_write": 0.00001875}
}}
EOF
# The same table WITHOUT the cliff — the box that has not landed the catalog yet.
cat > "$T/prices-nocliff.json" <<'EOF'
{"per_token": {
  "grok-4.6": {"prompt": 0.000002, "completion": 0.000006, "cache_read": 5e-7,
               "cache_write": null},
  "claude-opus-5": {"prompt": 0.000015, "completion": 0.000075}
}}
EOF

# ── A. bin/grok-usage.sh --calls: the per-call series ─────────────────────────
echo "--- A. bin/grok-usage.sh --calls"
ghome() { # ghome <dir-under-T> <fixture> <relative path inside the grok home>
  rm -rf "${T:?}/${1:?}"; mkdir -p "$T/$1/$(dirname "$3")"
  cp "$FIX/$2" "$T/$1/$3"
  echo "$T/$1"
}
HA=$(ghome ga grok-usage-nested-ticks.jsonl sessions/s1/updates.jsonl)
OUT=$(bash "$GU" --calls 0 "$HA"); RC=$?
[ "$RC" = 0 ] && ok || bad "A1 --calls must exit 0 (rc=$RC)"
EXPECT=$'1 120000 3100 41000 900\n2 310500 8200 96000 1400\n3 402118 11003 128044 2011'
[ "$OUT" = "$EXPECT" ] && ok \
  || bad "A1 --calls must print one line per usage record in ledger order, got: $(printf '%s' "$OUT" | tr '\n' '/')"

# A2. nothing to read is NOTHING — never the blank summary line, which a caller
# walking the series would read as a record with no tokens.
HB=$(ghome gb grok-usage-none.jsonl sessions/s2/updates.jsonl)
OUT=$(bash "$GU" --calls 0 "$HB"); RC=$?
[ "$RC" = 0 ] && ok || bad "A2 a usage-free ledger must not fail the caller (rc=$RC)"
[ -z "$OUT" ] && ok || bad "A2 a miss must print NOTHING in --calls mode, got '$OUT'"
OUT=$(bash "$GU" --calls 0 "$T/no-such-home"); RC=$?
[ "$RC" = 0 ] && [ -z "$OUT" ] && ok || bad "A2 a missing grok home must be empty and rc 0 (rc=$RC out='$OUT')"

# A3. the DEFAULT mode is byte-identical — the reader every cost row already
# depends on is not allowed to move while a second mode is added to it.
[ "$(bash "$GU" 0 "$HA")" = "402118 11003 128044 2011 0.905636" ] && ok \
  || bad "A3 default mode changed: '$(bash "$GU" 0 "$HA")'"
[ -z "$(tr -d ' ' <<<"$(bash "$GU" 0 "$HB")")" ] && ok \
  || bad "A3 default mode on a usage-free ledger must still be the blank line"

# ── B. cost_price_tokens + cost_model_cliff ──────────────────────────────────
echo "--- B. cost_price_tokens / cost_model_cliff"
awk '/^# >>> cost_price_tokens/{f=1;next} /^# <<< cost_price_tokens/{exit} f' \
  "$DIR/bin/lib/cost-row.sh" > "$T/bin/price.sh"
[ -s "$T/bin/price.sh" ] && grep -q 'cost_price_tokens()' "$T/bin/price.sh" && ok \
  || bad "B could not extract cost_price_tokens from bin/lib/cost-row.sh — markers missing?"
price() { ( MODEL_PRICES="$T/prices.json"; . "$T/bin/price.sh"; cost_price_tokens "$@" ); }
cliff() { ( MODEL_PRICES="${MP:-$T/prices.json}"; . "$T/bin/price.sh"; cost_model_cliff "$@" ); }

# B1. THE TICKET'S OWN CASE. 300000 in + 10000 out = $0.66 flat; the request is
# past the 200K cliff, so xAI billed $1.32 and the ledger must say so.
[ "$(price grok-4.6 300000 10000 0 0)" = "1.320000" ] && ok \
  || bad "B1 a row past the cliff must price at 2x: got '$(price grok-4.6 300000 10000 0 0)'"
# B2. under the cliff (100000 + 50000 cache_read = 150000): flat, unchanged.
[ "$(price grok-4.6 100000 10000 50000 1000)" = "0.285000" ] && ok \
  || bad "B2 a row under the cliff must be unchanged: got '$(price grok-4.6 100000 10000 50000 1000)'"
# B3. the UNIT is input + cache_read: 150000 + 60000 = 210000, over.
[ "$(price grok-4.6 150000 10000 60000 0)" = "0.780000" ] && ok \
  || bad "B3 cache_read must count toward the cliff: got '$(price grok-4.6 150000 10000 60000 0)'"
# B4. EXACTLY at the cliff is not past it — xAI's word is "exceeding".
[ "$(price grok-4.6 200000 0 0 0)" = "0.400000" ] && ok \
  || bad "B4 a row exactly at the cliff must not double: got '$(price grok-4.6 200000 0 0 0)'"
# B5. a model with no cliff is never doubled, at any size.
[ "$(price claude-opus-5 5000000 0 0 0)" = "75.000000" ] && ok \
  || bad "B5 a model with no cliff must price flat at 5M input: got '$(price claude-opus-5 5000000 0 0 0)'"
# B6. the lookup itself: present, absent, and no table at all.
[ "$(cliff grok-4.6)" = "200000" ] && ok || bad "B6 cost_model_cliff grok-4.6: got '$(cliff grok-4.6)'"
[ -z "$(cliff claude-opus-5)" ] && ok || bad "B6 a model with no cliff must print nothing: got '$(cliff claude-opus-5)'"
[ -z "$(MP="$T/nope.json" cliff grok-4.6)" ] && ok || bad "B6 an unreadable table must print nothing"
[ -z "$(MP="$T/prices-nocliff.json" cliff grok-4.6)" ] && ok \
  || bad "B6 a table without cliff_tokens must print nothing: got '$(MP="$T/prices-nocliff.json" cliff grok-4.6)'"
( MODEL_PRICES="$T/prices.json"; . "$T/bin/price.sh"; cost_model_cliff claude-opus-5 ) && \
  bad "B6 a missing cliff must return nonzero, not 0" || ok

# ── C. the production entry point: bin/agent-call.sh ─────────────────────────
echo "--- C. bin/agent-call.sh (driven)"
# The header the seeded ledger uses is the one the library ships, so this suite
# cannot drift from the writer it is asserting against.
HDR=$( . "$DIR/bin/lib/cost-row.sh" >/dev/null 2>&1; printf '%s' "$COST_ROW_HDR" )
NCOL=$(awk -F, '{print NF}' <<<"$HDR")
# The `note` column by NAME (BH-2303 appended lane_id after it, so it is no
# longer the last one). TEST-CHANGE: the note reads were `col "$NCOL"`.
NOTE_COL=$(awk -F, '{for (i = 1; i <= NF; i++) if ($i == "note") print i}' <<<"$HDR")

cat > "$T/fakebin/grok" <<'EOF'
#!/bin/bash
echo grok >> "$ORDER_SINK"
if [ -n "${GROK_FIXTURE:-}" ]; then
  mkdir -p "$HOME/.grok/sessions/s-run"
  cp "$GROK_FIXTURE" "$HOME/.grok/sessions/s-run/updates.jsonl"
fi
echo "grok answered"
exit "${GROK_EXIT:-0}"
EOF
cat > "$T/fakebin/claude" <<'EOF'
#!/bin/bash
echo claude >> "$ORDER_SINK"
case "${CLAUDE_RESULT:-fail}" in
  fail) echo "usage limit" >&2; exit 1 ;;
esac
printf '{"result":"claude answered","session_id":"s-fake"}\n'
EOF
cat > "$T/fakebin/codex" <<'EOF'
#!/bin/bash
provider=codex
for arg in "$@"; do
  case "$arg" in
    *model_provider*openrouter*) provider=openrouter ;;
    *model_provider*fireworks*)  provider=fireworks ;;
  esac
done
echo "$provider" >> "$ORDER_SINK"
echo "$provider answered"
EOF
cat > "$T/fakebin/timeout" <<'EOF'
#!/bin/bash
[ "${1:-}" = "--kill-after" ] && shift 2
case "${1:-}" in --kill-after=*) shift ;; esac
shift
exec "$@"
EOF
printf '#!/bin/bash\necho subscription\n' > "$T/bin/billing-mode.sh"
# The tier-3/3b beat: recorded rather than sent, so "a cliff-routed descent does
# not page" is an assertion on an artifact.
cat > "$T/bin/beat.sh" <<'EOF'
#!/bin/bash
printf '%s\n' "$*" >> "$BEAT_SINK"
exit 0
EOF
printf '#!/bin/bash\necho "test rules"\n' > "$T/bin/sync-agent-rules.sh"
chmod +x "$T/fakebin/"* "$T/bin/"*

# A manifest whose eval/testproj lane asks for routing, and one that does not.
cat > "$T/cb-on.json" <<'EOF'
{"lanes": [
  {"lane":"cliff-fixture","stage":"eval","project":"testproj","job":"fixture",
   "target_tokens":60000,"ceiling_tokens":200000,"cliff_route":true},
  {"lane":"other-project","stage":"eval","project":"otherproj","job":"fixture",
   "target_tokens":60000,"ceiling_tokens":200000,"cliff_route":true}
]}
EOF
cat > "$T/cb-off.json" <<'EOF'
{"lanes": [
  {"lane":"cliff-fixture","stage":"eval","project":"testproj","job":"fixture",
   "target_tokens":60000,"ceiling_tokens":200000}
]}
EOF

fresh_ledger() { printf '%s\n' "$HDR" > "$T/logs/cost.csv"; }
seed_row() { # seed_row <stage> <project> <rc> <input_toks> <cache_read>
  local r n
  r="2026-09-18T00:00:00Z,box,$2,$1,claude,claude-opus-5,$3,10,$4,100,$5,0,0.10,subscription,fp,acct,sess,transcript,,,,,"
  n=$(awk -F, '{print NF}' <<<"$r")
  while [ "$n" -lt "$NCOL" ]; do r="$r,"; n=$((n+1)); done
  printf '%s\n' "$r" >> "$T/logs/cost.csv"
}
seed_n() { # seed_n <count> <stage> <project> <rc> <input> <cache_read>
  local i=0; while [ "$i" -lt "$1" ]; do seed_row "$2" "$3" "$4" "$5" "$6"; i=$((i+1)); done
}
col() { tail -1 "$T/logs/cost.csv" | awk -F, -v c="$1" '{print $c}'; }
# THE NOTE COLUMN IS SHARED SINCE BH-1020. cost_row_price appends `UNPRICED:*`
# to it, joined with ';', when a billed row could not be priced — and every fake
# CLI below reports no usage, so every rc-0 row here now carries one. The cliff
# note is still the FIRST ';'-separated part, so these assertions read that part
# rather than the whole field: `cliff_note` must be exactly the decision, and
# an unrouted row must carry no cliff note at all.
cliff_note() { col "$NOTE_COL" | cut -d';' -f1; }
has_cliff_note() { case "$(col "$NOTE_COL")" in *cliff-routed*) return 0 ;; *) return 1 ;; esac; }
reset_logs() {
  : > "$T/logs/ALERTS.log"; : > "$T/logs/failovers.log"; : > "$T/order"; : > "$T/beats"
  rm -f "$T/logs/testproj.log" "$T/logs/alert-triage.log" "$T/flags/"alerted-* "$T/out.txt"
}

drive() { # drive <stage> <project> [env assignments...] ; echoes agent-call's rc
  local st="$1" pj="$2"; shift 2
  rm -rf "${T:?}/.grok/sessions"
  ( unset OPENROUTER_API_KEY FIREWORKS_API_KEY XAI_API_KEY GROK_CODE_XAI_API_KEY \
          OPENAI_API_KEY CODEX_API_KEY GEMINI_API_KEY ANTHROPIC_API_KEY
    export HOME="$T" HARNESS="$T" PATH="$T/fakebin:$PATH" \
           MODEL_PRICES="$T/prices.json" CONTEXT_BUDGETS="$DIR/catalog/context-budgets.json" \
           ORDER_SINK="$T/order" BEAT_SINK="$T/beats" LADDER_BACKOFF_SECS=0 \
           GROK_FIXTURE="" GROK_EXIT=0 CLAUDE_RESULT=fail "$@"
    bash "$DIR/bin/agent-call.sh" "$st" "$pj" claude-fable-5-1 60 "$T/out.txt" "hello" \
      >/dev/null 2>&1 )
  echo $?
}

# C1. THE WARN. A grok call whose ledger crosses the cliff writes ONE line to
# the lane log naming the call number and the context of that call. The ledger
# fixture is cumulative (161000 -> 406500 -> 530162), so call 2 is the crossing
# at 245500 and calls 1 and 3 are not.
fresh_ledger; reset_logs
RC=$(drive eval testproj RUNNER_EVAL=grok RUNNER_EVAL_FALLBACK=grok \
     GROK_FIXTURE="$FIX/grok-usage-nested-ticks.jsonl")
[ "$RC" = 0 ] && ok || bad "C1 the driven grok call failed (rc=$RC)"
[ "$(grep -c 'CLIFF: eval/testproj grok call 2 context 245500' "$T/logs/testproj.log" 2>/dev/null)" = 1 ] \
  && ok || bad "C1 one warn line naming call 2 and its context: got '$(cat "$T/logs/testproj.log" 2>/dev/null)'"
[ "$(grep -c 'CLIFF:' "$T/logs/testproj.log")" = 1 ] \
  && ok || bad "C1 exactly one line per crossing session: $(grep -c 'CLIFF:' "$T/logs/testproj.log")"
grep -qE 'HANDLED|ESCALATED|NOISE|PARKED' "$T/logs/testproj.log" \
  && bad "C1 the warn line carries a token bin/alert-digest.sh counts as a verdict" || ok
grep -q 'billed 2x' "$T/logs/testproj.log" && ok || bad "C1 the line must say what the crossing costs"
# a second session appends a second line rather than replacing the first
RC=$(drive eval testproj RUNNER_EVAL=grok RUNNER_EVAL_FALLBACK=grok \
     GROK_FIXTURE="$FIX/grok-usage-nested-ticks.jsonl")
[ "$(grep -c 'CLIFF:' "$T/logs/testproj.log")" = 2 ] \
  && ok || bad "C1 a second crossing session must add a second line: $(grep -c 'CLIFF:' "$T/logs/testproj.log")"
# ...and a ledger that never crosses says nothing.
rm -f "$T/logs/testproj.log"
RC=$(drive eval testproj RUNNER_EVAL=grok RUNNER_EVAL_FALLBACK=grok \
     GROK_FIXTURE="$FIX/grok-usage-no-ticks.jsonl")
[ ! -s "$T/logs/testproj.log" ] && ok \
  || bad "C1 a session that never crosses must write no line: $(cat "$T/logs/testproj.log")"

# C2. THE ROUTE. Routing on, the lane's recent history past the cliff: grok is
# never called, the ladder descends to the configured fallback, and the row the
# serving rung writes carries the decision.
fresh_ledger; seed_n 10 eval testproj 0 676000 0; reset_logs
RC=$(drive eval testproj RUNNER_CLIFF_ROUTE=1 RUNNER_EVAL=grok RUNNER_EVAL_FALLBACK=claude \
     CLAUDE_RESULT=success)
[ "$RC" = 0 ] && ok || bad "C2 the fallback answered but the stage exited $RC"
[ "$(paste -sd, "$T/order")" = "claude" ] \
  && ok || bad "C2 grok must not be called at all, got order: $(paste -sd, "$T/order")"
grep -q 'claude answered' "$T/out.txt" && ok || bad "C2 \$OUT must hold the serving lane's answer: $(cat "$T/out.txt")"
[ "$(col 5)" = claude ] && ok || bad "C2 the row must be the serving runner's: got '$(col 5)'"
[ "$(cliff_note)" = "cliff-routed:grok:676000>200000" ] && ok \
  || bad "C2 the note column must record the decision: got '$(col "$NOTE_COL")'"
[ "$(grep -c 'CLIFF ROUTE' "$T/logs/failovers.log")" = 1 ] \
  && ok || bad "C2 one CLIFF ROUTE line in failovers.log: $(grep -c 'CLIFF ROUTE' "$T/logs/failovers.log")"
grep -q ',grok,' "$T/logs/cost.csv" && bad "C2 a routed grok attempt must write NO cost row" || ok
[ ! -s "$T/beats" ] && ok || bad "C2 a cliff-routed descent must not beat: $(cat "$T/beats")"
[ "$(grep -c 'tier-3' "$T/logs/ALERTS.log")" = 0 ] \
  && ok || bad "C2 a cliff-routed descent must not raise a survival-lane ALERT"
grep -q 'STUCK' "$T/logs/ALERTS.log" && bad "C2 a working failover must not claim the stage stuck" || ok

# C3. THE KILL SWITCHES. Same seed, routing off in each of its three forms.
for OFF in "RUNNER_CLIFF_ROUTE=0" "RUNNER_CLIFF_ROUTE=yes"; do
  fresh_ledger; seed_n 10 eval testproj 0 676000 0; reset_logs
  RC=$(drive eval testproj "$OFF" RUNNER_EVAL=grok RUNNER_EVAL_FALLBACK=grok)
  grep -q '^grok$' "$T/order" && ok || bad "C3 $OFF must leave grok running: $(paste -sd, "$T/order")"
  [ "$(col 5)" = grok ] && ok || bad "C3 $OFF the row must be grok's: got '$(col 5)'"
  has_cliff_note && bad "C3 $OFF an unrouted row must carry NO cliff note: got '$(col "$NOTE_COL")'" || ok
done
fresh_ledger; seed_n 10 eval testproj 0 676000 0; reset_logs
touch "$T/flags/cliff-route-off"
RC=$(drive eval testproj RUNNER_CLIFF_ROUTE=1 RUNNER_EVAL=grok RUNNER_EVAL_FALLBACK=grok)
grep -q '^grok$' "$T/order" && ok || bad "C3 flags/cliff-route-off must beat RUNNER_CLIFF_ROUTE=1"
rm -f "$T/flags/cliff-route-off"

# C4. THE LANE DEFAULT. With the env knob unset the manifest decides, on the
# same specificity ladder the lane's other bounds use.
fresh_ledger; seed_n 10 eval testproj 0 676000 0; reset_logs
RC=$(drive eval testproj RUNNER_EVAL=grok RUNNER_EVAL_FALLBACK=grok CONTEXT_BUDGETS="$T/cb-on.json")
grep -q '^grok$' "$T/order" && bad "C4 a lane declaring cliff_route:true must route" || ok
[ "$(grep -c 'CLIFF ROUTE' "$T/logs/failovers.log")" = 1 ] && ok || bad "C4 the routed lane must log the route"
fresh_ledger; seed_n 10 eval testproj 0 676000 0; reset_logs
RC=$(drive eval testproj RUNNER_EVAL=grok RUNNER_EVAL_FALLBACK=grok CONTEXT_BUDGETS="$T/cb-off.json")
grep -q '^grok$' "$T/order" && ok || bad "C4 a lane without the key must NOT route"
# ...and a sibling lane's opt-in does not leak onto this project.
fresh_ledger; seed_n 10 eval otherlane 0 676000 0; reset_logs
RC=$(drive eval otherlane RUNNER_EVAL=grok RUNNER_EVAL_FALLBACK=grok CONTEXT_BUDGETS="$T/cb-on.json")
grep -q '^grok$' "$T/order" && ok || bad "C4 another project's cliff_route must not route this one"
# the REAL catalog: alert-triage is the lane the ticket names.
fresh_ledger; seed_n 10 triage alert-triage 0 676000 0; reset_logs
RC=$(drive triage alert-triage RUNNER_TRIAGE=grok RUNNER_TRIAGE_FALLBACK=grok)
grep -q '^grok$' "$T/order" \
  && bad "C4 catalog/context-budgets.json must route alert-triage by default" || ok

# C5. THE NEGATIVES. Every one of these must leave grok running.
neg() { # neg <label> <seed-count> <stage> <project> <rc> <input> <cache_read>
  fresh_ledger; seed_n "$2" "$3" "$4" "$5" "$6" "$7"; reset_logs
  RC=$(drive eval testproj RUNNER_CLIFF_ROUTE=1 RUNNER_EVAL=grok RUNNER_EVAL_FALLBACK=grok)
  grep -q '^grok$' "$T/order" && ok || bad "C5 $1 must not route: $(paste -sd, "$T/order")"
}
neg "two samples is not a history"        2  eval testproj 0 676000 0
neg "failed rows are not this lane's cost" 10 eval testproj 1 676000 0
neg "another project's rows"               10 eval otherproj 0 676000 0
neg "another stage's rows"                 10 plan testproj 0 676000 0
neg "a projection exactly at the cliff"    10 eval testproj 0 200000 0
neg "no history at all"                    0  eval testproj 0 676000 0
# blank token counts are ABSENT, not zero — and not a sample either.
fresh_ledger; seed_n 10 eval testproj 0 "" ""; reset_logs
RC=$(drive eval testproj RUNNER_CLIFF_ROUTE=1 RUNNER_EVAL=grok RUNNER_EVAL_FALLBACK=grok)
grep -q '^grok$' "$T/order" && ok || bad "C5 blank token counts must not be read as a projection"
# THE UNIT IS input_toks + cache_read, the unit every ceiling in
# catalog/context-budgets.json is stated in. 150000 input alone is under the
# cliff; with 100000 of cache_read the lane is at 250000 and must route. A
# projection on input_toks alone would run this call at 2x and call it fine.
fresh_ledger; seed_n 10 eval testproj 0 150000 100000; reset_logs
RC=$(drive eval testproj RUNNER_CLIFF_ROUTE=1 RUNNER_EVAL=grok RUNNER_EVAL_FALLBACK=grok)
grep -q '^grok$' "$T/order" && bad "C5 cache_read must count toward the projection" || ok
grep -q 'cliff-routed:grok:250000>200000' "$T/logs/failovers.log" "$T/logs/cost.csv" 2>/dev/null \
  || grep -q 'projected context 250000' "$T/logs/failovers.log" \
  && ok || bad "C5 the projection must be the summed unit: $(grep 'CLIFF ROUTE' "$T/logs/failovers.log")"

# C6. THE TIER-2 RUNG. The other way a grok call is issued: the primary failed
# and the ladder reached Grok. A cliff route there is still routine failover.
fresh_ledger; seed_n 10 eval testproj 0 676000 0; reset_logs
RC=$(drive eval testproj RUNNER_CLIFF_ROUTE=1 RUNNER_EVAL=claude OPENROUTER_API_KEY=test)
[ "$(paste -sd, "$T/order")" = "claude,claude,openrouter" ] \
  && ok || bad "C6 expected claude,claude,openrouter, got: $(paste -sd, "$T/order")"
[ "$(col 5)" = openrouter ] && ok || bad "C6 the survival lane must serve: got '$(col 5)'"
[ "$(cliff_note)" = "cliff-routed:grok:676000>200000" ] && ok \
  || bad "C6 the serving row must carry the note: got '$(col "$NOTE_COL")'"
grep -q 'tier-2 Grok cliff-routed (rc=79)' "$T/logs/failovers.log" && ok \
  || bad "C6 tier-2 must say it routed rather than that Grok failed: $(grep tier-2 "$T/logs/failovers.log")"
grep -q 'cliff-routed onto the OpenRouter survival lane' "$T/logs/failovers.log" && ok \
  || bad "C6 the tier-3 descent must be logged as routine failover"
[ ! -s "$T/beats" ] && ok || bad "C6 a cliff-routed survival descent must not beat: $(cat "$T/beats")"
[ "$(grep -c 'tier-3' "$T/logs/ALERTS.log")" = 0 ] \
  && ok || bad "C6 no tier-3 ALERT on a cliff route: $(grep 'tier-3' "$T/logs/ALERTS.log")"

# C7. A RUNNER WITH NO CLIFF is never routed and never warned, however big the
# lane runs — the whole mechanism is keyed on the table declaring one.
fresh_ledger; seed_n 10 eval testproj 0 676000 0; reset_logs
RC=$(drive eval testproj RUNNER_CLIFF_ROUTE=1 RUNNER_EVAL=grok RUNNER_EVAL_FALLBACK=grok \
     MODEL_PRICES="$T/prices-nocliff.json" GROK_FIXTURE="$FIX/grok-usage-nested-ticks.jsonl")
grep -q '^grok$' "$T/order" && ok || bad "C7 a model with no cliff must not be routed"
[ ! -s "$T/logs/testproj.log" ] && ok \
  || bad "C7 a model with no cliff must not be warned about: $(cat "$T/logs/testproj.log")"
# TEST-CHANGE BH-3986: a grok row's model is grok's, not the argv model, so
# its note now carries exactly `requested_model=claude-fable-5-1`. Still no
# cliff token: the whole note is pinned, so any cliff-routed marker fails.
[ "$(col "$NOTE_COL")" = "requested_model=claude-fable-5-1" ] && ok || bad "C7 that row must carry no cliff note, only requested_model=: got '$(col "$NOTE_COL")'"

# C8. ROUTED WITH NOTHING BELOW. The stage did not fail — it was routed and
# there was no lane to route to, which is a different sentence and a different
# alert from "every available lane failed". (grok as its own configured
# fallback is the shape that leaves no rung below it: tier-2 is skipped because
# grok IS the primary, the configured-fallback rung skips grok by name, and
# drive() unsets every survival-lane key.)
fresh_ledger; seed_n 10 eval testproj 0 676000 0; reset_logs
RC=$(drive eval testproj RUNNER_CLIFF_ROUTE=1 RUNNER_EVAL=grok RUNNER_EVAL_FALLBACK=grok)
[ "$RC" = 79 ] && ok || bad "C8 a route with nothing below must exit 79, got $RC"
[ "$(grep -c 'STUCK' "$T/logs/ALERTS.log")" = 1 ] \
  && ok || bad "C8 one STUCK line naming the route: $(cat "$T/logs/ALERTS.log")"
grep -q 'DEAD' "$T/logs/ALERTS.log" && bad "C8 a cliff route is not 'every lane failed'" || ok
grep -q 'RUNNER_EVAL_FALLBACK' "$T/logs/ALERTS.log" && ok \
  || bad "C8 the STUCK line must name the knob that fixes it: $(grep STUCK "$T/logs/ALERTS.log")"

# ── D. bin/cost-rollup.sh row_cost ───────────────────────────────────────────
echo "--- D. cost-rollup.sh row_cost"
python3 - "$DIR/bin/cost-rollup.sh" "$T/rowcost.py" <<'EXTRACT'
import sys
src = open(sys.argv[1]).read()
i = src.index("def row_cost(r):")
body = src[i:src.index("# per-build exact attribution", i)]
out = ["import json, sys\nprices = json.load(open(sys.argv[1]))\n", body,
       "print('%.6f' % row_cost(json.loads(sys.argv[2])))\n"]
open(sys.argv[2], "w").write("\n".join(out))
EXTRACT
[ -s "$T/rowcost.py" ] && grep -q 'def row_cost' "$T/rowcost.py" && ok \
  || bad "D could not extract row_cost from bin/cost-rollup.sh — markers moved?"
cat > "$T/rollup-prices.json" <<'EOF'
{"grok-4.6": {"prompt": 0.000002, "completion": 0.000006, "cache_read": 5e-7,
              "cache_write": null, "cliff_tokens": 200000},
 "grok-bool": {"prompt": 0.000002, "completion": 0.000006, "cliff_tokens": true}}
EOF
rc() { python3 "$T/rowcost.py" "$T/rollup-prices.json" "$1" 2>/dev/null; }
[ "$(rc '{"model":"grok-4.6","cost_usd":"","input_toks":"300000","output_toks":"10000","cache_read":"0"}')" = "1.320000" ] \
  && ok || bad "D1 the audit must price a past-cliff row at 2x: got '$(rc '{"model":"grok-4.6","cost_usd":"","input_toks":"300000","output_toks":"10000","cache_read":"0"}')'"
[ "$(rc '{"model":"grok-4.6","cost_usd":"0.70","input_toks":"300000","output_toks":"10000","cache_read":"0"}')" = "0.700000" ] \
  && ok || bad "D2 a vendor-reported cost_usd is authoritative and never re-doubled"
[ "$(rc '{"model":"grok-4.6","cost_usd":"","input_toks":"100000","output_toks":"10000","cache_read":"0"}')" = "0.260000" ] \
  && ok || bad "D3 a row under the cliff must be unchanged"
[ "$(rc '{"model":"grok-bool","cost_usd":"","input_toks":"300000","output_toks":"10000","cache_read":"0"}')" = "0.660000" ] \
  && ok || bad "D4 a non-numeric cliff_tokens must be ignored, not read as 1"

# ── E. bin/update-model-prices.sh carries the cliff into the live table ──────
echo "--- E. the daily refresh"
command -v git >/dev/null || { echo "git missing — skipping E"; }
if command -v git >/dev/null; then
  mkdir -p "$T/e/state" "$T/e/logs" "$T/e/bin" "$T/e/flags"
  python3 - "$T/e/openrouter.json" <<'PY'
import json, sys
slugs = ["anthropic/claude-fable-5.1", "anthropic/claude-opus-5",
         "anthropic/claude-sonnet-5", "anthropic/claude-haiku-4.5",
         "openai/gpt-6-astra", "x-ai/grok-4.6"]
data = [{"id": s, "pricing": {"prompt": str(0.00001 * (n + 1)),
         "completion": str(0.00005 * (n + 1)),
         "input_cache_read": str(0.000001 * (n + 1)),
         "input_cache_write": str(0.0000125 * (n + 1))}} for n, s in enumerate(slugs)]
json.dump({"data": data}, open(sys.argv[1], "w"))
PY
  cat > "$T/fakebin/curl" <<'SH'
#!/bin/bash
cat "$CURL_BODY"
SH
  cat > "$T/e/bin/lane-alert.sh" <<'SH'
#!/bin/bash
printf '%s\n' "$*" >> "$LANE_SINK"
exit 0
SH
  chmod +x "$T/fakebin/curl" "$T/e/bin/lane-alert.sh"
  git init -q --bare "$T/e/origin"
  git clone -q "$T/e/origin" "$T/e/ck" 2>/dev/null
  git -C "$T/e/ck" config user.email t@t; git -C "$T/e/ck" config user.name t
  mkdir -p "$T/e/ck/catalog"
  printf '{"updated_at":"2026-01-01T00:00:00Z","per_token":{}}\n' > "$T/e/ck/catalog/model-prices.json"
  # BH-1510.4: the slug map is the catalog's only (the script carries no copy).
  cp "$DIR/catalog/model-slugs.json" "$T/e/ck/catalog/model-slugs.json"
  git -C "$T/e/ck" add -A >/dev/null; git -C "$T/e/ck" commit -qm seed
  git -C "$T/e/ck" branch -M main 2>/dev/null; git -C "$T/e/ck" push -q origin main
  run_refresh() {
    ( export HARNESS="$T/e" HARNESS_CHECKOUT="$T/e/ck" PATH="$T/fakebin:$PATH" \
             CURL_BODY="$T/e/openrouter.json" LANE_SINK="$T/e/lane.txt"
      bash "$DIR/bin/update-model-prices.sh" ) >/dev/null 2>&1
  }
  : > "$T/e/lane.txt"
  run_refresh
  # Land the live table as the committed fallback, then DECLARE the cliff on it
  # — the only place the cliff is ever authored.
  jq '.per_token["grok-4.6"].cliff_tokens = 200000
      | .per_token["x-ai/grok-4.6"].cliff_tokens = 200000' \
     "$T/e/state/model-prices.json" > "$T/e/ck/catalog/model-prices.json"
  git -C "$T/e/ck" add -A >/dev/null; git -C "$T/e/ck" commit -qm "land the table"
  git -C "$T/e/ck" push -q origin main
  : > "$T/e/lane.txt"
  run_refresh
  [ "$(jq -r '.per_token["grok-4.6"].cliff_tokens' "$T/e/state/model-prices.json")" = "200000" ] \
    && ok || bad "E the refresh must carry cliff_tokens into the live table: got '$(jq -r '.per_token["grok-4.6"].cliff_tokens' "$T/e/state/model-prices.json")'"
  [ "$(jq -r '.per_token["x-ai/grok-4.6"].cliff_tokens' "$T/e/state/model-prices.json")" = "200000" ] \
    && ok || bad "E both grok keys must carry the cliff"
  [ "$(jq -r '.per_token["claude-opus-5"] | has("cliff_tokens")' "$T/e/state/model-prices.json")" = "false" ] \
    && ok || bad "E a model the catalog gives no cliff must not gain one"
  # BH-3990: the catalog-stale check resolves its id on an in-threshold run;
  # lane-alert.sh --resolve on an id that is not open sends nothing.
  [ -z "$(grep -v -- '^--resolve ' "$T/e/lane.txt")" ] && ok \
    || bad "E a carried cliff must not make the catalog read as behind: $(cat "$T/e/lane.txt")"
  [ -z "$(git -C "$T/e/ck" status --porcelain --untracked-files=no)" ] && ok \
    || bad "E the refresh must leave the checkout clean: $(git -C "$T/e/ck" status --porcelain)"
fi

echo "runner-cliff.bh-656-test: $PASS pass, $FAIL fail"
[ "$FAIL" -eq 0 ]
