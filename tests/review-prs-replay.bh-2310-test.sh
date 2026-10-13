#!/bin/bash
# tests/review-prs-replay.bh-2310-test.sh — bin/review-prs.sh REPLAYS its verdict
# onto a head whose own patch did not change, and buys no review (BH-2310).
#
# The REAL bin/review-prs.sh, a counting fake agent-call.sh, stubbed gh and
# jobs-client functions (the review-prs-d1-row.bh-1064 rig), and a REAL git
# fixture: a bare remote plus the hub checkout at $REPOS_ROOT/<project>.
#
#   A1  first head R: exactly 1 agent call, verdict APPROVE on R
#   A2  a fix round that only merged main (main touched a line next to the PR
#       hunk): 0 new agent calls, the SAME verdict now on the new head, the
#       ledger verdict rebound onto it, and no GitHub review/comment write
#   A3  a real change on top: exactly 1 new agent call
#   A4  a REQUEST_CHANGES verdict replays as REQUEST_CHANGES (an unchanged patch
#       fixes nothing), still 0 calls
#   A5  no checkout on this box: nothing can be proved, the review is bought
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/gh-list-bridge.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
RP="$DIR/bin/review-prs.sh"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@example.invalid GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@example.invalid
export GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null
PROJECT=project-1
SLUG=example-org/project-1
NUM=42
STATE="$T/h/state/$PROJECT.pr-reviews.json"
mkdir -p "$T/fakebin"

cat > "$T/fakebin/gh" <<'STUB'
#!/bin/bash
case "$*" in
  *"pr list"*) cat "$TEST_ROOT/prs.tsv" ;;
  *"pr diff"*"name-only"*) printf 'f.txt\n' ;;
  *"pr diff"*) printf 'diff --git a/f.txt b/f.txt\n+line 10 CHANGED BY PR\n' ;;
  *"pr view"*"state,mergeStateStatus"*) printf '{"state":"OPEN","mergeStateStatus":"BLOCKED"}\n' ;;
  *"pr view"*"comments,reviews"*) printf '{"comments":[],"reviews":[]}\n' ;;
  *"pr view"*"body"*) printf '{"body":"test body"}\n' ;;
  *"pr review"*|*"pr comment"*) printf '%s\n' "$*" >> "$TEST_ROOT/gh-writes.log" ;;
  *"pr merge"*) : ;;
  *actions/runs*) printf '{"s":"completed","c":"success","n":"CI"}\n' ;;
  *"api"*) : ;;
esac
exit 0
STUB
cat > "$T/fakebin/agent-call.sh" <<'STUB'
#!/bin/bash
printf '%s\n' "$*" >> "$TEST_ROOT/agent-calls.log"
printf 'Static review.\nTIER: 2\nVERDICT: %s\n' "$(cat "$TEST_ROOT/verdict" 2>/dev/null || echo APPROVE)" > "$5"
printf 'claude\n' > "$5.runner"
STUB
printf '#!/bin/bash\nexit 0\n' > "$T/fakebin/sleep"
cat > "$T/stub.sh" <<'STUB'
job_lane_open() { JOB_ID="job-x"; export JOB_ID; return 0; }
job_lane_close() { JOB_ID=""; export JOB_ID; return 0; }
job_artifact_put() { return 0; }
job_event() { return 0; }
job_heartbeat() { return 0; }
job_update() { return 0; }
job_phase_open() { return 0; }
job_verdict_rebind() { printf '%s %s\n' "$1" "$2" >> "$TEST_ROOT/rebinds.log"; return 0; }
STUB

. "$DIR/tests/lib/model-route-stub.sh" || exit 1
fresh_harness() {
  scratch_rm "$T/h" 2>/dev/null
  rm -f "$T/agent-calls.log" "$T/rebinds.log" "$T/gh-writes.log" "$T/verdict"
  mkdir -p "$T/h/bin/lib" "$T/h/state" "$T/h/logs" "$T/h/locks" "$T/h/env" "$T/h/builds"
  chmod +x "$T/fakebin/gh" "$T/fakebin/agent-call.sh" "$T/fakebin/sleep"
  cp "$T/fakebin/agent-call.sh" "$T/h/bin/agent-call.sh"; chmod +x "$T/h/bin/agent-call.sh"
  cp "$DIR/bin/lib/review-model.sh" "$DIR/bin/lib/patch-same.sh" "$T/h/bin/lib/"
  mrs_fixture "$T/h" "$PROJECT"
  cp "$T/stub.sh" "$T/h/bin/stub.sh"
  for b in beat.sh deploy-request.sh merge-queue.sh; do printf '#!/bin/bash\nexit 0\n' > "$T/h/bin/$b"; chmod +x "$T/h/bin/$b"; done
  printf '{}\n' > "$STATE"
}
calls()   { [ -f "$T/agent-calls.log" ] && wc -l < "$T/agent-calls.log" | tr -d ' ' || echo 0; }
st()      { jq -r --arg n "$NUM" ".[\$n].$1 // \"\"" "$STATE" 2>/dev/null; }
run_lane() {
  ( export PATH="$T/fakebin:$PATH" HARNESS="$T/h" FLEET_CONF="$DIR/fleet.conf" TEST_ROOT="$T" \
      REPOS_ROOT="${1:-$T/repos}" BASH_ENV="$T/h/bin/stub.sh"
    unset JOB_ID JOB_BEAT JOB_INFLIGHT JOB_REFUSED
    bash "$RP" "$PROJECT" >/dev/null 2>&1 )
}
set_head() { printf '%s\t%s\texternaldev\tTest PR\n' "$NUM" "$1" > "$T/prs.tsv"; }

