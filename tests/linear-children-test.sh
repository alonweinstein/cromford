#!/bin/bash
# tests/linear-children-test.sh — a Linear project's split files its children
# as Linear sub-issues (bin/lib/fc-linear.sh), in order, and a child waits for
# the ones that block it; the master closes when its last child does.
#
#   L1  file_children reaches the linear lane: one sub-issue per child under the
#       parent, with the build label, the `.0 contract` / `.n` titles and the
#       footer lines; the contract blocks every sibling, `after` adds a sibling
#   L2  the master: one comment naming the children, the build label off
#   L3  a rerun files nothing and says nothing twice
#   L4  a child created by a run that died before recording it is adopted by
#       its id, never filed twice
#   L5  rollout: waves blocked only by the waves `after` names
#   L6  a dry run sends no write; no build label for the team files nothing
#   L7  bin/triage-gate.sh --buildable: an open blocker is BLOCKED dependencies,
#       a completed one is OK, an issue with no relation is OK
#   L8  bin/run-decompose.sh takes the linear lane (no `gh issue create`)
#   L9  the master closes once every child is done, not before
#
# No network: a `curl` stub plays api.linear.app/graphql and the settings route.
#   HARNESS_TEST_SANDBOX=1 bash tests/linear-children-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null 2>&1 || { echo "jq missing — skipping"; exit 0; }

LKEY=tok-FIXTURE-SENTINEL-4082
S="$T/ls"
mkdir -p "$T/h/bin/lib" "$T/h/env" "$T/h/logs" "$T/h/state" "$T/stub" "$S"
cp -R "$DIR/bin/lib/." "$T/h/bin/lib/"
cp "$DIR/bin/fleet-conf.sh" "$DIR/bin/jobs-client.sh" "$T/h/bin/"
cat > "$T/h/fleet.conf" <<'CONF'
# <project> <repo> <prod> <board-api-prefix> <offset>
linproj  example-org/lin  https://lin.example  -  9
CONF
export HARNESS="$T/h" FLEET_CONF="$T/h/fleet.conf" PATH="$T/stub:$PATH"
export HARNESS_SECRET=fixture-secret JOBS_URL=https://jobs.example JOBS_RETRIES=0 JOBS_TIMEOUT=5
export TL_STATE="$S" TL_KEY_EXPECT="$LKEY" TL_FIX="$DIR/tests/fixtures/tracker-linear"
PARENT_ID=00000000-0000-0000-0000-100000000001
TEAM_ID=00000000-0000-0000-0000-c00000000001
LABEL_ID=00000000-0000-0000-0000-b00000000001

. "$DIR/tests/lib/linear-children-stub.sh" || exit 1
export PARENT_ID TEAM_ID PARENT_LABEL="$LABEL_ID"
row() { jq -n --arg k "$1" --arg v "$2" '{setting:{key:$k,value:$v}}' > "$S/setting-$1"; }
printf 'LINEAR_API_KEY=%s\n' "$LKEY" > "$T/h/env/linproj.env"
row tracker_adapter.linproj linear
row tracker_linear.linproj.team CRO
DONE=00000000-0000-0000-0000-500000000007
reset() { rm -rf "$T/b" "$S"/reqs "$S"/created "$S"/rels "$S"/next "$S"/create-* "$S"/comment-body "$S"/gh.log "$S"/nolabel "$S"/blocker; mkdir -p "$T/b"; }
nreq() { grep -c "^$1" "$S/reqs" 2>/dev/null; }
SPEC='[
 {"title":"ledger table","contract":"src/ledger.ts: LedgerRow","after":[],"body":"The table.\n\n## Observable outcome\nA row is written."},
 {"title":"export button","after":[1],"body":"The button.\n\n## Observable outcome\nThe file downloads."},
 {"title":"export email","after":[2],"body":"The email.\n\n## Observable outcome\nThe email arrives."}
]'
file() { # file <kind> [env…] — file_children in a subshell, the way the lanes call it
  local k="$1"; shift
  printf '%s\n' "$SPEC" > "$T/b/children.json"
  ( export "$@" 2>/dev/null; . "$T/h/bin/lib/file-children.sh"
    file_children linproj CRO-1 CRO-1 "$T/b" "$T/b/children.json" --kind "$k"; echo "rc=$? ${FC_ERROR:-}" ) > "$T/out" 2>&1
}

