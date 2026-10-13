#!/bin/bash
# tests/oauth-refresh-no-haiku.bh-2549-test.sh — BH-2561 (BH-2549.3):
# bin/oauth-refresh.sh refreshes a full login through the direct OAuth token
# endpoint when OAUTH_REFRESH_CLIENT_ID is set, and otherwise falls back to ONE
# CLI call through agent-call.sh on model_routes role auth.fallback — never a
# raw `claude -p --model haiku`.
#
# Runs the REAL script, copied into a scratch $T/bin beside stub libs
# (endpoints.sh, lane-model.sh), a stub agent-call.sh, and curl/claude stubs on
# PATH. Every stub logs its argv so the suite can prove who ran and that the
# refresh token never reached any argv.
#
#   1 client id empty, route m-auth: agent-call once (canary fleet m-auth …),
#     RUNNERS=claude, LANE=oauth-refresh, CLAUDE_CONFIG_DIR, no setup-token;
#     no haiku, no curl, no raw claude; rc 0. A second run calls again (no cap).
#  1c agent-call leaves expiresAt unmoved (refusal rc 76): rc 1.
#   2 client id set, curl 200: file rewritten (AT2/RT2, future expiresAt, other
#     fields kept), mode 600, rc 0, no agent-call; POST /v1/oauth/token with
#     grant_type/refresh_token/client_id in the body file.
#  2b a 200 with no access_token is not success: falls through to agent-call.
#   3 client id set, curl 404: falls through to agent-call, file not written
#     by the direct path.
#  3b curl rc 6 and 3c no refreshToken in the file: both reach agent-call.
#   4 fresh token: rc 0, nothing invoked.
#   5 no route (rc 75): rc 1, nothing invoked, one agent-rules.log line.
#   6 no .credentials.json: rc 2.
#   7 the refresh token string appears in no argv log.
#
# Mutation (run by hand once): put `--model haiku` back / pass `haiku` as the
# model argument in the fallback call, and case 1 goes red.
# Run: HARNESS_TEST_SANDBOX=1 bash tests/oauth-refresh-no-haiku.bh-2549-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
SRC="$DIR/bin/oauth-refresh.sh"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
RT='RT-SECRET-bh2561'

mkdir -p "$T/bin/lib" "$T/stubs" "$T/logs" "$T/cfg" "$T/argv"
cp "$SRC" "$T/bin/oauth-refresh.sh"; chmod +x "$T/bin/oauth-refresh.sh"

cat > "$T/bin/lib/endpoints.sh" <<'S'
endpoint_url() { [ "$1" = anthropic-oauth ] || return 1; echo "http://stub.invalid"; }
S
cat > "$T/bin/lib/lane-model.sh" <<'S'
lane_role_model() {
  [ "$1" = auth.fallback ] || { echo "WRONG_ROLE:$1" >> "$ARGV/role.log"; return 1; }
  [ -n "${ROUTE:-}" ] || return 75
  echo "$ROUTE"
}
S
cat > "$T/bin/agent-call.sh" <<'S'
#!/bin/bash
printf '%s\n' "$*" >> "$ARGV/agent-call.log"
echo "RUNNERS=${AGENT_CALL_RUNNERS:-} LANE=${AGENT_CALL_LANE:-} CDIR=${CLAUDE_CONFIG_DIR:-} TOKEN=${CLAUDE_CODE_OAUTH_TOKEN:-} APIKEY=${ANTHROPIC_API_KEY:-} ROUTING=${ACCOUNT_ROUTING:-}" >> "$ARGV/agent-call.env"
f="$CLAUDE_CONFIG_DIR/.credentials.json"
[ -n "${NOBUMP:-}" ] && { echo "refused" > "$5"; exit "$NOBUMP"; }
n=$(( ($(date -u +%s) + 28800) * 1000 ))
jq --argjson n "$n" '.claudeAiOauth.expiresAt=$n | .claudeAiOauth.accessToken="AT-CLI"' "$f" > "$f.t" && mv "$f.t" "$f"
echo ok > "$5"
exit 0
S
chmod +x "$T/bin/agent-call.sh"
cat > "$T/stubs/curl" <<'S'
#!/bin/bash
printf '%s\n' "$*" >> "$ARGV/curl.log"
o=""
while [ $# -gt 0 ]; do
  case "$1" in
    -o) o="$2"; shift ;;
    --data|--data-binary|-d) case "$2" in @*) cat "${2#@}" >> "$ARGV/curl-body.log"; echo >> "$ARGV/curl-body.log" ;; esac; shift ;;
  esac
  shift
