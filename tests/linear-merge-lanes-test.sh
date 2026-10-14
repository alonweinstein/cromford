#!/bin/bash
# tests/linear-merge-lanes-test.sh — every lane that lands a PR closes out a
# Linear project's ticket on Linear (bin/lib/linear-build.sh lb_merge_lane),
# and none of them turns record pool-linproj-CRO-1-<stamp> into GitHub issue #1.
#
#   K  lb_ticket_key reads the key from the record name, pool- or not
#   F  bin/merge-sweep.sh, a fresh reviewed merge: comment + done on Linear, the
#      merge recorded, nothing owed, no call at all on issues/1 (the old code
#      read #1's timeline, deferred the close, and never recorded the merge)
#   W  bin/merge-sweep.sh, a record left owing a close (the stranded shape):
#      closed out on Linear, the debt cleared, the merge recorded
#   O  the sweep is fail-open: a Linear close-out that did not land still
#      records the merge, and owes nothing
#   R  bin/batch-resolve.sh settle_member: the comment names the train, done;
#      a partial build stays in review; a GitHub-Issues project still gets its
#      issue closed
#
# No network: ghfx plays GitHub's REST, a `curl` stub plays api.linear.app.
#   HARNESS_TEST_SANDBOX=1 bash tests/linear-merge-lanes-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
# shellcheck source=tests/lib/gh-rest-fx.sh
. "$DIR/tests/lib/gh-rest-fx.sh" || exit 1
# shellcheck source=tests/lib/verdict-fixture.sh
. "$(dirname "$0")/lib/verdict-fixture.sh" || exit 1
vpf_export || exit 1
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null 2>&1 || { echo "jq missing — skipping"; exit 0; }

LKEY=tok-FIXTURE-SENTINEL-4081
S="$T/ls"
mkdir -p "$T/h/logs" "$T/h/state" "$T/h/env" "$T/h/flags" "$T/h/builds" "$T/h/locks" "$T/tmp" "$S"
# The lib subset tests/conductor-limited-read.bh-784-test.sh drives the sweep
# with, plus the Linear libs: the whole bin/lib arms gates this suite is not about.
mkdir -p "$T/h/bin/lib/mc" "$T/h/bin/lib/jobs" "$T/h/bin/lib/tracker"
for f in gh-rest.sh gh-rest-var.sh gh-pr-list.sh gh-budget.sh merge-conductor-lib.sh issue-state-lib.sh \
         verdict-parse.sh env-path.sh tracker.sh linear-build.sh; do cp "$DIR/bin/lib/$f" "$T/h/bin/lib/"; done
