#!/bin/bash
# tests/agent-call-own-account.bh-1657-test.sh — BH-1657: a project pinned to its
# own Claude account runs its claude rung on THAT account, whatever box runs it,
# and never falls to the shared project-6/max accounts.
#
#   (i)    pinned + ACCOUNT_ROUTING=1 + a project-6 box token -> the own token,
#          account-pick never runs, a box ANTHROPIC_API_KEY is unset, $OUT.account
#          names the label
#   (ii)   the same with ACCOUNT_ROUTING=0
#   (iii)  no token file but the live token's fp maps to the label (Fly builder)
#          -> runs on the live token
#   (iv)   no token file and a project-6 live token -> claude never runs, the rung
#          descends, failovers.log names the label
#   (v)    an unpinned project (and a pinned project's codex rung) still routes
#   (vi)   an own:<x>.env in accounts.d is never pooled by account-pick
#   (vii)  no token string in any log
#   (viii) the own account refusing (quota, auth) never rotates: one claude call,
#          no pick, no cooldown stamp, the refusal logged with the label
#   (ix)   the cost row's auth_account is the label
#
# DRIVEN, NOT GREPPED: bin/agent-call.sh runs for real against a scratch HARNESS
# with fake CLIs; what ran is read back off disk.
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
. "$DIR/tests/lib/model-route-stub.sh" || exit 1
mrs_fixture "$T" project-3 project-5-os
mkdir -p "$T/bin" "$T/bin/lib" "$T/fakebin" "$T/flags" "$T/locks" "$T/logs" "$T/state" "$T/env/accounts.d"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

PROJECT_3_TOK="sk-ant-oat01-FIXTURE-project-3-own-token"
MK_TOK="sk-ant-oat01-FIXTURE-project-6-token"
BOX_KEY="sk-ant-api03-FIXTURE-box-api-key"
fp8()  { printf '%s' "$1" | sha256sum | cut -c1-8; }
fp12() { printf '%s' "$1" | sha256sum | cut -c1-12; }
PROJECT_3_FP=$(fp8 "$PROJECT_3_TOK"); MK_FP=$(fp8 "$MK_TOK")

# ---------- fakes -----------------------------------------------------------
# claude records WHICH token it ran on (an fp, never the token) and whether a box
# API key reached it; it answers or fails the way the case needs.
cat > "$T/fakebin/claude" <<'EOF'
#!/bin/bash
case " $* " in *" --help "*) printf -- '  --session-id <uuid>\n'; exit 0 ;; esac
fp=$(printf '%s' "${CLAUDE_CODE_OAUTH_TOKEN:-}" | sha256sum | cut -c1-8)
printf 'claude fp=%s apikey=%s\n' "$fp" "${ANTHROPIC_API_KEY:+set}" >> "$ORDER_SINK"
case "${CLAUDE_MODE:-ok}" in
  ok)    printf '{"result":"ok","usage":{"input_tokens":5,"output_tokens":1},"total_cost_usd":0.01}\n'; exit 0 ;;
  quota) echo "Claude AI: you have hit your weekly limit" >&2; exit 1 ;;
  auth)  echo "API Error: 401 Unauthorized" >&2; exit 1 ;;
esac
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
# The picker stub: touching the sentinel is the proof it was asked.
cat > "$T/bin/account-pick.sh" <<'EOF'
#!/bin/bash
[ "${1:-}" = --overage-ok ] && exit 1
touch "$PICK_SENTINEL"
echo "name=default"; echo "reason=stub"; exit 0
EOF
printf '#!/bin/bash\necho subscription\n' > "$T/bin/billing-mode.sh"
printf '#!/bin/bash\nexit 0\n' > "$T/bin/beat.sh"
printf '#!/bin/bash\necho "test rules"\n' > "$T/bin/sync-agent-rules.sh"
printf '#!/bin/bash\necho "1 2 3 4"\n' > "$T/bin/codex-usage.sh"
chmod +x "$T/fakebin/"* "$T/bin/"*.sh
echo '{}' > "$T/catalog.json"

cache() { jq -n --argjson fa "$(date -u +%s)" --argjson v "$1" '{fetched_at:$fa,values:$v,seeded:{}}' > "$T/state/settings-cache.json"; }
tokfile() { printf 'CLAUDE_CODE_OAUTH_TOKEN=%s\n' "$PROJECT_3_TOK" > "$T/env/accounts.d/own:project-3.env"; chmod 600 "$T/env/accounts.d/own:project-3.env"; }
reset() { : > "$T/order"; : > "$T/logs/failovers.log"; rm -f "$T/pick" "$T/out.txt"*; rm -rf "$T/state/quota"; rm -f "$T/state/model-cooldown-"*; }

