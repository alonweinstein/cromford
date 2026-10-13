#!/bin/bash
. "$(dirname "$0")/lib/scratch.sh" || exit 1
# tests/mc-stack-parent-merge.bh-5519-test.sh — BH-5519: a stacked child PR
# whose parent PR is still OPEN, and that GitHub lists DIRTY, gets its PARENT
# branch merged into it by the conductor. Not main: main's diff would ride into
# a PR whose diff is read against the parent.
#
# THE DEFECT THIS PINS. The stacked block of bin/merge-conductor.sh only wrote
# a note in its `OPEN*` parent arm, and mc_classify returns STACKED_WAIT before
# its DIRTY clause, so a conflicted child sat until the parent merged. And
# mc_rebase could only merge origin/main.
#
#   A  mc_rebase <slug> <p> <br> <head> <url> <base>, sourced, against a REAL
#      bare origin: A1 a parent merge (2-parent commit, main NOT pulled in,
#      rc 5), A2 an append-only add/add on worker/jobs/schema.sql (parent block
#      first), A3 REBASE_ON_POOL (rc 3, nothing pushed, nothing queued), A4 no
#      approval rebind after A1, A5 the 5-argument call still merges main.
#   B  whole bin/merge-conductor.sh ticks over the same origin: B1 a DIRTY
#      child gets the merge (STACK_PARENT_MERGED, row STACKED_WAIT, no agent
#      call), B2 CLEAN = nothing, B3 a second tick on a conflicted head = no
#      second try, B4 MC_STACK_PARENT_MERGE=0 = nothing, B5 a real conflict =
#      STACK_PARENT_CONFLICT and BLOCKED_HUMAN conflict-unresolvable (BH-5796;
#      it was STACKED_WAIT), B6 a spent
#      rebase budget = nothing and a budget line, B7 observe mode = nothing.
#
# D1 MUTATIONS, run once before the PR and confirmed red: delete the mc_rebase
# call in the OPEN* arm (B1 red), force base=main in mc_rebase (A1 red), drop
# the `base != main` return before the rebind (A4 red).
#
# Run from anywhere: tests/mc-stack-parent-merge.bh-5519-test.sh   (exit 0 = all pass)
set -uo pipefail
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq    >/dev/null || { echo "jq missing — skipping";    exit 0; }
command -v git   >/dev/null || { echo "git missing — skipping";   exit 0; }
command -v flock >/dev/null || { echo "flock missing — skipping"; exit 0; }
[ -f "$DIR/bin/lib/mc/rebase.sh" ] && [ -f "$DIR/bin/merge-conductor.sh" ] || exit 1   # impact: bin/lib/mc/rebase.sh bin/merge-conductor.sh
REALGIT=$(command -v git)
SLUG=example-org/demo-os
URL2="https://github.com/$SLUG/pull/2"

# ── a real repository, and a real remote that never leaves this box ──────────
export GIT_CONFIG_GLOBAL="$T/gitconfig" GIT_CONFIG_NOSYSTEM=1
git config --global user.email t@example.com
git config --global user.name  t
git config --global init.defaultBranch main
git config --global commit.gpgsign false
git config --global protocol.file.allow always
git config --global "url.$T/origin.git.insteadOf" "https://x-access-token@github.com/$SLUG.git"
git config --global "url.$T/origin.git.insteadOf" "https://github.com/$SLUG.git" --add

# ── the scratch harness: the conductor's whole closure ───────────────────────
export HARNESS="$T/h"
mkdir -p "$T/h/bin/lib" "$T/h/logs" "$T/h/state" "$T/h/flags" "$T/h/locks" "$T/h/builds" \
         "$T/h/env" "$T/h/tmp" "$T/fakebin" "$T/repos"
