#!/bin/bash
# tests/blocked-resolver-supersede.bh-1642-test.sh — BH-1642: the rebuild rung
# must never throw away a PR whose CURRENT head nobody has judged yet, or whose
# head carries a lead/human verdict.
#
# WHAT HAPPENED (2026-09-23). bin/blocked-resolver.sh's rebuild rung closed two
# PRs as "Superseded by a fresh build":
#   #1559 "red-twice", ten minutes after the lead force-pushed a reviewed fix.
#         The red count was the conductor's, taken on the heads BEFORE that push;
#         the new head went green and was approved minutes later.
#   #1448 "head-not-reapproved", six minutes after the resolver's OWN fix round
#         pushed 3d02abc6, while the lead's reviewed head 62cc995f was approved.
# Both had to be reopened by hand.
#
# THE ACCEPTANCE ROWS, from the issue, red first:
#   1. red twice on head A, force-pushed to head B with CI pending: NOT superseded.
#   2. a lead MERGE row standing on the head: NEVER superseded (and an unreadable
#      verdicts table is not "no verdict": not superseded this tick).
#   3. red twice on its current head, no verdict, no HOLD: superseded as today.
#   4. the #1448 replay: the resolver's own fix round pushes, the conductor parks
#      the new head again, and the rebuild rung inside the settle window must not
#      close it. Past the window it still must not, while a lead MERGE stands on
#      the head that fix round pushed over. With neither, it supersedes.
# Every decline says so in ONE log line naming its reason.
#
# Run from anywhere: tests/blocked-resolver-supersede.bh-1642-test.sh  (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq  >/dev/null || { echo "jq missing — skipping"; exit 0; }
command -v git >/dev/null || { echo "git missing — skipping"; exit 0; }

# shellcheck source=tests/lib/fixture-harness.sh
. "$DIR/tests/lib/fixture-harness.sh" || exit 1
H="$T/h"
mkdir -p "$H/bin"
# The scripts this suite drives. The copy stays HERE, in the suite's own text,
# so bin/test-impact.sh selects this suite when one of them changes.
cp "$DIR/bin/blocked-resolver.sh" "$DIR/bin/fly-pool.sh" "$DIR/bin/merge-sweep.sh" \
   "$DIR/bin/merge-conductor.sh" "$DIR/bin/fleet-conf.sh" "$DIR/bin/project-of.sh" \
   "$DIR/bin/box-for.sh" "$H/bin/"
fx_br_harness "$DIR" "$T" || exit 1
[ -d "$DIR/bin/lib/br" ] || exit 1   # impact: this suite runs when bin/lib/br/ changes
# The fix round in section 4 resolves its model through model_routes; this
# worker-less box carries the resolver's cache of that table (BH-1510.1).
. "$DIR/tests/lib/model-route-stub.sh" || exit 1
mrs_fixture "$H" tproj
# THE TWO READERS THE GUARD ASKS. The ownership lib is the REAL one; the
# verdicts table and the ticket's hold are STUBS keyed on files, so a scenario
# is one write. The stubs keep each real contract's rc shape exactly:
#   vd_standing  rc 0 + one TSV line | rc 1 nothing stands | rc 2 unreadable
#   hold_check   rc 0 clear | rc 1 held | rc 2 unreadable
cp "$DIR/bin/lib/ticket-ownership.sh" "$H/bin/lib/" || exit 1
cat > "$H/bin/lib/verdicts.sh" <<EOF
# STUB of bin/lib/verdicts.sh (BH-1525): \$T/verdicts is "<full-sha> <VERDICT>"
# per line, \$T/vd-down makes every read unreadable. Every question is recorded.
vd_standing() {
  printf '%s %s %s\n' "\$1" "\$2" "\$3" >> "$T/vd-asked.txt"
  [ -e "$T/vd-down" ] && return 2
  # The real reader answers rc 2 for a head that is not a full sha.
  [[ "\$3" =~ ^[0-9a-f]{40}\$ ]] || return 2
  local v; v=\$(awk -v h="\$3" '\$1==h {print \$2; exit}' "$T/verdicts" 2>/dev/null)
  [ -n "\$v" ] || return 1
  printf '%s\tlead\t7\t2026-09-23T12:00:00Z\t-\toperator\n' "\$v"
}
# vd_clear_word, as bin/lib/verdicts.sh derives it from vd_standing.
vd_clear_word() {
  local line v
  line=\$(vd_standing "\$@") || return 1
  v=\$(cut -f1 <<<"\$line")
  case "\$v" in MERGE|MERGE-WITH-NOTES) printf '%s' "\$v"; return 0 ;; esac
  return 1
}
EOF
cat > "$H/bin/lib/hold.sh" <<EOF
# STUB of bin/lib/hold.sh: \$T/hold is the verdict line, \$T/hold-rc its rc.
hold_check() {
  if [ -s "$T/hold" ]; then cat "$T/hold"; return "\$(cat "$T/hold-rc" 2>/dev/null || echo 1)"; fi
  printf 'clear\tno hold on this ticket\n'; return 0
}
hold_check_thread() { printf 'clear\tno-hold\n'; return 0; }  # BH-1668: the PR's own thread, clear
hold_is_pause()   { case "\${1:-}" in *"	hold:"*)    return 0 ;; esac; return 1; }
hold_is_abandon() { case "\${1:-}" in *"	abandon:"*) return 0 ;; esac; return 1; }
EOF
cat > "$H/bin/jobs-client.sh" <<EOF
queue_put() { printf '%s\n' "\$*" >> "$T/queue.txt"; echo queued; }
queue_done() { printf 'done %s\n' "\$*" >> "$T/queue.txt"; return 0; }
queue_list() { return 1; }
EOF
touch "$H/flags/fly-pool-tproj"   # pool project: a rebuild is a queue row
# The regenerate rung (1b) would buy a real mc_rebase on a ci-red park; this
# suite is about rung 3, so the ladder goes 1 -> 2 -> 3 as the issue describes.
# The settle window is set the way an operator's settings row sets it.
BRENV=(BR_REGEN_RUNG=0 BR_SUPERSEDE_SETTLE_SECS=1800 BR_SUPERSEDE_DECLINE_ALERT_SECS=3600)
BASEENV=("${BRENV[@]}")

