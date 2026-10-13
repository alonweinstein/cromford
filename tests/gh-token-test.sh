#!/bin/bash
# tests/gh-token-test.sh — bin/gh-token.sh and bin/lib/gh-app-auth.sh against a
# throwaway RSA key and a stubbed curl.
#
# THE WALL UNDER TEST (the operator, 2026-09-14, "every throughput ceiling is a bug").
# One PAT for every lane, box and Fly builder is one 5000/h REST bucket for the
# whole fleet and one credential that never expires, so at 4000 builders GitHub
# is the ceiling. A GitHub App installation token is rate-limited per
# installation, scoped to one repo, and dead in an hour.
#
# What is proved here, in the order a reader cares about it:
#   1. the JWT is a real RS256 JWS — three base64url segments, the documented
#      header, iss = the App id, a 10-minute-max window, and a signature the
#      App's PUBLIC key verifies. A hand-rolled openssl JWT that GitHub rejects
#      is the whole risk of this change, so the signature is checked, not eyeballed.
#   2. the exchange is repo-SCOPED: the POST body names this one repo.
#   3. the cache is reused (a second ask spends no request) and refreshed once the
#      token is inside 5 minutes of expiry.
#   3b. --min-life/--fresh raise that floor for ONE call, because a 40-75 minute
#      pool build cannot spend a token with 13 minutes left (2026-09-14,
#      project-5 TK-680/681/682: three finished builds thrown away when their
#      pre-PR push answered `remote: Invalid username or token`). --expires-at is
#      the other half — how bin/fly-pool.sh learns when the token it shipped dies
#      without a second API call.
#   4. an unconfigured box, GH_APP_TOKENS=0 and flags/gh-app-tokens-off all print
#      TODAY's PAT — including the admin PAT for a repo only that one can see —
#      and touch GitHub not at all.
#   5. no token value reaches logs/gh-rate.log, which carries counts only.
#   6. two lanes asking at once buy ONE token (the mint's flock is dedupe).
# Run from anywhere: tests/gh-token-test.sh   (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
. "$DIR/tests/lib/rb-all.sh" || exit 1
RB_ALL=$(rb_all "$DIR" "$T/run-build.all.sh")
mkdir -p "$T/bin/lib" "$T/env" "$T/flags" "$T/logs" "$T/state" "$T/locks" "$T/fakebin"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

command -v openssl >/dev/null 2>&1 || { echo "gh-token: openssl missing — the script itself needs it, so this is a real skip"; exit 0; }
cp "$DIR/bin/gh-token.sh" "$T/bin/"; chmod +x "$T/bin/gh-token.sh"
cp "$DIR/bin/lib/gh-app-auth.sh" "$DIR/bin/lib/gh-repo-token.sh" "$T/bin/lib/"

# A THROWAWAY key, generated here and deleted with $T. Nothing in this repo, this
# fixture or its output is a real credential.
openssl genrsa -out "$T/env/github-app.pem" 2048 2>/dev/null
chmod 600 "$T/env/github-app.pem"
openssl rsa -in "$T/env/github-app.pem" -pubout -out "$T/pub.pem" 2>/dev/null

cat > "$T/env/github-app.env" <<'ENVF'
GH_APP_ID=778899
GH_APP_PRIVATE_KEY_FILE=__T__/env/github-app.pem
ENVF
sed -i "s#__T__#$T#" "$T/env/github-app.env"

# --- the curl stub -----------------------------------------------------------
# Logs "<url>|<authorization>|<body>" per call and answers the three endpoints
# bin/gh-token.sh uses. TOKSEQ makes every mint a distinguishable value so a
# cache HIT and a cache REFRESH cannot be confused for each other.
cat > "$T/fakebin/curl" <<'SH'
#!/bin/bash
URL=""; AUTH=""; BODY=""
while [ $# -gt 0 ]; do
  case "$1" in
    -H) case "$2" in Authorization:*) AUTH="${2#Authorization: }" ;; esac; shift 2 ;;
    -d) BODY="$2"; shift 2 ;;
    -X) shift 2 ;;
    -sS|-s|-S) shift ;;
    *) URL="$1"; shift ;;
  esac
