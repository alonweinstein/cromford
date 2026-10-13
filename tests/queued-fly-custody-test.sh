#!/bin/bash
# tests/queued-fly-custody-test.sh — watcher QUEUED_FLY stubs stop looking like
# owed board close-outs only after a newer exact-key pool result is RELAYED.
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1

DIR=$(cd "$(dirname "$0")/.." && pwd)
mkdir -p "$T/bin/remediations" "$T/builds" "$T/flags"
cp "$DIR/bin/queued-fly-relayed.sh" "$T/bin/"
cp "$DIR/bin/remediations/health-uncommented.sh" "$T/bin/remediations/"

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
probe() { HARNESS="$T" bash "$T/bin/queued-fly-relayed.sh" x-os "$1" >/dev/null 2>&1; }
handler() { HARNESS="$T" bash "$T/bin/remediations/health-uncommented.sh" health:uncommented:x-os:1 >/dev/null 2>&1; }

STUB="$T/builds/x-os-X-9-202608260100"
mkdir -p "$STUB"
printf 'QUEUED_FLY X-9\n' > "$STUB/RESULT"
printf '{"project":"x-os","key":"X-9"}\n' > "$STUB/job.json"
touch -d '3 hours ago' "$STUB/RESULT" "$STUB/job.json"

if probe "$STUB"; then bad "a queued stub with no successor was treated as relayed"; else ok; fi
RC=$(handler; echo $?)
[ "$RC" -ne 0 ] && [ "$RC" -ne 10 ] && ok || bad "an unclaimed queued stub must still page (rc=$RC)"

# Prefix collisions and older builds do not prove custody for X-9.
mkdir -p "$T/builds/pool-x-os-X-97-202608260200" "$T/builds/pool-x-os-X-9-202608250100"
touch "$T/builds/pool-x-os-X-97-202608260200/RESULT" "$T/builds/pool-x-os-X-97-202608260200/RELAYED"
touch -d '4 hours ago' "$T/builds/pool-x-os-X-9-202608250100/RESULT" "$T/builds/pool-x-os-X-9-202608250100/RELAYED"
if probe "$STUB"; then bad "a prefix collision or older relay discharged the stub"; else ok; fi

# The exact successor, relayed after the queue result, transfers custody.
SUCCESSOR="$T/builds/pool-x-os-X-9-202608260200"
mkdir -p "$SUCCESSOR"
touch "$SUCCESSOR/RELAYED"
if probe "$STUB"; then bad "a relay marker without a successor RESULT discharged the stub"; else ok; fi
touch "$SUCCESSOR/RESULT"
probe "$STUB" && ok || bad "a newer exact-key relayed successor was not recognized"
RC=$(handler; echo $?)
[ "$RC" -eq 10 ] && ok || bad "the remediation handler did not classify a relayed queue stub as terminal (rc=$RC)"

# Identity disagreement is ambiguous and must fail open.
printf 'QUEUED_FLY X-10\n' > "$STUB/RESULT"
touch -d '3 hours ago' "$STUB/RESULT"
if probe "$STUB"; then bad "RESULT/job identity mismatch was treated as relayed"; else ok; fi

grep -q 'queued-fly-relayed.sh.*&& continue' "$DIR/bin/pipeline-health.sh" \
  && ok || bad "pipeline-health is not wired to exclude proven relayed stubs"

echo "queued-fly-custody-test: $PASS pass, $FAIL fail"
[ "$FAIL" -eq 0 ]