# run_call <project> [ENV=...] — drives bin/agent-call.sh for real.
run_call() {
  local p="$1"; shift
  reset
  ( export ORDER_SINK="$T/order" PICK_SENTINEL="$T/pick" PATH="$T/fakebin:$PATH" HARNESS="$T" HOME="$T" \
           ACCOUNTS_DIR="$T/env/accounts.d" LADDER_BACKOFF_SECS=0 LADDER_TIER2_GROK=1 \
           RUNNER_EVAL="${RUNNER_EVAL:-claude}" CONTEXT_BUDGETS="$DIR/catalog/context-budgets.json" \
           AUTH_ACCOUNTS_CATALOG="$T/catalog.json" JOBS_URL=
    env -u ACCOUNT_ROUTING -u RUNNER_EVAL_FALLBACK -u OPENROUTER_API_KEY -u FIREWORKS_API_KEY \
      -u CLAUDE_CODE_OAUTH_TOKEN -u ANTHROPIC_API_KEY -u ACCOUNT_OWN_PROJECTS \
      "$@" bash "$DIR/bin/agent-call.sh" eval "$p" claude-opus-5 600 "$T/out.txt" "hello" \
      >/dev/null 2>&1 )
  echo $?
}
count() { grep -c "^$1" "$T/order" 2>/dev/null || true; }

cache '{"account.project-3":"own:project-3"}'
tokfile

# (i) pinned, routing ON, a project-6 box token and a box API key
RC=$(run_call project-3 ACCOUNT_ROUTING=1 CLAUDE_CODE_OAUTH_TOKEN="$MK_TOK" ANTHROPIC_API_KEY="$BOX_KEY")
[ "$RC" = 0 ] && ok || bad "(i) rc=$RC"
grep -q "^claude fp=$PROJECT_3_FP apikey=\$" "$T/order" && ok || bad "(i) claude did not run on the project-3 token alone: $(cat "$T/order")"
grep -q "fp=$MK_FP" "$T/order" && bad "(i) project-6 token reached claude" || ok
[ -e "$T/pick" ] && bad "(i) account-pick ran for a pinned project" || ok
[ "$(cat "$T/out.txt.account" 2>/dev/null)" = own:project-3 ] && ok || bad "(i) \$OUT.account=$(cat "$T/out.txt.account" 2>/dev/null)"
tail -1 "$T/logs/account-routing.log" 2>/dev/null | grep -q ',project-3,eval,claude-opus-5,own:project-3,pinned$' \
  && ok || bad "(i) account-routing.log row: $(tail -1 "$T/logs/account-routing.log" 2>/dev/null)"
# (ix) the cost row names the label (fp unmapped -> the label verbatim)
[ "$(tail -1 "$T/logs/cost.csv" | awk -F, '{print $16}')" = own:project-3 ] \
  && ok || bad "(ix) cost auth_account: $(tail -1 "$T/logs/cost.csv")"

# (ii) pinned, routing OFF
RC=$(run_call project-3 ACCOUNT_ROUTING=0 CLAUDE_CODE_OAUTH_TOKEN="$MK_TOK")
grep -q "^claude fp=$PROJECT_3_FP " "$T/order" && ok || bad "(ii) routing=0 did not use the project-3 token: $(cat "$T/order")"
[ -e "$T/pick" ] && bad "(ii) account-pick ran" || ok

# (iii) Fly builder: no token file, the live token IS the project-3 token and the
# overlay maps its fp to the label
rm -f "$T/env/accounts.d/own:project-3.env"
printf '{"%s":"own:project-3"}\n' "$(fp12 "$PROJECT_3_TOK")" > "$T/state/auth-accounts.local.json"
RC=$(run_call project-3 ACCOUNT_ROUTING=1 CLAUDE_CODE_OAUTH_TOKEN="$PROJECT_3_TOK")
[ "$RC" = 0 ] && ok || bad "(iii) rc=$RC"
grep -q "^claude fp=$PROJECT_3_FP " "$T/order" && ok || bad "(iii) builder did not run on its live token: $(cat "$T/order")"
[ -e "$T/pick" ] && bad "(iii) account-pick ran" || ok

