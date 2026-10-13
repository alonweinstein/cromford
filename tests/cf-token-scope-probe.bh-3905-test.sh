#!/bin/bash
# tests/cf-token-scope-probe.bh-3905-test.sh — bin/cf-token-scope-probe.sh, run
# as shipped against a scratch harness with npx, curl and timeout stubbed on
# PATH.
#
# WHY IT EXISTS (BH-3905, BH-4089). Acceptance 1 of #3905 is "from the hub,
# wrangler secret put and wrangler d1 execute ... INSERT INTO verdicts both fail
# with an auth error; record the run output". The probe is the tool that makes
# that record. What it must never do: call a timeout or a network error a PASS
# (only an auth error proves the token is narrow), pass while the token is dead
# (P4's positive control), pass while a cached `wrangler login` is on the box
# (P5), leave a probe secret on the worker, or print the token.
#
# Run from anywhere: tests/cf-token-scope-probe.bh-3905-test.sh   (exit 0 = all pass)
set -uo pipefail
DIR=$(cd "$(dirname "$0")/.." && pwd)
. "$(dirname "$0")/lib/scratch.sh" || exit 1
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }

PROBE="$DIR/bin/cf-token-scope-probe.sh"
TOKEN=cf-TOKEN-SENTINEL-4089
mkdir -p "$T/h/bin/lib" "$T/h/logs" "$T/env" "$T/checkout/worker/jobs" "$T/stub"
cp "$DIR/bin/lib/console-pages.sh" "$DIR/bin/lib/env-path.sh" "$T/h/bin/lib/"
echo '{ "name": "harness-jobs", "account_id": "acct-from-jsonc" }' > "$T/checkout/worker/jobs/wrangler.jsonc"
cat > "$T/h/bin/alert-line.sh" <<'SH'
#!/bin/bash
printf '%s\n' "$*" >> "$STUB_DIR/alerts.txt"
exit 0
SH
chmod +x "$T/h/bin/alert-line.sh"

# npx: one record per call (argv, cwd, whether the token reached its env —
# never the value), stdin kept, and an answer chosen by subcommand. Every answer
# echoes the token and a Bearer header back, so an unscrubbed path shows up.
cat > "$T/stub/npx" <<'SH'
#!/bin/bash
tok=unset; [ -n "${CLOUDFLARE_API_TOKEN:-}" ] && tok=set
printf 'argv: %s | cwd: %s | token: %s\n' "$*" "$(pwd)" "$tok" >> "$STUB_DIR/npx.calls"
cat >> "$STUB_DIR/npx.stdin" 2>/dev/null || true
case "$*" in
  *"secret put"*)    out=$NPX_PUT_OUT rc=$NPX_PUT_RC ;;
  *"secret delete"*) out=$NPX_DEL_OUT rc=$NPX_DEL_RC ;;
  *"d1 execute"*INSERT*) out=$NPX_INS_OUT rc=$NPX_INS_RC ;;
  *"d1 execute"*"SELECT 1"*) out=$NPX_SEL_OUT rc=$NPX_SEL_RC ;;
  *whoami*)          out=$NPX_WHO_OUT rc=$NPX_WHO_RC ;;
  *) out="stub: unexpected npx $*" rc=99 ;;
esac
printf '%s\n' "$out"
[ "$tok" = set ] && printf 'debug: token %s Authorization: Bearer %s\n' "$CLOUDFLARE_API_TOKEN" "$CLOUDFLARE_API_TOKEN"
# A Bearer value that is NOT the env token (an OAuth access token, say): only
# the Bearer rule of the scrub can catch it.
printf 'debug: oauth Authorization: Bearer cf-OTHER-BEARER-4089\n'
exit "$rc"
SH
# curl: argv logged (the token must not be in it), stdin kept apart, -o gets the
# body, -w gets the status code.
cat > "$T/stub/curl" <<'SH'
#!/bin/bash
printf '%s\n' "$*" >> "$STUB_DIR/curl.calls"
cat >> "$STUB_DIR/curl.stdin"
o=""; w=""
while [ $# -gt 0 ]; do
  case "$1" in -o) o=$2; shift ;; -w) w=$2; shift ;; esac; shift
