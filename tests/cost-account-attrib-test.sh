#!/bin/bash
# tests/cost-account-attrib-test.sh — every cost row names WHICH account paid,
# and this drives bin/agent-call.sh for real to prove it.
#
# WHY DRIVEN AND NOT GREPPED (same rule as agent-call-notools-test.sh): the
# attribution exists because accounts get switched, and a fingerprint that is
# computed from the wrong env, or written as the raw secret, or parked in
# DictReader's restkey under a stale header, would look exactly like a working
# column until the day someone billed the wrong client. So agent-call.sh runs
# against a temp HARNESS with a fake claude CLI on PATH, and the row is read
# back off disk.
#
# Covered: (a) an env OAuth token resolves to its sha256 prefix and an
# unmapped fp reads "unknown" against the EMPTY repo catalog; (b) a mapping in
# the box-local overlay resolves to its label; (c) a legacy 14-column
# cost.csv gets its header upgraded once, old rows byte-identical (and a
# 13-column file jumps straight to 16); (d) no raw token substring anywhere
# in the temp harness; (e) bin/auth-label.sh writes fp -> label from a live
# env token without echoing the secret.
# Run from anywhere: tests/cost-account-attrib-test.sh   (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
mkdir -p "$T/logs" "$T/locks" "$T/flags" "$T/state" "$T/bin" "$T/fakebin"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

# A fake token with a recognisable shape. If any file in the temp harness ever
# contains this string, the ledger is leaking secrets.
TOK="sk-ant-oat01-FAKE-TEST-TOKEN-do-not-ship-0123456789abcdef"
FP=$(printf '%s' "$TOK" | sha256sum | cut -c1-12)

# Fake claude: answers like the real CLI's json envelope.
cat > "$T/fakebin/claude" <<'EOF'
#!/bin/bash
printf '{"result":"ok","usage":{"input_tokens":10,"output_tokens":2},"total_cost_usd":0.01}\n'
EOF
chmod +x "$T/fakebin/claude"
# The real billing-mode.sh, so the row's billing_mode column is exercised too.
cp "$DIR/bin/billing-mode.sh" "$T/bin/"; chmod +x "$T/bin/billing-mode.sh"
# GNU `timeout` shim, same as the notools suite, so this runs on macOS too.
cat > "$T/fakebin/timeout" <<'EOF'
#!/bin/bash
[ "${1:-}" = "--kill-after" ] && shift 2
case "${1:-}" in --kill-after=*) shift ;; esac
shift
exec "$@"
EOF
chmod +x "$T/fakebin/timeout"

run_call() { # run_call <extra-env...> ; echoes the rc
  ( export PATH="$T/fakebin:$PATH" HARNESS="$T" HOME="$T" \
           CONTEXT_BUDGETS="$DIR/catalog/context-budgets.json" \
           AUTH_ACCOUNTS_CATALOG="$DIR/catalog/auth-accounts.json"
    "$@" bash "$DIR/bin/agent-call.sh" eval testproj claude-fable-5 60 "$T/out.txt" "hello" \
      >/dev/null 2>&1 )
  echo $?
}

# --- (a) env token -> fp, empty catalog -> "unknown" -------------------------
RC=$(run_call env -u ANTHROPIC_API_KEY CLAUDE_CODE_OAUTH_TOKEN="$TOK")
[ "$RC" = 0 ] && ok || bad "the claude lane failed under the fake CLI (rc=$RC)"
# The canonical header is 25 columns since BH-2303: session_id, row_source,
# result_usd and the ticket/job/pr/run tags (2026-09-14), `note` (2026-09-18)
# and `lane_id` (2026-09-25) were APPENDED at the end, so the sixteen this suite
# cares about are still at the same positions. (TEST-CHANGE BH-2303: 24 -> 25.)
# TEST-CHANGE BH-2537: 25 -> 26 on the HEADER (guard_fp), and on the row
# agent-call writes since the writer sibling (#2666) landed.
head -1 "$T/logs/cost.csv" | grep -qx 'ts,host,project,stage,runner,model,rc,duration_s,input_toks,output_toks,cache_read,cache_write,cost_usd,billing_mode,auth_fp,auth_account,session_id,row_source,result_usd,ticket,job_id,pr,run_id,note,lane_id,guard_fp' \
  && ok || bad "a fresh cost.csv did not get the canonical 26-column header (got: $(head -1 "$T/logs/cost.csv" 2>/dev/null))"
ROW=$(tail -1 "$T/logs/cost.csv")
# TEST-CHANGE BH-2537: 25 -> 26 (agent-call writes guard_fp, #2666)
[ "$(printf '%s' "$ROW" | awk -F, '{print NF}')" = 26 ] \
  && ok || bad "the new row does not have 26 fields: $ROW"
