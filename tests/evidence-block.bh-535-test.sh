#!/bin/bash
# tests/evidence-block.bh-535-test.sh — BH-535: the evidence block shows the QA
# flows each persona drove, and what came of them.
#
# WHY THIS FILE AND NOT AN APPEND. Test cases are per-ticket in this repo
# (bin/lib/test-home-lib.sh); tests/evidence-block-test.sh is shared and a
# sibling build is holding it.
#
# WHAT IS UNDER TEST. bin/evidence-summary.sh renders the block the operator merges
# tier-2 PRs from. A persona lane that drove three flows and blocked a fourth
# has to be readable THERE — with the screenshot path, and with which lane
# produced each row, because the preview lane and the production lane write
# rows of the same shape into different files. The renderer stays deterministic:
# no eval, no sourcing, a `|` inside an agent-authored reason may not split a
# markdown row, and the Digest line stays byte-identical to what the ledger and
# the existing suite pin.
#
# Run from anywhere: tests/evidence-block.bh-535-test.sh   (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

EV="$DIR/bin/evidence-summary.sh"
[ -x "$EV" ] && ok || bad "bin/evidence-summary.sh is missing or not executable"

# The same "went WELL" record the shared suite renders, so anything this file
# sees in the block is the FLOW rows' doing and nothing else's.
B="$T/rec"; mkdir -p "$B/qa-shots"
printf 'suite output\nHARNESS_EXIT: 0\n' > "$B/harness-suite.txt"
printf '{"tamper":0,"repro":0,"intent":0,"e2e":"pass","migration":"none"}\n' > "$B/gates.json"
printf 'INTENT DECLARED:\n  [agree] INTENT: src/lib/pay.ts:42 :: agree\nINTENT_VERDICT: declared\n' > "$B/intent-gate.txt"
printf 'drove it\nMAP ENTRIES: none\nQA COVERAGE: screens=2 flows=3 shots=4\nQA: PASS\n' > "$B/qa.md"
touch "$B/qa-shots/a.png" "$B/qa-shots/b.png"
printf 'FAIL: expected 3, got 0\n' > "$B/red.txt"
printf 'task one\nnpm test -- a.test.ts\nexit 0\n' > "$B/validate.txt"
printf 'src/lib/pay.ts\n' > "$B/planned-files.txt"
printf 'src/lib/pay.ts\n' > "$B/changed-files.txt"

# The record with no persona lane: the two-field coverage line, no FLOW rows.
NOFLOWS=$(printf 'ROUTE 200 / console=0 ok\nE2E COVERAGE: routes=1 failed=0\nE2E: PASS\n')

# The record a preview lane with personas leaves behind.
WITHFLOWS=$(cat <<'EOF'
ROUTE 200 / console=0 ok
Personas: 2 in scope, 1 driven (mode preview)
FLOW owner dashboard pass steps=2/2 shot=/b/e2e-flows/owner/dashboard.png
FLOW owner new-scan fail steps=3/4 shot=/b/e2e-flows/owner/new-scan.png expect timed out
FLOW admin users blocked no QA account for demo-os/qa-admin
E2E COVERAGE: routes=1 failed=0 flows=2 flows_failed=1 flows_blocked=1
E2E: FAIL
EOF
)

echo "--- the table a persona lane produces"
printf '%s\n' "$WITHFLOWS" > "$B/e2e.md"
printf 'FLOW owner dashboard pass steps=2/2 shot=-\nQA: PASS\n' > "$B/qa-prod.md"
OUT=$("$EV" "$B" 1 "")

[ "$(grep -c '^## QA flows per persona$' <<<"$OUT")" = 1 ] \
  && ok || bad "the QA flows section is missing or rendered twice: $OUT"
[ "$(grep -c '^| owner \|^| admin ' <<<"$OUT")" = 4 ] \
  && ok || bad "expected one table row per FLOW row (4), got $(grep -c '^| owner \|^| admin ' <<<"$OUT"): $OUT"
