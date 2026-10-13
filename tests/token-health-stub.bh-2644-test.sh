#!/bin/bash
# tests/token-health-stub.bh-2644-test.sh — BH-2644 (BH-2516.0): the reporter
# seam every token-health sibling imports. Sources the REAL
# bin/lib/token-health.sh and pins the contract a caller in gh-token.sh (whose
# stdout IS the token) relies on:
#
#   S1  sourcing the lib prints nothing
#   S2  token_health_report oauth x ok      -> rc 0, empty stdout
#   S3  under set -euo pipefail, a fail report with expiry and error -> rc 0,
#       empty stdout, and the caller keeps running
#   S4  token_health_report is defined as a function after sourcing
#
# Run from anywhere: bash tests/token-health-stub.bh-2644-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
LIB="$DIR/bin/lib/token-health.sh"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

# ---------- S1 ---------------------------------------------------------------
src_out=$(bash -c '. "$1"' _ "$LIB" 2>/dev/null); src_rc=$?
if [ "$src_rc" = 0 ] && [ -z "$src_out" ]; then ok; else bad "S1 sourcing: rc=$src_rc stdout='$src_out'"; fi

. "$(dirname "$0")/../bin/lib/token-health.sh" || exit 1

# BH-2646: the reporter now POSTs. S2/S3 pin the fail-open contract, not the
# send (tests/token-health.bh-2646-test.sh drives that against a stub worker),
# so both run with reporting off: without it S2 would load the real client,
# which reads /root/harness/env/global.env and would post a fake row to the
# live worker.
export TOKEN_HEALTH_REPORT=0 JOBS_URL=

# ---------- S2 ---------------------------------------------------------------
rc=0; out=$(token_health_report oauth x ok) || rc=$?
if [ "$rc" = 0 ] && [ -z "$out" ]; then ok; else bad "S2 oauth ok: rc=$rc stdout='$out'"; fi

# ---------- S3 ---------------------------------------------------------------
rc=0
out=$(bash -c 'set -euo pipefail; . "$1"; token_health_report gh_app app-1 fail 2026-01-01T00:00:00Z "boom"; echo -n AFTER >&2' _ "$LIB" 2>"$T/th-s3.err") || rc=$?
err=$(cat "$T/th-s3.err")
if [ "$rc" = 0 ] && [ -z "$out" ] && [ "$err" = AFTER ]; then ok; else bad "S3 set -e fail report: rc=$rc stdout='$out' stderr='$err'"; fi

# ---------- S4 ---------------------------------------------------------------
if declare -F token_health_report >/dev/null; then ok; else bad "S4 token_health_report not defined"; fi

echo "token-health-stub: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
