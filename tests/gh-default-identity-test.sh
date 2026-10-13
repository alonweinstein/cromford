#!/bin/bash
# tests/gh-default-identity-test.sh — the box's DEFAULT GitHub identity (#469).
#
# WHAT IS UNDER TEST. One PAT is one 5000/h REST bucket for every lane on every
# box. bin/lib/gh-app-auth.sh can already hand a lane a repo-scoped App
# installation token; this slice makes that token the DEFAULT identity — for a
# lane (gh_default_auth_for_slug / _for_project), for the box's shells and git
# (bin/ensure-box-gh-app-default.sh, which also points git's credential helper
# at bin/gh-token.sh inline), and it writes
# down WHICH identity got rate-limited when GitHub refuses (bin/lib/gh-limit-logger.sh).
#
# The properties that carry the weight, in the order they can hurt us:
#   1. the tag is a fact about the TOKEN, not about a return code. bin/gh-token.sh
#      prints the PAT when a mint fails, so `app:` is claimed only for a ghs_ token.
#   2. a lane that loops repos never runs repo B on repo A's installation token —
#      the helper resets to the process default before every attempt.
#   3. the ensure step logs the box out LAST, and only after a real App token, a
#      written profile snippet and a git credential helper this suite RUNS. A
#      failed mint or a failed write leaves the login exactly where it was.
#   4. no token VALUE reaches a log, a snippet or a console line.
#   5. an unarmed box behaves exactly as it did on 2026-09-13.
#
# Everything runs against a scratch $HARNESS with stubbed curl/gh and a
# throwaway RSA key generated in $T. Nothing here touches a real box, a real
# credential or a real repo.
# Run from anywhere: bash tests/gh-default-identity-test.sh   (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
# This box carries a live GH_TOKEN and may carry the App knobs. The fixture
# supplies its own; inheriting the real ones would test the box, not the code.
unset GH_TOKEN GH_LIMIT_IDENTITY GH_APP_TOKENS GH_TOKEN_READ
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

command -v openssl >/dev/null 2>&1 || { echo "gh-default-identity: openssl missing — bin/gh-token.sh itself needs it, so this is a real skip"; exit 0; }
command -v jq >/dev/null 2>&1 || { echo "gh-default-identity: jq missing — bin/gh-token.sh itself needs it, so this is a real skip"; exit 0; }

mkdir -p "$T/lanebin" "$T/bin/lib" "$T/env" "$T/flags" "$T/logs" "$T/state" "$T/locks" "$T/fakebin" "$T/w/x"
cp "$DIR/bin/gh-token.sh" "$DIR/bin/fleet-conf.sh" "$T/bin/"
cp "$DIR/bin/alert-line.sh" "$T/bin/"  # TEST-CHANGE: BH-2365 — converted writers call bin/alert-line.sh
cp "$DIR/bin/lib/gh-app-auth.sh" "$DIR/bin/lib/gh-repo-token.sh" "$DIR/bin/lib/gh-budget.sh" "$T/bin/lib/"
# The two files this ticket ADDS. Copied when they exist so the suite reports
# which assertion is unmet rather than dying on a missing path.
for NEWF in bin/lib/gh-limit-logger.sh bin/ensure-box-gh-app-default.sh; do
  [ -r "$DIR/$NEWF" ] && cp "$DIR/$NEWF" "$T/$NEWF"
done
chmod +x "$T/bin/gh-token.sh" "$T/bin/fleet-conf.sh" 2>/dev/null
chmod +x "$T/bin/ensure-box-gh-app-default.sh" 2>/dev/null
printf '#!/bin/bash\nexit 0\n' > "$T/bin/beat.sh"; chmod +x "$T/bin/beat.sh"

# A THROWAWAY key, generated here and deleted with $T.
openssl genrsa -out "$T/env/github-app.pem" 2048 2>/dev/null
chmod 600 "$T/env/github-app.pem"
printf 'GH_APP_ID=778899\nGH_APP_PRIVATE_KEY_FILE=%s/env/github-app.pem\n' "$T" > "$T/env/github-app.env"
printf 'widget TestOwner/widget - - 2 box-a\nflaky TestOwner/flaky - - 3 box-a\nblind o/blind - - 4 box-a\n' > "$T/fleet.conf"

# --- the curl stub (bin/gh-token.sh's three endpoints) ------------------------
# TOKSEQ makes every mint a distinguishable value, so a cache HIT and a REFRESH
# cannot be confused. The App is NOT installed on o/blind and MINT_FAILS=1 fails
# any mint — both are the fixture for "gh-token.sh answers the PAT instead".
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
    printf '[{"id":4242,"account":{"login":"TestOwner"}},{"id":7,"account":{"login":"o"}}]\n' ;;
  */access_tokens)
    case "${MINT_FAILS:-0}|$BODY" in 1\|*|*'"blind"'*) echo '{"message":"Bad credentials"}'; exit 0 ;; esac
    N=$(( $(cat "$TOKSEQ" 2>/dev/null || echo 0) + 1 )); printf '%s' "$N" > "$TOKSEQ"
    printf '{"token":"ghs_fixture_%s","expires_at":"%s"}\n' "$N" "$(date -u -d '+1 hour' '+%Y-%m-%dT%H:%M:%SZ')" ;; # determinism: ok an installation token's one-hour life IS the fixture
  */rate_limit)
    printf '{"rate":{"remaining":4996,"limit":5000}}\n' ;;
  *) echo '{}' ;;
esac
SH
chmod +x "$T/fakebin/curl"

# --- the gh stub -------------------------------------------------------------
# Records "<GH_TOKEN> <args>" per call, so a test can read the identity a call
# actually went out on. GH_MODE picks the stderr shape section 4 classifies;
# `api user` answers 403 the way GitHub really answers an installation token.
# THE TWO github_pat_ LITERALS BELOW CARRY A FIXTURE MARKER ON PURPOSE.
# bin/share/leakcheck.py refuses any github_pat_ with 20+ characters after the
# prefix, and bin/share/mapping.py exempts a literal only when it spells
# "fixture", "do-not-ship" or "example" — so a marker-less stub string makes the
# public-mirror publish, and tests/share-publish-clean.bh-795-test.sh, refuse
# the whole tree. Keep the marker in any token-shaped fixture added here.
cat > "$T/fakebin/gh" <<'SH'
#!/bin/bash
[ -n "${GH_SINK:-}" ] && printf '%s %s\n' "${GH_TOKEN:-unset}" "$*" >> "$GH_SINK"
case "${GH_MODE:-}" in
  ratelimit)   echo "gh: API rate limit exceeded for user ID 1. (HTTP 403)" >&2; exit 1 ;;
  secondary)   echo "gh: You have exceeded a secondary rate limit. Please wait a few minutes before you try again." >&2; exit 1 ;;
  notfound)    echo "gh: Not Found (HTTP 404)" >&2; exit 1 ;;
  perm403)     echo "gh: Resource not accessible by integration (HTTP 403)" >&2; exit 1 ;;
  badcreds)    echo "gh: Bad credentials (HTTP 401)" >&2; exit 1 ;;
  graphql404)  echo "GraphQL: Could not resolve to a Repository with the name 'o/nope'." >&2; exit 1 ;;
  stdoutlimit) echo "this PR body explains what API rate limit exceeded means"; exit 0 ;;
  okmode)      echo '{"ok":true}'; exit 0 ;;
  tokenleak)   echo "gh: API rate limit exceeded — ghs_fixture_1 is spent for the hour (HTTP 403)" >&2; exit 1 ;;
  patleak)     echo "gh: HTTP 429 for github_pat_11ABCDEFG_fixture_value, back off" >&2; exit 1 ;;
