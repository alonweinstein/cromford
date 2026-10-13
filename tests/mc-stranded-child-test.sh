#!/bin/bash
# tests/mc-stranded-child-test.sh — a stacked child whose parent was closed for
# a REBUILD is retargeted onto the rebuild, not thrown away (BH-458).
#
# THE DEFECT THIS PINS. `bin/merge-conductor.sh`'s stacked-child block asks
# `mc_stack_parent` for the PR whose head is the child's base branch. When the
# parent was closed and rebuilt, that PR is the parent's FIRST attempt: CLOSED,
# unmerged, its branch dead. The block parked the child `parent-closed` and
# nothing ever moved it — the rebuild landed from `ticket/<key>-r2`, which is a
# branch the child has never heard of, so GitHub's own retarget (which fires
# when the MERGED branch is deleted) never touched it either. Five fully built,
# APPROVED, CI-green children were closed by hand in one six-hour window on
# 2026-09-15, each of them about 50 minutes of build that had already been paid
# for.
#
# THE DECISION (the operator, 2026-09-16): stacking stays ON and the fix is to RETARGET,
# never to close. The child is rebased onto the retry head with
# `git rebase --onto <retry> <dead-parent>` — so its commits stay its own diff
# and none of the dead parent's work rides along — its base is PATCHed to the
# retry branch, CI is kicked, and the head-bound re-review runs on the new head
# like any other moved head. Close-for-rebuild survives only as the fallback for
# a rebase that CONFLICTS, and then the comment has to name the files.
#
# WHY DRIVEN AND NOT GREPPED. Every claim here is about control flow: which arm
# of the stacked block a shape reaches, what it hands git, and what it refuses
# to do in observe mode. `grep -q rebase bin/...` passes just as happily on a
# branch nothing reaches. gh and git are both stubbed and both record every
# argv, so an observe-only tick that pushed, PATCHed or closed anything fails
# here rather than on a real repo.
#
# Run from anywhere: tests/mc-stranded-child-test.sh   (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
# TEST-CHANGE (BH-1585): the open-PR list is REST now (a page plus per-PR reads);
# this bridge answers those reads from the GraphQL list this stub describes.
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/gh-list-bridge.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }

export HARNESS="$T/h"
mkdir -p "$T/h/bin/lib" "$T/h/logs" "$T/h/state" "$T/h/flags" "$T/h/locks" "$T/h/builds" \
         "$T/h/env" "$T/fakebin" "$T/repos/demo-os/.git" "$T/heads"
# bin/lib/gh-rest.sh rides along (BH-784): mc_stack_parent, mc_retry_pr and the
# pre-action re-read all go through it, and without it the lib's fail-closed shim
# answers "unverifiable" to every one of them — which reads as NONE, which parks
# every child and would make this suite green on a conductor that never looked.
cp "$DIR/bin/lib/gh-pr-list.sh" "$DIR/bin/lib/merge-conductor-lib.sh" "$DIR/bin/lib/gh-budget.sh" \
   "$DIR/bin/lib/gh-rest.sh" "$DIR/bin/lib/gh-rest-var.sh" "$T/h/bin/lib/"