done
[ -n "$o" ] && printf '%s' "${CURL_BODY:-}" > "$o"
printf '%s' "${CURL_CODE:-000}"
exit "${CURL_RC:-0}"
S
cat > "$T/stubs/claude" <<'S'
#!/bin/bash
printf '%s\n' "$*" >> "$ARGV/claude.log"
exit 0
S
chmod +x "$T/stubs/curl" "$T/stubs/claude"

now_ms() { echo $(( $(date -u +%s) * 1000 )); }
reset() {  # reset <expiresAt-offset-seconds>
  rm -f "$T/argv/"* "$T/logs/agent-rules.log"
  local e=$(( ($(date -u +%s) + $1) * 1000 ))
  jq -n --arg rt "$RT" --argjson e "$e" '{claudeAiOauth:{accessToken:"AT1",refreshToken:$rt,expiresAt:$e,scopes:["user:inference"],subscriptionType:"max"},other:{keep:1}}' > "$T/cfg/.credentials.json"
  chmod 600 "$T/cfg/.credentials.json"
}
run() {  # run [VAR=val ...] -> rc in RC
  env -u CLAUDE_CODE_OAUTH_TOKEN -u OAUTH_REFRESH_CLIENT_ID -u CLAUDE_CONFIG_DIR \
    CLAUDE_CODE_OAUTH_TOKEN=sk-ant-oat01-setup ANTHROPIC_API_KEY=sk-api \
    PATH="$T/stubs:$PATH" HARNESS="$T" ARGV="$T/argv" "$@" \
    "$T/bin/oauth-refresh.sh" "$T/cfg" >/dev/null 2>&1
  RC=$?
}
lines() { [ -f "$1" ] && wc -l < "$1" | tr -d ' ' || echo 0; }
CAT_ALL_ARGV() { cat "$T/argv/agent-call.log" "$T/argv/curl.log" "$T/argv/claude.log" 2>/dev/null; }
ALL_ARGV=""

# 1 — CLI fallback through agent-call on auth.fallback, no haiku, no cap
reset 60
run ROUTE=m-auth
[ "$RC" = 0 ] || bad "1 rc=$RC want 0"
[ "$(lines "$T/argv/agent-call.log")" = 1 ] || bad "1 agent-call invoked $(lines "$T/argv/agent-call.log") times, want 1"
a=$(cat "$T/argv/agent-call.log" 2>/dev/null)
case "$a" in "canary fleet m-auth "[0-9]*" /"*"/out reply ok") ok ;; *) bad "1 agent-call argv: '$a'" ;; esac
case "$a" in *haiku*) bad "1 haiku in agent-call argv: $a" ;; *) ok ;; esac
e=$(cat "$T/argv/agent-call.env" 2>/dev/null)
[ "$e" = "RUNNERS=claude LANE=oauth-refresh CDIR=$T/cfg TOKEN= APIKEY= ROUTING=0" ] && ok || bad "1 agent-call env: '$e'"
[ ! -s "$T/argv/curl.log" ] && ok || bad "1 curl ran with an empty client id"
[ ! -s "$T/argv/claude.log" ] && ok || bad "1 raw claude ran: $(cat "$T/argv/claude.log")"
[ ! -s "$T/argv/role.log" ] && ok || bad "1 $(cat "$T/argv/role.log")"
[ "$(jq -r .claudeAiOauth.accessToken "$T/cfg/.credentials.json")" = AT-CLI ] && ok || bad "1 file not refreshed by the CLI stub"
ALL_ARGV+=$(CAT_ALL_ARGV)
reset 60
run ROUTE=m-auth
[ "$RC" = 0 ] && [ "$(lines "$T/argv/agent-call.log")" = 1 ] && ok || bad "1b second run: rc=$RC agent-call=$(lines "$T/argv/agent-call.log") (a cap?)"
ALL_ARGV+=$(CAT_ALL_ARGV)

