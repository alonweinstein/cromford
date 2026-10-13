#!/bin/bash
# tests/doorbell-app-hook.pool-doctor-test.sh — the doorbell reads the GitHub
# App's OWN webhook, and never asks for a PAT.
#
# THE ALERT THIS RETIRES (2026-09-16 -> 2026-09-24, daily): "[doorbell] cannot
# read the webhooks of example-org/cromford with any token on this box …
# Needs: a PAT with admin:repo_hook". The fleet authenticates as GitHub Apps
# (cromford, cromford-builders). Neither holds the Webhooks
# (repository_hooks) permission, so no installation token can list a repo's
# hooks — and an App-level webhook, the one doorbell docs/EVENTS.md 4.3 designed,
# is readable on the App's JWT. Probed live 2026-09-24: both Apps answer
# GET /app/hook/config 404 and events=[], so today the honest verdict is
# still "unreadable" — but the remedy it names is the App, not a PAT.
#
#   a. bin/gh-token.sh --app-hook prints `<url>\t<events>` from the JWT reads,
#      an empty url (rc 0) for an App with no webhook, rc 1 with no App at all;
#   b. a repo whose hooks cannot be read is ARMED when the App's own webhook
#      points at the receiver with events subscribed;
#   c. an App webhook elsewhere, or with no events, stays unreadable and says so;
#   d. the App is asked ONCE per run, not once per repo.
# Run from anywhere: tests/doorbell-app-hook.pool-doctor-test.sh (exit 0 = pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null 2>&1 && command -v openssl >/dev/null 2>&1 || { echo "SKIP: jq/openssl missing"; exit 0; }

# ══ a. gh-token.sh --app-hook ══════════════════════════════════════════════
mkdir -p "$T/g/bin/lib" "$T/g/env" "$T/g/state" "$T/g/logs" "$T/g/flags" "$T/fakebin"
cp "$DIR/bin/gh-token.sh" "$T/g/bin/"; chmod +x "$T/g/bin/gh-token.sh"
cp "$DIR/bin/lib/gh-app-auth.sh" "$DIR/bin/lib/gh-repo-token.sh" "$DIR/bin/lib/env-path.sh" "$T/g/bin/lib/"
openssl genrsa -out "$T/g/env/github-app.pem" 2048 2>/dev/null   # a throwaway key
printf 'GH_APP_ID=778899\nGH_APP_PRIVATE_KEY_FILE=%s\n' "$T/g/env/github-app.pem" > "$T/g/env/github-app.env"
cat > "$T/fakebin/curl" <<'SH'
#!/bin/bash
URL=""
while [ $# -gt 0 ]; do case "$1" in -H|-d|-X) shift 2 ;; -*) shift ;; *) URL="$1"; shift ;; esac; done
printf '%s\n' "$URL" >> "$CURL_LOG"
case "$URL" in
  */app/hook/config)
    case "${HOOK_MODE:-none}" in
      none) echo '{"message":"Not Found","status":"404"}' ;;
      set)  echo '{"url":"https://jobs.test.invalid/webhooks/github","content_type":"json"}' ;;
    esac ;;
  */app) printf '{"id":778899,"slug":"cromford","events":%s}\n' "${APP_EVENTS:-[]}" ;;
  *) echo '{}' ;;
esac
SH
chmod +x "$T/fakebin/curl"
gt() { env PATH="$T/fakebin:$PATH" HARNESS="$T/g" GH_APP_API_BASE="http://api.test" CURL_LOG="$T/curl.log" "$@" "$T/g/bin/gh-token.sh" --app-hook 2>/dev/null; }

: > "$T/curl.log"
OUT=$(gt HOOK_MODE=none); RC=$?
[ "$RC" = 0 ] && [ "$OUT" = "$(printf '\t')" ] && ok || bad "an App with no webhook must answer an empty url, rc 0 (rc=$RC out='$OUT')"
grep -q '/app/hook/config' "$T/curl.log" && ok || bad "--app-hook must read /app/hook/config"
OUT=$(gt HOOK_MODE=set APP_EVENTS='["issues","pull_request","push"]')
[ "$OUT" = "$(printf 'https://jobs.test.invalid/webhooks/github\tissues,pull_request,push')" ] \
  && ok || bad "--app-hook must print url<TAB>events, got '$OUT'"
