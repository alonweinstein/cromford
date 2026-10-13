#!/bin/bash
# tests/lane-probe-endpoint.bh-2549-test.sh — BH-2560 (BH-2549.2): bin/lane-probe.sh
# probes the credential first and buys inference only through agent-call.
#   E1  --endpoint openrouter, endpoint ALIVE, claim rc 1: line 1 is the endpoint
#       verdict; no agent-call, no vendor CLI.
#   E2  claim rc 0: exactly one agent-call (stage canary, runner pinned, lane
#       claude-auth-check, the role model) and one record "openrouter fp1 ok".
#   E3  claim rc 2 (store unreachable): no spend, no record.
#   E4  `openrouter --endpoint` (lane first) is the same mode as E1.
#   E5  agent-call refused (rc 74): nothing billed, so nothing recorded.
#   D   default mode grok: one agent-call pinned to grok, no vendor CLI, the ok
#       line kept.
#   D-codex  default mode codex: codex-cli-version= first, then the ok line.
#   M   a claim that ignores its rc (always 0) turns E1's zero into one call.
# Drives the real script with HARNESS=$T. Run from anywhere (exit 0 = pass).
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

H="$T/h"
mkdir -p "$H/bin/lib" "$H/env" "$T/fakebin"
cp "$DIR/bin/lane-probe.sh" "$DIR/bin/lib/env-path.sh" "$H/bin/" 2>/dev/null
mv "$H/bin/env-path.sh" "$H/bin/lib/"
: > "$H/env/global.env"
printf 'lane_model() { echo m-test; }\nlane_role_model() { echo m-test; }\n' > "$H/bin/lib/lane-model.sh"
cat > "$H/bin/agent-call.sh" <<'SH'
#!/bin/bash
# argv: <stage> <project> <model> <timeout> <outfile> <prompt>
printf '%s\n' "$*" >> "$LOGD/ac.log"
printf 'AGENT_CALL_RUNNERS=%s AGENT_CALL_LANE=%s ACCOUNT_ROUTING=%s\n' \
  "${AGENT_CALL_RUNNERS:-}" "${AGENT_CALL_LANE:-}" "${ACCOUNT_ROUTING:-}" >> "$LOGD/ac.env"
if [ "${STUB_AC_RC:-0}" != 0 ]; then
  printf 'AGENT_CALL_REFUSED llm-gate day-cap\n' > "$5"; exit "$STUB_AC_RC"
fi
printf 'ok\n' > "$5"
SH
for v in claude codex openrouter fireworks grok; do
  cat > "$T/fakebin/$v" <<SH
#!/bin/bash
# codex --version is a version read, not a spend
[ "$v" = codex ] && [ "\${1:-}" = --version ] && { echo "codex-cli 1.2.3"; exit 0; }
printf '%s\n' "\$*" >> "\$LOGD/vendor-$v.log"
exit 99
SH
done
cat > "$T/credlib.sh" <<'SH'
cred_probe() { echo "${STUB_EP:-NO_ENDPOINT}"; }
cred_account_fp() { echo fp1; }
cred_inference_claim() { printf '%s\n' "$*" >> "$LOGD/claims"; return "${STUB_CLAIM_RC:-0}"; }
cred_inference_record() { printf '%s\n' "$*" >> "$LOGD/records"; }
SH
# the D1 mutation: a claim that always says "spend"
sed 's/return "${STUB_CLAIM_RC:-0}"/return 0/' "$T/credlib.sh" > "$T/credlib-mut.sh"
chmod +x "$H/bin/"*.sh "$T/fakebin/"*