A=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
B=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
LOGF="$H/logs/blocked-resolver.log"

# PARK <pr#> <STATE> <reason> <judged-head> — the conductor's row, exactly as
# mc_transition writes it: the head it JUDGED is field 4.
PARK() {
  printf 'o/tproj#%s\t%s\t%s\t%s\t%s\t-\t%s\t%s\n' "$1" "$2" "$(date -u +%s)" "$4" "$4" "$3" \
    "https://github.com/o/tproj/pull/$1" > "$H/state/merge-conductor/pr-state.tsv"
}
# FRESH — one scenario's clean slate: the ladder already spent rungs 1 and 2 for
# TK-9, so the park arrives at rung 3 (rebuild fresh), which is the rung that
# closes the PR.
FRESH() {
  scratch_rm "$H/state/blocked-resolver"
  SPENT tproj-TK-9
  : > "$T/closed.txt"; : > "$T/queue.txt"; : > "$T/comment-bodies.txt"; : > "$LOGF"
  : > "$T/vd-asked.txt"; : > "$T/verdicts"; rm -f "$T/vd-down" "$T/hold" "$T/hold-rc"
  : > "$T/lane-alert.txt"
  scratch_rm "$H/state/merge-conductor/handoff"
  scratch_rm "$H/state/merge-conductor/handoff-released"
  printf 'ticket/TK-9' > "$T/prbranch"; printf 'TK-9: a thing' > "$T/prtitle"
  echo OPEN > "$T/prstate"
}
CLOSED() { grep -q -- "-X PATCH.*pulls/$1" "$T/closed.txt" 2>/dev/null; }
DECLINES() { grep -c "SUPERSEDE DECLINED" "$LOGF" 2>/dev/null || true; }

# HANDOFF <pr#> <head> [released] — the conductor's hand-off record for a sticky
# park, and the resolver's release marker when asked (bin/lib/mc/classify.sh).
HANDOFF() {
  mkdir -p "$H/state/merge-conductor/handoff" "$H/state/merge-conductor/handoff-released"
  printf '%s\t%s\thead-not-reapproved\t%s\n' "$(date -u +%s)" "$2" \
    "https://github.com/o/tproj/pull/$1" > "$H/state/merge-conductor/handoff/o_tproj_$1"
  rm -f "$H/state/merge-conductor/handoff-released/o_tproj_$1"
  [ "${3:-}" = released ] && printf '%s\tblocked-resolver/fix-round\n' "$(date -u +%s)" \
    > "$H/state/merge-conductor/handoff-released/o_tproj_$1"
  return 0
}
RELEASED() { [ -e "$H/state/merge-conductor/handoff-released/o_tproj_$1" ]; }
ALERTS() { grep -c 'SUPERSEDE DECLINED' "$T/lane-alert.txt" 2>/dev/null || true; }

# ============================================================================
# 1. RED TWICE ON HEAD A, FORCE-PUSHED TO HEAD B, CI PENDING (#1559).
#    The conductor's red-twice row is about A. The PR is on B now, so nothing
#    the lane knows says B is red: the count restarts on B and the rebuild waits.
# ============================================================================
FRESH
PARK 9 RED_TWICE "red-twice: still red on ${A:0:8} after its failed jobs were re-run once" "$A"
printf '%s' "$B" > "$T/prhead"
RUN
CLOSED 9 && bad "1: a PR red on head A and force-pushed to B must NOT be closed (closed: $(cat "$T/closed.txt"))" || ok
grep -q '^tproj TK-9 ' "$T/queue.txt" && bad "1: no fresh build may be enqueued for a PR whose new head was never judged (queue: $(cat "$T/queue.txt"))" || ok
[ "$(STATEJSON tproj-TK-9 | jq -r .rebuilds)" = 0 ] && ok || bad "1: a declined supersede must spend no rebuild (got $(STATEJSON tproj-TK-9 | jq -r .rebuilds))"
grep -q 'SUPERSEDE DECLINED (head-moved)' "$LOGF" && ok \
  || bad "1: the decline must name its reason, head-moved (log: $(tail -3 "$LOGF"))"
