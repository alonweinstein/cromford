#!/bin/bash
# tests/orchestrator-account-routing-test.sh — orchestrator turns follow the
# account picker (the operator 2026-09-15), by TOKEN, failing open to the
# orchestrator.env credential in every degraded case.
# Run from anywhere: tests/orchestrator-account-routing-test.sh (exit 0 = pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
export HARNESS="$T/h"; mkdir -p "$HARNESS/bin" "$HARNESS/env/tokens.d" "$HARNESS/flags"
echo 'CLAUDE_CODE_OAUTH_TOKEN=tok-max6' > "$HARNESS/env/tokens.d/max6-setup-token.env"
echo 'CLAUDE_CODE_OAUTH_TOKEN=' > "$HARNESS/env/tokens.d/max2-setup-token.env"
# fake picker: answers from $PICK_OUT with rc $PICK_RC, records its argv
cat > "$HARNESS/bin/account-pick.sh" <<'P'
#!/bin/bash
echo "$* pin=${ACCOUNT_PIN_KEY:-} project=${PROJECT:-}" > "$HARNESS/pick.argv"
printf '%s\n' "${PICK_OUT:-}"; exit "${PICK_RC:-0}"
P
chmod +x "$HARNESS/bin/account-pick.sh"
. "$DIR/bin/lib/orc-account.sh"

reset() { ORC_TOKEN=orig; unset COST_ACCT_NAME ORC_ACCOUNT_LABEL ORC_ACCOUNT_ROUTING ORC_ACCOUNT_PIN; rm -f "$HARNESS/pick.argv" "$HARNESS/flags/orc-account-routing-off"; }

