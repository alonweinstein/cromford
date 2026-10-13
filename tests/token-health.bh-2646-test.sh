#!/bin/bash
# tests/token-health.bh-2646-test.sh — BH-2646 (BH-2516.2): the OAuth and GitHub
# App token health producers. Drives the REAL bin/lib/token-health.sh,
# bin/oauth-refresh.sh, bin/gh-token.sh, bin/quota-poll.sh and
# bin/extra-usage-track.sh in a scratch HARNESS, with curl and claude stubbed
# on PATH. The jobs worker is http://jobs.test, which only the curl stub
# answers, so nothing here can reach a real worker.
#
#   L1  one call = one POST to /api/account-leases/token-health, -m 5, and the
#       body {kind,subject,box,ok,expires_at,error}
#   L2  TOKEN_HEALTH_REPORT=0 -> no request; a normal call prints nothing
#   L2b JOBS_URL= (empty) -> no request
#   L3  the worker times out (curl rc 28) -> rc 0, one attempt, no retry
#   L4  under set -euo pipefail the caller keeps running, options unchanged
#   L5  token-shaped words are dropped from the error; it is cut to 200 chars
#   L6  bad kind / status / empty subject -> one stderr line, no POST, rc 0
#   O1  fresh file + ACCOUNT -> rc 0, one ok POST with the file's expiry (ISO)
#   O1b expired file the CLI refreshes -> rc 0, one ok POST with the new expiry
#   O2  expired file the CLI cannot refresh -> rc 1, one fail POST "still expired…"
#   O3  no file -> rc 2, no POST
#   O4  no ACCOUNT -> same rc as O1/O2, no POST
#   C1  quota-poll.sh passes the account name, extra-usage-track.sh the label
#   G1  a mint prints exactly the token and posts gh_app app-<id> ok <expiry>,
#       and the token never appears in the body
#   G1b a cache hit posts nothing
#   G2  access_tokens answers {} -> one fail POST for app-<id>, rc unchanged
#   G3  installation lookup empty -> one fail POST for app-unresolved-<owner>
#   G4  bin/lib/token-health.sh absent -> the mint still works, no POST
#
# Run from anywhere: bash tests/token-health.bh-2646-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null 2>&1 || { echo "jq missing — skipping"; exit 0; }

mkdir -p "$T/bin/lib/jobs" "$T/env" "$T/logs" "$T/state" "$T/flags" "$T/locks" "$T/fakebin"
cp "$DIR/bin/lib/token-health.sh" "$DIR/bin/lib/env-path.sh" \
   "$DIR/bin/lib/gh-app-auth.sh" "$DIR/bin/lib/gh-repo-token.sh" "$T/bin/lib/"
cp "$DIR/bin/jobs-client.sh" "$DIR/bin/oauth-refresh.sh" "$DIR/bin/gh-token.sh" "$T/bin/"
cp "$DIR"/bin/lib/jobs/*.sh "$T/bin/lib/jobs/"
# oauth-refresh's CLI fallback (BH-2561) resolves role auth.fallback through
# lib/lane-model.sh and calls agent-call.sh; the stub runs the claude stub below
# with its output in the out file (arg 5) and passes its rc through.
cat > "$T/bin/lib/lane-model.sh" <<'SH'
lane_role_model() { [ "$1" = auth.fallback ] && echo m-auth; }
SH
cat > "$T/bin/agent-call.sh" <<'SH'
#!/bin/bash
claude -p "$6" > "$5" 2>&1
SH
chmod +x "$T/bin/"*.sh

# --- curl stub ---------------------------------------------------------------
# Jobs calls (http://jobs.test/...): argv to $CALLS (one line), body to $BODIES
# (one line), answered 202 in the `-w '\n%{http_code}'` shape, or rc 28 when
# CURL_MODE=timeout. GitHub calls (http://api.test/...) answer the endpoints
# bin/gh-token.sh uses; MINT_MODE=empty answers access_tokens with {}.
cat > "$T/fakebin/curl" <<'SH'
#!/bin/bash
ARGV="$*"; URL=""; BODY=""
while [ $# -gt 0 ]; do
  case "$1" in
    -d|--data-binary) BODY="$2"; shift 2 ;;
    -H|-X|-m|-w|-o|-D|--connect-timeout) shift 2 ;;
    -*) shift ;;
    *) URL="$1"; shift ;;
  esac
done
case "$BODY" in @*) BODY=$(cat "${BODY#@}") ;; esac
case "$URL" in
  http://jobs.test/*)
    printf '%s\n' "$ARGV" >> "$CALLS"; printf '%s\n' "$BODY" >> "$BODIES"
    [ "${CURL_MODE:-}" = timeout ] && exit 28
    printf '{"ok":true}\n202'; exit 0 ;;
  */app/installations)
    [ "${INSTALL_MODE:-}" = empty ] && { echo '[]'; exit 0; }
    echo '[{"id":4242,"account":{"login":"TestOwner"}}]' ;;
  */access_tokens)
    [ "${MINT_MODE:-}" = empty ] && { echo '{}'; exit 0; }
    printf '{"token":"fake-token-xyz","expires_at":"%s"}\n' "$MINT_EXP" ;;
  */rate_limit) echo '{"rate":{"remaining":4999,"limit":5000}}' ;;
  *) echo '{}' ;;