done
[ "${CURL_RC:-0}" = 0 ] || exit "$CURL_RC"
if [ -n "$o" ]; then printf '%s' "$CURL_BODY" > "$o"; else printf '%s' "$CURL_BODY"; fi
[ -n "$w" ] && printf '%s' "$CURL_CODE"
exit 0
SH
cat > "$T/stub/timeout" <<'SH'
#!/bin/bash
printf '%s %s\n' "$1" "$2" >> "$STUB_DIR/timeout.calls"
shift
exec "$@"
SH
chmod +x "$T/stub/npx" "$T/stub/curl" "$T/stub/timeout"

AUTH='✘ [ERROR] A request to the Cloudflare API failed. Authentication error [code: 10000]'
reset() {
  rm -rf "$T/h/state"
  : > "$T/npx.calls"; : > "$T/npx.stdin"; : > "$T/curl.calls"; : > "$T/curl.stdin"
  : > "$T/timeout.calls"; : > "$T/alerts.txt"
  printf 'CLOUDFLARE_API_TOKEN=%s\nCLOUDFLARE_ACCOUNT_ID=acct123\n' "$TOKEN" > "$T/env/cloudflare.env"
}
probe() { # probe [VAR=val ...] — run the real script; stdout to out.txt, rc to RC
  ( export PATH="$T/stub:$PATH" STUB_DIR="$T" HARNESS="$T/h" HARNESS_ENV_DIR="$T/env" \
      HARNESS_CHECKOUT="$T/checkout" \
      NPX_PUT_OUT="$AUTH" NPX_PUT_RC=1 NPX_DEL_OUT="Success! Deleted secret BH3905_SCOPE_PROBE" NPX_DEL_RC=0 \
      NPX_INS_OUT="$AUTH" NPX_INS_RC=1 NPX_SEL_OUT="$AUTH" NPX_SEL_RC=1 \
      NPX_WHO_OUT="You are not authenticated. Please run \`wrangler login\`." NPX_WHO_RC=0 \
      CURL_RC=0 CURL_CODE=200 CURL_BODY='{"success":true,"errors":[],"result":{"name":"mission-control"}}' "$@"
    bash "$PROBE" </dev/null >"$T/out.txt" 2>"$T/err.txt" ); RC=$?
}
statefile() { ls "$T/h/state/cf-scope-probe/" 2>/dev/null; }
has() { grep -q "$1" "$T/out.txt"; }

# --- SP1: every probe PASS, exit 0, one dated state file, token nowhere ---------------
reset; probe
[ "$RC" = 0 ] && ok || bad "SP1 all-good fixtures must exit 0, got $RC: $(cat "$T/out.txt" "$T/err.txt")"
for n in 1 2 3 4 5; do has "^P$n PASS" && ok || bad "SP1 expected 'P$n PASS': $(cat "$T/out.txt")"; done
has "^cf-scope-probe: 5/5 PASS" && ok || bad "SP1 summary line: $(tail -1 "$T/out.txt")"
SF=$(statefile)
[ "$(grep -c . <<<"$SF")" = 1 ] && [[ "$SF" =~ ^[0-9]{8}T[0-9]{6}Z\.txt$ ]] && ok || bad "SP1 exactly one state/cf-scope-probe/<UTC>.txt, got '$SF'"
SFP="$T/h/state/cf-scope-probe/$SF"
grep -q "^== P1 " "$SFP" 2>/dev/null && grep -q "Authentication error" "$SFP" && ok || bad "SP1 state file must carry the raw probe output"
grep -q "^P5 PASS" "$SFP" 2>/dev/null && ok || bad "SP1 state file must carry the PASS/FAIL lines too"
grep -qF "$SF" "$T/out.txt" && ok || bad "SP1 summary must name the state file"
for f in "$T/out.txt" "$T/err.txt" "$SFP" "$T/npx.calls" "$T/curl.calls" "$T/timeout.calls" "$T/alerts.txt"; do
  grep -qF "$TOKEN" "$f" 2>/dev/null && bad "SP1 the token leaked into ${f#"$T"/}" || ok
done
grep -qF 'Bearer ***' "$SFP" && ok || bad "SP1 a Bearer value must be scrubbed to 'Bearer ***' in the state file"
grep -qF cf-OTHER-BEARER-4089 "$SFP" "$T/out.txt" && bad "SP1 a Bearer value other than the token leaked unscrubbed" || ok
grep -qF "Bearer $TOKEN" "$T/curl.stdin" && ok || bad "SP1 the Pages GET must carry the token on curl's stdin"
[ "$(grep -c 'cwd: '"$T"'/checkout/worker/jobs ' "$T/npx.calls")" = "$(grep -c . "$T/npx.calls")" ] \
  && ok || bad "SP1 every npx call must run from checkout/worker/jobs: $(cat "$T/npx.calls")"