# 1. routing off => untouched, picker never called
reset; ACCOUNT_ROUTING=0 orc_pick_account claude-fable-5-1
[ "$ORC_TOKEN" = orig ] && [ "$ORC_ACCOUNT" = default ] && [ "$ORC_ACCOUNT_REASON" = routing-off ] && [ ! -e "$HARNESS/pick.argv" ] && ok || bad "routing off must keep the token and skip the picker"
# 2. unset flag == off
reset; env -u ACCOUNT_ROUTING true; ( unset ACCOUNT_ROUTING; orc_pick_account m; [ "$ORC_ACCOUNT" = default ] ) && ok || bad "unset ACCOUNT_ROUTING must be off"
export ACCOUNT_ROUTING=1
# 3. happy path: named pick -> token swapped, name/reason/label/COST_ACCT_NAME set, picker argv right
reset; PICK_OUT=$'name=max6\nreason=tie_5h\nlabel=max6@example.com\nunset CLAUDE_CODE_OAUTH_TOKEN' orc_pick_account claude-fable-5-1
[ "$ORC_TOKEN" = tok-max6 ] && ok || bad "token must be max6's setup-token (got $ORC_TOKEN)"
[ "$ORC_ACCOUNT" = max6 ] && [ "$ORC_ACCOUNT_REASON" = tie_5h ] && ok || bad "name/reason from the pick"
[ "${COST_ACCT_NAME:-}" = max6 ] && [ "${ORC_ACCOUNT_LABEL:-}" = max6@example.com ] && ok || bad "COST_ACCT_NAME + label exported"
grep -q '^orchestrator claude claude-fable-5-1 pin=orchestrator project=fleet$' "$HARNESS/pick.argv" && ok || bad "picker argv/stage/pin (got: $(cat "$HARNESS/pick.argv"))"
# 4. pin + project knobs
reset; ORC_ACCOUNT_PIN=orc-x COST_PROJECT=ops PICK_OUT=$'name=max6\nreason=pinned' orc_pick_account m
grep -q 'pin=orc-x project=ops$' "$HARNESS/pick.argv" && [ "$ORC_ACCOUNT_REASON" = pinned ] && ok || bad "pin/project knobs"
# 5. name=default => untouched
reset; PICK_OUT=$'name=default\nreason=default' orc_pick_account m
[ "$ORC_TOKEN" = orig ] && [ "$ORC_ACCOUNT" = default ] && [ "$ORC_ACCOUNT_REASON" = default ] && ok || bad "default pick keeps the token"
# 6. picker rc=2 (no headroom) => untouched
reset; PICK_RC=2 PICK_OUT="" orc_pick_account m
[ "$ORC_TOKEN" = orig ] && [ "$ORC_ACCOUNT" = default ] && ok || bad "rc=2 keeps the token"
# 7. picked account with no token file => untouched, reason says so
reset; PICK_OUT=$'name=max9\nreason=tie_5h' orc_pick_account m
[ "$ORC_TOKEN" = orig ] && [ "$ORC_ACCOUNT_REASON" = "no-token-file:max9" ] && ok || bad "missing token file fails open ($ORC_ACCOUNT_REASON)"
# 8. empty token in file => untouched
reset; PICK_OUT=$'name=max2\nreason=tie_5h' orc_pick_account m
[ "$ORC_TOKEN" = orig ] && [ "$ORC_ACCOUNT_REASON" = "empty-token:max2" ] && ok || bad "empty token fails open"
# 9. kill switches: env + flag
reset; ORC_ACCOUNT_ROUTING=0 PICK_OUT=$'name=max6\nreason=tie_5h' orc_pick_account m
[ "$ORC_TOKEN" = orig ] && [ "$ORC_ACCOUNT_REASON" = orc-routing-off ] && [ ! -e "$HARNESS/pick.argv" ] && ok || bad "ORC_ACCOUNT_ROUTING=0 kill"
reset; touch "$HARNESS/flags/orc-account-routing-off"; PICK_OUT=$'name=max6\nreason=tie_5h' orc_pick_account m
[ "$ORC_TOKEN" = orig ] && [ "$ORC_ACCOUNT_REASON" = orc-routing-off ] && ok || bad "flag kill"
# 10. no picker binary => untouched
reset; chmod -x "$HARNESS/bin/account-pick.sh"; orc_pick_account m; chmod +x "$HARNESS/bin/account-pick.sh"
[ "$ORC_TOKEN" = orig ] && [ "$ORC_ACCOUNT_REASON" = no-picker ] && ok || bad "no picker fails open"
# 11. the pick never touches CLAUDE_CONFIG_DIR (memory + transcripts stay put)
reset; unset CLAUDE_CONFIG_DIR; PICK_OUT=$'name=max6\nreason=tie_5h\nexport CLAUDE_CONFIG_DIR=/root/.claude-max6' orc_pick_account m
[ -z "${CLAUDE_CONFIG_DIR:-}" ] && [ "$ORC_TOKEN" = tok-max6 ] && ok || bad "config dir must not move"
# 12. orchestrate.sh wires it: sources the lib after ORC_TOKEN, calls with ORC_MODEL, logs the account
bash -n "$DIR/bin/orchestrate.sh" && ok || bad "orchestrate.sh syntax"
grep -q 'orc_pick_account "\$ORC_MODEL"' "$DIR/bin/orchestrate.sh" && ok || bad "orchestrate.sh calls orc_pick_account with ORC_MODEL"
# The env DIRECTORY is resolved by bin/lib/env-path.sh (BH-455), so this
# assertion pins the ORDER it is about and lets the path expression move —
# tests/env-path-test.sh is what pins the path. It still requires the real read
# line (anchored `[ -r "…orchestrator.env" ] && ORC_TOKEN=`), so deleting that
# line still fails here.
L1=$(grep -n "^\[ -r \".*orchestrator\.env\" \] && ORC_TOKEN=" "$DIR/bin/orchestrate.sh" | cut -d: -f1)
# EVERY call site, not just the first: since BH-996 the turn re-picks inside the
# account ladder, and a pick above the orchestrator.env read would clobber the
# default token there exactly as it would at the pre-turn pick.
L2=$(grep -n 'orc_pick_account "\$ORC_MODEL"' "$DIR/bin/orchestrate.sh" | cut -d: -f1)
PICK_ORDER_OK=1; [ -n "$L1" ] && [ -n "$L2" ] || PICK_ORDER_OK=0
for l in $L2; do [ "$l" -gt "${L1:-0}" ] || PICK_ORDER_OK=0; done
[ "$PICK_ORDER_OK" = 1 ] && ok || bad "every pick must run AFTER orchestrator.env is read (else the env token clobbers it); env line $L1, picks: $(echo "$L2" | tr '\n' ' ')"
grep -q 'note "turn account: \$ORC_ACCOUNT' "$DIR/bin/orchestrate.sh" && ok || bad "turn logs its account"
# 13. claude-cost.sh labels the routed account only as a fallback
# TEST-CHANGE BH-3986: the acct:<name> literal and its `= unknown` gate moved
# into bin/lib/cost-row.sh cost_row_auth_account, which claude-cost.sh now
# calls with the turn's COST_ACCT_NAME and ORC_ACCOUNT_LABEL. The fallback
# order itself (fp label wins, label, registry, acct:<name>) is driven end to
# end in tests/cost-row-attribution.bh-3986-test.sh AC1(d)/(f).
grep -q 'cost_row_auth_account "\$AUTH_ACCT" "\${COST_ACCT_NAME:-}" "\${ORC_ACCOUNT_LABEL:-}"' "$DIR/bin/claude-cost.sh" && ok || bad "claude-cost routes auth_account through cost_row_auth_account"
grep -q 'AUTH_ACCT="\$COST_ROW_AUTH_ACCOUNT"' "$DIR/bin/claude-cost.sh" && ok || bad "claude-cost writes the canonicaliser's answer"
bash -n "$DIR/bin/claude-cost.sh" && ok || bad "claude-cost.sh syntax"

echo "orchestrator-account-routing: $PASS pass, $FAIL fail"; [ "$FAIL" -eq 0 ]
