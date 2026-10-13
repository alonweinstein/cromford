#!/bin/bash
# tests/watchdog-unknown-box.bh-1957-test.sh — runs the watchdog worker's node
# unit test (worker/watchdog/test/unknown-box.bh-1957.test.js) from the shell
# loop, because CI's JS job only runs worker/jobs. A ping from a box the config
# does not know must alert; known boxes must behave as before.
# Run from anywhere: tests/watchdog-unknown-box.bh-1957-test.sh   (exit 0 = pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
command -v node >/dev/null || { echo "node missing — skipping"; exit 0; }

( cd "$DIR/worker/watchdog" && node --test --test-reporter=tap test/unknown-box.bh-1957.test.js ) > "$T/out.txt" 2>&1
RC=$?
PASSN=$(sed -n 's/^# pass \([0-9]*\)$/\1/p' "$T/out.txt" | tail -1)
if [ "$RC" -ne 0 ]; then
  cat "$T/out.txt"
  echo "watchdog-unknown-box.bh-1957-test: FAIL (node rc=$RC)"; exit 1
fi
if [ "${PASSN:-0}" -eq 0 ]; then
  cat "$T/out.txt"
  echo "watchdog-unknown-box.bh-1957-test: FAIL (the reporter shows 0 passing tests)"; exit 1
fi
echo "watchdog-unknown-box.bh-1957-test: $PASSN pass, 0 fail"
