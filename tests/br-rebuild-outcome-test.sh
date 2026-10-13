#!/bin/bash
# tests/br-rebuild-outcome-test.sh — THE REBUILD'S OWN OUTCOME: what the lane
# does after the rebuild it bought has run. The last section of the old
# tests/blocked-resolver-test.sh, moved here verbatim by BH-1196.
#
# WHY IT IS ITS OWN SUITE. Every other rung ends where the lane's decision ends;
# this one ends somewhere else entirely, in a build's RESULT that lands minutes
# later, and it is the only section that reads it. 2026-09-16 is why it exists:
# project-5 #1634, #1645, #1642 and #1626 were rebuilt and the lane never looked
# at what came back.
#
# Sections carried (from tests/blocked-resolver-test.sh):
#   11. the rebuild's own outcome — the old suite's SECOND "9." section, a
#       duplicate number, renumbered here so no two sections share an id.
# Run from anywhere: tests/br-rebuild-outcome-test.sh   (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }

# The whole fixture — scratch tree, br modules, sibling libs, the stubbed PATH
# and the RUN/ROW/ROWST/STATEJSON/SPENT helpers — is tests/lib/fixture-harness.sh
# (BH-1196). What is installed and why is documented there.
# shellcheck source=tests/lib/fixture-harness.sh
. "$DIR/tests/lib/fixture-harness.sh" || exit 1
H="$T/h"
mkdir -p "$H/bin"
# The scripts this suite drives. The copy stays HERE, in the suite's own text,
# so bin/test-impact.sh still selects this suite when one of them changes.
cp "$DIR/bin/blocked-resolver.sh" "$DIR/bin/fly-pool.sh" "$DIR/bin/merge-sweep.sh" \
   "$DIR/bin/merge-conductor.sh" "$DIR/bin/fleet-conf.sh" "$DIR/bin/project-of.sh" \
   "$DIR/bin/box-for.sh" "$H/bin/"
cp "$DIR/bin/alert-line.sh" "$H/bin/"
fx_br_harness "$DIR" "$T" || exit 1
[ -d "$DIR/bin/lib/br" ] || exit 1   # impact: this suite runs when bin/lib/br/ changes

# ============================================================================
# 11. THE REBUILD'S OWN OUTCOME (2026-09-16: project-5 #1634, #1645, #1642, #1626).
#     (was the second "9." in tests/blocked-resolver-test.sh — a duplicate number)
#
#    Four conflict-unresolvable PRs reached rung 3 and every one of them was
#    still parked hours later, for two blind spots on the same rung:
#
#      * #1634 refused its enqueue with "no ticket key" at 14:04Z and then
#        refused it identically every ten minutes for three hours. A refusal
#        that spends nothing is a refusal that repeats for ever, so it is now
#        counted like any other failed rung attempt and capped.
#      * #1645's rebuild WAS enqueued (14:24Z) and ended DECOMPOSE_FAILED at
#        14:39Z — and nothing read that. The lane had three discovery sources
#        and not one of them was "the rebuild I started has finished", so the
#        rung never completed: no rebuild 2, no abandon, no ticket comment. The
#        client-facing record still said "Built and opened for review".
#
#    So the rebuild's terminal outcome is a discovery source of its own, and the
#    assertions below are on what the run WROTE — the state json, the queue, the
#    conductor row, ALERTS.log and the comment the ticket actually received.
# ============================================================================
NOW=$(date -u +%s)
AT=$(date -u -d "@$((NOW-3600))" '+%Y-%m-%d %H:%M:%SZ')

