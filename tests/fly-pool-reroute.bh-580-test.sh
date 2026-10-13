#!/bin/bash
# tests/fly-pool-reroute.bh-580-test.sh — bin/fly-pool.sh relays the reroute
# record to the pool machine (BH-584, part of #580).
#
# WHY. A pool builder has NO hub state: it runs out of a baked image against a
# tarball of bin/, so state/preplan-files/<project>-<KEY> — where the overlap
# guard just recorded "write your test cases HERE, not to the file a sibling is
# holding" — does not exist on it. Every project-5 and project-4 build is a pool
# build, so without this push the reroute would be a hub-only rule and the pool
# builder would keep appending to the shared file the guard just routed around.
#
# The function under test is the SHIPPED one: extracted verbatim from
# bin/fly-pool.sh by its marker comments and sourced (D2/D3). The extraction is
# asserted non-empty first, so a renamed marker fails loudly instead of testing
# an empty file.
#
# Run: tests/fly-pool-reroute.bh-580-test.sh   (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

awk '/^# >>> reroute relay/{f=1} /^# <<< reroute relay/{f=0} f' "$DIR/bin/fly-pool.sh" > "$T/blk.sh"
[ -s "$T/blk.sh" ] && ok || bad "could not extract the '# >>> reroute relay' block from bin/fly-pool.sh — markers missing?"
grep -q 'push_reroute()' "$T/blk.sh" && ok || bad "the extracted block must define push_reroute"

mkdir -p "$T/h/state/preplan-files"
REC="$T/h/state/preplan-files/proj-AB-1"

# push_reroute as the pool runs it: real lib, stubbed console transport.
# MPUT_RC drives the transport failure without a Fly machine anywhere.
call() { # call [nolib]
  : > "$T/mput.log"; : > "$T/say.log"
  (
    set +u
    HARNESS="$T/h"; P=proj
    [ "${1:-}" = nolib ] || . "$DIR/bin/lib/test-home-lib.sh"
    mput() { printf '%s|%s|%s\n' "$1" "$2" "$3" >> "$T/mput.log"; return "${MPUT_RC:-0}"; }
    say() { printf '%s\n' "$*" >> "$T/say.log"; }
    . "$T/blk.sh"
    push_reroute m1 AB-1
  )
  RC=$?
}

# 1. A record on the hub rides to the machine, exactly once, at the relay path
printf 'REROUTE tests: R/tests/level2-unit/foo.test.ts -> R/tests/level2-unit/foo.ab-1.test.ts\n' > "$REC"
call
[ "$RC" = 0 ] && ok || bad "1: the relay must never be fatal (rc $RC)"
[ "$(wc -l < "$T/mput.log")" = 1 ] && ok || bad "1: exactly one push, got: $(cat "$T/mput.log")"
grep -q '|/run/harness/test-reroute-proj-AB-1$' "$T/mput.log" && ok \
  || bad "1: the record must land at the contract's relay path (got: $(cat "$T/mput.log"))"
grep -q "|$REC|" "$T/mput.log" && ok || bad "1: the file pushed must be the hub record (got: $(cat "$T/mput.log"))"
grep -q 'relayed test reroute for AB-1' "$T/say.log" && ok || bad "1: a successful relay must be logged"

# 2. No record — the overwhelmingly common case — pushes nothing and says nothing
rm -f "$REC"
call
[ "$RC" = 0 ] && ok || bad "2: an absent record must be rc 0 (rc $RC)"
[ ! -s "$T/mput.log" ] && ok || bad "2: an absent record must push NOTHING (got: $(cat "$T/mput.log"))"
[ ! -s "$T/say.log" ] && ok || bad "2: an absent record must not write a log line"

# 2b. An empty record is the same as no record
: > "$REC"
call
[ "$RC" = 0 ] && ok || bad "2b: an empty record must be rc 0 (rc $RC)"
[ ! -s "$T/mput.log" ] && ok || bad "2b: an empty record must push nothing"

# 3. A failing transport is a cost of one plan stage, never a dead pool tick
printf 'REROUTE tests: a -> b\n' > "$REC"
MPUT_RC=1 call
[ "$RC" = 0 ] && ok || bad "3: a failed push must still return 0 (rc $RC)"
[ "$(wc -l < "$T/mput.log")" = 1 ] && ok || bad "3: it must have tried once"
grep -q 'failed' "$T/say.log" && ok || bad "3: a failed relay must say so (got: $(cat "$T/say.log"))"

# 4. A box whose bin/ predates the contract lib: no lib, no relay, no error
call nolib
[ "$RC" = 0 ] && ok || bad "4: without the contract lib the relay must be a no-op, rc 0 (rc $RC)"
[ ! -s "$T/mput.log" ] && ok || bad "4: without the contract lib nothing may be pushed"

# 5. Both push_preplan call sites (spawn and reuse) got a push_reroute beside
#    them, and a reused machine has the previous job's relay file cleared.
[ "$(grep -c 'push_reroute "$MID"' "$DIR/bin/fly-pool.sh")" = 2 ] && ok \
  || bad "5: both the SPAWN and the REUSE path must relay the record (a reused machine gets new work too)"
grep -q 'rm -f /run/harness/test-reroute-\*' "$DIR/bin/fly-pool.sh" && ok \
  || bad "5: a reused machine must have the previous job's relayed record cleared"
grep -q 'rm -rf /run/harness/preplan' "$DIR/bin/fly-pool.sh" && ok \
  || bad "5: the pre-plan cleanup it rides with must survive"

echo "fly-pool-reroute.bh-580: $PASS pass, $FAIL fail"
[ "$FAIL" = 0 ]
