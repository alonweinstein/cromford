#!/bin/bash
. "$(dirname "$0")/lib/scratch.sh" || exit 1
# tests/mc-stack-parent-moved.bh-5796-test.sh — BH-5796: when a stacked
# child's OPEN parent branch gets a new head, the conductor brings the new
# parent into the child itself, whether or not GitHub lists the child DIRTY.
#
# WHY. 14 review BLOCKs said the child kept the old parent commits after the
# parent was rebuilt or fixed (#5535, #5097, #4761, #4747). BH-5519 merged the
# parent in only for a DIRTY child, so a CLEAN child stayed stale until a
# reviewer found it.
#
#   M1  the parent moved, the child is CLEAN: the child's new head contains the
#       new parent commit, main is not merged in, one plain push, no model call
#   M2  the child already carries the parent head: nothing is pushed
#   M3  the parent's move conflicts with the child: BLOCKED_HUMAN
#       conflict-unresolvable naming the parent branch, nothing pushed (the
#       resolver's fix round takes it)
#   M4  a second tick on the same head: no second try
#   M5  MC_STACK_PARENT_FOLLOW=0: nothing
#
# The rig is tests/mc-stack-parent-merge.bh-5519-test.sh's: a REAL bare origin
# and whole bin/merge-conductor.sh ticks, gh stubbed.
# Run from anywhere: tests/mc-stack-parent-moved.bh-5796-test.sh   (exit 0 = all pass)
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
  if [ "$mode" = uptodate ]; then
    printf 'parent\nl2\nl3\n' > "$S/a.txt"; "$REALGIT" -C "$S" commit -qam parent
  fi
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
    uptodate) : ;;
    append)   printf '\nCREATE TABLE parent_t (id INTEGER PRIMARY KEY);\n' >> "$S/worker/jobs/schema.sql" ;;
    conflict) printf 'const x = 1;\n' > "$S/src/x.ts" ;;
    *)        printf 'parent\nl2\nl3\n' > "$S/a.txt" ;;
  esac
  [ "$mode" = uptodate ] || "$REALGIT" -C "$S" commit -qam parent
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


touch "$T/h/flags/merge-conductor-actions"
tick() { ( cd "$T" && PATH="$T/fakebin:$PATH" HARNESS="$T/h" HARNESS_SECRET=x \
  MC_REPOS="$T/repos" MC_MERGE_SETTLE=0 MC_MERGE_TREE=0 MC_DETACHED_REBASE=0 MC_KICK_REOPEN_SLEEP=0 MC_PR_PARALLEL=1 \
  "$@" bash "$T/h/bin/merge-conductor.sh" >/dev/null 2>"$T/tick.err" ) || { echo "tick rc=$?"; tail -5 "$T/tick.err"; }; }
has_parent() { "$REALGIT" -C "$T/origin.git" merge-base --is-ancestor "$PHEAD" "$(origin_rev ticket/bh-9002)" 2>/dev/null; }

# M1 — CLEAN child, the parent moved: the parent comes in.
fixture; echo CLEAN > "$T/child-mstate"; tick env
NEW=$(origin_rev ticket/bh-9002)
[ "$NEW" != "$CHEAD" ] && has_parent && ok || bad "M1: the child's new head must contain the new parent commit ${PHEAD:0:8} (child=${NEW:0:8}; log: $(grep -F '#2' "$LOG" | tail -4))"
"$REALGIT" -C "$T/origin.git" merge-base --is-ancestor "$CHEAD" "$NEW" 2>/dev/null && ok || bad "M1: the child's own work is kept (old head is an ancestor)"
"$REALGIT" -C "$T/origin.git" merge-base --is-ancestor "$MHEAD" "$NEW" 2>/dev/null && bad "M1: main must NOT be merged into a stacked child" || ok
grep -q "demo-os#2 STACK_PARENT_MOVED" "$LOG" && ok || bad "M1: the log names the parent move (got: $(grep -F '#2' "$LOG" | tail -3))"
[ "$(grep -c '^PUSH' "$T/events.txt")" = 1 ] && ok || bad "M1: exactly one push (events: $(cat "$T/events.txt"))"
grep -q -- '--force ' "$T/events.txt" && bad "M1: never a force push" || ok
[ -s "$T/agent-calls.txt" ] && bad "M1: no model call (got: $(cat "$T/agent-calls.txt"))" || ok

# M2 — the child already carries the parent head: nothing.
fixture uptodate; echo CLEAN > "$T/child-mstate"; tick env
[ "$(origin_rev ticket/bh-9002)" = "$CHEAD" ] && ok || bad "M2: a child that has the parent head is not pushed"
grep -q 'STACK_PARENT_MOVED' "$LOG" && bad "M2: no STACK_PARENT_MOVED line (got: $(grep STACK_PARENT_ "$LOG"))" || ok

# M3 — the move conflicts: marked for a fix round, nothing pushed.
fixture conflict; echo CLEAN > "$T/child-mstate"; tick env
[ "$(origin_rev ticket/bh-9002)" = "$CHEAD" ] && ok || bad "M3: a conflicted parent merge pushes nothing"
[ "$(state_of 2)" = BLOCKED_HUMAN ] && ok || bad "M3: the child is parked for the resolver's fix round (got '$(state_of 2)')"
case "$(reason_of 2)" in "conflict-unresolvable: stacked child of ticket/bh-9001"*"src/x.ts"*) ok ;; *) bad "M3: the reason names the parent branch and the file (got '$(reason_of 2)')" ;; esac
# M4 — no second try on the same head.
N0=$(grep -c 'STACK_PARENT_' "$LOG"); tick env
[ "$(grep -c 'STACK_PARENT_' "$LOG")" = "$N0" ] && ok || bad "M4: a second tick on the same head must not try again (got: $(grep STACK_PARENT_ "$LOG"))"

# M5 — the knob off: nothing.
fixture; echo CLEAN > "$T/child-mstate"; tick env MC_STACK_PARENT_FOLLOW=0
[ "$(origin_rev ticket/bh-9002)" = "$CHEAD" ] && ok || bad "M5: MC_STACK_PARENT_FOLLOW=0 pushes nothing"

echo "mc-stack-parent-moved.bh-5796-test: $PASS pass, $FAIL fail"
[ "$FAIL" = 0 ]
