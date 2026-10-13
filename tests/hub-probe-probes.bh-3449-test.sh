#!/bin/bash
# tests/hub-probe-probes.bh-3449-test.sh — the four hub-probe probe bodies
# (BH-3449, BH-3434.2): bin/lib/hub-probes/app-status-write.sh,
# app-permissions.sh, app-installation-repos.sh and d1-count.sh. Every case goes
# through the REAL hp_run in bin/lib/hub-probes/common.sh, after sourcing the
# REAL bin/jobs-client.sh from a scratch harness copy. gh_rest,
# gh_app_only_for/gh_app_only_release and _jobs_req are stubbed after that
# source; each appends to a call log.
#   S1-S9  app-status-write: PASS only on the newest hub-probe entry with
#          state success AND creator.type Bot; App token or no call at all;
#          the token is released on every path it was taken
#   P1-P4  app-permissions
#   R1-R5  app-installation-repos, including the D12 incomplete line
#   D1-D3  d1-count through the real hp_d1_count
#   X1-X3  no token on stdout, no graphql and no /root/harness in hub-probes/
# Run from anywhere: tests/hub-probe-probes.bh-3449-test.sh  (exit 0 = pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null 2>&1 || { echo "FAIL: jq is required"; exit 1; }

for f in "$DIR/bin/lib/hub-probes/app-status-write.sh" "$DIR/bin/lib/hub-probes/app-permissions.sh" \
         "$DIR/bin/lib/hub-probes/app-installation-repos.sh" "$DIR/bin/lib/hub-probes/d1-count.sh"; do
  [ -f "$f" ] && bash -n "$f" 2>/dev/null && ok || bad "missing or unparseable $f"
done