# --- L1 ---------------------------------------------------------------------
reset; file decompose
grep -q '^rc=0' "$T/out" && [ "$(nreq TrkChildCreate)" = 3 ] && ok || bad "L1 three sub-issues filed: $(cat "$T/out") / $(cat "$S/reqs" 2>/dev/null)"
[ "$(paste -sd, "$T/b/children.txt" 2>/dev/null)" = "CRO-20,CRO-21,CRO-22" ] && ok || bad "L1 children.txt: $(cat "$T/b/children.txt" 2>/dev/null)"
C0="$S/create-CRO-20.json"; C2="$S/create-CRO-22.json"
jq -e --arg p "$PARENT_ID" --arg t "$TEAM_ID" --arg l "$LABEL_ID" '.parentId == $p and .teamId == $t and .labelIds == [$l] and .priority == 2' "$C0" >/dev/null 2>&1 \
  && ok || bad "L1 parent, team, label and priority: $(cat "$C0" 2>/dev/null)"
[ "$(jq -r .title "$C0")" = "CRO-1.0: contract — ledger table" ] && [ "$(jq -r .title "$C2")" = "CRO-1.2: export email" ] && ok \
  || bad "L1 titles: $(jq -r .title "$S"/create-*.json 2>/dev/null)"
jq -r .description "$C2" | grep -q '^Part of #CRO-1$' && jq -r .description "$C2" | grep -q '^Blocked-by: CRO-20 (hard), CRO-21 (hard)$' \
  && jq -r .description "$C0" | grep -q '^CONTRACT: src/ledger.ts: LedgerRow$' && ok || bad "L1 footers: $(jq -r .description "$C2")"
[ "$(grep -c ' blocks ' "$S/rels")" = 3 ] && grep -q 'CRO-20 blocks CRO-21' "$S/rels" && grep -q 'CRO-20 blocks CRO-22' "$S/rels" \
  && grep -q 'CRO-21 blocks CRO-22' "$S/rels" && ok || bad "L1 relations: $(cat "$S/rels" 2>/dev/null)"

# --- L2 ---------------------------------------------------------------------
[ "$(nreq TrkComment)" = 1 ] && grep -q '1. CRO-20: ledger table' "$S/comment-body" && grep -q "^TrkRemoveLabel $LABEL_ID" "$S/reqs" && ok \
  || bad "L2 the master is commented and unlabelled: $(cat "$S/reqs") / $(cat "$S/comment-body" 2>/dev/null)"
[ ! -e "$S/gh.log" ] && ok || bad "L2 GitHub was asked: $(cat "$S/gh.log")"

# --- L3 ---------------------------------------------------------------------
: > "$S/reqs"; file decompose
grep -q '^rc=0' "$T/out" && [ "$(nreq TrkChildCreate)" = 0 ] && [ "$(nreq TrkComment)" = 0 ] && ok || bad "L3 a rerun files and says nothing: $(cat "$S/reqs")"

# --- L4 ---------------------------------------------------------------------
# The run died after creating child 2, before recording it.
head -1 "$T/b/children.txt" > "$T/b/c1"; mv "$T/b/c1" "$T/b/children.txt"; : > "$S/reqs"
file decompose
grep -q '^rc=0' "$T/out" && [ "$(nreq 'TrkChildCreate ')" = 0 ] && [ "$(nreq TrkChildFind)" = 2 ] \
  && [ "$(paste -sd, "$T/b/children.txt")" = "CRO-20,CRO-21,CRO-22" ] && [ "$(wc -l < "$S/created")" = 3 ] && ok \
  || bad "L4 an unrecorded child is adopted, not re-filed: $(cat "$T/out") / $(cat "$S/reqs")"

# --- L5 ---------------------------------------------------------------------
reset; SPEC='[{"title":"a","after":[],"body":"One."},{"title":"b","after":[],"body":"Two."},{"title":"c","after":[1],"body":"Three."}]'
file rollout
grep -q '^rc=0' "$T/out" && [ "$(jq -r .title "$S/create-CRO-20.json")" = "CRO-1.1: a" ] && [ "$(grep -c ' blocks ' "$S/rels")" = 1 ] \
  && grep -q 'CRO-20 blocks CRO-22' "$S/rels" && ok || bad "L5 rollout waves: $(cat "$T/out") / $(cat "$S/rels" 2>/dev/null)"

# --- L6 ---------------------------------------------------------------------
reset; file decompose DECOMPOSE_DRY_RUN=1 RB_LINEAR=1
grep -q '^rc=0' "$T/out" && ! grep -qE '^Trk(ChildCreate|Relate|Comment|RemoveLabel)' "$S/reqs" 2>/dev/null \
  && grep -q 'issueCreate' "$T/b/decompose-linear.log" && ok || bad "L6 a dry run writes nothing: $(cat "$S/reqs" 2>/dev/null) / $(cat "$T/out")"
