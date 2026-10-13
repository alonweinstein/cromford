#!/bin/bash
# tests/br-rebuild-test.sh — REBUILD FRESH: the rung the resolver reaches when
# the cheaper ones are spent, and every edge around it. Sections 2, 2b, 2c, 2d,
# 2e, 3 and 6 of the old tests/blocked-resolver-test.sh, moved here verbatim by
# BH-1196, in their original order.
#
# WHY THESE SEVEN TRAVEL TOGETHER. A rebuild is plan + execute + review, the
# most expensive thing this lane can buy, and it is the one action that can run
# for ever: the cap has to count the TICKET rather than the PR number (a rebuild
# produces a new PR every time), a merged PR has to read as a STALE park rather
# than as work to redo, and a park with no ticket id must not be enqueued at
# all. Section 6 is the same rung seen from the other side: observe mode takes
# no action, and the kill switch stops the lane dead.
#
# Sections carried (original numbering, from tests/blocked-resolver-test.sh):
#   2.  rebuild fresh: closes the stale PR, enqueues against current main
#   2b. the cap counts the TICKET, not the PR NUMBER
#   2c. a MERGED PR is a STALE park, not work to redo
#   2d. the ticket is already merged and the park never knew a PR number
#   2e. no ticket id, no enqueue
#   3.  box projects re-offer through the box, not through the pool queue
#   6.  observe mode takes no action, and the kill switch stops the lane
# Run from anywhere: tests/br-rebuild-test.sh   (exit 0 = all pass)
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
# 2. REBUILD FRESH: closes the stale PR, enqueues against current main, and
#    stops at the cap with an ABANDONED outcome record.
#
#    DRIVEN THROUGH `merge-failed-twice`, which is a park with no branch to fix
#    (the queue refused a READY PR twice — nothing about the code changed) and
#    so has no ladder class. A branch park would take the mechanical rung first
#    now; that ladder is section 8's business, and this section is about what
#    the rebuild rung itself does when it is the right answer.
# ============================================================================
ROW "o/tproj#9" "merge-failed-twice: gh pr merge refused" "https://github.com/o/tproj/pull/9"
touch "$H/flags/fly-pool-tproj"   # pool project: the enqueue is a queue row
# A jobs client whose queue_put is recorded rather than sent.
cat > "$H/bin/jobs-client.sh" <<EOF
queue_put() { printf '%s\n' "\$*" >> "$T/queue.txt"; echo queued; }
queue_done() { printf 'done %s\n' "\$*" >> "$T/queue.txt"; return 0; }
queue_list() { return 1; }
EOF
: > "$T/closed.txt"; : > "$T/queue.txt"
RUN
[ -s "$T/closed.txt" ] && ok || bad "a rebuild must CLOSE the stale PR"
# The close comment is a REST POST whose body goes by FILE (#783), so the
# sentence lives in what the stub read out of that file, never in argv.
grep -q 'superseded by a fresh build\|Superseded by a fresh build' "$T/comment-bodies.txt" \
  && ok || bad "the close comment must say the PR was superseded by a fresh build (bodies: $(cat "$T/comment-bodies.txt"))"
grep -q '^tproj TK-9 9 fly 0 ' "$T/queue.txt" && ok || bad "the fresh build must be enqueued at attempt 0 WITH its ticket id (got: $(cat "$T/queue.txt"))"
grep -q 'branch_suffix' "$T/queue.txt" && ok || bad "the fresh build must carry a branch suffix so it does not collide with the branch behind the closed PR"
[ "$(STATEJSON tproj-TK-9 | jq -r .rebuilds)" = 1 ] && ok || bad "the rebuild counter must be 1 after one rebuild"