esac
case "$*" in
  "auth status --hostname github.com"|"auth status -h github.com")
    [ -s "${GH_LOGGEDIN_FILE:-}" ] && exit 0
    echo "gh: You are not logged into any GitHub hosts." >&2; exit 1 ;;
  "auth logout --hostname github.com")
    [ -s "${GH_LOGGEDIN_FILE:-}" ] || { echo "gh: not logged in to github.com" >&2; exit 1; }
    rm -f "$GH_LOGGEDIN_FILE"; exit 0 ;;
  "auth setup-git"*) exit 0 ;;
  "auth token") printf 'keyring-tok\n' ;;
  "auth git-credential get") printf 'username=x-access-token\npassword=keyring-tok\n'; exit 0 ;;
  "api user"*) echo "gh: Resource not accessible by integration (HTTP 403)" >&2; exit 1 ;;
  "api repos/o/blind -q .id") echo "gh: Not Found (HTTP 404)" >&2; exit 1 ;;
  "api repos/"*" -q .id") exit 0 ;;
  "api repos/"*"--jq .full_name") S="$2"; printf '%s\n' "${S#repos/}" ;;
  *) exit 1 ;;
esac
SH
chmod +x "$T/fakebin/gh"

: > "$T/curl.log"; printf '0' > "$T/tokseq"; : > "$T/gh-sink.txt"
mints() { grep -c 'access_tokens' "$T/curl.log" 2>/dev/null; }

# drive <code> — gh-app-auth.sh sourced fresh, GH_TOKEN=pattok as the process
# default, the fixture's curl/gh on PATH. LIBS adds further libs to source.
drive() {
  ( export PATH="$T/fakebin:$PATH" HARNESS="$T" GH_APP_API_BASE=http://api.test \
           CURL_LOG="$T/curl.log" TOKSEQ="$T/tokseq" FLEET_CONF="$T/fleet.conf" \
           GH_SINK="$T/gh-sink.txt" GH_TOKEN=pattok
    # shellcheck source=/dev/null
    . "$T/bin/lib/gh-app-auth.sh"
    for L in ${LIBS:-}; do . "$T/bin/lib/$L"; done
    eval "$1" ) 2>/dev/null
}
idline() { printf 'rc=%s tok=%s id=%s' "$1" "${2:-unset}" "${3:-unset}"; }

# ══ 1. armed: the App token IS the default, and it is tagged app: ═══════════
: > "$T/curl.log"
OUT=$(drive 'gh_default_auth_for_project widget; printf "rc=%s tok=%s id=%s" "$?" "${GH_TOKEN:-unset}" "${GH_LIMIT_IDENTITY:-unset}"')
[ "$OUT" = "rc=0 tok=ghs_fixture_1 id=app:TestOwner/widget" ] && ok \
  || bad "1a: an armed box must resolve the project to its App token and tag it app:, got '$OUT'"
[ "$(mints)" = 1 ] && ok || bad "1b: the first ask must mint exactly once, got $(mints)"
OUT=$(drive 'gh_default_auth_for_slug TestOwner/widget; printf "rc=%s tok=%s id=%s" "$?" "${GH_TOKEN:-unset}" "${GH_LIMIT_IDENTITY:-unset}"')
[ "$OUT" = "rc=0 tok=ghs_fixture_1 id=app:TestOwner/widget" ] && ok \
  || bad "1c: the slug form must answer the same as the project form, got '$OUT'"
[ "$(mints)" = 1 ] && ok || bad "1d: a warm cache must cost no mint at all, got $(mints) total"
# The two functions this ticket must not disturb.
OUT=$(drive 'gh_auth_for TestOwner/widget; printf "tok=%s " "${GH_TOKEN:-unset}"; gh_auth_reset; printf "reset=%s" "${GH_TOKEN:-unset}"')
[ "$OUT" = "tok=ghs_fixture_1 reset=pattok" ] && ok \
  || bad "1e: gh_auth_for/gh_auth_reset must still behave exactly as before, got '$OUT'"
OUT=$(drive 'gh_default_auth_for_slug TestOwner/widget; gh_default_auth_reset; printf "rc=%s tok=%s id=%s" "$?" "${GH_TOKEN:-unset}" "${GH_LIMIT_IDENTITY:-unset}"')
[ "$OUT" = "rc=0 tok=pattok id=unset" ] && ok \
  || bad "1f: the reset must put the process default back and drop the tag, got '$OUT'"

# ══ 2. the PAT path is tagged pat:, always ═════════════════════════════════
OUT=$(drive 'GH_APP_TOKENS=0 gh_default_auth_for_project widget; printf "rc=%s tok=%s id=%s" "$?" "${GH_TOKEN:-unset}" "${GH_LIMIT_IDENTITY:-unset}"')
[ "$OUT" = "rc=0 tok=pattok id=pat:TestOwner/widget" ] && ok \
  || bad "2a: an unarmed box must keep its PAT and tag it pat:, got '$OUT'"
OUT=$(drive 'MINT_FAILS=1 gh_default_auth_for_project flaky; printf "rc=%s tok=%s id=%s" "$?" "${GH_TOKEN:-unset}" "${GH_LIMIT_IDENTITY:-unset}"')
[ "$OUT" = "rc=0 tok=pattok id=pat:TestOwner/flaky" ] && ok \
  || bad "2b: a FAILED mint prints the PAT, so it must be tagged pat: and never app:, got '$OUT'"
OUT=$(drive 'gh_default_auth_for_project nosuchproject; printf "rc=%s tok=%s id=%s" "$?" "${GH_TOKEN:-unset}" "${GH_LIMIT_IDENTITY:-unset}"')
[ "$OUT" = "rc=1 tok=pattok id=unset" ] && ok \
  || bad "2c: a project with no fleet.conf row must rc 1 and touch nothing, got '$OUT'"
# With the PAT probe sourced (the lanes that already have it), a repo NO token
# can see is still rc 1 — the invisible-repo alert keeps its trigger.
OUT=$(LIBS=gh-repo-token.sh drive 'gh_default_auth_for_slug o/blind; printf "rc=%s id=%s" "$?" "${GH_LIMIT_IDENTITY:-unset}"')
[ "$OUT" = "rc=1 id=pat:o/blind" ] && ok \
  || bad "2d: a repo no token can see must still rc 1 through the probe, got '$OUT'"
OUT=$(LIBS=gh-repo-token.sh drive 'GH_APP_TOKENS=0 gh_default_auth_for_slug TestOwner/widget; printf "rc=%s tok=%s" "$?" "${GH_TOKEN:-unset}"')
[ "$OUT" = "rc=0 tok=pattok" ] && ok \
  || bad "2e: a visible repo on the PAT path must rc 0, got '$OUT'"
# THE TWO-REPO CASE. Repo A mints; repo B cannot. B must run on the process's
# own PAT, never on A's installation token.
OUT=$(drive 'gh_default_auth_for_slug TestOwner/widget >/dev/null 2>&1; MINT_FAILS=1 gh_default_auth_for_slug TestOwner/flaky; printf "rc=%s tok=%s id=%s" "$?" "${GH_TOKEN:-unset}" "${GH_LIMIT_IDENTITY:-unset}"')
[ "$OUT" = "rc=0 tok=pattok id=pat:TestOwner/flaky" ] && ok \
  || bad "2f: the second repo must not inherit the first repo's installation token, got '$OUT'"
