#!/bin/bash
# reads-run-build: raw — B1 EXECUTES the driver against a scratch $HARNESS to reach its tracker block, so it needs the real runnable path; the flatten is not runnable. See tests/rb-raw-readers-baseline/linear-build-test.sh.txt.
# tests/linear-build-test.sh — a Linear project builds and is closed out on
# Linear (bin/lib/linear-build.sh), and nothing in that path reads or writes
# GitHub issue #<n> of the app repo.
#
#   B1  bin/run-build.sh: a linear project with its context gets past the
#       tracker block; one whose context does not load is refused, with why
#   B2  the plan stage: TICKET_FP is the Linear thread's digest (our own
#       comments do not move it, a human's does); TICKET_META is the issue
#   B3  the PR body: `Linear: <key>`, never `Closes #n`; a partial build says
#       so; a GitHub-Issues project still gets `Closes #n`
#   B4  bin/board-closeout.sh: PR attached, comment, then review (PR_CREATED)
#       or done (PR_MERGED); a partial build stays in review; no gh call
#   B5  lb_close_merged: once per (key, PR); rc 3 for a project not on Linear
#
# No network: a `curl` stub plays api.linear.app/graphql and the settings route.
#   HARNESS_TEST_SANDBOX=1 bash tests/linear-build-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null 2>&1 || { echo "jq missing — skipping"; exit 0; }

LKEY=tok-FIXTURE-SENTINEL-4080
S="$T/ls"
mkdir -p "$T/h/bin/lib" "$T/h/env" "$T/h/logs" "$T/h/state" "$T/stub" "$S"
cp -R "$DIR/bin/lib/." "$T/h/bin/lib/"
cp "$DIR/bin/fleet-conf.sh" "$DIR/bin/jobs-client.sh" "$T/h/bin/"
cat > "$T/h/fleet.conf" <<'CONF'
# <project> <repo> <prod> <board-api-prefix> <offset>
linproj  o/l  https://lin.example  -  9
ghp      o/r  https://gh.example   -  9
CONF
export HARNESS="$T/h" FLEET_CONF="$T/h/fleet.conf" PATH="$T/stub:$PATH"
export HARNESS_SECRET=fixture-secret JOBS_URL=https://jobs.example JOBS_RETRIES=0 JOBS_TIMEOUT=5
export TL_STATE="$S" TL_KEY_EXPECT="$LKEY" TL_TH="$DIR/tests/fixtures/triage-gate-linear" TL_FIX="$DIR/tests/fixtures/tracker-linear" TL_GATE="$DIR/tests/fixtures/tracker-linear-context"

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
reply() { if [ -n "$out" ]; then printf '%s' "$2" > "$out"; else printf '%s' "$2"; fi; printf '%s' "$fmt" | sed "s/%{http_code}/$1/g"; exit 0; }
case "$url" in
  https://jobs.example/api/settings/*)
    f="$S/setting-${url##*/}"; [ -r "$f" ] && reply 200 "$(cat "$f")"
    reply 404 '{"error":"no such setting"}' ;;
  https://jobs.example/*) reply 404 '{}' ;;
  https://api.linear.app/graphql) ;;
  *) echo "OFFBASE $url" >> "$S/reqs"; printf '000'; exit 7 ;;
esac
op=$(jq -r '.query // ""' "$data" 2>/dev/null | sed -nE '1s/^(query|mutation) ([A-Za-z]+).*/\2/p')
printf '%s %s\n' "$op" "$(jq -r '.variables.stateId // .variables.url // .variables.id // ""' "$data")" >> "$S/reqs"
[ "$auth" = "$TL_KEY_EXPECT" ] || reply 401 '{"errors":[{"message":"Authentication required"}]}'
case "$op" in
  TrkGate)   reply 200 "$(cat "$TL_GATE/gate-CRO-1.json")" ;;
  TrkThread) reply 200 "$(cat "$TL_TH/th-$(cat "$S/th" 2>/dev/null || echo a).json")" ;;
  TrkIssue|TrkIssueMeta) reply 200 "$(cat "$TL_FIX/issue-CRO-1.json")" ;;
  TrkAttach)  reply 200 '{"data":{"attachmentLinkURL":{"success":true,"attachment":{"id":"a-1"}}}}' ;;
  TrkComment) jq -r '.variables.body' "$data" > "$S/comment-body"
              reply 200 '{"data":{"commentCreate":{"success":true,"comment":{"id":"c-1"}}}}' ;;
  TrkUpdate)  reply 200 "$(jq -c '{data:{issueUpdate:{success:true,issue:{state:{id:.variables.stateId}}}}}' "$data")" ;;
