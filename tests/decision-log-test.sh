#!/bin/bash
# tests/decision-log-test.sh — self-contained assertions for bin/decision-log.sh.
# Run from anywhere: tests/decision-log-test.sh   (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
export HARNESS="$T"
mkdir -p "$T/logs"
PASS=0; FAIL=0
ok()   { PASS=$((PASS+1)); }
bad()  { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
DLOG="$T/logs/decisions.log"

# 1. extraction: DECISION lines land stamped with project/gate/scope annotations
cat > "$T/out1.txt" <<'EOF'
Worked the queue this tick.
DECISION: TK-12 :: launch :: client confirmed mechanism in latest comment
DECISION: TK-40 :: skip :: waitingOn=client, triage questions unanswered
tickets=2 handled
EOF
"$DIR/bin/decision-log.sh" p1 board-changed full "$T/out1.txt" || bad "rc nonzero on happy path"
grep -q '\[p1\] gate=board-changed scope=full TK-12 :: launch :: client confirmed mechanism' "$DLOG" \
  && grep -q 'TK-40 :: skip :: waitingOn=client' "$DLOG" \
  && ok || bad "extraction (got: $(cat "$DLOG" 2>/dev/null))"

# 2. no DECISION lines -> no-op, still rc=0, file untouched
BEFORE=$(wc -l < "$DLOG")
echo "just a summary, no decisions block" > "$T/out2.txt"
"$DIR/bin/decision-log.sh" p1 queue-pending queue "$T/out2.txt" || bad "rc nonzero on empty"
[ "$(wc -l < "$DLOG")" = "$BEFORE" ] && ok || bad "no-op appended lines"

# 3. cap: 50 DECISION lines -> only 40 recorded
: > "$T/out3.txt"
for i in $(seq 1 50); do echo "DECISION: T-$i :: comment :: reason $i" >> "$T/out3.txt"; done
"$DIR/bin/decision-log.sh" p2 daily-sweep full "$T/out3.txt"
N=$(grep -c '\[p2\]' "$DLOG")
[ "$N" = 40 ] && ok || bad "cap (got $N lines, want 40)"

# 4. long line truncated to ~300 chars of payload
LONG=$(printf 'x%.0s' $(seq 1 500))
echo "DECISION: T-99 :: launch :: $LONG" > "$T/out4.txt"
"$DIR/bin/decision-log.sh" p3 forced full "$T/out4.txt"
LEN=$(grep '\[p3\]' "$DLOG" | head -1 | wc -c)
[ "$LEN" -lt 420 ] && ok || bad "truncation (line length $LEN)"

# 5. missing outfile -> rc=0, nothing appended (fail-open: never break the triage tick)
BEFORE=$(wc -l < "$DLOG")
"$DIR/bin/decision-log.sh" p4 forced full "$T/nonexistent.txt" || bad "rc nonzero on missing file"
[ "$(wc -l < "$DLOG")" = "$BEFORE" ] && ok || bad "missing-file wrote lines"

echo "decision-log-test: $PASS pass, $FAIL fail"
[ "$FAIL" = 0 ]
