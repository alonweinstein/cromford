#!/bin/bash
# tests/tracker-linear-context-test.sh — a project an admin moved to Linear
# (settings row tracker_adapter.<project> = linear) loads its Linear context
# from its own env file and settings rows, is gated on Linear's own thread, and
# is refused by the lanes that would otherwise write to GitHub issue #<n>.
#
#   X1  context: LINEAR_API_KEY from the project's env file, the team row
#   X2  the key only counts in the project's own env file
#   X3  rows: team is required and shaped, label and states are optional and
#       checked, a settings outage fails the context, a failed context is blank
#   X4  bin/triage-gate.sh --buildable[-strict] reads the Linear thread
#   X5  a key outside the team, and an issue Linear moved to another team, are
#       unreadable; a context that does not load is BLOCKED token-unresolved
#   X6  no LINEAR_API_KEY costs no settings call; a non-linear row no Linear call
#   X7  tracker_off_github: only a jira or linear row on the project
#   X8  bin/run-build.sh refuses a Jira project before it creates anything,
#       launched bare (the worker's URL and secret only in global.env)
#   X9  bin/board-closeout.sh and bin/needs-human-hold.sh post nothing to GitHub
#
# No network. A `curl` stub plays api.linear.app/graphql from
# tests/fixtures/tracker-linear-context/ and the jobs worker's settings route.
# It never writes its argv, which is where the key rides.
#   HARNESS_TEST_SANDBOX=1 bash tests/tracker-linear-context-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null 2>&1 || { echo "jq missing — skipping"; exit 0; }

KEY=tok-FIXTURE-SENTINEL-4077
S="$T/ls"
mkdir -p "$T/h/bin" "$T/h/env" "$T/h/state" "$T/h/logs" "$T/stub" "$T/run" "$S"
cp "$DIR/bin/fleet-conf.sh" "$T/h/bin/"
cat > "$T/h/fleet.conf" <<'CONF'
# <project> <repo> <prod> <board-api-prefix> <offset>
linproj  o/l  https://lin.example  -  9
ghp      o/r  https://gh.example   -  9
nokey    o/n  https://n.example    -  9
CONF
export HARNESS="$T/h" FLEET_CONF="$T/h/fleet.conf" GH_ETAG=0 PATH="$T/stub:$PATH"
export HARNESS_SECRET=fixture-secret JOBS_URL=https://jobs.example JOBS_RETRIES=0 JOBS_TIMEOUT=5
export TL_STATE="$S" TL_FIX="$DIR/tests/fixtures/tracker-linear-context" TL_NOTFOUND="$DIR/tests/fixtures/tracker-linear/not-found.json" TL_KEY_EXPECT="$KEY"

cat > "$T/stub/curl" <<'SH'
#!/bin/bash
S="$TL_STATE"; url=""; data=""; out=""; fmt=""; auth=""
while [ $# -gt 0 ]; do
  case "$1" in
    -X|-m|--max-time|--connect-timeout) shift ;;
    --data-binary|-d) data="${2#@}"; shift ;;
    -o) out="$2"; shift ;;
    -w) fmt="$2"; shift ;;
    -H) case "$2" in Authorization:*) auth="${2#Authorization: }" ;; esac; shift ;;
    http*) url="$1" ;;
  esac
  shift
done
reply() { # reply <code> <body>
  if [ -n "$out" ]; then printf '%s' "$2" > "$out"; else printf '%s' "$2"; fi
  printf '%s' "$fmt" | sed "s/%{http_code}/$1/g"
  exit 0
}
case "$url" in
  https://jobs.example/api/settings/*)
    key="${url##*/}"; echo "$key" >> "$S/settings.log"
    [ -e "$S/settings-down" ] && reply 503 '{"error":"down"}'
    f="$S/setting-$key"
    [ -r "$f" ] && reply "$(head -1 "$f")" "$(sed -n '2,$p' "$f")"
    reply 404 '{"error":"no such setting"}' ;;
  https://jobs.example/*) reply 404 '{}' ;;
  https://api.linear.app/graphql) ;;
  *) echo "OFFBASE $url" >> "$S/reqs"; printf '000'; exit 7 ;;
