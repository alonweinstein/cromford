#!/bin/bash
# tests/agent-call-pin-alias.bh-3559-test.sh — BH-3559: a pinned project's claude
# rung resolves on its OWNING box when the box's live token is labelled with an
# ALIAS of the pin (catalog/account-aliases.json), and a pin that resolves nowhere
# raises ONE deduped warn lane-alert naming the box and label.
#
#   A1 token file present -> pinned on the file token
#   A2 no file, live fp labelled claude:project-3-dedicated, alias own:project-3 -> pinned
#   A3 negatives: another pin's alias, unmapped (project-6), alias "unknown",
#      malformed alias file, missing alias file -> no claude call
#   A4 neither -> the rung descends to grok, the refusal line is unchanged
#   A5 three refusals -> exactly one warn lane-alert naming box and label
#   A6 the 6 h window (and the knob) re-arms the alert
#   A7 no token string anywhere
#   A8 a pinned success after an alert resolves it once and removes the stamp
#   A9 the shipped catalog parses and every label passes the label rule
#
# DRIVEN, NOT GREPPED: bin/agent-call.sh runs for real against a scratch HARNESS.
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
. "$DIR/tests/lib/model-route-stub.sh" || exit 1
mrs_fixture "$T" project-3
mkdir -p "$T/bin" "$T/bin/lib" "$T/fakebin" "$T/flags" "$T/locks" "$T/logs" "$T/state" "$T/env/accounts.d"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

PROJECT_3_TOK="sk-ant-oat01-FIXTURE-project-3-box-token"
MK_TOK="sk-ant-oat01-FIXTURE-project-6-token"
fp8()  { printf '%s' "$1" | sha256sum | cut -c1-8; }
fp12() { printf '%s' "$1" | sha256sum | cut -c1-12; }
PROJECT_3_FP=$(fp8 "$PROJECT_3_TOK")
ALIASES="$T/aliases.json"
ALERT_SINK="$T/alert-sink"
STAMP_F="$T/state/account-pin/project-3.alerted"
ALERT_ID="account-pin-box-project-3-1-project-3"

cat > "$T/fakebin/claude" <<'EOF'
#!/bin/bash
case " $* " in *" --help "*) printf -- '  --session-id <uuid>\n'; exit 0 ;; esac
fp=$(printf '%s' "${CLAUDE_CODE_OAUTH_TOKEN:-}" | sha256sum | cut -c1-8)
printf 'claude fp=%s\n' "$fp" >> "$ORDER_SINK"
printf '{"result":"ok","usage":{"input_tokens":5,"output_tokens":1},"total_cost_usd":0.01}\n'; exit 0
EOF
cat > "$T/fakebin/grok" <<'EOF'
#!/bin/bash
echo "grok" >> "$ORDER_SINK"; echo "grok answered"; exit 0
EOF
cat > "$T/fakebin/codex" <<'EOF'
#!/bin/bash
echo "codex" >> "$ORDER_SINK"; echo "codex answered"; exit 0
EOF
cat > "$T/fakebin/timeout" <<'EOF'
#!/bin/bash
[ "${1:-}" = "--kill-after" ] && shift 2
case "${1:-}" in --kill-after=*) shift ;; esac
shift
exec "$@"
EOF
# The lane-alert stub records its argv, one line per invocation.
cat > "$T/bin/lane-alert.sh" <<'EOF'
#!/bin/bash
printf '%s\n' "$*" >> "$ALERT_SINK"
EOF
printf '#!/bin/bash\necho subscription\n' > "$T/bin/billing-mode.sh"
printf '#!/bin/bash\nexit 0\n' > "$T/bin/beat.sh"
printf '#!/bin/bash\necho "test rules"\n' > "$T/bin/sync-agent-rules.sh"
printf '#!/bin/bash\necho "1 2 3 4"\n' > "$T/bin/codex-usage.sh"
chmod +x "$T/fakebin/"* "$T/bin/"*.sh
echo '{}' > "$T/catalog.json"

jq -n --argjson fa "$(date -u +%s)" '{fetched_at:$fa,values:{"account.project-3":"own:project-3"},seeded:{}}' > "$T/state/settings-cache.json"
overlay() { printf '{"%s":"%s"}\n' "$(fp12 "$PROJECT_3_TOK")" "$1" > "$T/state/auth-accounts.local.json"; }
aliases() { printf '%s\n' "$1" > "$ALIASES"; }
reset() { : > "$T/order"; : > "$T/logs/failovers.log"; rm -f "$T/out.txt"*; rm -rf "$T/state/quota"; rm -f "$T/state/model-cooldown-"*; }