esac
SH
# --- claude stub: CLAUDE_MODE=refresh rewrites the file to NEW_EXP ms ---------
cat > "$T/fakebin/claude" <<'SH'
#!/bin/bash
[ "${CLAUDE_MODE:-}" = refresh ] && \
  printf '{"claudeAiOauth":{"accessToken":"a","expiresAt":%s}}\n' "$NEW_EXP" > "$CLAUDE_CONFIG_DIR/.credentials.json"
echo "Error: could not refresh the login"
exit 3
SH
chmod +x "$T/fakebin/curl" "$T/fakebin/claude"

export PATH="$T/fakebin:$PATH" HARNESS="$T" HARNESS_SECRET=test JOBS_URL=http://jobs.test \
  JOBS_BOX=testbox CALLS="$T/calls" BODIES="$T/bodies"
unset TOKEN_HEALTH_REPORT CURL_MODE
reset() { : > "$CALLS"; : > "$BODIES"; }
n_posts() { grep -c '/api/account-leases/token-health' "$CALLS" 2>/dev/null; }
LIB="$T/bin/lib/token-health.sh"
report() { bash -c '. "$1"; shift; token_health_report "$@"' _ "$LIB" "$@"; }

# ---------- L1 ---------------------------------------------------------------
reset
out=$(report oauth acct1 ok 2026-09-27T12:00:00Z); rc=$?
[ "$rc" = 0 ] && [ "$(n_posts)" = 1 ] && ok || bad "L1 rc=$rc posts=$(n_posts)"
grep -q -- '-m 5 ' "$CALLS" && grep -q -- '-X POST' "$CALLS" \
  && grep -q 'http://jobs.test/api/account-leases/token-health$' "$CALLS" \
  && ok || bad "L1 argv: $(cat "$CALLS")"
jq -e '. == {kind:"oauth",subject:"acct1",box:"testbox",ok:true,expires_at:"2026-09-27T12:00:00Z",error:null}' \
  "$BODIES" >/dev/null 2>&1 && ok || bad "L1 body: $(cat "$BODIES")"

# ---------- L2 ---------------------------------------------------------------
[ -z "$out" ] && ok || bad "L2 a normal call printed '$out'"
reset
out=$(TOKEN_HEALTH_REPORT=0 report oauth acct1 ok); rc=$?
[ "$rc" = 0 ] && [ -z "$out" ] && [ "$(n_posts)" = 0 ] && ok || bad "L2 TOKEN_HEALTH_REPORT=0 rc=$rc posts=$(n_posts)"

# ---------- L2b --------------------------------------------------------------
reset
out=$(JOBS_URL='' report oauth acct1 ok); rc=$?
[ "$rc" = 0 ] && [ -z "$out" ] && [ "$(n_posts)" = 0 ] && ok || bad "L2b empty JOBS_URL rc=$rc posts=$(n_posts)"

