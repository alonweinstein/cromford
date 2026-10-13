#!/bin/bash
# tests/blocked-resolver-author.bh-1134-test.sh — THE FIX ROUND COMMITS AS THE
# CONFIGURED AUTHOR, AND REFUSES TO PUSH ANYTHING ELSE (BH-1134).
#
# THE INCIDENT. project-5 PR #2708's fix-round commit 0cad3b30 was authored AND
# committed as `Claude Fable 5.1 <noreply@anthropic.com>`, while every build
# commit is the box's configured identity. The repo's ruleset requires author ==
# pusher, so the head was dequeued. The build lane never had the problem because
# it squashes (re-authoring everything with the global config); the fix round
# never squashes, so whatever identity the agent picked was what shipped.
#
# DRIVEN, NOT GREPPED. The real bin/blocked-resolver.sh runs a real fix round on
# tests/lib/fixture-harness.sh's local git (a bare "remote", branches that
# genuinely conflict with main). Only the agent is a stub, and each case makes it
# commit under a different foreign identity. The assertions read the commits that
# landed on the bare origin, never the lane's source.
#
#   a. the agent commits with `git -c user.name/-c user.email` Fable → the pin
#      wins: the pushed head is authored AND committed as the global identity
#   b. the agent commits with `--author=Fable` (the one thing the pin cannot
#      beat) → refused: nothing pushed, AUTHOR_MISMATCH recorded, the checkpoint
#      branch dropped, the round counted
#   c. bin/lib/git-identity.sh absent → the guard cannot run, so nothing is
#      pushed (fail CLOSED: a push without the check is the bug)
#   d. committer-only mismatch (author right, committer Fable) → refused
#
# Run from anywhere: HARNESS_TEST_SANDBOX=1 tests/blocked-resolver-author.bh-1134-test.sh
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
cp "$DIR/bin/blocked-resolver.sh" "$DIR/bin/fly-pool.sh" "$DIR/bin/merge-sweep.sh" \
   "$DIR/bin/merge-conductor.sh" "$DIR/bin/fleet-conf.sh" "$DIR/bin/project-of.sh" \
   "$DIR/bin/box-for.sh" "$H/bin/" || exit 1
fx_br_harness "$DIR" "$T" || exit 1
. "$DIR/tests/lib/model-route-stub.sh" || exit 1
mrs_fixture "$H" tproj
[ -d "$DIR/bin/lib/br" ] || exit 1   # impact: this suite runs when bin/lib/br/ changes
fx_br_ladder_git "$DIR" "$T" || exit 1

# THE CONFIGURED IDENTITY is the box's global git config. It is deliberately NOT
# the t@t the fixture's repos carry in their LOCAL config: the local config is
# the one an agent can poison, and the lane must not read it as "configured".
WANT=builder@box.test
export GIT_CONFIG_GLOBAL="$T/gitconfig-bh1134"
git config --file "$GIT_CONFIG_GLOBAL" user.name operator
git config --file "$GIT_CONFIG_GLOBAL" user.email "$WANT"

# The agent: resolves the real conflict in its cwd (the fix-round worktree) and
# commits it the way $T/agent-mode says.
cat > "$H/bin/agent-call.sh" <<EOF
#!/bin/bash
printf 'both sides, resolved\n' > a.txt
git add -A >/dev/null 2>&1
case "\$(cat "$T/agent-mode")" in
  cfg)       git -c user.name="Claude Fable 5.1" -c user.email=noreply@anthropic.com commit -q -m "fix round" >/dev/null 2>&1 ;;
  author)    git commit -q --author="Claude Fable 5.1 <noreply@anthropic.com>" -m "fix round" >/dev/null 2>&1 ;;
  committer) GIT_COMMITTER_NAME="Claude Fable 5.1" GIT_COMMITTER_EMAIL=noreply@anthropic.com git commit -q -m "fix round" >/dev/null 2>&1 ;;
  plain)     git commit -q -m "fix round" >/dev/null 2>&1 ;;
esac
exit 0
EOF
chmod +x "$H/bin/agent-call.sh"
: > "$T/failedruns"; : > "$T/joblog"
printf 'Head-bound harness re-review: BLOCK. Finding: the route is unauthenticated.\n' > "$T/findings"

