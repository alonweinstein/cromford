#!/bin/bash
# tests/fly-pool-relay-builddir-test.sh — the pool relay reads the BUILD'S OWN
# directory, never the first one on a reused machine.
#
# THE DEFECT (project-5 TK-493 / #520, 2026-09-13): bin/fly-pool.sh chose the
# remote build dir with `ls -d /data/harness/builds/* | head -1`. A reused pool
# machine holds every build it has run, so the alphabetically-first one won —
# #520's hub record carried TK-291's review.md and pipeline.log, the ledger said
# APPROVE, the record said BLOCK, and the sweep parked it for a human.
# Run from anywhere: tests/fly-pool-relay-builddir-test.sh   (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

# The RB derivation, lifted verbatim from the shipped script (the comment block
# above it and the relay comment below it are the anchors).
awk '/THE BUILD.S OWN DIRECTORY, NEVER THE FIRST ONE ON DISK/{f=1} /THE RELAY IS THE MERGE GATE.S EYES/{exit} f' \
  "$DIR/bin/fly-pool.sh" | grep -v '^ *#' > "$T/rb.sh"
[ -s "$T/rb.sh" ] && ok || bad "could not extract the RB block from bin/fly-pool.sh — anchors missing?"
grep -q 'ls -d /data/harness/builds/\* 2>/dev/null | head -1' "$DIR/bin/fly-pool.sh" \
  && bad "the alphabetical first-dir listing is still the relay's source" || ok

# a fake mexec that records what it was asked and answers a two-build machine
mexec() { # the remote command carries its own `| head -1`; honour it the way a shell would
  echo "$2" >> "$T/mexec.txt"
  printf '/data/harness/builds/project-5-TK-493-202609122300\n/data/harness/builds/project-5-TK-291-202609121900\n' | { case "$2" in *"head -1"*) head -1 ;; *) cat ;; esac; }; }
run_rb() { # run_rb <RESULT text>
  : > "$T/mexec.txt"
  ( RES="$1"; MID=m1; . "$T/rb.sh"; printf '%s' "$RB" )
}

# 1. RESULT names its BUILD_DIR -> that directory, no listing at all
RB=$(run_rb $'PR_CREATED https://github.com/example-org/project-5/pull/520\nTIER: 2\nBUILD_DIR: project-5-TK-493-202609122300\nWARM: warm')
[ "$RB" = "/data/harness/builds/project-5-TK-493-202609122300" ] && ok || bad "RB must be the RESULT's BUILD_DIR (got '$RB')"
[ ! -s "$T/mexec.txt" ] && ok || bad "a RESULT that names its BUILD_DIR must not list the machine"

# 2. an absolute BUILD_DIR still maps under the machine's builds root
RB=$(run_rb $'RESULT_OK\nBUILD_DIR: /root/harness/builds/project-5-TK-493-202609122300')
[ "$RB" = "/data/harness/builds/project-5-TK-493-202609122300" ] && ok || bad "an absolute BUILD_DIR must be re-rooted under /data/harness/builds (got '$RB')"

# 3. a RESULT predating BUILD_DIR falls back to the NEWEST dir, and lists by mtime
RB=$(run_rb $'PR_CREATED https://github.com/example-org/project-5/pull/1\nTIER: 2')
[ "$RB" = "/data/harness/builds/project-5-TK-493-202609122300" ] && ok || bad "without BUILD_DIR the fallback must take the first (newest) listing entry (got '$RB')"
grep -q 'ls -dt' "$T/mexec.txt" && ok || bad "the fallback listing must be newest-first (ls -dt), not alphabetical"

echo "fly-pool-relay-builddir: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
