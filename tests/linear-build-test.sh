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
#       or done (PR_MERGED); a partial build stays in review; a refused attach
#       or move still counts as posted (one comment); our own newest comment
#       leaves it for the sweep; no gh call
#   B5  lb_close_merged: once per (key, PR), a refused move included; rc 3 for
#       a project not on Linear
#   B6  the merge conductor's mc_settle_merged closes out the Linear issue
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
  TrkGate)   reply 200 "$(cat "$TL_GATE/gate-$(cat "$S/gate" 2>/dev/null || echo CRO-1).json")" ;;
  TrkThread) reply 200 "$(cat "$TL_TH/th-$(cat "$S/th" 2>/dev/null || echo a).json")" ;;
  TrkIssue|TrkIssueMeta) reply 200 "$(cat "$TL_FIX/issue-CRO-1.json")" ;;
  TrkAttach)  [ -e "$S/noattach" ] && reply 400 '{"errors":[{"message":"refused"}]}'
              reply 200 '{"data":{"attachmentLinkURL":{"success":true,"attachment":{"id":"a-1"}}}}' ;;
  TrkComment) jq -r '.variables.body' "$data" > "$S/comment-body"
              reply 200 '{"data":{"commentCreate":{"success":true,"comment":{"id":"c-1"}}}}' ;;
  TrkUpdate)  [ -e "$S/noupdate" ] && reply 200 '{"data":{"issueUpdate":{"success":false,"issue":null}}}'
              reply 200 "$(jq -c '{data:{issueUpdate:{success:true,issue:{state:{id:.variables.stateId}}}}}' "$data")" ;;
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
# A refused attach and a refused move still count as posted: ONE comment, rc 0.
: > "$S/noattach"; : > "$S/noupdate"; fresh; out=$(closeout "$T/b4"); rc=$?
[ "$rc" = 0 ] && [ "$out" = "POSTED linproj/CRO-1 (status not moved)" ] && [ "$(grep -c '^TrkComment' "$S/reqs")" = 1 ] && ok \
  || bad "B4 a refused attach and move: rc=$rc $out $(cat "$S/reqs")"
rm -f "$S/noattach" "$S/noupdate"
# The newest comment is the key's own (gate-CRO-2): the client-court guard
# leaves it for the sweep, nothing posted.
cp "$DIR/bin/triage-gate.sh" "$T/h/bin/"; echo CRO-2 > "$S/gate"
fresh; out=$(closeout "$T/b4"); rc=$?
[ "$rc" = 4 ] && ! grep -q '^TrkComment' "$S/reqs" && ok || bad "B4 own newest comment is left for the sweep (rc=$rc): $out"
rm -f "$S/gate" "$T/h/bin/triage-gate.sh"
[ ! -e "$S/gh.log" ] && ok || bad "B4 GitHub was asked: $(cat "$S/gh.log")"

# --- B5 -------------------------------------------------------------------
fresh; lb_close_merged linproj CRO-1 https://github.com/o/l/pull/11 "merge conductor"; rc=$?
[ "$rc" = 0 ] && grep -q "^TrkUpdate $DONE$" "$S/reqs" && grep -q 'Merged in https://github.com/o/l/pull/11' "$S/comment-body" && ok \
  || bad "B5 the merge close-out (rc=$rc): $(cat "$S/reqs" 2>/dev/null)"
fresh; lb_close_merged linproj CRO-1 https://github.com/o/l/pull/11 "merge conductor"; rc=$?
[ "$rc" = 0 ] && ! grep -q '^Trk\(Comment\|Update\)' "$S/reqs" 2>/dev/null && ok || bad "B5 a second settle says nothing twice"
: > "$S/noupdate"; fresh; lb_close_merged linproj CRO-1 https://github.com/o/l/pull/12 x 2>/dev/null; rc=$?
fresh; lb_close_merged linproj CRO-1 https://github.com/o/l/pull/12 x; rm -f "$S/noupdate"
[ "$rc" = 0 ] && ! grep -q '^TrkComment' "$S/reqs" 2>/dev/null && ok || bad "B5 a refused move still marks the comment posted (rc=$rc)"
fresh; lb_close_merged ghp TK-1 https://github.com/o/r/pull/3 x; rc=$?
[ "$rc" = 3 ] && [ ! -s "$S/reqs" ] && ok || bad "B5 a GitHub project is rc 3 with no Linear call (rc=$rc)"

# --- B6 -------------------------------------------------------------------
# The merge conductor's settle, driven: the ticket key comes from the record.
for st in beat.sh deploy-request.sh codegraph-ensure.sh pre-arm-guards.sh lane-alert.sh alert-line.sh; do
  printf '#!/bin/bash\nexit 0\n' > "$T/h/bin/$st"; chmod +x "$T/h/bin/$st"
done
REC="$T/h/builds/linproj-CRO-1-202610140001"; mkdir -p "$REC"
fresh
(
  . "$T/h/bin/lib/merge-conductor-lib.sh" && mc_init >/dev/null 2>&1
  mc_settle_merged o/l#13 https://github.com/o/l/pull/13 linproj o/l ticket/cro-1 "$REC" - abc123 >/dev/null 2>&1
) ; fresh_reqs=$(cat "$S/reqs" 2>/dev/null)
grep -q 'Merged in https://github.com/o/l/pull/13 (merge conductor' "$S/comment-body" 2>/dev/null && printf '%s' "$fresh_reqs" | grep -q "^TrkUpdate $DONE$" && ok \
  || bad "B6 mc_settle_merged closes out the Linear issue: $fresh_reqs $(tail -3 "$T/h/logs/merge-conductor.log" 2>/dev/null)"
! grep -q 'issues/1\b\|issue close' "$S/gh.log" 2>/dev/null && ok || bad "B6 GitHub issue #1 was touched: $(cat "$S/gh.log")"

LEAK=$(grep -rlF -- "$LKEY" "$S" "$T/h/logs" "$T/h1/logs" "$T/h/state" "$T"/*.out "$T"/*.err 2>/dev/null)
[ -z "$LEAK" ] && ok || bad "the key reached: $LEAK"

echo "linear-build: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
