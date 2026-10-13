#!/bin/bash
# tests/gh-token-extra-read-repos.bh-5910-test.sh — BH-5910: a pool build of one
# project must be able to READ a second repo, and nothing else must change.
#
# The pool token is scoped to one repo, so a plan that copies code from
# example-org/OtherRepo got "Repository not found" on the builder. bin/gh-token.sh
# --extra-read <csv> <owner/repo> mints a SECOND, read-only installation token for
# the project repo plus the extra repos. The project token is unchanged.
#
# PINNED (bin/gh-token.sh run as a process, stub curl on PATH, a throwaway key):
#   1  the default mint ignores EXTRA_READ_REPOS: one repo, no permissions key.
#   2  --extra-read: one body, repositories [project, extra], contents+metadata
#      read only; stdout is the token; rc 0.
#   3  a repo the installation does not cover is named EXTRA_READ_REPO_MISSING
#      on stderr and in logs/gh-rate.log, and dropped; the mint goes ahead.
#      The same for a repo on another installation, another owner, a failed
#      request (unverified) and an entry that is not owner/repo.
#   4  nothing left to mint: rc 1, no stdout, no access_tokens request.
#   5  unarmed (GH_APP_TOKENS=0): rc 1, no stdout, never the PAT.
#   6  no token value reaches logs/gh-rate.log.
#   7  a second ask is a cache hit; a changed list is a new mint.
#   8  a failed mint: rc 1, no stdout, never the PAT.
# Run from anywhere: bash tests/gh-token-extra-read-repos.bh-5910-test.sh   (exit 0 = pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v openssl >/dev/null 2>&1 || { echo "gh-token-extra-read: openssl missing — the script itself needs it, so this is a real skip"; exit 0; }
command -v jq >/dev/null 2>&1 || { echo "gh-token-extra-read: jq missing — skipping"; exit 0; }

mkdir -p "$T/env" "$T/flags" "$T/logs" "$T/state" "$T/locks" "$T/fakebin"
scratch_install_closure bin/gh-token.sh "$T" >/dev/null || { echo "closure install failed for bin/gh-token.sh"; exit 1; }
chmod +x "$T/bin/gh-token.sh"

# A THROWAWAY key, generated here and deleted with $T.
openssl genrsa -out "$T/env/github-app.pem" 2048 2>/dev/null
chmod 600 "$T/env/github-app.pem"
printf 'GH_APP_ID=778899\nGH_APP_PRIVATE_KEY_FILE=%s/env/github-app.pem\n' "$T" > "$T/env/github-app.env"

# The curl stub: logs "<method>|<url>|<body>" per call. The installation GET
# answers per repo: Gone is a 404 body, Flaky is a failed request (no output),
# Elsewhere sits on another installation, every other repo on 4242.
cat > "$T/fakebin/curl" <<'SH'
#!/bin/bash
URL=""; BODY=""; M=GET
while [ $# -gt 0 ]; do
  case "$1" in
    -H) shift 2 ;;
    -d) BODY="$2"; shift 2 ;;
    -X) M="$2"; shift 2 ;;
    -m|-o|-w) shift 2 ;;
    -*) shift ;;
    *) URL="$1"; shift ;;
  esac
done
printf '%s|%s|%s\n' "$M" "$URL" "$BODY" >> "$CURL_LOG"
case "$URL" in
  */app/installations) printf '[{"id":4242,"account":{"login":"example-org"}}]\n' ;;
  */repos/example-org/Gone/installation) printf '{"message":"Not Found"}\n' ;;
  */repos/example-org/Flaky/installation) exit 28 ;;
  */repos/example-org/Elsewhere/installation) printf '{"id":999}\n' ;;
  */repos/*/installation) printf '{"id":4242}\n' ;;
  */access_tokens)
    [ "${MINT_FAILS:-0}" = 1 ] && { echo '{"message":"Bad credentials"}'; exit 0; }
    N=$(( $(cat "$TOKSEQ" 2>/dev/null || echo 0) + 1 )); printf '%s' "$N" > "$TOKSEQ"
    printf '{"token":"ghs_xreadfixture_%s","expires_at":"%s"}\n' "$N" "$(date -u -d '+1 hour' '+%Y-%m-%dT%H:%M:%SZ')" ;;
  */rate_limit) printf '{"rate":{"remaining":4996,"limit":5000}}\n' ;;
  *) echo '{}' ;;