# The gh stub for this section: the parked PR's state is a file (a rebuild park
# normally points at a PR the rung already CLOSED), and every comment is
# recorded so "did this ticket get told" is a fact about the run.
cat > "$T/fakebin/gh" <<EOF
#!/bin/bash
printf '%s\n' "\$*" >> "$T/gh.txt"
case "\$*" in
  # bin/blocked-resolver.sh reads, comments and closes over REST (#783): the
  # gh-api-dash-i envelope is answered once, in tests/lib/gh-rest-stub.sh.
  *"-i -X "*) GHT="$T"; . "$DIR/tests/lib/gh-rest-stub.sh"; gh_rest_stub "\$@" ;;
  *"pr close"*) printf '%s\n' "\$*" >> "$T/closed.txt"; exit 0 ;;
  *"issue comment"*|*"pr comment"*) printf '%s\n' "\$*" >> "$T/comments.txt"; exit 0 ;;
  *"--json state"*) cat "$T/prstate" 2>/dev/null || echo OPEN ;;
  *"/pulls/"*) _h=\$(<"$T/prhead"); _b=\$(<"$T/prbranch"); echo "\${_h:-null} \${_b:-null}" ;;
  *"--json headRefOid,headRefName"*) echo "\$(cat "$T/prhead") \$(cat "$T/prbranch")" ;;
  *"--json headRefName"*) cat "$T/prbranch" ;;
  *"--json headRefOid"*)  cat "$T/prhead" ;;
  *"--json title"*)       cat "$T/prtitle" 2>/dev/null ;;
  *"pr list"*) : ;;
  *) echo "" ;;
esac
exit 0
EOF
chmod +x "$T/fakebin/gh"
: > "$T/prtitle"; : > "$T/mergedprs"; : > "$T/comments.txt"; : > "$T/comment-bodies.txt"
touch "$H/flags/fly-pool-tproj"
cat > "$H/bin/jobs-client.sh" <<EOF
queue_put() { printf '%s\n' "\$*" >> "$T/queue.txt"; echo queued; }
queue_done() { printf 'done %s\n' "\$*" >> "$T/queue.txt"; return 0; }
queue_list() { return 1; }
EOF

# ---- 9a. A NOKEY REFUSAL IS COUNTED AND CAPPED — the #1634 shape exactly.
#          record "-", a head branch that is not a ticket branch, no title: the
#          key genuinely is not derivable, so the enqueue is refused. What must
#          NOT happen is the same refusal, free, every tick for ever.
scratch_rm "$H/state/blocked-resolver"
: > "$H/state/merge-conductor/pr-state.tsv"
printf 'feature/x' > "$T/prbranch"; : > "$T/prhead"; echo OPEN > "$T/prstate"
SPENT o-tproj-1634
ROW "o/tproj#1634" "conflict-unresolvable: CONFLICT (content): src/a.ts" "https://github.com/o/tproj/pull/1634"
: > "$T/queue.txt"; : > "$T/closed.txt"; : > "$T/lane-alert.txt"; : > "$H/logs/ALERTS.log"
RUN
grep -q 'pull/1634' "$T/lane-alert.txt" && ok \
  || bad "a no-key refusal must still page once with the PR url (got: $(cat "$T/lane-alert.txt"))"
[ "$(STATEJSON o-tproj-1634 | jq -r .rebuilds)" = 1 ] && ok \
  || bad "THE #1634 BUG: a nokey refusal must SPEND the rung attempt it made (rebuilds=$(STATEJSON o-tproj-1634 | jq -r .rebuilds))"
[ "$(STATEJSON o-tproj-1634 | jq -r '[.attempts[].action] | index("rebuild-fresh-nokey") != null')" = true ] && ok \
  || bad "the no-key refusal must be recorded under its own action word rebuild-fresh-nokey"
[ "$(STATEJSON o-tproj-1634 | jq -r .outcome)" = "" ] && ok \
  || bad "one no-key refusal is not the cap (outcome '$(STATEJSON o-tproj-1634 | jq -r .outcome)')"
: > "$T/lane-alert.txt"
RUN
[ -s "$T/lane-alert.txt" ] && bad "the nokey alert must page once per key, not once per tick" || ok
[ "$(STATEJSON o-tproj-1634 | jq -r .rebuilds)" = 2 ] && ok \
  || bad "the second no-key refusal must be counted too (rebuilds=$(STATEJSON o-tproj-1634 | jq -r .rebuilds))"