# case <n> <mode> — one head-not-reapproved park on ticket/ts-<n>, which conflicts
# with main on a.txt, so the round has a real merge for the agent to commit.
case_run() {
  local n="$1" mode="$2"
  printf '%s' "$mode" > "$T/agent-mode"
  printf 'ticket/ts-%s\n' "$n" > "$T/prbranch"; osha "ticket/ts-$n" > "$T/prhead"
  mkdir -p "$H/state/blocked-resolver/tproj"
  jq -nc --arg k "tproj-TK-$n" '{project:"tproj",rkey:$k,mechanicals:1,fixrounds:0,rebuilds:0,outcome:"",attempts:[]}' \
    > "$H/state/blocked-resolver/tproj/tproj-TK-$n.json"
  ROW "o/tproj#$n" "head-not-reapproved" "https://github.com/o/tproj/pull/$n"
  : > "$H/logs/blocked-resolver.log"
  RUN
}
VERIFY() { cat "$H/state/blocked-resolver/tproj/tproj-TK-$1.fix-verify.txt" 2>/dev/null; }
refused() { # refused <n> <before-sha> <label> <marker>
  local n="$1" before="$2" L="$3" m="$4"
  grep -q 'FIX ROUND pushed' "$H/logs/blocked-resolver.log" \
    && bad "$L: a foreign-authored round must not push (log: $(grep 'FIX ROUND' "$H/logs/blocked-resolver.log"))" || ok
  [ "$(osha "ticket/ts-$n")" = "$before" ] && ok \
    || bad "$L: the PR branch moved on origin ($(git -C "$ORIGIN" log -1 --format='%h %ae %ce' "ticket/ts-$n"))"
  VERIFY "$n" | grep -q "^$m" && ok \
    || bad "$L: fix-verify.txt must record $m (got: $(VERIFY "$n" | tail -3))"
  git -C "$T/repos/tproj" rev-parse --verify -q "brfix/tproj-TK-$n" >/dev/null 2>&1 \
    && bad "$L: the foreign-authored checkpoint brfix/tproj-TK-$n must be dropped, not reused" || ok
  [ "$(STATEJSON "tproj-TK-$n" | jq -r .fixrounds)" = 1 ] && ok \
    || bad "$L: the refused round must be counted like any failed round (fixrounds=$(STATEJSON "tproj-TK-$n" | jq -r .fixrounds))"
}

echo "== a. the agent's -c user.* identity loses to the pin =="
B=$(osha ticket/TK-88)
case_run 88 cfg
grep -q 'FIX ROUND pushed' "$H/logs/blocked-resolver.log" && ok \
  || bad "a: a round committed under the pin must push (log: $(tail -4 "$H/logs/blocked-resolver.log"))"
[ "$(osha ticket/TK-88)" != "$B" ] && ok || bad "a: the PR branch did not move on origin"
IDS=$(git -C "$ORIGIN" log --format='%ae %ce' ticket/TK-88 --not "$B" main | sort -u)
[ "$IDS" = "$WANT $WANT" ] && ok \
  || bad "a: every commit the round pushed must be authored+committed as $WANT (got: $(tr '\n' ';' <<<"$IDS"))"
grep -q 'noreply@anthropic.com' <<<"$IDS" && bad "a: a Fable identity reached origin" || ok

echo "== b. an explicit --author is refused =="
B=$(osha ticket/TK-89)
case_run 89 author
refused 89 "$B" b AUTHOR_MISMATCH
VERIFY 89 | grep -q 'noreply@anthropic.com' && ok \
  || bad "b: the mismatch line must name the offending identity (got: $(VERIFY 89 | tail -2))"
grep -q "$WANT" "$H/logs/blocked-resolver.log" && ok \
  || bad "b: the lane's log line must name the expected email"

echo "== c. no identity lib → no check → no push =="
mv "$H/bin/lib/git-identity.sh" "$T/git-identity.sh.away" 2>/dev/null
B=$(osha ticket/TK-94)
case_run 94 plain
refused 94 "$B" c 'AUTHOR_CHECK: could-not-run'
mv "$T/git-identity.sh.away" "$H/bin/lib/git-identity.sh" 2>/dev/null

echo "== d. a foreign committer is refused even when the author is right =="
B=$(osha ticket/TK-95)
case_run 95 committer
refused 95 "$B" d AUTHOR_MISMATCH

echo
echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
