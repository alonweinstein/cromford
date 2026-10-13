#!/bin/bash
# tests/triage-gh-app-token-test.sh — the triage lane bills its GitHub calls to
# the project's App installation token, not the box's personal login.
#
# THE DEFECT THIS CLOSES (project-5, 2026-09-16 17:00–17:20Z). bin/run-build.sh
# has resolved a repo-scoped GitHub App installation token since 09-14, so
# builds, the conductor and the sweeps each bill their own 6,600/h. The triage
# lane never did: its shards (the codex/grok sessions that read ticket threads
# and post close-outs) inherit the box's `gh auth login` — the operator account,
# 5,000/h shared by every box AND the operator's Mac. That bucket emptied in
# twenty minutes and seven shards logged `GitHub API rate limit exhausted` and
# skipped their close-outs while the project-5 App token sat at 6,569/6,600.
#
# WHY DRIVEN AND NOT GREPPED. What matters is the VALUE of GH_TOKEN that the
# shard dispatch inherits: the minted `ghs_…` token when the App is armed, and
# exactly what the box had before when it is not (kill switch, no app env, or a
# project fleet.conf cannot name). The block is extracted VERBATIM from the
# shipped script by its markers, so a regression in the real lines fails here.
# The fixture is tests/gh-token-test.sh's: a throwaway RSA key and a curl stub.
# Run from anywhere: tests/triage-gh-app-token-test.sh   (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
mkdir -p "$T/bin/lib" "$T/env" "$T/flags" "$T/logs" "$T/state" "$T/locks" "$T/fakebin"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v openssl >/dev/null 2>&1 || { echo "triage-gh-app-token: openssl missing — real skip"; exit 0; }

# --- the block under test, verbatim from the shipped script ------------------
awk '/^# >>> triage github auth/{f=1} /^# <<< triage github auth/{f=0} f' "$DIR/bin/run-triage.sh" > "$T/block.sh"
[ -s "$T/block.sh" ] && ok || bad "bin/run-triage.sh carries a '# >>> triage github auth' … '# <<< triage github auth' block"

# --- fixture: App key, curl stub, fleet.conf, the lib ------------------------
cp "$DIR/bin/gh-token.sh" "$T/bin/"; chmod +x "$T/bin/gh-token.sh"
cp "$DIR/bin/lib/gh-app-auth.sh" "$DIR/bin/lib/gh-repo-token.sh" "$DIR/bin/lib/triage-gh-token.sh" "$T/bin/lib/"
cp "$DIR/bin/fleet-conf.sh" "$T/bin/"; chmod +x "$T/bin/fleet-conf.sh"
openssl genrsa -out "$T/env/github-app.pem" 2048 2>/dev/null; chmod 600 "$T/env/github-app.pem"
printf 'GH_APP_ID=778899\nGH_APP_PRIVATE_KEY_FILE=%s/env/github-app.pem\n' "$T" > "$T/env/github-app.env"
printf 'project-5 TestOwner/project-5 https://project-5.test - 3 box-project-5-1\n' > "$T/fleet.conf"
cat > "$T/fakebin/curl" <<'SH'
#!/bin/bash
URL=""; while [ $# -gt 0 ]; do case "$1" in -H|-d|-X) shift 2 ;; -sS|-s|-S) shift ;; *) URL="$1"; shift ;; esac; done
case "$URL" in
  */app/installations) printf '[{"id":4242,"account":{"login":"TestOwner"}}]\n' ;;
  */access_tokens) N=$(( $(cat "$TOKSEQ" 2>/dev/null || echo 0) + 1 )); printf '%s' "$N" > "$TOKSEQ"
    printf '{"token":"ghs_fixture_%s","expires_at":"%s"}\n' "$N" "$(date -u -d '+1 hour' '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null || date -u -v+1H '+%Y-%m-%dT%H:%M:%SZ')" ;;
  */rate_limit) printf '{"rate":{"remaining":4996,"limit":5000}}\n' ;;
  *) echo '{}' ;;
esac
SH
chmod +x "$T/fakebin/curl"
printf '0' > "$T/tokseq"

# drive <project> [env…] — run the block as run-triage.sh would, print GH_TOKEN after it
drive() {
  local p="$1"; shift
  # FLEET_CONF, not just $T/fleet.conf next to the copied reader (BH-470).
  # bin/fleet-conf.sh resolves $FLEET_CONF, then /root/harness/fleet.conf, then
  # ../fleet.conf — so ON A BOX WITH A LIVE HARNESS the live registry shadowed
  # this fixture's, the block asked for the real `example-org/project-5` instead of
  # `TestOwner/project-5`, the stubbed /app/installations does not list that
  # owner, and the mint failed: three of this suite's five checks were red on the
  # hub and green in CI (which has no /root/harness) for environmental reasons
  # that had nothing to do with run-triage.sh. The env var pins the registry the
  # same way HARNESS pins the tree.
  env PATH="$T/fakebin:$PATH" HARNESS="$T" FLEET_CONF="$T/fleet.conf" \
      GH_APP_API_BASE="http://api.test" TOKSEQ="$T/tokseq" \
      GH_TOKEN=pattok "$@" bash -c '
        PROJECT="$1"; HARNESS="$HARNESS"; REPO="/nonexistent/$PROJECT"; LOG="$HARNESS/logs/$PROJECT.log"
        . "$HARNESS/block.sh"
        printf "%s" "${GH_TOKEN:-<unset>}"' _ "$p" 2>/dev/null
}

