#!/bin/bash
# triage-contract.sh — print the system append every triage tick ships.
#
# ONE source for the BUILD DEDUPE + DECISION LOG contract (the BUILD LOCK rule it
# used to carry was deleted 2026-09-13: locks are dedupe, never a queue). It used
# to live as two
# hand-copied string literals, in bin/run-triage.sh (what the fleet actually
# runs) and bin/prompt-eval.sh (what the weekly eval grades), the second
# carrying a comment claiming it was "verbatim from run-triage.sh L216-217" —
# a line number that had long since moved. Two copies of one rule is this
# repo's named failure shape, and here it is the specific one that costs money:
# the eval exists to catch the live SOP drifting, so an eval grading a DIFFERENT
# contract than the fleet ships reports drift that is really its own staleness,
# and every such report is an alert nobody can act on. (2026-08-31: the
# project-2 `close` vs `comment|status` page, six sessions deep.)
#
# LOUD on failure, never empty. An empty append silently drops the DECISION LOG
# request, so the model stops emitting DECISION lines, bin/decision-log.sh
# harvests nothing, and logs/decisions.log just goes quiet — a dead routing log
# that looks exactly like a calm day.
set -uo pipefail
SELF=$(cd "$(dirname "$0")" && pwd)
HARNESS="${HARNESS:-/root/harness}"
for f in "$HARNESS/catalog/agent-contracts/triage-system-append.txt" \
         "/root/harness-checkout/catalog/agent-contracts/triage-system-append.txt" \
         "$SELF/../catalog/agent-contracts/triage-system-append.txt"; do
  if [ -s "$f" ]; then cat "$f"; exit 0; fi
done
echo "triage-contract.sh: catalog/agent-contracts/triage-system-append.txt not found or empty" >&2
exit 1
