#!/bin/bash
# tests/conductor-status-notes.bh-4717-test.sh — a READY or QUEUED row that has
# aged past its BUDGET is a conductor-log note, not a page (BH-4717.3 / BH-4723).
#
# WHY. mc_budget_check paged READY at 15m and QUEUED at 60m, and mc_stuck_check
# pages the same row at 20m (READY) and 60m (QUEUED) on its TTL. The budget page
# was a status report about a row the STUCK detector already owns, so it joins
# the machinery-wait states in MC_STATE_NOTE_STATES. What must NOT go quiet: the
# STUCK page itself (N3), WAIT_CI's budget page (N4), the READY-labelled defect
# page from the queue (N5), and both ways back to paging (N6, N7).
#
# Drives the REAL bin/lib/merge-conductor-lib.sh with the shipped default: the
# two knobs are unset BEFORE the lib is sourced, so a stale env cannot mask it.
#   HARNESS_TEST_SANDBOX=1 bash tests/conductor-status-notes.bh-4717-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

export HARNESS="$T/h"
mkdir -p "$HARNESS/bin" "$HARNESS/logs" "$HARNESS/state"

# lane-alert.sh IS the ALERTS boundary; beat.sh is the fallback one. Both record.
cat > "$HARNESS/bin/lane-alert.sh" <<STUB
#!/bin/bash
printf '%s\n' "\$*" >> "$T/lane-alert.calls"
STUB
cat > "$HARNESS/bin/beat.sh" <<STUB
#!/bin/bash
printf '%s\n' "\$1" >> "$T/beats.txt"
STUB
chmod +x "$HARNESS/bin/lane-alert.sh" "$HARNESS/bin/beat.sh"
: > "$T/lane-alert.calls"; : > "$T/beats.txt"

unset MC_STATE_NOTE_STATES MC_STATE_NOTES_ALERT
# shellcheck source=/dev/null
. "$DIR/bin/lib/merge-conductor-lib.sh"
SHIPPED_NOTE_STATES="$MC_STATE_NOTE_STATES"

nalerts() { wc -l < "$T/lane-alert.calls" | tr -d ' '; }
nbeats()  { wc -l < "$T/beats.txt" | tr -d ' '; }
reset()   { : > "$T/lane-alert.calls"; : > "$T/beats.txt"; : > "$MC_LOG"; }
mkdir -p "$(dirname "$MC_ROWS")"
NOW=$(date -u +%s)
U=https://github.com/example-org/x/pull

row() {  # row <key> <state> <since> — one fresh conductor row, the only one
  printf '%s\t%s\t%s\tdeadbeef\tdeadbeef\t-\tclean\t%s/%s\n' "$1" "$2" "$3" "$U" "${1##*#}" > "$MC_ROWS"
}

# ---------- N1. READY past its 15m budget: a note, no page ------------------
reset; row example-org/x#1 READY $((NOW-960))
mc_budget_check example-org/x#1 READY $((NOW-960)) "$U/1" "merge flag off"
[ "$(nalerts)" = 0 ] && ok || bad "N1: a READY budget age must not page (got: $(cat "$T/lane-alert.calls"))"
[ "$(nbeats)" = 0 ] && ok || bad "N1: and must not beat a fleet_alert (got: $(cat "$T/beats.txt"))"
[ "$(grep -c 'state note (not an alert): READY' "$MC_LOG")" = 1 ] \
  && ok || bad "N1: the READY age must be ONE conductor-log note (got: $(cat "$MC_LOG"))"

# ---------- N2. QUEUED past its 60m budget: a note, no page -----------------
reset; row example-org/x#2 QUEUED $((NOW-3900))
mc_budget_check example-org/x#2 QUEUED $((NOW-3900)) "$U/2" "in the merge queue"
[ "$(nalerts)" = 0 ] && ok || bad "N2: a QUEUED budget age must not page (got: $(cat "$T/lane-alert.calls"))"
[ "$(nbeats)" = 0 ] && ok || bad "N2: and must not beat a fleet_alert (got: $(cat "$T/beats.txt"))"
[ "$(grep -c 'state note (not an alert): QUEUED' "$MC_LOG")" = 1 ] \
  && ok || bad "N2: the QUEUED age must be ONE conductor-log note (got: $(cat "$MC_LOG"))"

