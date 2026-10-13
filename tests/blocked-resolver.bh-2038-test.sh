#!/bin/bash
# tests/blocked-resolver.bh-2038-test.sh — BH-2038: the BH-594 follow-ups.
#
# THE DEFECTS. `blocked-resolver.sh --fix-here` skipped the lane gate, so a box
# an operator had switched off (flags/all-off, lane-off-blocked-resolver[-<p>])
# still ran a hub-sent fix round. With blocked-resolver-disabled it exited with
# no FIX_RESULT at all, which the hub recorded as a fix-round-blocked attempt
# and paged.
#
# Every case drives the REAL script: the owning box's `--fix-here` entry exactly
# as bin/fix-round-claim.sh invokes it. Assertions are on stdout protocol lines,
# the record JSON, and the agent/worktree/remote state.
#
# Cases:
#   1-4   every box pause flag answers exactly one FIX_RESULT box-paused, runs nothing
#   5     flags that must NOT pause a round
# Cases 6-12 pinned the hub's ssh hop: its bound (FIX_LANE_TIMEOUT +
# BR_FIX_HOP_MARGIN) and its re-read of the box's record after a hop that came
# back with none. BH-2674 removed the hop, so they were deleted
# (docs/notes/2026-09-26-BH-2530-fix-round-queue.md). The hub reading
# box-paused as nothing spent is tests/fix-round-hub-restart.bh-2530-test.sh
# N5; the re-read is the claimer's re-offer guard,
# tests/fix-round-claim.bh-2530-test.sh.
# Run from anywhere: tests/blocked-resolver.bh-2038-test.sh   (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }

# shellcheck source=tests/lib/fixture-harness.sh
. "$DIR/tests/lib/fixture-harness.sh" || exit 1
H="$T/h"
mkdir -p "$H/bin"
# The scripts this suite drives. The copy stays HERE so bin/test-impact.sh
# selects this suite when one of them changes.
cp "$DIR/bin/blocked-resolver.sh" "$DIR/bin/fly-pool.sh" "$DIR/bin/merge-sweep.sh" \
   "$DIR/bin/merge-conductor.sh" "$DIR/bin/fleet-conf.sh" "$DIR/bin/project-of.sh" \
   "$DIR/bin/box-for.sh" "$H/bin/" || exit 1
fx_br_harness "$DIR" "$T" || exit 1
# The hub identity lib (the hop) and the lane gate (the box's off-switches):
# this suite is about exactly those two.
cp "$DIR/bin/lib/hub-box.sh" "$DIR/bin/lib/heartbeat.sh" "$DIR/bin/lib/lane-gate.sh" "$H/bin/lib/" || exit 1
. "$DIR/tests/lib/model-route-stub.sh" || exit 1
mrs_fixture "$H" tproj
[ -d "$DIR/bin/lib/br" ] || exit 1   # impact: this suite runs when bin/lib/br/ changes
fx_br_ladder_git "$DIR" "$T" || exit 1

# ---- stubs this suite owns ---------------------------------------------------
cat > "$H/bin/agent-call.sh" <<EOF
#!/bin/bash
printf '%s\n' "\$*" >> "$T/agent.txt"
if [ -f "$T/agent-resolves" ]; then
  printf 'the fix on %s\n' "\$(git rev-parse HEAD)" > fix.txt
  git add -A >/dev/null 2>&1
  git -c user.email=t@t -c user.name=t commit -q -m "fix round: answered the findings" >/dev/null 2>&1
fi
exit 0
EOF
chmod +x "$H/bin/agent-call.sh"
printf '#!/bin/bash\nprintf "%%s\\n" "$*" >> "%s/beat.txt"\nexit 0\n' "$T" > "$H/bin/beat.sh"
chmod +x "$H/bin/beat.sh"
FIXHERE() { ( HARNESS="$H" FLEET_CONF="$H/fleet.conf" REPOS_ROOT="$T/repos" BOX_NAME=box-tproj \
              bash "$H/bin/blocked-resolver.sh" --fix-here tproj o-tproj-91 head-not-reapproved "$PR91" - TK-91 < "$T/rec-in.json" ) 2>>"$T/run.log"; }
LOGF="$H/logs/blocked-resolver.log"
PR91="https://github.com/o/tproj/pull/91"
RECP="$H/state/blocked-resolver/tproj/tproj-TK-91.json"