# The git side: a bare remote, a work clone, the hub checkout under REPOS_ROOT.
W="$T/work"
w() { git -C "$W" "$@"; }
edit() { sed -i.bak "${1}s/.*/$2/" "$W/f.txt" && rm -f "$W/f.txt.bak"; }
commit() { w add -A; w commit -qm "$1"; w rev-parse HEAD; }
push() { w push -q -f origin "$@" >/dev/null 2>&1; }
fixture() {
  scratch_rm "$T/remote.git" 2>/dev/null; scratch_rm "$W" 2>/dev/null; scratch_rm "$T/repos" 2>/dev/null
  git init -q --bare -b main "$T/remote.git"
  git init -q -b main "$W"; w remote add origin "$T/remote.git"
  seq 1 30 | sed 's/^/line /' > "$W/f.txt"; commit base >/dev/null; push main
  w checkout -qb pr; edit 10 'line 10 CHANGED BY PR'; R=$(commit pr-change); push pr
  mkdir -p "$T/repos"; git clone -q "$T/remote.git" "$T/repos/$PROJECT"
}
main_merge() { # main edits line 13 (in the PR hunk's context), the PR merges main
  w checkout -q main; edit 13 'line 13 EDITED ON MAIN'; commit m >/dev/null; push main
  w checkout -q pr; w merge -q --no-edit main >/dev/null 2>&1; push pr; w rev-parse HEAD
}

# ---- A1..A3
fresh_harness; fixture
set_head "$R"; run_lane
[ "$(calls)" = 1 ] && ok || bad "A1 the first head must buy exactly 1 review, got $(calls)"
[ "$(st sha)" = "$R" ] && [ "$(st verdict)" = APPROVE ] && ok || bad "A1 state: $(cat "$STATE")"

H=$(main_merge); set_head "$H"; rm -f "$T/gh-writes.log"; run_lane
[ "$(calls)" = 1 ] && ok || bad "A2 a main-merge-only head must buy NO review (0 new agent calls), got $(( $(calls) - 1 )) new"
[ "$(st sha)" = "$H" ] && ok || bad "A2 the verdict must now sit on the new head: $(cat "$STATE")"
[ "$(st verdict)" = APPROVE ] && ok || bad "A2 the verdict must be the same one (APPROVE): $(st verdict)"
[ "$(st replayed_from)" = "$R" ] && [ "$(st replay_how)" = main-merge ] && ok || bad "A2 the replay must be recorded: $(cat "$STATE")"
grep -qxF "https://github.com/$SLUG/pull/$NUM $H" "$T/rebinds.log" 2>/dev/null && ok || bad "A2 the ledger verdict must be rebound onto $H: $(cat "$T/rebinds.log" 2>/dev/null)"
[ ! -s "$T/gh-writes.log" ] && ok || bad "A2 a replay must post and dismiss nothing on GitHub: $(cat "$T/gh-writes.log")"
grep -q "verdict REPLAYED from ${R:0:7} (APPROVE): own patch unchanged (main-merge)" "$T/h/logs/"*review* 2>/dev/null && ok \
  || bad "A2 the log must say it replayed: $(cat "$T/h/logs/"*review* 2>/dev/null | tail -2)"

edit 20 'line 20 REAL FIX'; H2=$(commit fix); push pr; set_head "$H2"; run_lane
[ "$(calls)" = 2 ] && ok || bad "A3 a real change must buy exactly 1 new review, got $(( $(calls) - 1 )) new"
[ "$(st sha)" = "$H2" ] && [ -z "$(st replayed_from)" ] && ok || bad "A3 the reviewed head is the new one, not a replay: $(cat "$STATE")"

# ---- A4: REQUEST_CHANGES replays as REQUEST_CHANGES
fresh_harness; fixture
echo REQUEST_CHANGES > "$T/verdict"
set_head "$R"; run_lane
[ "$(calls)" = 1 ] && [ "$(st verdict)" = REQUEST_CHANGES ] && ok || bad "A4 setup: calls=$(calls) $(cat "$STATE")"
H=$(main_merge); set_head "$H"; run_lane
[ "$(calls)" = 1 ] && [ "$(st sha)" = "$H" ] && [ "$(st verdict)" = REQUEST_CHANGES ] && ok \
  || bad "A4 an unchanged patch keeps REQUEST_CHANGES with no new call: calls=$(calls) $(cat "$STATE")"

# ---- A5: no checkout here -> nothing is proved, the review is bought
fresh_harness; fixture
set_head "$R"; run_lane
H=$(main_merge); set_head "$H"; run_lane "$T/no-repos"
[ "$(calls)" = 2 ] && [ -z "$(st replayed_from)" ] && ok \
  || bad "A5 with no checkout the moved head must be reviewed (fail closed): calls=$(calls) $(cat "$STATE")"

echo "review-prs-replay.bh-2310: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
