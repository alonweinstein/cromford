#!/bin/bash
# Hidden retry spec. spec.sh <tree> sources <tree>/lib/retry.sh and counts attempts.
. "$1/lib/retry.sh" || exit 1
fails=0
calls=0
always_fails() { calls=$((calls + 1)); return 1; }
works_second_time() { calls=$((calls + 1)); [ "$calls" -ge 2 ]; }
calls=0; with_retry always_fails && { echo "spec: an always-failing command reported success"; fails=$((fails+1)); }
[ "$calls" -eq 3 ] || { echo "spec: want exactly 3 attempts, got $calls"; fails=$((fails+1)); }
calls=0; with_retry works_second_time || { echo "spec: a second-try success reported failure"; fails=$((fails+1)); }
[ "$calls" -eq 2 ] || { echo "spec: want 2 attempts, got $calls"; fails=$((fails+1)); }
[ "$fails" -eq 0 ]
