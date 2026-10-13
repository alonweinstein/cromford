#!/bin/bash
# tests/split-watchdog-contract.bh-1805-test.sh — the split-watchdog CONTRACT
# (BH-1805, BH-1793.0): the shapes the four sibling slices import, and nothing
# else. Every stub must fail closed.
#   C1. bash -n and `set -u; .` pass on bin/lib/jobs/split-watchdog.sh,
#       bin/lib/split-watchdog.sh and bin/lib/split-watchdog-act.sh.
#   C2. sw_record / sw_seen / sw_list / sw_actions_today: rc 1, no stdout.
#   C3. sw_next_step drains a family on stdin, prints nothing, rc 0.
#   C4. sw_act with no ledger client fails closed: drains stdin, rc 1, no stdout
#       (BH-1809 replaced the stub that printed `skipped`).
#   C5. the REAL bin/jobs-client.sh loads the module (JC_MODULES names it).
#   C6. the decision lib's header carries the 14 child-state columns in order,
#       the act lib names the four outcome words.
#   C7. the lane is registered exactly once (BH-1808); the decision and act libs make no
#       side-effect call. (BH-1806 landed the routes and the ledger verbs'
#       _jobs_req bodies, so the route table and bin/lib/jobs/split-watchdog.sh
#       are no longer in this check.)
# Run from anywhere: tests/split-watchdog-contract.bh-1805-test.sh   (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $*"; }

JLIB="$DIR/bin/lib/jobs/split-watchdog.sh"
DLIB="$DIR/bin/lib/split-watchdog.sh"
ALIB="$DIR/bin/lib/split-watchdog-act.sh"
ROW=$'k\t1\tready\t0\tnone\t\t\tunknown\t\t0\tnone\t\t\tunknown'

# --- C1 -----------------------------------------------------------------------
for f in "$JLIB" "$DLIB" "$ALIB"; do
  [ -f "$f" ] && bash -n "$f" && ok || bad "C1 bash -n $f"
  bash -c 'set -u; . "$1"' _ "$f" && ok || bad "C1 set -u source $f"
done

# --- C2 -----------------------------------------------------------------------
for call in "sw_record p f c s r o" "sw_seen p c s r" "sw_list p" "sw_actions_today p"; do
  out=$(bash -c 'set -u; . "$1"; shift; "$@"' _ "$JLIB" $call 2>/dev/null); rc=$?
  [ "$rc" = 1 ] && [ -z "$out" ] && ok || bad "C2 $call rc=$rc out=[$out], want rc 1 and nothing"
done

# --- C3 -----------------------------------------------------------------------
out=$(printf '%s\n' "$ROW" | bash -c 'set -u; . "$1"; sw_next_step 1000 10 30 PLAN_STALE' _ "$DLIB" 2>/dev/null); rc=$?
[ "$rc" = 0 ] && [ -z "$out" ] && ok || bad "C3 sw_next_step rc=$rc out=[$out], want rc 0 and nothing"

# --- C4 -----------------------------------------------------------------------
out=$(printf '%s\n' "$ROW" | bash -c 'set -u; . "$1"; sw_act p f pool enqueue c r' _ "$ALIB" 2>/dev/null); rc=$?
[ "$rc" = 1 ] && [ -z "$out" ] && ok || bad "C4 sw_act rc=$rc out=[$out], want rc 1 and nothing (no ledger client)"

# --- C5: through the production client ------------------------------------------
mkdir -p "$T/h/bin/lib/jobs" "$T/h/logs"
cp "$DIR/bin/jobs-client.sh" "$T/h/bin/" && cp "$DIR"/bin/lib/jobs/*.sh "$T/h/bin/lib/jobs/"
( cd "$T/h" && HARNESS="$T/h" JOBS_HARNESS="$T/h" \
    bash -c '. bin/jobs-client.sh; declare -F sw_record sw_seen sw_list sw_actions_today' >/dev/null 2>&1 ) \
  && ok || bad "C5 bin/jobs-client.sh does not define the four sw_* verbs"
mods=$(sed -n 's/^JC_MODULES="\(.*\)"$/\1/p' "$DIR/bin/jobs-client.sh")
grep -qw 'split-watchdog' <<<"$mods" && ok || bad "C5 JC_MODULES [$mods] does not name split-watchdog"

# --- C6 -----------------------------------------------------------------------
hdr=$(grep '^#' "$DLIB" 2>/dev/null | tr '\n' ' ')
cols='key.*ticket_id.*board_status.*waiting_on_client.*pr_state.*pr_url.*merged_at_epoch.*mergeable.*head_sha.*lock_held.*queue_status.*queue_reason.*queue_finished_epoch.*deploy_serves_merge'
grep -qE "$cols" <<<"$hdr" && ok || bad "C6 $DLIB header lacks the 14 columns in order"
for w in enqueue reenqueue owed-completion handoff-rebase close-parent; do
  grep -qw -- "$w" <<<"$hdr" && ok || bad "C6 $DLIB header does not name step $w"
done
ahdr=$(grep '^#' "$ALIB" 2>/dev/null | tr '\n' ' ')
for w in acted skipped failed stalled; do
  grep -qw "$w" <<<"$ahdr" && ok || bad "C6 $ALIB header does not name outcome $w"
done

# --- C7 -----------------------------------------------------------------------
# TEST-CHANGE (BH-1806): the route registration in worker/jobs/src/index.js and
# _jobs_req in $JLIB ARE the BH-1806 slice, so both left this check. No lane or
# cron line yet, and the decision/act libs still make no side-effect call.
# TEST-CHANGE (BH-1808): the lane slice registers the lane, so C7a no longer
# asserts "not registered"; it pins that the lane is registered exactly ONCE:
# one registry entry and one cron line, the hub fragment 719.
runs=$(grep -rlE '^[^#]*bin/split-watchdog\.sh' "$DIR"/cron/ 2>/dev/null | sed "s|^$DIR/||" | sort | tr '\n' ' ')
[ "$runs" = "cron/lanes/719-split-watchdog.cron " ] && ok || bad "C7 cron lines running bin/split-watchdog.sh: [$runs], want only cron/lanes/719-split-watchdog.cron"
nreg=$(grep -l '"id": *"split-watchdog"' "$DIR"/catalog/lanes.d/*.json 2>/dev/null | wc -l | tr -d ' ')
[ "$nreg" = 1 ] && ok || bad "C7 registry entries for split-watchdog: $nreg, want 1"
side=$(grep -v '^[[:space:]]*#' "$DLIB" "$ALIB" 2>/dev/null | grep -E '\bgh |git push|curl|agent-call|_jobs_req')
[ -z "$side" ] && ok || bad "C7b side-effect call in a stub: $side"

echo "split-watchdog-contract.bh-1805: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