reset; : > "$S/nolabel"; file decompose
grep -q '^rc=1.*no single label' "$T/out" && [ "$(nreq TrkChildCreate)" = 0 ] && ok || bad "L6 no build label files nothing: $(cat "$T/out")"

# --- L7 ---------------------------------------------------------------------
GATE="$DIR/bin/triage-gate.sh"
reset; echo started > "$S/blocker"
[ "$("$GATE" linproj --buildable CRO-21)" = "BLOCKED dependencies CRO-20" ] && ok || bad "L7 open blocker: $("$GATE" linproj --buildable CRO-21)"
echo completed > "$S/blocker"
[ "$("$GATE" linproj --buildable CRO-21)" = OK ] && ok || bad "L7 a done blocker: $("$GATE" linproj --buildable CRO-21)"
rm -f "$S/blocker"
[ "$("$GATE" linproj --buildable CRO-21)" = OK ] && ok || bad "L7 no relation: $("$GATE" linproj --buildable CRO-21)"

# --- L8 ---------------------------------------------------------------------
. "$DIR/tests/lib/model-route-stub.sh" || exit 1; model_routes_fixture "$T/h" linproj || exit 1
cp "$DIR/bin/run-decompose.sh" "$T/h/bin/"
printf '#!/bin/bash\necho "AGENT CALL" >> "$TL_STATE/agent.log"\nexit 0\n' > "$T/h/bin/agent-call.sh"; chmod +x "$T/h/bin/agent-call.sh"
reset; SPEC='[{"title":"ledger table","contract":"src/ledger.ts: LedgerRow","after":[],"body":"The table.\n\n## Observable outcome\nA row is written."},{"title":"export button","after":[1],"body":"The button.\n\n## Observable outcome\nThe file downloads."}]'
printf '%s\n' "$SPEC" > "$T/b/children.json"
printf 'SIZE_DECLARED: files=18 lines=1900\nSIZE_OVER: lines=1900>300\nSIZE_VERDICT: over\n' > "$T/b/size-gate.txt"
RB_LINEAR=1 DECOMPOSE_DRY_RUN=1 "$T/h/bin/run-decompose.sh" linproj CRO-1 CRO-1 "$T/b" 300 12 > "$T/out" 2>&1; rc=$?
[ "$rc" = 0 ] && grep -q 'decompose lane: Linear sub-issues of CRO-1' "$T/b/pipeline.log" && [ "$(grep -c 'DRYRUN linear graphql issueCreate' "$T/out")" = 2 ] \
  && ! grep -q 'gh issue' "$T/out" && ok || bad "L8 run-decompose takes the linear lane (rc=$rc): $(tail -5 "$T/out") / $(tail -3 "$T/b/pipeline.log" 2>/dev/null)"

# --- L9 ---------------------------------------------------------------------
# The stub answers every issue read with one fixture, so the master's move is
# the second `done` after the child's own.
. "$T/h/bin/lib/linear-build.sh"
po() { jq -n --arg s "$1" '{data:{issue:{parent:{identifier:"CRO-1",team:{key:"CRO"},state:{type:"started"},
  children:{nodes:[{identifier:"CRO-20",state:{type:"completed"}},{identifier:"CRO-21",state:{type:$s}}],pageInfo:{hasNextPage:false}}}}}}' > "$S/parentof"; }
reset; rm -f "$T/h/state"/linear-merged-*; po started
lb_close_merged linproj CRO-20 https://github.com/example-org/lin/pull/5 x >/dev/null 2>&1
grep -q '^TrkParentOf CRO-20' "$S/reqs" && [ "$(nreq TrkUpdate)" = 1 ] && ok || bad "L9 an open sibling keeps the master open: $(cat "$S/reqs")"
reset; po completed
lb_close_merged linproj CRO-21 https://github.com/example-org/lin/pull/6 x >/dev/null 2>&1
[ "$(nreq "TrkUpdate .* $DONE")" = 2 ] && grep -q 'Every part of this split has landed (the last was CRO-21)' "$S/comment-body" && ok \
  || bad "L9 the last child closes the master: $(cat "$S/reqs")"

LEAK=$(grep -rlF -- "$LKEY" "$S" "$T/b" "$T/h/logs" "$T/out" 2>/dev/null)
[ -z "$LEAK" ] && ok || bad "the key reached: $LEAK"

echo "linear-children: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