# 1. armed: the triage lane exports the App installation token for the project's repo
out=$(drive project-5)
case "$out" in ghs_fixture_*) ok ;; *) bad "armed → GH_TOKEN is the minted App token (got: $out)" ;; esac

# 2. the token is scoped to the project's repo from fleet.conf (one mint, for installation 4242)
[ "$(cat "$T/tokseq")" = 1 ] && ok || bad "exactly one mint for the tick (mints: $(cat "$T/tokseq"))"

# 3. kill switch: flags/gh-app-tokens-off → the box's own token, untouched
touch "$T/flags/gh-app-tokens-off"
out=$(drive project-5)
[ "$out" = pattok ] && ok || bad "flags/gh-app-tokens-off leaves GH_TOKEN as it was (got: $out)"
rm -f "$T/flags/gh-app-tokens-off"

# 4. a project fleet.conf cannot name → untouched, no mint, no crash
before=$(cat "$T/tokseq")
out=$(drive nosuchproject)
[ "$out" = pattok ] && [ "$(cat "$T/tokseq")" = "$before" ] && ok || bad "unknown project → GH_TOKEN untouched and no mint (got: $out, mints $(cat "$T/tokseq"))"

# 5. the log says which identity the tick bills, and never the token value
grep -q "triage github auth: App installation token for TestOwner/project-5" "$T/logs/project-5.log" 2>/dev/null \
  && ok || bad "the tick logs that it bills the App token for the repo"
grep -q "ghs_fixture" "$T/logs/project-5.log" 2>/dev/null && bad "the token value must never reach the log" || ok

# A TICK OUTLIVES A NEARLY-SPENT CACHED TOKEN (project-4, 2026-09-24). The cache
# hands a token out until 5 minutes before it dies; a full triage tick runs
# 10-20 minutes and its session's `git fetch origin` goes through `gh auth
# git-credential`, i.e. this GH_TOKEN. Ticks that started at 17:58Z and 18:58Z
# armed a token with ~7 minutes left and stopped on "Invalid username or token"
# mid-run. So a cached token with less than the tick's life left is re-minted.
rm -f "$T/logs/project-5.log"
cache="$T/state/gh-app-tokens/TestOwner-project-5.json"
if [ -s "$cache" ]; then
  soon=$(date -u -d '+8 minutes' '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null || date -u -v+8M '+%Y-%m-%dT%H:%M:%SZ')
  jq --arg e "$soon" '.token="ghs_nearly_spent" | .expires_at=$e' "$cache" > "$cache.tmp" && mv "$cache.tmp" "$cache"
  before=$(cat "$T/tokseq")
  out=$(drive project-5)
  case "$out" in
    ghs_fixture_*) [ "$(cat "$T/tokseq")" = $((before + 1)) ] && ok || bad "a nearly-spent cached token is re-minted exactly once (mints $before -> $(cat "$T/tokseq"))" ;;
    *) bad "a cached token with 8 minutes left must not arm a triage tick (got: $out)" ;;
  esac
  # And a cached token with most of its hour left is reused, not re-minted.
  before=$(cat "$T/tokseq")
  out=$(drive project-5)
  case "$out" in ghs_fixture_*) [ "$(cat "$T/tokseq")" = "$before" ] && ok || bad "a fresh cached token is reused (mints $before -> $(cat "$T/tokseq"))" ;;
    *) bad "fresh cached token reuse (got: $out)" ;; esac
  # TRIAGE_TOKEN_MIN_LIFE is the registered knob (catalog/lanes.d/run-triage.json),
  # not a literal: asked for 300s, the same 8-minutes-left token is good enough.
  jq --arg e "$soon" '.token="ghs_nearly_spent" | .expires_at=$e' "$cache" > "$cache.tmp" && mv "$cache.tmp" "$cache"
  before=$(cat "$T/tokseq")
  out=$(drive project-5 TRIAGE_TOKEN_MIN_LIFE=300)
  [ "$out" = ghs_nearly_spent ] && [ "$(cat "$T/tokseq")" = "$before" ] && ok \
    || bad "TRIAGE_TOKEN_MIN_LIFE=300 reuses a token with 8 minutes left (got: $out, mints $before -> $(cat "$T/tokseq"))"
  # And text that is not a number falls back to the 3000s default: re-minted.
  out=$(drive project-5 TRIAGE_TOKEN_MIN_LIFE=soon)
  case "$out" in ghs_fixture_*) [ "$(cat "$T/tokseq")" = $((before + 1)) ] && ok || bad "an unparseable knob re-mints once (mints $before -> $(cat "$T/tokseq"))" ;;
    *) bad "an unparseable TRIAGE_TOKEN_MIN_LIFE falls back to 3000 (got: $out)" ;; esac
else
  bad "the first armed tick wrote the token cache at $cache"
fi

echo "triage-gh-app-token-test: $PASS pass, $FAIL fail"
[ "$FAIL" = 0 ]
