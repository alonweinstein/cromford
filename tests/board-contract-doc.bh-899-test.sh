#!/bin/bash
# tests/board-contract-doc.bh-899-test.sh — BH-899 (BH-815.0): the board
# contract document states the dependency primitive an app has to serve.
#
# docs/BOARD-API-CONTRACT.md is what a client app's engineer builds against.
# The harness cannot feature-detect a rule nobody wrote down, so the four
# fields, the `null`-never-`""` rule, the `[]`-vs-absent rule and the
# boolean-only rule are part of the deliverable, not decoration.
#
# THIS SUITE IS PRESENCE-ONLY ON PURPOSE (D3). It proves the document says the
# thing; what the CODE does is pinned by tests/triage-gate-fingerprint-deps.bh-899-test.sh,
# which drives the real bin/triage-gate.sh. An absent or unreadable document is
# a FAIL here, never a skip — a grep over a missing file passes silently, and a
# silently passing doc test is how a contract goes stale unnoticed.
#
# Run from anywhere: tests/board-contract-doc.bh-899-test.sh   (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1

DIR=$(cd "$(dirname "$0")/.." && pwd)
DOC="$DIR/docs/BOARD-API-CONTRACT.md"

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

if [ ! -r "$DOC" ]; then
  echo "FAIL: docs/BOARD-API-CONTRACT.md is missing or unreadable at $DOC"
  echo "board-contract-doc: 0 passed, 1 failed"
  exit 1
fi

has() { # has <fixed-string> <what it is>
  if grep -qF -- "$1" "$DOC"; then ok; else bad "$2 — docs/BOARD-API-CONTRACT.md does not mention: $1"; fi
}

# 1. the four ticket fields and the board capability flag are named.
has 'parentId'     'the parent pointer'
has 'dependsOn'    'the blocker list'
has 'children'     'the slice list'
has 'blocked'      'the derived blocked boolean'
has 'capabilities' 'the optional board capabilities list'

# 2. the fields get their own section, not a sentence in passing.
if grep -qE '^### Dependencies$' "$DOC"; then ok; else
  bad 'no "### Dependencies" section heading in docs/BOARD-API-CONTRACT.md'
fi

# 3. the two rules that bite an implementer live INSIDE that section. Slicing
#    to the next heading is what keeps this honest: the same words elsewhere in
#    a 400-line document would not tell an app author what to serve here.
START=$(grep -nE '^### Dependencies$' "$DOC" | head -1 | cut -d: -f1)
END=$(grep -nE '^### Buildability' "$DOC" | head -1 | cut -d: -f1)
if [ -n "$START" ] && [ -n "$END" ] && [ "$END" -gt "$START" ]; then
  SLICE=$(sed -n "${START},${END}p" "$DOC")
  ok
else
  SLICE=""
  bad "could not slice ### Dependencies (line ${START:-none}) to ### Buildability (line ${END:-none})"
fi

if grep -qF -- 'never `""`' <<<"$SLICE"; then ok; else
  bad 'the Dependencies section does not carry the `null`, never `""` rule'
fi
if grep -qE 'omits all four|absence is the signal' <<<"$SLICE"; then ok; else
  bad 'the Dependencies section does not say that a board without the primitive omits the fields (absence is the signal)'
fi

# 4. ORDERING. `blocked` is the block that clears itself, so it is checked
#    before the turn and the verdict — and the buildability table must read in
#    that order, because the table is the order an implementer infers.
BLINE=$(grep -nE '^\| *`blocked` = `true`' "$DOC" | head -1 | cut -d: -f1)
WLINE=$(grep -nE '^\| *`waitingOn` = `client`' "$DOC" | head -1 | cut -d: -f1)
if [ -z "$BLINE" ]; then
  bad 'the buildability table has no `blocked` = `true` row'
elif [ -z "$WLINE" ]; then
  bad 'the buildability table has no `waitingOn` = `client` row to order against'
elif [ "$BLINE" -lt "$WLINE" ]; then
  ok
else
  bad "the \`blocked\` row (line $BLINE) must come BEFORE the \`waitingOn\` row (line $WLINE) in the buildability table"
fi

echo "board-contract-doc: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