grep -q "SUPERSEDE DECLINED (head-moved).*${B:0:12}" "$LOGF" && ok \
  || bad "1: the head-moved line must name the PR's current head"
[ "$(DECLINES)" = 1 ] && ok || bad "1: one decline is ONE log line (got $(DECLINES))"
grep -q 'Superseded by a fresh build' "$T/comment-bodies.txt" && bad "1: no superseded comment may be posted" || ok

# 1b. The conductor re-parks it red twice on B, and B has only just appeared:
#     the settle window (BR_SUPERSEDE_SETTLE_SECS) still holds the rebuild.
PARK 9 RED_TWICE "red-twice: still red on ${B:0:8} after its failed jobs were re-run once" "$B"
: > "$LOGF"
RUN
CLOSED 9 && bad "1b: a head this lane first saw moments ago must not be superseded inside the settle window" || ok
grep -q 'SUPERSEDE DECLINED (settle-window)' "$LOGF" && ok \
  || bad "1b: inside the window the decline must say settle-window (log: $(tail -3 "$LOGF"))"
[ "$(DECLINES)" = 1 ] && ok || bad "1b: one decline is ONE log line (got $(DECLINES))"

# 1c. Past the window, red twice on the head it is on, no verdict, no hold: the
#     rebuild is exactly today's (a 0 window is "the window has run out").
: > "$LOGF"
BRENV=(BR_REGEN_RUNG=0 BR_SUPERSEDE_SETTLE_SECS=0 BR_SUPERSEDE_DECLINE_ALERT_SECS=3600)
RUN
BRENV=("${BASEENV[@]}")
CLOSED 9 && ok || bad "1c: red twice on its CURRENT head past the window must be superseded (log: $(tail -3 "$LOGF"))"
grep -q '^tproj TK-9 9 fly 0 ' "$T/queue.txt" && ok || bad "1c: the fresh build must be enqueued (queue: $(cat "$T/queue.txt"))"

# 1d. THE RECOVERED HAND-OFF. The conductor already moved its row on to the new
#     head (WAIT_CI on B, CI pending) and the red-twice park reaches this lane
#     only through its logged hand-off line. The row's head is the conductor's
#     CURRENT view, never the parked one: no park stands to supersede on.
FRESH
printf 'o/tproj#9\tWAIT_CI\t%s\t%s\t%s\t-\tchecks pending\t%s\n' "$(date -u +%s)" "$B" "$B" \
  "https://github.com/o/tproj/pull/9" > "$H/state/merge-conductor/pr-state.tsv"
printf '%sZ o/tproj#9 RED_TWICE red-twice: CI is still red on %s after its failed jobs were re-run once — handed to bin/blocked-resolver.sh (fix round on the branch, or a fresh rebuild against current main): https://github.com/o/tproj/pull/9\n' \
  "$(date -u '+%Y-%m-%d %H:%M:%S')" "${A:0:8}" > "$H/logs/merge-conductor.log"
printf '%s' "$B" > "$T/prhead"
RUN
grep -q 'recovered from the hand-off' "$LOGF" && ok || bad "1d: the park must reach the lane through the recovered hand-off (log: $(tail -4 "$LOGF"))"
CLOSED 9 && bad "1d: a recovered red-twice hand-off whose row moved on to the new head must NOT be superseded (the #1559 shape)" || ok
grep -q 'SUPERSEDE DECLINED (park-moved-on)' "$LOGF" && ok || bad "1d: the decline must say the park moved on (log: $(tail -3 "$LOGF"))"
: > "$H/logs/merge-conductor.log"

# 1e. A HEAD AN EARLIER RUNG SAW. The mechanical rung read the PR on A; the
#     lead then force-pushed B, and by the time the rebuild rung runs the
#     conductor has already re-parked red twice on B. B replaced a head this
#     lane recorded, so it is a push, and the window holds the rebuild.
FRESH
scratch_rm "$H/state/blocked-resolver"   # rung 1 not spent yet: it runs this tick
PARK 9 RED_TWICE "red-twice: still red on ${A:0:8} after its failed jobs were re-run once" "$A"
printf '%s' "$A" > "$T/prhead"
RUN
[ "$(STATEJSON tproj-TK-9 | jq -r '.sup_head // ""')" = "$A" ] && ok \
  || bad "1e: the mechanical rung's head read must be recorded (got '$(STATEJSON tproj-TK-9 | jq -r '.sup_head // ""')'; log: $(tail -3 "$LOGF"))"
jq -c '.mechanicals=1 | .fixrounds=1' "$H/state/blocked-resolver/tproj/tproj-TK-9.json" > "$T/st.json" \
  && cp "$T/st.json" "$H/state/blocked-resolver/tproj/tproj-TK-9.json"
