#!/bin/bash
# tests/stacked-child-builds-test.sh — a child ticket builds ON TOP of its
# parent's open PR instead of waiting for it to merge (the operator, 2026-09-14).
#
# WHY DRIVEN AND NOT GREPPED. Every claim here is about a decision, not a
# string: which children bin/unblocked-children.sh calls STACKABLE and which it
# leaves alone, which branch bin/run-build.sh ends up cutting from, and which
# state the conductor puts a PR in whose base is a feature branch. A grep for
# "STACKABLE" passes just as happily on a script that emits it for every child
# on the board, which is the version that would launch unbuildable work.
#
# The three pieces are driven the way the fleet drives them: the emitter against
# a gh stub, run-build's base selection against a REAL git repo (the fetch it
# does is the existence probe, so a fake would test nothing), and the classifier
# as the pure function it is.
# Run from anywhere: tests/stacked-child-builds-test.sh   (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
export GH_CLI_REST_ADAPTER="$DIR/tests/lib/gh-cli-rest-adapter.sh"
. "$DIR/tests/lib/rb-all.sh" || exit 1
RB_ALL=$(rb_all "$DIR" "$T/run-build.all.sh")
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }
command -v git >/dev/null || { echo "git missing — skipping"; exit 0; }

# ============================================================================
# 1. bin/unblocked-children.sh — the STACKABLE class
# ============================================================================
mkdir -p "$T/h/flags" "$T/h/bin" "$T/fakebin"
export HARNESS="$T/h" GH_ISSUES_REPO="org/repo"
# gh stub: `issue list` answers from issues.json, `pr list` from prs.json.
cat > "$T/fakebin/gh" <<'SH'
#!/bin/bash
. "${GH_CLI_REST_ADAPTER:?}" || exit 1; gh_cli_rest "$0" "$@" && exit 0
case "$*" in
  *"issue list"*) cat "$HARNESS/issues.json" ;;
  *"pr list"*)    [ "${PR_FAIL:-}" = 1 ] && exit 1; cat "$HARNESS/prs.json" ;;
esac
exit 0
SH
chmod +x "$T/fakebin/gh"; export PATH="$T/fakebin:$PATH"
uc() { "$DIR/bin/unblocked-children.sh" p 2>/dev/null; }
mkdir -p "$T/h/bin/lib"; cp "$DIR/bin/lib/gh-rest.sh" "$DIR/bin/lib/gh-rest-var.sh" "$DIR/bin/lib/gh-rest-list.sh" "$T/h/bin/lib/"

cat > "$T/h/issues.json" <<'JSON'
[
 {"number":611,"state":"OPEN","title":"TK-611 the parent","body":"parent work"},
 {"number":563,"state":"OPEN","title":"TK-563 child one","body":"Blocked-by: #611"},
 {"number":564,"state":"OPEN","title":"TK-564 child two","body":"Blocked-by: #611"},
 {"number":565,"state":"OPEN","title":"TK-565 child already built","body":"Blocked-by: #611"},
 {"number":566,"state":"OPEN","title":"TK-566 parent has no PR","body":"Blocked-by: #700"},
 {"number":567,"state":"OPEN","title":"TK-567 two live parents","body":"Blocked-by: #611, #700"},
 {"number":568,"state":"OPEN","title":"TK-568 parent PR is a draft","body":"Blocked-by: #701"},
 {"number":569,"state":"OPEN","title":"TK-569 one closed one stacked","body":"Blocked-by: #555, #611"},
 {"number":555,"state":"CLOSED","title":"TK-555 done","body":""},
 {"number":700,"state":"OPEN","title":"TK-700 no PR at all","body":""},
 {"number":701,"state":"OPEN","title":"TK-701 draft PR","body":""}
]
JSON
cat > "$T/h/prs.json" <<'JSON'
[
 {"number":900,"url":"https://github.com/org/repo/pull/900","title":"TK-611: the parent","headRefName":"ticket/TK-611","isDraft":false},
 {"number":901,"url":"https://github.com/org/repo/pull/901","title":"TK-565: child already built","headRefName":"ticket/TK-565","isDraft":false},
 {"number":902,"url":"https://github.com/org/repo/pull/902","title":"TK-701: draft","headRefName":"ticket/TK-701","isDraft":true}
]
JSON