esac
op=$(jq -r '.query // ""' "$data" 2>/dev/null | sed -nE '1s/^(query|mutation) ([A-Za-z]+).*/\2/p')
id=$(jq -r '.variables.id // ""' "$data" 2>/dev/null)
printf '%s %s\n' "$op" "$id" >> "$S/reqs"
[ "$auth" = "$TL_KEY_EXPECT" ] || { echo "badauth $op" >> "$S/authbad"; reply 401 '{"errors":[{"message":"Authentication required"}]}'; }
case "$op" in
  TrkGate) [ -r "$TL_FIX/gate-$id.json" ] && reply 200 "$(cat "$TL_FIX/gate-$id.json")"; reply 200 "$(cat "$TL_NOTFOUND")" ;;
esac
reply 400 '{"errors":[{"message":"the stub has no such operation"}]}'
SH
cat > "$T/stub/gh" <<'SH'
#!/bin/bash
printf 'gh %s\n' "$*" >> "$TL_STATE/gh.log"
exit 1
SH
chmod +x "$T/stub/curl" "$T/stub/gh"

row()   { jq -n --arg k "$1" --arg v "$2" '{setting:{key:$k,value:$v}}' | { echo 200; cat; } > "$S/setting-$1"; }
norow() { rm -f "$S/setting-$1"; }
fresh() { rm -f "$S/reqs" "$S/settings.log" "$S/gh.log" "$S/authbad"; }
nreq()  { cat "$S/reqs" 2>/dev/null | grep -c .; }
goodenv() { printf 'LINEAR_API_KEY=%s\n' "$KEY" > "$T/h/env/linproj.env"; }
goodenv
row tracker_adapter.linproj linear
row tracker_linear.linproj.team CRO

. "$DIR/bin/lib/tracker.sh" || exit 1
tracker_load linear || { echo "FAIL: tracker_load linear"; exit 1; }
declare -F trk_linear_context >/dev/null || { echo "FAIL: bin/lib/tracker/linear.sh has no trk_linear_context"; echo "tracker-linear-context: 0 passed, 1 failed"; exit 1; }
GATE="$DIR/bin/triage-gate.sh"

# --- X1 -------------------------------------------------------------------
fresh; trk_linear_context linproj 2>"$T/run/x1.err"; rc=$?
[ "$rc" = 0 ] && ok || bad "X1 the good env file and team row load (rc=$rc): $(cat "$T/run/x1.err")"
[ "${TRK_LINEAR_TOKEN:-}" = "$KEY" ] && [ "${TRK_LINEAR_TOKEN_VAR:-}" = LINEAR_API_KEY ] && ok || bad "X1 token context: var=${TRK_LINEAR_TOKEN_VAR:-}"
[ "${TRK_LINEAR_TEAM:-}" = CRO ] && [ "${TRK_LINEAR_LABEL:-}" = ai-build ] && [ -z "${TRK_LINEAR_STATES:-}" ] && ok \
  || bad "X1 team/label/states: ${TRK_LINEAR_TEAM:-}/${TRK_LINEAR_LABEL:-}/${TRK_LINEAR_STATES:-}"

# --- X2 -------------------------------------------------------------------
: > "$T/h/env/linproj.env"; printf 'LINEAR_API_KEY=%s\n' "$KEY" > "$T/h/env/global.env"
LINEAR_API_KEY="$KEY" trk_linear_context linproj 2>"$T/run/x2.err"; rc=$?
[ "$rc" = 1 ] && [ -z "${TRK_LINEAR_TOKEN:-}" ] && ok || bad "X2 a key in global.env or inherited must not stand in (rc=$rc)"
grep -q 'LINEAR_API_KEY' "$T/run/x2.err" && ok || bad "X2 stderr names the missing variable: $(cat "$T/run/x2.err")"
rm -f "$T/h/env/global.env" "$T/h/env/linproj.env"
trk_linear_context linproj 2>/dev/null; [ "$?" = 1 ] && ok || bad "X2 no env file must fail the context"
goodenv

# --- X3 -------------------------------------------------------------------
norow tracker_linear.linproj.team
trk_linear_context linproj 2>"$T/run/x3.err"; rc=$?
[ "$rc" = 1 ] && [ -z "${TRK_LINEAR_TOKEN:-}${TRK_LINEAR_TEAM:-}" ] && ok || bad "X3 no team row must fail and blank the context (rc=$rc)"
grep -q 'tracker_linear.linproj.team' "$T/run/x3.err" && ok || bad "X3 stderr names the row: $(cat "$T/run/x3.err")"
row tracker_linear.linproj.team 'CRO OTH'
trk_linear_context linproj 2>/dev/null; [ "$?" = 1 ] && ok || bad "X3 a team row that is not one team key must fail"
row tracker_linear.linproj.team CRO
row tracker_linear.linproj.label ai-ready
row tracker_linear.linproj.states '{"review":"QA","done":"Shipped"}'
trk_linear_context linproj 2>"$T/run/x3.err" && [ "$TRK_LINEAR_LABEL" = ai-ready ] && [ "$(printf '%s' "$TRK_LINEAR_STATES" | jq -r .review)" = QA ] && ok \
  || bad "X3 label and states rows: ${TRK_LINEAR_LABEL:-} ${TRK_LINEAR_STATES:-} $(cat "$T/run/x3.err")"
