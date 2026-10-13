#!/bin/bash
# tests/load-project-events.bh-4058-test.sh — the doorbell arming command that
# bin/load-project.sh prints for an unarmed repo subscribes to EXACTLY the
# canonical event list (bin/webhook-rearm.sh --print-events), which since
# BH-4058 includes status, workflow_run and merge_group.
#
# Runs the REAL `# >>> doorbell banner` … `# <<< doorbell banner` block out of
# bin/load-project.sh in a scratch dir, with a stub doorbell-coverage-check.sh.
#   L1  banner events[] set == bin/webhook-rearm.sh --print-events
#   L2  the stub answering 0 (armed) prints no banner
#   L3  each marker exists exactly once and the extracted block is non-empty
#
# Run from anywhere: HARNESS_TEST_SANDBOX=1 bash tests/load-project-events.bh-4058-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

LP="$DIR/bin/load-project.sh"
# L3 — the markers, once each, around a block that is not empty.
nb=$(grep -c '^# >>> doorbell banner' "$LP"); ne=$(grep -c '^# <<< doorbell banner' "$LP")
sed -n '/^# >>> doorbell banner/,/^# <<< doorbell banner/p' "$LP" > "$T/block.sh"
if [ "$nb" = 1 ] && [ "$ne" = 1 ] && grep -q 'events\[\]=' "$T/block.sh"; then ok
else bad "L3 markers begin=$nb end=$ne, block has $(wc -l < "$T/block.sh") lines"; fi

mkdir -p "$T/run/bin"
banner() { # banner <stub rc> — run the real block, print what it prints
  printf '#!/bin/bash\nexit %s\n' "$1" > "$T/run/bin/doorbell-coverage-check.sh"
  chmod +x "$T/run/bin/doorbell-coverage-check.sh"
  (cd "$T/run" && SLUG=example-org/x bash "$T/block.sh")
}

# L1 — the printed events[] set is the canonical list, nothing more or less.
want=$("$DIR/bin/webhook-rearm.sh" --print-events | sort)
got=$(banner 1 | grep -o "events\[\]=[a-z_]*" | sed 's/^events\[\]=//' | sort)
if [ -n "$want" ] && [ "$got" = "$want" ]; then ok
else bad "L1 banner events differ from --print-events: $(diff <(echo "$want") <(echo "$got") | tr '\n' ' ')"; fi
for e in status workflow_run merge_group; do
  if grep -qx "$e" <<<"$got"; then ok; else bad "L1 banner lacks $e"; fi
done

# L2 — an armed repo gets no banner.
out=$(banner 0)
if ! grep -q 'DOORBELL NOT ARMED' <<<"$out"; then ok; else bad "L2 armed repo printed the banner"; fi

echo "load-project-events (BH-4058): $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