done
printf '%s|%s|%s\n' "$URL" "$AUTH" "$BODY" >> "$CURL_LOG"
case "$URL" in
  */app/installations)
    [ "${INSTALL_LIST_FAILS:-0}" = 1 ] && { echo '{"message":"Bad credentials"}'; exit 0; }
    printf '[{"id":4242,"account":{"login":"TestOwner"}},{"id":9,"account":{"login":"someoneelse"}}]\n' ;;
  */access_tokens)
    [ "${MINT_FAILS:-0}" = 1 ] && { echo '{"message":"Bad credentials"}'; exit 0; }
    [ "${MINT_SLOW:-0}" = 1 ] && sleep 2   # determinism: ok the slow mint IS the fixture — the caller's timeout is under test
    N=$(( $(cat "$TOKSEQ" 2>/dev/null || echo 0) + 1 )); printf '%s' "$N" > "$TOKSEQ"
    printf '{"token":"ghs_fixture_%s","expires_at":"%s"}\n' "$N" "$(date -u -d '+1 hour' '+%Y-%m-%dT%H:%M:%SZ')" ;;
  */rate_limit)
    printf '{"rate":{"remaining":4996,"limit":5000}}\n' ;;
  *) echo '{}' ;;
esac
SH
chmod +x "$T/fakebin/curl"

# gh shim for the PAT fallback: o/seen is visible to the default token,
# o/adminonly only to the admin one — the same shape tests/gh-repo-token-test.sh
# drives, because that file is the fallback and is not re-implemented here.
cat > "$T/fakebin/gh" <<'SH'
#!/bin/bash
[ -n "${GH_CALL_LOG:-}" ] && printf '%s\n' "$*" >> "$GH_CALL_LOG"
case "$*" in
  "api repos/o/seen -q .id")      exit 0 ;;
  "api repos/o/adminonly -q .id") [ "${GH_TOKEN:-}" = admintok ] && exit 0; exit 1 ;;
  "auth token") printf 'keyring-tok\n' ;;
  *) exit 1 ;;
esac
SH
chmod +x "$T/fakebin/gh"

: > "$T/curl.log"; printf '0' > "$T/tokseq"
run() { # run <args...> — bin/gh-token.sh under the fixture env; extra env via ENV_EXTRA
  env PATH="$T/fakebin:$PATH" HARNESS="$T" GH_APP_API_BASE="http://api.test" \
      CURL_LOG="$T/curl.log" TOKSEQ="$T/tokseq" GH_TOKEN=pattok \
      GH_CALL_LOG="${GH_CALL_LOG:-}" \
      ${ENV_EXTRA:-} "$T/bin/gh-token.sh" "$@" 2>/dev/null
}
# `grep -c` already prints 0 for no match; an `|| echo 0` on top of it prints
# TWO lines and every count comparison below then silently fails.
mints() { grep -c 'access_tokens' "$T/curl.log" 2>/dev/null; }

# ── 1. the mint, and the JWT it is signed with ───────────────────────────────
TOK1=$(run TestOwner/widget)
[ "$TOK1" = "ghs_fixture_1" ] && ok || bad "first ask should print the minted token, got '$TOK1'"