scratch_install_closure bin/merge-conductor.sh "$T/h" >/dev/null || exit 1
cp "$DIR/bin/fleet-conf.sh" "$T/h/bin/" || exit 1
cp "$DIR/tests/lib/rest-emit.sh" "$T/fakebin/restpr" && chmod +x "$T/fakebin/restpr" || exit 1
: > "$T/h/env/global.env"
printf 'demo-os %s - - 2 box-d\n' "$SLUG" > "$T/h/fleet.conf"
export FLEET_CONF="$T/h/fleet.conf"
for s in beat.sh deploy-request.sh pre-arm-guards.sh codegraph-ensure.sh deploy-verify.sh prod-url.sh lane-alert.sh; do
  printf '#!/bin/bash\nexit 0\n' > "$T/h/bin/$s"; chmod +x "$T/h/bin/$s"
done
# The model lane: any call at all is recorded, and B1 asserts there was none.
printf '#!/bin/bash\nprintf "%%s\\n" "$*" >> "%s/agent-calls.txt"\necho "" > "$4"; exit 0\n' "$T" > "$T/h/bin/agent-call.sh"
chmod +x "$T/h/bin/agent-call.sh"
cat > "$T/h/bin/jobs-client.sh" <<EOF
job_verdict_rebind() { printf '%s\n' "\$*" >> "$T/rebinds.txt"; return 0; }
job_ledger_put() { return 0; }
EOF

# BH-2504: a PR-branch push reads its ticket's hold first; FIXTURE: unheld.
. "$DIR/tests/lib/hold-fixture.sh" || exit 1
hold_fixture_answer_lib "$T/holdfx" || exit 1
export HOLD_FX_ANSWER="$T/holdfx/hold-answer.sh"

# ── git: the real one, every push recorded ───────────────────────────────────
cat > "$T/fakebin/git" <<EOF
#!/bin/bash
case " \$* " in *" push "*) printf 'PUSH %s\n' "\$*" >> "$T/events.txt" ;; esac
exec "$REALGIT" "\$@"
EOF
chmod +x "$T/fakebin/git"

# ── gh: PR #1 is the OPEN parent on main, PR #2 the child on ticket/bh-9001 ──
# The child's merge state is read from $T/child-mstate (DIRTY / CLEAN).
cat > "$T/fakebin/gh" <<EOF
#!/bin/bash
[ -n "\${HOLD_FX_ANSWER:-}" ] && . "\$HOLD_FX_ANSWER" && hold_answer "\$@" && exit 0
printf '%s\n' "\$*" >> "$T/gh-calls.txt"
C=\$(cat "$T/child-head" 2>/dev/null); P=\$(cat "$T/parent-head" 2>/dev/null)
MS=\$(cat "$T/child-mstate" 2>/dev/null); MG=MERGEABLE; MSL=clean; MB=true
[ "\$MS" = DIRTY ] && { MG=CONFLICTING; MSL=dirty; MB=false; }
case "\$*" in
  *"auth token"*) echo faketoken-fixture ;;
  *"rate_limit"*) echo '{"resources":{"core":{"remaining":5000,"limit":5000,"reset":2000000000},"graphql":{"remaining":5000,"limit":5000,"reset":2000000000}}}' ;;
  *"api -i -X GET repos/$SLUG/rulesets"*) restpr --raw 200 '[]' ;;
  *"api -i -X GET repos/$SLUG/contents/"*) restpr --raw 404 '{"message":"Not Found"}' ;;
  *"api -i -X GET repos/"*"/check-runs"*) restpr --raw 200 '{"check_runs":[]}' ;;
  *"api -i -X GET repos/$SLUG/pulls?state=open"*)
    restpr --raw 200 "\$(jq -nc --arg c "\$C" --arg p "\$P" --arg ms "\$MSL" --argjson mb "\$MB" '[
      {number:1,state:"open",draft:false,html_url:"https://github.com/$SLUG/pull/1",head:{sha:\$p,ref:"ticket/bh-9001",repo:{full_name:"$SLUG"}},base:{ref:"main",repo:{full_name:"$SLUG"}},labels:[],user:{login:"app/cromford"}},
      {number:2,state:"open",draft:false,html_url:"$URL2",head:{sha:\$c,ref:"ticket/bh-9002",repo:{full_name:"$SLUG"}},base:{ref:"ticket/bh-9001",repo:{full_name:"$SLUG"}},labels:[],user:{login:"app/cromford"}}]')" ;;
  *"api -i -X GET repos/$SLUG/pulls"*"head=example-org:ticket/bh-9001"*|*"api -i -X GET repos/$SLUG/pulls"*"head=example-org%3Aticket%2Fbh-9001"*)
    restpr --raw 200 '[{"number":1,"state":"open","merged_at":null,"html_url":"https://github.com/$SLUG/pull/1"}]' ;;
  *"api -i -X GET repos/$SLUG/pulls/1/files"*|*"api -i -X GET repos/$SLUG/pulls/2/files"*) restpr --raw 200 '[]' ;;
  *"api -i -X GET repos/$SLUG/pulls/"*"v3.diff"*|*"v3.diff"*) restpr --diff '+++ b/a.txt