row tracker_linear.linproj.states '{"shipped":"Done"}'
trk_linear_context linproj 2>"$T/run/x3.err"; [ "$?" = 1 ] && grep -q 'states' "$T/run/x3.err" && ok || bad "X3 a status the contract does not have must fail: $(cat "$T/run/x3.err")"
row tracker_linear.linproj.states 'review=QA'
trk_linear_context linproj 2>/dev/null; [ "$?" = 1 ] && ok || bad "X3 a states row that is not JSON must fail"
norow tracker_linear.linproj.states; norow tracker_linear.linproj.label
: > "$S/settings-down"
trk_linear_context linproj 2>/dev/null; rc=$?
[ "$rc" = 1 ] && [ -z "${TRK_LINEAR_TOKEN:-}" ] && ok || bad "X3 a settings outage must fail the context (rc=$rc)"
rm -f "$S/settings-down"

# --- X4 -------------------------------------------------------------------
fresh
[ "$("$GATE" linproj --buildable CRO-1)" = OK ] && ok || bad "X4 CRO-1, newest comment a client's: $("$GATE" linproj --buildable CRO-1)"
grep -q '^TrkGate CRO-1$' "$S/reqs" 2>/dev/null && [ ! -e "$S/authbad" ] && ok || bad "X4 the gate read Linear with the key: $(cat "$S/reqs" "$S/authbad" 2>/dev/null)"
[ "$("$GATE" linproj --buildable CRO-2)" = "BLOCKED newest-comment-system" ] && ok || bad "X4 CRO-2, newest comment the key's own: $("$GATE" linproj --buildable CRO-2)"
[ "$("$GATE" linproj --buildable CRO-404)" = OK ] && ok || bad "X4 a missing issue is fail-open OK"
[ "$("$GATE" linproj --buildable-strict CRO-404)" = "BLOCKED unreadable" ] && ok || bad "X4 a missing issue under strict"
[ "$("$GATE" linproj --buildable-strict CRO-3)" = "BLOCKED unreadable" ] && ok || bad "X4 a thread longer than one page is unreadable under strict"
[ ! -s "$S/gh.log" ] && ok || bad "X4 the gate called GitHub: $(cat "$S/gh.log")"

# --- X5 -------------------------------------------------------------------
fresh
[ "$("$GATE" linproj --buildable-strict OTH-5)" = "BLOCKED unreadable" ] && [ "$(nreq)" = 0 ] && ok || bad "X5 another team's key is unreadable and never fetched: $(cat "$S/reqs" 2>/dev/null)"
[ "$("$GATE" linproj --buildable-strict CRO-9)" = "BLOCKED unreadable" ] && ok || bad "X5 an issue Linear answers from another team is unreadable"
norow tracker_linear.linproj.team; fresh
[ "$("$GATE" linproj --buildable CRO-1)" = "BLOCKED token-unresolved" ] && [ "$(nreq)" = 0 ] && ok || bad "X5 no team row: $("$GATE" linproj --buildable CRO-1)"
row tracker_linear.linproj.team CRO

# --- X6 -------------------------------------------------------------------
row tracker_adapter.nokey linear; fresh
[ "$("$GATE" nokey --buildable 7)" = OK ] && ok || bad "X6 nokey: $("$GATE" nokey --buildable 7)"
[ ! -s "$S/settings.log" ] && [ "$(nreq)" = 0 ] && ok || bad "X6 no LINEAR_API_KEY, yet: $(cat "$S/settings.log" "$S/reqs" 2>/dev/null)"
row tracker_adapter.linproj github-issues; fresh
out=$("$GATE" linproj --buildable CRO-2)
[ "$out" = OK ] && [ "$(nreq)" = 0 ] && ok || bad "X6 a github-issues row took the Linear arm ($out): $(cat "$S/reqs" 2>/dev/null)"
row tracker_adapter.linproj linear

