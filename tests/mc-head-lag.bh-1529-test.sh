#!/bin/bash
# tests/mc-head-lag.bh-1529-test.sh — a PR whose head LAGS its branch tip is
# closed and reopened ONCE, after MC_HEAD_LAG_MINS, and never again (BH-1529).
#
# THE DEFECT THIS PINS. 2026-09-22, PR #1480: the branch was pushed to b3bd7457
# while GitHub's PR object kept answering head 1cfafae7 for ~20 minutes. The new
# head had zero check-runs and nothing moved until the lead closed and reopened
# the PR by hand. mc_kick_ci fires on a retarget and on a run-less head the PR
# object KNOWS about; a head the PR object has not heard of is neither.
#
# WHAT IS DRIVEN. Four open PRs through the real bin/merge-conductor.sh, gh and
# the clock stubbed:
#   #91  list head OLD91, branch tip NEW91 — the lag.
#   #92  list head == branch tip — untouched.
#   #93  a FORK PR (isCrossRepository) that would look lagging — never read,
#        never touched: its head ref names a branch in someone else's repo.
#   #94  the branch read answers 500 — unverifiable, so the tick is skipped.
# Sections: observe mode writes nothing (A); below N minutes nothing is kicked
# (B); past N minutes #91 is closed and reopened exactly once and #92/#93/#94
# are not (C); a second tick does not reopen again, and the still-lagging head
# pages exactly once (D); a warm ETag cache adds no counted read (E).
#
# Run from anywhere: tests/mc-head-lag.bh-1529-test.sh   (exit 0 = all pass)
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
         "$T/h/env" "$T/fakebin" "$T/repos/demo-os/.git"
# gh-rest-etag.sh rides along: section E is about the ETag half, and gh-rest.sh
# degrades to unconditional reads without it — a suite that claimed "no counted
# read on a warm cache" without it would be green on a conductor that never asked.
cp "$DIR/bin/lib/gh-pr-list.sh" "$DIR/bin/lib/merge-conductor-lib.sh" "$DIR/bin/lib/gh-budget.sh" \
   "$DIR/bin/lib/gh-rest.sh" "$DIR/bin/lib/gh-rest-var.sh" "$DIR/bin/lib/gh-rest-etag.sh" "$T/h/bin/lib/"
