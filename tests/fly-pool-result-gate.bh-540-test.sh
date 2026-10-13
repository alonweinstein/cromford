#!/bin/bash
# The pool-rebase RESULT words (BH-486, bin/lib/rebase-job.sh) must pass the
# reap gate, and the mexec-panic rule must survive them: a leading space is
# still a miss, and a flyctl line that merely CONTAINS one of the words is not
# a RESULT. Companion to tests/fly-pool-result-gate-test.sh, which keeps the
# pre-rebase vocabulary.
. "$(dirname "$0")/lib/scratch.sh" || exit 1
V="$(cd "$(dirname "$0")/.." && pwd)/bin/result-prefix-ok.sh"
P=0; F=0
ok(){ if "$V" "$1"; then P=$((P+1)); else F=$((F+1)); echo "FAIL (should be RESULT): $1"; fi; }
no(){ if "$V" "$1"; then F=$((F+1)); echo "FAIL (should be MISS): $1"; else P=$((P+1)); fi; }
ok "REBASED abc"
ok "CONFLICT a.txt"
ok "GATE_RED unit"
ok "REBASE_SETUP_FAILED x"
no "  REBASED abc"
no "Oops, something went wrong! REBASED"
echo "pass=$P fail=$F"; [ "$F" = 0 ]
