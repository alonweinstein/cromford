#!/bin/bash
# tests/blocked-resolver-green-at-head.bh-1671-test.sh — BH-1671: the rebuild
# rung must never supersede (or abandon) a PR parked for a CI reason whose
# CURRENT head is green.
#
# WHAT HAPPENED (2026-09-23). project-5 #3172 and #3175 were both green on
# `Build + Unit tests` at their current head, and bin/blocked-resolver.sh closed
# them at 11:32/11:33Z as "Superseded by a fresh build". br_supersede_guard
# (BH-1642) read the head, the park, the settle window, the verdicts and the
# hold, and never the CI on the head it was about to throw away.
#
# THE ACCEPTANCE ROWS, red first:
#   1. red twice on head A, current head B green: no close, ONE `SKIP green-at-head`.
#   2. judged on the current head B, and B has since gone green: the same.
#   3. the same fixture with B red: closed and rebuilt exactly as today.
#   4. red-ci-twice (the conductor's cross-head count), B green: not closed.
#   5. queue-ejected-twice, B green: not closed (a rebase case, not a rebuild).
#   6. negatives: B pending, B unreadable, and a green head on a reason that is
#      not a CI reason — none of them says green-at-head.
#   7. (2026-09-24) queue-ejected-twice on a repo that tests ONLY in its merge
#      queue: the head runs the fast checks, so its green answers nothing. A red
#      newest batch carrying the PR keeps the park (no green-at-head); a green
#      batch carrying it releases it as in row 5.
#
# Run from anywhere: tests/blocked-resolver-green-at-head.bh-1671-test.sh  (exit 0 = all pass)
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
[ -f "$DIR/bin/lib/mc/classify.sh" ] || exit 1   # impact: mc_ci_state is the read the guard makes
cp "$DIR/bin/lib/ticket-ownership.sh" "$H/bin/lib/" || exit 1
# The verdicts table and the hold are STUBS with the real rc shapes (see
# tests/blocked-resolver-supersede.bh-1642-test.sh): nothing stands, nothing held.
cat > "$H/bin/lib/verdicts.sh" <<'EOF'
vd_standing() { [[ "$3" =~ ^[0-9a-f]{40}$ ]] || return 2; return 1; }
vd_clear_word() { return 1; }
EOF
cat > "$H/bin/lib/hold.sh" <<'EOF'
hold_check() { printf 'clear\tno hold on this ticket\n'; return 0; }
hold_check_thread() { printf 'clear\tno-hold\n'; return 0; }  # BH-1668: the PR's own thread, clear
hold_is_pause()   { return 1; }
hold_is_abandon() { return 1; }
EOF
cat > "$H/bin/jobs-client.sh" <<EOF
queue_put() { printf '%s\n' "\$*" >> "$T/queue.txt"; echo queued; }
queue_done() { printf 'done %s\n' "\$*" >> "$T/queue.txt"; return 0; }
queue_list() { return 1; }
EOF
touch "$H/flags/fly-pool-tproj"   # pool project: a rebuild is a queue row

