#!/bin/bash
# tests/merge-queue-batch-hold.bh-1366-test.sh — BH-576: a PR that bin/batch-resolve.sh has
# put into a live merge-time train is landed BY the train, and only by it
# (docs/MERGE-CONDUCTOR.md §15).
#
# WHY THIS TEST EXISTS. BH-498 gave the fleet merge-time trains and a marker to
# go with them (`mc_batch_hold` / `mc_batch_held`), and exactly ONE lane read it:
# bin/merge-conductor.sh's pr_worker. Two other lanes land or feed a landing —
# bin/merge-queue.sh, which is the script that actually runs `gh pr merge`, and
# bin/tier2-merge-sweep.sh, which pushes every approved tier-2 PR onto that
# queue. A hold honoured by one of three lanes is not a hold: the member lands
# twice, and then the train's settle closes a PR GitHub already merged or the
# train goes red on a phantom conflict.
#
# So both scripts are DRIVEN here, from one fixture, with a marker written by
# the REAL lib (`mc_batch_hold`), and the assertions are on artifacts — the
# `gh pr merge` calls the stub recorded, the queue directory, the two lane logs
# — never on the source of the scripts. The negatives carry the weight: a hold
# for an OLDER head must still merge (holds are head-keyed), no marker must
# behave byte-for-byte as it did (not even one extra gh call), and a held member
# must never be parked `.blocked`, paged, or dropped from the queue — it is
# waiting for its train, not for a human.
#
# BH-1366 moved this file from tests/tier2-merge-sweep-test.sh when the tier-2
# sweep retired: sections A and A' (bin/merge-queue.sh) survive verbatim; the
# sweep-only sections B and C went with the script they drove.
#
# Run from anywhere: tests/merge-queue-batch-hold.bh-1366-test.sh   (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
# BH-1247: catalog/lanes.json and cron/<box>.cron are GENERATED and not
# committed. rendered_registry / rendered_cron render this repo's own into $T.
. "$(dirname "$0")/lib/rendered.sh" || exit 1
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }

Q="$T/h/state/merge-queue/p"
MQLOG="$T/h/logs/merge-queue.log"
H0=0000aaaa0000                       # an older head: the train's copy is stale
H1=1111bbbb1111                       # the head the PR is on right now
TRAIN=https://github.com/o/p/pull/99  # the train PR that carries the members

mkdir -p "$T/h/bin/lib" "$T/h/logs" "$T/h/state" "$T/h/flags" "$T/h/locks" \
         "$T/h/env" "$T/h/builds" "$Q" "$T/fakebin" "$T/trainbin" "$T/wt"
