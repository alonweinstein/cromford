#!/bin/bash
# tests/alert-project-routing-test.sh — an alert about a project must NAME it.
#
# WHY (2026-09-01). Telegram alerts now route to a per-project forum topic, and
# the field they route on is the beat's `project`. Two lanes hardcoded it EMPTY:
# alerts-medic.sh and watchdog-responder.sh both shipped
# `"project":""` in the escalation contract they hand the model.
#
# The consequence was invisible rather than broken: the medic would correctly
# diagnose an project-3 problem, escalate it perfectly, and file it into the General
# channel alongside every other project's traffic — which is exactly the pile
# the topics were created to end. Nothing errored; the alert simply arrived
# where nobody was looking for it.
#
# A per-project alert with no project is a routing bug wearing the costume of a
# working alert, so the contract is asserted here rather than left to review.
#
# Run from anywhere: tests/alert-project-routing-test.sh   (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

# 1. The two model-authored escalation contracts must ASK for a project.
for f in bin/alerts-medic.sh bin/watchdog-responder.sh; do
  ! grep -q '\\"project\\":\\"\\"' "$DIR/$f" \
    && ok || bad "$f still hardcodes an empty project — its escalations can never reach a project topic"
  grep -q 'spelled exactly as in the FLEET table' "$DIR/$f" \
    && ok || bad "$f must tell the model WHICH spelling routes (a near-miss name silently falls back to General)"
  # ...and it must NOT restate the roster. fleet.conf is the registry; a list
  # typed into a prompt goes stale the moment a project is added or parked, and
  # then the model confidently names a project that routes nowhere. The first
  # draft of this very fix hardcoded all nine names, which is the same class of
  # bug as a hardcoded model id or a hardcoded rate.
  ! grep -qE '\(project-1, project-2|project-1, project-2, project-3' "$DIR/$f" \
    && ok || bad "$f hardcodes the project roster — render it from fleet.conf instead"
  grep -q 'fleet.conf' "$DIR/$f" \
    && ok || bad "$f must point at fleet.conf as the source of valid project names"
  grep -q 'buries a project problem in the General channel' "$DIR/$f" \
    && ok || bad "$f must say what a blank project COSTS, or the empty case reads as the harmless default"
done

# 2. Genuinely fleet-wide lanes are the deliberate exception and must stay put.
# Without this the rule above reads as "always set a project", and the next
# person dutifully invents one for a cost report that belongs to no project.
for f in bin/cap-loss-detector.sh bin/cost-report.sh; do
  grep -q 'project:""' "$DIR/$f" \
    && ok || bad "$f is fleet-wide and should keep an empty project (General is correct for it)"
done

# 3. Per-project beats defined in the prompts must pass the project through.
# These are the new-ticket pings, the most frequent per-project alert there is.
TN=$(grep -rl 'kind:"ticket_new"' "$DIR/prompts/" 2>/dev/null | wc -l | tr -d ' ')
[ "${TN:-0}" -ge 1 ] && ok || bad "no prompt defines the ticket_new beat any more — has the contract moved?"
MISSING=""
for f in $(grep -rl 'kind:"ticket_new"' "$DIR/prompts/" 2>/dev/null); do
  grep -q 'kind:"ticket_new",project:\$p' "$f" || MISSING="$MISSING $(basename "$f")"
done
[ -z "$MISSING" ] && ok || bad "these prompts emit ticket_new without passing the project through:$MISSING"

# The medic's prompt already carries the FLEET table (triage-map.sh renders it
# from fleet.conf every run), so it only has to REFERENCE it. The responder gets
# no orientation map, so it has to render the list itself -- and fail loudly
# rather than hand the model an empty roster.
grep -q 'FLEET_PROJECTS=$("$HARNESS/bin/fleet-conf.sh" --projects' "$DIR/bin/watchdog-responder.sh" \
  && ok || bad "watchdog-responder must render valid project names from fleet.conf at runtime"
grep -q 'fleet.conf unreadable' "$DIR/bin/watchdog-responder.sh" \
  && ok || bad "an unreadable fleet.conf must say so in the prompt, not silently pass an empty roster"

echo "pass=$PASS fail=$FAIL"
[ "$FAIL" -eq 0 ]
