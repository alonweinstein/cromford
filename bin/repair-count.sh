#!/bin/bash
# bin/repair-count.sh — how many times ONE build had to be sent back.
#
# usage: repair-count.sh <build-dir>
# prints: "<n>\t<comma-list>"   (list is "-" when n is 0)
#
# WHY (SDLC item 3, 2026-09-06). A build that sailed through every lens and a
# build that needed two fix rounds settled at the SAME tier and merged the same
# way. The repair count is the cheapest risk signal the pipeline already has on
# disk and never read: 56 BLOCKed builds were mined into the D1-D34 discipline
# rules, and none of that history could be joined to "did this one need fixing".
#
# WHAT COUNTS AS A REPAIR — six facts, each one a file or a recorded exit code:
#   review2-run.txt           the general lens sent it back
#   security-review2-run.txt  the security lens sent it back
#   refute-review2-run.txt    the refuter sent it back
#   qa2-run.txt               preview QA sent it back
#   gates.json tamper == 2    tests were deleted and the diff justified it
#   gates.json repro  == 4    the new tests were red on the head they arrived on
# The four run files are the RE-REVIEW of a fix round, so each one means code
# changed after somebody objected. The two gate codes are not fix rounds; they
# are the two "recorded, not blocked" verdicts the mechanical gates can reach —
# the soft spots documented as F7 and the TEST-CHANGE: escape hatch — and a
# build that used one of them has spent a piece of its own evidence.
#
# PRESENCE, NOT SIZE. A re-review session that produced an empty file still
# means the code went back for repair; a risk signal that a died session can
# soften is a risk signal pointing the wrong way. (bin/evidence-summary.sh's
# "fix rounds" row counts fix-run.txt by size and answers a different question:
# which lenses wrote a fix. The two numbers legitimately differ, and neither is
# derived from the other.)
#
# ONE IMPLEMENTATION, THREE READERS: bin/run-build.sh (the tier demoter and the
# verdict row), bin/findings-log.sh (the repairs= field on every finding) and
# any operator re-running it against an archived record. Two copies of this rule
# would make "REPAIRS >= 2" mean two different things at once, which is this
# repo's named failure shape.
#
# NO NETWORK, NO REPO ACCESS, NO MODEL CALL — build-dir files only, so an
# archived record months later returns the same count. Fail-open on every
# branch: a missing dir prints "0" and exits 0, because a counter that can stop
# a build is worse than a counter that can be absent.
set -uo pipefail
BUILD="${1:-}"
N=0; LIST=""
add() { N=$((N + 1)); LIST="$LIST${LIST:+,}$1"; }

if [ -n "$BUILD" ] && [ -d "$BUILD" ]; then
  for PAIR in review:review2-run.txt security:security-review2-run.txt \
              refute:refute-review2-run.txt qa:qa2-run.txt; do
    [ -f "$BUILD/${PAIR#*:}" ] && add "${PAIR%%:*}"
  done
  # The gate codes come from gates.json — the same file bin/evidence-summary.sh
  # reads — rather than from re-parsing the gate reports, so the rc a build is
  # scored on is the rc the pipeline recorded for it.
  if [ -s "$BUILD/gates.json" ] && command -v jq >/dev/null 2>&1; then
    GT=$(jq -r '.tamper // "" | tostring' "$BUILD/gates.json" 2>/dev/null)
    GR=$(jq -r '.repro  // "" | tostring' "$BUILD/gates.json" 2>/dev/null)
    [ "$GT" = 2 ] && add tamper-justified
    [ "$GR" = 4 ] && add repro-head-red
  fi
fi
printf '%s\t%s\n' "$N" "${LIST:--}"
exit 0
