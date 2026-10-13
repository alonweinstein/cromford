#!/bin/bash
# tests/gh-default-auth-lanes-test.sh — the eleven per-project lanes default to
# the project's GitHub App installation token, and `bin/gh-token.sh --status`
# never prints `?/?`.
#
# THE WALL (#424, BH-470). One PAT is one 5000/h REST bucket for every lane on
# every box. bin/gh-token.sh mints a repo-scoped installation token instead, and
# #469 turns that into a one-line default for a lane: `gh_default_auth_for_project
# <project>` resolves the project's slug out of fleet.conf, arms GH_TOKEN with
# that repo's installation token and tags the identity for the rate-limit logger.
# This slice wires the eleven per-project lanes to that call. What matters is the
# VALUE of GH_TOKEN the lane (and every session or shard it launches, which
# inherits the environment) ends up with — so the wiring is DRIVEN, not grepped:
# each lane's `# >>> gh default auth` region is extracted VERBATIM from the
# shipped script and run in a scratch shell against a stubbed GitHub, and the
# assertions are on GH_TOKEN, GH_LIMIT_IDENTITY and the mint count. A regression
# in the real lines fails here.
#
# THE SHIM, STATED OUT LOUD. `gh_default_auth_for_project` is slice 1's (#469,
# PR #911) and is not on main yet. When the copied bin/lib/gh-app-auth.sh does
# not define it, this suite appends a stand-in with #469's documented contract to
# the SCRATCH COPY ONLY and says so on stdout. The stand-in is never the thing
# under test — the lanes are. bin/lib/gh-limit-logger.sh is always a stub that
# records it was sourced (the real wrapper's behaviour is slice 1's suite to
# prove; this one proves the lanes source that path fail-open).
#
# The `--status` half drives the REAL bin/gh-token.sh CLI against four
# /rate_limit bodies: the deprecated `.rate` object, today's `.resources.core`,
# an unauthenticated answer and an empty one.
# Run from anywhere: tests/gh-default-auth-lanes-test.sh   (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
unset GH_TOKEN GH_LIMIT_IDENTITY GH_APP_TOKENS GH_TOKEN_READ RL_BODY
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

command -v openssl >/dev/null 2>&1 || { echo "gh-default-auth-lanes: openssl missing — bin/gh-token.sh needs it, so this is a real skip"; exit 0; }
command -v jq      >/dev/null 2>&1 || { echo "gh-default-auth-lanes: jq missing — bin/gh-token.sh needs it, so this is a real skip"; exit 0; }

LANES="run-triage.sh run-build.sh run-product.sh review-prs.sh rebase-train.sh
       deploy-train.sh check-migration-prs.sh wake-loop.sh
       claude-auth-check.sh fly-pool.sh"

# ── the fixture ──────────────────────────────────────────────────────────────
mkdir -p "$T/regions" "$T/fakebin" "$T/env" "$T/empty"
openssl genrsa -out "$T/env/github-app.pem" 2048 2>/dev/null; chmod 600 "$T/env/github-app.pem"
printf 'widget TestOwner/widget https://widget.test - 2 box-a 100.0.0.1\n' > "$T/fleet.conf"

# The stand-in for #469's helper, appended to the SCRATCH copy of the lib only
# when this checkout predates it. Contract, from PR #911's header: reset to the
# process default first, then ask for the App token; a `ghs_*` answer is tagged
# `app:<slug>`, anything else `pat:<slug>`; rc 1 (env untouched) when fleet.conf
# has no row for the project or the row is not a slug.
cat > "$T/shim.sh" <<'SHIM'