# --- X7 -------------------------------------------------------------------
declare -F tracker_off_github >/dev/null && ok || bad "X7 bin/lib/tracker.sh has no tracker_off_github"
if declare -F tracker_off_github >/dev/null; then
  out=$(tracker_off_github linproj); rc=$?
  [ "$rc" = 0 ] && [ "$out" = linear ] && ok || bad "X7 a linear row: rc=$rc [$out]"
  out=$(tracker_off_github ghp); rc=$?
  [ "$rc" = 1 ] && [ -z "$out" ] && ok || bad "X7 no row on a '-' project is GitHub's: rc=$rc [$out]"
  : > "$S/settings-down"
  tracker_off_github linproj >/dev/null; [ "$?" = 1 ] && ok || bad "X7 an outage falls back to fleet.conf, which says GitHub"
  rm -f "$S/settings-down"
fi

# --- X8 -------------------------------------------------------------------
# As cron launches it: nothing inherited, the worker's URL and secret only in
# the box's global.env. A guard that needs them handed down would never fire.
printf 'HARNESS_SECRET=fixture-secret\nJOBS_URL=https://jobs.example\n' > "$T/h/env/global.env"
bare() { env -u HARNESS_SECRET -u JOBS_URL "$@"; }
# (Linear projects build since tests/linear-build-test.sh; a jira row still refuses.)
row tracker_adapter.linproj jira
fresh
REPOS_ROOT="$T/repos" bare timeout 60 bash "$DIR"/bin/run-build.sh linproj CRO-1 CRO-1 >"$T/run/x8.out" 2>&1; rc=$?
[ "$rc" = 2 ] && ok || bad "X8 run-build on a jira project rc=$rc, want 2: $(tail -3 "$T/run/x8.out")"
grep -q '\[linproj/CRO-1\].*jira' "$T/h/logs/ALERTS.log" 2>/dev/null && ok || bad "X8 ALERTS says why: $(cat "$T/h/logs/ALERTS.log" 2>/dev/null)"
grep -q '^tracker_adapter.linproj$' "$S/settings.log" 2>/dev/null && ok || bad "X8 the row was never asked for"
[ ! -d "$T/h/builds" ] && [ ! -s "$S/gh.log" ] && ok || bad "X8 a build dir or a gh call: $(ls "$T/h/builds" 2>/dev/null) $(cat "$S/gh.log" 2>/dev/null)"

# --- X9 -------------------------------------------------------------------
mkdir -p "$T/h/bin/lib" "$T/b9"; cp "$DIR/bin/lib/builder-direct.sh" "$DIR/bin/lib/tracker.sh" "$T/h/bin/lib/"; cp -R "$DIR/bin/lib/tracker" "$T/h/bin/lib/"
cp "$DIR/bin/jobs-client.sh" "$T/h/bin/"; cp -R "$DIR/bin/lib/jobs" "$T/h/bin/lib/" 2>/dev/null
echo 'PR_CREATED https://github.com/o/l/pull/9' > "$T/b9/RESULT"
fresh
BUILDER_DIRECT=1 bare bash "$DIR/bin/board-closeout.sh" linproj CRO-1 CRO-1 "$T/b9" >"$T/run/x9.out" 2>&1; rc=$?
[ "$rc" = 4 ] && grep -q 'jira' "$T/run/x9.out" && ok || bad "X9 board-closeout rc=$rc, want 4 and the reason: $(tail -2 "$T/run/x9.out")"
[ ! -s "$S/gh.log" ] && ok || bad "X9 board-closeout called GitHub: $(cat "$S/gh.log")"
row tracker_adapter.linproj linear
fresh
bare bash "$DIR/bin/needs-human-hold.sh" linproj 1 abc123 "apply the key" review >"$T/run/x9b.out" 2>&1; rc=$?
[ "$rc" = 0 ] && grep -q 'linear' "$T/run/x9b.out" && ok || bad "X9 needs-human-hold rc=$rc, want 0 and the reason: $(tail -2 "$T/run/x9b.out")"
[ ! -s "$S/gh.log" ] && ok || bad "X9 needs-human-hold called GitHub: $(cat "$S/gh.log")"

LEAK=$(grep -rlF -- "$KEY" "$T/run" "$S" "$T/h/logs" "$T/h/state" 2>/dev/null)
[ -z "$LEAK" ] && ok || bad "the key reached: $LEAK"

echo "tracker-linear-context: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