PARK 9 RED_TWICE "red-twice: still red on ${B:0:8} after its failed jobs were re-run once" "$B"
printf '%s' "$B" > "$T/prhead"
: > "$T/closed.txt"; : > "$T/queue.txt"; : > "$LOGF"
RUN
CLOSED 9 && bad "1e: a head that replaced one this lane saw must not be superseded inside the window" || ok
grep -q 'SUPERSEDE DECLINED (settle-window)' "$LOGF" && ok || bad "1e: the decline must say settle-window (log: $(tail -3 "$LOGF"))"

# ============================================================================
# 2. A LEAD MERGE ROW STANDS ON THE HEAD: NEVER SUPERSEDED.
# ============================================================================
FRESH
PARK 9 RED_TWICE "red-twice: still red on ${B:0:8} after its failed jobs were re-run once" "$B"
printf '%s' "$B" > "$T/prhead"
printf '%s MERGE\n' "$B" > "$T/verdicts"
RUN
CLOSED 9 && bad "2: a PR with a lead MERGE standing on its head must never be closed" || ok
grep -q '^tproj TK-9 ' "$T/queue.txt" && bad "2: no rebuild may be enqueued over a lead MERGE (queue: $(cat "$T/queue.txt"))" || ok
grep -q "o/tproj 9 $B" "$T/vd-asked.txt" && ok || bad "2: the verdicts table must be asked about the PR's CURRENT head (asked: $(cat "$T/vd-asked.txt"))"
grep -q 'SUPERSEDE DECLINED (verdict)' "$LOGF" && ok || bad "2: the decline must name the verdict (log: $(tail -3 "$LOGF"))"
grep -q 'SUPERSEDE DECLINED (verdict).*MERGE' "$LOGF" && ok || bad "2: the line must say which verdict stands"
[ "$(DECLINES)" = 1 ] && ok || bad "2: one decline is ONE log line (got $(DECLINES))"
# A second tick is the same answer: a standing lead verdict is not a clock.
: > "$LOGF"
BRENV=(BR_REGEN_RUNG=0 BR_SUPERSEDE_SETTLE_SECS=0 BR_SUPERSEDE_DECLINE_ALERT_SECS=3600)
RUN
CLOSED 9 && bad "2: a lead MERGE keeps the PR on every tick, window or not" || ok
BRENV=("${BASEENV[@]}")

# 2b. FAIL CLOSED: the verdicts table cannot be read, so nobody knows whether a
#     lead verdict stands. Not this tick.
FRESH
PARK 9 RED_TWICE "red-twice: still red on ${A:0:8} after its failed jobs were re-run once" "$A"
printf '%s' "$A" > "$T/prhead"
touch "$T/vd-down"
RUN
CLOSED 9 && bad "2b: an unreadable verdicts table must never read as 'no verdict' — the PR was closed" || ok
grep -q 'SUPERSEDE DECLINED (verdict-unreadable)' "$LOGF" && ok || bad "2b: the decline must say the verdict read failed (log: $(tail -3 "$LOGF"))"
[ "$(STATEJSON tproj-TK-9 | jq -r .rebuilds)" = 0 ] && ok || bad "2b: an unreadable verdict spends no rebuild"

# 2c. A verdict is bound to its head: a MERGE on an OLD head does not protect
#     the head the PR is on now.
FRESH
PARK 9 RED_TWICE "red-twice: still red on ${A:0:8} after its failed jobs were re-run once" "$A"
printf '%s' "$A" > "$T/prhead"
printf '%s MERGE\n' "$B" > "$T/verdicts"
RUN
CLOSED 9 && ok || bad "2c: a MERGE standing on another head must not stop the rebuild of this one (log: $(tail -3 "$LOGF"))"

# ============================================================================
# 3. RED TWICE ON ITS CURRENT HEAD, NO VERDICT, NO HOLD: SUPERSEDED AS TODAY.
#    The first time this lane sees a PR there is no push to settle after.
# ============================================================================
FRESH
PARK 9 RED_TWICE "red-twice: still red on ${A:0:8} after its failed jobs were re-run once" "$A"
printf '%s' "$A" > "$T/prhead"
RUN
CLOSED 9 && ok || bad "3: red twice on its current head with no verdict and no hold must be superseded (log: $(tail -5 "$LOGF"))"
grep -q 'Superseded by a fresh build' "$T/comment-bodies.txt" && ok || bad "3: the close comment is today's"
grep -q '^tproj TK-9 9 fly 0 ' "$T/queue.txt" && ok || bad "3: the fresh build must be enqueued (queue: $(cat "$T/queue.txt"))"
[ "$(STATEJSON tproj-TK-9 | jq -r .rebuilds)" = 1 ] && ok || bad "3: the rebuild must be counted"
[ "$(DECLINES)" = 0 ] && ok || bad "3: a supersede that goes ahead writes no decline line"

# 3b. A HOLD on the ticket: never superseded.
FRESH
PARK 9 RED_TWICE "red-twice: still red on ${A:0:8} after its failed jobs were re-run once" "$A"
printf '%s' "$A" > "$T/prhead"
printf 'held\thold:body HOLD: the lead is building this on the Mac\n' > "$T/hold"; echo 1 > "$T/hold-rc"
RUN
CLOSED 9 && bad "3b: a ticket on HOLD must keep its PR" || ok
grep -q '^tproj TK-9 ' "$T/queue.txt" && bad "3b: a held ticket must not be rebuilt" || ok