esac
reply 400 '{"errors":[{"message":"the stub has no such operation"}]}'
SH
printf '#!/bin/bash\nprintf "gh %%s\\n" "$*" >> "$TL_STATE/gh.log"\nexit 1\n' > "$T/stub/gh"
chmod +x "$T/stub/curl" "$T/stub/gh"
row() { jq -n --arg k "$1" --arg v "$2" '{setting:{key:$k,value:$v}}' > "$S/setting-$1"; }
fresh() { rm -f "$S/reqs" "$S/gh.log" "$S/comment-body"; }
printf 'LINEAR_API_KEY=%s\n' "$LKEY" > "$T/h/env/linproj.env"
row tracker_adapter.linproj linear
row tracker_linear.linproj.team CRO
IN_REVIEW=00000000-0000-0000-0000-500000000004
DONE=00000000-0000-0000-0000-500000000007
. "$DIR/bin/lib/linear-build.sh" 2>/dev/null || bad "bin/lib/linear-build.sh did not load"

# --- B1 -------------------------------------------------------------------
# A root with no stage modules: past the tracker block, the next stop is the
# module check's own ALERTS line, so nothing is built.
H1="$T/h1"; mkdir -p "$H1/env" "$H1/logs"
cp "$T/h/env/linproj.env" "$H1/env/"
printf 'HARNESS_SECRET=fixture-secret\nJOBS_URL=https://jobs.example\n' > "$H1/env/global.env"
b1() { HARNESS="$H1" REPOS_ROOT="$T/repos" timeout 60 bash "$DIR/bin/run-build.sh" linproj CRO-1 CRO-1 >"$T/b1.out" 2>&1; }
fresh; b1
! grep -q 'build refused' "$H1/logs/ALERTS.log" && grep -q 'stage module' "$H1/logs/ALERTS.log" && ok \
  || bad "B1 a linear project gets past the tracker block (to the module check): $(cat "$H1/logs/ALERTS.log")"
printf 'LINEAR_API_KEY=\n' > "$H1/env/linproj.env"; : > "$H1/logs/ALERTS.log"
b1; rc=$?
[ "$rc" = 2 ] && grep -q 'build refused.*Linear context did not load.*LINEAR_API_KEY' "$H1/logs/ALERTS.log" && ok \
  || bad "B1 no context is refused with the reason (rc=$rc): $(cat "$H1/logs/ALERTS.log")"
[ ! -e "$S/gh.log" ] && ok || bad "B1 GitHub was asked: $(cat "$S/gh.log")"

# --- B2 -------------------------------------------------------------------
lb_on linproj || bad "B2 lb_on linproj"
awk '/^TICKET_FP\(\) \{/,/^\}/' "$DIR/bin/lib/rb/plan.sh" > "$T/fp.sh"
awk '/^TICKET_META\(\) \{/,/^\}/' "$DIR/bin/lib/rb/plan.sh" > "$T/meta.sh"
. "$T/fp.sh"; . "$T/meta.sh"
PROJECT=linproj; KEY=CRO-1; RB_LINEAR=1
echo a > "$S/th"; f0=$(TICKET_FP)
echo self > "$S/th"; f1=$(TICKET_FP)
echo human > "$S/th"; f2=$(TICKET_FP); echo a > "$S/th"
[[ "$f0" =~ ^[0-9a-f]{16}$ ]] && [ "$f0" = "$f1" ] && [ "$f0" != "$f2" ] && ok || bad "B2 TICKET_FP: $f0 / own edit $f1 / human edit $f2"
m=$(TICKET_META)
printf '%s' "$m" | jq -e '(.title | length) > 0 and (.labels | type) == "array" and (.labels[0] | has("name"))' >/dev/null 2>&1 && ok \
  || bad "B2 TICKET_META is the Linear issue in kind-gate's shape: $m"
[ ! -e "$S/gh.log" ] && ok || bad "B2 GitHub was asked: $(cat "$S/gh.log")"