mkdir -p "$T/h/bin/lib/mc" && cp "$DIR"/bin/lib/mc/*.sh "$T/h/bin/lib/mc/"
# BH-2504: the conductor pushes only through bin/lib/hold-push.sh (+ hold.sh).
cp "$DIR/bin/lib/hold-push.sh" "$DIR/bin/lib/hold.sh" "$T/h/bin/lib/"
cp "$DIR/bin/merge-conductor.sh" "$DIR/bin/fleet-conf.sh" "$DIR/bin/jobs-client.sh" "$T/h/bin/"
mkdir -p "$T/h/bin/lib/jobs" && cp "$DIR"/bin/lib/jobs/*.sh "$T/h/bin/lib/jobs/"
# The stub `gh` answers the REST reads as FULL HTTP responses, because gh-rest.sh
# judges the status line and not gh's exit code. tests/lib/rest-emit.sh is the
# emitter, on the stub PATH as `restpr`.
cp "$DIR/tests/lib/rest-emit.sh" "$T/fakebin/restpr"; chmod +x "$T/fakebin/restpr"

# The four children under test, their dead bases and the retry that replaced it.
H71=aaaa0071aaaa; H72=bbbb0072bbbb; H74=cccc0074cccc; H76=dddd0076dddd
NEW71=eeee0071eeee; NEW72=eeee0072eeee

# ============================================================================
# The stubs
# ============================================================================
# git: records every argv, answers the handful of verbs mc_restack uses, and
# fakes a conflict for whichever branch has a $T/conflict-<branch> file. It
# tracks WHICH branch a worktree holds (written at `worktree add`) so parallel
# PR workers cannot read each other's head.
cat > "$T/fakebin/git" <<EOF
#!/bin/bash
printf '%s\n' "\$*" >> "$T/git-argv.txt"
WT=""; SUB=""
while [ \$# -gt 0 ]; do
  case "\$1" in
    -C) WT="\$2"; shift 2 ;;
    -c) shift 2 ;;
    *)  SUB="\$1"; shift; break ;;
  esac
done
KEY=\$(printf '%s' "\$WT" | tr '/' '_')
case "\$SUB" in
  ls-remote) case " \$* " in *" -h "*) exit 2 ;; esac; exit 0 ;;
  remote|fetch) exit 0 ;;
  worktree)
    if [ "\${1:-}" = add ]; then
      for a in "\$@"; do case "\$a" in
        /*) mkdir -p "\$a"; KEY=\$(printf '%s' "\$a" | tr '/' '_') ;;
        origin/*) printf '%s' "\${a#origin/}" > "$T/wt-\$KEY" ;;
      esac; done
    fi
    exit 0 ;;
  checkout) for a in "\$@"; do case "\$a" in origin/*) printf '%s' "\${a#origin/}" > "$T/wt-\$KEY" ;; esac; done; exit 0 ;;
  rev-parse)
    BR=\$(cat "$T/wt-\$KEY" 2>/dev/null)
    if [ -f "$T/done-\$KEY" ]; then cat "$T/heads/new-\$(printf '%s' "\$BR" | tr '/' '_')" 2>/dev/null
    else cat "$T/heads/\$(printf '%s' "\$BR" | tr '/' '_')" 2>/dev/null; fi
    exit 0 ;;
  rebase)
    BR=\$(cat "$T/wt-\$KEY" 2>/dev/null)
    case " \$* " in
      *" --abort "*|*" --abort") exit 0 ;;
    esac
    printf '%s %s %s\n' "\$BR" "\$SUB" "\$*" >> "$T/rebases.txt"
    [ -f "$T/conflict-\$(printf '%s' "\$BR" | tr '/' '_')" ] && exit 1
    touch "$T/done-\$KEY"; exit 0 ;;
  diff)
    BR=\$(cat "$T/wt-\$KEY" 2>/dev/null)
    cat "$T/conflict-\$(printf '%s' "\$BR" | tr '/' '_')" 2>/dev/null; exit 0 ;;
  push) printf '%s\n' "\$*" >> "$T/pushes.txt"; exit 0 ;;
  *) exit 0 ;;
esac
EOF
chmod +x "$T/fakebin/git"

printf '%s' "$H71" > "$T/heads/ticket_pb-71"; printf '%s' "$NEW71" > "$T/heads/new-ticket_pb-71"
printf '%s' "$H72" > "$T/heads/ticket_pb-72"; printf '%s' "$NEW72" > "$T/heads/new-ticket_pb-72"
printf '%s' "$H74" > "$T/heads/ticket_pb-74"; printf '%s' "$H74" > "$T/heads/new-ticket_pb-74"
printf '%s' "$H76" > "$T/heads/ticket_pb-76"; printf '%s' "$H76" > "$T/heads/new-ticket_pb-76"
# PR 74's rebase hits a conflict in the child's own file.
printf 'src/child.ts\n' > "$T/conflict-ticket_pb-74"

# gh: the PR list, the parent/retry lookups, and every write recorded by kind.
#
# THE PARENT/RETRY LOOKUP IS REST NOW (BH-784). `mc_stack_parent` asks
# `pulls?state=all&head=<owner>:<branch>&per_page=1` and reads a JSON ARRAY, so a
# branch with no PR is an EMPTY array under a 200 — a real "no PR", never the
# silence of a failed read. The head cases are anchored on the SPACE that follows
# the branch name (the ` -F per_page=1` that comes next), because `ticket/TK-70`
# is a PREFIX of `ticket/TK-70-r2` and a trailing-glob stub would answer the probe
# for every retry generation with the dead parent. Real gh matches a head branch
# exactly; a stub that does not is a test that passes on code that never looked.
mk_gh() {
cat > "$T/fakebin/gh" <<EOF
#!/bin/bash
printf '%s\n' "\$*" >> "$T/gh-calls.txt"
B71=ticket/TK-70; [ -f "$T/retargeted.71" ] && B71=ticket/TK-70-r2
B72=ticket/TK-73; [ -f "$T/retargeted.72" ] && B72=main
# plist <OPEN|MERGED|CLOSED> <pr-number> — the one-element array the list read
#   answers. The state half comes out of restpr, so MERGED is state "closed" WITH
#   merged_at set and CLOSED is closed with merged_at null, which is the one
#   distinction this suite turns on.
plist() {
  restpr --raw 200 "[\$(restpr "\$1" x - - '' | tail -1 \
    | jq -c --arg u "https://github.com/example-org/demo-os/pull/\$2" '{state,merged_at,html_url:\$u}')]"
}
case "\$*" in
  *"auth token"*) echo faketoken ;;
  *"api -X PATCH repos/example-org/demo-os/pulls/"*" -f base="*)
    printf '%s\n' "\$*" >> "$T/retargets.txt"
    printf '%s\n' "\$*" | sed -E 's#.*pulls/([0-9]+).*#\1#' > "$T/retargeted.\$(printf '%s' "\$*" | sed -E 's#.*pulls/([0-9]+).*#\1#')"
    exit 0 ;;
  *"api -X PATCH repos/example-org/demo-os/pulls/"*" -f state="*)
    printf '%s\n' "\$*" >> "$T/kicks.txt"; exit 0 ;;
  *"api -X POST repos/example-org/demo-os/issues/"*"/comments"*)
    printf '%s\n' "\$*" >> "$T/comments.txt"; exit 0 ;;
  # The REST comment POST lands in the same ledger, so an observe-only tick that
  # commented through gh-rest.sh still fails section 1.
  *"api -i -X POST repos/example-org/demo-os/issues/"*"/comments"*)
    printf '%s\n' "\$*" >> "$T/comments.txt"; restpr --raw 201 '{"id":1}' ;;
  *"pr merge"*|*"pr edit"*|*"pr close"*) printf '%s\n' "\$*" >> "$T/gh-writes.txt"; exit 1 ;;
  *"head=example-org:ticket/TK-70-r2 "*) plist OPEN 80 ;;
  *"head=example-org:ticket/TK-73-r2 "*) plist MERGED 81 ;;
  *"head=example-org:ticket/TK-75-r2 "*) plist OPEN 82 ;;
  *"head=example-org:ticket/TK-70 "*) plist CLOSED 70 ;;
  *"head=example-org:ticket/TK-73 "*) plist CLOSED 73 ;;
  *"head=example-org:ticket/TK-75 "*) plist CLOSED 75 ;;
  *"head=example-org:ticket/TK-77 "*) plist OPEN 77 ;;
  # Every other branch name: an EMPTY list under a 200, which is what GitHub
  # really answers and what mc_stack_parent reads as "no PR on that branch".
  *"api -i -X GET repos/example-org/demo-os/pulls -f state=all"*) restpr --raw 200 '[]' ;;
  # The per-PR object read: the pre-action re-read, the harness-PR body check and
  # the settle all take this one call. Each child's base mirrors the list row.
  *"api -i -X GET repos/example-org/demo-os/pulls/"*"/files"*) restpr --raw 200 '[]' ;;
  *"api -i -X GET repos/example-org/demo-os/pulls/"*"v3.diff"*) restpr --diff '+++ b/src/child.ts
+const a = 1;
' ;;
  *"api -i -X GET repos/example-org/demo-os/pulls/71"*) restpr OPEN "$H71" ticket/TK-71 "\$B71" ;;
  *"api -i -X GET repos/example-org/demo-os/pulls/72"*) restpr OPEN "$H72" ticket/TK-72 "\$B72" ;;
  *"api -i -X GET repos/example-org/demo-os/pulls/74"*) restpr OPEN "$H74" ticket/TK-74 ticket/TK-75 ;;
  *"api -i -X GET repos/example-org/demo-os/pulls/76"*) restpr OPEN "$H76" ticket/TK-76 ticket/TK-77 ;;
  *"pr list -R example-org/demo-os --state open"*)
    cat <<J
[{"number":71,"url":"https://github.com/example-org/demo-os/pull/71","headRefOid":"$H71","headRefName":"ticket/TK-71","isDraft":false,"mergeStateStatus":"CLEAN","mergeable":"MERGEABLE","state":"OPEN","labels":[],"baseRefName":"\$B71"},
 {"number":72,"url":"https://github.com/example-org/demo-os/pull/72","headRefOid":"$H72","headRefName":"ticket/TK-72","isDraft":false,"mergeStateStatus":"CLEAN","mergeable":"MERGEABLE","state":"OPEN","labels":[],"baseRefName":"\$B72"},
 {"number":74,"url":"https://github.com/example-org/demo-os/pull/74","headRefOid":"$H74","headRefName":"ticket/TK-74","isDraft":false,"mergeStateStatus":"CLEAN","mergeable":"MERGEABLE","state":"OPEN","labels":[],"baseRefName":"ticket/TK-75"},
 {"number":76,"url":"https://github.com/example-org/demo-os/pull/76","headRefOid":"$H76","headRefName":"ticket/TK-76","isDraft":false,"mergeStateStatus":"CLEAN","mergeable":"MERGEABLE","state":"OPEN","labels":[],"baseRefName":"ticket/TK-77"}]
J
    ;;
  *"pr list"*) echo "[]" ;;
  *"actions/runs?head_sha="*) printf 'completed|success\n' ;;
  *"api rate_limit"*) echo '{"resources":{"core":{"remaining":5000,"limit":5000,"reset":2000000000},"graphql":{"remaining":5000,"limit":5000,"reset":2000000000}}}' ;;
  *) echo "" ;;
esac
exit 0
EOF
chmod +x "$T/fakebin/gh"
}
mk_gh

# flock is util-linux and macOS does not ship it. The per-PR lock is not what
# this suite is about — one tick at a time, no concurrent worker — so on a box
# without it the lock is a no-op and the tick runs. On Linux (CI, the fleet, the
# docker runner) the REAL flock is used, untouched.
command -v flock >/dev/null || { printf '#!/bin/bash\nexit 0\n' > "$T/fakebin/flock"; chmod +x "$T/fakebin/flock"; }

cat > "$T/fakebin/curl" <<'EOF'
#!/bin/bash
URL="${!#}"; M=GET
while [ $# -gt 0 ]; do case "$1" in -X) M="$2"; shift 2 ;; *) shift ;; esac; done
case "$M $URL" in
  "PUT "*/api/ledger) printf '{"ok":true}\n200\n' ;;
  *) printf '{"error":"not found"}\n404\n' ;;