# 2x: THE TAG IS READ FROM THE TOKEN THE FALLBACK LEAVES BEHIND. Since BH-765 the
# gh_repo_use_token ladder can itself export an App installation token, so a tag
# decided before that call names the wrong bucket in logs/gh-rate.log. The stub
# below is that ladder: the box is unarmed, so gh_auth_for returns 1 and the
# fallback is the only thing that sets GH_TOKEN.
OUT=$(drive 'gh_repo_use_token() { export GH_TOKEN=ghs_fromladder; return 0; }
             GH_APP_TOKENS=0 gh_default_auth_for_slug TestOwner/widget
             printf "rc=%s tok=%s id=%s" "$?" "${GH_TOKEN:-unset}" "${GH_LIMIT_IDENTITY:-unset}"')
[ "$OUT" = "rc=0 tok=ghs_fromladder id=app:TestOwner/widget" ] && ok \
  || bad "2x1: a fallback that exports an App token must be tagged app:, got '$OUT'"
OUT=$(drive 'gh_repo_use_token() { export GH_TOKEN=github_pat_11ABCDEFG_fixture_other; return 0; }
             GH_APP_TOKENS=0 gh_default_auth_for_slug TestOwner/widget
             printf "rc=%s tok=%s id=%s" "$?" "${GH_TOKEN:-unset}" "${GH_LIMIT_IDENTITY:-unset}"')
[ "$OUT" = "rc=0 tok=github_pat_11ABCDEFG_fixture_other id=pat:TestOwner/widget" ] && ok \
  || bad "2x2: a fallback that exports a PAT must be tagged pat:, got '$OUT'"
OUT=$(drive 'gh_repo_use_token() { return 1; }
             GH_APP_TOKENS=0 gh_default_auth_for_slug TestOwner/widget
             printf "rc=%s tok=%s id=%s" "$?" "${GH_TOKEN:-unset}" "${GH_LIMIT_IDENTITY:-unset}"')
[ "$OUT" = "rc=1 tok=pattok id=pat:TestOwner/widget" ] && ok \
  || bad "2x3: a fallback that finds no token must still rc 1 and tag the PAT it kept, got '$OUT'"

# ══ 3. not a slug at all ═══════════════════════════════════════════════════
OUT=$(drive 'gh_default_auth_for_slug notaslug; printf "rc=%s tok=%s id=%s" "$?" "${GH_TOKEN:-unset}" "${GH_LIMIT_IDENTITY:-unset}"')
[ "$OUT" = "rc=1 tok=pattok id=unset" ] && ok || bad "3a: 'notaslug' must rc 1 and touch nothing, got '$OUT'"
OUT=$(drive 'gh_default_auth_for_slug ""; printf "rc=%s tok=%s id=%s" "$?" "${GH_TOKEN:-unset}" "${GH_LIMIT_IDENTITY:-unset}"')
[ "$OUT" = "rc=1 tok=pattok id=unset" ] && ok || bad "3b: an empty slug must rc 1 and touch nothing, got '$OUT'"

# ══ 4. the rate-limit logger: one line per REFUSAL, and only per refusal ════
W="$T/w"
ghw() { # ghw <GH_MODE> <args...> — the gh wrapper, stdout then rc on its own line
  ( export PATH="$T/fakebin:$PATH" HARNESS="$W" GH_MODE="$1"; shift
    [ -n "${IDENT:-}" ] && export GH_LIMIT_IDENTITY="$IDENT"
    # shellcheck source=/dev/null
    . "$T/bin/lib/gh-limit-logger.sh" 2>/dev/null || { echo "NO-LIB"; exit 9; }
    gh "$@"; echo "rc=$?" )
}
limits() { grep -c 'gh-limit' "$W/logs/gh-rate.log" 2>/dev/null; }
if [ -r "$T/bin/lib/gh-limit-logger.sh" ]; then
  rm -f "$W/logs/gh-rate.log"
  OUT=$(IDENT=app:TestOwner/widget ghw ratelimit api rate_limit 2>"$W/err.txt")
  [ "$OUT" = "rc=1" ] && ok || bad "4a: the wrapper must pass the real exit code through, got '$OUT'"
  [ "$(limits)" = 1 ] && ok || bad "4b: a rate-limit refusal must write exactly one line, got $(limits)"
  L=$(grep 'gh-limit' "$W/logs/gh-rate.log" | tail -1)
  case "$L" in *"identity=app:TestOwner/widget"*) ok ;; *) bad "4c: the line must name the identity, got '$L'" ;; esac
  case "$L" in *"rc=1"*) ok ;; *) bad "4d: the line must carry the rc, got '$L'" ;; esac
  case "$L" in *"cmd=api rate_limit"*) ok ;; *) bad "4e: the line must name the command, got '$L'" ;; esac
  case "$L" in *"rate limit exceeded"*) ok ;; *) bad "4f: the line must carry GitHub's own words, got '$L'" ;; esac
  grep -q 'API rate limit exceeded' "$W/err.txt" && ok || bad "4g: stderr must still reach the caller, got '$(cat "$W/err.txt")'"
  IDENT=app:TestOwner/widget ghw secondary api rate_limit >/dev/null 2>&1
  [ "$(limits)" = 2 ] && ok || bad "4h: a secondary rate limit is a refusal too, got $(limits)"
  # ...and the six shapes that must stay SILENT.
  for M in notfound perm403 badcreds graphql404 stdoutlimit okmode; do
    IDENT=app:TestOwner/widget ghw "$M" api "repos/x/y" >/dev/null 2>&1
  done
  [ "$(limits)" = 2 ] && ok || bad "4i: a 404/403/401/GraphQL miss/success must write nothing, got $(limits) lines"
  OUT=$(IDENT=app:TestOwner/widget ghw okmode api repos/x/y 2>/dev/null)
  [ "$OUT" = '{"ok":true}
rc=0' ] && ok || bad "4j: stdout and rc must pass through untouched, got '$OUT'"
  rm -f "$W/logs/gh-rate.log"
  ghw ratelimit api rate_limit >/dev/null 2>&1
  grep -q 'identity=unset' "$W/logs/gh-rate.log" && ok || bad "4k: with no tag the line must say unset, got '$(cat "$W/logs/gh-rate.log")'"
  IDENT=pat:TestOwner/widget ghw tokenleak api repos/x/y >/dev/null 2>&1
  IDENT=pat:TestOwner/widget ghw patleak api repos/x/y >/dev/null 2>&1
  [ "$(grep -c '<redacted>' "$W/logs/gh-rate.log")" = 2 ] && ok \
    || bad "4l: a token-shaped run in GitHub's message must be redacted, got '$(cat "$W/logs/gh-rate.log")'"
  grep -qE 'ghs_fixture|github_pat_|pattok|keyring-tok' "$W/logs/gh-rate.log" \
    && bad "4m: a token VALUE reached logs/gh-rate.log: $(cat "$W/logs/gh-rate.log")" || ok
  # A log we cannot write never changes what the caller sees.
  # $T/notafile is a regular FILE, so the lib's mkdir -p under it cannot work —
  # an unwritable log inside the scratch tree, never a path on the real box.
  : > "$T/notafile"
  OUT=$( ( export PATH="$T/fakebin:$PATH" HARNESS="$T/notafile/nope" GH_MODE=ratelimit
           . "$T/bin/lib/gh-limit-logger.sh"; gh api rate_limit; echo "rc=$?" ) 2>/dev/null )
  [ "$OUT" = "rc=1" ] && ok || bad "4n: an unwritable log must not change the rc, got '$OUT'"
  # A tree with no gh BINARY must define no gh FUNCTION: bin/lib/hotfix-lib.sh
  # and bin/lib/revdep-lib.sh ask `command -v gh` to decide whether the feature
  # exists at all, and a wrapper would answer yes for a box that has no gh.
  OUT=$( ( export PATH="$T/empty"; mkdir -p "$T/empty"
           . "$T/bin/lib/gh-limit-logger.sh"; echo "rc=$? fn=$(type -t gh 2>/dev/null || echo none)" ) 2>/dev/null )
  [ "$OUT" = "rc=0 fn=none" ] && ok || bad "4o: with no gh binary the lib must define nothing, got '$OUT'"
  # THE ERREXIT LANDMINE. The classifier's `msg=$(grep …)` is the last command
  # before the `if`, and grep exits 1 when stderr is clean — so under `set -e`
  # the caller died on its first SUCCESSFUL gh call, before `return "$rc"` ever
  # ran. Every assertion above this one runs WITHOUT -e (a $(...) substitution
  # does not inherit errexit either), which is exactly why a wrapper the header
  # sells as drop-in could ship with it: this is the assertion that sees it.
  OUT=$( ( set -e; export PATH="$T/fakebin:$PATH" HARNESS="$W" GH_MODE=okmode
           # shellcheck source=/dev/null
           . "$T/bin/lib/gh-limit-logger.sh"
           gh api repos/x/y >/dev/null
           echo REACHED ) 2>/dev/null; printf 'rc=%s' "$?" )
  [ "$OUT" = "REACHED
rc=0" ] && ok || bad "4p: under set -e a SUCCESSFUL gh call must not kill the caller, got '$OUT'"
else
  bad "4: bin/lib/gh-limit-logger.sh does not exist — section 4's sixteen assertions cannot run"
fi

# ══ 6. the ensure step: refuse early, log out LAST ═════════════════════════
SNIP="$T/profile-snippet.sh"; BRC="$T/bashrc"; GCFG="$T/gitconfig"
ensure() { # ensure <slug|project> — stdout+stderr, then rc on its own line
  ( export PATH="$T/fakebin:$PATH" HARNESS="$T" GH_APP_API_BASE=http://api.test \
           CURL_LOG="$T/curl.log" TOKSEQ="$T/tokseq" FLEET_CONF="$T/fleet.conf" \
           GH_TOKEN=pattok GH_SINK="$T/ensure-sink.txt" GH_LOGGEDIN_FILE="$T/loggedin" \
           GH_DEFAULT_PROFILE_SNIPPET="$SNIP" GH_DEFAULT_BASHRC="$BRC" \
           GIT_CONFIG_GLOBAL="$GCFG" HOME="$T" ${ENSURE_ENV:-PATH=$T/fakebin:$PATH}
    "$T/bin/ensure-box-gh-app-default.sh" "$@" 2>&1; echo "rc=$?" )
}
logouts() { grep -c 'auth logout' "$T/ensure-sink.txt" 2>/dev/null; }
if [ -x "$T/bin/ensure-box-gh-app-default.sh" ]; then
  : > "$T/ensure-sink.txt"; : > "$BRC"; rm -f "$SNIP" "$GCFG"; echo operator > "$T/loggedin"
  # The box's plain PAT on disk, where gh-token.sh --pat finds it once the
  # keyring is gone: since BH-4798 step 5 refuses to log out a keyring that is
  # the only plain PAT, and the process GH_TOKEN does not count (in a login
  # shell it is the snippet's App token). The refusal is pinned in
  # tests/fly-envbundle-pool-nopat.bh-4798-test.sh.
  printf 'GH_PAT=pattok\n' > "$T/env/gh-pat"
  # (a) an unarmed box: nothing written, nobody logged out, and it says so
  mv "$T/env/github-app.env" "$T/env/github-app.env.off"
  OUT=$(ensure widget)
  grep -q 'rc=0' <<<"$OUT" && grep -qi 'not armed' <<<"$OUT" && ok \
    || bad "6a: an unarmed box must exit 0 and say it did nothing, got '$OUT'"
  [ ! -f "$SNIP" ] && [ "$(logouts)" = 0 ] && [ -s "$T/loggedin" ] && ok \
    || bad "6b: an unarmed box must write no snippet and log nobody out (snippet=$([ -f "$SNIP" ] && echo yes || echo no) logouts=$(logouts))"
  mv "$T/env/github-app.env.off" "$T/env/github-app.env"
  # (b) armed, but the mint fails: gh-token.sh answers the PAT, and swapping a
  #     working login for the PAT we already have is all downside. `flaky` is
  #     the project with nothing in the token cache, so the mint is really tried.
  OUT=$(ENSURE_ENV=MINT_FAILS=1 ensure flaky)
  grep -q 'rc=1' <<<"$OUT" && ok || bad "6c: a failed mint must refuse, got '$OUT'"
  [ ! -f "$SNIP" ] && [ "$(logouts)" = 0 ] && [ -s "$T/loggedin" ] && ok \
    || bad "6d: a failed mint must leave the login and write no snippet (snippet=$([ -f "$SNIP" ] && echo yes || echo no) logouts=$(logouts))"
  # (c) the real thing
  OUT=$(ensure widget)
  grep -q 'rc=0' <<<"$OUT" && ok || bad "6e: the armed ensure step must succeed, got '$OUT'"
  grep -q 'export GH_TOKEN=' "$SNIP" 2>/dev/null && grep -q 'gh-token.sh "TestOwner/widget"' "$SNIP" 2>/dev/null \
    && ok || bad "6f: the snippet must export GH_TOKEN from gh-token.sh for this repo, got '$(cat "$SNIP" 2>/dev/null)'"
  [ "$(grep -cF "$SNIP" "$BRC")" = 1 ] && ok || bad "6g: the bashrc must source the snippet exactly once, got '$(cat "$BRC")'"
  grep -q 'gh-token.sh' "$GCFG" 2>/dev/null && ok \
    || bad "6h: git's credential helper must mint through gh-token.sh, got '$(cat "$GCFG" 2>/dev/null)'"
  grep -q 'useHttpPath' "$GCFG" 2>/dev/null && ok \
    || bad "6h2: the helper needs useHttpPath to learn WHICH repo git is fetching, got '$(cat "$GCFG" 2>/dev/null)'"
  [ "$(logouts)" = 1 ] && [ ! -s "$T/loggedin" ] && ok \
    || bad "6i: the box login must be logged out exactly once (logouts=$(logouts))"
  grep -q 'reads TestOwner/widget' <<<"$OUT" && ok || bad "6j: the smoke summary must name the repo the App identity can read, got '$OUT'"
  SL=$(grep -n "$SNIP" <<<"$OUT" | head -1 | cut -d: -f1)
  LL=$(grep -n 'logged the box login out' <<<"$OUT" | head -1 | cut -d: -f1)
  [ -n "$SL" ] && [ -n "$LL" ] && [ "$SL" -lt "$LL" ] && ok \
    || bad "6k: the snippet must be written BEFORE the logout (snippet line $SL, logout line $LL) in '$OUT'"
  # (d) idempotent
  OUT=$(ensure TestOwner/widget)
  grep -q 'rc=0' <<<"$OUT" && [ "$(logouts)" = 1 ] && [ "$(grep -cF "$SNIP" "$BRC")" = 1 ] && ok \
    || bad "6l: a re-run must change nothing (logouts=$(logouts) bashrc=$(grep -cF "$SNIP" "$BRC")) '$OUT'"
  grep -qi 'nothing to log out' <<<"$OUT" && ok || bad "6m: a box with no login must say so plainly, got '$OUT'"
  grep -qE 'ghs_fixture|pattok|keyring-tok' <<<"$OUT" && bad "6n: a token value reached the ensure step's output: $OUT" || ok
  grep -qE 'ghs_fixture|pattok|keyring-tok' "$SNIP" && bad "6o: a token value reached the profile snippet: $(cat "$SNIP")" || ok
  rm -f "$T/env/gh-pat"
else
  bad "6: bin/ensure-box-gh-app-default.sh does not exist — section 6's fifteen assertions cannot run"
fi

# ══ 7. bin/bootstrap-machine.sh, its two blocks driven verbatim ════════════
B7="$T/boot"; mkdir -p "$B7/bin" "$B7/env"
printf '#!/bin/bash\nprintf "%%s\\n" "$*" >> "%s/ensure-calls.txt"\nexit 0\n' "$B7" > "$B7/bin/ensure-box-gh-app-default.sh"
printf '#!/bin/bash\nprintf ghs_boot_stub\n' > "$B7/bin/gh-token.sh"
chmod +x "$B7/bin/ensure-box-gh-app-default.sh" "$B7/bin/gh-token.sh"
: > "$B7/env/global.env"; : > "$B7/ensure-calls.txt"
blk() { awk -v s="^# >>> $1\$" -v e="^# <<< $1\$" '$0~s{f=1;next} $0~e{exit} f' "$DIR/bin/bootstrap-machine.sh"; }
IDBLK=$(blk 'box gh default'); PREBLK=$(blk 'gh preflight')
if [ -n "$IDBLK" ]; then
  OUT=$(env HARNESS="$B7" HENV="$B7/env" PATH="$T/fakebin:$PATH" bash -c \
        'set -euo pipefail; HERE="$1"; REPO_SLUG="$2"; eval "$3"; printf "GH_TOKEN=%s\n" "${GH_TOKEN:-unset}"' \
        _ "$B7/bin" TestOwner/widget "$IDBLK" 2>&1)
  grep -q 'GH_TOKEN=ghs_boot_stub' <<<"$OUT" && ok \
    || bad "7a: the identity block must export what gh-token.sh answers, got '$OUT'"
  [ "$(grep -cx 'TestOwner/widget' "$B7/ensure-calls.txt")" = 1 ] && ok \
    || bad "7b: the block must call the ensure step exactly once with the repo slug, got '$(cat "$B7/ensure-calls.txt")'"
else
  bad "7: no '# >>> box gh default' block in bin/bootstrap-machine.sh — nothing to drive"
fi
if [ -n "$PREBLK" ]; then
  : > "$B7/gh-pre.txt"
  OUT=$(env HENV="$B7/env" PATH="$T/fakebin:$PATH" GH_SINK="$B7/gh-pre.txt" GH_LOGGEDIN_FILE="$B7/no-login" \
        bash -c 'set -euo pipefail; eval "$1"; echo REACHED-THE-END' _ "$PREBLK" 2>&1)
  grep -q 'REACHED-THE-END' <<<"$OUT" && ok \
    || bad "7c: a box with no keyring login must survive the preflight under set -e, got '$OUT'"
  grep -q 'WARN' <<<"$OUT" && ok || bad "7d: a login-less box must be warned, got '$OUT'"
  grep -q 'setup-git' "$B7/gh-pre.txt" && bad "7e: gh auth setup-git must not run without a login — it exits 1" || ok
  : > "$B7/gh-pre.txt"; echo operator > "$B7/loggedin"
  OUT=$(env HENV="$B7/env" PATH="$T/fakebin:$PATH" GH_SINK="$B7/gh-pre.txt" GH_LOGGEDIN_FILE="$B7/loggedin" \
        bash -c 'set -euo pipefail; eval "$1"; echo REACHED-THE-END' _ "$PREBLK" 2>&1)
  grep -q 'setup-git' "$B7/gh-pre.txt" && ok || bad "7f: a logged-in box must still get gh auth setup-git, got '$(cat "$B7/gh-pre.txt")'"
else
  bad "7: no '# >>> gh preflight' block in bin/bootstrap-machine.sh — nothing to drive"
fi
IDLINE=$(grep -n '^# >>> box gh default' "$DIR/bin/bootstrap-machine.sh" | head -1 | cut -d: -f1)
CLONE=$(grep -n '|| gh repo clone' "$DIR/bin/bootstrap-machine.sh" | head -1 | cut -d: -f1)
# BH-6043: the clone lives in bm_repos(), defined near the top so --repos-only
# can run it alone. The full bootstrap clones where it CALLS bm_repos, so that
# call is the line the identity block must come before.
if grep -q '^bm_repos() {' "$DIR/bin/bootstrap-machine.sh"; then
  CLONE=$(grep -n '^bm_repos$' "$DIR/bin/bootstrap-machine.sh" | head -1 | cut -d: -f1)
fi
[ -n "$IDLINE" ] && [ -n "$CLONE" ] && [ "$IDLINE" -lt "$CLONE" ] && ok \
  || bad "7g: the identity block must come BEFORE the clone (block $IDLINE, clone $CLONE) — an App-only box cannot clone otherwise"
grep -q 'gh-repo-token.sh' "$DIR/bin/bootstrap-machine.sh" && ok \
  || bad "7h: bootstrap must name bin/lib/gh-repo-token.sh as the PAT fallback"
grep -q 'GH_TOKEN from gh-token.sh' "$DIR/bin/bootstrap-machine.sh" && ok \
  || bad "7i: the smoke test must say which identity it ran on"
# 7j: AN EMPTY MINT MUST NOT BECOME AN EMPTY GH_TOKEN. On a PAT-keyring box with
# no GH_TOKEN in global.env, gh-token.sh prints nothing; GH_TOKEN="" would make
# the clone below run unauthenticated instead of on the keyring identity. Note
# ${GH_TOKEN-unset}, not ${GH_TOKEN:-unset} — set-and-empty is exactly the bug.
if [ -n "$IDBLK" ]; then
  printf '#!/bin/bash\nexit 0\n' > "$B7/bin/gh-token.sh"; chmod +x "$B7/bin/gh-token.sh"
  OUT=$(env HARNESS="$B7" HENV="$B7/env" PATH="$T/fakebin:$PATH" bash -c \
        'set -euo pipefail; HERE="$1"; REPO_SLUG="$2"; eval "$3"; printf "GH_TOKEN=%s\n" "${GH_TOKEN-unset}"' \
        _ "$B7/bin" TestOwner/widget "$IDBLK" 2>&1)
  grep -qx 'GH_TOKEN=unset' <<<"$OUT" && ok \
    || bad "7j1: an empty mint must leave GH_TOKEN alone, not export an empty one, got '$OUT'"
  OUT=$(env HARNESS="$B7" HENV="$B7/env" PATH="$T/fakebin:$PATH" GH_TOKEN=keyring-pat bash -c \
        'set -euo pipefail; HERE="$1"; REPO_SLUG="$2"; eval "$3"; printf "GH_TOKEN=%s\n" "${GH_TOKEN-unset}"' \
        _ "$B7/bin" TestOwner/widget "$IDBLK" 2>&1)
  grep -qx 'GH_TOKEN=keyring-pat' <<<"$OUT" && ok \
    || bad "7j2: an empty mint must leave an existing GH_TOKEN standing, got '$OUT'"
  printf '#!/bin/bash\nprintf ghs_boot_stub\n' > "$B7/bin/gh-token.sh"; chmod +x "$B7/bin/gh-token.sh"
fi

# ══ 8. the ticket's own static checks ══════════════════════════════════════
for F in bin/lib/gh-app-auth.sh bin/lib/gh-limit-logger.sh bin/ensure-box-gh-app-default.sh \
         bin/bootstrap-machine.sh bin/merge-conductor.sh \
         bin/merge-sweep.sh bin/reconcile-prs.sh bin/review-rescue.sh bin/main-red-detector.sh; do
  if [ -f "$DIR/$F" ] && bash -n "$DIR/$F" 2>/dev/null; then ok; else bad "8: bash -n $F"; fi
done
for F in merge-conductor merge-sweep reconcile-prs review-rescue main-red-detector; do
  for NEEDLE in 'gh_default_auth_for_slug' 'gh-limit-logger.sh' 'gh-app-auth.sh' 'gh_default_auth_reset'; do
    grep -qF "$NEEDLE" "$DIR/bin/$F.sh" && ok || bad "8: bin/$F.sh never names '$NEEDLE'"
  done
  # The call is GUARDED — a box mid-harness-sync still carries the old lib, and
  # an unguarded call there would kill the lane with "command not found".
  grep -qE '(command -v|type) gh_default_auth_for_slug' "$DIR/bin/$F.sh" && ok \
    || bad "8: bin/$F.sh calls the helper without checking that it exists"
done
# The helper is asked FIRST in the two lanes that also carry the PAT probe: a
# probe that ran first would 404 a repo the App can see and page for it.
for F in main-red-detector review-rescue; do
  A=$(grep -n 'gh_default_auth_for_slug "\$SLUG"' "$DIR/bin/$F.sh" | head -1 | cut -d: -f1)
  B=$(grep -n 'gh_repo_use_token "\$SLUG"' "$DIR/bin/$F.sh" | head -1 | cut -d: -f1)
  [ -n "$A" ] && [ -n "$B" ] && [ "$A" -lt "$B" ] && ok \
    || bad "8: in bin/$F.sh the App helper (line ${A:-none}) must be asked before the PAT probe (line ${B:-none})"
done

# ══ 9. bin/merge-sweep.sh's token routing, driven verbatim ═════════════════
SWBLK=$(awk '/^# >>> sweep token routing$/{f=1;next} /^# <<< sweep token routing$/{exit} f' "$DIR/bin/merge-sweep.sh")
sweep() { # sweep <code> — the production block evaluated in a scratch $HARNESS
  ( export PATH="$T/fakebin:$PATH" HARNESS="$T" GH_APP_API_BASE=http://api.test \
           CURL_LOG="$T/curl.log" TOKSEQ="$T/tokseq" GH_SINK="$T/sweep-sink.txt" \
           ${SWEEPTOK:-GH_TOKEN=pattok}
    H="$T"; HENV="$T/env"; STAMP() { date -u '+%Y-%m-%d %H:%M:%SZ'; }   # determinism: ok the sweep's own stamp, compared to nothing
    # LOG matches the real script's own assignment (bin/merge-sweep.sh:
    # LOG="$H/logs/merge-sweep.log") — sweep_use_token_for's credential line
    # (BH-597, ticket item 2) writes to it, and it is not set by anything the
    # marker block itself carries.
    LOG="$T/logs/merge-sweep.log"
    eval "$SWBLK"
    eval "$1" ) 2>/dev/null
}
if [ -n "$SWBLK" ]; then
  : > "$T/logs/ALERTS.log"; : > "$T/sweep-sink.txt"; rm -f "$T"/flags/alerted-repo-invisible-merge-sweep-*
  OUT=$(sweep 'sweep_use_token_for TestOwner/widget; printf "rc=%s tok=%s id=%s" "$?" "${GH_TOKEN:-unset}" "${GH_LIMIT_IDENTITY:-unset}"')
  case "$OUT" in "rc=0 tok=ghs_fixture_"*" id=app:TestOwner/widget") ok ;;
    *) bad "9a: the sweep must run an armed repo on its App token, got '$OUT'" ;; esac
  [ ! -s "$T/logs/ALERTS.log" ] && ok || bad "9b: a minted token IS proof the repo is visible — nothing may page: $(cat "$T/logs/ALERTS.log")"
  # unarmed, and a repo nobody can see: the 2026-09-12 project-5 alert stands
  mv "$T/env/github-app.env" "$T/env/github-app.env.off"
  # A 404 is the invisible-repo shape BH-796 kept as rc 1. The stub answers
  # GitHub's own wording, because that classifier reads the HTTP status out of
  # gh's message and a bare rc 1 is "transient" (rc 2) on purpose.
  OUT=$(sweep 'sweep_use_token_for o/blind; printf "rc=%s" "$?"')
  [ "$OUT" = "rc=1" ] && ok || bad "9c: an invisible repo (404) must still rc 1, got '$OUT'"
  [ "$(grep -c 'INVISIBLE' "$T/logs/ALERTS.log")" = 1 ] && ok \
    || bad "9d: an invisible repo must page exactly once a day, got '$(cat "$T/logs/ALERTS.log")'"
  grep -qE 'ghs_fixture|pattok' "$T/logs/ALERTS.log" && bad "9e: a token value reached ALERTS.log: $(cat "$T/logs/ALERTS.log")" || ok
  OUT=$(sweep 'sweep_use_token_for TestOwner/widget; printf "rc=%s tok=%s id=%s" "$?" "${GH_TOKEN:-unset}" "${GH_LIMIT_IDENTITY:-unset}"')
  [ "$OUT" = "rc=0 tok=pattok id=pat:TestOwner/widget" ] && ok \
    || bad "9f: an unarmed sweep must behave exactly as it did on 2026-09-13, got '$OUT'"
  # THE PIN. A leftover installation token from the previous repo must never be
  # the token the next repo's visibility probe runs on.
  : > "$T/sweep-sink.txt"
  sweep 'export GH_TOKEN=ghs_leftover_from_repo_A; sweep_token_for TestOwner/flaky >/dev/null'
  [ "$(grep -c '^pattok api repos/TestOwner/flaky' "$T/sweep-sink.txt")" = 1 ] && ok \
    || bad "9g: the probe must be pinned to the sweep's own default token, got '$(cat "$T/sweep-sink.txt")'"
  grep -q '^ghs_leftover_from_repo_A ' "$T/sweep-sink.txt" \
    && bad "9h: the probe ran on the previous repo's installation token: $(cat "$T/sweep-sink.txt")" || ok
  mv "$T/env/github-app.env.off" "$T/env/github-app.env"