# probe <logdir> [VAR=val ...] -- <args...>: the production entry point
probe() {
  local L="$1"; shift
  local envs=()
  while [ "$1" != -- ]; do envs+=("$1"); shift; done; shift
  scratch_rm "$L" || return 1; mkdir -p "$L"
  env -i PATH="$T/fakebin:/usr/bin:/bin" HOME="$T" HARNESS="$H" HARNESS_ENV_DIR="$H/env" \
    LOGD="$L" CRED_PROBE_LIB="$T/credlib.sh" "${envs[@]}" \
    bash "$H/bin/lane-probe.sh" "$@" >"$L/out" 2>"$L/err"
  echo $? > "$L/rc"
}
lines() { [ -f "$1" ] && grep -c . "$1" || echo 0; }
vendor_lines() { cat "$1"/vendor-*.log 2>/dev/null | grep -c . ; }

# ---- E1 -----------------------------------------------------------------------
L="$T/e1"; probe "$L" STUB_EP="ALIVE 200" STUB_CLAIM_RC=1 -- --endpoint openrouter
[ "$(cat "$L/rc")" = 0 ] && ok || bad "E1 rc=$(cat "$L/rc"): $(cat "$L/err")"
[ "$(head -1 "$L/out")" = "ALIVE 200" ] && ok || bad "E1 line 1 is not the endpoint verdict: $(cat "$L/out")"
[ "$(lines "$L/ac.log")" = 0 ] && ok || bad "E1 claim rc 1 still called agent-call: $(cat "$L/ac.log")"
[ "$(vendor_lines "$L")" = 0 ] && ok || bad "E1 a vendor CLI ran: $(cat "$L"/vendor-*.log)"
[ "$(lines "$L/claims")" = 1 ] && grep -qx 'openrouter fp1' "$L/claims" && ok || bad "E1 claim not asked as 'openrouter fp1': $(cat "$L/claims" 2>/dev/null)"
[ "$(lines "$L/records")" = 0 ] && ok || bad "E1 recorded without spending: $(cat "$L/records")"

# ---- E2 -----------------------------------------------------------------------
L="$T/e2"; probe "$L" STUB_EP="ALIVE 200" STUB_CLAIM_RC=0 -- --endpoint openrouter
[ "$(lines "$L/ac.log")" = 1 ] && ok || bad "E2 want exactly 1 agent-call, got: $(cat "$L/ac.log" 2>/dev/null)"
grep -q '^canary fleet m-test 120 .* Reply with exactly: ok$' "$L/ac.log" 2>/dev/null && ok || bad "E2 agent-call argv: $(cat "$L/ac.log" 2>/dev/null)"
grep -qx 'AGENT_CALL_RUNNERS=openrouter AGENT_CALL_LANE=claude-auth-check ACCOUNT_ROUTING=0' "$L/ac.env" 2>/dev/null && ok || bad "E2 agent-call env: $(cat "$L/ac.env" 2>/dev/null)"
[ "$(head -1 "$L/out")" = "ALIVE 200" ] && ok || bad "E2 line 1: $(cat "$L/out")"
grep -qx INFERENCE "$L/out" && grep -qx ok "$L/out" && ok || bad "E2 inference section missing: $(cat "$L/out")"
[ "$(cat "$L/records" 2>/dev/null)" = "openrouter fp1 ok" ] && ok || bad "E2 record: $(cat "$L/records" 2>/dev/null)"
[ "$(vendor_lines "$L")" = 0 ] && ok || bad "E2 a vendor CLI ran: $(cat "$L"/vendor-*.log)"

# ---- E3 -----------------------------------------------------------------------
L="$T/e3"; probe "$L" STUB_EP="NO_ENDPOINT" STUB_CLAIM_RC=2 -- --endpoint openrouter
[ "$(lines "$L/ac.log")" = 0 ] && ok || bad "E3 claim rc 2 spent: $(cat "$L/ac.log")"
[ "$(lines "$L/records")" = 0 ] && ok || bad "E3 recorded: $(cat "$L/records")"
[ "$(head -1 "$L/out")" = NO_ENDPOINT ] && ok || bad "E3 line 1: $(cat "$L/out")"
grep -qx INFERENCE "$L/out" && bad "E3 printed an INFERENCE section: $(cat "$L/out")" || ok