+x
' ;;
  *"api -i -X GET repos/$SLUG/pulls/1"*)
    restpr --raw 200 "\$(jq -nc --arg p "\$P" '{number:1,state:"open",merged_at:null,draft:false,mergeable:true,mergeable_state:"clean",html_url:"https://github.com/$SLUG/pull/1",head:{sha:\$p,ref:"ticket/bh-9001",repo:{full_name:"$SLUG"}},base:{ref:"main"},labels:[],user:{login:"app/cromford",type:"Bot"},body:"x"}')" ;;
  *"api -i -X GET repos/$SLUG/pulls/2"*)
    restpr --raw 200 "\$(jq -nc --arg c "\$C" --arg ms "\$MSL" --argjson mb "\$MB" '{number:2,state:"open",merged_at:null,draft:false,mergeable:\$mb,mergeable_state:\$ms,html_url:"$URL2",head:{sha:\$c,ref:"ticket/bh-9002",repo:{full_name:"$SLUG"}},base:{ref:"ticket/bh-9001"},labels:[],user:{login:"app/cromford",type:"Bot"},body:"x"}')" ;;
  *"api -i -X GET repos/$SLUG/pulls"*) restpr --raw 200 '[]' ;;
  *"api -i -X GET repos/"*"/issues/"*) restpr --raw 200 '{"state":"open","number":2}' ;;
  *"pr merge"*|*"pr edit"*|*"pr close"*|*"-X PATCH"*|*"-X POST"*) printf '%s\n' "\$*" >> "$T/gh-writes.txt"; exit 0 ;;
  *"pr list"*) echo "[]" ;;
  *"actions/runs?head_sha="*) restpr --runs 'completed|success' ;;
  *) echo "" ;;
esac
exit 0
EOF
chmod +x "$T/fakebin/gh"
printf '#!/bin/bash\nprintf '"'"'{"error":"not found"}\\n404\\n'"'"'\n' > "$T/fakebin/curl"; chmod +x "$T/fakebin/curl"
export PATH="$T/fakebin:$PATH"