else
  bad "9: no '# >>> sweep token routing' block in bin/merge-sweep.sh — nothing to drive"
fi

# ══ 10. git's credential helper, RUN the way git runs it ═══════════════════
# The helper is not a file this ticket ships: it is the inline shell function
# bin/ensure-box-gh-app-default.sh writes into git's own config. So the only
# honest test is to read it back out of the config the ensure step wrote and
# execute it exactly as git does — `sh -c '<helper> "$@"' - get` with the
# request on stdin. A box whose keyring login is gone and whose helper does not
# answer cannot `git pull`, which is how bin/harness-sync.sh stops.
HELPER=$(git config --file "$GCFG" --get credential.https://github.com.helper 2>/dev/null)
if [ -n "${HELPER#!}" ] && [ "$HELPER" != "${HELPER#!}" ]; then
  # THE REQUEST GOES IN THROUGH A FILE, NOT A PIPE (BH-1250). git feeds the
  # helper on stdin, but the helper's store/erase arm exits without reading it —
  # by design, and git ignores SIGPIPE around its own write. This suite runs
  # under `set -o pipefail`, so when a pipe writer loses that race it dies of
  # SIGPIPE and 10c/10d report rc 141 instead of rc 0: 967 of 9600 iterations
  # red across 24 concurrent loops on this box, 0 of 9600 with the file form.
  # The shared test host runs a dozen suites at once, which is exactly that
  # load. A redirect from a file is identical input for 10a/10b, which do read.
  gitcred() { # gitcred <verb> <request lines...> — stdout of the inline helper
    local verb="$1"; shift
    printf '%s\n' "$@" '' > "$T/cred-req"
    env PATH="$T/fakebin:$PATH" HARNESS="$T" \
      GH_APP_API_BASE=http://api.test CURL_LOG="$T/curl.log" TOKSEQ="$T/tokseq" \
      ${CREDTOK:-GH_TOKEN=pattok} sh -c "${HELPER#!} \"\$@\"" - "$verb" 2>/dev/null < "$T/cred-req"
  }
  OUT=$(gitcred get protocol=https host=github.com path=TestOwner/widget.git)
  grep -q '^username=x-access-token$' <<<"$OUT" && grep -qE '^password=ghs_fixture_[0-9]+$' <<<"$OUT" \
    && ok || bad "10a: the helper must answer that repo's App token, got '$OUT'"
  OUT=$(gitcred get protocol=https host=github.com)
  grep -q '^password=pattok$' <<<"$OUT" && ok \
    || bad "10b: with no path at all the helper must fall back to GH_TOKEN, got '$OUT'"
  OUT=$(gitcred store protocol=https host=github.com path=TestOwner/widget.git; echo "rc=$?")
  [ "$OUT" = "rc=0" ] && ok || bad "10c: store must be silent and rc 0, got '$OUT'"
  OUT=$(gitcred erase protocol=https host=github.com path=TestOwner/widget.git; echo "rc=$?")
  [ "$OUT" = "rc=0" ] && ok || bad "10d: erase must be silent and rc 0, got '$OUT'"
else
  bad "10: bin/ensure-box-gh-app-default.sh wrote no inline credential helper into git's config — nothing to drive"
fi

# ══ 11. the two lanes RUN WHOLE, two repos, one mintable ═══════════════════
# Sections 1-9 drive functions and extracted blocks. This one runs the
# production entry points end to end: repo A can be minted for, repo B cannot,
# and the gh stub records the token every call actually went out on. A deleted
# call site in either lane goes red here.
L="$T/lane"; mkdir -p "$L/bin/lib" "$L/logs" "$L/flags" "$L/locks" "$L/state" "$L/env"
cp "$DIR/bin/main-red-detector.sh" "$DIR/bin/reconcile-prs.sh" "$DIR/bin/gh-token.sh" "$L/bin/"
cp "$DIR/bin/alert-line.sh" "$L/bin/"  # TEST-CHANGE: BH-2365 — converted writers call bin/alert-line.sh
cp "$DIR/bin/lib/gh-app-auth.sh" "$DIR/bin/lib/gh-repo-token.sh" "$DIR/bin/lib/gh-budget.sh" "$L/bin/lib/"
[ -r "$DIR/bin/lib/gh-limit-logger.sh" ] && cp "$DIR/bin/lib/gh-limit-logger.sh" "$L/bin/lib/"
chmod +x "$L/bin"/*.sh
cp "$T/env/github-app.env" "$T/env/github-app.pem" "$L/env/" 2>/dev/null
sed -i "s|$T/env/github-app.pem|$L/env/github-app.pem|" "$L/env/github-app.env"
printf 'GH_TOKEN=pattok\n' > "$L/env/global.env"
printf '#!/bin/bash\nexit 0\n' > "$L/bin/lane-alert.sh"; chmod +x "$L/bin/lane-alert.sh"
printf '#!/bin/bash\nexit 0\n' > "$L/bin/beat.sh"; chmod +x "$L/bin/beat.sh"
cp "$T/bin/fleet-conf.sh" "$L/bin/" 2>/dev/null
cp "$T/fleet.conf" "$L/" 2>/dev/null
# A gh stub that records "<GH_TOKEN> <args>" and answers the two lanes' reads.
cat > "$T/lanebin/gh" <<'SH'
#!/bin/bash
printf '%s %s\n' "${GH_TOKEN:-unset}" "$*" >> "$GH_SINK"
case "$*" in
  "api repos/"*" -q .id") exit 0 ;;
  *"actions/runs"*) printf '[]\n' ;;
  # BH-1295 REVIEW FIX (F1b follow-up, drain review): reconcile-prs.sh's
  # no-lib mc_pr_view fallback is REST now (`gh api repos/…/pulls/N -q
  # '{STATE:…}'`), never GraphQL — this arm answers that shape, matching
  # 11d's assertion below.
  "api repos/"*"/pulls/"*" -q "*) printf '{"STATE":"OPEN","closed_at":null,"merged_at":null,"merge_commit_sha":null}\n' ;;
  "pr view "*) printf 'OPEN \n' ;;
  *) printf '\n' ;;
esac
SH
chmod +x "$T/lanebin/gh"
: > "$T/lane-sink.txt"
# MINT_FAILS_FOR names the ONE repo whose mint fails, so repo B falls back to
# the PAT while repo A really mints — the two-repo case, through the lane.
cat > "$T/lanebin/curl" <<'SH'
#!/bin/bash
URL=""; BODY=""
while [ $# -gt 0 ]; do
  case "$1" in
    -H) shift 2 ;; -d) BODY="$2"; shift 2 ;; -X) shift 2 ;; -sS|-s|-S) shift ;;
    *) URL="$1"; shift ;;
  esac
done
case "$URL" in
  */app/installations) printf '[{"id":4242,"account":{"login":"TestOwner"}}]\n' ;;
  */access_tokens)
    case "$BODY" in *"\"${MINT_FAILS_FOR:-nothing-at-all}\""*) echo '{"message":"Bad credentials"}'; exit 0 ;; esac
    printf '{"token":"ghs_lane","expires_at":"%s"}\n' "$(date -u -d '+1 hour' '+%Y-%m-%dT%H:%M:%SZ')" ;;
  *) echo '{}' ;;
