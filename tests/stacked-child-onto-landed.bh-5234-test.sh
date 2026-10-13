#!/bin/bash
. "$(dirname "$0")/lib/scratch.sh" || exit 1
# tests/stacked-child-onto-landed.bh-5234-test.sh — BH-5234: a stacked child
# whose parent was REWRITTEN after the child was cut is moved onto the landed
# parent by patch-id, carrying only its own commits.
#
# THE DEFECT THIS PINS (#5010 / #5053, 2026-10-07). Child #5053 was cut from
# parent commits 6da7eac3 + be7d4731. The parent PR #5010 was force-pushed (a
# pure rebase onto newer main: same patches, new shas) while the child was
# stacked on it, then landed. mc_restack was handed the parent's pre-merge head,
# which is not in the child's history, answered rc 6, and nothing restacked
# the child: it kept the parent's OLD commits plus a hand sync merge.
#
# Every case runs against a REAL bare origin and the real merge-conductor lib.
# L1-L6 call mc_restack directly; L7 drives conductor_settle; L8 is a chain
# bh-1 -> bh-2 -> bh-3, where restacking bh-2 must leave bh-3 owed a restack
# from bh-2's OLD head, and draining that record restacks bh-3.
#
# D1 MUTATIONS, run before the PR and confirmed red: drop the cumulative
# (squash) step in sp_fork_point (L2 red); drop the replay patch-id compare in
# sp_replay (L6 pushes, red); remove HOLD_PUSH_CHILDREN=follow from mc_restack
# (L8 red: the guard refuses the rewrite of a branch with children).
#
# Run from anywhere: tests/stacked-child-onto-landed.bh-5234-test.sh   (exit 0 = all pass)
set -uo pipefail
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq  >/dev/null || { echo "jq missing — skipping";  exit 0; }
command -v git >/dev/null || { echo "git missing — skipping"; exit 0; }
command -v flock >/dev/null || { echo "flock missing — skipping"; exit 0; }
[ -f "$DIR/bin/lib/mc/rebase.sh" ] && [ -f "$DIR/bin/lib/mc/settle.sh" ] || exit 1   # impact: bin/lib/mc/rebase.sh bin/lib/mc/settle.sh
[ -f "$DIR/bin/lib/stale-parent.sh" ] && ok || bad "bin/lib/stale-parent.sh does not exist"
REALGIT=$(command -v git)
SLUG=example-org/demo-os

export GIT_CONFIG_GLOBAL="$T/gitconfig" GIT_CONFIG_NOSYSTEM=1
git config --global user.email t@example.com
git config --global user.name  t
git config --global init.defaultBranch main
git config --global commit.gpgsign false
git config --global protocol.file.allow always
git config --global "url.$T/origin.git.insteadOf" "https://x-access-token@github.com/$SLUG.git"
git config --global "url.$T/origin.git.insteadOf" "https://github.com/$SLUG.git" --add

# shellcheck source=tests/lib/fixture-harness.sh
. "$DIR/tests/lib/fixture-harness.sh" || exit 1
export HARNESS="$T/h"; fx_mc_harness "$DIR" "$T" || exit 1
# The lib this suite drives, installed through its closure so the test-impact
# map sees the dependency: fx_mc_harness copies it with a plain cp the
# extractor cannot follow, and a change to it must select this suite.
scratch_install_closure bin/lib/merge-conductor-lib.sh "$T/h" >/dev/null || exit 1
scratch_install_closure bin/lib/gh-pr-merge.sh "$T/h" >/dev/null || exit 1
mkdir -p "$T/repos"

cat > "$T/fakebin/git" <<EOF
#!/bin/bash
case " \$* " in *" push "*) printf 'PUSH %s\n' "\$*" >> "$T/events.txt" ;; esac
exec "$REALGIT" "\$@"
EOF
chmod +x "$T/fakebin/git"