# 1c — agent-call ran but the expiry did not move (a 74..79 refusal): rc 1
reset 60
run ROUTE=m-auth NOBUMP=76
[ "$RC" = 1 ] && ok || bad "1c rc=$RC want 1 when expiresAt did not move"
[ "$(lines "$T/argv/agent-call.log")" = 1 ] && ok || bad "1c agent-call not invoked"
grep -q 'rc=76' "$T/logs/agent-rules.log" 2>/dev/null && ok || bad "1c log line lacks rc=76: $(cat "$T/logs/agent-rules.log" 2>/dev/null)"
ALL_ARGV+=$(CAT_ALL_ARGV)

# 2 — direct refresh, 200
reset 60
t0=$(now_ms)
run ROUTE=m-auth OAUTH_REFRESH_CLIENT_ID=cid-test CURL_CODE=200 \
  CURL_BODY='{"access_token":"AT2","refresh_token":"RT2","expires_in":28800}'
[ "$RC" = 0 ] || bad "2 rc=$RC want 0"
F="$T/cfg/.credentials.json"
[ "$(stat -c %a "$F")" = 600 ] && ok || bad "2 mode $(stat -c %a "$F") want 600"
[ "$(jq -r .claudeAiOauth.accessToken "$F")" = AT2 ] && ok || bad "2 accessToken $(jq -r .claudeAiOauth.accessToken "$F")"
[ "$(jq -r .claudeAiOauth.refreshToken "$F")" = RT2 ] && ok || bad "2 refreshToken not rotated"
ex=$(jq -r .claudeAiOauth.expiresAt "$F")
[ "$ex" -gt $(( t0 + 28000 * 1000 )) ] 2>/dev/null && ok || bad "2 expiresAt $ex not ~now+8h"
[ "$(jq -c '[.claudeAiOauth.scopes,.claudeAiOauth.subscriptionType,.other]' "$F")" = '[["user:inference"],"max",{"keep":1}]' ] && ok || bad "2 other fields lost: $(jq -c . "$F")"
[ ! -s "$T/argv/agent-call.log" ] && ok || bad "2 agent-call invoked after a direct success"
[ ! -s "$T/argv/claude.log" ] && ok || bad "2 raw claude ran"
case "$(cat "$T/argv/curl.log" 2>/dev/null)" in *"http://stub.invalid/v1/oauth/token"*) ok ;; *) bad "2 curl URL: $(cat "$T/argv/curl.log" 2>/dev/null)" ;; esac
b=$(cat "$T/argv/curl-body.log" 2>/dev/null)
[ "$(printf '%s' "$b" | jq -c '[.grant_type,.refresh_token,.client_id]' 2>/dev/null)" = "[\"refresh_token\",\"$RT\",\"cid-test\"]" ] && ok || bad "2 body: '$b'"
grep -q 'oauth-refresh' "$T/logs/agent-rules.log" 2>/dev/null && ok || bad "2 no agent-rules.log line"
grep -q -e "$RT" -e AT2 -e RT2 "$T/logs/agent-rules.log" 2>/dev/null && bad "2 token in agent-rules.log" || ok
left=$(find "$T/cfg" -name '.credentials.json.*')
[ -z "$left" ] && ok || bad "2 temp file left: $left"
ALL_ARGV+=$(CAT_ALL_ARGV)

# 2b — 200 without an access_token is not success
reset 60
run ROUTE=m-auth OAUTH_REFRESH_CLIENT_ID=cid-test CURL_CODE=200 CURL_BODY='{"expires_in":28800}'
[ "$RC" = 0 ] && [ "$(lines "$T/argv/agent-call.log")" = 1 ] && [ "$(jq -r .claudeAiOauth.accessToken "$F")" = AT-CLI ] \
  && ok || bad "2b 200 without access_token: rc=$RC agent-call=$(lines "$T/argv/agent-call.log")"