# ---------- N3. the STUCK detector still pages READY past its 20m TTL -------
reset; row example-org/x#3 READY $((NOW-1300))
mc_stuck_check example-org/x#3 READY $((NOW-1300)) deadbeefcafe0000 "$U/3" clean >/dev/null
[ "$(grep -c 'STUCK:' "$T/lane-alert.calls")" = 1 ] && [ "$(nalerts)" = 1 ] \
  && ok || bad "N3: a READY row past its STUCK TTL must page exactly once (got: $(cat "$T/lane-alert.calls"))"

# ---------- N4. WAIT_CI is NOT in the note set: its budget still pages ------
reset; row example-org/x#4 WAIT_CI $((NOW-1900))
mc_budget_check example-org/x#4 WAIT_CI $((NOW-1900)) "$U/4" "checks pending"
[ "$(grep -c 'WAIT_CI' "$T/lane-alert.calls")" = 1 ] && [ "$(nalerts)" = 1 ] \
  && ok || bad "N4: a WAIT_CI budget age must still page once (got: $(cat "$T/lane-alert.calls"))"

# ---------- N5. a READY-labelled defect still pages ------------------------
reset
mc_queue_inactive_alert example-org/x "$U/5" "no ack"
[ "$(grep -c 'READY .*mergify queue not answering' "$T/lane-alert.calls")" = 1 ] && [ "$(nalerts)" = 1 ] \
  && ok || bad "N5: the queue-not-answering READY page must still page (got: $(cat "$T/lane-alert.calls"))"

# ---------- N6. MC_STATE_NOTES_ALERT=1 restores the READY page --------------
reset; row example-org/x#6 READY $((NOW-960))
MC_STATE_NOTES_ALERT=1 mc_budget_check example-org/x#6 READY $((NOW-960)) "$U/6" "merge flag off"
[ "$(nalerts)" = 1 ] && ok || bad "N6: MC_STATE_NOTES_ALERT=1 must page a READY budget age (got $(nalerts))"

# ---------- N7. the knob is registered, settable, and read ------------------
jq -e '.knobs[]|select(.env=="MC_STATE_NOTE_STATES" and .type=="string" and (.settable//true) and .read_in=="bin/lib/mc/log.sh")' \
  "$DIR/catalog/lanes.d/merge-conductor.json" >/dev/null \
  && ok || bad "N7: MC_STATE_NOTE_STATES must be a settable string knob read in bin/lib/mc/log.sh"
( cd "$DIR" && HARNESS_TEST_SANDBOX=1 bin/lanes-build.sh --check >/dev/null 2>&1 ) \
  && ok || bad "N7: bin/lanes-build.sh --check must pass with the knob registered"
[ "$SHIPPED_NOTE_STATES" = "HEAD_MOVED STACKED_WAIT NEEDS_REBASE REBASING READY QUEUED" ] \
  && ok || bad "N7: the shipped default is the four machinery waits plus READY QUEUED (got: $SHIPPED_NOTE_STATES)"
# A settings row that names the legacy four puts the READY page back, no deploy.
reset; row example-org/x#7 READY $((NOW-960))
MC_STATE_NOTE_STATES="HEAD_MOVED STACKED_WAIT NEEDS_REBASE REBASING" \
  mc_budget_check example-org/x#7 READY $((NOW-960)) "$U/7" "merge flag off"
[ "$(nalerts)" = 1 ] && ok || bad "N7: the legacy four in MC_STATE_NOTE_STATES must page READY again (got $(nalerts))"

# ---------- MUTATION: drop READY from the shipped default, N1 must page -----
# D1/D3: the sed must actually change the file, or this block proves nothing.
mkdir -p "$T/mut"; cp -r "$DIR/bin/lib" "$T/mut/lib"
sed -i 's/ READY QUEUED}/ QUEUED}/' "$T/mut/lib/mc/log.sh"
if cmp -s "$DIR/bin/lib/mc/log.sh" "$T/mut/lib/mc/log.sh"; then
  bad "MUT: the mutation pattern ' READY QUEUED}' is absent from bin/lib/mc/log.sh — nothing was mutated"
else
  reset
  MUTN=$(
    unset MC_STATE_NOTE_STATES MC_STATE_NOTES_ALERT
    # shellcheck source=/dev/null
    . "$T/mut/lib/merge-conductor-lib.sh"
    row example-org/x#9 READY $((NOW-960))
    mc_budget_check example-org/x#9 READY $((NOW-960)) "$U/9" "merge flag off"
    wc -l < "$T/lane-alert.calls" | tr -d ' '
  )
  [ "$MUTN" = 1 ] && ok || bad "MUT: with READY out of the default, N1 must page (got $MUTN) — the suite cannot see the change"
fi

echo "pass=$PASS fail=$FAIL"
[ "$FAIL" -eq 0 ]