OUT=$(uc <<<'board issues: CHANGED 555 "TK-555 done" (state: OPEN -> CLOSED)')
grep -q '^board issues: STACKABLE 563 "TK-563 child one" base=ticket/TK-611 parent-pr=https://github.com/org/repo/pull/900 ' <<<"$OUT" \
  && ok || bad "563 must be STACKABLE on the parent's branch with its PR url (got: $OUT)"
grep -q 'STACKABLE 564 ' <<<"$OUT" && ok || bad "564 must be STACKABLE too — one parent PR releases every child (got: $OUT)"
grep -q 'STACKABLE 565 ' <<<"$OUT" && bad "565 already has its own open PR — it must NOT be re-offered (got: $OUT)" || ok
grep -q 'STACKABLE 566 ' <<<"$OUT" && bad "566's blocker has no PR at all — nothing to stack on (got: $OUT)" || ok
grep -q 'STACKABLE 567 ' <<<"$OUT" && bad "567 has TWO live blockers — a child can only be cut from one base (got: $OUT)" || ok
grep -q 'STACKABLE 568 ' <<<"$OUT" && bad "568's parent PR is a DRAFT — not a branch to build on yet (got: $OUT)" || ok
grep -q '^board issues: STACKABLE 569 .*base=ticket/TK-611 ' <<<"$OUT" \
  && ok || bad "569's other blocker is closed, so its one live blocker decides the base (got: $OUT)"
grep -q 'STACKABLE 611 ' <<<"$OUT" && bad "the parent itself has no Blocked-by line and must never be listed (got: $OUT)" || ok

# The two classes coexist: a closure still produces UNBLOCKED on the same run.
cat > "$T/h/issues2.json" <<'JSON'
[
 {"number":555,"state":"CLOSED","title":"TK-555 done","body":""},
 {"number":556,"state":"OPEN","title":"TK-556 released","body":"Blocked-by: #555"}
]
JSON
cp "$T/h/issues.json" "$T/h/issues.keep"; cp "$T/h/issues2.json" "$T/h/issues.json"
OUT=$(uc <<<'board issues: CHANGED 555 "x" (state: OPEN -> CLOSED)')
grep -q 'UNBLOCKED 556 ' <<<"$OUT" && ok || bad "the UNBLOCKED class must be untouched by the stacked one (got: $OUT)"
cp "$T/h/issues.keep" "$T/h/issues.json"

# A dead `gh pr list` costs the STACKABLE class and nothing else.
OUT=$(PR_FAIL=1 uc <<<'board issues: CHANGED 555 "x" (state: OPEN -> CLOSED)')
grep -q 'STACKABLE ' <<<"$OUT" && bad "a failed PR list must not invent a stack base (got: $OUT)" || ok

# THE KILL FLAG, both spellings: nothing new is emitted, and the diff with no
# closure in it goes back to costing nothing at all.
OUT=$(STACKED_BUILDS=0 uc <<<'board issues: CHANGED 555 "x" (state: OPEN -> CLOSED)')
grep -q 'STACKABLE ' <<<"$OUT" && bad "STACKED_BUILDS=0 must emit no STACKABLE line (got: $OUT)" || ok
touch "$T/h/flags/stacked-builds-off"
OUT=$(uc <<<'board issues: CHANGED 555 "x" (state: OPEN -> CLOSED)')
grep -q 'STACKABLE ' <<<"$OUT" && bad "flags/stacked-builds-off must emit no STACKABLE line (got: $OUT)" || ok
OUT=$(uc <<<'board issues: CHANGED 563 "x" (comments: 1 -> 2)'); RC=$?
[ "$RC" -eq 0 ] && [ -z "$OUT" ] && ok || bad "with the class off, a diff with no closure must be silent exit 0 (rc=$RC out=$OUT)"
rm -f "$T/h/flags/stacked-builds-off"