# 3c. The hold cannot be read: not this tick either.
FRESH
PARK 9 RED_TWICE "red-twice: still red on ${A:0:8} after its failed jobs were re-run once" "$A"
printf '%s' "$A" > "$T/prhead"
printf 'unreadable\tHTTP 502 from the issues read\n' > "$T/hold"; echo 2 > "$T/hold-rc"
RUN
CLOSED 9 && bad "3c: an unreadable hold must never read as 'no hold' — the PR was closed" || ok

# 3d. The PR answers OPEN with no usable head sha. Nothing a verdict row could
#     bind to came back, so the verdicts reader (rc 2 for a non-sha head) says
#     "unknown" and the PR is kept. The park here names no head of its own, so
#     it is the verdict read that must hold, not the head comparison.
FRESH
PARK 9 RED_TWICE "red-twice: still red after its failed jobs were re-run once" "-"
printf '' > "$T/prhead"
RUN
CLOSED 9 && bad "3d: a PR whose current head came back empty must not be closed" || ok
grep -q 'SUPERSEDE DECLINED (verdict-unreadable)' "$LOGF" && ok || bad "3d: a head no verdict can bind to must fail closed (log: $(tail -3 "$LOGF"))"

# ============================================================================
# 4. THE #1448 REPLAY. The resolver's OWN fix round pushes a new head over the
#    lead's reviewed one; the conductor's head-bound re-review BLOCKs the new
#    head and parks it head-not-reapproved; the next tick's ladder is at rung 3.
#    Inside the settle window after its own push the rung must NOT supersede.
# ============================================================================
# A REAL local git: a branch that genuinely conflicts with main, a fix round
# that merges main and resolves it, a push under --force-with-lease.
fx_br_ladder_git "$DIR" "$T" || exit 1
printf 'ticket/TK-101' > "$T/prbranch"; printf 'TK-101: a thing' > "$T/prtitle"
LEAD=$(osha ticket/TK-101)          # the lead's reviewed, approved head (62cc995f)
printf '%s' "$LEAD" > "$T/prhead"
U101="https://github.com/o/tproj/pull/101"
# The ladder has spent rung 1; the conflict is a LARGE one (the #1448 park took
# the large ladder: one fix round, then "rebuild 1 of 3").
mkdir -p "$H/state/blocked-resolver/tproj"
jq -nc '{project:"tproj",rkey:"tproj-TK-101",mechanicals:1,fixrounds:0,rebuilds:0,conflict_lines:500,outcome:"",attempts:[]}' \
  > "$H/state/blocked-resolver/tproj/tproj-TK-101.json"
PARK 101 BLOCKED_HUMAN "head-not-reapproved" "$LEAD"
touch "$T/agent-resolves"
: > "$T/closed.txt"; : > "$T/queue.txt"; : > "$LOGF"; : > "$T/verdicts"; rm -f "$T/vd-down" "$T/hold" "$T/hold-rc"
RUN
grep -q 'FIX ROUND pushed' "$LOGF" && ok || bad "4: the replay needs the resolver's own fix round to push (log: $(tail -5 "$LOGF"))"
PUSHED=$(osha ticket/TK-101)
[ "$PUSHED" != "$LEAD" ] && ok || bad "4: the fix round must have moved the branch"
CLOSED 101 && bad "4: the fix round itself must not close the PR" || ok

# The conductor's head-bound re-review BLOCKs the pushed head, six minutes later.
rm -f "$T/agent-resolves"
printf '%s' "$PUSHED" > "$T/prhead"
PARK 101 BLOCKED_HUMAN "head-not-reapproved" "$PUSHED"
: > "$T/closed.txt"; : > "$T/queue.txt"; : > "$LOGF"
RUN
grep -q 'ladder rung: rebuild-fresh' "$LOGF" && ok || bad "4: the replay must reach the rebuild rung (log: $(tail -5 "$LOGF"))"
CLOSED 101 && bad "4: a PR must NOT be superseded inside the settle window after the resolver's own fix-round push (the #1448 close)" || ok
grep -q '^tproj TK-101 ' "$T/queue.txt" && bad "4: no rebuild may be enqueued inside the window (queue: $(cat "$T/queue.txt"))" || ok
grep -q 'SUPERSEDE DECLINED (settle-window)' "$LOGF" && ok || bad "4: the decline must say settle-window (log: $(tail -3 "$LOGF"))"
grep -q "SUPERSEDE DECLINED (settle-window).*${PUSHED:0:12}" "$LOGF" && ok \
  || bad "4: the settle-window line must name the head the resolver pushed"
[ "$(DECLINES)" = 1 ] && ok || bad "4: one decline is ONE log line (got $(DECLINES))"
[ "$(STATEJSON tproj-TK-101 | jq -r .rebuilds)" = 0 ] && ok || bad "4: a declined supersede must spend no rebuild"