# Three rebuilds, then the terminal. Each tick is one action, so it takes three.
: > "$T/queue.txt"
RUN; RUN
[ "$(STATEJSON tproj-TK-9 | jq -r .rebuilds)" = 3 ] && ok || bad "three ticks must produce three rebuilds (got $(STATEJSON tproj-TK-9 | jq -r .rebuilds))"
: > "$T/queue.txt"
RUN
[ "$(STATEJSON tproj-TK-9 | jq -r .outcome)" = ABANDONED ] && ok \
  || bad "the 4th tick past the cap must record ABANDONED (got '$(STATEJSON tproj-TK-9 | jq -r .outcome)')"
grep -q 'ABANDONED' "$H/logs/ALERTS.log" 2>/dev/null && ok || bad "ABANDONED must write exactly one ALERTS line"
grep -q 'rebuild-fresh' <<<"$(STATEJSON tproj-TK-9 | jq -r '.attempts[].action')" && ok || bad "the ABANDONED record must list what was tried"
# ...and the alert must not ask anybody for anything.
grep -iE 'needs a human|by hand|for the operator' "$H/logs/ALERTS.log" >/dev/null 2>&1 \
  && bad "the ABANDONED alert must never say human/by hand/for the operator" || ok
# An abandoned key is terminal: a later tick does nothing at all with it.
: > "$T/queue.txt"; : > "$T/closed.txt"
RUN
[ -s "$T/queue.txt" ] && bad "an ABANDONED key must never be enqueued again" || ok

# ============================================================================
# 2b. The cap counts the TICKET, not the PR NUMBER. A rebuild produces a NEW pr,
#     so a cap keyed on the number restarts at zero on every rung and the ladder
#     never ends: 9 -> rebuild -> 20 -> rebuild -> 21, for ever, one pool machine
#     every ten minutes. Same ticket, three different PR numbers, still capped.
# ============================================================================
scratch_rm "$H/state/blocked-resolver"
: > "$T/queue.txt"; : > "$T/closed.txt"
for n in 20 21 22; do
  ROW "o/tproj#$n" "merge-failed-twice: gh pr merge refused" "https://github.com/o/tproj/pull/$n"
  RUN
done
[ "$(STATEJSON tproj-TK-9 | jq -r .rebuilds)" = 3 ] && ok \
  || bad "three rebuilds of one ticket must share one counter across PR numbers (got $(STATEJSON tproj-TK-9 | jq -r .rebuilds))"
ROW "o/tproj#23" "merge-failed-twice: gh pr merge refused" "https://github.com/o/tproj/pull/23"
: > "$T/queue.txt"
RUN
[ "$(STATEJSON tproj-TK-9 | jq -r .outcome)" = ABANDONED ] && ok \
  || bad "a 4th PR number for the same ticket must hit the cap, not restart it (got '$(STATEJSON tproj-TK-9 | jq -r .outcome)')"
# (the ABANDONED close writes a `done` row; what must be absent is a new ENQUEUE)
grep -q '^tproj TK-9 ' "$T/queue.txt" \
  && bad "past the cap a new PR number must not buy another rebuild (got: $(cat "$T/queue.txt"))" || ok

# ============================================================================
# 2c. A MERGED PR is a STALE park, not work to redo. br_close_pr returns
#     silently on anything that is not OPEN, so before this the ladder sailed
#     past the close and enqueued a DUPLICATE build of work that had landed.
# ============================================================================
scratch_rm "$H/state/blocked-resolver"
echo MERGED > "$T/prstate"
ROW "o/tproj#31" "merge-failed-twice: gh pr merge refused" "https://github.com/o/tproj/pull/31"
: > "$T/queue.txt"; : > "$T/closed.txt"
RUN
[ -s "$T/queue.txt" ] && bad "a MERGED PR must never be rebuilt — that duplicates work that already landed (got: $(cat "$T/queue.txt"))" || ok
[ "$(STATEJSON tproj-TK-9 | jq -r .outcome)" = RESOLVED_MERGED ] && ok \
  || bad "a MERGED PR's park must be recorded resolved (got '$(STATEJSON tproj-TK-9 | jq -r .outcome)')"
[ "$(STATEJSON tproj-TK-9 | jq -r .rebuilds)" = 0 ] && ok || bad "resolving a merged park must not spend a rebuild"
[ -s "$T/closed.txt" ] && bad "a merged PR must not be closed" || ok
echo OPEN > "$T/prstate"