esac
EOF
chmod +x "$T/fakebin/curl"

printf 'demo-os example-org/demo-os https://demo.example /api/board 2 box-demo\n' > "$T/h/fleet.conf"
: > "$T/h/env/global.env"
printf '#!/bin/bash\necho "" > "$4"; exit 0\n' > "$T/h/bin/agent-call.sh"; chmod +x "$T/h/bin/agent-call.sh"
# Each child is a real build: APPROVE bound to its head, exactly the shape that
# was being thrown away.
i=1
for spec in "71 $H71" "72 $H72" "74 $H74" "76 $H76"; do
  set -- $spec
  D="$T/h/builds/demo-os-TK-$1-20260916000$i"; mkdir -p "$D"
  echo "PR_CREATED https://github.com/example-org/demo-os/pull/$1" > "$D/RESULT"
  printf 'findings\nTIER: 2\nVERDICT: APPROVE\n' > "$D/review.md"
  echo "$2" > "$D/reviewed-sha"
  i=$((i+1))
done

# MC_PR_PARALLEL=1 — ONE PR worker at a time. Not because the lane is serial (it
# is not, and tests/merge-conductor-test.sh is where that is proven), but
# because the row file is guarded by flock, and on a box without flock the
# stub above cannot guard anything: four workers rewriting pr-state.tsv at once
# then lose a row every few runs. A suite that is red one time in twenty
# teaches people to re-run it, which is how a real regression gets waved
# through.
run_tick() { ( cd "$T" && PATH="$T/fakebin:$PATH" HARNESS="$T/h" HARNESS_SECRET=x \
  MC_REPOS="$T/repos" MC_MERGE_SETTLE=0 MC_MERGE_TREE=0 MC_DETACHED_REBASE=0 MC_KICK_REOPEN_SLEEP=0 \
  MC_PR_PARALLEL=1 \
  "$@" bash "$T/h/bin/merge-conductor.sh" >/dev/null 2>"$T/tick.err" ) \
  || { echo "tick rc=$? stderr:"; tail -5 "$T/tick.err"; }; }