# ---------- L3 ---------------------------------------------------------------
reset
out=$(CURL_MODE=timeout report gh_app app-1 fail "" boom 2>&1); rc=$?
[ "$rc" = 0 ] && [ -z "$out" ] && [ "$(n_posts)" = 1 ] && ok || bad "L3 timeout rc=$rc out='$out' attempts=$(n_posts)"
! grep -q 'harness-jobs unreachable' "$T/logs/ALERTS.log" 2>/dev/null && ok || bad "L3 a failed report wrote ALERTS.log"

# ---------- L4 ---------------------------------------------------------------
reset
out=$(CURL_MODE=timeout bash -c 'set -euo pipefail; before=$(set -o); . "$1"
  token_health_report oauth acct1 fail "" boom; [ "$(set -o)" = "$before" ] && echo SAME; echo AFTER' _ "$LIB" 2>/dev/null)
[ "$out" = "SAME
AFTER" ] && ok || bad "L4 set -euo pipefail caller: '$out'"
out=$(bash -c 'set +u; set +o pipefail; before=$(set -o); . "$1"
  token_health_report oauth acct1 ok; [ "$(set -o)" = "$before" ] && echo SAME' _ "$LIB" 2>/dev/null)
[ "$out" = SAME ] && ok || bad "L4 the client's set -uo pipefail leaked into a lax caller: '$out'"

# ---------- L5 ---------------------------------------------------------------
reset
report gh_app app-1 fail "" "boom ghs_abc123 rc=1 sk-ant-oat01-x eyJhbGci.x ghost github_pat_11x ghp_y gho_z ghu_w ghr_v
eyes skip ghx_q *"
e=$(jq -r '.error' "$BODIES")
[ "$e" = "boom rc=1 ghost eyes skip ghx_q *" ] && ok || bad "L5 scrub: '$e'"
reset
report gh_app app-1 fail "" "$(printf 'x%.0s' $(seq 1 1000))"
e=$(jq -r '.error' "$BODIES")
[ "${#e}" = 200 ] && ok || bad "L5 1000-char error posted at ${#e} chars"

# ---------- L6 ---------------------------------------------------------------
reset
for args in "nope acct1 ok" "oauth acct1 maybe" "oauth '' ok"; do
  eval "set -- $args"
  out=$(report "$@" 2>"$T/l6.err"); rc=$?
  [ "$rc" = 0 ] && [ -z "$out" ] && [ "$(wc -l < "$T/l6.err")" = 1 ] && ok || bad "L6 '$args' rc=$rc stderr=$(cat "$T/l6.err")"
done
[ "$(n_posts)" = 0 ] && ok || bad "L6 misuse posted $(n_posts) time(s)"

# ---------- oauth-refresh ----------------------------------------------------
CDIR="$T/cfg"; mkdir -p "$CDIR"
now_s=$(date -u +%s)
cred() { printf '{"claudeAiOauth":{"accessToken":"a","expiresAt":%s}}\n' "$1" > "$CDIR/.credentials.json"; }
iso() { date -u -d "@$(( $1 / 1000 ))" +%FT%TZ; }
refresh() { bash "$T/bin/oauth-refresh.sh" "$@" >/dev/null 2>&1; }

# O1
reset; FRESH=$(( (now_s + 36000) * 1000 )); cred "$FRESH"
refresh "$CDIR" acct1; rc=$?
[ "$rc" = 0 ] && [ "$(n_posts)" = 1 ] && ok || bad "O1 rc=$rc posts=$(n_posts)"
jq -e --arg e "$(iso "$FRESH")" '. == {kind:"oauth",subject:"acct1",box:"testbox",ok:true,expires_at:$e,error:null}' \
  "$BODIES" >/dev/null 2>&1 && ok || bad "O1 body: $(cat "$BODIES")"
# O1b
reset; NEW=$(( (now_s + 28800) * 1000 )); cred $(( (now_s - 60) * 1000 ))
CLAUDE_MODE=refresh NEW_EXP="$NEW" refresh "$CDIR" acct1; rc=$?
[ "$rc" = 0 ] && [ "$(n_posts)" = 1 ] && ok || bad "O1b rc=$rc posts=$(n_posts)"
jq -e --arg e "$(iso "$NEW")" '.ok == true and .expires_at == $e' "$BODIES" >/dev/null 2>&1 \
  && ok || bad "O1b body: $(cat "$BODIES")"
# O2
reset; cred $(( (now_s - 60) * 1000 ))
refresh "$CDIR" acct1; rc=$?
[ "$rc" = 1 ] && [ "$(n_posts)" = 1 ] && ok || bad "O2 rc=$rc posts=$(n_posts)"
jq -e '.ok == false and .expires_at == null and .subject == "acct1"
       and (.error | startswith("still expired")) and (.error | contains("rc=3"))' "$BODIES" >/dev/null 2>&1 \
  && ok || bad "O2 body: $(cat "$BODIES")"
# O3
reset; rm -f "$CDIR/.credentials.json"
refresh "$CDIR" acct1; rc=$?
[ "$rc" = 2 ] && [ "$(n_posts)" = 0 ] && ok || bad "O3 rc=$rc posts=$(n_posts)"
# O4
reset; cred "$FRESH"; refresh "$CDIR"; rc=$?
[ "$rc" = 0 ] && [ "$(n_posts)" = 0 ] && ok || bad "O4 fresh, no ACCOUNT: rc=$rc posts=$(n_posts)"
reset; cred $(( (now_s - 60) * 1000 )); refresh "$CDIR"; rc=$?
[ "$rc" = 1 ] && [ "$(n_posts)" = 0 ] && ok || bad "O4 expired, no ACCOUNT: rc=$rc posts=$(n_posts)"

# ---------- C1: the callers pass the label -----------------------------------
C="$T/c1"; mkdir -p "$C/bin/lib/jobs" "$C/env/accounts.d" "$C/state/quota" "$C/logs" "$C/flags" "$C/cfg-b" "$C/cfg-own"
cp "$DIR/bin/quota-poll.sh" "$DIR/bin/account-pick.sh" "$DIR/bin/extra-usage-track.sh" "$DIR/bin/jobs-client.sh" "$C/bin/"
cp "$DIR"/bin/lib/jobs/*.sh "$C/bin/lib/jobs/"
cat > "$C/bin/oauth-refresh.sh" <<'EOF'
#!/bin/bash
printf '%s|%s\n' "$1" "${2:-}" >> "$REFRESH_SINK"
exit 0
EOF
chmod +x "$C/bin/"*.sh
printf '{"claudeAiOauth":{"accessToken":"live-b","expiresAt":99999999999999}}\n' > "$C/cfg-b/.credentials.json"
printf 'ACCOUNT_NAME=acctb\nACCOUNT_VENDOR=claude\nCLAUDE_CONFIG_DIR=%s\n' "$C/cfg-b" > "$C/env/accounts.d/acctb.env"
printf '#!/bin/bash\necho %s\n' "'{\"five_hour\":{\"utilization\":1},\"seven_day\":{\"utilization\":2}}'" > "$C/fetch.sh"; chmod +x "$C/fetch.sh"
: > "$C/refreshed"
env HARNESS="$C" HOME="$C" ACCOUNTS_DIR="$C/env/accounts.d" OAUTH_USAGE_FETCH="$C/fetch.sh" \
  ACCOUNT_POLL_STAGGER_SECS=0 REFRESH_SINK="$C/refreshed" bash "$C/bin/quota-poll.sh" >/dev/null 2>&1
grep -qx "$C/cfg-b|acctb" "$C/refreshed" && ok || bad "C1 quota-poll did not pass the account name: $(cat "$C/refreshed")"
: > "$C/refreshed"
env HARNESS="$C" HOME="$C" CLAUDE_CONFIG_DIR="$C/cfg-own" EXTRA_USAGE_LOGINS="mylabel=$C/cfg-b" \
  OAUTH_USAGE_URL="http://127.0.0.1:9/none" REFRESH_SINK="$C/refreshed" \
  bash "$C/bin/extra-usage-track.sh" hub >/dev/null 2>&1
grep -qx "$C/cfg-b|mylabel" "$C/refreshed" && ok || bad "C1 extra-usage-track did not pass the login label: $(cat "$C/refreshed")"

# ---------- gh-token mint ----------------------------------------------------
command -v openssl >/dev/null 2>&1 || { echo "openssl missing — gh_app cases skipped"; echo "token-health: $PASS passed, $FAIL failed"; [ "$FAIL" = 0 ]; exit; }
openssl genrsa -out "$T/env/github-app.pem" 2048 2>/dev/null; chmod 600 "$T/env/github-app.pem"
printf 'GH_APP_ID=778899\nGH_APP_PRIVATE_KEY_FILE=%s\n' "$T/env/github-app.pem" > "$T/env/github-app.env"
export GH_APP_API_BASE=http://api.test GH_TOKEN=pattok MINT_EXP
MINT_EXP=$(date -u -d '+1 hour' +%Y-%m-%dT%H:%M:%SZ)
ghtok() { bash "$T/bin/gh-token.sh" "$@" 2>/dev/null; }
fresh_cache() { rm -rf "$T/state/gh-app-tokens" "$T/state/gh-app-installations.json"; }

# G1
reset; fresh_cache
ghtok TestOwner/widget > "$T/g1.out"; rc=$?
printf 'fake-token-xyz\n' | cmp -s - "$T/g1.out" && [ "$rc" = 0 ] && ok || bad "G1 stdout/rc: rc=$rc '$(cat "$T/g1.out")'"
[ "$(n_posts)" = 1 ] && ok || bad "G1 posts=$(n_posts)"
jq -e --arg e "$MINT_EXP" '. == {kind:"gh_app",subject:"app-4242",box:"testbox",ok:true,expires_at:$e,error:null}' \
  "$BODIES" >/dev/null 2>&1 && ok || bad "G1 body: $(cat "$BODIES")"
! grep -q 'fake-token-xyz' "$BODIES" "$CALLS" && ok || bad "G1 the token reached the report"
# G1b
reset
[ "$(ghtok TestOwner/widget)" = fake-token-xyz ] && [ "$(n_posts)" = 0 ] && ok || bad "G1b cache hit posted $(n_posts)"
# G2 — rc and stdout pinned to what origin/main's gh-token.sh answers on this
# fixture: the PAT fallback, rc 0 (recorded before the edit, BH-2646 build).
reset; fresh_cache
g2=$(MINT_MODE=empty ghtok TestOwner/widget); rc=$?
[ "$rc" = 0 ] && [ "$g2" = pattok ] && ok || bad "G2 rc=$rc stdout='$g2'"
[ "$(n_posts)" = 1 ] && jq -e '.kind=="gh_app" and .subject=="app-4242" and .ok==false and .expires_at==null
  and .error=="access_tokens returned no token"' "$BODIES" >/dev/null 2>&1 && ok || bad "G2 posts=$(n_posts) body: $(cat "$BODIES")"
# G3
reset; fresh_cache
INSTALL_MODE=empty ghtok TestOwner/widget >/dev/null
[ "$(n_posts)" = 1 ] && jq -e '.subject=="app-unresolved-TestOwner" and .ok==false and .error=="no installation id"' \
  "$BODIES" >/dev/null 2>&1 && ok || bad "G3 posts=$(n_posts) body: $(cat "$BODIES")"
# G4
reset; fresh_cache; rm -f "$T/bin/lib/token-health.sh"
ghtok TestOwner/widget > "$T/g4.out"; rc=$?
printf 'fake-token-xyz\n' | cmp -s - "$T/g4.out" && [ "$rc" = 0 ] && [ "$(n_posts)" = 0 ] \
  && ok || bad "G4 lib absent: rc=$rc stdout='$(cat "$T/g4.out")' posts=$(n_posts)"
reset; cred "$FRESH"; refresh "$CDIR" acct1; rc=$?
[ "$rc" = 0 ] && [ "$(n_posts)" = 0 ] && ok || bad "G4 oauth-refresh with the lib absent: rc=$rc posts=$(n_posts)"

echo "token-health: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