mkdir -p "$T/h/bin/lib/mc" && cp "$DIR"/bin/lib/mc/*.sh "$T/h/bin/lib/mc/"
cp "$DIR/bin/merge-conductor.sh" "$DIR/bin/fleet-conf.sh" "$DIR/bin/jobs-client.sh" "$T/h/bin/"
mkdir -p "$T/h/bin/lib/jobs" && cp "$DIR"/bin/lib/jobs/*.sh "$T/h/bin/lib/jobs/"
cp "$DIR/tests/lib/rest-emit.sh" "$T/fakebin/restpr"; chmod +x "$T/fakebin/restpr"

OLD91=aaaa0091aaaa; NEW91=bbbb0091bbbb; H92=cccc0092cccc
OLD93=dddd0093dddd; OLD94=eeee0094eeee

# gh: the open list (isCrossRepository rides it), the branch reads (ETag'd, 304
# on If-None-Match), and every PATCH recorded. The branch arms are anchored on
# the end of the argv or a following space so ticket/TK-9 never answers TK-91.
cat > "$T/fakebin/gh" <<EOF
#!/bin/bash
printf '%s\n' "\$*" >> "$T/gh-calls.txt"
branch() { # branch <name> <sha>
  printf '%s\n' "\$*" >> "$T/branch-reads.txt"
  # The ETag is the tip's, as GitHub's is a content hash: a push changes it.
  case "\$ARGS" in *"If-None-Match: \"b-\$1-\$2\""*)
    printf 'HTTP/1.1 304 Not Modified\r\nETag: "b-%s-%s"\r\n\r\n' "\$1" "\$2"; exit 0 ;; esac
  printf 'HTTP/1.1 200 OK\r\nETag: "b-%s-%s"\r\n\r\n' "\$1" "\$2"
  jq -nc --arg n "ticket/pb-\$1" --arg s "\$2" '{name:\$n,commit:{sha:\$s}}'; exit 0
}
ARGS="\$*"
case "\$*" in
  *"auth token"*) echo faketoken ;;
  *"api -X PATCH repos/example-org/demo-os/pulls/"*" -f state=closed"*)
    [ -f "$T/refuse" ] && { printf '%s\n' "\$*" >> "$T/refused.txt"; exit 1; }
    printf '%s\n' "\$*" >> "$T/kicks.txt"; exit 0 ;;
  *"api -X PATCH repos/example-org/demo-os/pulls/"*" -f state="*)
    printf '%s\n' "\$*" >> "$T/kicks.txt"; exit 0 ;;
  *"api -i -X PATCH"*|*"api -i -X POST"*|*"pr merge"*|*"pr edit"*|*"pr close"*)
    printf '%s\n' "\$*" >> "$T/gh-writes.txt"; exit 1 ;;
  *"api -i -X GET repos/example-org/demo-os/branches/ticket/TK-91"|*"api -i -X GET repos/example-org/demo-os/branches/ticket/TK-91 "*)
    branch 91 "\$(cat "$T/tip91")" ;;
  *"api -i -X GET repos/example-org/demo-os/branches/ticket/TK-92"|*"api -i -X GET repos/example-org/demo-os/branches/ticket/TK-92 "*)
    branch 92 "$H92" ;;
  *"api -i -X GET repos/example-org/demo-os/branches/ticket/TK-93"*)
    branch 93 ffff0093ffff ;;
  *"api -i -X GET repos/example-org/demo-os/branches/ticket/TK-94"*)
    printf '%s\n' "\$*" >> "$T/branch-reads.txt"; restpr --raw 500 '{"message":"boom"}' ;;
  *"api -i -X GET repos/example-org/demo-os/pulls/"*"/files"*) restpr --raw 200 '[]' ;;
  *"api -i -X GET repos/example-org/demo-os/pulls/"*) restpr OPEN x ticket/pb-9x main ;;
  *"pr list -R example-org/demo-os --state open"*)
    cat <<J
[{"number":91,"url":"https://github.com/example-org/demo-os/pull/91","headRefOid":"\$(cat "$T/head91")","headRefName":"ticket/TK-91","isDraft":false,"mergeStateStatus":"BLOCKED","mergeable":"MERGEABLE","state":"OPEN","labels":[],"baseRefName":"main","isCrossRepository":false},
 {"number":92,"url":"https://github.com/example-org/demo-os/pull/92","headRefOid":"$H92","headRefName":"ticket/TK-92","isDraft":false,"mergeStateStatus":"BLOCKED","mergeable":"MERGEABLE","state":"OPEN","labels":[],"baseRefName":"main","isCrossRepository":false},
 {"number":93,"url":"https://github.com/example-org/demo-os/pull/93","headRefOid":"$OLD93","headRefName":"ticket/TK-93","isDraft":false,"mergeStateStatus":"BLOCKED","mergeable":"MERGEABLE","state":"OPEN","labels":[],"baseRefName":"main","isCrossRepository":true},
 {"number":94,"url":"https://github.com/example-org/demo-os/pull/94","headRefOid":"$OLD94","headRefName":"ticket/TK-94","isDraft":false,"mergeStateStatus":"BLOCKED","mergeable":"MERGEABLE","state":"OPEN","labels":[],"baseRefName":"main","isCrossRepository":false}]
J
    ;;
  # mc_hold_keeps_pr's plain PR read (BH-1460): the branch names the ticket.
  *"api repos/example-org/demo-os/pulls/91") restpr OPEN x ticket/TK-91 main | tail -1 ;;
  *"pr list"*) echo "[]" ;;
  *"actions/runs?head_sha="*) printf 'in_progress|\n' ;;
  *"api rate_limit"*) echo '{"resources":{"core":{"remaining":5000,"limit":5000,"reset":2000000000},"graphql":{"remaining":5000,"limit":5000,"reset":2000000000}}}' ;;
  *) echo "" ;;
esac
exit 0
EOF
chmod +x "$T/fakebin/gh"
printf '%s' "$OLD91" > "$T/head91"; printf '%s' "$NEW91" > "$T/tip91"

command -v flock >/dev/null || { printf '#!/bin/bash\nexit 0\n' > "$T/fakebin/flock"; chmod +x "$T/fakebin/flock"; }
cat > "$T/fakebin/curl" <<'EOF'
#!/bin/bash
printf '{"error":"not found"}\n404\n'
EOF
chmod +x "$T/fakebin/curl"

printf 'demo-os example-org/demo-os https://demo.example /api/board 2 box-demo\n' > "$T/h/fleet.conf"
: > "$T/h/env/global.env"
printf '#!/bin/bash\necho "" > "$4"; exit 0\n' > "$T/h/bin/agent-call.sh"; chmod +x "$T/h/bin/agent-call.sh"

run_tick() { ( cd "$T" && PATH="$T/fakebin:$PATH" HARNESS="$T/h" HARNESS_SECRET=x \
  MC_REPOS="$T/repos" MC_MERGE_SETTLE=0 MC_MERGE_TREE=0 MC_DETACHED_REBASE=0 MC_KICK_REOPEN_SLEEP=0 \
  MC_PR_PARALLEL=1 MC_HEAD_LAG_MINS=10 \
  env "$@" bash "$T/h/bin/merge-conductor.sh" >/dev/null 2>"$T/tick.err" ) \
  || { echo "tick rc=$? stderr:"; tail -5 "$T/tick.err"; }; }
LOG="$T/h/logs/merge-conductor.log"
ALERTS="$T/h/logs/ALERTS.log"
LAGDIR="$T/h/state/merge-conductor/head-lag"
# backdate <pr> <secs> — the clock half of the stub: the lag started <secs> ago.
backdate() {
  local f="$LAGDIR/example-org_demo-os_$1" since
  [ -f "$f" ] || { bad "no head-lag state was recorded for #$1 (looked for $f)"; return 1; }
  since=$(cut -f3 "$f"); awk -F'\t' -v OFS='\t' -v s="$((since - $2))" '{$3=s; print}' "$f" > "$f.t" && mv "$f.t" "$f"
}
kicks_of() { grep -c "pulls/$1 -f state=$2" "$T/kicks.txt" 2>/dev/null || true; }
counted() { grep 'TICK demo-os ' "$LOG" | tail -1 | sed -E 's/.* counted=([0-9]+).*/\1/'; }
: > "$T/kicks.txt"; : > "$T/gh-writes.txt"; : > "$T/branch-reads.txt"; : > "$T/gh-calls.txt"

