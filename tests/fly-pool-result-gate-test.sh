#!/bin/bash
# Regression: a flyctl panic on mexec stdout must never read as a build RESULT
# (MEDIC 4467 — false-reap force-destroyed pool machines mid-build).
. "$(dirname "$0")/lib/scratch.sh" || exit 1
V="$(cd "$(dirname "$0")/.." && pwd)/bin/result-prefix-ok.sh"
P=0; F=0
ok(){ if "$V" "$1"; then P=$((P+1)); else F=$((F+1)); echo "FAIL (should be RESULT): $1"; fi; }
no(){ if "$V" "$1"; then F=$((F+1)); echo "FAIL (should be MISS): $1"; else P=$((P+1)); fi; }
ok "PR_CREATED https://github.com/x/y/pull/1"
ok "PLAN_BLOCKED ambiguous ticket"
ok "BUILD_ERROR npm install failed"
ok "REVIEW_APPROVE TIER: 1"
ok "QUEUED_RETRY attempt=2"
ok "EXECUTE_DONE"
ok "DECOMPOSE 3 subtickets"
ok "SECURITY_BLOCK secret in diff"
ok "REFUTE_OK"; ok "QA_PASS"; ok "TAMPER_NONE"; ok "RESULT_OK"
ok "SMOKE_OK on pool machine 123"
no ""
no "Oops, something went wrong! You can try again"
no "panic: runtime error: invalid memory address or nil pointer dereference"
no "goroutine 1 [running]:"
no "[signal SIGSEGV: segmentation violation code=0x1 addr=0x0]"
no "github.com/superfly/flyctl/ssh.selectContainer(0x0)"
no "Error: machine not found"
no "connection reset by peer"
no "  PR_CREATED leading-space is not a first-column result"
echo "pass=$P fail=$F"; [ "$F" = 0 ]