esac
SH
chmod +x "$T/lanebin/curl"
lane() { # lane <script> [args...] — a production lane, run whole
  ( export PATH="$T/lanebin:$PATH" HARNESS="$L" GH_APP_API_BASE=http://api.test \
           GH_SINK="$T/lane-sink.txt" MINT_FAILS_FOR=flaky FLEET_CONF="$L/fleet.conf" \
           MAIN_RED_REPOS="TestOwner/widget TestOwner/flaky" CONSOLE_URL=http://console.test \
           HARNESS_SECRET=s3cret
    "$L/bin/$1" "${@:2}" ) >/dev/null 2>&1
}
if command -v gh_default_auth_for_slug >/dev/null 2>&1 || grep -q gh_default_auth_for_slug "$DIR/bin/main-red-detector.sh"; then
  lane main-red-detector.sh
  [ "$(grep -c '^ghs_lane api .*repos/TestOwner/widget/actions/runs' "$T/lane-sink.txt")" -ge 1 ] && ok \
    || bad "11a: main-red-detector must read repo A's runs on its App token, got '$(cat "$T/lane-sink.txt")'"
  [ "$(grep -c '^pattok api .*repos/TestOwner/flaky/actions/runs' "$T/lane-sink.txt")" -ge 1 ] && ok \
    || bad "11b: a repo whose mint fails must be read on the PAT, never on repo A's token, got '$(cat "$T/lane-sink.txt")'"
  grep -q '^ghs_lane api .*repos/TestOwner/flaky/actions/runs' "$T/lane-sink.txt" \
    && bad "11c: repo B's read went out on repo A's installation token: $(cat "$T/lane-sink.txt")" || ok
  # reconcile-prs.sh derives the slug from the PR URL, so its read must be
  # armed for the repo in that URL.
  : > "$T/lane-sink.txt"
  cat > "$T/lanebin/curl-console" <<'SH'