# gh: the open-children list of any ticket/bh-N is read from $T/kids-N (default
# none), and PR N's own read from $T/pr-N.{head,base}.
. "$DIR/tests/lib/hold-fixture.sh" || exit 1
hold_fixture_answer_lib "$T/holdfx" || exit 1
export HOLD_FX_ANSWER="$T/holdfx/hold-answer.sh"
cat > "$T/fakebin/gh" <<EOF
#!/bin/bash
[ -n "\${HOLD_FX_ANSWER:-}" ] && . "\$HOLD_FX_ANSWER" && hold_answer "\$@" && exit 0
printf '%s\n' "\$*" >> "$T/gh-argv.txt"
case "\$*" in
  *"auth token"*) echo faketoken ;;
  *"rate_limit"*) echo '{"resources":{"core":{"remaining":5000,"limit":5000,"reset":2000000000},"graphql":{"remaining":5000,"limit":5000,"reset":2000000000}}}' ;;
  *"pulls?state=open&base=ticket%2Fbh-"*"&per_page=100"*)
    N=\$(sed -n 's/.*base=ticket%2Fbh-\([0-9]*\)&.*/\1/p' <<<"\$*")
    K=\$(cat "$T/kids-\$N" 2>/dev/null)
    restpr --raw 200 "\$(jq -nc --arg k "\$K" '[\$k | split(" ")[] | select(. != "") | {number: tonumber}]')" ;;
  *"api -X PATCH repos/$SLUG/pulls/"*" -f base="*)
    printf 'PATCH %s\n' "\$*" >> "$T/events.txt"
    N=\$(sed -n 's|.*pulls/\([0-9]*\) .*|\1|p' <<<"\$*")
    printf '%s' "\${*##*base=}" > "$T/pr-\$N.base"; exit 0 ;;
  *"api -X PATCH repos/$SLUG/pulls/"*" -f state="*) printf 'KICK %s\n' "\$*" >> "$T/events.txt"; exit 0 ;;
  *"api -i -X GET repos/$SLUG/pulls/"*)
    N=\$(sed -n 's|.*repos/$SLUG/pulls/\([0-9]*\).*|\1|p' <<<"\$*")
    restpr --raw 200 "\$(jq -nc --argjson n "\$N" --arg sha "\$(cat "$T/pr-\$N.head")" --arg base "\$(cat "$T/pr-\$N.base")" \
      '{number:\$n,state:"open",merged_at:null,head:{sha:\$sha,ref:("ticket/bh-"+(\$n|tostring)),repo:{full_name:"$SLUG"}},base:{ref:\$base},labels:[],html_url:("https://github.com/$SLUG/pull/"+(\$n|tostring))}')" ;;
  *) echo "" ;;
esac
exit 0
EOF
chmod +x "$T/fakebin/gh"