cp "$DIR"/bin/lib/mc/*.sh "$T/h/bin/lib/mc/"; cp "$DIR"/bin/lib/jobs/*.sh "$T/h/bin/lib/jobs/"
cp "$DIR"/bin/lib/tracker/*.sh "$T/h/bin/lib/tracker/"
cp "$DIR/bin/fleet-conf.sh" "$DIR/bin/jobs-client.sh" "$DIR/bin/merge-sweep.sh" "$T/h/bin/"
for s in beat.sh deploy-request.sh codegraph-ensure.sh pre-arm-guards.sh lane-alert.sh alert-line.sh; do
  printf '#!/bin/bash\nexit 0\n' > "$T/h/bin/$s"; chmod +x "$T/h/bin/$s"
done
printf '#!/bin/bash\necho "" > "$4"; exit 0\n' > "$T/h/bin/agent-call.sh"; chmod +x "$T/h/bin/agent-call.sh"
cat > "$T/h/fleet.conf" <<'CONF'
# <project> <repo> <prod> <board-api-prefix> <offset>
linproj  example-org/lin  https://lin.example  -  9
ghp      example-org/ghp  https://gh.example   -  9
CONF
: > "$T/h/env/global.env"
printf 'LINEAR_API_KEY=%s\n' "$LKEY" > "$T/h/env/linproj.env"
ghfx_init
printf '#!/bin/bash\nexit 0\n' > "$T/fakebin/flock"; chmod +x "$T/fakebin/flock"
export HARNESS="$T/h" TMPDIR="$T/tmp" PATH="$T/fakebin:$PATH" FLEET_CONF="$T/h/fleet.conf" MC_DETACHED_DEPLOY_VERIFY=0
export HARNESS_SECRET=fixture-secret JOBS_URL=https://jobs.example JOBS_RETRIES=0 JOBS_TIMEOUT=5
export TL_STATE="$S" TL_KEY_EXPECT="$LKEY" TL_GATE="$DIR/tests/fixtures/tracker-linear-context" TL_FIX="$DIR/tests/fixtures/tracker-linear"

# The Linear side: the same operations tests/linear-build-test.sh plays.
cat > "$T/fakebin/curl" <<'SH'
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
  https://api.linear.app/graphql) ;;
  *) reply 404 '{}' ;;
esac
[ -e "$S/down" ] && reply 503 '{"errors":[{"message":"down"}]}'
op=$(jq -r '.query // ""' "$data" 2>/dev/null | sed -nE '1s/^(query|mutation) ([A-Za-z]+).*/\2/p')
printf '%s %s\n' "$op" "$(jq -r '.variables.stateId // .variables.url // .variables.id // ""' "$data")" >> "$S/reqs"
[ "$auth" = "$TL_KEY_EXPECT" ] || reply 401 '{"errors":[{"message":"Authentication required"}]}'
case "$op" in
  TrkGate)    reply 200 "$(cat "$TL_GATE/gate-CRO-1.json")" ;;
  TrkIssue|TrkIssueMeta) reply 200 "$(cat "$TL_FIX/issue-CRO-1.json")" ;;
  TrkAttach)  reply 200 '{"data":{"attachmentLinkURL":{"success":true,"attachment":{"id":"a-1"}}}}' ;;
  TrkComment) jq -r '.variables.body' "$data" >> "$S/comment-body"
              reply 200 '{"data":{"commentCreate":{"success":true,"comment":{"id":"c-1"}}}}' ;;
  TrkUpdate)  reply 200 "$(jq -c '{data:{issueUpdate:{success:true,issue:{state:{id:.variables.stateId}}}}}' "$data")" ;;
esac
reply 400 '{"errors":[{"message":"the stub has no such operation"}]}'
SH
chmod +x "$T/fakebin/curl"
row() { jq -n --arg k "$1" --arg v "$2" '{setting:{key:$k,value:$v}}' > "$S/setting-$1"; }
row tracker_adapter.linproj linear
row tracker_linear.linproj.team CRO
row lead_pr_authors lead-bot
IN_REVIEW=00000000-0000-0000-0000-500000000004
DONE=00000000-0000-0000-0000-500000000007
H1=aaaaaaaa1111; MSHA=cccccccc3333
SLOG="$T/h/logs/merge-sweep.log"
fresh() { rm -f "$S/reqs" "$S/comment-body" "$S/down"; ghfx_routes_reset; ghfx_log_reset; : > "$SLOG"
          : > "$T/h/state/merge-sweep-done.txt"; : > "$T/h/state/merge-sweep-terminal.txt"; rm -f "$T/h/state"/linear-merged-*
          ghfx_route GET 'repos/example-org/lin' 200 '{"id":1}'; }
gh_issue_writes() { grep -F 'repos/example-org/lin/issues' "$T/gh-argv.log" 2>/dev/null; }
sweep_tick() { ( cd "$T" && HARNESS="$T/h" SWEEP_MERGE_SETTLE=0 bash "$T/h/bin/merge-sweep.sh" >/dev/null 2>&1 ) || true; }
record() { # record <name> -> $REC, a reviewed record for PR #9
  rm -rf "$T/h/builds/"*; REC="$T/h/builds/$1"; mkdir -p "$REC"
  echo "PR_CREATED https://github.com/example-org/lin/pull/9" > "$REC/RESULT"
  printf 'findings\nTIER: 2\nVERDICT: APPROVE\n' > "$REC/review.md"; echo "$H1" > "$REC/reviewed-sha"
}
PR=https://github.com/example-org/lin/pull/9
# shellcheck source=/dev/null
. "$T/h/bin/lib/linear-build.sh" || { echo "FAIL: cannot source linear-build.sh"; exit 1; }