# ============================================================================
# 2d. THE TICKET IS ALREADY MERGED and the park never knew a PR number.
#     2026-09-14: seven parked records — stale pool rows with NO pr url — were
#     rebuilt from scratch although their tickets had merged days earlier. The
#     only merged-guard asked about the park's PR url, and there wasn't one. So
#     the question is asked about the TICKET now, and it is asked FIRST: before
#     the adjudication rung spends a model, not after.
# ============================================================================
scratch_rm "$H/state/blocked-resolver"
: > "$H/state/merge-conductor/pr-state.tsv"
touch "$H/flags/fly-pool-tproj"
PARK="$H/state/build-queue/tproj/TK-9.failed.json"
echo '{"key":"TK-9","ticket_id":"9","attempt":2}' > "$PARK"
touch -d '2 days ago' "$PARK"
printf 'https://github.com/o/tproj/pull/44\t%s\tticket/TK-9\tTS-9: the thing\n' \
  "$(date -u -d '1 day ago' +%Y-%m-%dT%H:%M:%SZ)" > "$T/mergedprs"
: > "$T/queue.txt"; : > "$T/closed.txt"
RUN
# (the resolve closes the queue row, which writes a `done` line; what must be
# absent is an ENQUEUE)
grep -q '^tproj TK-9 ' "$T/queue.txt" \
  && bad "a park whose TICKET already merged must never be rebuilt (got: $(cat "$T/queue.txt"))" || ok
[ "$(STATEJSON tproj-TK-9 | jq -r .outcome)" = RESOLVED_MERGED ] && ok \
  || bad "a ticket that already merged must record RESOLVED_MERGED (got '$(STATEJSON tproj-TK-9 | jq -r .outcome)')"
[ "$(STATEJSON tproj-TK-9 | jq -r .rebuilds)" = 0 ] && ok || bad "resolving a merged ticket must not spend a rebuild"
grep -q 'already merged via https://github.com/o/tproj/pull/44' "$H/logs/blocked-resolver.log" && ok \
  || bad "the resolved line must name the PR the ticket merged through"
grep -q 'park is stale, nothing rebuilt' "$H/logs/blocked-resolver.log" && ok \
  || bad "the resolved line must say the park is stale and nothing was rebuilt"
# A second tick costs nothing and changes nothing: the outcome is terminal.
: > "$T/queue.txt"
RUN
grep -q '^tproj TK-9 ' "$T/queue.txt" \
  && bad "a RESOLVED_MERGED key must never be enqueued on a later tick (got: $(cat "$T/queue.txt"))" || ok

# A merge that PREDATES the park is not this park's answer — a ticket can
# legitimately have follow-up work, and swallowing that would be the mirror
# image of the bug: a real rebuild silently dropped.
scratch_rm "$H/state/blocked-resolver"
printf 'https://github.com/o/tproj/pull/40\t%s\tticket/TK-9\tTS-9: the first pass\n' \
  "$(date -u -d '5 days ago' +%Y-%m-%dT%H:%M:%SZ)" > "$T/mergedprs"
: > "$T/queue.txt"
RUN
grep -q '^tproj TK-9 9 fly 0 ' "$T/queue.txt" && ok \
  || bad "a merged PR OLDER than the park must not block the rebuild (got: $(cat "$T/queue.txt"))"
grep -q 'predates this park' "$H/logs/blocked-resolver.log" && ok \
  || bad "an older merged PR must still be logged as a one-line note"
: > "$T/mergedprs"; rm -f "$PARK"; scratch_rm "$H/state/blocked-resolver"