grep -qF '/b/e2e-flows/owner/dashboard.png' <<<"$OUT" \
  && ok || bad "the passing flow's screenshot path is not in the block: $OUT"
grep -qF '/b/e2e-flows/owner/new-scan.png' <<<"$OUT" \
  && ok || bad "the failing flow's screenshot path is not in the block: $OUT"
grep -q '^| owner | new-scan | fail — expect timed out |' <<<"$OUT" \
  && ok || bad "a failing flow's reason is not in its verdict cell: $OUT"
grep -q '^| admin | users | blocked — no QA account for demo-os/qa-admin | - | preview |$' <<<"$OUT" \
  && ok || bad "a blocked flow must say why, and carry '-' for the absent shot: $OUT"
grep -q '^| owner | dashboard | pass | - | production |$' <<<"$OUT" \
  && ok || bad "the production lane's row is missing or mislabelled: $OUT"
[ "$(grep -c '| preview |$' <<<"$OUT")" = 3 ] \
  && ok || bad "the three preview rows are not labelled as preview: $OUT"
# The Digest is what the ledger keys on, and it is the last thing a reader sees.
grep -q 'Digest: `suite=0 tamper=clean repro=proven intent=declared e2e=pass' <<<"$OUT" \
  && ok || bad "the digest changed shape: $(grep Digest <<<"$OUT")"
grep -q '^Digest: ' <<< "$(tail -1 <<<"$OUT")" \
  && ok || bad "the Digest line is no longer last: $(tail -3 <<<"$OUT")"
# ...and the section belongs after the rows a reviewer reads first.
TIERLN=$(grep -n '| settled tier |' <<<"$OUT" | head -1 | cut -d: -f1)
SECLN=$(grep -n '^## QA flows per persona$' <<<"$OUT" | head -1 | cut -d: -f1)
{ [ -n "$TIERLN" ] && [ -n "$SECLN" ] && [ "$SECLN" -gt "$TIERLN" ]; } \
  && ok || bad "the flows section is not below the check table (tier=$TIERLN section=$SECLN)"

echo "--- negative (a): no FLOW rows, nothing rendered, nothing changed"
printf '%s\n' "$NOFLOWS" > "$B/e2e.md"
rm -f "$B/qa-prod.md"
"$EV" "$B" 1 "" > "$T/out-noflows.txt"
rm -f "$B/e2e.md"
"$EV" "$B" 1 "" > "$T/out-noe2e.txt"
[ "$(grep -c 'QA flows per persona' "$T/out-noflows.txt")" = 0 ] \
  && ok || bad "a record with no FLOW rows rendered the section anyway"
cmp -s "$T/out-noflows.txt" "$T/out-noe2e.txt" \
  && ok || bad "an e2e.md with no FLOW rows changed the block: $(diff "$T/out-noe2e.txt" "$T/out-noflows.txt")"

echo "--- negative (b): agent text never breaks the table"
printf 'FLOW owner new-scan blocked timed out | see /x\001y for the trace\n' > "$B/e2e.md"
OUT=$("$EV" "$B" 1 "")
[ "$(grep -c '^| owner ' <<<"$OUT")" = 1 ] \
  && ok || bad "a reason containing a pipe split the markdown row: $OUT"
grep -q '^| owner | new-scan | blocked — timed out / see /xy for the trace | - | preview |$' <<<"$OUT" \
  && ok || bad "the pipe was not neutralised or the control char survived: $(grep '^| owner ' <<<"$OUT")"

echo "--- the ledger row is untouched"
rm -f "$B/e2e.md"
"$EV" --json "$B" 1 "" > "$T/json-none.txt"
printf '%s\n' "$WITHFLOWS" > "$B/e2e.md"
"$EV" --json "$B" 1 "" > "$T/json-flows.txt"
cmp -s "$T/json-none.txt" "$T/json-flows.txt" \
  && ok || bad "FLOW rows leaked into the --json ledger row: $(diff "$T/json-none.txt" "$T/json-flows.txt")"

echo "evidence-block.bh-535: $PASS pass, $FAIL fail"
[ "$FAIL" -eq 0 ]