# ============================================================================
# A. OBSERVE MODE WRITES NOTHING, even past the window.
# ============================================================================
run_tick
backdate 91 700
run_tick
[ -s "$T/kicks.txt" ] && bad "an observe-only tick closed or reopened a PR: $(cat "$T/kicks.txt")" || ok
grep -q 'demo-os#91 .*would close and reopen' "$LOG" \
  && ok || bad "observe mode must say what it would do about the lagging head (log: $(grep 'demo-os#91' "$LOG" | tail -2))"
[ -s "$ALERTS" ] && grep -q 'HEAD_LAG' "$ALERTS" && bad "observe mode must not page: $(cat "$ALERTS")" || ok

# ============================================================================
# B. BELOW THE WINDOW NOTHING IS KICKED (actions on, lag fresh).
# ============================================================================
touch "$T/h/flags/merge-conductor-actions"
scratch_rm "$LAGDIR"
run_tick
[ "$(kicks_of 91 closed)" = 0 ] && ok || bad "a lag younger than MC_HEAD_LAG_MINS must not be kicked (kicks: $(cat "$T/kicks.txt"))"

# ============================================================================
# C. PAST THE WINDOW: #91 closed and reopened exactly once; nobody else.
# ============================================================================
backdate 91 700
run_tick
[ "$(kicks_of 91 closed)" = 1 ] && [ "$(kicks_of 91 open)" = 1 ] \
  && ok || bad "the lagging PR must be closed and reopened exactly once (kicks: $(cat "$T/kicks.txt"))"
grep -q "demo-os#91 HEAD_LAG_KICKED.*${OLD91:0:8}.*${NEW91:0:8}" "$LOG" \
  && ok || bad "one log line must name the PR, the stale head and the tip (log: $(grep 'demo-os#91' "$LOG" | tail -2))"
[ "$(kicks_of 92 closed)" = 0 ] && ok || bad "a PR whose head matches its tip must be untouched"
[ "$(kicks_of 93 closed)" = 0 ] && ok || bad "a FORK PR must never be closed or reopened"
grep -q 'branches/ticket/TK-93' "$T/branch-reads.txt" \
  && bad "a fork PR's head ref must never be read off the base repo (it names someone else's branch)" || ok