# 4b. Past the window, the lead's MERGE still stands on the head that fix round
#     pushed OVER: that reviewed work is not thrown away either.
printf '%s MERGE\n' "$LEAD" > "$T/verdicts"
: > "$LOGF"
BRENV=(BR_REGEN_RUNG=0 BR_SUPERSEDE_SETTLE_SECS=0 BR_SUPERSEDE_DECLINE_ALERT_SECS=3600)
RUN
CLOSED 101 && bad "4b: a lead MERGE on the head the resolver's fix round replaced must keep the PR" || ok
grep -q 'SUPERSEDE DECLINED (verdict)' "$LOGF" && ok || bad "4b: the decline must name the verdict (log: $(tail -3 "$LOGF"))"
grep -q "SUPERSEDE DECLINED (verdict).*${LEAD:0:12}" "$LOGF" && ok || bad "4b: the verdict line must name the head the MERGE stands on"

# 4c. (review N4) A lead BLOCK on the head the fix round pushed OVER says "do
#     not merge that code", not "keep this PR": only a MERGE / MERGE-WITH-NOTES
#     on a remembered head protects it. With the window run out, the rebuild is
#     today's.
printf '%s BLOCK\n' "$LEAD" > "$T/verdicts"; : > "$LOGF"
RUN
grep -q 'SUPERSEDE DECLINED (verdict)' "$LOGF" && bad "4c: a lead BLOCK on the pushed-over head must not hold the PR (log: $(tail -3 "$LOGF"))" || ok
BRENV=("${BASEENV[@]}")
CLOSED 101 && ok || bad "4c: with no verdict and the window spent the rung must supersede as today (log: $(tail -5 "$LOGF"))"
grep -q '^tproj TK-101 ' "$T/queue.txt" && ok || bad "4c: the fresh build must be enqueued (queue: $(cat "$T/queue.txt"))"


# ============================================================================
# 6. (review N1) A DECLINE THAT KEEPS HAPPENING PAGES, ONCE. Resolver-owned
#    parks never page and this lane only alerts on ABANDONED, so a decline that
#    never ends would strand the PR silently. Past
#    BR_SUPERSEDE_DECLINE_ALERT_SECS one lane-alert per (PR, head, reason).
# ============================================================================
FRESH
PARK 9 RED_TWICE "red-twice: still red on ${B:0:8} after its failed jobs were re-run once" "$B"
printf '%s' "$B" > "$T/prhead"
printf '%s MERGE\n' "$B" > "$T/verdicts"
BRENV=(BR_REGEN_RUNG=0 BR_SUPERSEDE_SETTLE_SECS=1800 BR_SUPERSEDE_DECLINE_ALERT_SECS=600)
RUN
[ "$(ALERTS)" = 0 ] && ok || bad "6: the first decline is inside the alert threshold and must not page (alerts: $(cat "$T/lane-alert.txt"))"
# The same decline has now lasted longer than the threshold: its recorded start
# is moved back rather than slept past (a sleep is a race under load).
jq -c '.decl_since = (.decl_since - 3600)' "$H/state/blocked-resolver/tproj/tproj-TK-9.json" > "$T/st.json" \
  && cp "$T/st.json" "$H/state/blocked-resolver/tproj/tproj-TK-9.json"
RUN
[ "$(ALERTS)" = 1 ] && ok || bad "6: a decline repeated past the threshold must page exactly once (alerts: $(cat "$T/lane-alert.txt"))"
grep -q 'SUPERSEDE DECLINED.*(verdict)' "$T/lane-alert.txt" 2>/dev/null && ok || bad "6: the page must name the reason"
RUN; RUN
[ "$(ALERTS)" = 1 ] && ok || bad "6: the page is said ONCE per (PR, head, reason), not once per tick (alerts: $(ALERTS))"

# 6b. A decline on a read that cannot be made pages too (verdict-unreadable).
FRESH
PARK 9 RED_TWICE "red-twice: still red on ${A:0:8} after its failed jobs were re-run once" "$A"
printf '%s' "$A" > "$T/prhead"
touch "$T/vd-down"
BRENV=(BR_REGEN_RUNG=0 BR_SUPERSEDE_SETTLE_SECS=1800 BR_SUPERSEDE_DECLINE_ALERT_SECS=0)
RUN
[ "$(ALERTS)" = 1 ] && ok || bad "6b: verdict-unreadable must page past the threshold (alerts: $(cat "$T/lane-alert.txt"))"

# 6c. ...and so does an unreadable window knob while a window is in force.
FRESH
PARK 9 RED_TWICE "red-twice: still red on ${B:0:8} after its failed jobs were re-run once" "$B"
printf '%s' "$B" > "$T/prhead"
jq -c --arg u "https://github.com/o/tproj/pull/9" --arg h "$B" --argjson a "$(date -u +%s)" \
  '.sup_pr=$u | .sup_head=$h | .sup_at=$a | .sup_settle=true' \
  "$H/state/blocked-resolver/tproj/tproj-TK-9.json" > "$T/st.json" && cp "$T/st.json" "$H/state/blocked-resolver/tproj/tproj-TK-9.json"