# --- K ----------------------------------------------------------------------
[ "$(lb_ticket_key linproj "$T/h/builds/pool-linproj-CRO-12-202610140001")" = CRO-12 ] \
  && [ "$(lb_ticket_key linproj /x/linproj-CRO-3-202610140001)" = CRO-3 ] \
  && [ -z "$(lb_ticket_key linproj /x/other-CRO-3-202610140001)" ] && ok || bad "K lb_ticket_key"

# --- F ----------------------------------------------------------------------
ghfx_extra <<'SH'
case "$A" in
  *"pr merge"*) printf '%s\n' "$A" >> "$GHFX/merge-calls.txt"; touch "$GHFX/merged9"; exit 0 ;;
  "api repos/example-org/lin -q .id"*) echo 1; exit 0 ;;
  *"actions/runs?head_sha="*) printf 'completed|success\n'; exit 0 ;;
esac
SH
fresh; record pool-linproj-CRO-1-202610140001; rm -f "$T/merged9"; : > "$T/merge-calls.txt"
ghfx_route GET  'repos/example-org/lin/pulls/9' 200 "$(ghfx_pr closed 2026-10-14T00:00:00Z "$H1" ticket/cro-1 main '' true clean 'app/cromford' "$MSHA")" "$T/merged9"
ghfx_route GET  'repos/example-org/lin/pulls/9' 200 "$(ghfx_pr open - "$H1" ticket/cro-1 main '' true clean 'app/cromford' '')"
ghfx_route DIFF 'repos/example-org/lin/pulls/9' 200 $'+++ b/src/x.ts\n+const a = 1;'
ghfx_route POST  'repos/example-org/lin/issues/1/comments' 201 '{"id":1}'
ghfx_route PATCH 'repos/example-org/lin/issues/1' 200 '{"state":"closed"}'
sweep_tick
if [ -s "$T/merge-calls.txt" ]; then
  ok
  grep -q 'Merged in https://github.com/example-org/lin/pull/9 (reviewed-merge sweep' "$S/comment-body" 2>/dev/null \
    && grep -q "^TrkUpdate $DONE$" "$S/reqs" && ok || bad "F the fresh merge closes out CRO-1 on Linear: $(cat "$S/reqs" 2>/dev/null) / $(cat "$SLOG")"
  grep -qxF "$PR" "$T/h/state/merge-sweep-done.txt" && [ ! -e "$REC/issue-close-owed" ] && ok \
    || bad "F the merge is recorded and owes nothing (log: $(cat "$SLOG"))"
  [ -z "$(gh_issue_writes)" ] && ok || bad "F GitHub issue #1 was touched: $(gh_issue_writes)"
else
  bad "F the sweep never reached the merge verb, so F proves nothing (log: $(cat "$SLOG"))"
fi

# --- W ----------------------------------------------------------------------
wsetup() {
  fresh; record "$1"; touch "$REC/issue-close-owed"
  ghfx_route GET 'repos/example-org/lin/pulls/9' 200 "$(ghfx_pr closed 2026-10-14T00:00:00Z "$H1" ticket/cro-1 main '' true clean 'app/cromford' "$MSHA")"
  ghfx_route POST  'repos/example-org/lin/issues/1/comments' 201 '{"id":1}'
  ghfx_route PATCH 'repos/example-org/lin/issues/1' 200 '{"state":"closed"}'
  ghfx_route GET   'repos/example-org/lin/issues/1' 200 '{"state":"closed","labels":[]}'
}
wsetup linproj-CRO-1-202610140002
sweep_tick
grep -q "^TrkComment" "$S/reqs" 2>/dev/null && grep -q "^TrkUpdate $DONE$" "$S/reqs" && ok \
  || bad "W the owed close is settled on Linear: $(cat "$S/reqs" 2>/dev/null) / $(cat "$SLOG")"
[ ! -e "$REC/issue-close-owed" ] && grep -qxF "$PR" "$T/h/state/merge-sweep-done.txt" && ok \
  || bad "W the debt is cleared and the merge recorded (log: $(cat "$SLOG"))"
[ -z "$(gh_issue_writes)" ] && ok || bad "W GitHub issue #1 was touched: $(gh_issue_writes)"

