#!/bin/bash
# tests/agent-call-canary-unbilled.bh-3222-test.sh — BH-3222: a failed canary
# that bought nothing is `row_source=unbilled`, and a caller can keep its
# failed stage off the page.
#
# Drives the REAL bin/agent-call.sh with a fake `claude` on PATH. The dead-login
# fixture is what the CLI does on an expired login: rc 1, no usage envelope.
#
#  A1 AGENT_CALL_DEAD_ALERT=0: no DEAD line in ALERTS.log, one in failovers.log.
#  A2 flag unset: `DEAD: every available lane failed` in ALERTS.log (as before).
#  A3 stage canary, rc 1, 0 tokens: cost row column 18 = unbilled.
#  A4 stage plan, same fake: column 18 = unbilled, column 13 = 0.
# TEST-CHANGE (BH-6175): A4 pinned `none` for a non-canary failure. BH-6175
#  widens the rule to every stage, so a failed call that bought nothing writes
#  a priced $0 row, not a blank (D1 NULL) one.
#  A5 stage canary, rc 0 with a usage envelope: column 18 != unbilled.
#  A6 stage canary, rc 1 but the envelope reports input tokens: != unbilled.
#
# Mutation (run by hand once): drop the unbilled block before ROW= in
# agent-call.sh and A3 goes red; drop the AGENT_CALL_DEAD_ALERT branch and A1
# goes red.
# Run: HARNESS_TEST_SANDBOX=1 bash tests/agent-call-canary-unbilled.bh-3222-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
. "$(dirname "$0")/lib/verdict-fixture.sh" || exit 1
vpf_export || exit 1
. "$(dirname "$0")/lib/model-route-stub.sh" || exit 1
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

mkdir -p "$T/bin" "$T/fakebin" "$T/flags" "$T/locks" "$T/logs" "$T/state"
mrs_fixture "$T" fleet
cat > "$T/fakebin/claude" <<'EOF'
#!/bin/bash
case " $* " in *" --help "*) echo "  --resume"; exit 0 ;; esac
cat >/dev/null
case "${FAKE_MODE:-dead}" in
  dead) echo "Invalid API key · Please run /login"; exit 1 ;;
  okusage) echo '{"result":"ok","is_error":false,"total_cost_usd":0.0001,"usage":{"input_tokens":5,"output_tokens":1,"cache_read_input_tokens":0,"cache_creation_input_tokens":0}}'; exit 0 ;;
  errusage) echo '{"result":"overloaded","is_error":true,"usage":{"input_tokens":7,"output_tokens":0,"cache_read_input_tokens":0,"cache_creation_input_tokens":0}}'; exit 1 ;;
esac
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
printf '#!/bin/bash\necho rules\n' > "$T/bin/sync-agent-rules.sh"
chmod +x "$T/fakebin/"* "$T/bin/"*

# call <stage> <out-name> [VAR=val ...] — one whole agent-call run on claude
# only, logs reset first. Prints the exit code.
call() {
  local stage="$1" out="$2"; shift 2
  : > "$T/logs/ALERTS.log"; : > "$T/logs/failovers.log"; rm -f "$T/logs/cost.csv"
  ( export PATH="$T/fakebin:$PATH" HARNESS="$T" HOME="$T" \
      OPENROUTER_API_KEY= FIREWORKS_API_KEY= ACCOUNT_ROUTING=0 \
      LADDER_BACKOFF_SECS=0 LADDER_TIER2_GROK=0 AGENT_CALL_LEDGER=0 \
      AGENT_CALL_RUNNERS=claude AGENT_CALL_LANE=oauth-refresh "$@"
    unset AGENT_CALL_TICKET AGENT_CALL_PR COST_RUN_ID
    cd / && bash "$DIR/bin/agent-call.sh" "$stage" fleet m-auth 60 "$T/$out" 'reply ok' \
      </dev/null >/dev/null 2>&1 )
  echo $?
}
# col18 — row_source of the last data row in cost.csv (empty when none).
col18() { tail -n +2 "$T/logs/cost.csv" 2>/dev/null | tail -1 | awk -F, '{print $18}'; }
rows() { tail -n +2 "$T/logs/cost.csv" 2>/dev/null | grep -c . ; }

# A1 — the caller routes the DEAD line off the page
RC=$(call canary a1.txt AGENT_CALL_DEAD_ALERT=0)
[ "$RC" -ne 0 ] && ok || bad "A1 a dead login must still exit non-zero (rc=$RC)"
grep -q 'DEAD' "$T/logs/ALERTS.log" && bad "A1 DEAD paged with AGENT_CALL_DEAD_ALERT=0: $(cat "$T/logs/ALERTS.log")" || ok
grep -q 'canary DEAD: every available lane failed' "$T/logs/failovers.log" && ok \
  || bad "A1 the DEAD line must land in failovers.log (got: $(grep DEAD "$T/logs/failovers.log"))"

# A2 — every other caller pages exactly as before
RC=$(call canary a2.txt)
[ "$RC" -ne 0 ] && ok || bad "A2 rc=$RC"
grep -q 'canary DEAD: every available lane failed' "$T/logs/ALERTS.log" && ok \
  || bad "A2 flag unset must still page DEAD (ALERTS: $(cat "$T/logs/ALERTS.log"))"
grep -q 'DEAD: every available lane failed' "$T/logs/failovers.log" && bad "A2 DEAD also went to failovers.log" || ok

# A3 — failed canary, no usage → unbilled
RC=$(call canary a3.txt)
[ "$(rows)" = 1 ] && ok || bad "A3 want 1 cost row, got $(rows)"
[ "$(col18)" = unbilled ] && ok || bad "A3 row_source '$(col18)' want unbilled"
r=$(tail -1 "$T/logs/cost.csv")
[ "$(awk -F, '{print $4","$7}' <<<"$r")" = "canary,1" ] && ok || bad "A3 row is not the canary rc 1 row: $r"

# A4 — same fake on stage plan: unbilled too since BH-6175, priced $0
RC=$(call plan a4.txt)
[ "$(col18)" = unbilled ] && ok || bad "A4 stage plan row_source '$(col18)' want unbilled"
[ "$(tail -n +2 "$T/logs/cost.csv" | tail -1 | awk -F, '{print $13}')" = 0 ] && ok || bad "A4 stage plan cost_usd is not 0"

# A5 — canary that worked
RC=$(call canary a5.txt FAKE_MODE=okusage)
[ "$RC" = 0 ] && ok || bad "A5 rc=$RC want 0"
[ -n "$(col18)" ] && [ "$(col18)" != unbilled ] && ok || bad "A5 row_source '$(col18)' must be set and not unbilled"

# A6 — canary that failed but reports usage
RC=$(call canary a6.txt FAKE_MODE=errusage)
[ "$(rows)" -ge 1 ] && ok || bad "A6 no cost row"
[ -n "$(col18)" ] && [ "$(col18)" != unbilled ] && ok || bad "A6 row_source '$(col18)' must not be unbilled with input tokens"

echo "agent-call-canary-unbilled: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