#!/bin/bash
SH
  # The console answer is the lane's only input; a tiny wrapper serves it.
  cat > "$T/lanebin/curl" <<'SH'
#!/bin/bash
ARGS="$*"
case "$ARGS" in
  *"/api/builds/unmerged"*)
    printf '{"builds":[{"bkey":"k1","pr_url":"https://github.com/TestOwner/widget/pull/7"}]}\n'; exit 0 ;;
  *"/api/builds/reconcile"*) printf '{}\n'; exit 0 ;;
esac
URL=""; BODY=""
set -- $ARGS
while [ $# -gt 0 ]; do
  case "$1" in
    -H) shift 2 ;; -d) BODY="$2"; shift 2 ;; -X) shift 2 ;; -sS|-s|-S) shift ;;
    *) URL="$1"; shift ;;
  esac
done
case "$URL" in
  */app/installations) printf '[{"id":4242,"account":{"login":"TestOwner"}}]\n' ;;
  */access_tokens) printf '{"token":"ghs_lane","expires_at":"%s"}\n' "$(date -u -d '+1 hour' '+%Y-%m-%dT%H:%M:%SZ')" ;;
  *) echo '{}' ;;
esac
SH
  chmod +x "$T/lanebin/curl"
  # BH-1583: armed as the reconcile owner in a SUBSHELL, so the owner identity
  # it exports does not follow the sections below.
  . "$(dirname "$0")/lib/reconcile-fixture.sh" || exit 1
  ( rcfx_arm "$L" "$DIR" && lane reconcile-prs.sh )
  grep -q '^ghs_lane api repos/TestOwner/widget/pulls/7 -q' "$T/lane-sink.txt" && ok \
    || bad "11d: reconcile-prs must read the PR on that repo's App token, got '$(cat "$T/lane-sink.txt")'"
  # NEGATIVE, the one that matters: no token VALUE in any of the lanes' logs.
  grep -rqE 'ghs_lane|pattok' "$L/logs" 2>/dev/null \
    && bad "11e: a token value reached a lane log: $(grep -rlE 'ghs_lane|pattok' "$L/logs")" || ok