H="$T/h"
mkdir -p "$H/bin/lib/jobs" "$H/bin/lib/hub-probes" "$H/logs" "$T/fakebin"
cp "$DIR/bin/jobs-client.sh" "$H/bin/" && cp "$DIR"/bin/lib/*.sh "$H/bin/lib/" 2>/dev/null
cp "$DIR"/bin/lib/jobs/*.sh "$H/bin/lib/jobs/"
cp "$DIR"/bin/lib/hub-probes/*.sh "$H/bin/lib/hub-probes/" 2>/dev/null
printf '#!/bin/bash\necho "curl $*" >> "$CALLS"\nexit 7\n' > "$T/fakebin/curl"
chmod +x "$T/fakebin/curl"
CALLS="$T/calls.log"; SCRIPT="$T/script"; ALLOUT="$T/all-stdout"
: > "$ALLOUT"; : > "$T/all-calls"; : > "$T/s7"
export CALLS SCRIPT H

# The script file holds one line per gh_rest call, in order: `<rc> <status> <body>`.
# APP holds gh_app_only_for's rc. JANS/JRC are _jobs_req's answer and rc.
STUBS='
_n=0
gh_rest() {
  echo "gh_rest $*" >> "$CALLS"
  _n=$((_n+1))
  local line rc st body
  line=$(sed -n "${_n}p" "$SCRIPT")
  rc=${line%% *}; line=${line#* }; st=${line%% *}; body=${line#* }
  GH_REST_STATUS=$st; GH_REST_REASON=
  [ -n "$body" ] && [ "$body" != - ] && printf "%s\n" "$body"
  return "${rc:-75}"
}
gh_app_only_for() {
  echo "gh_app_only_for $*" >> "$CALLS"
  [ "${APP:-0}" = 0 ] || return 1
  export GH_TOKEN=ghs_FAKE
  return 0
}
gh_app_only_release() { echo "gh_app_only_release" >> "$CALLS"; export GH_TOKEN=prior; return 0; }
_jobs_req() { printf "_jobs_req %s %s\n" "$1" "$2" >> "$CALLS"; [ "${JRC:-0}" = 0 ] || return 1; printf "%s" "$JANS"; }
'
export STUBS

# run <script lines...> -- <hp_run args...>. stdout -> $T/out, rc -> $T/vrc,
# HP_HTTP_STATUS -> $T/st, GH_TOKEN after the probe -> $T/tok.
run() {
  : > "$CALLS"; : > "$SCRIPT"
  while [ $# -gt 0 ] && [ "$1" != -- ]; do printf '%s\n' "$1" >> "$SCRIPT"; shift; done
  shift
  PATH="$T/fakebin:$PATH" HARNESS="$H" JOBS_URL="" HARNESS_SECRET="" GH_TOKEN=prior ST="$T/st" TOK="$T/tok" bash -c '
    . "$H/bin/jobs-client.sh" >/dev/null 2>&1 || exit 99
    eval "$STUBS"
    . "$H/bin/lib/hub-probes/common.sh" || exit 98
    HP_HTTP_STATUS=unset
    hp_run "$@"; rc=$?
    printf "%s" "$HP_HTTP_STATUS" > "$ST"
    printf "%s" "${GH_TOKEN-UNSET}" > "$TOK"
    exit $rc' _ "$@" > "$T/out" 2>/dev/null
  echo $? > "$T/vrc"
  cat "$T/out" >> "$ALLOUT"
  cat "$CALLS" >> "$T/all-calls"
  # S7: a token taken is a token released, exactly once, on every path
  if grep -q '^gh_app_only_for' "$CALLS" && [ "${APP:-0}" = 0 ]; then
    [ "$(grep -c '^gh_app_only_release$' "$CALLS")" = 1 ] && [ "$(cat "$T/tok")" = prior ] || echo "$*" >> "$T/s7"
  fi
}
out()   { cat "$T/out"; }
vrc()   { cat "$T/vrc"; }
st()    { cat "$T/st"; }
calls() { tr '\n' '|' < "$CALLS"; }
has()   { grep -qxF -- "$1" "$T/out"; }
nrest() { grep -c '^gh_rest ' "$CALLS"; }
nrel()  { grep -c '^gh_app_only_release$' "$CALLS"; }

REPO=example-org/cromford
SHA=0123456789abcdef0123456789abcdef01234567
OKPOST='0 201 {"id":1,"context":"hub-probe","state":"success"}'
st1() { printf '0 200 [{"context":"hub-probe","state":"%s","creator":{"type":"%s"}}]' "$1" "$2"; }

# --- app-status-write --------------------------------------------------------
# S1
run "$OKPOST" "$(st1 success Bot)" -- app-status-write "$REPO" "$SHA"
[ "$(vrc)" = 0 ] && has state=success && has creator.type=Bot && [ "$(st)" = 200 ] && ok \
  || bad "S1 success+Bot rc=$(vrc) st=$(st) out=$(out)"
[ "$(nrest)" = 2 ] && grep -q "^gh_rest GET repos/$REPO/commits/$SHA/statuses" "$CALLS" \
  && grep -q "^gh_rest POST repos/$REPO/statuses/$SHA " "$CALLS" && ok || bad "S1 calls: $(calls)"
[ "$(head -1 "$CALLS")" = "gh_app_only_for $REPO" ] && ok || bad "S1 app token first: $(calls)"
# POST, release, then read back — the read never runs under the App token
[ "$(sed -n '2,4p' "$CALLS" | cut -d' ' -f1-2 | tr '\n' '|')" = "gh_rest POST|gh_app_only_release|gh_rest GET|" ] \
  && ok || bad "S1 order: $(calls)"
[ "$(nrel)" = 1 ] && [ "$(cat "$T/tok")" = prior ] && ok || bad "S7(S1) release=$(nrel) tok=$(cat "$T/tok")"

# S2: POST 403
run '75 403 {"message":"Resource not accessible by integration"}' -- app-status-write "$REPO" "$SHA"
[ "$(vrc)" = 1 ] && has 'HTTP 403' && has 'FAIL unverifiable' && [ "$(st)" = 403 ] && [ "$(nrest)" = 1 ] && ok \
  || bad "S2 POST 403 rc=$(vrc) st=$(st) out=$(out) calls=$(calls)"
[ "$(nrel)" = 1 ] && [ "$(cat "$T/tok")" = prior ] && ok || bad "S7(S2) release on a failed POST: $(calls)"
# POST 404
run '44 404 {"message":"Not Found"}' -- app-status-write "$REPO" "$SHA"
[ "$(vrc)" = 1 ] && has 'HTTP 404' && has 'FAIL post-rejected' && [ "$(nrest)" = 1 ] && [ "$(nrel)" = 1 ] && ok \
  || bad "S2 POST 404 rc=$(vrc) out=$(out) calls=$(calls)"

# S3: creator User
run "$OKPOST" "$(st1 success User)" -- app-status-write "$REPO" "$SHA"
[ "$(vrc)" = 1 ] && has creator.type=User && [ "$(nrel)" = 1 ] && ok || bad "S3 User creator rc=$(vrc) out=$(out)"
# pending with a Bot creator
run "$OKPOST" "$(st1 pending Bot)" -- app-status-write "$REPO" "$SHA"
[ "$(vrc)" = 1 ] && has state=pending && ok || bad "S3 pending+Bot rc=$(vrc) out=$(out)"

# S4: no App token -> no call at all
APP=1 run "$OKPOST" "$(st1 success Bot)" -- app-status-write "$REPO" "$SHA"
[ "$(vrc)" = 1 ] && [ "$(out)" = 'FAIL app-token-unavailable' ] && [ "$(nrest)" = 0 ] && [ "$(st)" = 000 ] && ok \
  || bad "S4 no token rc=$(vrc) st=$(st) out=$(out) calls=$(calls)"
export APP=0

# S6: POST 201, read-back 75
run "$OKPOST" '75 000 -' -- app-status-write "$REPO" "$SHA"
[ "$(vrc)" = 1 ] && has 'FAIL unverifiable' && has 'HTTP 000' && [ "$(st)" = 000 ] && ok || bad "S6 read-back 75 rc=$(vrc) out=$(out)"
[ "$(nrel)" = 1 ] && ok || bad "S7(S6) release: $(calls)"
# read-back 404
run "$OKPOST" '44 404 -' -- app-status-write "$REPO" "$SHA"
[ "$(vrc)" = 1 ] && has 'FAIL not-found' && ok || bad "S6 read-back 404 rc=$(vrc) out=$(out)"
# read-back not JSON
run "$OKPOST" '0 200 <html>' -- app-status-write "$REPO" "$SHA"
[ "$(vrc)" = 1 ] && has 'FAIL unparseable' && ok || bad "S6 read-back garbage rc=$(vrc) out=$(out)"

# S8: no creator key; creator null
run "$OKPOST" '0 200 [{"context":"hub-probe","state":"success"}]' -- app-status-write "$REPO" "$SHA"
[ "$(vrc)" = 1 ] && has creator.type=none && has state=success && ok || bad "S8 no creator rc=$(vrc) out=$(out)"
run "$OKPOST" '0 200 [{"context":"hub-probe","state":"success","creator":null}]' -- app-status-write "$REPO" "$SHA"
[ "$(vrc)" = 1 ] && has creator.type=none && ok || bad "S8 null creator rc=$(vrc) out=$(out)"

# S9: newest hub-probe entry wins; another context never counts
run "$OKPOST" '0 200 [{"context":"hub-probe","state":"failure","creator":{"type":"Bot"}},{"context":"hub-probe","state":"success","creator":{"type":"Bot"}}]' \
  -- app-status-write "$REPO" "$SHA"
[ "$(vrc)" = 1 ] && has state=failure && ok || bad "S9 newest failure masked rc=$(vrc) out=$(out)"
run "$OKPOST" '0 200 [{"context":"lead-verdict","state":"success","creator":{"type":"Bot"}}]' -- app-status-write "$REPO" "$SHA"
[ "$(vrc)" = 1 ] && has state=none && has creator.type=none && ok || bad "S9 lead-verdict counted rc=$(vrc) out=$(out)"
run "$OKPOST" '0 200 [{"context":"lead-verdict","state":"failure","creator":{"type":"User"}},{"context":"hub-probe","state":"success","creator":{"type":"Bot"}}]' \
  -- app-status-write "$REPO" "$SHA"
[ "$(vrc)" = 0 ] && ok || bad "S9 hub-probe behind a newer lead-verdict rc=$(vrc) out=$(out)"

# S5: every POST names context=hub-probe, none names lead-verdict
grep '^gh_rest POST' "$T/all-calls" > "$T/posts"
[ -s "$T/posts" ] && ! grep -qv -- '-f context=hub-probe' "$T/posts" && ! grep -q lead-verdict "$T/posts" \
  && grep -q -- '-f state=success' "$T/posts" && ok || bad "S5 POST argv: $(tr '\n' '|' < "$T/posts")"

# --- app-permissions -----------------------------------------------------------
run '0 200 {"slug":"x","permissions":{"statuses":"write","metadata":"read"}}' -- app-permissions my-app
[ "$(vrc)" = 0 ] && has statuses=write && has metadata=read && [ "$(st)" = 200 ] && ok || bad "P1 rc=$(vrc) st=$(st) out=$(out)"
[ "$(calls)" = "gh_rest GET apps/my-app|" ] && ok || bad "P1 calls: $(calls)"
run '44 404 -' -- app-permissions my-app
[ "$(vrc)" = 1 ] && has 'HTTP 404' && has 'FAIL not-found' && [ "$(st)" = 404 ] && ok || bad "P2 rc=$(vrc) out=$(out)"
run '75 403 {"message":"rate limit"}' -- app-permissions my-app
[ "$(vrc)" = 1 ] && has 'HTTP 403' && has 'FAIL unverifiable' && [ "$(st)" = 403 ] && ok || bad "P3 rc=$(vrc) out=$(out)"
run '0 200 {"name":"x"}' -- app-permissions my-app
[ "$(vrc)" = 1 ] && has 'FAIL no-permissions' && ok || bad "P4 rc=$(vrc) out=$(out)"
run '0 200 <html>' -- app-permissions my-app
[ "$(vrc)" = 1 ] && has 'FAIL no-permissions' && ok || bad "P4 garbage rc=$(vrc) out=$(out)"

# --- app-installation-repos ----------------------------------------------------
run '0 200 {"total_count":2,"repositories":[{"full_name":"a/b"},{"full_name":"c/d"}]}' -- app-installation-repos
[ "$(vrc)" = 0 ] && [ "$(out)" = "$(printf 'a/b\nc/d\ntotal_count=2')" ] && [ "$(st)" = 200 ] && ok || bad "R1 rc=$(vrc) out=$(out)"
[ "$(head -1 "$CALLS")" = "gh_app_only_for $REPO" ] && ok || bad "R1 default mint repo: $(calls)"
# R4
[ "$(calls)" = "gh_app_only_for $REPO|gh_rest GET installation/repositories?per_page=100|gh_app_only_release|" ] \
  && [ "$(cat "$T/tok")" = prior ] && ok || bad "R4 calls: $(calls)"
# R2: 100 of 150
R2=$(jq -nc '{total_count:150, repositories:[range(100)|{full_name:"o/r\(.)"}]}')
run "0 200 $R2" -- app-installation-repos
[ "$(vrc)" = 0 ] && has 'incomplete: 100 of 150' && has total_count=150 && [ "$(grep -c '^o/r' "$T/out")" = 100 ] && ok \
  || bad "R2 rc=$(vrc) tail=$(tail -2 "$T/out")"
R2=$(jq -nc '{total_count:100, repositories:[range(100)|{full_name:"o/r\(.)"}]}')
run "0 200 $R2" -- app-installation-repos
[ "$(vrc)" = 0 ] && ! grep -q incomplete "$T/out" && ok || bad "R2 exact 100 must not be incomplete"
# R3
APP=1 run '0 200 {"total_count":0,"repositories":[]}' -- app-installation-repos
[ "$(vrc)" = 1 ] && [ "$(out)" = 'FAIL app-token-unavailable' ] && [ "$(nrest)" = 0 ] && [ "$(st)" = 000 ] && ok \
  || bad "R3 rc=$(vrc) out=$(out) calls=$(calls)"
# R5
run '75 403 {"message":"nope"}' -- app-installation-repos
[ "$(vrc)" = 1 ] && has 'HTTP 403' && has 'FAIL unverifiable' && [ "$(nrel)" = 1 ] && ok || bad "R5 403 rc=$(vrc) out=$(out)"
run '44 404 -' -- app-installation-repos
[ "$(vrc)" = 1 ] && has 'FAIL not-found' && [ "$(nrel)" = 1 ] && ok || bad "R5 404 rc=$(vrc) out=$(out)"
run '0 200 {"repositories":"x"}' -- app-installation-repos
[ "$(vrc)" = 1 ] && has 'FAIL unparseable' && ok || bad "R5 unparseable rc=$(vrc) out=$(out)"
# the mint repo reads HARNESS_REPO when it is a slug, never when it is a path
HARNESS_REPO=o/x run '0 200 {"total_count":0,"repositories":[]}' -- app-installation-repos
[ "$(head -1 "$CALLS")" = "gh_app_only_for o/x" ] && ok || bad "R5 HARNESS_REPO slug: $(calls)"
HARNESS_REPO=/root/harness-checkout run '0 200 {"total_count":0,"repositories":[]}' -- app-installation-repos
[ "$(head -1 "$CALLS")" = "gh_app_only_for $REPO" ] && ok || bad "R5 HARNESS_REPO path: $(calls)"

# --- d1-count -------------------------------------------------------------------
JANS='{"count":7}' run -- d1-count jobs all
[ "$(vrc)" = 0 ] && [ "$(out)" = count=7 ] && [ "$(st)" = 200 ] && ok || bad "D1 rc=$(vrc) st=$(st) out=$(out)"
[ "$(calls)" = "_jobs_req GET /api/hub-probe/count?table=jobs&template=all|" ] && ok || bad "D1 calls: $(calls)"
JANS='{"count":7}' JRC=1 run -- d1-count jobs all
[ "$(vrc)" = 1 ] && [ "$(out)" = 'FAIL worker-unavailable' ] && [ "$(st)" = 000 ] && ok || bad "D2 rc=$(vrc) out=$(out)"
JANS='{"count":"7"}' run -- d1-count ledgers last-24h
[ "$(vrc)" = 1 ] && [ "$(out)" = 'FAIL worker-unavailable' ] && ok || bad "D3 rc=$(vrc) out=$(out)"

# S7 over every case above that took a token
[ -s "$T/all-calls" ] && [ ! -s "$T/s7" ] && ok || bad "S7 token not released exactly once: $(tr '\n' '|' < "$T/s7")"

# --- X1-X3 ------------------------------------------------------------------------
[ -s "$ALLOUT" ] && ! grep -qE 'ghs_|ghp_|github_pat_' "$ALLOUT" && ok || bad "X1 a token reached stdout"
[ -z "$(grep -rn graphql "$DIR/bin/lib/hub-probes")" ] && ok || bad "X2 graphql in hub-probes/"
[ -z "$(grep -rn '/root/harness' "$DIR/bin/lib/hub-probes")" ] && ok || bad "X3 /root/harness literal in hub-probes/"

echo "hub-probe-probes.bh-3449: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