# (iv) no token file and a project-6 live token: fail closed, descend
RC=$(run_call project-3 ACCOUNT_ROUTING=1 CLAUDE_CODE_OAUTH_TOKEN="$MK_TOK")
[ "$(count claude)" = 0 ] && ok || bad "(iv) claude ran on a box with no project-3 token: $(cat "$T/order")"
[ -e "$T/pick" ] && bad "(iv) account-pick ran" || ok
grep -q 'pinned account own:project-3 for project-3 has no token on this box, not falling back to shared accounts' "$T/logs/failovers.log" \
  && ok || bad "(iv) refusal not logged with the label: $(cat "$T/logs/failovers.log")"
[ "$(count grok)" = 1 ] && ok || bad "(iv) the rung did not descend to grok: $(cat "$T/order")"
tail -1 "$T/logs/account-routing.log" | grep -q ',own:project-3,pinned_unavailable$' && ok || bad "(iv) routing row: $(tail -1 "$T/logs/account-routing.log")"
rm -f "$T/state/auth-accounts.local.json"
tokfile

# (v) unpinned project: routing unchanged
RC=$(run_call project-5-os ACCOUNT_ROUTING=1 CLAUDE_CODE_OAUTH_TOKEN="$MK_TOK")
[ -e "$T/pick" ] && ok || bad "(v) project-5 did not route through account-pick"
grep -q "^claude fp=$MK_FP " "$T/order" && ok || bad "(v) project-5 did not run on its box token: $(cat "$T/order")"
[ "$(tail -1 "$T/logs/cost.csv" | awk -F, '{print $16}')" = own:project-3 ] && bad "(ix) project-5 row labelled own:project-3" || ok
# ... and a pinned project's codex rung still routes (only the claude account is pinned)
mkdir -p "$T/.codex"; echo '{}' > "$T/.codex/auth.json"
RC=$(RUNNER_EVAL=codex run_call project-3 ACCOUNT_ROUTING=1)
[ -e "$T/pick" ] && ok || bad "(v) codex rung for project-3 skipped account-pick"
[ "$(count codex)" = 1 ] && [ "$(count claude)" = 0 ] && ok || bad "(v) codex rung did not serve: $(cat "$T/order")"
rm -rf "$T/.codex"

# (vi) the own-account file is never pooled, even when it names itself
printf 'ACCOUNT_NAME=own:project-3\nACCOUNT_VENDOR=claude\nCLAUDE_CODE_OAUTH_TOKEN=%s\n' "$PROJECT_3_TOK" > "$T/env/accounts.d/own:project-3.env"
out=$(HARNESS="$T" HOME="$T" ACCOUNTS_DIR="$T/env/accounts.d" CLAUDE_CODE_OAUTH_TOKEN="$MK_TOK" \
      bash "$DIR/bin/account-pick.sh" eval claude claude-opus-5 2>&1)
grep -q 'own:project-3' <<<"$(printf '%s' "$out")" && bad "(vi) account-pick pooled own:project-3: $out" || ok
grep -qF "$PROJECT_3_TOK" <<<"$(printf '%s' "$out")" && bad "(vi) account-pick printed the project-3 token" || ok
tokfile

# (viii) the own account refuses: no rotation, no second paid attempt
for mode in quota auth; do
  RC=$(run_call project-3 ACCOUNT_ROUTING=1 CLAUDE_CODE_OAUTH_TOKEN="$MK_TOK" CLAUDE_MODE=$mode)
  [ "$(count claude)" = 1 ] && ok || bad "(viii/$mode) claude ran $(count claude) times: $(cat "$T/order")"
  grep -q "fp=$MK_FP" "$T/order" && bad "(viii/$mode) fell to the project-6 token" || ok
  [ -e "$T/pick" ] && bad "(viii/$mode) account-pick ran" || ok
  [ -z "$(ls -A "$T/state/quota/cooldown/claude" 2>/dev/null)" ] && ok || bad "(viii/$mode) a cooldown was stamped: $(ls "$T/state/quota/cooldown/claude")"
  grep -q 'pinned account own:project-3 refused' "$T/logs/failovers.log" && ok || bad "(viii/$mode) refusal not logged: $(cat "$T/logs/failovers.log")"
  [ "$(count grok)" = 1 ] && ok || bad "(viii/$mode) did not descend a rung: $(cat "$T/order")"
done

# (vii) no token string anywhere under logs/
for tok in "$PROJECT_3_TOK" "$MK_TOK" "$BOX_KEY"; do
  hits=$(grep -rlF "$tok" "$T/logs" 2>/dev/null)
  [ -z "$hits" ] && ok || bad "(vii) a token leaked into: $hits"
done

echo "agent-call-own-account.bh-1657: $PASS pass, $FAIL fail"
[ "$FAIL" = 0 ]