# CI PER HEAD. The shared stub answers `actions/runs` as unverifiable, so this
# wrapper answers it from $T/ciruns-<sha> (one `status|conclusion` line per
# workflow run, tests/lib/rest-emit.sh --runs) and hands every other call on.
# No file for a head keeps the shared stub's answer: an unreadable CI read.
mv "$T/fakebin/gh" "$T/fakebin/gh.real"
cat > "$T/fakebin/gh" <<EOF
#!/bin/bash
case "\$*" in
  *"actions/runs?event=pull_request"*)
    printf '%s\n' "\$*" >> "$T/queue-asked.txt"
    [ -f "$T/queue-runs.json" ] && { cat "$T/queue-runs.json"; exit 0; }
    exit 1 ;;
  *"-i -X GET"*"actions/runs?head_sha="*)
    a="\$*"; sha=\${a##*head_sha=}; sha=\${sha%%&*}; sha=\${sha%% *}
    printf '%s\n' "\$sha" >> "$T/ci-asked.txt"
    if [ -f "$T/ciruns-\$sha" ]; then restpr --runs - < "$T/ciruns-\$sha"; exit 0; fi ;;
esac
exec "$T/fakebin/gh.real" "\$@"
EOF
chmod +x "$T/fakebin/gh"

# The regenerate rung (1b) is off and the settle window has run out, so the park
# reaches rung 3 and the only guards left standing are the head and the CI.
BRENV=(BR_REGEN_RUNG=0 BR_SUPERSEDE_SETTLE_SECS=0 BR_SUPERSEDE_DECLINE_ALERT_SECS=3600)

A=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
B=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
LOGF="$H/logs/blocked-resolver.log"

# PARK <pr#> <STATE> <reason> <judged-head> — the conductor's row, as
# mc_transition writes it: the head it JUDGED is field 4.
PARK() {
  printf 'o/tproj#%s\t%s\t%s\t%s\t%s\t-\t%s\t%s\n' "$1" "$2" "$(date -u +%s)" "$4" "$4" "$3" \
    "https://github.com/o/tproj/pull/$1" > "$H/state/merge-conductor/pr-state.tsv"
}
# FRESH — rungs 1 and 2 already spent for TK-9, PR 9 open on head B, no CI file.
FRESH() {
  scratch_rm "$H/state/blocked-resolver"
  SPENT tproj-TK-9
  : > "$T/closed.txt"; : > "$T/queue.txt"; : > "$T/comment-bodies.txt"; : > "$LOGF"
  : > "$T/lane-alert.txt"; : > "$T/ci-asked.txt"
  rm -f "$T/ciruns-$A" "$T/ciruns-$B"
  scratch_rm "$H/state/merge-conductor/handoff"
  scratch_rm "$H/state/merge-conductor/handoff-released"
  printf 'ticket/TK-9' > "$T/prbranch"; printf 'TK-9: a thing' > "$T/prtitle"
  echo OPEN > "$T/prstate"
  printf '%s' "$B" > "$T/prhead"
}
CI() { local h="$1"; shift; printf '%s\n' "$@" > "$T/ciruns-$h"; }
CLOSED() { grep -q -- "-X PATCH.*pulls/$1" "$T/closed.txt" 2>/dev/null; }
SKIPS() { grep -c 'SKIP green-at-head' "$LOGF" 2>/dev/null || true; }
REBUILDS() { STATEJSON tproj-TK-9 | jq -r .rebuilds; }

# KEPT_GREEN <case> — the PR is left for the queue: nothing closed, nothing
# enqueued, no counter, one SKIP line, no superseded comment, park released.
KEPT_GREEN() {
  CLOSED 9 && bad "$1: a PR green on its current head must NOT be closed (closed: $(cat "$T/closed.txt"))" || ok
  grep -q '^tproj TK-9 ' "$T/queue.txt" && bad "$1: no fresh build may be enqueued (queue: $(cat "$T/queue.txt"))" || ok
  [ "$(REBUILDS)" = 0 ] && ok || bad "$1: a green-at-head decline must spend no rebuild (got $(REBUILDS))"
  [ "$(SKIPS)" = 1 ] && ok || bad "$1: exactly ONE 'SKIP green-at-head' line (got $(SKIPS); log: $(tail -3 "$LOGF"))"
  grep -q "SKIP green-at-head.*${B:0:12}" "$LOGF" && ok || bad "$1: the SKIP line must name the current head"
  grep -q 'Superseded by a fresh build' "$T/comment-bodies.txt" && bad "$1: no superseded comment may be posted" || ok
  grep -qx "$B" "$T/ci-asked.txt" && ok || bad "$1: CI must be read on the CURRENT head (asked: $(tr '\n' ' ' < "$T/ci-asked.txt"))"
  # A green head is the queue's: the park is RELEASED (br_sup_decline), so the
  # conductor judges the PR again — the marker mc_handoff_release writes.
  [ -e "$H/state/merge-conductor/handoff-released/o_tproj_9" ] && ok \
    || bad "$1: a green-at-head decline must release the conductor's park, not keep it"
}
# SUPERSEDED <case> — today's close: closed, rebuilt, and no green-at-head.
SUPERSEDED() {
  CLOSED 9 && ok || bad "$1: must be superseded as today (log: $(tail -3 "$LOGF"))"
  grep -q '^tproj TK-9 9 fly 0 ' "$T/queue.txt" && ok || bad "$1: the fresh build must be enqueued (queue: $(cat "$T/queue.txt"))"
  [ "$(REBUILDS)" = 1 ] && ok || bad "$1: one rebuild spent (got $(REBUILDS))"
  [ "$(SKIPS)" = 0 ] && ok || bad "$1: no green-at-head line when the head is not green (got $(SKIPS))"
}

# ============================================================================
# 1. THE TICKET'S FIXTURE: red twice on head A, current head B green.
# ============================================================================
FRESH
PARK 9 RED_TWICE "red-twice: still red on ${A:0:8} after its failed jobs were re-run once" "$A"
CI "$A" 'completed|failure' 'completed|failure'
CI "$B" 'completed|success'
RUN
KEPT_GREEN 1
grep -q 'SUPERSEDE DECLINED (head-moved)' "$LOGF" && bad "1: green-at-head is read first, so the line is not head-moved" || ok

# ============================================================================
# 2. JUDGED ON THE CURRENT HEAD, WHICH HAS SINCE GONE GREEN (a rerun passed).
# ============================================================================
FRESH
PARK 9 RED_TWICE "red-twice: still red on ${B:0:8} after its failed jobs were re-run once" "$B"
CI "$B" 'completed|success' 'completed|skipped'
RUN
KEPT_GREEN 2

# ============================================================================
# 3. THE SAME FIXTURE WITH HEAD B RED: closed exactly as today.
# ============================================================================
FRESH
PARK 9 RED_TWICE "red-twice: still red on ${B:0:8} after its failed jobs were re-run once" "$B"
CI "$A" 'completed|failure' 'completed|failure'
CI "$B" 'completed|failure'
RUN
SUPERSEDED 3
grep -q 'Superseded by a fresh build.*red-twice' "$T/comment-bodies.txt" && ok \
  || bad "3: the close carries today's superseded comment (bodies: $(cat "$T/comment-bodies.txt"))"

# ============================================================================
# 4. red-ci-twice — the conductor's BLOCKED_HUMAN count, current head green.
# ============================================================================
FRESH
PARK 9 BLOCKED_HUMAN "red-ci-twice: CI red twice" "$B"
CI "$B" 'completed|success'
RUN
KEPT_GREEN 4

# ============================================================================
# 5. queue-ejected-twice, current head green: a rebase case, never a rebuild.
# ============================================================================
FRESH
PARK 9 BLOCKED_HUMAN "queue-ejected-twice: ejected from the merge queue twice" "$B"
CI "$B" 'completed|success'
RUN
KEPT_GREEN 5

# ============================================================================
# 6. NEGATIVES — only an affirmative green declines.
# ============================================================================
# 6a. B pending: no green claim, so today's close.
FRESH
PARK 9 RED_TWICE "red-twice: still red on ${B:0:8} after its failed jobs were re-run once" "$B"
CI "$B" 'in_progress|'
RUN
SUPERSEDED 6a
# 6b. B unreadable (the shared stub's unverifiable answer): today's close.
FRESH
PARK 9 RED_TWICE "red-twice: still red on ${B:0:8} after its failed jobs were re-run once" "$B"
RUN
SUPERSEDED 6b
# 6c. A green head on a reason that is not about CI says nothing about it.
FRESH
PARK 9 BLOCKED_HUMAN "head-not-reapproved: the review blocked this head" "$B"
CI "$B" 'completed|success'
RUN
[ "$(SKIPS)" = 0 ] && ok || bad "6c: head-not-reapproved is not a CI reason — no green-at-head line (got $(SKIPS))"

# ============================================================================
# 7. queue-ejected-twice on a QUEUE-ONLY repo: the batch answers, not the head.
# ============================================================================
printf 'mc_queue_batch_only() { return 0; }\n' > "$H/bin/lib/queue-batch-only.sh"
QRUNS() { # QRUNS <conclusion-of-newest-batch-with-#9>
  jq -n --arg c "$1" '{workflow_runs:[
    {id:71, head_branch:"mergify/merge-queue/aa", status:"completed", conclusion:$c, created_at:"2026-09-24T12:00:00Z",
     display_title:"merge queue: checking #9 + #12 together on main (1111111)"},
    {id:70, head_branch:"mergify/merge-queue/bb", status:"completed", conclusion:"success", created_at:"2026-09-24T11:00:00Z",
     display_title:"merge queue: checking #8 on main (0000000)"},
    {id:69, head_branch:"mergify/merge-queue/cc", status:"completed", conclusion:"success", created_at:"2026-09-24T10:00:00Z",
     display_title:"merge queue: checking #9 on main (0000000)"}]}' > "$T/queue-runs.json"
}
# 7a. the newest batch carrying #9 is RED: the fast-check green is not believed.
FRESH
PARK 9 BLOCKED_HUMAN "queue-ejected-twice: ejected from the merge queue twice" "$B"
CI "$B" 'completed|success'
QRUNS failure
RUN
[ "$(SKIPS)" = 0 ] && ok || bad "7a: a red batch carrying #9 must not read as green-at-head on a queue-only repo (got $(SKIPS); log: $(tail -3 "$LOGF"))"
# The ladder goes on (here: the rung-3 rebuild this fixture has left) instead of
# releasing the park back to a conductor that would only re-park it.
CLOSED 9 && ok || bad "7a: the ladder must proceed, not release on a fast-check green (log: $(tail -3 "$LOGF"))"
grep -q 'event=pull_request' "$T/queue-asked.txt" 2>/dev/null && ok || bad "7a: the batch runs must be read"
# 7b. the newest batch carrying #9 is GREEN: released exactly as row 5.
FRESH
PARK 9 BLOCKED_HUMAN "queue-ejected-twice: ejected from the merge queue twice" "$B"
CI "$B" 'completed|success'
QRUNS success
RUN
KEPT_GREEN 7b
# 7c. no batch readable: not believed either (the head alone is not evidence).
FRESH
PARK 9 BLOCKED_HUMAN "queue-ejected-twice: ejected from the merge queue twice" "$B"
CI "$B" 'completed|success'
rm -f "$T/queue-runs.json"
RUN
[ "$(SKIPS)" = 0 ] && ok || bad "7c: an unreadable queue is not a green batch (got $(SKIPS))"
# 7d. red-twice on the same repo is about the head's OWN runs: unchanged.
FRESH
PARK 9 BLOCKED_HUMAN "red-ci-twice: CI red twice" "$B"
CI "$B" 'completed|success'
QRUNS failure
RUN
KEPT_GREEN 7d
rm -f "$H/bin/lib/queue-batch-only.sh" "$T/queue-runs.json"

echo "blocked-resolver-green-at-head.bh-1671: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