# fixture <mode> — a fresh origin. main: a.txt + schema.sql. Parent
# ticket/bh-9001 off main; child ticket/bh-9002 off the parent's FIRST commit;
# then the parent moves on (one more commit) and main moves on (one commit the
# child must NEVER receive from a parent merge).
#   (none)   parent edits line 1 of a.txt, child edits line 3: clean merge
#   append   both append one CREATE TABLE block to worker/jobs/schema.sql
#   conflict parent and child change the same line of src/x.ts
fixture() {
  local mode="${1:-}" S="$T/seed"
  rm -rf "$T/origin.git" "$S" "$T/h/tmp/conductor"
  : > "$T/events.txt"; : > "$T/gh-calls.txt"; : > "$T/gh-writes.txt"; : > "$T/rebinds.txt"; : > "$T/agent-calls.txt"
  : > "$T/h/logs/merge-conductor.log"
  rm -rf "$T/h/state/merge-conductor" "$T/h/state/stack-follow"
  "$REALGIT" init -q --bare "$T/origin.git"
  "$REALGIT" clone -q "$T/origin.git" "$S" 2>/dev/null
  mkdir -p "$S/worker/jobs" "$S/src"
  printf 'l1\nl2\nl3\n' > "$S/a.txt"; printf 'const x = 0;\n' > "$S/src/x.ts"
  printf 'CREATE TABLE base (id INTEGER PRIMARY KEY);\n' > "$S/worker/jobs/schema.sql"
  "$REALGIT" -C "$S" add -A && "$REALGIT" -C "$S" commit -qm base
  "$REALGIT" -C "$S" checkout -qb ticket/bh-9001
  printf 'p0\n' > "$S/p0.txt"; "$REALGIT" -C "$S" add -A && "$REALGIT" -C "$S" commit -qm p0
  "$REALGIT" -C "$S" checkout -qb ticket/bh-9002
  case "$mode" in
    append)   printf '\nCREATE TABLE child_t (id INTEGER PRIMARY KEY);\n' >> "$S/worker/jobs/schema.sql" ;;
    conflict) printf 'const x = 2;\n' > "$S/src/x.ts" ;;
    *)        printf 'l1\nl2\nchild\n' > "$S/a.txt" ;;
  esac
  "$REALGIT" -C "$S" commit -qam child
  CHEAD=$("$REALGIT" -C "$S" rev-parse HEAD)
  "$REALGIT" -C "$S" checkout -q ticket/bh-9001
  case "$mode" in
    append)   printf '\nCREATE TABLE parent_t (id INTEGER PRIMARY KEY);\n' >> "$S/worker/jobs/schema.sql" ;;
    conflict) printf 'const x = 1;\n' > "$S/src/x.ts" ;;
    *)        printf 'parent\nl2\nl3\n' > "$S/a.txt" ;;
  esac
  "$REALGIT" -C "$S" commit -qam parent
  PHEAD=$("$REALGIT" -C "$S" rev-parse HEAD)
  "$REALGIT" -C "$S" checkout -q main
  printf 'main-only\n' > "$S/main-only.txt"; "$REALGIT" -C "$S" add -A && "$REALGIT" -C "$S" commit -qm 'main moves'
  MHEAD=$("$REALGIT" -C "$S" rev-parse HEAD)
  "$REALGIT" -C "$S" push -q origin main ticket/bh-9001 ticket/bh-9002 2>/dev/null
  printf '%s' "$CHEAD" > "$T/child-head"; printf '%s' "$PHEAD" > "$T/parent-head"
  echo DIRTY > "$T/child-mstate"
  # The child's build record: approved on CHEAD.
  rm -rf "$T/h/builds"/*; local R="$T/h/builds/demo-os-BH-9002-202610080001"; mkdir -p "$R"
  echo "PR_CREATED $URL2" > "$R/RESULT"
  printf 'findings\nTIER: 2\nVERDICT: APPROVE\n' > "$R/review.md"; echo "$CHEAD" > "$R/reviewed-sha"; : > "$R/pipeline.log"
  local R1="$T/h/builds/demo-os-BH-9001-202610080000"; mkdir -p "$R1"
  echo "PR_CREATED https://github.com/$SLUG/pull/1" > "$R1/RESULT"
  printf 'findings\nTIER: 2\nVERDICT: APPROVE\n' > "$R1/review.md"; echo "$PHEAD" > "$R1/reviewed-sha"; : > "$R1/pipeline.log"
  REC2="$R"
}
origin_rev() { "$REALGIT" -C "$T/origin.git" rev-parse "$1" 2>/dev/null; }
LOG="$T/h/logs/merge-conductor.log"
state_of()  { awk -F'\t' -v k="$SLUG#$1" '$1==k {print $2}' "$T/h/state/merge-conductor/pr-state.tsv" 2>/dev/null; }
reason_of() { awk -F'\t' -v k="$SLUG#$1" '$1==k {print $7}' "$T/h/state/merge-conductor/pr-state.tsv" 2>/dev/null; }

# ============================================================================
# A. mc_rebase with a named base, sourced (each case in a subshell so the
#    sourced lib never leaks into the B ticks).
# ============================================================================
arun() { # arun <out-file> <args...> — mc_rebase in a fresh subshell; rc to $T/arc
  ( . "$T/h/bin/lib/merge-conductor-lib.sh"; mc_init; MC_REPOS="$T/repos"
    [ -n "${A_POOL:-}" ] && { routing_pool_app() { return 0; }; mc_pool_rebase_enqueue() { echo "$*" >> "$T/pool-enq.txt"; return 6; }; }
    mc_rebase "${@:2}" > "$1" 2>/dev/null; echo $? > "$T/arc" )
}

# A1 — a clean parent merge.
fixture
arun "$T/a1.out" "$SLUG" demo-os ticket/bh-9002 "$CHEAD" "$URL2" ticket/bh-9001
RC=$(cat "$T/arc"); NEW=$(origin_rev ticket/bh-9002)
[ "$RC" = 5 ] && ok || bad "A1: a parent merge answers rc 5 (got $RC; log: $(tail -2 "$LOG"))"
[ "$(cat "$T/a1.out")" = "$NEW" ] && [ "$NEW" != "$CHEAD" ] && ok || bad "A1: stdout is the pushed sha (out='$(cat "$T/a1.out")' origin=$NEW)"
[ "$("$REALGIT" -C "$T/origin.git" rev-parse "$NEW^1" 2>/dev/null)" = "$CHEAD" ] && [ "$("$REALGIT" -C "$T/origin.git" rev-parse "$NEW^2" 2>/dev/null)" = "$PHEAD" ] \
  && ok || bad "A1: the child tip is a merge of (old head, parent tip) (parents: $("$REALGIT" -C "$T/origin.git" log -1 --format=%P "$NEW" 2>/dev/null))"
"$REALGIT" -C "$T/origin.git" merge-base --is-ancestor "$MHEAD" "$NEW" 2>/dev/null \
  && bad "A1: main's own commit must NOT be in the child after a parent merge" || ok
[ "$("$REALGIT" -C "$T/origin.git" show "$NEW:a.txt" 2>/dev/null | tr '\n' ' ')" = "parent l2 child " ] \
  && ok || bad "A1: a.txt carries both sides (got: $("$REALGIT" -C "$T/origin.git" show "$NEW:a.txt" 2>/dev/null | tr '\n' ' '))"
# A4 — the approval is NOT rebound onto a parent merge.
[ "$(cat "$REC2/reviewed-sha")" = "$CHEAD" ] && ok || bad "A4: reviewed-sha must stay on the old head (got $(cat "$REC2/reviewed-sha"))"
[ -s "$T/rebinds.txt" ] && bad "A4: job_verdict_rebind must not be called (got: $(cat "$T/rebinds.txt"))" || ok
grep -q "approval .*NOT rebound" "$LOG" && ok || bad "A4: the log says the approval was not rebound (got: $(tail -2 "$LOG"))"

# A2 — append-only add/add on schema.sql: both blocks, the parent's first.
if command -v python3 >/dev/null && python3 -c 'import sqlite3' 2>/dev/null; then
  fixture append
  arun "$T/a2.out" "$SLUG" demo-os ticket/bh-9002 "$CHEAD" "$URL2" ticket/bh-9001
  RC=$(cat "$T/arc"); NEW=$(origin_rev ticket/bh-9002)
  [ "$RC" = 5 ] && ok || bad "A2: a union-resolved parent merge answers rc 5 (got $RC; log: $(tail -2 "$LOG"))"
  SQL=$("$REALGIT" -C "$T/origin.git" show "$NEW:worker/jobs/schema.sql" 2>/dev/null)
  PL=$(grep -n parent_t <<<"$SQL" | cut -d: -f1); CL=$(grep -n child_t <<<"$SQL" | cut -d: -f1)
  [ -n "$PL" ] && [ -n "$CL" ] && [ "$PL" -lt "$CL" ] && ok || bad "A2: both blocks, the parent's first (got: $SQL)"
  [ "$("$REALGIT" -C "$T/origin.git" rev-parse "$NEW^2" 2>/dev/null)" = "$PHEAD" ] && ok || bad "A2: the merge's second parent is the parent tip"
else
  echo "A2: python3 sqlite3 missing — the union validator cannot run; A2 skipped"
fi

# A3 — REBASE_ON_POOL: no hub git, nothing queued, rc 3.
fixture
touch "$T/h/flags/fly-pool-app-demo-os"; rm -f "$T/pool-enq.txt"
A_POOL=1 REBASE_ON_POOL=1 arun "$T/a3.out" "$SLUG" demo-os ticket/bh-9002 "$CHEAD" "$URL2" ticket/bh-9001
rm -f "$T/h/flags/fly-pool-app-demo-os"
[ "$(cat "$T/arc")" = 3 ] && ok || bad "A3: a parent merge under REBASE_ON_POOL answers rc 3 (got $(cat "$T/arc"))"
[ "$(origin_rev ticket/bh-9002)" = "$CHEAD" ] && ok || bad "A3: the child on origin is unchanged"
[ -s "$T/pool-enq.txt" ] && bad "A3: a parent merge must not be queued as a pool (main) rebase (got: $(cat "$T/pool-enq.txt"))" || ok
grep -q "not a pool job" "$LOG" && ok || bad "A3: the log names the skip (got: $(tail -2 "$LOG"))"

# A5 — five arguments: still a main merge (the seven existing callers).
fixture
arun "$T/a5.out" "$SLUG" demo-os ticket/bh-9002 "$CHEAD" "$URL2"
NEW=$(origin_rev ticket/bh-9002)
"$REALGIT" -C "$T/origin.git" merge-base --is-ancestor "$MHEAD" "$NEW" 2>/dev/null \
  && ok || bad "A5: the 5-argument call merges origin/main (rc $(cat "$T/arc"))"
"$REALGIT" -C "$T/origin.git" merge-base --is-ancestor "$PHEAD" "$NEW" 2>/dev/null \
  && bad "A5: the 5-argument call must not merge the parent" || ok
[ "$(cat "$T/arc")" = 0 ] && ok || bad "A5: a clean main merge still rebinds and answers rc 0 (got $(cat "$T/arc"))"

# ============================================================================
# B. Whole bin/merge-conductor.sh ticks.
# ============================================================================
touch "$T/h/flags/merge-conductor-actions"
tick() { ( cd "$T" && PATH="$T/fakebin:$PATH" HARNESS="$T/h" HARNESS_SECRET=x \
  MC_REPOS="$T/repos" MC_MERGE_SETTLE=0 MC_MERGE_TREE=0 MC_DETACHED_REBASE=0 MC_KICK_REOPEN_SLEEP=0 MC_PR_PARALLEL=1 \
  "$@" bash "$T/h/bin/merge-conductor.sh" >/dev/null 2>"$T/tick.err" ) || { echo "tick rc=$?"; tail -5 "$T/tick.err"; }; }
merged() { "$REALGIT" -C "$T/origin.git" merge-base --is-ancestor "$PHEAD" "$(origin_rev ticket/bh-9002)" 2>/dev/null; }

# B1 — DIRTY child, OPEN parent: the parent branch is merged in.
fixture; tick env
NEW=$(origin_rev ticket/bh-9002)
[ "$NEW" != "$CHEAD" ] && merged && ok || bad "B1: the child on origin carries the parent tip (child=${NEW:0:8}; log: $(grep -F '#2' "$LOG" | tail -4))"
"$REALGIT" -C "$T/origin.git" merge-base --is-ancestor "$CHEAD" "$NEW" 2>/dev/null && ok || bad "B1: a plain merge — the old head is an ancestor of the new one"
"$REALGIT" -C "$T/origin.git" merge-base --is-ancestor "$MHEAD" "$NEW" 2>/dev/null && bad "B1: main must NOT be merged into a stacked child" || ok
grep -q "demo-os#2 STACK_PARENT_MERGED ${NEW:0:8} from ticket/bh-9001" "$LOG" && ok || bad "B1: the log has STACK_PARENT_MERGED (got: $(grep -F '#2' "$LOG" | tail -3))"
[ "$(state_of 2)" = STACKED_WAIT ] && ok || bad "B1: the row stays STACKED_WAIT (got '$(state_of 2)')"
case "$(reason_of 2)" in *"parent branch merged in"*) ok ;; *) bad "B1: the reason names the merge (got '$(reason_of 2)')" ;; esac
[ "$(cat "$REC2/reviewed-sha")" = "$CHEAD" ] && ok || bad "B1: the reviewed sha is not moved"
[ -s "$T/agent-calls.txt" ] && bad "B1: no model call (got: $(cat "$T/agent-calls.txt"))" || ok
[ "$(grep -c '^PUSH' "$T/events.txt")" = 1 ] && ok || bad "B1: exactly one push (events: $(cat "$T/events.txt"))"
grep -q -- '--force ' "$T/events.txt" && bad "B1: never a force push" || ok

# B2 — CLEAN child: nothing.
# TEST-CHANGE (BH-5796): a CLEAN child whose parent MOVED now gets the parent
# merged in (tests/mc-stack-parent-moved.bh-5796-test.sh M1). This fixture's
# parent has moved, so B2 turns that half off to keep pinning what it pinned:
# the DIRTY condition of the BH-5519 merge.
fixture; echo CLEAN > "$T/child-mstate"; tick env MC_STACK_PARENT_FOLLOW=0
[ "$(origin_rev ticket/bh-9002)" = "$CHEAD" ] && ok || bad "B2: a CLEAN child is not pushed"
grep -q 'STACK_PARENT_' "$LOG" && bad "B2: no STACK_PARENT_ line for a CLEAN child (got: $(grep STACK_PARENT_ "$LOG"))" || ok

# B5 — a real conflict: nothing pushed, and marked for a fix round.
# TEST-CHANGE (BH-5796): a conflict used to stay STACKED_WAIT until the parent
# merged. The ticket makes it a fix round: the row is BLOCKED_HUMAN
# conflict-unresolvable naming the parent branch, and bin/blocked-resolver.sh's
# round merges that branch, not main (tests/br-stacked-fixround.bh-5796-test.sh).
fixture conflict; tick env
[ "$(origin_rev ticket/bh-9002)" = "$CHEAD" ] && ok || bad "B5: a conflicted parent merge pushes nothing"
grep -q 'demo-os#2 STACK_PARENT_CONFLICT src/x.ts' "$LOG" && ok || bad "B5: the log names the conflicted file (got: $(grep -F '#2' "$LOG" | tail -3))"
[ "$(state_of 2)" = BLOCKED_HUMAN ] && ok || bad "B5: the row is parked for the fix round (got '$(state_of 2)')"
case "$(reason_of 2)" in "conflict-unresolvable: stacked child of ticket/bh-9001"*"src/x.ts"*) ok ;; *) bad "B5: the reason names the parent and the conflict (got '$(reason_of 2)')" ;; esac
# B3 — the next tick on the same head does not try again.
N0=$(grep -c 'STACK_PARENT_' "$LOG"); tick env
[ "$(grep -c 'STACK_PARENT_' "$LOG")" = "$N0" ] && ok || bad "B3: a second tick on the same head must not try again (got: $(grep STACK_PARENT_ "$LOG"))"

# B4 — the knob off: nothing.
fixture; tick env MC_STACK_PARENT_MERGE=0
[ "$(origin_rev ticket/bh-9002)" = "$CHEAD" ] && ok || bad "B4: MC_STACK_PARENT_MERGE=0 pushes nothing"
grep -q 'STACK_PARENT_' "$LOG" && bad "B4: no STACK_PARENT_ line with the knob off" || ok

# B6 — the rebase budget spent: nothing, and the budget line.
fixture; tick env MC_REBASE_BUDGET=0
[ "$(origin_rev ticket/bh-9002)" = "$CHEAD" ] && ok || bad "B6: a spent budget pushes nothing"
grep -q 'demo-os#2 rebase deferred' "$LOG" && ok || bad "B6: the budget-spent line (got: $(grep -F '#2' "$LOG" | tail -3))"

# B7 — observe mode: nothing.
fixture; rm -f "$T/h/flags/merge-conductor-actions"; tick env
touch "$T/h/flags/merge-conductor-actions"
[ "$(origin_rev ticket/bh-9002)" = "$CHEAD" ] && ok || bad "B7: observe mode pushes nothing"
grep -q 'STACK_PARENT_' "$LOG" && bad "B7: no STACK_PARENT_ line in observe mode" || ok

echo "mc-stack-parent-merge.bh-5519-test: $PASS pass, $FAIL fail"
[ "$FAIL" = 0 ]