G() { "$REALGIT" -C "$S" "$@"; }
commit() { # commit <msg> <file> <content>
  printf '%s' "$3" > "$S/$2"; G add -A && G commit -qm "$1"
}
# fixture <landing> [variant]
#   landing: merge (merge --no-ff) | squash
#   variant: sync     the child also merges main after the parent landed (#5053)
#            changed  the parent's p2 is rewritten with DIFFERENT content
#            interleave the child's own commit sits before a stale copy of p1
#            ctx      main edits the context of c1's change after the landing
#            chain    a grandchild ticket/bh-3 is cut from the child
# Sets PHEAD (the parent's rewritten, landed head), CHEAD (the child's head)
# and C1/C2 (the child's own commits as cut).
fixture() {
  local landing="$1" variant="${2:-}"
  S="$T/seed"
  rm -rf "$T/origin.git" "$S" "$T/h/tmp/conductor" "$T/h/state/stack-follow"
  : > "$T/events.txt"; : > "$T/gh-argv.txt"; : > "$T/h/logs/merge-conductor.log"
  rm -f "$T"/kids-* "$T"/pr-*.head "$T"/pr-*.base "$T/h/state/merge-conductor/pr-state.tsv"
  "$REALGIT" init -q --bare "$T/origin.git"
  "$REALGIT" clone -q "$T/origin.git" "$S" 2>/dev/null
  printf 'base\n' > "$S/a.txt"; printf 'l1\nl2\nl3\nl4\nl5\nl6\nl7\n' > "$S/child.txt"
  G add -A && G commit -qm base
  G checkout -qb ticket/bh-1
  commit p1 p1.txt $'p1\n'
  commit p2 p2.txt $'p2\n'
  local P2OLD; P2OLD=$(G rev-parse HEAD)
  G checkout -qb ticket/bh-2
  if [ "$variant" = interleave ]; then
    G reset -q --hard main
    commit x x.txt $'x\n'
    G cherry-pick "$(G rev-parse ticket/bh-1~1)" >/dev/null 2>&1 || G commit -qm p1   # a stale copy of p1, after an own commit
  fi
  printf 'l1\nl2\nchild\nl4\nl5\nl6\nl7\n' > "$S/child.txt"; printf 'new\n' > "$S/new-child.txt"
  G add -A && G commit -qm c1; C1=$(G rev-parse HEAD)
  if [ "$variant" != interleave ]; then printf 'p1\nchild-line\n' > "$S/p1.txt"; else printf 'x\nchild-line\n' > "$S/x.txt"; fi
  G add -A && G commit -qm c2; C2=$(G rev-parse HEAD)
  if [ "$variant" = chain ]; then
    G checkout -qb ticket/bh-3; commit g1 g.txt $'g\n'; GHEAD=$(G rev-parse HEAD); G checkout -q ticket/bh-2
  fi
  CHEAD=$C2
  G push -q origin main ticket/bh-1 ticket/bh-2 2>/dev/null
  [ "$variant" = chain ] && G push -q origin ticket/bh-3 2>/dev/null
  # main moves, and the parent is REBASED onto it (new shas; for `changed`,
  # p2 is rewritten with different content as well) and force-pushed.
  G checkout -q main; commit unrelated u.txt $'u\n'
  G checkout -q ticket/bh-1; G rebase -q main >/dev/null 2>&1
  if [ "$variant" = changed ]; then printf 'p2-rewritten\n' > "$S/p2.txt"; G commit -q --amend -am p2b; fi
  PHEAD=$(G rev-parse HEAD)
  [ "$PHEAD" != "$P2OLD" ] || bad "fixture: the parent rebase did not rewrite p2"
  G push -q -f origin ticket/bh-1 2>/dev/null
  G checkout -q main
  case "$landing" in
    merge)  G merge -q --no-ff -m 'Merge pull request #1' ticket/bh-1 >/dev/null ;;
    squash) G merge -q --squash ticket/bh-1 >/dev/null && G commit -qm 'parent (#1)' ;;
  esac
  [ "$variant" = ctx ] && { printf 'main-l1\nl2\nl3\nl4\nl5\nl6\nl7\n' > "$S/child.txt"; G commit -qam 'main edits c1 context'; }
  G push -q origin main 2>/dev/null
  G push -q origin --delete ticket/bh-1 2>/dev/null
  if [ "$variant" = sync ]; then
    # The add/add on p1.txt is the one #5053's own sync merge resolved by hand;
    # the fixture resolves it the same way, keeping the child's side.
    G checkout -q ticket/bh-2
    G merge -q --no-edit main >/dev/null 2>&1 || { G checkout -q --ours -- . && G add -A && G commit -q --no-edit; } \
      || bad "fixture: the sync merge could not be made"
    CHEAD=$(G rev-parse HEAD); G push -q origin ticket/bh-2 2>/dev/null; G checkout -q main
  fi
  printf '%s' "$CHEAD" > "$T/pr-2.head"; printf 'main' > "$T/pr-2.base"
  : > "$T/events.txt"
}
origin_rev() { "$REALGIT" -C "$T/origin.git" rev-parse "$1" 2>/dev/null; }
OG() { "$REALGIT" -C "$T/origin.git" "$@"; }
pid_of() { "$REALGIT" -C "$T/origin.git" show "$1" | "$REALGIT" patch-id --stable | cut -d' ' -f1; }
LOG="$T/h/logs/merge-conductor.log"
URL2="https://github.com/$SLUG/pull/2"

# shellcheck source=/dev/null
. "$T/h/bin/lib/merge-conductor-lib.sh"; mc_init
export PATH="$T/fakebin:$PATH" MC_REPOS="$T/repos"
export MC_STACK_FOLLOW_TRIES=3 MC_STACK_FOLLOW_GIVEUP_S=21600
MERGES=0   # conductor_settle counts the merges of a tick

