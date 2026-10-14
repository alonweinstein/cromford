#!/bin/bash
# tests/linear-rollout-test.sh — bin/run-rollout.sh on a Linear project reads
# the ticket's `## Rollout` section from the Linear issue, never from GitHub
# issue #<n>, and files the waves as Linear sub-issues (bin/lib/fc-linear.sh).
#
#   R1  the body is the Linear issue's description; the waves are filed in
#       order, the second blocked by the first; nothing reaches `gh`
#   R2  a Linear read that fails is ROLLOUT_FAILED, with no GitHub fallback
#   R3  a GitHub-Issues project still reads its body with `gh issue view`
#
# No network: tests/lib/linear-children-stub.sh plays Linear and the settings route.
#   HARNESS_TEST_SANDBOX=1 bash tests/linear-rollout-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null 2>&1 || { echo "jq missing — skipping"; exit 0; }

LKEY=tok-FIXTURE-SENTINEL-4083
S="$T/ls"
mkdir -p "$T/h/bin/lib" "$T/h/env" "$T/h/logs" "$T/h/state" "$T/stub" "$S"
cp -R "$DIR/bin/lib/." "$T/h/bin/lib/"
cp "$DIR/bin/fleet-conf.sh" "$DIR/bin/jobs-client.sh" "$DIR/bin/run-rollout.sh" "$T/h/bin/"
cat > "$T/h/fleet.conf" <<'CONF'
# <project> <repo> <prod> <board-api-prefix> <offset>
linproj  example-org/lin  https://lin.example  -  9
ghp      example-org/ghp  https://gh.example   -  9
CONF
export HARNESS="$T/h" FLEET_CONF="$T/h/fleet.conf" PATH="$T/stub:$PATH"
export HARNESS_SECRET=fixture-secret JOBS_URL=https://jobs.example JOBS_RETRIES=0 JOBS_TIMEOUT=5
export TL_STATE="$S" TL_KEY_EXPECT="$LKEY" TL_FIX="$DIR/tests/fixtures/tracker-linear"
export PARENT_ID=00000000-0000-0000-0000-100000000001 TEAM_ID=00000000-0000-0000-0000-c00000000001 PARENT_LABEL=00000000-0000-0000-0000-b00000000001
. "$DIR/tests/lib/linear-children-stub.sh" || exit 1
row() { jq -n --arg k "$1" --arg v "$2" '{setting:{key:$k,value:$v}}' > "$S/setting-$1"; }
printf 'LINEAR_API_KEY=%s\n' "$LKEY" > "$T/h/env/linproj.env"
row tracker_adapter.linproj linear
row tracker_linear.linproj.team CRO
reset() { rm -rf "$T/b" "$S"/reqs "$S"/created "$S"/rels "$S"/next "$S"/create-* "$S"/gh.log; mkdir -p "$T/b"; }
printf '## Rollout\n### Wave: schema\nAdd the table.\n### Wave: backfill\nafter: schema\nFill it.\n' > "$S/body"

# --- R1 ---------------------------------------------------------------------
reset; "$T/h/bin/run-rollout.sh" linproj CRO-1 CRO-1 "$T/b" > "$T/out" 2>&1; rc=$?
[ "$rc" = 0 ] && grep -q '^TrkIssue CRO-1' "$S/reqs" && grep -q 'ROLLOUT_FILED 2' "$T/out" && ok \
  || bad "R1 the body comes from Linear and the waves are filed (rc=$rc): $(tail -3 "$T/out") / $(cat "$S/reqs" 2>/dev/null)"
[ "$(jq -r .title "$S/create-CRO-20.json" 2>/dev/null)" = "CRO-1.1: schema" ] && grep -q 'CRO-20 blocks CRO-21' "$S/rels" 2>/dev/null && ok \
  || bad "R1 wave titles and order: $(cat "$S/rels" 2>/dev/null)"
[ ! -e "$S/gh.log" ] && ok || bad "R1 GitHub was asked: $(cat "$S/gh.log")"

# --- R2 ---------------------------------------------------------------------
reset; mv "$T/h/env/linproj.env" "$T/h/env/off"; printf 'LINEAR_API_KEY=wrong-fixture\n' > "$T/h/env/linproj.env"
RB_LINEAR=1 "$T/h/bin/run-rollout.sh" linproj CRO-1 CRO-1 "$T/b" > "$T/out" 2>&1; rc=$?
[ "$rc" = 1 ] && grep -q 'ROLLOUT_FAILED body fetch failed' "$T/out" && [ ! -e "$S/gh.log" ] && ok \
  || bad "R2 a failed Linear read fails, no GitHub fallback (rc=$rc): $(cat "$T/out") / $(cat "$S/gh.log" 2>/dev/null)"
mv "$T/h/env/off" "$T/h/env/linproj.env"

# --- R3 ---------------------------------------------------------------------
reset; "$T/h/bin/run-rollout.sh" ghp 7 TK-7 "$T/b" > "$T/out" 2>&1
grep -q '^gh issue view 7 -R example-org/ghp' "$S/gh.log" 2>/dev/null && [ ! -s "$S/reqs" ] && ok \
  || bad "R3 a GitHub-Issues project reads GitHub: $(cat "$S/gh.log" 2>/dev/null) / $(cat "$S/reqs" 2>/dev/null)"

LEAK=$(grep -rlF -- "$LKEY" "$S" "$T/b" "$T/h/logs" "$T/out" 2>/dev/null)
[ -z "$LEAK" ] && ok || bad "the key reached: $LEAK"

echo "linear-rollout: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