# ============================================================================
# 2e. NO TICKET ID, NO ENQUEUE. br_enqueue_fresh used to call queue_put with an
#     empty ticket, and bin/fly-pool.sh quarantines exactly that row
#     ("malformed queue entry (ticket='')") — so the rebuild was a PR closed, a
#     counter spent, and no build. A blank id is now a refusal.
# ============================================================================
REC2="$H/builds/tproj-FOO-202609130009"
mkdir -p "$REC2"
echo "BUILD_DEAD the machine went away" > "$REC2/RESULT"
touch -d '3 hours ago' "$REC2/RESULT"
: > "$T/queue.txt"
RUN
grep -q '^tproj FOO ' "$T/queue.txt" \
  && bad "a ticket whose id cannot be resolved must NOT be enqueued (got: $(cat "$T/queue.txt"))" || ok
grep -q 'no ticket id — cannot enqueue' "$H/logs/blocked-resolver.log" && ok \
  || bad "the refusal must say 'no ticket id — cannot enqueue'"
[ "$(STATEJSON tproj-FOO | jq -r .rebuilds)" = 0 ] && ok || bad "a refused enqueue must spend no rebuild counter"
grep -q 'rebuild-fresh-failed' <<<"$(STATEJSON tproj-FOO | jq -r '.attempts[].action')" && ok \
  || bad "a refused enqueue must be recorded as rebuild-fresh-failed"
scratch_rm "$REC2"; scratch_rm "$H/state/blocked-resolver"

# ============================================================================
# 3. Box projects re-offer through the box's blocked stamp, not through the pool
#    queue. Since BH-2674 that is the D1 `commented` row flipped to `cleared`
#    (bin/lib/comment-mark.sh), never an ssh to the box.
# ============================================================================
scratch_rm "$H/state/blocked-resolver"; scratch_rm "$H/flags/fly-pool-tproj"
: > "$T/ssh.txt"; : > "$T/queue.txt"; : > "$T/ledger.txt"
cp "$DIR/bin/lib/comment-mark.sh" "$H/bin/lib/" || exit 1
printf 'job_ledger_put() { printf "%%s\\n" "$*" >> %q; }\n' "$T/ledger.txt" >> "$H/bin/jobs-client.sh"
ROW "o/tproj#11" "merge-failed-twice: gh pr merge refused" "https://github.com/o/tproj/pull/11"
RUN
grep -qx 'commented blocked tproj TK-9 cleared -' "$T/ledger.txt" && ok \
  || bad "a box project's rebuild must clear the box's blocked stamp through its commented row (ledger: $(cat "$T/ledger.txt"))"
[ -s "$T/ssh.txt" ] && bad "a box project's rebuild must not ssh to the box (got: $(cat "$T/ssh.txt"))" || ok
[ -s "$T/queue.txt" ] && bad "a box project must not be enqueued onto the fly pool queue" || ok

# ============================================================================
# 6. Observe mode takes no action at all, and the kill switch stops the lane.
# ============================================================================
scratch_rm "$H/state/blocked-resolver"
ROW "o/tproj#13" "merge-failed-twice: gh pr merge refused" "https://github.com/o/tproj/pull/13"
cat > "$H/bin/jobs-client.sh" <<EOF
queue_put() { printf '%s\n' "\$*" >> "$T/queue.txt"; echo queued; }
queue_done() { return 0; }
queue_list() { return 1; }
EOF
: > "$T/queue.txt"; : > "$T/closed.txt"
touch "$H/flags/blocked-resolver-observe"
RUN
[ -s "$T/closed.txt" ] && bad "observe mode must not close a PR" || ok
[ -s "$T/queue.txt" ] && bad "observe mode must not enqueue" || ok
grep -q 'WOULD rebuild fresh' "$H/logs/blocked-resolver.log" && ok || bad "observe mode must still SAY what it would have done"
rm -f "$H/flags/blocked-resolver-observe"
touch "$H/flags/blocked-resolver-disabled"
BEFORE=$(wc -l < "$H/logs/blocked-resolver.log")
RUN
[ "$(wc -l < "$H/logs/blocked-resolver.log")" = "$BEFORE" ] && ok || bad "the kill switch must stop the lane dead"
rm -f "$H/flags/blocked-resolver-disabled"

echo "br-rebuild-test: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
