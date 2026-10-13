#!/bin/bash
# tests/br-stacked-fixround.bh-5796-test.sh — BH-5796: a stacked child's fix
# round merges ITS OWN BASE (the parent branch), not main, and re-renders the
# repo's generated files as the round's last step.
#
# WHY. The conductor now parks a stacked child conflict-unresolvable when its
# parent's new tip conflicts (tests/mc-stack-parent-moved.bh-5796-test.sh M3).
# The round used to merge origin/main whatever the base: main's diff rode into
# a PR read against the parent, and the parent's change stayed unmerged. And a
# hand-resolved conflict can leave a generated file stale against its sources.
#
#   F1  the round merges origin/ticket/TK-80 (the PR's base): the brief names
#       it, the pushed head carries the parent's tip and NOT main's commit
#   F2  the round's last commit re-renders gen/sum.txt from the merged tree
#       (the repo's "Generated files" table, read from the base)
#   F3  a PR on main: the brief still merges origin/main (unchanged)
#
# Drives the REAL script through `--fix-here`, the way bin/fix-round-claim.sh
# runs it, over the fx_br_ladder_git origin.
# Run from anywhere: tests/br-stacked-fixround.bh-5796-test.sh   (exit 0 = all pass)
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
for lib in bin/lib/hub-box.sh bin/lib/heartbeat.sh bin/lib/lane-gate.sh; do
  scratch_install_closure "$lib" "$H" >/dev/null || { echo "FAIL: closure of $lib"; exit 1; }
done
. "$DIR/tests/lib/model-route-stub.sh" || exit 1
mrs_fixture "$H" tproj
[ -f "$DIR/bin/lib/mc/rebase.sh" ] || exit 1   # impact: mc_regen_generated lives here
[ -d "$DIR/bin/lib/br" ] || exit 1   # impact: this suite runs when bin/lib/br/ changes
fx_br_ladder_git "$DIR" "$T" || exit 1

# ── the stack: parent ticket/TK-80 off the root (it declares a generated file),
# child ticket/TK-81 cut from it, then the parent moves on the child's line.
S="$T/seed"
git -C "$S" checkout -q main
git -C "$S" checkout -q -b ticket/TK-80 "$(git -C "$S" rev-list --max-parents=0 HEAD)"
mkdir -p "$S/docs/verification-map/index" "$S/gen"
printf '## Generated files\n\n| path | command |\n|---|---|\n| `gen/sum.txt` | `sh gen.sh` |\n' > "$S/docs/verification-map/index/tail.md"
printf 'mkdir -p gen\ncksum < a.txt > gen/sum.txt\n' > "$S/gen.sh"
( cd "$S" && sh gen.sh )
git -C "$S" add -A; git -C "$S" commit -qm "parent: a generated file"; git -C "$S" push -q origin ticket/TK-80
git -C "$S" checkout -q -b ticket/TK-81
printf 'the child changed this line\n' >> "$S/a.txt"
git -C "$S" commit -qam "child work"; git -C "$S" push -q origin ticket/TK-81
git -C "$S" checkout -q ticket/TK-80
printf 'the parent changed this line\n' >> "$S/a.txt"
git -C "$S" commit -qam "parent moves"; git -C "$S" push -q origin ticket/TK-80
git -C "$T/repos/tproj" fetch -q origin

cat > "$H/bin/agent-call.sh" <<AGENT
#!/bin/bash
printf '%s\n' "\$*" >> "$T/agent.txt"
printf '%s' "\$6" > "$T/prompt.txt"
printf 'both sides, resolved\n' > a.txt
git add -A >/dev/null 2>&1
git commit -q -m "fix round: resolved the merge" >/dev/null 2>&1
exit 0
AGENT
chmod +x "$H/bin/agent-call.sh"

PR91="https://github.com/o/tproj/pull/91"
LOGF="$H/logs/blocked-resolver.log"
FIXHERE() { ( HARNESS="$H" FLEET_CONF="$H/fleet.conf" REPOS_ROOT="$T/repos" BOX_NAME=box-tproj \
              bash "$H/bin/blocked-resolver.sh" --fix-here tproj sfr-1 conflict-unresolvable "$PR91" - - < "$T/rec-in.json" ) >>"$T/run.log" 2>&1; }
RESET() { # RESET <branch> <base>
  scratch_rm "$H/state/blocked-resolver"; scratch_rm "$H/tmp/brfix"
  : > "$LOGF"; : > "$T/agent.txt"; rm -f "$T/prompt.txt"
  git -C "$T/repos/tproj" worktree prune >/dev/null 2>&1
  git -C "$T/repos/tproj" for-each-ref --format='%(refname:short)' refs/heads/brfix/ \
    | while read -r b; do git -C "$T/repos/tproj" branch -D "$b" >/dev/null 2>&1; done
  printf '%s\n' "$1" > "$T/prbranch"; osha "$1" | tr -d '\n' > "$T/prhead"; printf '%s\n' "$2" > "$T/prbase"
  printf 'conductor: conflict-unresolvable\n' > "$T/findings"
  jq -nc '{project:"tproj",rkey:"sfr-1",fixrounds:0,rebuilds:0,mechanicals:1,outcome:"",attempts:[]}' > "$T/rec-in.json"
}

# ── F1 / F2: the stacked child
RESET ticket/TK-81 ticket/TK-80
PTIP=$(osha ticket/TK-80); MTIP=$(osha main); C0=$(osha ticket/TK-81)
FIXHERE
[ -s "$T/prompt.txt" ] && ok || bad "F1: the round never reached the agent (log: $(tail -4 "$LOGF"))"
grep -qF 'THE MERGE OF origin/ticket/TK-80' "$T/prompt.txt" 2>/dev/null && ok || bad "F1: the brief must name the merge of origin/ticket/TK-80"
grep -qF 'THE MERGE OF origin/main' "$T/prompt.txt" 2>/dev/null && bad "F1: a stacked child's round must not merge origin/main" || ok
NEW=$(osha ticket/TK-81)
[ "$NEW" != "$C0" ] && ok || bad "F1: the round must push (log: $(tail -4 "$LOGF"))"
git -C "$T/origin.git" merge-base --is-ancestor "$PTIP" "$NEW" 2>/dev/null && ok || bad "F1: the pushed head must carry the parent's tip ${PTIP:0:8}"
git -C "$T/origin.git" merge-base --is-ancestor "$MTIP" "$NEW" 2>/dev/null && bad "F1: main's commit must NOT ride into a stacked child" || ok
case "$(git -C "$T/origin.git" log -1 --format=%s "$NEW" 2>/dev/null)" in
  "regenerate gen/sum.txt"*) ok ;; *) bad "F2: the round's last commit must re-render gen/sum.txt (got '$(git -C "$T/origin.git" log -1 --format=%s "$NEW" 2>/dev/null)')" ;;
esac
WANT=$(git -C "$T/origin.git" show "$NEW:a.txt" 2>/dev/null | cksum)
[ "$(git -C "$T/origin.git" show "$NEW:gen/sum.txt" 2>/dev/null)" = "$WANT" ] && ok || bad "F2: gen/sum.txt must match the resolved a.txt"

# ── F3: a PR on main is unchanged
RESET ticket/TK-88 main
FIXHERE
grep -qF 'THE MERGE OF origin/main' "$T/prompt.txt" 2>/dev/null && ok || bad "F3: a PR on main still merges origin/main (log: $(tail -3 "$LOGF"))"

echo "br-stacked-fixround.bh-5796: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
