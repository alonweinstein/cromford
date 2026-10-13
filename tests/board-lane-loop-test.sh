#!/bin/bash
# tests/board-lane-loop-test.sh — two automated lanes may not argue over a ticket.
#
# THE INCIDENT THIS PINS (project-3 TK-135, 2026-09-05 20:21Z → 09-06 07:21Z).
# The OS's hourly deploy audit promoted the ticket to Review on PR #289 (merged,
# serving). The triage lane knew a second build was queued with no PR yet, so it
# moved the ticket back with a correction comment. An hour later the audit saw
# In Progress + every named PR merged and serving, and promoted again on the very
# same evidence. Twelve round trips, 31 duplicate client-visible comments, until
# the second PR opened and the audit's own demote lane took over.
#
# The OS half is fixed in the app (the audit refuses to re-promote a ticket whose
# live stamp already names the shipping commit). This test pins the harness half:
# every app-board prompt must carry the reversal cap — correct an automated
# lane's move at most once per ticket and commit, then ALERT once and stop.
# Same family as tests/alert-loop-test.sh: A LANE'S OWN OUTPUT IS NEVER ITS OWN
# INPUT, and another lane's automated output is not a reason to act twice.
#
# Run from anywhere: tests/board-lane-loop-test.sh   (exit 0 = all pass)
set -u
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR="$(cd "$(dirname "$0")/.." && pwd)"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

# Every prompt that already knows the app's [AI Triage] comment is not a person
# is a prompt whose board has automated lanes, so it needs the cap too.
PROMPTS=$(grep -l 'own `\[AI Triage\]` comment' "$DIR"/prompts/*.md)
[ -n "$PROMPTS" ] && ok || bad "no app-board prompt found (the [AI Triage] anchor line moved?)"

for P in $PROMPTS; do
  N=$(basename "$P")
  grep -q 'deploy audit is a lane, not a person' "$P" \
    && ok || bad "$N: missing the deploy-audit reversal cap"
  grep -q 'AT MOST ONCE per ticket and commit' "$P" \
    && ok || bad "$N: the cap must be stated per ticket AND commit (a newer merge is new evidence)"
  grep -q 'do NOT comment and do NOT move it back again' "$P" \
    && ok || bad "$N: the second reversal must be neither a comment nor a move"
  grep -q 'Write ONE ALERTS.log line' "$P" \
    && ok || bad "$N: the second sighting escalates once, it does not re-derive"
done

echo "board-lane-loop-test: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