else
  bad "11: bin/main-red-detector.sh never names gh_default_auth_for_slug — the lanes are not wired"
fi

# == 12. --explain STILL pages for nothing, on the NEW arm too (BH-997) =====
# main's BH-997 made every --explain arm of the detector READ-ONLY: a dry run
# takes no lock, writes no flag, publishes no row and SENDS NO PAGE -- it prints
# WOULD lines instead. #469 puts a THIRD arm ABOVE the two it hardened
# (gh_default_auth_for_slug), and that new arm is the one that runs on every box
# once this lands. An arm that pages on an invisible repo would put the 997 bug
# back wholesale, and nothing else in tests/ drives the repo-invisible path with
# the App lib loaded. So: one repo no credential can see, the detector run WHOLE
# with --explain, and nothing may be written.
L2="$T/lane2"; mkdir -p "$L2/bin/lib" "$L2/logs" "$L2/flags" "$L2/locks" "$L2/state" "$L2/env" "$T/lanebin2"
cp "$DIR/bin/main-red-detector.sh" "$DIR/bin/gh-token.sh" "$L2/bin/"
cp "$DIR/bin/alert-line.sh" "$L2/bin/"  # TEST-CHANGE: BH-2365 — converted writers call bin/alert-line.sh
cp "$DIR/bin/lib/gh-app-auth.sh" "$DIR/bin/lib/gh-repo-token.sh" "$DIR/bin/lib/gh-budget.sh" "$L2/bin/lib/"
[ -r "$DIR/bin/lib/gh-limit-logger.sh" ] && cp "$DIR/bin/lib/gh-limit-logger.sh" "$L2/bin/lib/"
chmod +x "$L2/bin"/*.sh
cp "$T/env/github-app.env" "$T/env/github-app.pem" "$L2/env/" 2>/dev/null
sed -i "s|$T/env/github-app.pem|$L2/env/github-app.pem|" "$L2/env/github-app.env"
printf 'GH_TOKEN=pattok\n' > "$L2/env/global.env"
printf '#!/bin/bash\nexit 0\n' > "$L2/bin/beat.sh"; chmod +x "$L2/bin/beat.sh"
printf '#!/bin/bash\nexit 0\n' > "$L2/bin/lane-alert.sh"; chmod +x "$L2/bin/lane-alert.sh"
# Every visibility probe on this repo fails, so gh_default_auth_for_slug returns
# 1 and the detector takes its repo-invisible exit -- the one arm this ticket added.
cat > "$T/lanebin2/gh" <<'SH'
#!/bin/bash
case "$*" in
  *"repos/TestOwner/blind"*) exit 1 ;;
  *) printf '\n' ;;
esac
SH
chmod +x "$T/lanebin2/gh"
printf '#!/bin/bash\necho %s\n' "'{\"message\":\"Bad credentials\"}'" > "$T/lanebin2/curl"
chmod +x "$T/lanebin2/curl"
blindlane() { # blindlane [args...] -- the detector, whole, over one invisible repo
  ( export PATH="$T/lanebin2:$PATH" HARNESS="$L2" GH_APP_API_BASE=http://api.test \
           MAIN_RED_REPOS="TestOwner/blind" FLEET_CONF="$L2/fleet.conf"
    "$L2/bin/main-red-detector.sh" "$@" ) 2>/dev/null
}
OUT=$(blindlane --explain)
grep -q 'WOULD ALERT(repo-invisible) TestOwner/blind' <<<"$OUT" && ok \
  || bad "12a: --explain on an invisible repo must print the WOULD line, got '$OUT'"
[ -s "$L2/logs/ALERTS.log" ] \
  && bad "12b: --explain paged: $(cat "$L2/logs/ALERTS.log")" || ok
ls "$L2/flags"/alerted-repo-invisible-* >/dev/null 2>&1 \
  && bad "12c: --explain wrote the alert's dedup flag: $(ls "$L2/flags")" || ok
# THE CONTROL. A plain tick on the same repo still pages, so 12b and 12c cannot
# pass because the fixture never reaches the arm at all.
blindlane >/dev/null
[ -s "$L2/logs/ALERTS.log" ] && ok \
  || bad "12d: a plain tick on an invisible repo must still page -- 12b/12c prove nothing otherwise"

echo "gh-default-identity: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