cp "$DIR/bin/merge-queue.sh" "$DIR/bin/fleet-conf.sh" "$T/h/bin/"
cp "$DIR/bin/lib/gh-pr-list.sh" "$DIR/bin/lib/merge-conductor-lib.sh" "$DIR/bin/lib/gh-rest.sh" "$DIR/bin/lib/gh-rest-var.sh" "$T/h/bin/lib/"
# bin/lib/gh-rest.sh rides with the lib: since BH-784 both lanes read the PR
# through it, and a fixture tree without it leaves the fail-closed shim answering
# "unverifiable" to every read — every case below would then pass for the wrong
# reason (nothing merges, nothing enqueues).
cp "$DIR/tests/lib/rest-emit.sh" "$T/fakebin/restpr"; chmod +x "$T/fakebin/restpr"
# The lane gate is part of the shipped script now (BH-1165), so the fixture
# carries it: without bin/lib/lane-gate.sh every `command -v` guard in the
# header is false and the per-project switch below would be untestable — the
# suite would pass on a sweep that ignores it, which is exactly the defect.
mkdir -p "$T/h/catalog"
cp "$DIR/bin/lib/lane-gate.sh" "$T/h/bin/lib/"
cp "$(rendered_registry)" "$T/h/catalog/lanes.json"
mkdir -p "$T/h/bin/lib/mc" && cp "$DIR"/bin/lib/mc/*.sh "$T/h/bin/lib/mc/"
printf 'p o/p - - 2 box-p\n' > "$T/h/fleet.conf"
export FLEET_CONF="$T/h/fleet.conf"
: > "$T/h/env/global.env"; : > "$T/h/env/p.env"

printf '#!/bin/bash\nexit 0\n' > "$T/fakebin/flock"; chmod +x "$T/fakebin/flock"
printf '#!/bin/bash\nprintf "{}\\n404\\n"\n' > "$T/fakebin/curl"; chmod +x "$T/fakebin/curl"
# The queue's settle waits (sleep 4/5/10 around a landing) are wall-clock time
# this fixture has no use for, and a suite that really waits is a suite nobody
# runs. Stubbed, so nothing here reads the clock.
printf '#!/bin/bash\nexit 0\n' > "$T/fakebin/sleep"; chmod +x "$T/fakebin/sleep"
# git: RECORDED and failing. There is no /root/repos/p in this fixture, so a
# lane that reaches for a worktree or a push is itself the finding (AT-5).
cat > "$T/fakebin/git" <<EOF
#!/bin/bash
printf '%s\n' "\$*" >> "$T/git-calls.txt"
exit 1
EOF
chmod +x "$T/fakebin/git"
# The train driver (§A′) needs the union merge to SUCCEED so the loop's own
# decision — member taken, member skipped — is what the assertion reads.
printf '#!/bin/bash\nexit 0\n' > "$T/trainbin/git"; chmod +x "$T/trainbin/git"
cat > "$T/h/bin/beat.sh" <<EOF
#!/bin/bash
printf '%s\n' "\$*" >> "$T/beats.txt"
exit 0
EOF
cat > "$T/h/bin/lander.sh" <<EOF
#!/bin/bash
printf '%s\n' "\$*" >> "$T/lander-calls.txt"
exit 1
EOF
printf '#!/bin/bash\nexit 0\n' > "$T/h/bin/deploy-request.sh"
chmod +x "$T/h/bin/beat.sh" "$T/h/bin/lander.sh" "$T/h/bin/deploy-request.sh"
# gh: every call recorded, a merge recorded separately — "did anything try to
# land this PR" is then a fact and not a reading of the code. The PR's state,
# mergeability and head come from files the cases set.
#
# THE READS ARE REST (BH-784). Both lanes ask the same one endpoint —
# gh api -i -X GET repos/o/p/pulls/N — for state, mergeability, head and merge
# sha, and bin/lib/gh-rest.sh judges the HTTP STATUS LINE, so the stub prints a
# whole response through restpr (tests/lib/rest-emit.sh) instead of a word.
# One arm answers for every PR number in this fixture, from the same three files
# the GraphQL arms read.
cat > "$T/fakebin/gh" <<EOF
#!/bin/bash
printf '%s\n' "\$*" >> "$T/gh-calls.txt"
case "\$*" in
  *"pr merge"*) printf '%s\n' "\$*" >> "$T/merge-calls.txt"; echo MERGED > "$T/prstate"; exit 0 ;;
  *"api repos/"*"/rulesets"*) : ;;
  *"api rate_limit"*) echo '{"resources":{"core":{"remaining":5000,"limit":5000,"reset":2000000000},"graphql":{"remaining":5000,"limit":5000,"reset":2000000000}}}' ;;
  *"api -i -X GET repos/o/p/pulls/"*)
    restpr "\$(cat "$T/prstate")" "\$(cat "$T/prhead" 2>/dev/null)" ticket/x main "" \\
           "\$(cat "$T/mergeable")" CLEAN app/cromford deadbeefcafe ;;
  *) echo "" ;;
esac
exit 0
EOF
chmod +x "$T/fakebin/gh"

# The markers are written and removed through the REAL lib — the point of the
# ticket is that these lanes read the same marker batch-resolve writes, so a
# fixture that hand-rolled the file format would prove nothing about the lane.
lib_do() { ( export HARNESS="$T/h"
             . "$T/h/bin/lib/merge-conductor-lib.sh"
             "$@" ); }
hold()   { lib_do mc_batch_hold "${3:-o/p}" "$1" "$2" "$TRAIN"; }
empty_marker() { ( export HARNESS="$T/h"
                   . "$T/h/bin/lib/merge-conductor-lib.sh"
                   mc_batch_hold o/p "$1" "$H1" "$TRAIN"
                   : > "$(mc_batch_file o/p "$1")" ); }
clear_holds() { local n
                for n in 7 8 9; do lib_do mc_batch_release o/p "$n"
                                   lib_do mc_batch_release o/q "$n"; done; }

mq() { ( cd "$T" && PATH="$T/fakebin:$PATH" HARNESS="$T/h" MC_QUEUE_TTL=0 \
  bash "$T/h/bin/merge-queue.sh" p >/dev/null 2>&1 ) || true; }

reset_case() {
  rm -f "$Q"/*
  clear_holds
  : > "$T/merge-calls.txt"; : > "$T/gh-calls.txt"; : > "$T/git-calls.txt"
  : > "$T/lander-calls.txt"; : > "$T/beats.txt"
  : > "$MQLOG"
  echo OPEN > "$T/prstate"; echo MERGEABLE > "$T/mergeable"
  printf '%s' "$H1" > "$T/prhead"
}

# ============================================================================
# A. bin/merge-queue.sh — the serial landing path (the one that runs gh pr merge)
# ============================================================================

# AT-1 — a hold for the CURRENT head: not merged, entry KEPT, one log line that
#        names the train, and no park/no page (the PR is waiting for its train).
reset_case; touch "$Q/7"; hold 7 "$H1"; mq
[ -s "$T/merge-calls.txt" ] && bad "AT-1: the merge queue landed a member of a live batch train: $(cat "$T/merge-calls.txt")" || ok
[ -f "$Q/7" ] && ok || bad "AT-1: the held entry was dropped from the queue — the train's landing must hand it straight back"
[ -f "$Q/7.blocked" ] && bad "AT-1: a held member was parked .blocked — a train owns it, no human does" || ok
[ -s "$T/beats.txt" ] && bad "AT-1: a held member paged: $(cat "$T/beats.txt")" || ok
grep -q "#7 HELD on 1111bbbb" "$MQLOG" && ok || bad "AT-1: no HELD line for #7 on its head: $(cat "$MQLOG")"
grep -qF "$TRAIN" "$MQLOG" && ok || bad "AT-1: the skip does not name the train url: $(cat "$MQLOG")"
grep -qF 'bin/batch-resolve.sh closes it out' "$MQLOG" && ok || bad "AT-1: the skip does not say who closes the PR out: $(cat "$MQLOG")"

# AT-2 — a hold for an OLDER head is not a hold: the head the train was built
#        from is gone, so this PR is the queue's again and it lands.
reset_case; touch "$Q/7"; hold 7 "$H0"; mq
grep -qF 'pr merge 7 -R o/p --squash' "$T/merge-calls.txt" && ok || bad "AT-2: a hold for an older head blocked the landing — holds are head-keyed"
[ -f "$Q/7" ] && bad "AT-2: the landed entry was left in the queue" || ok
grep -q 'HELD' "$MQLOG" && bad "AT-2: a stale hold was logged as a hold: $(cat "$MQLOG")" || ok

# AT-3 — no marker: byte-for-byte today's behaviour, and not one extra gh call.
reset_case; touch "$Q/7"; mq
grep -qF 'pr merge 7 -R o/p --squash' "$T/merge-calls.txt" && ok || bad "AT-3: an unheld PR was not merged"
grep -qF -- '--json headRefOid' "$T/gh-calls.txt" && bad "AT-3: the no-marker path spent a gh head read: $(grep -F -- '--json headRefOid' "$T/gh-calls.txt")" || ok

# AT-3n — the negatives the lib keys on: another PR, another repo, an empty file.
reset_case; touch "$Q/7"; hold 8 "$H1"; mq
grep -qF 'pr merge 7 -R o/p --squash' "$T/merge-calls.txt" && ok || bad "AT-3n: a hold on #8 held #7"
reset_case; touch "$Q/7"; hold 7 "$H1" o/q; mq
grep -qF 'pr merge 7 -R o/p --squash' "$T/merge-calls.txt" && ok || bad "AT-3n: a hold on o/q#7 held o/p#7"
reset_case; touch "$Q/7"; empty_marker 7; mq
grep -qF 'pr merge 7 -R o/p --squash' "$T/merge-calls.txt" && ok || bad "AT-3n: an empty marker file held #7 — the lib reads it as no hold"

# AT-5 — CONFLICTING + held: the queue must not rebase or force-push a member,
#        that would rewrite the very head the train was built from. And no
#        lander: an agent resolution here is a model call spent on a head this
#        lane has already decided not to land.
reset_case; echo CONFLICTING > "$T/mergeable"; touch "$Q/7"; hold 7 "$H1"; mq
[ -s "$T/git-calls.txt" ] && bad "AT-5: the queue went for the repo on a held member: $(cat "$T/git-calls.txt")" || ok
[ -s "$T/lander-calls.txt" ] && bad "AT-5: the lander was spent on a held member: $(cat "$T/lander-calls.txt")" || ok
[ -s "$T/merge-calls.txt" ] && bad "AT-5: a conflicting held member was merged" || ok
[ -f "$Q/7" ] && ok || bad "AT-5: the held entry was dropped"
[ -f "$Q/7.blocked" ] && bad "AT-5: a held member was parked .blocked" || ok

# AT-5u — marker present, head unreadable (a gh outage): HELD. A train owns this
#         PR and nothing proves the head moved; skipping is reversible next pass,
#         merging is not.
reset_case; : > "$T/prhead"; touch "$Q/7"; hold 7 "$H1"; mq
[ -s "$T/merge-calls.txt" ] && bad "AT-5u: an unreadable head fell open to a merge on a held PR" || ok
[ -f "$Q/7" ] && ok || bad "AT-5u: the held entry was dropped on an unreadable head"
grep -q 'head could not be read' "$MQLOG" && ok || bad "AT-5u: the unreadable-head skip said nothing: $(cat "$MQLOG")"
grep -qF 'pull/7' "$MQLOG" && ok || bad "AT-5u: the unreadable-head skip does not name the PR: $(cat "$MQLOG")"

# AT-5c — the train landed and batch-resolve closed the member: the not-OPEN
#         dequeue still runs FIRST, so the hold never strands a finished PR.
reset_case; echo CLOSED > "$T/prstate"; touch "$Q/7"; hold 7 "$H1"; mq
[ -f "$Q/7" ] && bad "AT-5c: a CLOSED held PR stayed in the queue for ever" || ok

# ============================================================================
# A′. bin/merge-queue.sh — the merge train, the path that actually lands in bulk
#     (the union loop needs a real repo at the hard-coded /root/repos/$PROJECT,
#     so it is driven the way tests/head-bound-approval-test.sh §5e drives it:
#     the production blocks, extracted verbatim by their markers)
# ============================================================================
awk '/^# >>> batch-hold gate/{f=1;next} /^# <<< batch-hold gate/{exit} f' \
  "$DIR/bin/merge-queue.sh" > "$T/mq-bh.sh"
[ -s "$T/mq-bh.sh" ] && ok || bad "could not extract the batch-hold gate from bin/merge-queue.sh — markers missing?"
grep -q 'bh_held()' "$T/mq-bh.sh" && ok || bad "the queue's batch-hold check is not a function — the merge train cannot share it"
awk '/# >>> head-bound train members/{f=1;next} /# <<< head-bound train members/{exit} f' \
  "$DIR/bin/merge-queue.sh" > "$T/mq-train-members.sh"
[ -s "$T/mq-train-members.sh" ] && ok || bad "could not extract the merge train's member loop"
# The member loop reads the PR through the queue's own one-line reader (mq_pr ->
# mc_pr_view -> the REST contract, BH-784), so that line is lifted VERBATIM out
# of bin/merge-queue.sh too — a hand-rolled copy here would be a second reader
# that could drift from the one the lane actually uses.
grep '^mq_pr()' "$DIR/bin/merge-queue.sh" > "$T/mq-read.sh"
[ -s "$T/mq-read.sh" ] && ok || bad "could not extract the queue's PR read (mq_pr) from bin/merge-queue.sh"
{ cat "$T/mq-read.sh"; cat "$T/mq-bh.sh"; cat "$T/mq-train-members.sh"
  echo 'echo "BATCH=$BATCH" > "$REACHED"'; } > "$T/mq-train.sh"

train_run() {
  rm -f "$T/reached"; : > "$MQLOG"
  ( cd "$T" && PATH="$T/trainbin:$T/fakebin:$PATH" \
    env HARNESS="$T/h" Q="$Q" QUEUED="7 8" BATCH="" WT="$T/wt" PROJECT=p SLUG=o/p \
        LOG="$MQLOG" REACHED="$T/reached" \
    bash -c 'set -uo pipefail
      STAMP() { echo TS; }
      hb_blocked() { return 1; }
      . "$HARNESS/bin/lib/merge-conductor-lib.sh"
      . "$0"' "$T/mq-train.sh" >/dev/null 2>&1 ) || true
}

# AT-4 — the held member never enters the union: not merged into the candidate,
#        not typechecked with it, not landed by the cheap gh merges after it.
#        Its sibling still rides.
reset_case; touch "$Q/7" "$Q/8"; hold 7 "$H1"; train_run
grep -q '\b8\b' "$T/reached" && ok || bad "AT-4: the train dropped an unheld member: $(cat "$T/reached" 2>/dev/null)"
grep -q '\b7\b' "$T/reached" && bad "AT-4: the train took a held member into the union: $(cat "$T/reached")" || ok
[ -f "$Q/7" ] && [ -f "$Q/8" ] && ok || bad "AT-4: the train path dropped a queue entry"
grep -qF "$TRAIN" "$MQLOG" && ok || bad "AT-4: the train path's skip does not name the train url: $(cat "$MQLOG")"

# AT-4b — an older head on the marker: both members ride, as before the gate.
reset_case; touch "$Q/7" "$Q/8"; hold 7 "$H0"; train_run
grep -q '\b7\b' "$T/reached" && grep -q '\b8\b' "$T/reached" \
  && ok || bad "AT-4b: a hold for an older head kept a member out of the union: $(cat "$T/reached" 2>/dev/null)"

echo "merge-queue-batch-hold.bh-1366-test: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