state_of()  { awk -F'\t' -v k="$1" '$1==k {print $2}' "$T/h/state/merge-conductor/pr-state.tsv"; }
reason_of() { awk -F'\t' -v k="$1" '$1==k {print $7}' "$T/h/state/merge-conductor/pr-state.tsv"; }
LOG="$T/h/logs/merge-conductor.log"
: > "$T/git-argv.txt"; : > "$T/rebases.txt"; : > "$T/pushes.txt"; : > "$T/retargets.txt"
: > "$T/kicks.txt"; : > "$T/comments.txt"; : > "$T/gh-writes.txt"; : > "$T/gh-calls.txt"

# ============================================================================
# 1. OBSERVE MODE WRITES NOTHING. The actions flag is absent, so a tick that
#    rebased, PATCHed or closed anything here would do it on a real repo the
#    day somebody pins the conductor to observe.
# ============================================================================
run_tick
[ -s "$T/rebases.txt" ]  && bad "an observe-only tick rebased a child: $(cat "$T/rebases.txt")" || ok
[ -s "$T/pushes.txt" ]   && bad "an observe-only tick pushed: $(cat "$T/pushes.txt")" || ok
[ -s "$T/retargets.txt" ] && bad "an observe-only tick PATCHed a base: $(cat "$T/retargets.txt")" || ok
[ -s "$T/comments.txt" ] && bad "an observe-only tick commented on a PR: $(cat "$T/comments.txt")" || ok
[ -s "$T/kicks.txt" ]    && bad "an observe-only tick closed or reopened a PR: $(cat "$T/kicks.txt")" || ok
[ "$(state_of 'example-org/demo-os#71')" = BLOCKED_HUMAN ] \
  && ok || bad "with no actions flag the stranded child must still park as it does today (got $(state_of 'example-org/demo-os#71'))"