# ============================================================================
# 2. bin/run-build.sh — which branch the build is cut from
# ============================================================================
# A REAL repo, because the block's existence probe IS a `git fetch`: main plus
# one live parent branch, cloned the way a builder clones it.
git init -q --bare "$T/origin.git"
git init -q "$T/seed" && ( cd "$T/seed"
  git config user.email t@t; git config user.name t
  echo base > f.txt; git add f.txt; git commit -qm base
  git branch -M main; git remote add origin "$T/origin.git"; git push -q origin main
  git checkout -qb ticket/TK-611; echo parent >> f.txt; git commit -qam parent; git push -q origin ticket/TK-611 ) >/dev/null 2>&1
git clone -q "$T/origin.git" "$T/repo" 2>/dev/null

awk '/^# >>> stacked child builds/{f=1;next} /^# <<< stacked child builds/{exit} f' \
  "$RB_ALL" > "$T/stack.sh"
[ -s "$T/stack.sh" ] && ok || bad "could not extract the stacked-base block — markers missing?"
# The block is driven with exactly the variables run-build.sh has at that point.
run_stack() { # run_stack <STACK_BASE> [env assignments...] ; prints "BASE|STACK_ON|BASE_MAIN"
  local sb="$1"; shift
  mkdir -p "$T/h/builds/b"; : > "$T/h/builds/b/pipeline.log"
  ( export HARNESS="$T/h" PROJECT=p KEY=TK-563 BUILD="$T/h/builds/b" REPO="$T/repo" STACK_BASE="$sb"
    export "$@" 2>/dev/null || true
    bash -c 'set -uo pipefail
      STAMP() { echo TS; }
      BASE=main
      . "$0"
      printf "%s|%s|%s\n" "$BASE" "$STACK_ON" "$BASE_MAIN"' "$T/stack.sh" 2>/dev/null )
}
R=$(run_stack ticket/TK-611 X=1)
[ "$R" = "ticket/TK-611|ticket/TK-611|main" ] \
  && ok || bad "a live parent branch must become \$BASE, with \$BASE_MAIN keeping the real base (got '$R')"
grep -q 'STACKED on ticket/TK-611' "$T/h/builds/b/pipeline.log" \
  && ok || bad "the stack must be recorded in pipeline.log"
grep -q 'pull/900' "$T/h/builds/b/pipeline.log" \
  && ok || bad "the pipeline.log line must name the parent PR url, not just the branch"

R=$(run_stack ticket/TK-999 X=1)
[ "$R" = "main||main" ] \
  && ok || bad "a branch that is gone from origin (parent merged) must fall back to the base, never die (got '$R')"
grep -q 'could not be fetched from origin' "$T/h/builds/b/pipeline.log" \
  && ok || bad "the fallback must say why in pipeline.log"

R=$(run_stack main X=1)
[ "$R" = "main||main" ] && ok || bad "STACK_BASE equal to the base is not a stack (got '$R')"
R=$(run_stack 'ticket/../../etc; rm -rf /' X=1)
[ "$R" = "main||main" ] && ok || bad "an unsafe ref name must be refused, not interpolated into git (got '$R')"
R=$(run_stack '--upload-pack=evil' X=1)
[ "$R" = "main||main" ] && ok || bad "a ref starting with - must be refused (got '$R')"
R=$(run_stack "" X=1)
[ "$R" = "main||main" ] && ok || bad "no STACK_BASE at all must leave everything exactly as it is (got '$R')"

# THE KILL FLAG: the same live parent branch, ignored, both spellings.
R=$(run_stack ticket/TK-611 STACKED_BUILDS=0)
[ "$R" = "main||main" ] && ok || bad "STACKED_BUILDS=0 must ignore STACK_BASE entirely (got '$R')"
grep -q 'stacked builds are switched off' "$T/h/builds/b/pipeline.log" \
  && ok || bad "the switched-off path must say so in pipeline.log"
touch "$T/h/flags/stacked-builds-off"
R=$(run_stack ticket/TK-611 X=1)
[ "$R" = "main||main" ] && ok || bad "flags/stacked-builds-off must ignore STACK_BASE entirely (got '$R')"
rm -f "$T/h/flags/stacked-builds-off"

# THE CRITICAL SECTION, DRIVEN. The pin below says the ref update is in the
# source; this says the worktree it produces actually sits on the PARENT's
# commit and not on main, which is the only thing the whole feature is for.
mkdir -p "$T/h/locks"
{ printf '(\n'; awk '/exec 6>"\$HARNESS\/locks\/build-repo-\$PROJECT.lock"/{f=1} f{print} f&&/^\)/{exit}' "$RB_ALL"; } > "$T/wtsec.sh"
PARENT_SHA=$(git -C "$T/repo" rev-parse origin/ticket/TK-611)
MAIN_SHA=$(git -C "$T/repo" rev-parse origin/main)
run_wtsec() { # run_wtsec <BASE> <STACK_ON> <worktree-dir> ; prints the worktree HEAD
  scratch_rm "$3"; git -C "$T/repo" worktree prune >/dev/null 2>&1
  ( export HARNESS="$T/h" PROJECT=p KEY=TK-563 REPO="$T/repo" BASE="$1" STACK_ON="$2" WT="$3" \
           ALERTS="$T/h/logs/ALERTS.log"
    bash -c 'set -uo pipefail
      STAMP() { echo TS; }
      RESULT() { echo "$*" > '"$T"'/WTRESULT; }
      . "$0"' "$T/wtsec.sh" >/dev/null 2>&1 )
  git -C "$3" rev-parse HEAD 2>/dev/null
}
[ "$(run_wtsec ticket/TK-611 ticket/TK-611 "$T/wt-stacked")" = "$PARENT_SHA" ] \
  && ok || bad "a stacked build's worktree must be cut from the PARENT's commit, not from main"
[ "$(run_wtsec main "" "$T/wt-plain")" = "$MAIN_SHA" ] \
  && ok || bad "an ordinary build's worktree must still be cut from the base, byte-for-byte as before"
# ...and the parent's own worktree must survive a child being cut beside it: a
# `checkout` of the parent branch here would move the branch under it.
git -C "$T/repo" worktree prune >/dev/null 2>&1; rm -rf "$T/wt-parent"
git -C "$T/repo" worktree add -q --detach "$T/wt-parent" origin/ticket/TK-611 2>/dev/null
( cd "$T/wt-parent" && git checkout -qB ticket/TK-611 origin/ticket/TK-611 ) 2>/dev/null
run_wtsec ticket/TK-611 ticket/TK-611 "$T/wt-stacked2" >/dev/null
[ "$(git -C "$T/wt-parent" rev-parse HEAD 2>/dev/null)" = "$PARENT_SHA" ] \
  && ok || bad "cutting a child beside a live parent worktree must leave that worktree exactly where it was"
git -C "$T/repo" worktree remove --force "$T/wt-parent" >/dev/null 2>&1

# The rest of the pipeline reads $BASE and nothing else — that is the whole
# reason one variable carries the stack. These four are the sites that decide
# what a reviewer sees and where the PR points.
grep -q 'git update-ref "refs/heads/$BASE" "refs/remotes/origin/$BASE"' "$RB_ALL" \
  && ok || bad "the stacked base must be made resolvable by a REF update — a checkout would move the branch under the parent's own worktree"
grep -q 'gh pr create --head "$BRANCH" --base "$BASE"' "$RB_ALL" \
  && ok || bad "the PR must open against \$BASE, which is the parent branch when stacked"
grep -q 'git rebase "origin/$BASE"' "$RB_ALL" \
  && ok || bad "the pre-PR rebase must rebase onto \$BASE, never onto main when stacked"
grep -q 'STACK_ON' <<<"$(awk '/^# >>> tier-1 merge gate/{f=1} /^# <<< tier-1 merge gate/{exit} f' "$RB_ALL")" \
  && ok || bad "the tier-1 gate must hold a stacked PR — merging it would land the child INTO the parent"

# The carry: the queue entry a watcher writes must hold the branch, or the
# machine two hops away builds the child against main.
grep -q 'stack_base:\$sb' "$RB_ALL"      && ok || bad "run-build's queue entry must carry stack_base"
# TEST-CHANGE (BH-1026.3): the row -> job.json mapping moved OUT of
# bin/fly-dispatch.sh and into bin/lib/queue-row-job.sh, which the dispatcher and
# bin/fly-pool.sh both source — so the carry is now pinned where it lives, plus
# the source line that reaches it. Two assertions, not one, because either half
# alone passes on a dispatcher that no longer materialises anything.
grep -q 'stack_base:\$sb' "$DIR/bin/lib/queue-row-job.sh" \
  && ok || bad "the shared row->job mapping must materialise stack_base out of the row meta"
grep -q 'lib/queue-row-job.sh' "$DIR/bin/fly-dispatch.sh" \
  && ok || bad "fly-dispatch must source the mapping that carries stack_base"
grep -q 'STACK_BASE="\$stack_base"' "$DIR/fly/builder-runner.sh" \
  && ok || bad "the builder runner must hand stack_base to run-build.sh as STACK_BASE"
grep -q 'stack_base:\$sb' "$DIR/bin/fly-pool.sh"       && ok || bad "the pool must carry stack_base across a requeue"

# ============================================================================
# 3. bin/lib/merge-conductor-lib.sh — a PR based on a feature branch
# ============================================================================
mkdir -p "$T/h/bin/lib" "$T/h/logs" "$T/h/state" "$T/h/env"
# bin/lib/gh-rest.sh rides with the conductor lib: since BH-784 every decision
# read in it goes through gh_rest, and without the file the lib's fail-closed
# shims answer "unverifiable" to all of them.
cp "$DIR/bin/lib/gh-pr-list.sh" "$DIR/bin/lib/merge-conductor-lib.sh" "$DIR/bin/lib/gh-rest.sh" "$DIR/bin/lib/gh-rest-var.sh" "$T/h/bin/lib/"
cp "$DIR/tests/lib/rest-emit.sh" "$T/fakebin/restpr"; chmod +x "$T/fakebin/restpr"
mkdir -p "$T/h/bin/lib/mc" && cp "$DIR"/bin/lib/mc/*.sh "$T/h/bin/lib/mc/"
# shellcheck source=/dev/null
. "$T/h/bin/lib/merge-conductor-lib.sh"; mc_init
H1=aaaaaaaa1111
c() { mc_classify "$@" | cut -f1; }

[ "$(MC_STACK=wait MC_STACK_BASE=ticket/TK-611 c OPEN CLEAN MERGEABLE $H1 $H1 APPROVE claude green 0 0 0 0 - -)" = STACKED_WAIT ] \
  && ok || bad "an approved, green, clean PR based on a feature branch must be STACKED_WAIT, never READY"
[ "$(MC_STACK=wait MC_STACK_BASE=ticket/TK-611 c OPEN DIRTY CONFLICTING $H1 $H1 APPROVE claude green 0 0 0 0 - -)" = STACKED_WAIT ] \
  && ok || bad "a stacked PR must NOT be sent to NEEDS_REBASE — the conductor rebases onto main, which is not this PR's base"
[ "$(MC_STACK=wait MC_STACK_BASE=ticket/TK-611 c MERGED CLEAN MERGEABLE $H1 $H1 APPROVE claude green 0 0 0 0 - -)" = MERGED ] \
  && ok || bad "GitHub's own terminal states still outrank the stack clause"
[ "$(MC_STACK=parent-closed MC_STACK_BASE=ticket/TK-611 c OPEN CLEAN MERGEABLE $H1 $H1 APPROVE claude green 0 0 0 0 - -)" = BLOCKED_HUMAN ] \
  && ok || bad "a parent closed without merging must park the child"
grep -q 'parent-closed' <<<"$(MC_STACK=parent-closed MC_STACK_BASE=ticket/TK-611 mc_classify OPEN CLEAN MERGEABLE $H1 $H1 APPROVE claude green 0 0 0 0 - - | cut -f2)" \
  && ok || bad "the park reason must be parent-closed, so the alert says what is actually wrong"
[ "$(c OPEN CLEAN MERGEABLE $H1 $H1 APPROVE claude green 0 0 0 0 - -)" = READY ] \
  && ok || bad "with no stack the classifier must be byte-for-byte what it was — an ordinary PR is still READY"
grep -q 'STACKED_WAIT' <<<"$MC_STATES" && ok || bad "STACKED_WAIT must be in MC_STATES"
[ "$(mc_budget STACKED_WAIT)" -gt 0 ] && ok || bad "STACKED_WAIT must age against a budget — a stack nothing is driving has to surface"

# The project's base, which is the other half of the comparison.
[ "$(mc_project_base p)" = main ] && ok || bad "a project with no BASE_BRANCH must base on main"
printf 'BASE_BRANCH=dev\n' > "$T/h/env/p.env"
[ "$(mc_project_base p)" = dev ] && ok || bad "a project that sets BASE_BRANCH must use it (the same file run-build.sh reads)"
printf 'BASE_BRANCH=dev; rm -rf /\n' > "$T/h/env/p.env"
[ "$(mc_project_base p)" = main ] && ok || bad "an unsafe BASE_BRANCH must fall back to main, never reach a git command"
rm -f "$T/h/env/p.env"

# The parent's state, and the retarget GitHub sometimes does not do for us.
cat > "$T/fakebin/gh" <<SH
#!/bin/bash
printf '%s\n' "\$*" >> "$T/gh2.txt"
case "\$*" in
  # mc_stack_parent reads the parent through REST now (BH-784):
  # gh api -i -X GET repos/org/repo/pulls -f state=all -f head=org:<branch>.
  *"api -i -X GET repos/org/repo/pulls"*"head=org:ticket/TK-611"*) restpr --raw 200; cat "$T/parent.json" ;;
  *"api -i -X GET repos/org/repo/pulls"*) restpr --raw 200 '[]' ;;
  *"api -X PATCH"*) [ "\${PATCH_FAIL:-}" = 1 ] && exit 1; exit 0 ;;
esac
exit 0
SH
chmod +x "$T/fakebin/gh"
printf '[{"state":"open","merged_at":null,"html_url":"https://github.com/org/repo/pull/900"}]\n' > "$T/parent.json"
[ "$(mc_stack_parent org/repo ticket/TK-611)" = "$(printf 'OPEN\thttps://github.com/org/repo/pull/900')" ] \
  && ok || bad "mc_stack_parent must report the parent's state and url"
[ "$(mc_stack_parent org/repo ticket/nothing | cut -f1)" = NONE ] \
  && ok || bad "a base branch with no PR on it must read NONE, never an empty string a caller could mistake for OPEN"
: > "$T/gh2.txt"
mc_retarget_base org/repo 91 main && ok || bad "mc_retarget_base must succeed when the API accepts the PATCH"
grep -q 'api -X PATCH repos/org/repo/pulls/91 -f base=main' "$T/gh2.txt" \
  && ok || bad "the retarget must be the REST PATCH — gh pr edit --base reports success and changes nothing (got: $(cat "$T/gh2.txt"))"
grep -q 'pr edit .*--base' <<<"$(grep -vE '^[[:space:]]*#' "$DIR/bin/lib/merge-conductor-lib.sh" "$DIR/bin/merge-conductor.sh")" \
  && bad "nothing may retarget a PR through gh pr edit --base" || ok
PATCH_FAIL=1 mc_retarget_base org/repo 91 main && bad "a refused PATCH must return nonzero, or the row would read retargeted while the PR still points at a feature branch" || ok

# A RETARGET FIRES NO CI, SO THE CONDUCTOR RE-FIRES IT (2026-09-15, project-5
# #913/#943/#1011/#1020/#1021). A `pull_request` workflow's default activity
# types are opened|synchronize|reopened; a base change is `edited`, so the
# retarget above leaves the head with exactly the runs it already had — which
# for a child cut from a feature branch is NONE. All five PRs carried a
# base_ref_changed event by cromford[bot] and zero runs on their head, sat
# in `WAIT_CI checks none` for ever, and `gh pr close N && gh pr reopen N`
# unstuck every one of them within a minute. mc_kick_ci is that pair, as REST.
cat > "$T/fakebin/gh" <<SH
#!/bin/bash
printf '%s\n' "\$*" >> "$T/gh3.txt"
case "\$*" in
  *"-f state=closed"*) [ "\${CLOSE_FAIL:-}" = 1 ] && exit 1; exit 0 ;;
  *"-f state=open"*)   [ "\${OPEN_FAIL:-}" = 1 ]  && exit 1; exit 0 ;;
esac
exit 0
SH
chmod +x "$T/fakebin/gh"
: > "$T/gh3.txt"
( MC_KICK_REOPEN_SLEEP=0; mc_kick_ci org/repo 91 ) \
  && ok || bad "mc_kick_ci must return 0 when both PATCHes land"
[ "$(sed -n 1p "$T/gh3.txt")" = "api -X PATCH repos/org/repo/pulls/91 -f state=closed" ] \
  && ok || bad "the kick's first call must be the REST close (got: $(sed -n 1p "$T/gh3.txt"))"
[ "$(sed -n 2p "$T/gh3.txt")" = "api -X PATCH repos/org/repo/pulls/91 -f state=open" ] \
  && ok || bad "the reopen must follow the close — it is the reopen that fires the workflow (got: $(sed -n 2p "$T/gh3.txt"))"
[ "$(wc -l < "$T/gh3.txt")" -eq 2 ] && ok || bad "a kick is exactly those two calls (got: $(cat "$T/gh3.txt"))"
grep -qE 'gh pr (close|reopen)' <<<"$(grep -vE '^[[:space:]]*#' "$DIR/bin/lib/merge-conductor-lib.sh" "$DIR/bin/merge-conductor.sh")" \
  && bad "the kick must be the REST pair — gh's high-level commands have lied about exactly this before (mc_retarget_base)" || ok
# THE CLOSE MUST NEVER BE LEFT STANDING. A reopen that fails is retried, and a
# PR the conductor could not reopen is PAGED, not merely logged: nothing in the
# fleet reads merge-conductor.log for that line, and the conductor's own
# closed-unmerged pass will tell the human on the next tick to "rebuild or close
# the issue" — which produces a duplicate PR for a change that is sitting right
# there, one reopen away.
printf '#!/bin/bash\nprintf "%%s\\n" "$*" >> "%s/lane-alerts.txt"\nexit 0\n' "$T" > "$T/h/bin/lane-alert.sh"
chmod +x "$T/h/bin/lane-alert.sh"
: > "$T/lane-alerts.txt"
: > "$T/gh3.txt"
( export OPEN_FAIL=1; MC_KICK_REOPEN_SLEEP=0; mc_kick_ci org/repo 92 ) \
  && bad "a kick whose reopen never landed must return nonzero" || ok
[ "$(grep -c 'pulls/92 -f state=open' "$T/gh3.txt")" -ge 3 ] \
  && ok || bad "the reopen must be RETRIED, not attempted once (got $(grep -c 'pulls/92 -f state=open' "$T/gh3.txt") attempts)"
grep -q 'org/repo#92 LEFT CLOSED' "$MC_LOG" \
  && ok || bad "a PR left closed must be named LEFT CLOSED in the log, or nothing in the fleet knows the conductor closed it"
grep -q 'LEFT CLOSED' "$T/lane-alerts.txt" \
  && ok || bad "a PR left closed must ALERT, not just log — a log line nothing reads is not a hand-off (got: $(cat "$T/lane-alerts.txt"))"
grep -q -- '--critical' "$T/lane-alerts.txt" \
  && ok || bad "the LEFT CLOSED alert must be critical: the conductor closed a PR and only a person can reopen it (got: $(cat "$T/lane-alerts.txt"))"
grep -q 'state=open' "$T/lane-alerts.txt" \
  && ok || bad "the alert must carry the command that undoes it, so the reader does not have to look it up"
: > "$T/gh3.txt"
( export CLOSE_FAIL=1; MC_KICK_REOPEN_SLEEP=0; mc_kick_ci org/repo 93 ) \
  && bad "a kick whose close was refused must return nonzero" || ok
grep -q 'state=open' "$T/gh3.txt" \
  && bad "a refused close must not be followed by a reopen — the PR was never closed" || ok

# The tick wiring: the conductor must ASK for baseRefName, or it can never know.
grep -q 'headRefName,baseRefName' "$DIR/bin/merge-conductor.sh" \
  && ok || bad "the open-PR list must request baseRefName"
grep -q 'PBASE=$(mc_project_base "$P")' "$DIR/bin/merge-conductor.sh" \
  && ok || bad "the tick must resolve the project's base once, not per PR"

echo "stacked-child-builds: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