esac
SH
chmod +x "$T/fakebin/curl"

: > "$T/curl.log"; printf '0' > "$T/tokseq"
# run <args...> -> stdout in $OUT, stderr in $ERR, rc in $RC. Extra env via ENV_EXTRA.
run() {
  OUT=$(env PATH="$T/fakebin:$PATH" HARNESS="$T" GH_APP_API_BASE="http://api.test" \
      CURL_LOG="$T/curl.log" TOKSEQ="$T/tokseq" GH_TOKEN=ghp_patfixture \
      ${ENV_EXTRA:-} "$T/bin/gh-token.sh" "$@" 2>"$T/err")
  RC=$?; ERR=$(cat "$T/err")
}
bodies() { awk -F'|' '$2 ~ /access_tokens$/ {print $3}' "$T/curl.log"; }
mints() { grep -c 'access_tokens|' "$T/curl.log"; }
reset_log() { : > "$T/curl.log"; }

# ── 1. the default mint is today's, whatever EXTRA_READ_REPOS says ──────────
ENV_EXTRA="EXTRA_READ_REPOS=example-org/OtherRepo" run example-org/proj-repo
[ "$RC" = 0 ] && [ "$OUT" = ghs_xreadfixture_1 ] && ok || bad "1: default mint must print the token, rc=$RC out='$OUT' err='$ERR'"
B=$(bodies)
[ "$(printf '%s\n' "$B" | grep -c .)" = 1 ] && ok || bad "1: exactly one access_tokens body, got: $B"
[ "$(jq -c '.repositories' <<<"$B")" = '["proj-repo"]' ] && ok || bad "1: default body must list one repo, got: $B"
[ "$(jq -c 'has("permissions")' <<<"$B")" = false ] && ok || bad "1: default body must carry no permissions key, got: $B"
grep -q '/installation|' "$T/curl.log" && bad "1: the default mint must make no installation GET" || ok

# ── 2. --extra-read: one read-only token for the project plus the extra ─────
reset_log
run --extra-read example-org/OtherRepo example-org/proj-repo
[ "$RC" = 0 ] && ok || bad "2: rc must be 0, got $RC ($ERR)"
[ "$OUT" = ghs_xreadfixture_2 ] && ok || bad "2: stdout must be the new token, got '$OUT'"
B=$(bodies)
[ "$(printf '%s\n' "$B" | grep -c .)" = 1 ] && ok || bad "2: exactly one access_tokens body, got: $B"
[ "$(jq -c '.repositories' <<<"$B")" = '["proj-repo","OtherRepo"]' ] && ok || bad "2: repositories must be [project, extra], got: $B"
[ "$(jq -c '.permissions' <<<"$B")" = '{"contents":"read","metadata":"read"}' ] && ok || bad "2: permissions must be contents+metadata read, got: $B"
grep -q '^GET|http://api.test/repos/example-org/OtherRepo/installation|' "$T/curl.log" && ok || bad "2: the extra repo's installation must be checked"
[ -z "$ERR" ] && ok || bad "2: no stderr when every repo is present, got: $ERR"

# ── 7. cache hit, then a changed list mints anew ───────────────────────────
reset_log
run --extra-read example-org/OtherRepo example-org/proj-repo
[ "$OUT" = ghs_xreadfixture_2 ] && [ "$(mints)" = 0 ] && ok || bad "7: a second ask must be a cache hit, out='$OUT' mints=$(mints)"
grep -q '/installation|' "$T/curl.log" && bad "7: a cache hit must make no installation GET" || ok
run --extra-read "example-org/OtherRepo,example-org/ThirdRepo" example-org/proj-repo
[ "$OUT" = ghs_xreadfixture_3 ] && [ "$(mints)" = 1 ] && ok || bad "7: a changed list must mint a new token, out='$OUT' mints=$(mints)"
[ "$(bodies | jq -c '.repositories')" = '["proj-repo","OtherRepo","ThirdRepo"]' ] && ok || bad "7: changed list body, got: $(bodies)"
# The default project token's cache is not the read token's.
run example-org/proj-repo
[ "$OUT" = ghs_xreadfixture_1 ] && ok || bad "7: the default token must still answer from its own cache, got '$OUT'"