# --- #469 stand-in, appended by tests/gh-default-auth-lanes-test.sh ----------
gh_default_auth_for_slug() {
  local slug="${1:-}"
  [ -n "$slug" ] || return 1
  case "$slug" in */*) ;; *) return 1 ;; esac
  gh_auth_reset
  if gh_auth_for "$slug"; then
    case "${GH_TOKEN:-}" in
      ghs_*) export GH_LIMIT_IDENTITY="app:$slug"; return 0 ;;
    esac
  fi
  command -v gh_repo_use_token >/dev/null 2>&1 && gh_repo_use_token "$slug" >/dev/null 2>&1
  case "${GH_TOKEN:-}" in
    ghs_*) export GH_LIMIT_IDENTITY="app:$slug" ;;
    *)     export GH_LIMIT_IDENTITY="pat:$slug" ;;
  esac
  return 0
}
gh_default_auth_for_project() {
  local p="${1:-}" slug
  [ -n "$p" ] || return 1
  slug=$("$_GHAA_H/bin/fleet-conf.sh" "$p" repo 2>/dev/null) || return 1
  [ -n "$slug" ] && [ "$slug" != "-" ] || return 1
  gh_default_auth_for_slug "$slug"
}
gh_default_auth_reset() {
  gh_auth_reset
  command -v gh_repo_token_reset >/dev/null 2>&1 && gh_repo_token_reset
  unset GH_LIMIT_IDENTITY
  return 0
}
SHIM
SHIMMED=no
grep -q 'gh_default_auth_for_project' "$DIR/bin/lib/gh-app-auth.sh" || SHIMMED=yes
[ "$SHIMMED" = yes ] && echo "gh-default-auth-lanes: bin/lib/gh-app-auth.sh does not define gh_default_auth_for_project (#469 is not on this checkout) — the scratch copy gets the stand-in from PR #911's contract; the LANES are what is under test."

mk_tree() { # mk_tree <dir> <yes|no: append the #469 stand-in>
  local d="$1" shim="$2"
  mkdir -p "$d/bin/lib" "$d/env" "$d/flags" "$d/logs" "$d/locks" "$d/state/gh-app-tokens"
  cp "$DIR/bin/gh-token.sh" "$DIR/bin/fleet-conf.sh" "$d/bin/"
  chmod +x "$d/bin/gh-token.sh" "$d/bin/fleet-conf.sh"
  cp "$DIR/bin/lib/gh-app-auth.sh" "$DIR/bin/lib/gh-repo-token.sh" \
     "$DIR/bin/lib/gh-budget.sh" "$DIR/bin/lib/env-path.sh" "$d/bin/lib/"
  printf 'GH_APP_ID=778899\nGH_APP_PRIVATE_KEY_FILE=%s/env/github-app.pem\n' "$T" > "$d/env/github-app.env"
  # The logger stub: slice 1 defines a `gh` wrapper here. All this slice claims
  # is that every lane SOURCES this path, fail-open.
  printf '#!/bin/bash\n# stub for tests/gh-default-auth-lanes-test.sh\n_GHLL_STUB_SOURCED=1\n' \
    > "$d/bin/lib/gh-limit-logger.sh"
  if [ "$shim" = yes ] && [ "$SHIMMED" = yes ]; then cat "$T/shim.sh" >> "$d/bin/lib/gh-app-auth.sh"; fi
}
mk_tree "$T" yes
mk_tree "$T/pre" no     # the pre-#469 lib: no default helper at all

# The stubbed GitHub. RL_BODY overrides the /rate_limit answer for the --status
# cases; TOKSEQ makes every mint a distinguishable value so a cache HIT and a
# fresh mint cannot be confused.
cat > "$T/fakebin/curl" <<'SH'
#!/bin/bash
URL=""; AUTH=""
while [ $# -gt 0 ]; do
  case "$1" in
    -H) case "$2" in Authorization:*) AUTH="${2#Authorization: }" ;; esac; shift 2 ;;
    -d|-X) shift 2 ;;
    -sS|-s|-S) shift ;;
    *) URL="$1"; shift ;;
  esac
done
case "$URL" in
  */app/installations) printf '[{"id":4242,"account":{"login":"TestOwner"}}]\n' ;;
  */access_tokens)
    N=$(( $(cat "$TOKSEQ" 2>/dev/null || echo 0) + 1 )); printf '%s' "$N" > "$TOKSEQ"
    printf '{"token":"ghs_fixture_%s","expires_at":"%s"}\n' "$N" "$(date -u -d '+1 hour' '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null || date -u -v+1H '+%Y-%m-%dT%H:%M:%SZ')" ;;  # determinism: ok an installation token's one-hour life IS the fixture
  */rate_limit)
    # A `ghs_bad_*` token is refused whatever RL_BODY says, so one --status run
    # can hold a good cache file and a dead one at the same time.
    case "$AUTH" in *ghs_bad*) printf '{"message":"Bad credentials"}\n'; exit 0 ;; esac
    if [ -n "${RL_BODY:-}" ]; then cat "$RL_BODY"; else printf '{"rate":{"remaining":4996,"limit":5000}}\n'; fi ;;
  *) echo '{}' ;;