RESET() {
  scratch_rm "$H/state/blocked-resolver"
  scratch_rm "$H/state/lane-gate"
  scratch_rm "$H/state/heartbeat"
  scratch_rm "$H/tmp/brfix"
  rm -f "$H/flags/all-off" "$H/flags/lane-off-"* "$H/flags/blocked-resolver-"* "$H/locks/blocked-resolver-cron.lock"
  : > "$LOGF"; : > "$H/logs/ALERTS.log"
  : > "$T/agent.txt"; : > "$T/beat.txt"; : > "$T/closed.txt"; : > "$T/queue.txt"
  : > "$T/lane-alert.txt"
  rm -f "$T/agent-resolves"
  git -C "$T/repos/tproj" worktree prune >/dev/null 2>&1
  git -C "$T/repos/tproj" branch -D brfix/tproj-TK-91 >/dev/null 2>&1
  printf 'ticket/TK-91\n' > "$T/prbranch"; osha ticket/TK-91 | tr -d '\n' > "$T/prhead"
  printf 'Head-bound harness re-review: BLOCK. Finding: the route is unauthenticated.\n' > "$T/findings"
  jq -nc '{project:"tproj",rkey:"tproj-TK-91",fixrounds:0,rebuilds:0,mechanicals:0,outcome:"",attempts:[]}' > "$T/rec-in.json"
}
REC() { cat "$RECP" 2>/dev/null || echo "{}"; }
WORKTREES() { git -C "$T/repos/tproj" worktree list --porcelain 2>/dev/null | grep -c '^worktree '; }

# ============================================================================
# 1-4. EVERY BOX PAUSE FLAG ANSWERS box-paused AND RUNS NOTHING
# ============================================================================
PAUSED() { # PAUSED <n> <flag> <reason-must-contain>
  local n="$1" flag="$2" want="$3" out r why wt0 sha0
  RESET; touch "$H/flags/$flag"; touch "$T/agent-resolves"
  wt0=$(WORKTREES); sha0=$(osha ticket/TK-91)
  out=$(FIXHERE)
  [ "$(grep -c '^FIX_RESULT ' <<<"$out")" = 1 ] && ok || bad "$n: exactly one FIX_RESULT line with $flag (stdout: $out; log: $(tail -3 "$LOGF"))"
  r=$(grep '^FIX_RESULT box-paused ' <<<"$out" | head -1)
  [ -n "$r" ] && ok || bad "$n: $flag must answer FIX_RESULT box-paused (stdout: $out)"
  why=$(printf '%s' "${r#FIX_RESULT box-paused }" | base64 -d 2>/dev/null)
  grep -qF -- "$want" <<<"$why" && ok || bad "$n: the decoded reason must name $want (got '$why')"
  grep -qx 'FIX_RESULT done' <<<"$out" && bad "$n: a paused box must not answer done" || ok
  [ -s "$T/agent.txt" ] && bad "$n: a paused box runs no agent ($(cat "$T/agent.txt"))" || ok
  [ "$(WORKTREES)" = "$wt0" ] && ok || bad "$n: a paused box adds no worktree"
  [ "$(osha ticket/TK-91)" = "$sha0" ] && ok || bad "$n: a paused box pushes nothing"
  [ -e "$RECP" ] && bad "$n: a paused box writes no record ($(REC))" || ok
}
PAUSED 1 all-off all-off
PAUSED 2 lane-off-blocked-resolver lane-off-blocked-resolver
PAUSED 3 lane-off-blocked-resolver-tproj lane-off-blocked-resolver-tproj
PAUSED 4 blocked-resolver-disabled blocked-resolver-disabled

# ============================================================================
# 5. NEGATIVES: flags that are NOT this box's off-switch for this project
# ============================================================================
for flag in lane-off-merge-conductor lane-off-blocked-resolver-otherproj ""; do
  RESET; touch "$T/agent-resolves"
  [ -n "$flag" ] && touch "$H/flags/$flag"
  out=$(FIXHERE)
  grep -q '^FIX_RESULT box-paused' <<<"$out" && bad "5[$flag]: must not answer box-paused ($out)" || ok
  grep -qx 'FIX_RESULT done' <<<"$out" && ok || bad "5[$flag]: the round runs and answers done (stdout: $out; log: $(tail -3 "$LOGF"))"
  [ -s "$T/agent.txt" ] && ok || bad "5[$flag]: the agent must run"
done
RESET; touch "$H/flags/blocked-resolver-observe"
out=$(FIXHERE)
grep -q '^FIX_RESULT box-paused' <<<"$out" && bad "5[observe]: observe mode is not box-paused ($out)" || ok
r=$(grep '^FIX_RESULT setup-blocked ' <<<"$out" | head -1)
printf '%s' "${r#FIX_RESULT setup-blocked }" | base64 -d 2>/dev/null | grep -q 'observe mode' && ok \
  || bad "5[observe]: observe mode stays setup-blocked naming observe mode (stdout: $out)"
[ -s "$T/agent.txt" ] && bad "5[observe]: observe mode runs no agent" || ok

echo "blocked-resolver.bh-2038: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