# restacked_ok <case> — the shared asserts for a restack that should have worked
restacked_ok() {
  local c="$1" new own mt
  new=$(origin_rev ticket/bh-2)
  [ -n "$new" ] && [ "$new" != "$CHEAD" ] && ok || bad "$c: origin ticket/bh-2 must have moved (still ${CHEAD:0:8})"
  own=$(OG rev-list --no-merges main..ticket/bh-2 | wc -l)
  [ "$own" = 2 ] && ok || bad "$c: the child must carry exactly its 2 own commits over main (got $own)"
  [ "$(OG rev-list --merges main..ticket/bh-2 | wc -l)" = 0 ] && ok || bad "$c: the restacked child must carry no merge commits"
  mt=$(OG merge-tree --write-tree main ticket/bh-2 2>&1); local mrc=$?
  [ "$mrc" = 0 ] && ok || bad "$c: the child must merge cleanly into main (merge-tree rc $mrc: $mt)"
  grep -q 'CONFLICT (add/add)' <<<"$mt" && bad "$c: an add/add conflict against main" || ok
  [ "$(pid_of ticket/bh-2~1)" = "$(pid_of "$C1")" ] && ok || bad "$c: c1's own diff changed in the replay"
  [ "$(pid_of ticket/bh-2)" = "$(pid_of "$C2")" ] && ok || bad "$c: c2's own diff changed in the replay"
  grep -q 'fork point .* by patch-id' "$LOG" && ok || bad "$c: the log must name the patch-id fork point (got: $(tail -2 "$LOG"))"
}
not_restacked() { # not_restacked <case> <rc> <log-word>
  [ "$2" = 6 ] && ok || bad "$1: must answer rc 6 (got $2)"
  [ "$(origin_rev ticket/bh-2)" = "$CHEAD" ] && ok || bad "$1: origin's child must be unchanged"
  grep -q '^PUSH' "$T/events.txt" && bad "$1: nothing may be pushed" || ok
  grep -qi "$3" "$LOG" && ok || bad "$1: the log must say '$3' (got: $(tail -2 "$LOG"))"
}
restack() { RC=0; OUT=$(mc_restack "$SLUG" demo-os ticket/bh-2 "$CHEAD" "$PHEAD" main "$URL2" 2>/dev/null) || RC=$?; }

# L1 — the parent was rebased, then landed by a merge commit.
fixture merge; restack
[ "$RC" = 0 ] && ok || bad "L1: rc must be 0 (got $RC; log: $(tail -2 "$LOG"))"
[ "$OUT" = "$(origin_rev ticket/bh-2)" ] && ok || bad "L1: stdout must be the pushed head"
restacked_ok L1

# L2 — the parent was rebased, then SQUASH-landed: the cumulative step finds it.
fixture squash; restack
[ "$RC" = 0 ] && ok || bad "L2: rc must be 0 (got $RC; log: $(tail -2 "$LOG"))"
restacked_ok L2

# L3 — the child also merged main after a squash landing (#5053's aee2823b):
# the merge is on its first-parent line, so only its own commits are replayed.
fixture squash sync; restack
[ "$RC" = 0 ] && ok || bad "L3: rc must be 0 (got $RC; log: $(tail -2 "$LOG"))"
restacked_ok L3
grep -q '1 sync merge(s) dropped' "$LOG" && ok || bad "L3: the log must say 1 sync merge(s) dropped (got: $(tail -2 "$LOG"))"
# L3b — the same after a MERGE-COMMIT landing. The sync merge brings the
# parent's landed head into the child's history, so this is the ancestor path
# (git rebase drops the old copies, which apply empty); the result is the same.
fixture merge sync; restack
[ "$RC" = 0 ] && ok || bad "L3b: rc must be 0 (got $RC; log: $(tail -2 "$LOG"))"

[ "$(OG rev-list --no-merges main..ticket/bh-2 | wc -l)" = 2 ] && ok || bad "L3b: the child must carry exactly its 2 own commits"
OG merge-tree --write-tree main ticket/bh-2 >/dev/null 2>&1 && ok || bad "L3b: the child must merge cleanly into main"
[ "$(pid_of ticket/bh-2)" = "$(pid_of "$C2")" ] && ok || bad "L3b: c2's own diff changed"

# L4 — the parent was rewritten with DIFFERENT content: no proof, rc 6 as before.
fixture squash changed; restack
not_restacked L4 "$RC" 'not an ancestor'