# auth_fp,auth_account are columns 15 and 16 — no longer the LAST two, so this
# reads them by position. A suffix match would have silently started asserting
# nothing the day the row grew, which is exactly how $NF readers break.
[ "$(printf '%s' "$ROW" | cut -d, -f15,16)" = "$FP,unknown" ] \
  && ok || bad "expected fields 15,16 to be '$FP,unknown' (env token fp + unmapped label): $ROW"

# --- (b) a mapping in the local overlay resolves to its label ----------------
printf '{"%s":"acct-project-2-max"}\n' "$FP" > "$T/state/auth-accounts.local.json"
RC=$(run_call env -u ANTHROPIC_API_KEY CLAUDE_CODE_OAUTH_TOKEN="$TOK")
[ "$(tail -1 "$T/logs/cost.csv" | cut -d, -f15,16)" = "$FP,acct-project-2-max" ] \
  && ok || bad "the local overlay label was not resolved: $(tail -1 "$T/logs/cost.csv")"
rm -f "$T/state/auth-accounts.local.json"

# --- (c) legacy headers upgrade once; old rows stay byte-identical -----------
LEGACY="2026-08-01T00:00:00Z,oldbox,proj,plan,claude,claude-opus-5,0,10,1,2,3,4,0.5,subscription"
{ echo "ts,host,project,stage,runner,model,rc,duration_s,input_toks,output_toks,cache_read,cache_write,cost_usd,billing_mode"
  echo "$LEGACY"; } > "$T/logs/cost.csv"
RC=$(run_call env -u ANTHROPIC_API_KEY CLAUDE_CODE_OAUTH_TOKEN="$TOK")
[ "$(head -1 "$T/logs/cost.csv" | awk -F, '{print NF}')" = 26 ] \
  && ok || bad "a 14-column header was not upgraded to 26"
grep -qxF "$LEGACY" "$T/logs/cost.csv" \
  && ok || bad "the legacy 14-field row was modified by the upgrade"
# TEST-CHANGE BH-2537: 25 -> 26 (agent-call writes guard_fp, #2666)
[ "$(tail -1 "$T/logs/cost.csv" | awk -F, '{print NF}')" = 26 ] \
  && ok || bad "the row appended after the upgrade is not 26 fields"
# once means once: a second call must not touch the header again
RC=$(run_call env -u ANTHROPIC_API_KEY CLAUDE_CODE_OAUTH_TOKEN="$TOK")
[ "$(grep -c '^ts,host,' "$T/logs/cost.csv")" = 1 ] \
  && ok || bad "the header upgrade is not idempotent (multiple header lines)"
# a 13-column file (pre-billing_mode) jumps straight to 23
{ echo "ts,host,project,stage,runner,model,rc,duration_s,input_toks,output_toks,cache_read,cache_write,cost_usd"
  echo "${LEGACY%,subscription}"; } > "$T/logs/cost.csv"
RC=$(run_call env -u ANTHROPIC_API_KEY CLAUDE_CODE_OAUTH_TOKEN="$TOK")
[ "$(head -1 "$T/logs/cost.csv" | awk -F, '{print NF}')" = 26 ] \
  && ok || bad "a 13-column header was not upgraded to 26"
grep -qxF "${LEGACY%,subscription}" "$T/logs/cost.csv" \
  && ok || bad "the legacy 13-field row was modified by the upgrade"

# --- (d) the raw secret appears NOWHERE in the temp harness ------------------
grep -rqF "$TOK" "$T" \
  && bad "the raw token leaked into the temp harness: $(grep -rlF "$TOK" "$T" | tr '\n' ' ')" || ok

# --- (e) auth-label.sh maps the LIVE token to a label, silently on the secret -
LBL_OUT=$(env -u ANTHROPIC_API_KEY CLAUDE_CODE_OAUTH_TOKEN="$TOK" HOME="$T" \
  AUTH_ACCOUNTS_LOCAL="$T/state/label-overlay.json" \
  bash "$DIR/bin/auth-label.sh" "ops-hub" claude 2>&1)
[ "$(jq -r --arg fp "$FP" '.[$fp] // ""' "$T/state/label-overlay.json" 2>/dev/null)" = "ops-hub" ] \
  && ok || bad "auth-label.sh did not write fp -> label to the overlay ($LBL_OUT)"
case "$LBL_OUT" in
  *"$TOK"*) bad "auth-label.sh echoed the raw token" ;;
  *) ok ;;
esac

echo "cost-account-attrib-test: $PASS pass, $FAIL fail"
[ "$FAIL" -eq 0 ]