# --- B3 -------------------------------------------------------------------
awk '/^# >>> closes line/,/^# <<< closes line/' "$DIR/bin/lib/rb/pr.sh" > "$T/closes.sh"
grep -q 'RB_LINEAR' "$T/closes.sh" || bad "B3 bin/lib/rb/pr.sh has no closes-line region"
closes() { ( HARNESS="$T/h" PROJECT="$1" KEY="$2" RB_LINEAR="$3" BUILD="$4"; . "$T/closes.sh"; printf '%s|%s' "$CLOSES_LINE" "$NOTMET_SECTION" ); }
mkdir -p "$T/b3"
[ "$(closes linproj CRO-12 1 "$T/b3")" = "Linear: CRO-12|" ] && ok || bad "B3 a Linear build: $(closes linproj CRO-12 1 "$T/b3")"
printf '{"claims":[{"n":1,"claim":"export","verdict":"REFUTED"}]}' > "$T/b3/evidence.json"
o=$(closes linproj CRO-12 1 "$T/b3")
case "$o" in "Linear: CRO-12|"*"review rather than done"*) ok ;; *) bad "B3 a partial Linear build says so: $o" ;; esac
case "$(closes ghp TK-12 "" "$T/b3")" in "Refs #12|"*) ok ;; *) bad "B3 a GitHub project is unchanged: $(closes ghp TK-12 "" "$T/b3")" ;; esac
rm -f "$T/b3/evidence.json"
case "$(closes ghp TK-12 "" "$T/b3")" in "Closes #12|") ok ;; *) bad "B3 a GitHub project still closes its issue" ;; esac

# --- B4 -------------------------------------------------------------------
closeout() { BUILDER_DIRECT=1 bash "$DIR/bin/board-closeout.sh" linproj CRO-1 CRO-1 "$1" 2>"$T/b4.err"; }
mkdir -p "$T/b4"; echo 'PR_CREATED https://github.com/o/l/pull/9' > "$T/b4/RESULT"; echo '- add CSV export' > "$T/b4/what.txt"
fresh; out=$(closeout "$T/b4"); rc=$?
[ "$rc" = 0 ] && [ "$out" = "POSTED linproj/CRO-1 -> review" ] && ok || bad "B4 PR_CREATED (rc=$rc): $out $(cat "$T/b4.err")"
grep -q '^TrkAttach https://github.com/o/l/pull/9$' "$S/reqs" && grep -q "^TrkUpdate $IN_REVIEW$" "$S/reqs" \
  && [ "$(grep -n TrkComment "$S/reqs" | cut -d: -f1)" -lt "$(grep -n TrkUpdate "$S/reqs" | cut -d: -f1)" ] && ok \
  || bad "B4 attach, comment, then review: $(cat "$S/reqs")"
grep -q 'Built and opened for review' "$S/comment-body" && grep -q 'pull/9' "$S/comment-body" && ok || bad "B4 the comment"
echo 'PR_MERGED https://github.com/o/l/pull/9' > "$T/b4/RESULT"
fresh; out=$(closeout "$T/b4")
[ "$out" = "POSTED linproj/CRO-1 -> done" ] && grep -q "^TrkUpdate $DONE$" "$S/reqs" && ok || bad "B4 PR_MERGED moves to done: $out"
printf '{"claims":[{"n":1,"verdict":"REFUTED"}]}' > "$T/b4/evidence.json"
fresh; out=$(closeout "$T/b4")
[ "$out" = "POSTED linproj/CRO-1 -> review" ] && ok || bad "B4 a partial merged build stays in review: $out"
rm -f "$T/b4/evidence.json"
[ ! -e "$S/gh.log" ] && ok || bad "B4 GitHub was asked: $(cat "$S/gh.log")"

# --- B5 -------------------------------------------------------------------
fresh; lb_close_merged linproj CRO-1 https://github.com/o/l/pull/11 "merge conductor"; rc=$?
[ "$rc" = 0 ] && grep -q "^TrkUpdate $DONE$" "$S/reqs" && grep -q 'Merged in https://github.com/o/l/pull/11' "$S/comment-body" && ok \
  || bad "B5 the merge close-out (rc=$rc): $(cat "$S/reqs" 2>/dev/null)"
fresh; lb_close_merged linproj CRO-1 https://github.com/o/l/pull/11 "merge conductor"; rc=$?
[ "$rc" = 0 ] && ! grep -q '^Trk\(Comment\|Update\)' "$S/reqs" 2>/dev/null && ok || bad "B5 a second settle says nothing twice"
fresh; lb_close_merged ghp TK-1 https://github.com/o/r/pull/3 x; rc=$?
[ "$rc" = 3 ] && [ ! -s "$S/reqs" ] && ok || bad "B5 a GitHub project is rc 3 with no Linear call (rc=$rc)"

LEAK=$(grep -rlF -- "$LKEY" "$S" "$T/h/logs" "$T/h1/logs" "$T/h/state" "$T"/*.out "$T"/*.err 2>/dev/null)
[ -z "$LEAK" ] && ok || bad "the key reached: $LEAK"

echo "linear-build: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