case "$(reason_of 'example-org/demo-os#71')" in
  parent-closed*) ok ;;
  *) bad "the observe-mode park reason must stay parent-closed (got $(reason_of 'example-org/demo-os#71'))" ;;
esac
grep -q 'restack example-org/demo-os#71' "$T/h/state/merge-conductor/attempts.txt" 2>/dev/null \
  && bad "observe mode must not burn the one-attempt marker — the next actions tick has to be able to act" || ok

# ============================================================================
# 2. THE RETRY IS OPEN: rebase onto it, PATCH the base, kick CI (BH-458 case 1)
# ============================================================================
touch "$T/h/flags/merge-conductor-actions"
run_tick
grep -q 'ticket/TK-71 rebase --onto origin/ticket/TK-70-r2 origin/ticket/TK-70' "$T/rebases.txt" \
  && ok || bad "the child must be rebased --onto the RETRY head from the dead parent head, so its diff stays its own commits (got: $(cat "$T/rebases.txt"))"
grep -q -- "--force-with-lease=ticket/TK-71:$H71" "$T/pushes.txt" \
  && ok || bad "the restacked branch must be pushed under a lease on the head this tick read (got: $(cat "$T/pushes.txt"))"
grep -q 'pulls/71 -f base=ticket/TK-70-r2' "$T/retargets.txt" \
  && ok || bad "the child's base must be PATCHed to the retry branch over the REST API (got: $(cat "$T/retargets.txt"))"