BRENV=(BR_REGEN_RUNG=0 BR_SUPERSEDE_SETTLE_SECS=soon BR_SUPERSEDE_DECLINE_ALERT_SECS=0)
RUN
grep -q 'SUPERSEDE DECLINED (knob-unreadable)' "$LOGF" && ok || bad "6c: an unreadable window must decline (log: $(tail -3 "$LOGF"))"
[ "$(ALERTS)" = 1 ] && ok || bad "6c: knob-unreadable must page past the threshold (alerts: $(cat "$T/lane-alert.txt"))"
BRENV=("${BASEENV[@]}")

# ============================================================================
# 7. (review N2) A SAME-STATE RE-PARK LEAVES NO STALE head-moved. The conductor
#    re-parks BLOCKED_HUMAN -> BLOCKED_HUMAN on a new head without rewriting the
#    hand-off record, so once the resolver has RELEASED that record, the row's
#    own head is the head the park is about.
# ============================================================================
FRESH
PARK 9 BLOCKED_HUMAN "head-not-reapproved" "$B"
HANDOFF 9 "$A" released
printf '%s' "$B" > "$T/prhead"
RUN
grep -q 'SUPERSEDE DECLINED (head-moved)' "$LOGF" && bad "7: a released hand-off's old head must not read as the parked head (log: $(tail -3 "$LOGF"))" || ok
CLOSED 9 && ok || bad "7: judged on the row's current head, the park supersedes as today (log: $(tail -3 "$LOGF"))"
# ...while an UNRELEASED record still names the head the park was handed on.
FRESH
PARK 9 BLOCKED_HUMAN "head-not-reapproved" "$B"
HANDOFF 9 "$A"
printf '%s' "$B" > "$T/prhead"
RUN
grep -q 'SUPERSEDE DECLINED (head-moved)' "$LOGF" && ok || bad "7: an open hand-off on A with the PR on B is still head-moved (log: $(tail -3 "$LOGF"))"

# ============================================================================
# 8. (review N3) A verdict decline RELEASES the park, so the conductor classifies
#    the PR again and reads the lead MERGE itself: a sticky park gets no verdict
#    read. A fail-closed read keeps the park.
# ============================================================================
FRESH
PARK 9 BLOCKED_HUMAN "head-not-reapproved" "$B"
HANDOFF 9 "$B"
printf '%s' "$B" > "$T/prhead"
printf '%s MERGE\n' "$B" > "$T/verdicts"
RUN
grep -q 'SUPERSEDE DECLINED (verdict)' "$LOGF" && ok || bad "8: the lead MERGE must decline the supersede (log: $(tail -3 "$LOGF"))"
RELEASED 9 && ok || bad "8: a verdict decline must release the hand-off so the conductor reads the MERGE"
grep -q 'blocked-resolver' "$H/state/merge-conductor/handoff-released/o_tproj_9" 2>/dev/null && ok \
  || bad "8: the release marker must name this lane"
# the fail-closed read: the park is kept
FRESH
PARK 9 BLOCKED_HUMAN "head-not-reapproved" "$B"
HANDOFF 9 "$B"
printf '%s' "$B" > "$T/prhead"
touch "$T/vd-down"
RUN
grep -q 'SUPERSEDE DECLINED (verdict-unreadable)' "$LOGF" && ok || bad "8: the unreadable table must decline (log: $(tail -3 "$LOGF"))"
RELEASED 9 && bad "8: a fail-closed read must KEEP the park — nobody knows what stands on the head" || ok

# ============================================================================
# 9. (BH-4149) A LEAD BLOCK ON A HEAD FROZEN BY fix-round-noop DOES NOT KEEP THE
#    PR. The lane's fix round already ran on that head against the lead's own
#    findings and answered none of them, so declining on that BLOCK was an
#    indefinite park behind a "decide it" page. It rebuilds, and at the rebuild
#    cap it ends ABANDONED once. A BLOCK on a head with no noop round still
#    declines, as section 2's MERGE does.
# ============================================================================
NOOP() { # NOOP <head> [rebuilds] — the frozen head on TK-9's record
  jq -c --arg h "$1" --argjson r "${2:-0}" '.noop_heads=[$h] | .rebuilds=$r' \
    "$H/state/blocked-resolver/tproj/tproj-TK-9.json" > "$T/st.json" \
    && cp "$T/st.json" "$H/state/blocked-resolver/tproj/tproj-TK-9.json"
}
FRESH
PARK 9 BLOCKED_HUMAN "head-not-reapproved" "$B"
HANDOFF 9 "$B"
printf '%s' "$B" > "$T/prhead"
printf '%s BLOCK\n' "$B" > "$T/verdicts"
NOOP "$B" 3
BRENV=(BR_REGEN_RUNG=0 BR_SUPERSEDE_SETTLE_SECS=1800 BR_SUPERSEDE_DECLINE_ALERT_SECS=0)
RUN
[ "$(STATEJSON tproj-TK-9 | jq -r .outcome)" = ABANDONED ] && ok \
  || bad "9a: a frozen head under the lead's BLOCK at the rebuild cap must end ABANDONED, got '$(STATEJSON tproj-TK-9 | jq -r .outcome)' (log: $(tail -4 "$LOGF"))"
