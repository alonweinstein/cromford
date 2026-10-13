#!/bin/bash
# stub stand-in for tests/lib/scratch.sh — the fixture never sources a real one.
#
# INERT BY DESIGN. These trees are fixture DATA for checks/tests-scratch-only:
# mode 644, and nothing in the repo executes them. But "nothing executes them"
# is not a property this repo controls — bin/repro-gate.sh already globbed all
# fifteen of them as added test files and ran bash over the list — and one of
# the fixtures next door is a loaded #388. So the stub exits on source, and
# every fixture that sources it stops right there, before its own mkdir / trap /
# rm can run. The check reads TEXT, not behaviour, so every seeded hit is
# unchanged. tests/tests-scratch-only-check-test.sh section A0 proves the
# inertness by executing each fixture against a fake harness that must survive.
exit 0
T=/dev/null/stub-scratch   # what the real lib hands out; unreachable on purpose