grep -q 'pulls/71 -f state=closed' "$T/kicks.txt" && grep -q 'pulls/71 -f state=open' "$T/kicks.txt" \
  && ok || bad "CI must be kicked after the retarget — a base change fires no workflow (got: $(cat "$T/kicks.txt"))"
grep -q 'issues/71/comments' "$T/comments.txt" \
  && bad "a child that rebased cleanly must NEVER be closed for rebuild: $(cat "$T/comments.txt")" || ok
grep -q 'demo-os#71 .*ticket/TK-70.*pull/80' "$LOG" \
  && ok || bad "one log line must name the child, the dead base and the retry PR (got: $(grep 'demo-os#71' "$LOG" | tail -1))"

# ============================================================================
# 3. THE RETRY ALREADY MERGED: the child is retargeted to the project base
# ============================================================================
grep -q 'ticket/TK-72 rebase --onto origin/main origin/ticket/TK-73' "$T/rebases.txt" \
  && ok || bad "when the retry has MERGED the child rebases onto the project base, not onto a merged branch (got: $(cat "$T/rebases.txt"))"
grep -q 'pulls/72 -f base=main' "$T/retargets.txt" \
  && ok || bad "a child whose parent merged from a retry must be retargeted to main (got: $(cat "$T/retargets.txt"))"
grep -q 'pulls/72 -f state=closed' "$T/kicks.txt" \
  && ok || bad "the merged-retry retarget must be kicked too (got: $(cat "$T/kicks.txt"))"
grep -q 'demo-os#72 .*ticket/TK-73.*pull/81' "$LOG" \
  && ok || bad "the merged-retry action must be logged with the child, the dead base and the merged PR"

# ============================================================================
# 4. THE REBASE CONFLICTS IN THE CHILD'S OWN FILES: close for rebuild, and the
#    comment has to say which files, or the rebuild has nothing to go on.
# ============================================================================
grep -q 'pulls/74 -f state=closed' "$T/kicks.txt" \
  && ok || bad "a child whose rebase conflicts must fall back to close-for-rebuild (got: $(cat "$T/kicks.txt"))"
grep -q 'pulls/74 -f state=open' "$T/kicks.txt" \
  && bad "close-for-rebuild is not a CI kick — the PR must stay closed" || ok
grep -q 'issues/74/comments' "$T/comments.txt" \
  && ok || bad "the close must carry a comment saying why (got: $(cat "$T/comments.txt"))"
grep -q 'src/child.ts' "$T/comments.txt" \
  && ok || bad "the close comment must NAME the conflicting files (got: $(cat "$T/comments.txt"))"
grep -q 'pulls/74 -f base=' "$T/retargets.txt" \
  && bad "a child that could not be rebased must not have its base moved" || ok
grep -q -- "--force-with-lease=ticket/TK-74" "$T/pushes.txt" \
  && bad "a conflicted rebase must never be pushed" || ok
[ "$(state_of 'example-org/demo-os#74')" = BLOCKED_HUMAN ] \
  && ok || bad "the closed child's row stays parked for the resolver (got $(state_of 'example-org/demo-os#74'))"

