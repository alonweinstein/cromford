#!/bin/bash
# tests/watchdog-progress.k2-test.sh — runs the watchdog worker's node
# unit test (worker/watchdog/test/progress.k2.test.js) from the shell
# loop, because CI's JS job only runs worker/jobs. K2: the outside dead-man's
# progress rules (spend without progress, silent stop, watch the watchers), their
# dedupe/repage/resolve paging, and the /api/progress + /api/stamp routes.
# Run from anywhere: tests/watchdog-progress.k2-test.sh   (exit 0 = pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
# A missing node is a FAIL, not a skip (#2289 review): these are the only tests
# of the outside dead-man's paging, and a green that ran nothing hides that.
command -v node >/dev/null || { echo "watchdog-progress.k2-test: FAIL (node missing — the paging rules were not tested)"; exit 1; }

( cd "$DIR/worker/watchdog" && node --test --test-reporter=tap test/progress.k2.test.js ) > "$T/out.txt" 2>&1
RC=$?
PASSN=$(sed -n 's/^# pass \([0-9]*\)$/\1/p' "$T/out.txt" | tail -1)
if [ "$RC" -ne 0 ]; then
  cat "$T/out.txt"
  echo "watchdog-progress.k2-test: FAIL (node rc=$RC)"; exit 1
fi
if [ "${PASSN:-0}" -eq 0 ]; then
  cat "$T/out.txt"
  echo "watchdog-progress.k2-test: FAIL (the reporter shows 0 passing tests)"; exit 1
fi
echo "watchdog-progress.k2-test: $PASSN pass, 0 fail"