RUN
[ "$(STATEJSON o-tproj-1634 | jq -r .outcome)" = ABANDONED ] && ok \
  || bad "the third identical no-key refusal must end the ladder with ABANDONED (got '$(STATEJSON o-tproj-1634 | jq -r .outcome)')"
[ "$(grep -c 'ABANDONED tproj/o-tproj-1634' "$H/logs/ALERTS.log")" = 1 ] && ok \
  || bad "the nokey cap must write exactly one ABANDONED line (got $(grep -c 'ABANDONED tproj/o-tproj-1634' "$H/logs/ALERTS.log"))"
grep -q 'no ticket key' "$H/logs/ALERTS.log" && ok \
  || bad "the ABANDONED line must say WHY it stopped: no ticket key could be derived"
grep -q '^tproj ' "$T/queue.txt" \
  && bad "a no-key park must never enqueue anything (got: $(cat "$T/queue.txt"))" || ok
# A key that CANNOT be derived is not the same as one that can: the counter must
# not fire on the no-ticket-ID refusal, which §2e pins at rebuilds=0.
RUN
[ "$(STATEJSON o-tproj-1634 | jq -r .rebuilds)" = 3 ] && ok \
  || bad "an ABANDONED no-key park is terminal and must not keep counting (rebuilds=$(STATEJSON o-tproj-1634 | jq -r .rebuilds))"

# ---- 9b. THE BRANCH CARRIES THE KEY (regression pin, green since PR #497).
#          #1634's key was in `ticket/TK-1602` the whole time. This is the
#          driven proof that rung 3 reads it, so the nokey cap above can only
#          ever fire on a branch that really has no key.
scratch_rm "$H/state/blocked-resolver"
printf 'ticket/TK-1602' > "$T/prbranch"
SPENT tproj-TK-1602
ROW "o/tproj#1635" "conflict-unresolvable: CONFLICT (content): src/a.ts" "https://github.com/o/tproj/pull/1635"
: > "$T/queue.txt"; : > "$T/lane-alert.txt"
RUN
grep -q '^tproj TK-1602 1602 fly 0 ' "$T/queue.txt" && ok \
  || bad "a record-less park on branch ticket/TK-1602 must enqueue TK-1602 (queue: $(cat "$T/queue.txt"))"
[ -s "$T/lane-alert.txt" ] \
  && bad "a park whose branch names TK-1602 must not page nokey (got: $(cat "$T/lane-alert.txt"))" || ok
[ "$(STATEJSON tproj-TK-1602 | jq -r .parked_url)" = "https://github.com/o/tproj/pull/1635" ] && ok \
  || bad "a successful rebuild must remember the PR it parked, so the abandon can name and move it (got '$(STATEJSON tproj-TK-1602 | jq -r .parked_url)')"