# ============================================================================
# 5. THE HEALTHY CASE IS UNTOUCHED: parent PR still OPEN on the same branch
# ============================================================================
[ "$(state_of 'example-org/demo-os#76')" = STACKED_WAIT ] \
  && ok || bad "a child whose parent PR is still OPEN must stay STACKED_WAIT (got $(state_of 'example-org/demo-os#76'))"
grep -q 'ticket/TK-76 rebase' "$T/rebases.txt" \
  && bad "a healthy stacked child must not be rebased" || ok
grep -q 'pulls/76' "$T/retargets.txt" \
  && bad "a healthy stacked child must not be retargeted" || ok
[ -s "$T/gh-writes.txt" ] && bad "no PR may be merged or edited by this lane: $(cat "$T/gh-writes.txt")" || ok

# ============================================================================
# 6. ONE ATTEMPT PER (CHILD, HEAD), and the restacked child then waits on its
#    new parent like any other healthy stack.
# ============================================================================
N71=$(grep -c 'ticket/TK-71 rebase' "$T/rebases.txt")
C74=$(grep -c 'issues/74/comments' "$T/comments.txt")
run_tick
[ "$(grep -c 'ticket/TK-71 rebase' "$T/rebases.txt")" = "$N71" ] \
  && ok || bad "a child already restacked onto the retry must not be rebased again (was $N71, now $(grep -c 'ticket/TK-71 rebase' "$T/rebases.txt"))"
[ "$(grep -c 'issues/74/comments' "$T/comments.txt")" = "$C74" ] \
  && ok || bad "the conflicted child must be closed once, not once per tick (was $C74, now $(grep -c 'issues/74/comments' "$T/comments.txt"))"
[ "$(state_of 'example-org/demo-os#71')" = STACKED_WAIT ] \
  && ok || bad "the restacked child now sits on an OPEN parent — an ordinary STACKED_WAIT (got $(state_of 'example-org/demo-os#71'))"
[ "$(state_of 'example-org/demo-os#72')" != STACKED_WAIT ] \
  && ok || bad "the child retargeted to main must classify normally once GitHub reports the new base (got $(state_of 'example-org/demo-os#72'))"

# ============================================================================
# 7. mc_retry_pr, directly: the newest retry branch for a dead base, and NONE
#    when there is no rebuild in flight (the shape that must still park).
# ============================================================================
# shellcheck source=/dev/null
. "$T/h/bin/lib/merge-conductor-lib.sh"; mc_init
export PATH="$T/fakebin:$PATH"
[ "$(mc_retry_pr example-org/demo-os ticket/TK-70 | cut -f1)" = OPEN ] \
  && ok || bad "mc_retry_pr must find the OPEN retry PR for a dead base (got $(mc_retry_pr example-org/demo-os ticket/TK-70))"
[ "$(mc_retry_pr example-org/demo-os ticket/TK-70 | cut -f3)" = ticket/TK-70-r2 ] \
  && ok || bad "mc_retry_pr must name the retry BRANCH — it is what the base is PATCHed to (got $(mc_retry_pr example-org/demo-os ticket/TK-70 | cut -f3))"
[ "$(mc_retry_pr example-org/demo-os ticket/TK-73 | cut -f1)" = MERGED ] \
  && ok || bad "a MERGED retry must be reported as merged, not as absent"
[ "$(mc_retry_pr example-org/demo-os ticket/TK-77 | cut -f1)" = NONE ] \
  && ok || bad "with no rebuild in flight mc_retry_pr must answer NONE, so the row parks exactly as it does today"
# A base that is ITSELF a retry: the search starts above it, never below, or a
# child on -r2 would be retargeted onto the -r2 that was just abandoned.
[ "$(mc_retry_pr example-org/demo-os ticket/TK-70-r2 | cut -f1)" = NONE ] \
  && ok || bad "a child already on -r2 must not be handed its own dead branch back (got $(mc_retry_pr example-org/demo-os ticket/TK-70-r2))"

echo "mc-stranded-child-test: $PASS pass, $FAIL fail"
[ "$FAIL" = 0 ]