# ---- E4: lane first ------------------------------------------------------------
L="$T/e4"; probe "$L" STUB_EP="ALIVE 200" STUB_CLAIM_RC=1 -- openrouter --endpoint
[ "$(head -1 "$L/out")" = "ALIVE 200" ] && ok || bad "E4 line 1: $(cat "$L/out")"
[ "$(lines "$L/ac.log")" = 0 ] && [ "$(vendor_lines "$L")" = 0 ] && ok || bad "E4 spent: $(cat "$L/ac.log" "$L"/vendor-*.log 2>/dev/null)"

# ---- E5: refused = nothing billed = no record -----------------------------------
L="$T/e5"; probe "$L" STUB_EP="NO_ENDPOINT" STUB_CLAIM_RC=0 STUB_AC_RC=74 -- --endpoint grok
[ "$(lines "$L/ac.log")" = 1 ] && ok || bad "E5 agent-call not tried: $(cat "$L/ac.log" 2>/dev/null)"
[ "$(lines "$L/records")" = 0 ] && ok || bad "E5 a refused call was recorded: $(cat "$L/records")"
[ "$(cat "$L/rc")" = 0 ] && ok || bad "E5 --endpoint must exit 0 (the verdict is the text): rc=$(cat "$L/rc")"

# ---- D: default mode grok --------------------------------------------------------
L="$T/d"; probe "$L" -- grok
[ "$(lines "$L/ac.log")" = 1 ] && ok || bad "D want exactly 1 agent-call: $(cat "$L/ac.log" 2>/dev/null)"
grep -q '^canary fleet m-test 120 .* Reply with exactly: ok$' "$L/ac.log" 2>/dev/null && ok || bad "D argv: $(cat "$L/ac.log" 2>/dev/null)"
grep -q '^AGENT_CALL_RUNNERS=grok AGENT_CALL_LANE=claude-auth-check ' "$L/ac.env" 2>/dev/null && ok || bad "D env: $(cat "$L/ac.env" 2>/dev/null)"
[ "$(vendor_lines "$L")" = 0 ] && ok || bad "D a vendor CLI ran directly: $(cat "$L"/vendor-*.log)"
grep -qx ok "$L/out" && ok || bad "D the ok line is gone: $(cat "$L/out")"
[ "$(lines "$L/claims")" = 0 ] && ok || bad "D default mode must not claim: $(cat "$L/claims")"

# ---- D-codex ------------------------------------------------------------------
L="$T/dcx"; probe "$L" -- codex
[ "$(head -1 "$L/out")" = "codex-cli-version=1.2.3" ] && ok || bad "D-codex line 1: $(cat "$L/out")"
sed -n '2,$p' "$L/out" | grep -qx ok && ok || bad "D-codex no ok after the version line: $(cat "$L/out")"
[ "$(vendor_lines "$L")" = 0 ] && ok || bad "D-codex codex exec ran directly: $(cat "$L"/vendor-*.log)"

# ---- D-claude: the new claude arm routes the triage role --------------------------
L="$T/dcl"; probe "$L" -- claude
grep -qx 'AGENT_CALL_RUNNERS=claude AGENT_CALL_LANE=claude-auth-check ACCOUNT_ROUTING=0' "$L/ac.env" 2>/dev/null && ok || bad "D-claude env: $(cat "$L/ac.env" 2>/dev/null) $(cat "$L/out" "$L/err")"

# ---- M: mutated claim (always 0) makes E1 spend -----------------------------------
L="$T/m"; probe "$L" STUB_EP="ALIVE 200" STUB_CLAIM_RC=1 CRED_PROBE_LIB="$T/credlib-mut.sh" -- --endpoint openrouter
[ "$(lines "$L/ac.log")" != 0 ] && ok || bad "M the claim-ignoring lib did not spend, so E1's zero proves nothing"

echo "lane-probe-endpoint: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
