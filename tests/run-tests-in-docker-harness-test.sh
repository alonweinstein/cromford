#!/bin/bash
# tests/run-tests-in-docker-harness-test.sh — bin/run-tests-in-docker.sh and the
# loop it runs inside the container (bin/lib/suite-runner.sh), BH-514.
#
# THE BUG THIS PINS. The runner used to deliver its in-container script on the
# container's stdin (`bash -s <<'INNER'`) and then ran every suite without
# closing stdin. bash reads a script from stdin one line at a time, so the first
# suite that called `cat` or `read` swallowed everything after the loop — the
# summary line, the failing list and the final `exit "$FAIL"` — and the shell hit
# EOF and exited 0. A whole-suite run with real failures printed no totals and
# reported success. Roughly one suite in six here reads stdin, so this was not a
# corner case; it was the normal shape of a red run.
#
# WHY THERE IS NO DOCKER HERE. The fix moved the loop into a sourceable library,
# which is exactly what makes it testable: sections A-E drive
# `suite_runner_main` — the same string the container executes — against a
# fixture tests/ dir, and section F drives the REAL runner with a stub `docker`
# first on PATH, so the argv and the container's stdin are assertions rather than
# a claim. Nothing here starts a container, which is also why this file is safe
# to sit in tests/ and be picked up by the `tests/*.sh` sweep.
#
# Section A is the reproduction: it feeds its driver script on stdin the way the
# old runner did. If the loop stops closing stdin per suite, the stdin-reading
# fixture eats the driver's last two lines and `runner-rc=`/`after-loop-line`
# never print.
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
LIB="$DIR/bin/lib/suite-runner.sh"
RUNNER="$DIR/bin/run-tests-in-docker.sh"

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
has()   { grep -qF -- "$2" "$1" && ok || bad "$3"; }
hasre() { grep -qE -- "$2" "$1" && ok || bad "$3"; }
lacks()   { grep -qF -- "$2" "$1" && bad "$3" || ok; }
lacksre() { grep -qE -- "$2" "$1" && bad "$3" || ok; }
rcis()  { [ "$1" = "$2" ] && ok || bad "$3 (rc=$1, want $2)"; }

# ── fixtures ────────────────────────────────────────────────────────────────
R="$T/repo"
mkdir -p "$R/tests"
export STDIN_MARK="$T/stdin-ran"

cat > "$R/tests/pass-test.sh" <<'EOF'
echo "pass-suite: 1 passed, 0 failed"
exit 0
EOF
cat > "$R/tests/fail-test.sh" <<'EOF'
echo "fail-suite: 0 passed, 1 failed"
exit 1
EOF
# The suite that caused the incident: it reads stdin to EOF before saying
# anything. The marker is how we know it ran to completion even in whole-suite
# mode, where its stdout goes to /dev/null.
cat > "$R/tests/stdin-test.sh" <<'EOF'
cat > /dev/null
echo "stdin-suite: 1 passed, 0 failed"
echo done > "$STDIN_MARK"
exit 0
EOF

# ── A: the bug shape — whole-suite mode, driver script fed on stdin ─────────
OUT_A="$T/out-a.txt"
SRC="$R" WORK="$T/work-a" bash -s > "$OUT_A" 2>&1 <<EOF
set -uo pipefail
. "$LIB" || exit 99
suite_runner_main
echo "runner-rc=\$?"
echo after-loop-line
EOF
has   "$OUT_A" 'debian trixie: 2 pass, 1 fail' "A: whole-suite summary line missing"
has   "$OUT_A" 'failing:'                      "A: failing list missing"
hasre "$OUT_A" '^  tests/fail-test\.sh$'       "A: the failing suite is not listed plainly"
has   "$OUT_A" 'runner-rc=1'                   "A: exit status did not reach the caller (stdin eaten?)"
has   "$OUT_A" 'after-loop-line'               "A: the line after the run never executed (stdin eaten?)"
[ -f "$STDIN_MARK" ] && ok || bad "A: the stdin-reading suite did not run to completion"

# ── B: named/verbose mode shows every suite's own output ────────────────────
OUT_B="$T/out-b.txt"
SRC="$R" WORK="$T/work-b" SUITES="tests/stdin-test.sh tests/fail-test.sh" \
  bash -c "set -uo pipefail; . '$LIB' && suite_runner_main" > "$OUT_B" 2>&1 </dev/null
RC_B=$?
has "$OUT_B" '─── tests/stdin-test.sh'          "B: verbose header missing"
has "$OUT_B" 'stdin-suite: 1 passed, 0 failed'  "B: the stdin suite's own summary is missing"
has "$OUT_B" 'fail-suite: 0 passed, 1 failed'   "B: the failing suite's own output is missing"
has "$OUT_B" 'debian trixie: 1 pass, 1 fail'    "B: summary line missing in named mode"
rcis "$RC_B" 1                                  "B: named mode exit status"

# ── C: a named suite that does not exist is a counted failure ───────────────
OUT_C="$T/out-c.txt"
SRC="$R" WORK="$T/work-c" SUITES="tests/no-such-suite.sh" \
  bash -c "set -uo pipefail; . '$LIB' && suite_runner_main" > "$OUT_C" 2>&1 </dev/null
RC_C=$?
has "$OUT_C" 'no such suite: tests/no-such-suite.sh' "C: no message for a missing suite"
has "$OUT_C" 'debian trixie: 0 pass, 1 fail'        "C: a missing suite was not counted as a failure"
rcis "$RC_C" 1                                      "C: a missing suite must not exit 0"