# L5 — an own commit before a stale one: not a parent prefix, refused.
fixture merge interleave; restack
not_restacked L5 "$RC" interleaved

# L6 — main edited c1's context: the replay applies but c1's own diff changes.
fixture merge ctx; restack
not_restacked L6 "$RC" 'own diff changed'

# L7 — end to end: conductor_settle on the parent, child #2 open on it.
fixture merge; echo 2 > "$T/kids-1"; printf 'ticket/bh-1' > "$T/pr-2.base"
ACTIONS=1
conductor_settle "$SLUG#1" "https://github.com/$SLUG/pull/1" demo-os "$SLUG" ticket/bh-1 "" "" \
  "$PHEAD" "$PHEAD" APPROVE CLEAN "merged" "" >/dev/null 2>&1
grep -q 'PATCH .*pulls/2 -f base=main' "$T/events.txt" && ok || bad "L7: the child must be retargeted to main (events: $(cat "$T/events.txt"))"
[ "$(grep -c '^PUSH' "$T/events.txt")" = 1 ] && ok || bad "L7: exactly one push (events: $(cat "$T/events.txt"))"
PL=$(grep -n '^PATCH' "$T/events.txt" | head -1 | cut -d: -f1); UL=$(grep -n '^PUSH' "$T/events.txt" | head -1 | cut -d: -f1)
[ -n "$PL" ] && [ -n "$UL" ] && [ "$PL" -lt "$UL" ] && ok || bad "L7: the base PATCH must precede the push"
[ -e "$T/h/state/stack-follow/example-org_demo-os#2" ] && bad "L7: the pending follow must be cleared" || ok
[ -e "$T/h/state/stack-follow/example-org_demo-os#2.pushed" ] && ok || bad "L7: the .pushed marker must exist"
restacked_ok L7

# L8 — a chain: restacking bh-2 owes bh-3 a restack from bh-2's OLD head, and
# draining that record moves bh-3 onto the new bh-2 with its own diff intact.
fixture merge chain; echo 3 > "$T/kids-2"
printf '%s' "$GHEAD" > "$T/pr-3.head"; printf 'ticket/bh-2' > "$T/pr-3.base"
restack
[ "$RC" = 0 ] && ok || bad "L8: the middle child must restack (rc $RC; log: $(tail -2 "$LOG"))"
PEND3="$T/h/state/stack-follow/example-org_demo-os#3"
[ -s "$PEND3" ] && ok || bad "L8: bh-3 must be owed a restack after bh-2 was rewritten"
R_PN=""; R_PURL=""; R_PBR=""; R_PHEAD=""; R_BASE=""
[ -s "$PEND3" ] && IFS=$'\t' read -r R_PN R_PURL R_PBR R_PHEAD R_BASE _ _ < "$PEND3"
[ "${R_PHEAD:-}" = "$CHEAD" ] && ok || bad "L8: the record must hold bh-2's OLD head ${CHEAD:0:8} (got ${R_PHEAD:-none})"
[ "${R_BASE:-}" = ticket/bh-2 ] && [ "${R_PBR:-}" = ticket/bh-2 ] && ok || bad "L8: the record's base and parent branch must be ticket/bh-2 (got base=${R_BASE:-} pbr=${R_PBR:-})"
[ "${R_PN:-}" = 2 ] && ok || bad "L8: the record's parent number must be 2 (got ${R_PN:-})"
: > "$T/events.txt"
mc_stack_follow demo-os "$SLUG" 3 "$R_PN" "$R_PURL" "$R_PBR" "$R_PHEAD" "$R_BASE" >/dev/null 2>&1
OG merge-base --is-ancestor ticket/bh-2 ticket/bh-3 && ok || bad "L8: bh-3 must sit on the NEW bh-2 after the drain"
[ "$(OG rev-list --count ticket/bh-2..ticket/bh-3)" = 1 ] && ok || bad "L8: bh-3 must carry exactly its one own commit over bh-2"
[ "$(pid_of ticket/bh-3)" = "$(pid_of "$GHEAD")" ] && ok || bad "L8: bh-3's own diff must be unchanged"
[ -e "$PEND3" ] && bad "L8: the drained record must be cleared" || ok

echo "stacked-child-onto-landed.bh-5234-test: $PASS pass, $FAIL fail"
[ "$FAIL" = 0 ]