[ "$(grep -c -- "-X PATCH.*pulls/9" "$T/closed.txt" 2>/dev/null || true)" = 1 ] && ok \
  || bad "9a: the PR is closed exactly once (closed: $(cat "$T/closed.txt"))"
[ "$(DECLINES)" = 0 ] && ok || bad "9a: the BLOCK on a frozen head must not decline (log: $(grep 'SUPERSEDE DECLINED' "$LOGF"))"
[ ! -s "$T/lane-alert.txt" ] && ok || bad "9a: nothing pages a person, threshold 0 or not: $(cat "$T/lane-alert.txt")"
grep -q 'the BLOCK does not keep this PR' "$LOGF" && ok || bad "9a: the lane log says why the BLOCK was passed over (log: $(tail -4 "$LOGF"))"
: > "$LOGF"; : > "$T/lane-alert.txt"
RUN
[ "$(grep -c -- "-X PATCH.*pulls/9" "$T/closed.txt" 2>/dev/null || true)" = 1 ] && [ "$(DECLINES)" = 0 ] && [ ! -s "$T/lane-alert.txt" ] && ok \
  || bad "9a: a second tick closes, declines and pages nothing more (closed: $(cat "$T/closed.txt"); alerts: $(cat "$T/lane-alert.txt"))"
# 9b. Under the cap the same park is a fresh rebuild, not a decline.
FRESH
PARK 9 BLOCKED_HUMAN "head-not-reapproved" "$B"
HANDOFF 9 "$B"
printf '%s' "$B" > "$T/prhead"
printf '%s BLOCK\n' "$B" > "$T/verdicts"
NOOP "$B" 0
RUN
CLOSED 9 && ok || bad "9b: a frozen head under the lead's BLOCK must be superseded (log: $(tail -4 "$LOGF"))"
grep -q '^tproj TK-9 ' "$T/queue.txt" && ok || bad "9b: and rebuilt fresh (queue: $(cat "$T/queue.txt"))"
[ "$(DECLINES)" = 0 ] && ok || bad "9b: no decline line (log: $(grep 'SUPERSEDE DECLINED' "$LOGF"))"
# 9c. Negative: the same BLOCK on a head the lane never ran a round on still
#     keeps the PR, and so does a BLOCK on a DIFFERENT frozen head.
for frozen in "" "$A"; do
  FRESH
  PARK 9 BLOCKED_HUMAN "head-not-reapproved" "$B"
  HANDOFF 9 "$B"
  printf '%s' "$B" > "$T/prhead"
  printf '%s BLOCK\n' "$B" > "$T/verdicts"
  [ -n "$frozen" ] && NOOP "$frozen" 3
  RUN
  CLOSED 9 && bad "9c: a lead BLOCK on an un-frozen head (frozen: '${frozen:0:8}') must keep the PR" || ok
  grep -q 'SUPERSEDE DECLINED (verdict).*BLOCK' "$LOGF" && ok \
    || bad "9c: the BLOCK declines as before (frozen: '${frozen:0:8}'; log: $(tail -3 "$LOGF"))"
done
BRENV=("${BASEENV[@]}")

# ============================================================================
# 5. THE KNOB IS REGISTERED, required, with its default in the registry — the
#    script reads it with no literal of its own.
# ============================================================================
K=$(jq -c '.knobs[] | select(.env=="BR_SUPERSEDE_SETTLE_SECS")' "$DIR/catalog/lanes.d/blocked-resolver.json" 2>/dev/null)
[ -n "$K" ] && ok || bad "5: BR_SUPERSEDE_SETTLE_SECS must be registered in catalog/lanes.d/blocked-resolver.json"
[ -n "$K" ] && [ "$(jq -r .default <<<"$K")" = 1800 ] && ok || bad "5: its registry default must be 1800 (30 min)"
[ -n "$K" ] && [ "$(jq -r .required <<<"$K")" = true ] && ok || bad "5: it must be required: true (no literal in the script)"
grep -nE '\$\{BR_SUPERSEDE_SETTLE_SECS:[-=][^}]' "$DIR/bin/blocked-resolver.sh" >/dev/null \
  && bad "5: the script must not carry a literal default for BR_SUPERSEDE_SETTLE_SECS" || ok
K2=$(jq -c '.knobs[] | select(.env=="BR_SUPERSEDE_DECLINE_ALERT_SECS")' "$DIR/catalog/lanes.d/blocked-resolver.json" 2>/dev/null)
[ -n "$K2" ] && [ "$(jq -r .required <<<"$K2")" = true ] && ok \
  || bad "5: BR_SUPERSEDE_DECLINE_ALERT_SECS must be registered, required: true"
grep -nE '\$\{BR_SUPERSEDE_DECLINE_ALERT_SECS:[-=][^}]' "$DIR/bin/blocked-resolver.sh" >/dev/null \
  && bad "5: the script must not carry a literal default for BR_SUPERSEDE_DECLINE_ALERT_SECS" || ok

echo "blocked-resolver-supersede.bh-1642: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