# ── C2: the default path with NO matching suite is loud and nonzero ─────────
# A copy that landed without tests/ (wrong SRC, a bad cp) must not read as a
# green "0 pass, 0 fail" — BH-514 removed exactly that vacuous green.
OUT_C2="$T/out-c2.txt"
mkdir -p "$T/empty-repo/tests"
SRC="$T/empty-repo" WORK="$T/work-c2" \
  bash -c "set -uo pipefail; . '$LIB' && suite_runner_main" > "$OUT_C2" 2>&1 </dev/null
RC_C2=$?
has   "$OUT_C2" 'suite-runner: no suites matched tests/*.sh tests/mc/*.sh' "C2: no message when nothing matched"
lacks "$OUT_C2" '0 pass, 0 fail'                                          "C2: an empty run printed a vacuous green summary"
rcis  "$RC_C2" 2                                                          "C2: an empty run must not exit 0"

# ── D: the known-failures list decorates, and only what it lists ────────────
printf '# known container-only failures\n\ntests/fail-test.sh\n' \
  > "$R/tests/known-container-failures.txt"
OUT_D="$T/out-d.txt"
SRC="$R" WORK="$T/work-d" \
  bash -c "set -uo pipefail; . '$LIB' && suite_runner_main" > "$OUT_D" 2>&1 </dev/null
RC_D=$?
hasre "$OUT_D" '^  tests/fail-test\.sh +expected \(tests/known-container-failures\.txt\)$' \
      "D: a listed failure is not marked expected"
has  "$OUT_D" '1 of 1 expected'  "D: the expected-count line is missing"
rcis "$RC_D" 1                   "D: an expected failure still counts toward the exit status"

printf 'tests/pass-test.sh\n' > "$R/tests/known-container-failures.txt"
OUT_D2="$T/out-d2.txt"
SRC="$R" WORK="$T/work-d2" \
  bash -c "set -uo pipefail; . '$LIB' && suite_runner_main" > "$OUT_D2" 2>&1 </dev/null
RC_D2=$?
hasre "$OUT_D2" '^  tests/fail-test\.sh$' "D: an UNLISTED failure was decorated as expected"
lacks "$OUT_D2" 'of 1 expected'           "D: the expected-count line printed with nothing expected"
rcis  "$RC_D2" 1                          "D: the list must not change the exit status"

# ── E: the exit status is capped at 125, the printed count is not ───────────
M="$T/many"
mkdir -p "$M/tests"
i=1
while [ "$i" -le 130 ]; do printf 'exit 1\n' > "$M/tests/f-$i-test.sh"; i=$((i+1)); done
OUT_E="$T/out-e.txt"
SRC="$M" WORK="$T/work-e" \
  bash -c "set -uo pipefail; . '$LIB' && suite_runner_main" > "$OUT_E" 2>&1 </dev/null
RC_E=$?
has  "$OUT_E" 'debian trixie: 0 pass, 130 fail' "E: the true count must still be printed"
rcis "$RC_E" 125                                "E: exit status is capped at 125"

# ── F: the production entry point, with a stub docker ───────────────────────
mkdir -p "$T/stub"
export DOCKER_ARGS="$T/docker-args.txt" DOCKER_STDIN="$T/docker-stdin.txt"
cat > "$T/stub/docker" <<'EOF'
#!/bin/bash
case "${1:-}" in
  info)  exit 0 ;;
  image) exit 0 ;;
  run)   printf '%s\n' "$@" > "$DOCKER_ARGS"; cat > "$DOCKER_STDIN"; exit 4 ;;
esac
exit 0
EOF
chmod +x "$T/stub/docker"

OUT_F="$T/out-f.txt"
PATH="$T/stub:$PATH" bash "$RUNNER" > "$OUT_F" 2>&1 </dev/null
RC_F=$?
rcis "$RC_F" 4 "F: the runner must exit with the container's status"
[ -f "$DOCKER_STDIN" ] && [ ! -s "$DOCKER_STDIN" ] && ok \
  || bad "F: the container was handed a non-empty stdin (a suite can eat the runner)"
hasre "$DOCKER_ARGS" '^bash$'            "F: docker run does not invoke bash"
hasre "$DOCKER_ARGS" '^-c$'              "F: the container script is not passed with -c"
lacksre "$DOCKER_ARGS" '^-s$'            "F: docker run still uses bash -s"
has   "$DOCKER_ARGS" 'suite_runner_main' "F: the container does not call suite_runner_main"
has   "$DOCKER_ARGS" 'suite-runner.sh'   "F: the container does not source the suite-runner lib"
hasre "$DOCKER_ARGS" '^SUITES='          "F: SUITES is not passed to the container"

DOCKER_ARGS="$T/docker-args2.txt" PATH="$T/stub:$PATH" \
  bash "$RUNNER" tests/x-test.sh > "$T/out-f2.txt" 2>&1 </dev/null
RC_F2=$?
rcis  "$RC_F2" 4 "F: named mode must also propagate the container's status"
hasre "$T/docker-args2.txt" '^SUITES=tests/x-test\.sh$' "F: a named suite is not forwarded"

# Guard, next to the behavioural assertions above rather than in place of them:
# the heredoc delivery must not come back, in code OR in a comment that a future
# reader could copy. The runner's header describes the old form without spelling
# it, for exactly this reason.
lacks "$RUNNER" 'bash -s' "F: bin/run-tests-in-docker.sh still contains 'bash -s'"

# ── G: the library is sourceable and silent ────────────────────────────────
OUT_G=$(bash -c ". '$LIB'" 2>&1 </dev/null)
RC_G=$?
[ -z "$OUT_G" ] && ok || bad "G: sourcing the lib printed: $OUT_G"
rcis "$RC_G" 0 "G: sourcing the lib must exit 0"

echo "run-tests-in-docker-harness: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
