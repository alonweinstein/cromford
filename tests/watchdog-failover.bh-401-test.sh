#!/bin/bash
# tests/watchdog-failover.bh-401-test.sh — runs the watchdog worker's node suite
# from the tests/*.sh loop (BH-401 contract, issue #1920). Exit code is node's.
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
cd "$(dirname "$0")/../worker/watchdog" || exit 1
node --test test/*.test.js
