#!/bin/bash
. "$(dirname "$0")/../lib/retry.sh" || exit 1
fails=0
calls=0
always_fails() { calls=$((calls + 1)); return 1; }
works_second_time() { calls=$((calls + 1)); [ "$calls" -ge 2 ]; }

calls=0; with_retry always_fails
[ "$calls" -eq 5 ] || { echo "FAIL: expected 5 attempts, got $calls"; fails=$((fails+1)); }

calls=0; with_retry works_second_time || { echo "FAIL: expected success"; fails=$((fails+1)); }
[ "$calls" -eq 2 ] || { echo "FAIL: expected 2 attempts, got $calls"; fails=$((fails+1)); }

[ "$fails" -eq 0 ] && echo "retry: all passed"
[ "$fails" -eq 0 ]