# ---- 9c. THE REBUILD'S TERMINAL OUTCOME, one sub-case per RESULT line.
# Older sections left TK-9 build dirs behind; they are another ticket's
# evidence, not this one's rebuild.
for d in "$H"/builds/*TK-9-*; do [ -e "$d" ] && scratch_rm "$d"; done
printf 'ticket/TK-9' > "$T/prbranch"; echo CLOSED > "$T/prstate"
SEED9() { # SEED9 [rebuilds] — a ticket whose LAST action was a fresh rebuild
  scratch_rm "$H/state/blocked-resolver"
  mkdir -p "$H/state/blocked-resolver/tproj"
  jq -nc --arg at "$AT" --argjson n "${1:-1}" \
    '{project:"tproj",rkey:"tproj-TK-9",mechanicals:1,fixrounds:1,rebuilds:$n,outcome:"",
      parked_url:"https://github.com/o/tproj/pull/9",
      attempts:[{at:$at,action:"rebuild-fresh",reason:"conflict-unresolvable",
                 detail:"fresh build enqueued against current main (rebuild 1 of 3)"}]}' \
    > "$H/state/blocked-resolver/tproj/tproj-TK-9.json"
}
REBDIR() { # REBDIR <dir-name> <RESULT first line> [mtime-epoch] — the rebuild's record
  local d="$H/builds/$1"
  [ -e "$d" ] && scratch_rm "$d"
  mkdir -p "$d"; printf '%s\n' "$2" > "$d/RESULT"
  touch -d "@${3:-$NOW}" "$d/RESULT"
  printf '%s' "$d"
}
RESET9() { : > "$T/queue.txt"; : > "$T/closed.txt"; : > "$T/comments.txt"; : > "$T/comment-bodies.txt"
           : > "$T/lane-alert.txt"; : > "$H/logs/ALERTS.log"; : > "$H/logs/blocked-resolver.log"
           for d in "$H"/builds/*TK-9-*; do [ -e "$d" ] && scratch_rm "$d"; done; }

# --- DECOMPOSE_FAILED: a ticket-level stop. Another rebuild ends the same way.
RESET9; SEED9 1
ROW "o/tproj#9" "conflict-unresolvable: CONFLICT (content): src/a.ts" "https://github.com/o/tproj/pull/9"
D9=$(REBDIR "pool-tproj-TK-9-202609161439" "DECOMPOSE_FAILED see $H/builds/pool-tproj-TK-9-202609161439/decompose-run.txt")
RUN
[ "$(STATEJSON tproj-TK-9 | jq -r .outcome)" = ABANDONED ] && ok \
  || bad "THE #1645 BUG: a rebuild that ended DECOMPOSE_FAILED must reach ABANDONED, not sit for ever (outcome '$(STATEJSON tproj-TK-9 | jq -r .outcome)')"
STATEJSON tproj-TK-9 | jq -r '.attempts[-1].detail' | grep -q 'DECOMPOSE_FAILED' && ok \
  || bad "the ABANDONED record must name the real rebuild outcome DECOMPOSE_FAILED (got '$(STATEJSON tproj-TK-9 | jq -r '.attempts[-1].detail')')"
[ -f "$D9/.blocked-resolver-abandoned" ] && ok \
  || bad "the consumed rebuild outcome record must be marked abandoned so no later sweep re-offers it"
[ "$(grep -c 'ABANDONED tproj/tproj-TK-9' "$H/logs/ALERTS.log")" = 1 ] && ok \
  || bad "an abandoned rebuild outcome writes exactly one ALERTS line (got $(grep -c 'ABANDONED tproj/tproj-TK-9' "$H/logs/ALERTS.log"))"
# THE POST IS THE COUNT, THE BODY FILE IS THE TEXT (#783): the comment goes out
# as `gh api -i -X POST repos/o/tproj/issues/9/comments -F body=@<file>`, so the
# body never appears in argv and the stub keeps it in comment-bodies.txt.
[ "$(grep -c 'issues/9/comments' "$T/comments.txt")" = 1 ] && ok \
  || bad "the ticket must get exactly ONE comment when its rebuild blocks (issues/9/comments count: $(grep -c 'issues/9/comments' "$T/comments.txt"))"
grep -q 'DECOMPOSE_FAILED' "$T/comment-bodies.txt" && ok \
  || bad "the ticket comment must name the outcome DECOMPOSE_FAILED (got: $(cat "$T/comment-bodies.txt"))"
grep -q 'decompose-run.txt' "$T/comment-bodies.txt" && ok \
  || bad "the ticket comment must name the artifact to read (got: $(cat "$T/comment-bodies.txt"))"
grep -iE 'needs a human|by hand|for the operator|As an AI' "$T/comment-bodies.txt" >/dev/null 2>&1 \
  && bad "the ticket comment must never ask for a human or read like a machine: $(cat "$T/comment-bodies.txt")" || ok
[ "$(awk -F'\t' '$1=="o/tproj#9"{print $2}' "$H/state/merge-conductor/pr-state.tsv")" = ABANDONED ] && ok \
  || bad "the parked PR's conductor row must move to ABANDONED so nothing counts it in flight (got '$(awk -F'\t' '$1=="o/tproj#9"{print $2}' "$H/state/merge-conductor/pr-state.tsv")')"
grep -q 'done tproj TK-9 failed' "$T/queue.txt" && ok \
  || bad "the abandon must close the pool queue row failed (got: $(cat "$T/queue.txt"))"
# And the NEXT tick says nothing at all: a client ticket never gets told twice.
CBEFORE=$(wc -l < "$T/comments.txt"); ABEFORE=$(wc -l < "$H/logs/ALERTS.log")
RUN
[ "$(wc -l < "$T/comments.txt")" = "$CBEFORE" ] && ok \
  || bad "a second tick must not post a second comment on the same rebuild outcome"
[ "$(wc -l < "$H/logs/ALERTS.log")" = "$ABEFORE" ] && ok \
  || bad "a second tick must not write a second ALERTS line either"
# ...and the at-most-once marker is what carries that, not the terminal outcome.
# Driven where the terminal guard is GONE: the ticket is walked back into the
# ladder (outcome cleared, a fresh rebuild attempt on the record) with a SECOND
# rebuild record answering the same way. A client ticket told twice about one
# stop is the worse failure, so the marker — written before the post — refuses.
jq -c --arg at "$AT" '.outcome="" | .attempts += [{at:$at,action:"rebuild-fresh",
    reason:"conflict-unresolvable",detail:"re-offered after the outcome was walked back"}]' \
  "$H/state/blocked-resolver/tproj/tproj-TK-9.json" > "$T/reoffer.json" \
  && mv "$T/reoffer.json" "$H/state/blocked-resolver/tproj/tproj-TK-9.json"
REBDIR "pool-tproj-TK-9-202609161450" "DECOMPOSE_FAILED see /x/decompose-run.txt" >/dev/null
: > "$T/comments.txt"; : > "$H/logs/blocked-resolver.log"
RUN
[ -s "$T/comments.txt" ] \
  && bad "a ticket already told about its rebuild must never get a second comment: $(cat "$T/comments.txt")" || ok
[ "$(STATEJSON tproj-TK-9 | jq -r .outcome)" = ABANDONED ] && ok \
  || bad "the re-offered rebuild outcome must still reach ABANDONED (got '$(STATEJSON tproj-TK-9 | jq -r .outcome)')"
grep -q 'already been told' "$H/logs/blocked-resolver.log" && ok \
  || bad "the run must SAY the second comment was refused because this ticket was already told (log: $(tail -3 "$H/logs/blocked-resolver.log"))"

# --- PLAN_BLOCKED: same terminal, different artifact.
RESET9; SEED9 1
: > "$H/state/merge-conductor/pr-state.tsv"
# BH-3971: the comment QUOTES the plan's question instead of naming plan.md, a
# path on the build machine the client cannot open. The resolver scrubs the
# quote first, so the scrubber rides in the fixture tree.
cp "$DIR/bin/transcript-scrub.sh" "$H/bin/"; mkdir -p "$H/bin/lib"; cp "$DIR/bin/lib/env-path.sh" "$H/bin/lib/"
D9P=$(REBDIR "pool-tproj-TK-9-202609161500" "PLAN_BLOCKED the ticket does not say which rate applies, see $H/builds/pool-tproj-TK-9-202609161500/plan.md")
printf 'BLOCKED-NEEDS-CLARIFICATION\n1. Which rate applies to a late invoice?\n' > "$D9P/plan.md"
RUN
[ "$(STATEJSON tproj-TK-9 | jq -r .outcome)" = ABANDONED ] && ok \
  || bad "a rebuild that ended PLAN_BLOCKED must reach ABANDONED (got '$(STATEJSON tproj-TK-9 | jq -r .outcome)')"
grep -qxF '> 1. Which rate applies to a late invoice?' "$T/comment-bodies.txt" && ok \
  || bad "the PLAN_BLOCKED comment must quote the plan's question (got: $(cat "$T/comment-bodies.txt"))"
grep -qF "$H/builds" "$T/comment-bodies.txt" \
  && bad "the PLAN_BLOCKED comment must not point the client at a build-machine path: $(cat "$T/comment-bodies.txt")" || ok

# --- REVIEW_BLOCKED: bin/review-rescue.sh can still turn this record into a
#     PR_CREATED, so it is NOT consumed until that lane is finished with it.
RESET9; SEED9 1
: > "$H/state/merge-conductor/pr-state.tsv"
D9R=$(REBDIR "pool-tproj-TK-9-202609161530" "REVIEW_BLOCKED test-tamper: 2 test cases removed, see $H/builds/pool-tproj-TK-9-202609161530/test-tamper.txt")
RUN
[ "$(STATEJSON tproj-TK-9 | jq -r .outcome)" = "" ] && ok \
  || bad "a REVIEW_BLOCKED rebuild must not be abandoned while review-rescue may still rescue it (got '$(STATEJSON tproj-TK-9 | jq -r .outcome)')"
[ -s "$T/comments.txt" ] \
  && bad "and it must not comment on the ticket either: $(cat "$T/comments.txt")" || ok
touch "$D9R/.review-rescued"
RUN
[ "$(STATEJSON tproj-TK-9 | jq -r .outcome)" = ABANDONED ] && ok \
  || bad "once review-rescued is written the REVIEW_BLOCKED rebuild is consumed (got '$(STATEJSON tproj-TK-9 | jq -r .outcome)')"
[ "$(grep -c 'issues/9/comments' "$T/comments.txt")" = 1 ] && ok \
  || bad "a rescued-and-still-blocked rebuild gets ONE comment (count $(grep -c 'issues/9/comments' "$T/comments.txt"))"

# --- BUILD_DEAD: the machine went away, so it spends the NEXT rebuild counter.
RESET9; SEED9 1
: > "$H/state/merge-conductor/pr-state.tsv"
DD=$(REBDIR "pool-tproj-TK-9-202609161600" "BUILD_DEAD resumed 2 times and the machine went away again")
RUN
[ "$(STATEJSON tproj-TK-9 | jq -r .outcome)" = "" ] && ok \
  || bad "a BUILD_DEAD rebuild is not a ticket-level stop and must not be abandoned (got '$(STATEJSON tproj-TK-9 | jq -r .outcome)')"
[ "$(STATEJSON tproj-TK-9 | jq -r .rebuilds)" = 2 ] && ok \
  || bad "a BUILD_DEAD rebuild must buy rebuild 2 of 3 (rebuilds=$(STATEJSON tproj-TK-9 | jq -r .rebuilds))"
grep -q '^tproj TK-9 9 fly 0 ' "$T/queue.txt" && ok \
  || bad "the BUILD_DEAD rebuild must enqueue the ticket again (queue row: $(cat "$T/queue.txt"))"
grep -q 'r2' "$T/queue.txt" && ok \
  || bad "the re-enqueued BUILD_DEAD rebuild must take the next branch suffix (queue row: $(cat "$T/queue.txt"))"
[ -f "$DD/.blocked-resolver-superseded" ] && ok \
  || bad "the dead rebuild's record must be marked superseded so it is not re-offered as a BUILD_DEAD park"
[ -s "$T/comments.txt" ] \
  && bad "a BUILD_DEAD rebuild must not comment on the ticket — it is still being built: $(cat "$T/comments.txt")" || ok

# --- PR_CREATED: the rebuild LANDED. Nothing is spent, nothing is said, and the
#     conductor owns the new PR from here.
RESET9; SEED9 1
: > "$H/state/merge-conductor/pr-state.tsv"
DL=$(REBDIR "pool-tproj-TK-9-202609161630" "PR_CREATED https://github.com/o/tproj/pull/40")
RUN
[ "$(STATEJSON tproj-TK-9 | jq -r .outcome)" = "" ] && ok \
  || bad "a rebuild-landed outcome must never abandon the ticket (got '$(STATEJSON tproj-TK-9 | jq -r .outcome)')"
[ "$(STATEJSON tproj-TK-9 | jq -r .rebuilds)" = 1 ] && ok \
  || bad "a rebuild that landed a PR must spend no further counter (rebuilds=$(STATEJSON tproj-TK-9 | jq -r .rebuilds))"
[ "$(STATEJSON tproj-TK-9 | jq -r '.attempts[-1].action')" = rebuild-landed ] && ok \
  || bad "the landed rebuild must be recorded as rebuild-landed (got '$(STATEJSON tproj-TK-9 | jq -r '.attempts[-1].action')')"
[ "$(STATEJSON tproj-TK-9 | jq -r '.rebuild_seen[0]')" = "$(basename "$DL")" ] && ok \
  || bad "the consumed rebuild-landed record must be remembered (got '$(STATEJSON tproj-TK-9 | jq -r '.rebuild_seen[0]')')"
[ -s "$T/queue.txt" ] && bad "a landed rebuild must not enqueue anything (got: $(cat "$T/queue.txt"))" || ok
[ -s "$T/comments.txt" ] && bad "a landed rebuild must not comment (got: $(cat "$T/comments.txt"))" || ok
LEN=$(STATEJSON tproj-TK-9 | jq -r '.attempts | length')
RUN
[ "$(STATEJSON tproj-TK-9 | jq -r '.attempts | length')" = "$LEN" ] && ok \
  || bad "a rebuild-landed record must be consumed ONCE, not re-recorded every tick"

# --- NEGATIVES: records that must NOT be read as this rebuild's outcome.
RESET9; SEED9 1
: > "$H/state/merge-conductor/pr-state.tsv"
REBDIR "pool-tproj-TK-9-202609150001" "DECOMPOSE_FAILED see /x/decompose-run.txt" "$((NOW-7200))" >/dev/null
RUN
[ "$(STATEJSON tproj-TK-9 | jq -r .outcome)" = "" ] && ok \
  || bad "a rebuild outcome OLDER than the rebuild attempt is a pre-park build and must not be consumed"
RESET9; SEED9 1
REBDIR "pool-tproj-TK-9-202609161700" "BUILD_DEFERRED over the box cap" >/dev/null
RUN
[ "$(STATEJSON tproj-TK-9 | jq -r '.attempts | length')" = 1 ] && ok \
  || bad "a BUILD_DEFERRED rebuild belongs to the lane that owns it and must not be consumed here"
RESET9; SEED9 1
D9S=$(REBDIR "pool-tproj-TK-9-202609161710" "DECOMPOSE_FAILED see /x/decompose-run.txt")
: > "$D9S/.blocked-resolver-superseded"
RUN
[ "$(STATEJSON tproj-TK-9 | jq -r .outcome)" = "" ] && ok \
  || bad "a rebuild outcome record already marked superseded must not be consumed again"
# A state whose last action is NOT a fresh rebuild has no rebuild in flight.
RESET9
scratch_rm "$H/state/blocked-resolver"; mkdir -p "$H/state/blocked-resolver/tproj"
jq -nc --arg at "$AT" '{project:"tproj",rkey:"tproj-TK-9",mechanicals:1,fixrounds:0,rebuilds:0,outcome:"",
   attempts:[{at:$at,action:"mechanical",reason:"conflict-unresolvable",detail:"merged origin/main"}]}' \
  > "$H/state/blocked-resolver/tproj/tproj-TK-9.json"
REBDIR "pool-tproj-TK-9-202609161720" "DECOMPOSE_FAILED see /x/decompose-run.txt" >/dev/null
RUN
[ "$(STATEJSON tproj-TK-9 | jq -r .outcome)" = "" ] && ok \
  || bad "a ticket with no rebuild in flight must not be abandoned by some other build's outcome"
# OBSERVE writes nothing and says what it would have done.
RESET9; SEED9 1
REBDIR "pool-tproj-TK-9-202609161730" "DECOMPOSE_FAILED see /x/decompose-run.txt" >/dev/null
touch "$H/flags/blocked-resolver-observe"
RUN
rm -f "$H/flags/blocked-resolver-observe"
[ "$(STATEJSON tproj-TK-9 | jq -r .outcome)" = "" ] && ok \
  || bad "observe mode must not abandon a rebuild outcome"
[ -s "$T/comments.txt" ] && bad "observe mode must not comment on the ticket" || ok
grep -q 'WOULD' "$H/logs/blocked-resolver.log" && ok \
  || bad "observe mode must still SAY what it would have done with the rebuild outcome (log: $(tail -3 "$H/logs/blocked-resolver.log"))"

# ---- 9d. THE RELAYED `-remote` RECORD. A pool build reaped onto the hub lands
#          in builds/<project>-<KEY>-remote<stamp>, and that is the only record
#          the hub ever sees for a remote rebuild.
RESET9; SEED9 1
: > "$H/state/merge-conductor/pr-state.tsv"
REBDIR "tproj-TK-9-remote202609161740" "PLAN_BLOCKED the ticket is ambiguous, see $H/builds/tproj-TK-9-remote202609161740/plan.md" >/dev/null
RUN
[ "$(STATEJSON tproj-TK-9 | jq -r .outcome)" = ABANDONED ] && ok \
  || bad "a relayed -remote rebuild record must be consumed like a hub one (got '$(STATEJSON tproj-TK-9 | jq -r .outcome)')"

# ---- 9e. THE LEDGER ROW. With no record on the hub at all, the pool's own queue
#          row carries the RESULT line as its reason (bin/fly-pool.sh:665).
RESET9; SEED9 1
: > "$H/state/merge-conductor/pr-state.tsv"
QROW9() { cat > "$H/bin/jobs-client.sh" <<EOF
queue_put() { printf '%s\n' "\$*" >> "$T/queue.txt"; echo queued; }
queue_done() { printf 'done %s\n' "\$*" >> "$T/queue.txt"; return 0; }
queue_list() {
  [ "\${2:-}" = done ] || return 1
  printf 'tproj\tTS-9\t9\tdone\tfly\t0\tm1\t%s\tDECOMPOSE_FAILED see /x/decompose-run.txt\t-\n' "$1"
}
EOF
}
QROW9 "$(date -u -d "@$NOW" +%Y-%m-%dT%H:%M:%SZ)"
RUN
[ "$(STATEJSON tproj-TK-9 | jq -r .outcome)" = ABANDONED ] && ok \
  || bad "with no build dir the pool queue row must carry the rebuild outcome (got '$(STATEJSON tproj-TK-9 | jq -r .outcome)')"
grep -q '/x/decompose-run.txt' "$T/comment-bodies.txt" && ok \
  || bad "the queue row's own reason must supply the artifact path (got: $(cat "$T/comment-bodies.txt"))"
# A row enqueued BEFORE the rebuild is a previous build's row: fail closed.
RESET9; SEED9 1
QROW9 "$(date -u -d "@$((NOW-7200))" +%Y-%m-%dT%H:%M:%SZ)"
RUN
[ "$(STATEJSON tproj-TK-9 | jq -r .outcome)" = "" ] && ok \
  || bad "a queue row that predates the rebuild must not be read as its outcome"
# An unparseable timestamp aborts consumption rather than guessing.
RESET9; SEED9 1
QROW9 "not-a-timestamp"
RUN
[ "$(STATEJSON tproj-TK-9 | jq -r .outcome)" = "" ] && ok \
  || bad "a queue row with an unreadable enqueued_at must not be consumed"
cat > "$H/bin/jobs-client.sh" <<EOF
queue_put() { printf '%s\n' "\$*" >> "$T/queue.txt"; echo queued; }
queue_done() { printf 'done %s\n' "\$*" >> "$T/queue.txt"; return 0; }
queue_list() { return 1; }
EOF
for d in "$H"/builds/*TK-9-*; do [ -e "$d" ] && scratch_rm "$d"; done
rm -f "$H/flags/fly-pool-tproj"

echo "br-rebuild-outcome-test: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