grep 'secret put BH3905_SCOPE_PROBE --name harness-jobs' "$T/npx.calls" | grep -q 'token: set' && ok || bad "SP1 P1 must reach wrangler with the env token"
grep -c 'd1 execute harness-jobs --remote' "$T/npx.calls" | grep -qx 2 && ok || bad "SP1 two remote d1 executes expected"
grep -F 'INSERT INTO verdicts' "$T/npx.calls" | grep -q 'WHERE 0' && ok || bad "SP1 P2 INSERT must be WHERE 0"
grep whoami "$T/npx.calls" | grep -q 'token: unset' && ok || bad "SP1 P5 whoami must run with the token unset"
grep -q 'secret delete' "$T/npx.calls" && bad "SP1 no delete when the put failed" || ok
grep -q 'accounts/acct123/pages/projects/mission-control' "$T/curl.calls" && ok || bad "SP1 P4 must GET the Pages project: $(cat "$T/curl.calls")"
[ -s "$T/alerts.txt" ] && bad "SP1 an all-pass run writes no alert" || ok

# --- SP2: secret put SUCCEEDS -> deleted at once, P1 FAIL, rc 1, one alert ------------
reset; probe NPX_PUT_OUT="✨ Success! Uploaded secret BH3905_SCOPE_PROBE" NPX_PUT_RC=0
[ "$RC" = 1 ] && ok || bad "SP2 a writable token must exit 1, got $RC"
has "^P1 FAIL" && ok || bad "SP2 expected 'P1 FAIL': $(cat "$T/out.txt")"
PUT_N=$(grep -n 'secret put' "$T/npx.calls" | head -1 | cut -d: -f1)
DEL_N=$(grep -n 'secret delete BH3905_SCOPE_PROBE --name harness-jobs' "$T/npx.calls" | head -1 | cut -d: -f1)
[ -n "$PUT_N" ] && [ -n "$DEL_N" ] && [ "$DEL_N" -gt "$PUT_N" ] && ok || bad "SP2 the probe secret must be deleted after the put: $(cat "$T/npx.calls")"
[ "$(grep -c . "$T/alerts.txt")" = 1 ] && grep -q 'cf-scope-probe' "$T/alerts.txt" && ok || bad "SP2 exactly one cf-scope-probe alert line: $(cat "$T/alerts.txt")"
grep -q 'NOT deleted' "$T/alerts.txt" && bad "SP2 a delete that worked must not say NOT deleted" || ok
reset; probe NPX_PUT_OUT="Success! Uploaded secret" NPX_PUT_RC=0 NPX_DEL_OUT="$AUTH" NPX_DEL_RC=1
[ "$RC" = 1 ] && grep -q 'NOT deleted' "$T/alerts.txt" && ok || bad "SP2 a failed delete must say so in the alert: $(cat "$T/alerts.txt")"

# --- SP3: d1 must fail with an AUTH error; anything else is FAIL ----------------------
reset; probe NPX_INS_OUT="🚣 Executed 1 command" NPX_INS_RC=0
[ "$RC" = 1 ] && has "^P2 FAIL" && ok || bad "SP3 INSERT rc 0 must be P2 FAIL rc 1: $(cat "$T/out.txt")"
reset; probe NPX_INS_OUT="" NPX_INS_RC=124 NPX_SEL_OUT="" NPX_SEL_RC=124
[ "$RC" = 1 ] && has "^P2 FAIL" && has "^P3 FAIL" && ok || bad "SP3 a timeout (rc 124) is FAIL, never PASS: $(cat "$T/out.txt")"
reset; probe NPX_SEL_OUT="✘ [ERROR] fetch failed: getaddrinfo ENOTFOUND api.cloudflare.com" NPX_SEL_RC=1
[ "$RC" = 1 ] && has "^P3 FAIL" && ok || bad "SP3 a network error is FAIL: $(cat "$T/out.txt")"
reset; probe NPX_INS_OUT="✘ [ERROR] Couldn't find a D1 DB with the name or binding 'harness-jobs'" NPX_INS_RC=1
[ "$RC" = 1 ] && has "^P2 FAIL" && ok || bad "SP3 'Couldn't find a D1 DB' is FAIL: $(cat "$T/out.txt")"
reset; probe NPX_SEL_OUT="" NPX_SEL_RC=1
[ "$RC" = 1 ] && has "^P3 FAIL" && ok || bad "SP3 empty output rc 1 is FAIL: $(cat "$T/out.txt")"
reset; probe NPX_SEL_OUT="Authentication error [code: 10000]" NPX_SEL_RC=0
[ "$RC" = 1 ] && has "^P3 FAIL" && ok || bad "SP3 rc 0 is FAIL even if the text says auth: $(cat "$T/out.txt")"
reset; probe NPX_INS_OUT="✘ [ERROR] A request to the Cloudflare API (/accounts/x/d1/database) failed. [code: 7403] The given account is not valid or is not authorized to access this service" NPX_INS_RC=1
[ "$RC" = 0 ] && ok || bad "SP3 a 7403 not-authorized answer is an auth error (PASS): $(cat "$T/out.txt")"