esac
SH
chmod +x "$T/fakebin/curl"
cat > "$T/fakebin/gh" <<'SH'
#!/bin/bash
[ -n "${GH_CALL_LOG:-}" ] && printf '%s %s\n' "${GH_TOKEN:-<unset>}" "$*" >> "$GH_CALL_LOG"
case "$*" in
  api\ repos/*\ -q\ .id) exit 0 ;;
  "auth token") printf 'keyring-tok\n' ;;
  *) exit 1 ;;
esac
SH
chmod +x "$T/fakebin/gh"
printf '0' > "$T/tokseq"; : > "$T/gh.log"
mints() { cat "$T/tokseq"; }

# run-build.sh is read as the pipeline's ONE text (tests/lib/rb-all.sh): since
# the BH-572 cut its gh default auth region lives in a stage module under
# bin/lib/rb/, and the flatten puts it back where the driver calls it.
. "$DIR/tests/lib/rb-all.sh" || exit 1
RB_ALL=$(rb_all "$DIR" "$T/run-build.all.sh") || { echo "FAIL: rb_all could not flatten bin/run-build.sh"; exit 1; }
lane_text() { # lane_text <lane>  -> the file whose text is that lane
  if [ "$1" = run-build.sh ]; then printf '%s' "$RB_ALL"; else printf '%s' "$DIR/bin/$1"; fi
}

# ── the regions, extracted verbatim from the shipped lanes ───────────────────
for L in $LANES; do
  # Leading whitespace is allowed: a loop lane's second region sits inside the
  # `for`/`while` body it arms, and its markers are indented with it. The marker
  # name is anchored so the `gh default auth reset` pair below is a region of its
  # own and does not fold into the arming one.
  awk '/^[[:space:]]*# >>> (gh default auth|triage github auth)[[:space:]]*$/{f=1;next}
       /^[[:space:]]*# <<< (gh default auth|triage github auth)[[:space:]]*$/{f=0;next} f' \
    "$(lane_text "$L")" > "$T/regions/$L"
  # The arming regions PLUS the reset, for the three lanes that arm per row and
  # must not leak that row's identity into what they launch next.
  { cat "$T/regions/$L"
    awk '/^[[:space:]]*# >>> gh default auth reset[[:space:]]*$/{f=1;next}
         /^[[:space:]]*# <<< gh default auth reset[[:space:]]*$/{f=0;next} f' "$(lane_text "$L")"
  } > "$T/regions/$L.reset"
done

# drive <lane> — run that lane's marked region(s) as the lane would, and print
# "<GH_TOKEN>|<GH_LIMIT_IDENTITY>|<logger sourced>". DRIVE_HARNESS points the
# lane at a different tree (the pre-#469 lib, or a box with no libs at all).
drive() {
  local lane="$1" hr="${DRIVE_HARNESS:-$T}"
  env PATH="$T/fakebin:$PATH" \
      HARNESS="$hr" H="$hr" SELF="$hr/bin" HENV="$hr/env" \
      FLEET_CONF="$T/fleet.conf" GH_APP_API_BASE="http://api.test" \
      TOKSEQ="$T/tokseq" GH_CALL_LOG="$T/gh.log" \
      PROJECT=widget P=widget p=widget SLUG=TestOwner/widget \
      GH_AUTH_SLUG=TestOwner/widget URL="https://github.com/TestOwner/widget/pull/1" \
      REPO="$T/norepo" LOG="$T/logs/$lane.log" _AUTH_CHECK_LIB_ONLY=0 \
      GH_TOKEN=pattok \
      bash -c 'set -uo pipefail; . "$1"
               printf "%s|%s|%s" "${GH_TOKEN:-<unset>}" "${GH_LIMIT_IDENTITY:-<unset>}" "${_GHLL_STUB_SOURCED:-0}"' \
      _ "$T/regions/$lane" 2>/dev/null
}

# ══ 1-2. every lane: the region exists, arms the cached App token, tags the
#         identity, and sourced the rate-limit logger ═══════════════════════════
for L in $LANES; do
  if [ -s "$T/regions/$L" ]; then ok; else bad "bin/$L carries no '# >>> gh default auth' region"; fi
  if grep -q 'gh_default_auth_for' "$T/regions/$L"; then ok
  else bad "bin/$L's marked region does not call gh_default_auth_for_project"; fi
done
CACHED=""
for L in $LANES; do
  OUT=$(drive "$L")
  TOK=${OUT%%|*}; REST=${OUT#*|}; IDENT=${REST%%|*}; LOGGED=${REST#*|}
  [ -z "$CACHED" ] && CACHED=$(jq -r '.token // empty' "$T/state/gh-app-tokens/TestOwner-widget.json" 2>/dev/null)
  case "$TOK" in
    ghs_fixture_*) [ "$TOK" = "$CACHED" ] && ok || bad "$L: GH_TOKEN ($TOK) is not the cached App token ($CACHED)" ;;
    *) bad "$L: armed → GH_TOKEN must be the minted App token, got '$TOK'" ;;
  esac
  [ "$IDENT" = "app:TestOwner/widget" ] && ok || bad "$L: GH_LIMIT_IDENTITY must be app:TestOwner/widget, got '$IDENT'"
  [ "$LOGGED" = 1 ] && ok || bad "$L: bin/lib/gh-limit-logger.sh was not sourced"
done

# ══ 3. one mint for all eleven lanes — every lane reads the shared cache ═════
[ "$(mints)" = 1 ] && ok || bad "eleven lanes must buy exactly ONE installation token, got $(mints) mints"

# ══ 4. unarmed box: the lane's own token, untouched, and no mint ════════════
touch "$T/flags/gh-app-tokens-off"
BEFORE=$(mints)
for L in $LANES; do
  OUT=$(drive "$L"); TOK=${OUT%%|*}
  [ "$TOK" = pattok ] && ok || bad "$L: flags/gh-app-tokens-off must leave GH_TOKEN as it was, got '$TOK'"
done
[ "$(mints)" = "$BEFORE" ] && ok || bad "an unarmed box must not mint (mints went $BEFORE → $(mints))"
rm -f "$T/flags/gh-app-tokens-off"

# ══ 5. fail-open: a box whose bin/lib/ has neither library ══════════════════
DRIVE_HARNESS="$T/empty"
for L in $LANES; do
  OUT=$(drive "$L"); RC=$?
  TOK=${OUT%%|*}
  [ "$RC" = 0 ] && [ "$TOK" = pattok ] && ok \
    || bad "$L: with no libraries on the box the region must exit 0 and leave GH_TOKEN alone (rc $RC, token '$TOK')"
done

# ══ 6. run-build's fallback: a pre-#469 lib still arms through gh_auth_for ══
DRIVE_HARNESS="$T/pre"
OUT=$(drive run-build.sh); TOK=${OUT%%|*}
DRIVE_HARNESS="$T"
case "$TOK" in
  ghs_fixture_*) ok ;;
  *) bad "run-build.sh must still arm via gh_auth_for \"\$GH_AUTH_SLUG\" on a pre-#469 lib, got '$TOK'" ;;
esac

# ══ 6b. the two per-row lanes put the process default BACK ═════════════════
# wake-loop launches other lanes and claude-auth-check runs a PAT-only canary
# after this point; a row's installation token that outlived its row would be
# inherited as "the default" by whatever comes next. (BH-1366 retired the third,
# bin/tier2-merge-sweep.sh, with its lane.)
for L in wake-loop.sh claude-auth-check.sh; do
  [ -s "$T/regions/$L.reset" ] || { bad "bin/$L carries no '# >>> gh default auth reset' region"; continue; }
  ok
  OUT=$(env PATH="$T/fakebin:$PATH" HARNESS="$T" H="$T" SELF="$T/bin" HENV="$T/env" \
        FLEET_CONF="$T/fleet.conf" GH_APP_API_BASE="http://api.test" TOKSEQ="$T/tokseq" \
        PROJECT=widget P=widget p=widget SLUG=TestOwner/widget GH_AUTH_SLUG=TestOwner/widget \
        URL="https://github.com/TestOwner/widget/pull/1" REPO="$T/norepo" \
        LOG="$T/logs/$L.log" _AUTH_CHECK_LIB_ONLY=0 GH_TOKEN=pattok \
        bash -c 'set -uo pipefail; . "$1"
                 printf "%s|%s" "${GH_TOKEN:-<unset>}" "${GH_LIMIT_IDENTITY:-<unset>}"' \
        _ "$T/regions/$L.reset" 2>/dev/null)
  [ "$OUT" = "pattok|<unset>" ] && ok \
    || bad "$L: after its reset the process default must be back (wanted 'pattok|<unset>', got '$OUT')"
done

# ══ 7. no token value in any log this fixture wrote ═════════════════════════
if grep -rq 'ghs_fixture' "$T/logs" 2>/dev/null; then bad "a token VALUE reached a log under logs/"; else ok; fi

# ══ 8-12. bin/gh-token.sh --status, the real CLI, four /rate_limit bodies ═══
mkdir -p "$T/st/state/gh-app-tokens" "$T/st/env" "$T/st/logs"
printf '{"repo":"TestOwner/widget","token":"ghs_fixture_1","expires_at":"2099-01-01T00:00:00Z"}' \
  > "$T/st/state/gh-app-tokens/TestOwner-widget.json"
printf '{"rate":{"remaining":4996,"limit":5000}}\n'                  > "$T/st/rate.json"
printf '{"resources":{"core":{"remaining":4996,"limit":5000}}}\n'    > "$T/st/core.json"
printf '{"message":"Bad credentials"}\n'                             > "$T/st/unauth.json"
: > "$T/st/empty.json"
status() { # status <body-file> ; stdout on fd 1, stderr captured to $T/st/err.txt
  env PATH="$T/fakebin:$PATH" HARNESS="$T/st" HARNESS_ENV_DIR="$T/st/env" \
      GH_APP_API_BASE="http://api.test" RL_BODY="$1" GH_TOKEN=pattok \
      "$T/bin/gh-token.sh" --status 2>"$T/st/err.txt"
}
ALL_STATUS=""
S=$(status "$T/st/rate.json"); ALL_STATUS="$ALL_STATUS$S"
grep -q 'TestOwner/widget remaining=4996/5000 expires_at=2099-01-01T00:00:00Z' <<<"$S" \
  && ok || bad "--status with a .rate body: '$S'"
# SPEC CHANGE (BH-426): --status now reports one row per TOKEN, not per cache
# file — this fixture exports GH_TOKEN=pattok, so a `pat:default` row is part of
# the correct answer. What this case is about is the APP rows, so it counts those.
[ "$(grep -c '^TestOwner/' <<<"$S")" = 1 ] && ok || bad "--status must print one line per cache file, got: '$S'"

S=$(status "$T/st/core.json"); ALL_STATUS="$ALL_STATUS$S"
grep -q 'TestOwner/widget remaining=4996/5000 expires_at=2099-01-01T00:00:00Z' <<<"$S" \
  && ok || bad "--status with a .resources.core body must report 4996/5000, got: '$S'"

S=$(status "$T/st/unauth.json"); ALL_STATUS="$ALL_STATUS$S"; ERR=$(cat "$T/st/err.txt")
grep -q 'TestOwner/widget remaining=0/0 expires_at=' <<<"$S" \
  && ok || bad "--status on an unauthenticated body must report 0/0, got: '$S'"
[ -n "$ERR" ] && grep -q '0/0' <<<"$ERR" \
  && ok || bad "--status on an unauthenticated body must say so once on stderr, got: '$ERR'"

S=$(status "$T/st/empty.json"); ALL_STATUS="$ALL_STATUS$S"
grep -q 'TestOwner/widget remaining=0/0 expires_at=' <<<"$S" \
  && ok || bad "--status on an empty body must report 0/0, got: '$S'"

grep -q '?/?' <<<"$ALL_STATUS" && bad "--status printed '?/?' — it must report 0/0 with a note instead" || ok
grep -q 'ghs_fixture' <<<"$ALL_STATUS$(cat "$T/st/err.txt")" && bad "--status printed a token value" || ok

# ══ 12b. two cache files, one dead: each line reports ITS OWN answer ════════
# The shape on a real box is several cache files in one run, and `read` into the
# same two variables per iteration is exactly where a previous file's numbers
# would be reported for a file that answered nothing.
printf '{"repo":"TestOwner/zombie","token":"ghs_bad_1","expires_at":"2099-01-01T00:00:00Z"}' \
  > "$T/st/state/gh-app-tokens/TestOwner-zombie.json"
S=$(status "$T/st/rate.json"); ERR=$(cat "$T/st/err.txt")
# SPEC CHANGE (BH-426), same as case 8: the App rows are what this case is
# about, and the PAT row beside them is the new spec, not a regression.
[ "$(grep -c '^TestOwner/' <<<"$S")" = 2 ] && ok || bad "--status must print one line per cache file (2 expected), got: '$S'"
grep -q '^TestOwner/widget remaining=4996/5000 ' <<<"$S" && ok || bad "the live cache file's own numbers: '$S'"
grep -q '^TestOwner/zombie remaining=0/0 ' <<<"$S" && ok \
  || bad "a refused token must report 0/0, not the previous file's numbers: '$S'"
grep -q 'TestOwner/zombie' <<<"$ERR" && ! grep -q 'TestOwner/widget' <<<"$ERR" && ok \
  || bad "the stderr note must name only the file that failed, got: '$ERR'"
grep -q '?/?' <<<"$S" && bad "--status printed '?/?' for a multi-file run" || ok

# ══ 13. the ticket's own grep: every lane names the helper ═════════════════
# TEN since BH-1366 retired bin/tier2-merge-sweep.sh with its lane. The count is
# derived from $LANES rather than typed, so the next retirement or addition does
# not leave a number here that nothing recomputes.
N=0; NL=0
for L in $LANES; do NL=$((NL+1)); grep -q 'gh_default_auth_for' "$(lane_text "$L")" && N=$((N+1)); done
[ "$NL" -gt 0 ] && [ "$N" = "$NL" ] && ok || bad "grep -l gh_default_auth_for over the $NL lanes must find $NL, found $N"

echo "gh-default-auth-lanes-test: $PASS pass, $FAIL fail"
[ "$FAIL" = 0 ]