ALL_ARGV+=$(CAT_ALL_ARGV)

# 3 — direct 404 falls through to the CLI
reset 60
run ROUTE=m-auth OAUTH_REFRESH_CLIENT_ID=cid-test CURL_CODE=404 CURL_BODY='not found'
[ "$RC" = 0 ] || bad "3 rc=$RC want 0"
[ "$(lines "$T/argv/curl.log")" = 1 ] && ok || bad "3 curl not invoked once"
[ "$(lines "$T/argv/agent-call.log")" = 1 ] && ok || bad "3 agent-call invoked $(lines "$T/argv/agent-call.log") times, want 1"
[ "$(jq -r .claudeAiOauth.accessToken "$F")" != AT2 ] && ok || bad "3 direct path wrote the file on a 404"
grep -q '404' "$T/logs/agent-rules.log" 2>/dev/null && ok || bad "3 no log line naming the 404"
ALL_ARGV+=$(CAT_ALL_ARGV)

# 3b — curl itself fails (rc 6, no HTTP code): falls through to the CLI
reset 60
run ROUTE=m-auth OAUTH_REFRESH_CLIENT_ID=cid-test CURL_CODE=000 CURL_RC=6
[ "$RC" = 0 ] && [ "$(lines "$T/argv/agent-call.log")" = 1 ] && ok || bad "3b curl rc 6: rc=$RC agent-call=$(lines "$T/argv/agent-call.log")"
ALL_ARGV+=$(CAT_ALL_ARGV)

# 3c — no refreshToken in the file: direct is skipped, CLI runs
reset 60
jq 'del(.claudeAiOauth.refreshToken)' "$F" > "$F.t" && mv "$F.t" "$F"
run ROUTE=m-auth OAUTH_REFRESH_CLIENT_ID=cid-test CURL_CODE=200 CURL_BODY='{"access_token":"AT2","expires_in":28800}'
[ ! -s "$T/argv/curl.log" ] && [ "$(lines "$T/argv/agent-call.log")" = 1 ] && [ "$RC" = 0 ] && ok \
  || bad "3c no refreshToken: rc=$RC curl=$(lines "$T/argv/curl.log") agent-call=$(lines "$T/argv/agent-call.log")"
ALL_ARGV+=$(CAT_ALL_ARGV)

# 4 — fresh token: nothing runs
reset 7200
run ROUTE=m-auth OAUTH_REFRESH_CLIENT_ID=cid-test CURL_CODE=200 CURL_BODY='{"access_token":"AT2","expires_in":28800}'
[ "$RC" = 0 ] && ok || bad "4 rc=$RC want 0"
[ -z "$(CAT_ALL_ARGV)" ] && ok || bad "4 something ran on a fresh token: $(CAT_ALL_ARGV)"
[ "$(jq -r .claudeAiOauth.accessToken "$F")" = AT1 ] && ok || bad "4 file changed"

# 5 — no route: one line, no call, rc 1
reset 60
run ROUTE=
[ "$RC" = 1 ] && ok || bad "5 rc=$RC want 1"
[ -z "$(CAT_ALL_ARGV)" ] && ok || bad "5 something ran with no route: $(CAT_ALL_ARGV)"
[ "$(lines "$T/logs/agent-rules.log")" = 1 ] && ok || bad "5 agent-rules.log has $(lines "$T/logs/agent-rules.log") lines, want 1"

# 6 — no credentials file
rm -f "$T/cfg/.credentials.json"
run ROUTE=m-auth
[ "$RC" = 2 ] && ok || bad "6 rc=$RC want 2"

# 7 — the refresh token never reached any argv
[ -n "$ALL_ARGV" ] || bad "7 no argv captured at all (vacuous)"
case "$ALL_ARGV" in *"$RT"*) bad "7 refresh token in an argv log" ;; *) ok ;; esac

echo "oauth-refresh-no-haiku: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