# --- O ----------------------------------------------------------------------
wsetup linproj-CRO-1-202610140003; : > "$S/down"
sweep_tick
[ ! -e "$REC/issue-close-owed" ] && grep -qxF "$PR" "$T/h/state/merge-sweep-done.txt" \
  && grep -q 'could not be closed out' "$SLOG" && ok || bad "O a Linear outage still records the merge, and says so (log: $(cat "$SLOG"))"
[ -z "$(gh_issue_writes)" ] && ok || bad "O GitHub issue #1 was touched: $(gh_issue_writes)"

# --- R ----------------------------------------------------------------------
awk '/^settle_member\(\) \{/{f=1} f{print} f&&/^\}/{exit}' "$DIR/bin/batch-resolve.sh" > "$T/settle-member.sh"
[ -s "$T/settle-member.sh" ] && ok || bad "R settle_member not extracted"
bsettle() { # bsettle <project> <slug> <record> -> $T/br.out
  rm -f "$T/closed-issue"
  ( export T BR_PROJECT="$1" BR_SLUG="$2" BR_REC="$3"
    bash -c '
      H="$HARNESS"; STATE="$T/br-state"; SLUG="$BR_SLUG"; PROJECT="$BR_PROJECT"; PBASE=main; LOG=/dev/null
      mkdir -p "$STATE"; rm -f "$STATE/landed.txt"
      say() { echo "$*"; }; mc_batch_release() { :; }; lt_put() { :; }; mc_record_for() { echo "$BR_REC"; }
      member_excluded() { return 1; }
      gh_rest_pr_state_var() { printf -v "$1" open; }
      gh_rest_comment() { return 0; }; gh_rest_close() { return 0; }
      mc_issue_of() { basename "$1" | sed -nE "s/^(pool-)?.*-[A-Za-z]+-([0-9]+)-[0-9]+$/\2/p"; }
      issue_close_shipped() { echo "$1#$2" > "$T/closed-issue"; echo closed; }
      . "$T/settle-member.sh"
      settle_member 9 trainsha https://github.com/example-org/lin/pull/77 -' ) > "$T/br.out" 2>&1
}
fresh; mkdir -p "$T/h/builds/linproj-CRO-1-202610140004"
bsettle linproj example-org/lin "$T/h/builds/linproj-CRO-1-202610140004"
grep -q 'batch train https://github.com/example-org/lin/pull/77' "$S/comment-body" 2>/dev/null && grep -q "^TrkUpdate $DONE$" "$S/reqs" && ok \
  || bad "R the train closes out CRO-1 on Linear: $(cat "$S/reqs" 2>/dev/null) / $(cat "$T/br.out")"
[ ! -e "$T/closed-issue" ] && ok || bad "R GitHub issue $(cat "$T/closed-issue") was closed for a Linear ticket"

fresh; P="$T/h/builds/linproj-CRO-1-202610140005"; mkdir -p "$P"
echo '{"claims":[{"id":"A1","verdict":"REFUTED"}]}' > "$P/evidence.json"
bsettle linproj example-org/lin "$P"
grep -q "^TrkUpdate $IN_REVIEW$" "$S/reqs" 2>/dev/null && ! grep -q "^TrkUpdate $DONE$" "$S/reqs" && ok \
  || bad "R a partial build stays in review: $(cat "$S/reqs" 2>/dev/null)"

fresh; mkdir -p "$T/h/builds/ghp-TK-4-202610140006"
bsettle ghp example-org/ghp "$T/h/builds/ghp-TK-4-202610140006"
[ "$(cat "$T/closed-issue" 2>/dev/null)" = "example-org/ghp#4" ] && [ ! -s "$S/reqs" ] && ok \
  || bad "R a GitHub-Issues project still closes its issue, with no Linear call: $(cat "$T/br.out")"

LEAK=$(grep -rlF -- "$LKEY" "$T/h/logs" "$T/h/state" "$T/br.out" "$T/gh-argv.log" 2>/dev/null)
[ -z "$LEAK" ] && ok || bad "the key reached: $LEAK"

echo "linear-merge-lanes: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