[ "$(kicks_of 94 closed)" = 0 ] && ok || bad "a PR whose tip could not be read must be skipped, never kicked"
[ -f "$LAGDIR/example-org_demo-os_94" ] \
  && bad "an unreadable tip must not start a lag clock: $(cat "$LAGDIR/example-org_demo-os_94")" || ok
[ -f "$LAGDIR/example-org_demo-os_92" ] && bad "a matching PR must hold no lag state" || ok
[ -s "$T/gh-writes.txt" ] && bad "nothing else may be written: $(cat "$T/gh-writes.txt")" || ok

# ============================================================================
# D. A SECOND TICK DOES NOT REOPEN AGAIN; a lag that outlives the reopen by the
#    window pages ONCE.
# ============================================================================
run_tick
[ "$(kicks_of 91 closed)" = 1 ] && ok || bad "a second tick must not reopen again (kicks: $(cat "$T/kicks.txt"))"
grep -q 'HEAD_LAG' "$ALERTS" 2>/dev/null && bad "no alert before the post-reopen window has passed: $(cat "$ALERTS")" || ok
f="$LAGDIR/example-org_demo-os_91"
awk -F'\t' -v OFS='\t' '{$4=$4-700; print}' "$f" > "$f.t" && mv "$f.t" "$f"
run_tick; run_tick
[ "$(kicks_of 91 closed)" = 1 ] && ok || bad "the reopen is spent once per tip, not once per tick (kicks: $(cat "$T/kicks.txt"))"
[ "$(grep -c 'demo-os#91 .*HEAD_LAG' "$ALERTS" 2>/dev/null || true)" = 1 ] \
  && ok || bad "a lag that persists after the reopen must page exactly once (ALERTS: $(cat "$ALERTS" 2>/dev/null))"
[ "$(grep -c 'demo-os#94 head-lag check skipped' "$LOG" || true)" = 1 ] \
  && ok || bad "an unreadable tip is said once per head, not once per tick (got $(grep -c 'demo-os#94 head-lag check skipped' "$LOG"))"
# GitHub catches up: the state goes, and the next lag starts a fresh clock.
printf '%s' "$NEW91" > "$T/head91"
run_tick
[ -f "$f" ] && bad "a head that caught up must drop its lag state: $(cat "$f")" || ok

# ============================================================================
# E. A WARM ETAG CACHE ADDS NO COUNTED READ. The same tick with the check off
#    (MC_HEAD_LAG_MINS=0) and on: the check's branch reads go out conditional
#    and 304, so the TICK line's counted= must be the same number.
# ============================================================================
run_tick; run_tick MC_HEAD_LAG_MINS=0; C0=$(counted)
run_tick; C1=$(counted)
[ -n "$C0" ] && [ "$C1" = "$C0" ] \
  && ok || bad "the head-lag check must cost no counted read on a warm cache (counted off=$C0 on=$C1)"
# ...and the meter is live: with the cache emptied the same tick DOES count
# the two readable branch reads, so the equality above is not a counter that
# never moves.
rm -rf "$T/h/state/gh-etag"; run_tick; C2=$(counted)
[ "$C2" = "$((C0 + 2))" ] \
  && ok || bad "a cold cache must count the branch reads (counted off=$C0 cold=$C2) — else section E proves nothing"
grep -q 'If-None-Match: "b-92-' "$T/gh-calls.txt" \
  && ok || bad "the branch read must go out conditional once its ETag is cached"

# ============================================================================
# F. A HELD TICKET'S PR IS NOT TOUCHED, and the hold does not spend the reopen.
#    The seam is bin/lib/ticket-ownership.sh's to_lane_hold, which the conductor
#    sources when the file is there; this fixture's copy holds #91 only.
# ============================================================================
printf 'cafe0091cafe' > "$T/tip91"
run_tick
backdate 91 700
printf 'to_lane_hold() { [ "$3" = 91 ] && { echo "$2#$3 held" >> "%s/holds.txt"; return 0; }; return 1; }\n' "$T" \
  > "$T/h/bin/lib/ticket-ownership.sh"
