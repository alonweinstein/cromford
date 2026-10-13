#!/bin/bash
# tests/fly-lock-guard-test.sh — the guard kills ONLY a `flyctl agent run`
# daemon that holds a fly lock fd; an agent without a lock and a non-agent
# lock holder both survive. exit 0 = all pass
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
. "$(dirname "$0")/lib/wait-for.sh" || exit 1  # BH-6049: wait for the renamed processes, not a fixed sleep
DIR=$(cd "$(dirname "$0")/.." && pwd)
mkdir -p "$T/locks"
PIDS=""
trap 'kill $PIDS 2>/dev/null; scratch_cleanup' EXIT
PASS=0; FAIL=0; ok() { PASS=$((PASS+1)); }; bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

( exec -a "flyctl agent run /tmp/agent.log" sleep 300 ) 8>"$T/locks/fly-pool-p.lock" & A=$!
( exec -a "flyctl agent run /tmp/agent2.log" sleep 300 ) & B=$!
( exec -a "not-an-agent" sleep 300 ) 8>"$T/locks/fly-dispatch.lock" & C=$!
PIDS="$A $B $C"
# The guard matches /proc/<pid>/cmdline, which reads the subshell's own command
# line until `exec -a` has run. Wait until all three carry their new names.
named() { local c; [ -r "/proc/$1/cmdline" ] || return 0; c=$(tr '\0' ' ' < "/proc/$1/cmdline"); [[ $c == *"$2"* ]]; }
renamed() { named "$A" "flyctl agent run" && named "$B" "flyctl agent run" && named "$C" "not-an-agent"; }
wait_for 10 renamed

OUT=$(FLY_LOCK_GUARD_LOG="$T/log" "$DIR/bin/fly-lock-guard.sh" "$T/locks")
[ "$OUT" = 1 ] && ok || bad "exactly one kill reported (got '$OUT')"
gone() { ! kill -0 "$1" 2>/dev/null; }
wait_for 10 gone "$A"
kill -0 "$A" 2>/dev/null && bad "agent holding the lock still alive" || ok
kill -0 "$B" 2>/dev/null && ok || bad "agent WITHOUT a lock was killed"
kill -0 "$C" 2>/dev/null && ok || bad "non-agent lock holder was killed"
grep -q "fly-pool-p.lock" "$T/log" 2>/dev/null && ok || bad "log line names the lock"
( exec 8>"$T/locks/fly-pool-p.lock"; flock -n 8 ) && ok || bad "lock is free after the kill"

echo "fly-lock-guard: $PASS pass, $FAIL fail"; [ "$FAIL" = 0 ]