# --- SP4: P4 needs HTTP 200 AND success:true ------------------------------------------
reset; probe CURL_CODE=403 CURL_BODY='{"success":false,"errors":[{"code":10000,"message":"Authentication error"}]}'
[ "$RC" = 1 ] && has "^P4 FAIL" && ok || bad "SP4 a 403 is P4 FAIL: $(cat "$T/out.txt")"
reset; probe CURL_BODY='{"success":false,"errors":[]}'
[ "$RC" = 1 ] && has "^P4 FAIL" && ok || bad "SP4 200 with success:false is P4 FAIL: $(cat "$T/out.txt")"
reset; probe CURL_RC=28
[ "$RC" = 1 ] && has "^P4 FAIL" && ok || bad "SP4 a curl failure is P4 FAIL: $(cat "$T/out.txt")"

# --- SP5: whoami must say not authenticated -------------------------------------------
reset; probe NPX_WHO_OUT="You are logged in with an OAuth Token, associated with the email ops@example.com."
[ "$RC" = 1 ] && has "^P5 FAIL" && ok || bad "SP5 a cached OAuth login is P5 FAIL: $(cat "$T/out.txt")"
reset; probe NPX_WHO_OUT="You are logged in with an API Token"
[ "$RC" = 1 ] && has "^P5 FAIL" && ok || bad "SP5 an API token login is P5 FAIL: $(cat "$T/out.txt")"

# --- SP6: every npx under timeout 120; preconditions exit 2 before any call -----------
reset; probe
NPX_N=$(grep -c . "$T/npx.calls"); TO_N=$(grep -c '^120 npx$' "$T/timeout.calls")
[ "$NPX_N" = 4 ] && [ "$NPX_N" = "$TO_N" ] && [ "$(grep -c . "$T/timeout.calls")" = "$TO_N" ] \
  && ok || bad "SP6 every npx must be 'timeout 120 npx' (4 calls when P1 is refused): npx=$NPX_N timeout=$(cat "$T/timeout.calls")"
reset; probe NPX_PUT_OUT="Success! Uploaded secret" NPX_PUT_RC=0
NPX_N=$(grep -c . "$T/npx.calls"); TO_N=$(grep -c '^120 npx$' "$T/timeout.calls")
[ "$NPX_N" = 5 ] && [ "$NPX_N" = "$TO_N" ] && [ "$(grep -c . "$T/timeout.calls")" = "$TO_N" ] \
  && ok || bad "SP6 the delete is under 'timeout 120 npx' too (5 calls): npx=$NPX_N timeout=$(cat "$T/timeout.calls")"
reset; rm -f "$T/env/cloudflare.env"; probe
[ "$RC" = 2 ] && ok || bad "SP6 missing cloudflare.env must exit 2, got $RC"
[ -s "$T/npx.calls" ] || [ -s "$T/curl.calls" ] && bad "SP6 missing cloudflare.env must call nothing" || ok
[ -s "$T/out.txt" ] || [ -s "$T/err.txt" ] && ok || bad "SP6 missing cloudflare.env must say why"
reset; mv "$T/checkout/worker/jobs/wrangler.jsonc" "$T/wrangler.jsonc.bak"; probe
[ "$RC" = 2 ] && [ ! -s "$T/npx.calls" ] && ok || bad "SP6 missing worker/jobs/wrangler.jsonc must exit 2 with no npx call, got $RC"
mv "$T/wrangler.jsonc.bak" "$T/checkout/worker/jobs/wrangler.jsonc"

echo "cf-token-scope-probe.bh-3905: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