JWT=$(awk -F'|' '/access_tokens/ {print $2}' "$T/curl.log" | head -1 | sed 's/^Bearer //')
[ "$(awk -F. '{print NF}' <<<"$JWT")" = 3 ] && ok || bad "the JWT is not three dot-separated segments: '$JWT'"
b64d() { # base64url -> bytes, padding restored
  local d="$1"; case $(( ${#d} % 4 )) in 2) d="$d==" ;; 3) d="$d=" ;; esac
  printf '%s' "$d" | tr '_-' '/+' | openssl base64 -d -A 2>/dev/null
}
HDR=$(b64d "$(cut -d. -f1 <<<"$JWT")")
[ "$HDR" = '{"alg":"RS256","typ":"JWT"}' ] && ok || bad "JWT header: $HDR"
PAY=$(b64d "$(cut -d. -f2 <<<"$JWT")")
[ "$(jq -r '.iss' <<<"$PAY")" = 778899 ] && ok || bad "JWT iss must be the App id: $PAY"
WIN=$(jq -r '.exp - .iat' <<<"$PAY")
[ "$WIN" -gt 0 ] && [ "$WIN" -le 600 ] && ok || bad "JWT window must be inside GitHub's 10-minute max, got ${WIN}s"
# iat is backdated so a clock a few seconds ahead of GitHub's is not a 401.
[ "$(jq -r '.iat' <<<"$PAY")" -le "$(date +%s)" ] && ok || bad "JWT iat is in the future: $PAY"
# THE SIGNATURE, verified with the App's public key. This is the assertion that
# says GitHub would actually accept what openssl produced.
printf '%s' "$(cut -d. -f1,2 <<<"$JWT")" > "$T/si.txt"
b64d "$(cut -d. -f3 <<<"$JWT")" > "$T/sig.bin"
openssl dgst -sha256 -verify "$T/pub.pem" -signature "$T/sig.bin" "$T/si.txt" >/dev/null 2>&1 \
  && ok || bad "the JWT signature does not verify against the App's public key"

# ── 2. repo scope, installation discovery, and its cache ─────────────────────
BODY=$(awk -F'|' '/access_tokens/ {print $3}' "$T/curl.log" | head -1)
[ "$(jq -c '.repositories' <<<"$BODY")" = '["widget"]' ] && ok || bad "the exchange must be scoped to the one repo, body was: $BODY"
grep -q 'app/installations/4242/access_tokens' "$T/curl.log" && ok || bad "the discovered installation id was not used: $(cat "$T/curl.log")"
[ "$(jq -r '.testowner' "$T/state/gh-app-installations.json" 2>/dev/null)" = 4242 ] \
  && ok || bad "installation id not cached (owner matched case-insensitively): $(cat "$T/state/gh-app-installations.json" 2>/dev/null)"
# env wins over discovery: with the id named, /app/installations is never called.
: > "$T/curl.log"
ENV_EXTRA="GH_APP_INSTALLATION_TESTOWNER=5150" run TestOwner/other >/dev/null
grep -q '/app/installations|' "$T/curl.log" && bad "an env-named installation id must not list installations" || ok
grep -q 'app/installations/5150/access_tokens' "$T/curl.log" && ok || bad "GH_APP_INSTALLATION_<OWNER> was ignored: $(cat "$T/curl.log")"

# ── 3. cache reuse, and the refresh 5 minutes before expiry ──────────────────
: > "$T/curl.log"
TOK2=$(run TestOwner/widget)
[ "$TOK2" = "$TOK1" ] && [ "$(mints)" = 0 ] && ok || bad "a warm cache must cost no request: tok=$TOK2 mints=$(mints)"
CF="$T/state/gh-app-tokens/TestOwner-widget.json"
[ -s "$CF" ] && ok || bad "no cache file at $CF ($(ls "$T/state/gh-app-tokens" 2>/dev/null))"
[ "$(stat -c %a "$CF")" = 600 ] && ok || bad "the cache file must be mode 600, is $(stat -c %a "$CF")"
# 4 minutes of life left is INSIDE the 5-minute floor: refresh, do not reuse.
jq --arg e "$(date -u -d '+4 minutes' '+%Y-%m-%dT%H:%M:%SZ')" '.expires_at=$e' "$CF" > "$CF.x" && mv "$CF.x" "$CF"
: > "$T/curl.log"
TOK3=$(run TestOwner/widget)
[ "$TOK3" != "$TOK1" ] && [ "$(mints)" = 1 ] && ok || bad "a token inside 5 min of expiry must be re-minted: tok=$TOK3 mints=$(mints)"
# ...and an hour of life left is reused.
: > "$T/curl.log"
[ "$(run TestOwner/widget)" = "$TOK3" ] && [ "$(mints)" = 0 ] && ok || bad "the fresh token was not reused"
# A cache file that is corrupt reads as expired rather than as an answer.
echo 'not json' > "$CF"; : > "$T/curl.log"
[ -n "$(run TestOwner/widget)" ] && [ "$(mints)" = 1 ] && ok || bad "a corrupt cache file must re-mint, not return junk"

# ── 3b. --min-life: alive is not the same as alive ENOUGH ────────────────────
# The default floor is 5 minutes and it is right for a lane that spends its token
# in seconds. A pool build spends its token 40-75 minutes after the bundle was
# written, so it asks for a token with most of its hour still on it.
: > "$T/curl.log"
TOKA=$(run TestOwner/longbuild)
CF2="$T/state/gh-app-tokens/TestOwner-longbuild.json"
age_to() { jq --arg e "$(date -u -d "$1" '+%Y-%m-%dT%H:%M:%SZ')" '.expires_at=$e' "$CF2" > "$CF2.x" && mv "$CF2.x" "$CF2"; }
age_to '+50 minutes'
: > "$T/curl.log"
[ "$(run TestOwner/longbuild)" = "$TOKA" ] && [ "$(mints)" = 0 ] \
  && ok || bad "50 minutes of life is a cache HIT for a caller that asks for nothing"
: > "$T/curl.log"
TOKB=$(run --min-life 3300 TestOwner/longbuild)
[ "$TOKB" != "$TOKA" ] && [ "$(mints)" = 1 ] \
  && ok || bad "--min-life 3300 must re-mint a token with only 50 minutes left: tok=$TOKB mints=$(mints)"
# The freshly minted token REPLACES the cached one — a --min-life ask that did not
# write through would make every later caller pay for the mint again.
: > "$T/curl.log"
[ "$(run TestOwner/longbuild)" = "$TOKB" ] && [ "$(mints)" = 0 ] \
  && ok || bad "the token minted for --min-life was not cached"
# An ask the cached token already satisfies costs nothing.
age_to '+50 minutes'; : > "$T/curl.log"
[ "$(run --min-life 600 TestOwner/longbuild)" = "$TOKB" ] && [ "$(mints)" = 0 ] \
  && ok || bad "--min-life 600 against 50 minutes of life must reuse the cache"
# --min-life=<n> and --fresh are the same door.
: > "$T/curl.log"
TOKC=$(run --min-life=3300 TestOwner/longbuild)
[ "$TOKC" != "$TOKB" ] && [ "$(mints)" = 1 ] && ok || bad "--min-life=<n> form was not honoured"
age_to '+50 minutes'; : > "$T/curl.log"
TOKD=$(run --fresh TestOwner/longbuild)
[ "$TOKD" != "$TOKC" ] && [ "$(mints)" = 1 ] && ok || bad "--fresh must bypass a 50-minute-old cache entry"
# ...and --fresh does NOT mint forever: the token it just bought satisfies it.
: > "$T/curl.log"
[ "$(run --fresh TestOwner/longbuild)" = "$TOKD" ] && [ "$(mints)" = 0 ] \
  && ok || bad "--fresh must accept a token minted seconds ago, or every call mints"
# Bad input is an exit, never a silent floor of zero (which would be "any token").
run --min-life >/dev/null 2>&1; [ "$?" = 2 ] && ok || bad "--min-life with no number must exit 2"
run --min-life abc TestOwner/longbuild >/dev/null 2>&1; [ "$?" = 2 ] && ok || bad "--min-life with a non-number must exit 2"
# --expires-at: the expiry, and NOTHING else. This is what bin/fly-pool.sh records
# on the machine json so a later tick can decide about rotation locally.
: > "$T/curl.log"
EXPAT=$(run --expires-at TestOwner/longbuild)
[ "$EXPAT" = "$(jq -r '.expires_at' "$CF2")" ] && ok || bad "--expires-at printed '$EXPAT', cache says $(jq -r '.expires_at' "$CF2")"
[ "$(mints)" = 0 ] && ok || bad "--expires-at must read the cache, not buy a token"
grep -qE 'ghs_fixture' <<<"$EXPAT" && bad "--expires-at printed a token value" || ok
run --expires-at TestOwner/nevercached >/dev/null 2>&1; [ "$?" = 1 ] && ok || bad "--expires-at for an uncached repo must exit 1, not print an empty 'soon'"
run --expires-at notaslug >/dev/null 2>&1; [ "$?" = 2 ] && ok || bad "--expires-at without owner/repo must exit 2"
# The option changes nothing on an unarmed box: still the PAT, still no request.
mv "$T/env/github-app.env" "$T/env/github-app.env.parked"; : > "$T/curl.log"
[ "$(run --min-life 3300 o/seen)" = pattok ] && [ ! -s "$T/curl.log" ] \
  && ok || bad "--min-life on an unarmed box must still be the PAT and no request"
mv "$T/env/github-app.env.parked" "$T/env/github-app.env"

# ── 4. rate visibility: one line per MINT, counts only, never a token value ──
grep -q 'gh-rate TestOwner/widget remaining=4996/5000' "$T/logs/gh-rate.log" \
  && ok || bad "no gh-rate line for the mint: $(cat "$T/logs/gh-rate.log" 2>/dev/null)"
BEFORE=$(grep -c 'gh-rate' "$T/logs/gh-rate.log")
run TestOwner/widget >/dev/null
[ "$(grep -c 'gh-rate' "$T/logs/gh-rate.log")" = "$BEFORE" ] && ok || bad "a cache hit must not write a gh-rate line"
grep -qE 'ghs_fixture|pattok|admintok' "$T/logs/gh-rate.log" && bad "a token VALUE leaked into logs/gh-rate.log" || ok
# --status reports the live remaining/limit for what is cached, and no token.
ST=$(run --status)
grep -q 'TestOwner/widget remaining=4996/5000 expires_at=' <<<"$ST" && ok || bad "--status output: $ST"
grep -qE 'ghs_fixture' <<<"$ST" && bad "--status printed a token value" || ok

# ── 5. the fallback IS today: the PAT, and no GitHub call at all ─────────────
mv "$T/env/github-app.env" "$T/env/github-app.env.parked"
: > "$T/curl.log"
[ "$(run o/seen)" = pattok ] && ok || bad "unconfigured must print GH_TOKEN, got '$(run o/seen)'"
[ ! -s "$T/curl.log" ] && ok || bad "the unconfigured path must not touch GitHub: $(cat "$T/curl.log")"
# the admin PAT for a repo only that one can see — bin/lib/gh-repo-token.sh's
# answer, reused rather than copied
echo 'GH_ADMIN_TOKEN=admintok' > "$T/env/github-admin.env"
[ "$(run o/adminonly)" = admintok ] && ok || bad "an admin-only repo must fall back to the admin PAT, got '$(run o/adminonly)'"
mv "$T/env/github-app.env.parked" "$T/env/github-app.env"
# ── 5b. the fallback asks the PAT-ONLY question, so the two files cannot loop ──
# (BH-765) The lib's ladder now tries an App installation token first, and that
# rung mints one by running THIS script — while THIS script's PAT fallback
# sources the lib. `pat_for` therefore sets _GHRT_NO_APP=1 before it sources it,
# and the proof is the probe count: answering "which PAT can see o/adminonly"
# costs exactly the two repo probes (default, then admin). Without the guard the
# fallback re-enters this script through the lib's App rung, that child asks the
# same question again, and the count doubles.
rm -rf "$T/state/gh-app-tokens"; : > "$T/gh-calls.log"
OUT=$(GH_CALL_LOG="$T/gh-calls.log" ENV_EXTRA=MINT_FAILS=1 run o/adminonly)
[ "$OUT" = admintok ] && ok \
  || bad "5b: a failed mint on an admin-only repo must still answer the admin PAT, got '$OUT'"
NPROBE=$(grep -c 'repos/o/adminonly' "$T/gh-calls.log" 2>/dev/null)
[ "$NPROBE" = 2 ] && ok \
  || bad "5b: the PAT fallback re-entered gh-token.sh through the lib — $NPROBE repo probes for one ask (expected 2): $(cat "$T/gh-calls.log")"
rm -rf "$T/state/gh-app-tokens"
rm -f "$T/env/github-admin.env"
# GH_APP_TOKENS=0 and the flag file are the same off, with the App configured
: > "$T/curl.log"
[ "$(ENV_EXTRA=GH_APP_TOKENS=0 run o/seen)" = pattok ] && [ ! -s "$T/curl.log" ] && ok || bad "GH_APP_TOKENS=0 must be the PAT and no request"
touch "$T/flags/gh-app-tokens-off"; : > "$T/curl.log"
[ "$(run o/seen)" = pattok ] && [ ! -s "$T/curl.log" ] && ok || bad "flags/gh-app-tokens-off must be the PAT and no request"
rm -f "$T/flags/gh-app-tokens-off"
# A mint that FAILS is the PAT plus a stderr line, never an empty answer: an
# empty token is a 401 three stages later with nothing naming the cause.
[ "$(ENV_EXTRA=MINT_FAILS=1 run o/seen)" = pattok ] && ok || bad "a failed mint must fall back to the PAT, not print nothing"
[ "$(ENV_EXTRA=INSTALL_LIST_FAILS=1 run Unknown/repo)" = pattok ] && ok || bad "an owner with no discoverable installation must fall back to the PAT"
# usage
run --nope >/dev/null 2>&1; [ "$?" = 2 ] && ok || bad "an unknown flag should exit 2"
run notaslug >/dev/null 2>&1; [ "$?" = 2 ] && ok || bad "a bare name that is not owner/repo should exit 2"

# ── 6. the mint's flock is DEDUPE: two lanes at once buy one token ───────────
rm -rf "$T/state/gh-app-tokens" "$T/locks"; mkdir -p "$T/locks"; : > "$T/curl.log"
ENV_EXTRA=MINT_SLOW=1 run TestOwner/race >/dev/null & P1=$!
sleep 0.2
run TestOwner/race > "$T/race2.txt" & P2=$!
wait "$P1" "$P2" 2>/dev/null
[ "$(mints)" = 1 ] && ok || bad "two concurrent asks minted $(mints) tokens — the flock is not deduping"
[ -s "$T/race2.txt" ] && ok || bad "the second asker got no token"

# ── 7. gh_auth_for: the one line a lane adds ─────────────────────────────────
drive() { # drive <snippet> — the lib sourced fresh with the fixture's env
  ( export PATH="$T/fakebin:$PATH" HARNESS="$T" GH_APP_API_BASE="http://api.test" \
           CURL_LOG="$T/curl.log" TOKSEQ="$T/tokseq" GH_TOKEN=pattok
    # shellcheck source=/dev/null
    . "$T/bin/lib/gh-app-auth.sh"; eval "$1" ) 2>/dev/null
}
[ "$(drive 'gh_auth_for TestOwner/widget; printf %s "$GH_TOKEN"')" = "$(run TestOwner/widget)" ] \
  && ok || bad "gh_auth_for did not export the installation token"
[ "$(drive 'gh_auth_for TestOwner/widget; gh_auth_reset; printf %s "$GH_TOKEN"')" = pattok ] \
  && ok || bad "gh_auth_reset did not restore the caller's GH_TOKEN"
# UNARMED = UNTOUCHED. This is the whole rollback argument: rc 1 and the
# environment is exactly what global.env left it.
mv "$T/env/github-app.env" "$T/env/github-app.env.parked"
[ "$(drive 'gh_auth_for TestOwner/widget; echo "rc=$? tok=$GH_TOKEN"')" = "rc=1 tok=pattok" ] \
  && ok || bad "unarmed gh_auth_for must rc 1 and leave GH_TOKEN alone: $(drive 'gh_auth_for TestOwner/widget; echo "rc=$? tok=$GH_TOKEN"')"
[ "$(drive 'gh_auth_armed; echo $?')" = 1 ] && ok || bad "gh_auth_armed must be 1 with no env/github-app.env"
mv "$T/env/github-app.env.parked" "$T/env/github-app.env"
[ "$(drive 'gh_auth_armed; echo $?')" = 0 ] && ok || bad "gh_auth_armed must be 0 once configured"
[ "$(drive 'gh_auth_for notaslug; echo "rc=$? tok=$GH_TOKEN"')" = "rc=1 tok=pattok" ] \
  && ok || bad "gh_auth_for must refuse a name that is not owner/repo without touching the env"
# GH_TOKEN absent entirely (a box on gh's keyring): the reset must UNSET, not
# export an empty token — an empty GH_TOKEN is not the same as no GH_TOKEN to gh.
OUT=$( export PATH="$T/fakebin:$PATH" HARNESS="$T" GH_APP_API_BASE="http://api.test" \
              CURL_LOG="$T/curl.log" TOKSEQ="$T/tokseq"; unset GH_TOKEN
       # shellcheck source=/dev/null
       . "$T/bin/lib/gh-app-auth.sh"
       gh_auth_for TestOwner/widget >/dev/null 2>&1; gh_auth_reset; echo "${GH_TOKEN+set}" )
[ "$OUT" = "" ] && ok || bad "gh_auth_reset must unset GH_TOKEN when there was none, got '$OUT'"

# ── 8. no key or token anywhere it could be committed ────────────────────────
# Scoped to the files this change adds. A repo-wide scan hits the redaction
# guards' own PEM-header fixtures (bin/share/mapping.py, transcript-scrub), which
# are there on purpose.
grep -lE -- '-----BEGIN [A-Z ]*PRIVATE KEY' \
  "$DIR/bin/gh-token.sh" "$DIR/bin/lib/gh-app-auth.sh" "$DIR/tests/gh-token-test.sh" \
  "$DIR/env-templates/github-app.env.example" 2>/dev/null \
  && bad "a private key is present in one of this change's files" || ok

# ── 9. the wiring: each consumer resolves through the helper, behind the flag ─
# Static, on purpose. These four scripts cannot be driven end to end here (one is
# a 3000-line build pipeline, one spawns Fly machines), but a call site that
# quietly disappears in a later edit is exactly the regression this change has to
# survive — and "guarded by gh_auth_armed / gh_auth_for" is what makes the
# rollback claim true, so it is asserted rather than trusted.
# run-build.sh is read through the flatten: since the BH-572 cut its wiring lives
# in a stage module under bin/lib/rb/, and $RB_ALL is the pipeline as one text.
for f in bin/run-build.sh bin/merge-conductor.sh bin/wake-loop.sh bin/fly-pool.sh; do
  src="$DIR/$f"; [ "$f" = bin/run-build.sh ] && src="$RB_ALL"
  grep -q 'lib/gh-app-auth.sh' "$src" && ok || bad "$f does not source bin/lib/gh-app-auth.sh"
  grep -qE 'gh_auth_(for|armed)' "$src" && ok || bad "$f sources the lib but never calls it"
  # Every call site is guarded by `command -v`, so a box whose harness sync has
  # not landed the lib yet runs today's code instead of dying on an unset function.
  grep -qE 'command -v gh_auth_(for|armed)' "$src" && ok || bad "$f calls the helper without a command -v guard"
done
grep -q 'gh_auth_reset' "$DIR/bin/merge-conductor.sh" && ok || bad "merge-conductor reset_token must also reset the App token"
# fly-pool must REPLACE the bundle's GH_TOKEN line, not append a second one: the
# builder's `set -a; . global.env` takes the LAST value, so an append silently
# keeps shipping the PAT. The idiom itself is exercised, not just grepped.
grep -q "grep -v '\^GH_TOKEN='" "$DIR/bin/fly-pool.sh" && ok || bad "fly-pool must strip the bundle's PAT line before writing the minted token"
printf 'CLAUDE_CODE_OAUTH_TOKEN=x\nGH_TOKEN=pattok\nCONSOLE_URL=y\n' > "$T/bundle.env"
( grep -v '^GH_TOKEN=' "$T/bundle.env" > "$T/bundle.new"; printf 'GH_TOKEN=%s\n' ghs_machine >> "$T/bundle.new" )
[ "$(grep -c '^GH_TOKEN=' "$T/bundle.new")" = 1 ] && ok || bad "the swapped bundle has $(grep -c '^GH_TOKEN=' "$T/bundle.new") GH_TOKEN lines"
[ "$(set -a; . "$T/bundle.new"; printf '%s' "$GH_TOKEN")" = ghs_machine ] && ok || bad "the swapped bundle still sources the PAT"
grep -q '^CLAUDE_CODE_OAUTH_TOKEN=x' "$T/bundle.new" && grep -q '^CONSOLE_URL=y' "$T/bundle.new" \
  && ok || bad "the swap dropped another var out of the bundle"
# run-build resolves ONCE, before any stage: after global.env is sourced and
# before the first `git push`. A resolution that lands after the push is a
# resolution that does nothing.
# Comment lines are filtered out: this file and run-build.sh both TALK about
# `git push` and global.env long before either happens, and an ordering assertion
# that a comment can satisfy proves nothing.
rbline() { grep -n -- "$1" "$RB_ALL" | grep -vE '^[0-9]+:[[:space:]]*#' | head -1 | cut -d: -f1; }
RB_ENV=$(rbline 'env/global.env')
RB_AUTH=$(rbline 'gh_auth_for ')
RB_PUSH=$(rbline 'RB_PUSH -u')   # BH-2504: every run-build push is RB_PUSH
[ "$RB_ENV" -lt "$RB_AUTH" ] && [ "$RB_AUTH" -lt "$RB_PUSH" ] \
  && ok || bad "run-build must resolve the token after global.env ($RB_ENV) and before the first push ($RB_PUSH), resolves at $RB_AUTH"

# ── 10. gh_auth_for_url, and the re-source guard ─────────────────────────────
# A lane that has a PR URL and no slug should not have to parse the URL itself.
# URLs that are not github.com leave the env untouched.
[ "$(drive 'gh_auth_for_url https://example.com/foo/bar; echo "rc=$? tok=$GH_TOKEN"')" = "rc=1 tok=pattok" ] \
  && ok || bad "gh_auth_for_url on a non-GitHub URL must rc=1 and leave GH_TOKEN alone"
# GitHub URLs are parsed down to owner/repo, including PR URLs with extra path.
[ "$(drive 'gh_auth_for_url https://github.com/TestOwner/widget/pull/1; printf %s "$GH_TOKEN"')" = "$(run TestOwner/widget)" ] \
  && ok || bad "gh_auth_for_url did not extract owner/repo from a PR URL"
# A github.com URL that is NOT owner/repo is a miss, not a guess. Both halves are
# checked BEFORE the slug is rebuilt, or "github.com/owner" mints for owner/owner
# and "github.com/" asks gh-token.sh for the repo "/".
[ "$(drive 'gh_auth_for_url https://github.com/owner; echo "rc=$? tok=$GH_TOKEN"')" = "rc=1 tok=pattok" ] \
  && ok || bad "gh_auth_for_url on a github.com URL with no repo must rc=1 and leave GH_TOKEN alone"
[ "$(drive 'gh_auth_for_url https://github.com/; echo "rc=$? tok=$GH_TOKEN"')" = "rc=1 tok=pattok" ] \
  && ok || bad "gh_auth_for_url on a bare github.com URL must rc=1 and leave GH_TOKEN alone"
# "…/owner/" DOES have a slash, so the shape test alone lets it through and the
# repo half comes out empty. Both halves are checked by value for that reason.
[ "$(drive 'gh_auth_for_url https://github.com/owner/; echo "rc=$? tok=$GH_TOKEN"')" = "rc=1 tok=pattok" ] \
  && ok || bad "gh_auth_for_url on a trailing-slash owner URL must rc=1 and leave GH_TOKEN alone"
# A query string or fragment is not part of the repo name. Without the strip,
# "…/widget?tab=readme" asks gh-token.sh to mint for the repo "widget?tab=readme"
# and the lane goes out on the PAT with no sign anything was wrong.
[ "$(drive 'gh_auth_for_url https://github.com/TestOwner/widget?tab=readme; printf %s "$GH_TOKEN"')" = "$(run TestOwner/widget)" ] \
  && ok || bad "gh_auth_for_url must drop a query/fragment before it reads the repo name"
# Re-sourcing the helper must not re-capture GH_TOKEN. Without the guard the
# second source saves the APP token as "the default" and gh_auth_reset then
# restores the App token instead of the PAT the lane started on — a lane that
# never goes back to its own identity, and nothing says so.
OUT=$( export PATH="$T/fakebin:$PATH" HARNESS="$T" GH_APP_API_BASE="http://api.test" \
              CURL_LOG="$T/curl.log" TOKSEQ="$T/tokseq" GH_TOKEN=pattok
       # shellcheck source=/dev/null
       . "$T/bin/lib/gh-app-auth.sh"
       gh_auth_for TestOwner/widget >/dev/null 2>&1
       # shellcheck source=/dev/null
       . "$T/bin/lib/gh-app-auth.sh"
       gh_auth_reset
       printf '%s' "$GH_TOKEN" )
[ "$OUT" = pattok ] && ok || bad "re-sourcing gh-app-auth.sh then resetting must restore the original GH_TOKEN, got '$OUT'"

echo "gh-token: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