run_call() {
  reset
  ( export ORDER_SINK="$T/order" ALERT_SINK="$ALERT_SINK" PATH="$T/fakebin:$PATH" HARNESS="$T" HOME="$T" \
           ACCOUNTS_DIR="$T/env/accounts.d" LADDER_BACKOFF_SECS=0 LADDER_TIER2_GROK=1 \
           RUNNER_EVAL=claude CONTEXT_BUDGETS="$DIR/catalog/context-budgets.json" \
           AUTH_ACCOUNTS_CATALOG="$T/catalog.json" JOBS_URL= \
           ACCOUNT_ALIASES_CATALOG="$ALIASES" ACCOUNT_PIN_BOX=box-project-3-1
    env -u ACCOUNT_ROUTING -u RUNNER_EVAL_FALLBACK -u OPENROUTER_API_KEY -u FIREWORKS_API_KEY \
      -u ANTHROPIC_API_KEY -u ACCOUNT_OWN_PROJECTS -u ACCOUNT_PIN_ALERT_WINDOW_S \
      CLAUDE_CODE_OAUTH_TOKEN="$PROJECT_3_TOK" "$@" \
      bash "$DIR/bin/agent-call.sh" eval project-3 claude-opus-5 600 "$T/out.txt" "hello" >/dev/null 2>&1 )
  echo $?
}
count() { grep -c "^$1" "$T/order" 2>/dev/null || true; }
alerts() { cat "$ALERT_SINK" 2>/dev/null | grep -c -- "--severity warn"; }
resolves() { cat "$ALERT_SINK" 2>/dev/null | grep -c -- "--resolve"; }
last_row() { tail -1 "$T/logs/account-routing.log" 2>/dev/null; }

# ---- A1 token file present -------------------------------------------------
printf 'CLAUDE_CODE_OAUTH_TOKEN=%s\n' "$PROJECT_3_TOK" > "$T/env/accounts.d/own:project-3.env"
aliases '{"own:project-3":["claude:project-3-dedicated"]}'
RC=$(run_call CLAUDE_CODE_OAUTH_TOKEN="$MK_TOK")
[ "$RC" = 0 ] && ok || bad "A1 rc=$RC"
grep -q "^claude fp=$PROJECT_3_FP" "$T/order" && ok || bad "A1 claude not on the file token: $(cat "$T/order")"
last_row | grep -q ',own:project-3,pinned$' && ok || bad "A1 row: $(last_row)"
rm -f "$T/env/accounts.d/own:project-3.env"

# ---- A2 no file, live fp labelled with an alias of the pin -----------------
overlay claude:project-3-dedicated
RC=$(run_call)
[ "$RC" = 0 ] && ok || bad "A2 rc=$RC (alias label did not resolve the pin)"
grep -q "^claude fp=$PROJECT_3_FP" "$T/order" && ok || bad "A2 claude did not run on the live token: $(cat "$T/order")"
last_row | grep -q ',own:project-3,pinned$' && ok || bad "A2 row: $(last_row)"
[ "$(count grok)" = 0 ] && ok || bad "A2 descended: $(cat "$T/order")"

# ---- A3 negatives ------------------------------------------------------------
neg() { # <name>
  RC=$(run_call)
  [ "$(count claude)" = 0 ] && ok || bad "A3/$1 claude ran: $(cat "$T/order")"
  last_row | grep -q ',own:project-3,pinned_unavailable$' && ok || bad "A3/$1 row: $(last_row)"
}
overlay claude:project-4-dedicated;  aliases '{"own:project-3":["claude:project-3-dedicated"],"own:project-4":["claude:project-4-dedicated"]}'; neg other-alias
rm -f "$T/state/auth-accounts.local.json"; neg unmapped-project-6
aliases '{"own:project-3":["unknown"]}'; neg alias-unknown
overlay ../max1; aliases '{"own:project-3":["../max1"]}'; neg alias-traversal
overlay claude:project-3-dedicated
aliases '{"own:project-3":["claude:project-3-dedicated"'; neg malformed
rm -f "$ALIASES"; neg missing
aliases '{"own:project-32":["claude:project-3-dedicated"],"own:om":["claude:project-3-dedicated"]}'; neg prefix-key