: > "$T/g/flags/gh-app-tokens-off"
OUT=$(gt HOOK_MODE=set APP_EVENTS='["push"]'); RC=$?
[ "$RC" = 0 ] && ok || bad "--app-hook is a GET: the write kill switch must not stop it (rc=$RC)"
rm -f "$T/g/flags/gh-app-tokens-off"
mv "$T/g/env/github-app.env" "$T/g/env/off.env"
OUT=$(gt HOOK_MODE=set); RC=$?
[ "$RC" = 1 ] && [ -z "$OUT" ] && ok || bad "with no App configured --app-hook must answer rc 1 and nothing (rc=$RC out='$OUT')"

# ══ b-d. the doorbell ══════════════════════════════════════════════════════
export JOBS_URL="https://jobs.test.invalid" HARNESS="$T/harness" HARNESS_ALERTS="$T/harness/logs/ALERTS.log"
mkdir -p "$HARNESS/logs" "$HARNESS/flags"
export FLEET_CONF="$T/fleet.conf"
printf 'a  Test/a  -  -  1  box-test 100.0.0.1\nb  Test/b  -  -  2  box-test 100.0.0.1\n' > "$FLEET_CONF"
printf '#!/bin/bash\nexit 1\n' > "$T/fakebin/gh"; chmod +x "$T/fakebin/gh"   # no token lists any hooks
cat > "$T/apphook" <<'SH'
#!/bin/bash
printf 'x\n' >> "$APPHOOK_LOG"
case "${APPHOOK_MODE:-}" in
  armed)    printf '%s\t%s\n' "https://jobs.test.invalid/webhooks/github" "issues,pull_request,push" ;;
  noevents) printf '%s\t\n' "https://jobs.test.invalid/webhooks/github" ;;
  elsewhere) printf '%s\t%s\n' "https://example.invalid/hook" "push" ;;
  none)     printf '\t\n' ;;
  *) exit 1 ;;
esac
SH
chmod +x "$T/apphook"
run() { # run <mode> <args...>
  rm -f "$HARNESS"/flags/alerted-doorbell-* "$HARNESS_ALERTS"; : > "$T/apphook.log"
  OUT=$(env PATH="$T/fakebin:$PATH" DOORBELL_APP_HOOK="$T/apphook" APPHOOK_MODE="$1" APPHOOK_LOG="$T/apphook.log" \
        DOORBELL_GH="$T/fakebin/gh" "$DIR/bin/doorbell-coverage-check.sh" "${@:2}" 2>&1); RC=$?
}
alerts() { cat "$HARNESS_ALERTS" 2>/dev/null; }

run armed
case "$OUT" in *"Test/a: doorbell armed (the GitHub App"*) ok ;; *) bad "an App webhook at the receiver must arm an unreadable repo — $OUT" ;; esac
case "$OUT" in *"checked=2 missing=0 unreadable=0"*) ok ;; *) bad "App-armed repos must not count as unreadable — $OUT" ;; esac
[ -z "$(alerts)" ] && ok || bad "an App-armed fleet must not page: $(alerts)"
[ "$(grep -c . "$T/apphook.log")" = 1 ] && ok || bad "the App must be asked once per run, not per repo (asked $(grep -c . "$T/apphook.log"))"

run none
case "$OUT" in *"checked=2 missing=0 unreadable=2"*) ok ;; *) bad "no App webhook: repos stay unreadable — $OUT" ;; esac
case "$(alerts)" in *"has no webhook of its own"*) ok ;; *) bad "the alert must say the App has no webhook: $(alerts)" ;; esac
case "$(alerts)" in *"PAT with"*|*"admin:repo_hook"*) bad "the alert still asks for a PAT: $(alerts)" ;; *) ok ;; esac

run noevents --repo Test/a
case "$OUT" in *"unreadable=1"*) ok ;; *) bad "an App webhook with no events is not a doorbell — $OUT" ;; esac
case "$(alerts)" in *"subscribes to no events"*) ok ;; *) bad "the alert must say the App hook has no events: $(alerts)" ;; esac

run elsewhere --repo Test/a
case "$OUT" in *"unreadable=1"*) ok ;; *) bad "an App webhook elsewhere is not a doorbell — $OUT" ;; esac
case "$(alerts)" in *"points at https://example.invalid/hook, not at the receiver"*) ok ;; *) bad "the alert must name where the App hook points: $(alerts)" ;; esac

run fail --repo Test/a --strict
[ "$RC" = 0 ] && ok || bad "an unaskable App must not fail --strict (rc=$RC)"
case "$(alerts)" in *"could not be read"*) ok ;; *) bad "an unaskable App must say so: $(alerts)" ;; esac

echo "doorbell-app-hook.pool-doctor-test: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