# ── 3. missing repos are named, dropped, and the mint goes ahead ────────────
reset_log; : > "$T/logs/gh-rate.log"
run --extra-read "example-org/Gone, example-org/OtherRepo example-org/Elsewhere,Other-Owner/thing,example-org/Flaky,not-a-slug,example-org/proj-repo" example-org/proj-repo
[ "$RC" = 0 ] && ok || bad "3: rc must be 0 while one extra survives, got $RC ($ERR)"
[ "$(bodies | jq -c '.repositories')" = '["proj-repo","OtherRepo"]' ] && ok || bad "3: body must list the project and OtherRepo only, got: $(bodies)"
for r in example-org/Gone example-org/Elsewhere Other-Owner/thing example-org/Flaky not-a-slug; do
  grep -q "^gh-token: EXTRA_READ_REPO_MISSING $r\b" <<<"$ERR" && ok || bad "3: stderr must name EXTRA_READ_REPO_MISSING $r, got: $ERR"
  grep -q "EXTRA_READ_REPO_MISSING $r\b.* for example-org/proj-repo$" "$T/logs/gh-rate.log" && ok || bad "3: gh-rate.log must name $r, got: $(cat "$T/logs/gh-rate.log")"
done
grep -q 'EXTRA_READ_REPO_MISSING example-org/Flaky (unverified)' <<<"$ERR" && ok || bad "3: a failed check must say (unverified), got: $ERR"
grep -q 'EXTRA_READ_REPO_MISSING not-a-slug (not owner/repo)' <<<"$ERR" && ok || bad "3: an invalid entry must say (not owner/repo), got: $ERR"
grep -q 'EXTRA_READ_REPO_MISSING example-org/proj-repo' <<<"$ERR" && bad "3: the project repo itself is dropped silently, not named missing" || ok
grep -q '/repos/Other-Owner/thing/installation' "$T/curl.log" && bad "3: another owner is missing without a request" || ok

# ── 4. nothing survives: no mint, no output ─────────────────────────────────
reset_log
run --extra-read example-org/Gone example-org/proj-repo
[ "$RC" = 1 ] && [ -z "$OUT" ] && ok || bad "4: rc 1 and no stdout when every extra is missing, rc=$RC out='$OUT'"
[ "$(mints)" = 0 ] && ok || bad "4: no access_tokens request when nothing survives, got $(mints)"
run --extra-read "" example-org/proj-repo
[ "$RC" = 1 ] && [ -z "$OUT" ] && ok || bad "4: an empty list is no extra repos: rc 1, no stdout, rc=$RC out='$OUT'"

# ── 5. unarmed: nothing, never the PAT ──────────────────────────────────────
reset_log
ENV_EXTRA="GH_APP_TOKENS=0" run --extra-read example-org/OtherRepo example-org/proj-repo
[ "$RC" = 1 ] && [ -z "$OUT" ] && ok || bad "5: GH_APP_TOKENS=0 must print nothing, rc=$RC out='$OUT'"
[ "$(mints)" = 0 ] && ok || bad "5: GH_APP_TOKENS=0 must mint nothing"
touch "$T/flags/gh-app-tokens-off"
run --extra-read example-org/OtherRepo example-org/proj-repo
[ "$RC" = 1 ] && [ -z "$OUT" ] && ok || bad "5: flags/gh-app-tokens-off must print nothing, rc=$RC out='$OUT'"
rm -f "$T/flags/gh-app-tokens-off"
mv "$T/env/github-app.env" "$T/env/github-app.env.off"
run --extra-read example-org/OtherRepo example-org/proj-repo
[ "$RC" = 1 ] && [ -z "$OUT" ] && ok || bad "5: an unconfigured box must print nothing (never the PAT), rc=$RC out='$OUT'"
mv "$T/env/github-app.env.off" "$T/env/github-app.env"

# ── 8. a failed mint: rc 1, no output, never the PAT ────────────────────────
reset_log
ENV_EXTRA="MINT_FAILS=1" run --extra-read example-org/FourthRepo example-org/proj-repo
[ "$RC" = 1 ] && [ -z "$OUT" ] && ok || bad "8: a failed mint must be rc 1 with no stdout, rc=$RC out='$OUT'"
[ "$(mints)" = 1 ] && ok || bad "8: the failed mint is one request, no retry, got $(mints)"

# ── 6. no token value in the rate log ───────────────────────────────────────
grep -q 'ghs_xreadfixture\|ghp_patfixture' "$T/logs/gh-rate.log" && bad "6: a token value reached logs/gh-rate.log" || ok

echo "gh-token-extra-read-repos (BH-5910): $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