# ---- A4 neither -> descends, refusal line unchanged -------------------------
RC=$(run_call)
[ "$(count grok)" = 1 ] && ok || bad "A4 did not descend to grok: $(cat "$T/order")"
grep -q 'pinned account own:project-3 for project-3 has no token on this box, not falling back to shared accounts, descending' "$T/logs/failovers.log" \
  && ok || bad "A4 refusal line changed: $(cat "$T/logs/failovers.log")"

# ---- A5 three refusals -> exactly one alert ---------------------------------
rm -f "$ALERT_SINK" "$STAMP_F"
for _ in 1 2 3; do run_call >/dev/null; done
[ "$(alerts)" = 1 ] && ok || bad "A5 expected 1 alert, got $(alerts): $(cat "$ALERT_SINK" 2>/dev/null)"
grep -q -- "--id $ALERT_ID" "$ALERT_SINK" 2>/dev/null && ok || bad "A5 alert id: $(cat "$ALERT_SINK" 2>/dev/null)"
grep -q 'own:project-3' "$ALERT_SINK" 2>/dev/null && ok || bad "A5 alert does not name the label"
grep -q 'box-project-3-1:' "$ALERT_SINK" 2>/dev/null && ok || bad "A5 alert does not name the box"
grep -q ' account-pin ' "$ALERT_SINK" 2>/dev/null && ok || bad "A5 lane is not account-pin"
[ -f "$STAMP_F" ] && ok || bad "A5 no stamp"

# ---- A6 window ------------------------------------------------------------------
touch -d '7 hours ago' "$STAMP_F"
run_call >/dev/null
[ "$(alerts)" = 2 ] && ok || bad "A6 stamp 7h old: expected 2 alerts, got $(alerts)"
touch -d '2 minutes ago' "$STAMP_F"
run_call >/dev/null
[ "$(alerts)" = 2 ] && ok || bad "A6 stamp 2m old re-alerted under the default window: $(alerts)"
touch -d '2 minutes ago' "$STAMP_F"
run_call ACCOUNT_PIN_ALERT_WINDOW_S=60 >/dev/null
[ "$(alerts)" = 3 ] && ok || bad "A6 knob 60s not honoured: $(alerts)"

# ---- A8 recovery resolves once --------------------------------------------------
aliases '{"own:project-3":["claude:project-3-dedicated"]}'
RC=$(run_call)
[ "$RC" = 0 ] && ok || bad "A8 rc=$RC"
[ "$(resolves)" = 1 ] && ok || bad "A8 expected 1 resolve, got $(resolves)"
grep -q -- "--resolve --id $ALERT_ID" "$ALERT_SINK" && ok || bad "A8 resolve line: $(cat "$ALERT_SINK")"
[ -e "$STAMP_F" ] && bad "A8 stamp left behind" || ok
run_call >/dev/null
[ "$(resolves)" = 1 ] && ok || bad "A8 second success resolved again: $(resolves)"

# ---- A7 no token anywhere ------------------------------------------------------
for tok in "$PROJECT_3_TOK" "$MK_TOK"; do
  hits=$(grep -rlF "$tok" "$T/logs" "$ALERT_SINK" "$T/out.txt" "$T/state/account-pin" 2>/dev/null)
  [ -z "$hits" ] && ok || bad "A7 a token leaked into: $hits"
done

# ---- A9 the shipped catalog -------------------------------------------------------
CAT="$DIR/catalog/account-aliases.json"
jq -e 'type == "object"' "$CAT" >/dev/null 2>&1 && ok || bad "A9 $CAT does not parse as an object"
while read -r l; do
  case "$l" in ''|unknown|*/*|*..*|.*|*[!A-Za-z0-9:._@-]*) bad "A9 bad label '$l'" ;; *) ok ;; esac
done < <(jq -r 'to_entries[] | .key, (.value[])' "$CAT" 2>/dev/null)
[ "$(jq -r '."own:project-3"[0]' "$CAT" 2>/dev/null)" = claude:project-3-dedicated ] && ok || bad "A9 own:project-3 alias missing"
# The knob is registered where lib_env_apply project-account reads it.
jq -e '.libs[] | select(.id=="project-account") | .knobs[] | select(.env=="ACCOUNT_PIN_ALERT_WINDOW_S" and .default==21600)' \
  "$DIR/catalog/lanes.d/_lib.project-account.json" >/dev/null 2>&1 && ok || bad "A9 knob not registered"

echo "agent-call-pin-alias.bh-3559: $PASS pass, $FAIL fail"
[ "$FAIL" = 0 ]