K0=$(kicks_of 91 closed)
run_tick
[ "$(kicks_of 91 closed)" = "$K0" ] && ok || bad "a held ticket's PR must not be closed and reopened (kicks: $(cat "$T/kicks.txt"))"
grep -q 'demo-os#91 held' "$T/holds.txt" 2>/dev/null && ok || bad "the ownership hold must be asked before the kick"
[ "$(cut -f4 "$LAGDIR/example-org_demo-os_91")" = 0 ] \
  && ok || bad "a hold must not spend the one reopen for this tip (state: $(cat "$LAGDIR/example-org_demo-os_91"))"

# ============================================================================
# G. A LEAD PR ON A HOLD TICKET (fix round 1). to_lane_hold exempts a lead's
#    PR, mc_hold_keeps_pr (the BH-1460 hold mc_kick_ci obeys) does not. The
#    reopen must not be spent, and nothing may page "after one close/reopen"
#    about a PR nobody closed. The hold comes through a hold.sh, as on a box.
# ============================================================================
printf 'to_lane_hold() { return 1; }\n' > "$T/h/bin/lib/ticket-ownership.sh"
cat > "$T/h/bin/lib/hold.sh" <<'HOLD'
hold_check() { if [ "$2" = 91 ]; then printf 'held\thold:body HOLD: the lead builds this\n'; else printf 'clear\tno hold\n'; fi; }
hold_is_pause()   { case "${1:-}" in *"	hold:"*) return 0 ;; esac; return 1; }
hold_is_abandon() { case "${1:-}" in *"	abandon:"*) return 0 ;; esac; return 1; }
HOLD
A0=$(grep -c 'HEAD_LAG' "$ALERTS" 2>/dev/null || true)
K0=$(kicks_of 91 closed)
run_tick; run_tick
[ "$(kicks_of 91 closed)" = "$K0" ] && ok || bad "a lead PR on a HOLD ticket must not be closed (kicks: $(cat "$T/kicks.txt"))"
[ "$(cut -f4 "$LAGDIR/example-org_demo-os_91")" = 0 ] \
  && ok || bad "the BH-1460 hold must not spend the reopen (state: $(cat "$LAGDIR/example-org_demo-os_91"))"
[ "$(grep -c 'HEAD_LAG' "$ALERTS" 2>/dev/null || true)" = "$A0" ] \
  && ok || bad "a held PR must not page a close/reopen that never happened: $(tail -1 "$ALERTS")"
grep -q 'demo-os#91 HEAD_LAG kick' "$LOG" && bad "no kick may even be attempted on a held PR: $(grep 'demo-os#91 HEAD_LAG kick' "$LOG" | tail -1)" || ok
rm -f "$T/h/bin/lib/hold.sh"

# ============================================================================
# H. A CLOSE GITHUB REFUSES CHANGES NOTHING, so it does not spend the reopen —
#    until MC_KICK_REOPEN_TRIES refusals, and then the page says it was never
#    closed rather than claiming a close/reopen.
# ============================================================================
touch "$T/refuse"; : > "$T/refused.txt"
run_tick
[ "$(wc -l < "$T/refused.txt" | tr -d ' ')" = 1 ] && [ "$(cut -f4 "$LAGDIR/example-org_demo-os_91")" = 0 ] \
  && ok || bad "one refused close must leave the reopen unspent (refused=$(wc -l < "$T/refused.txt"), state: $(cat "$LAGDIR/example-org_demo-os_91"))"
run_tick; run_tick; run_tick
[ "$(wc -l < "$T/refused.txt" | tr -d ' ')" = 3 ] \
  && ok || bad "the close is attempted at most MC_KICK_REOPEN_TRIES (3) times per tip (got $(wc -l < "$T/refused.txt"))"
[ "$(cut -f6 "$LAGDIR/example-org_demo-os_91")" = refused ] \
  && ok || bad "after the last refusal the state must say refused (state: $(cat "$LAGDIR/example-org_demo-os_91"))"
f="$LAGDIR/example-org_demo-os_91"
awk -F'\t' -v OFS='\t' '{$4=$4-700; print}' "$f" > "$f.t" && mv "$f.t" "$f"
run_tick
tail -1 "$ALERTS" | grep -q 'demo-os#91 .*HEAD_LAG.*refused the close 3 times' \
  && ok || bad "the page must say the close was refused, not that a reopen happened (got: $(tail -1 "$ALERTS"))"
rm -f "$T/refuse"

echo "mc-head-lag.bh-1529-test: $PASS pass, $FAIL fail"
[ "$FAIL" = 0 ]
