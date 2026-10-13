#!/bin/bash
# tests/trace-safety-gate-test.sh — bin/test-trace-safety.sh --gate: ONE traced
# run of the corpus yields BOTH CI verdicts (CI cost cut, 2026-09-24).
#
# WHY. CI ran the corpus twice per run: bare for `Pure-logic gate fixtures` and
# under this tracer for `Tests cannot touch a real harness`. The traced run
# already executes every test to completion, so its exit statuses ARE the
# pure-logic verdict. The second copy was ~half of every billed CI minute.
#
# THE PROPERTY UNDER TEST: --gate reports the two verdicts SEPARATELY and never
# lets one hide the other — a failing test with a clean trace is pure=fail
# trace=clean; a passing test that deletes outside a temp root is pure=pass
# trace=dirty; a timeout is a failure (the bare lane had no timeout to hide
# behind); the verdict file exists ONLY when the scan completed; the corpus is
# tests/*.sh AND tests/mc/*.sh (what the bare lane swept); and a failing test's
# own output is printed, because it is now the only place a reader sees it.
# Without --gate the runner is byte-for-byte the old lane (tests/mc excluded,
# nonzero exits counted and never judged) — tests/tests-trace-safety-test.sh
# pins that half.
#
# Fixtures that must HIT aim at /nonexistent-trace-safety-gate/…, which cannot
# exist, so nothing is deleted even if something runs them directly.
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
RUN="$DIR/bin/test-trace-safety.sh"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
has() { case "$2" in *"$1"*) return 0 ;; esac; return 1; }
# The runner needs timeout(1). A dev Mac without coreutils skips; CI (which sets
# CI=true) never may, or this whole gate reads green having run nothing.
if ! command -v timeout >/dev/null 2>&1; then
  [ -n "${CI:-}" ] && { echo "FAIL: no timeout(1) on a CI runner"; exit 1; }
  echo "trace-safety-gate: no timeout(1) on PATH — skipping on this dev machine"; exit 0
fi
if [ "$(id -u)" -eq 0 ]; then export HARNESS_TEST_SANDBOX=1; fi

mktree() { mkdir -p "$T/$1/tests/mc"; printf '%s\n' "$T/$1"; }
vget() { sed -n "s/^$1=//p" "$2" 2>/dev/null | head -1; }

# ── G1. a clean tree: both verdicts clean, tests/mc swept, rc 0 ─────────────
G1=$(mktree clean)
printf '#!/bin/bash\necho "a: 1 pass, 0 fail"\nexit 0\n' > "$G1/tests/a-test.sh"
printf '#!/bin/bash\necho "mc: 1 pass, 0 fail"\nexit 0\n' > "$G1/tests/mc/m-test.sh"
OUT=$("$RUN" --gate --verdict "$T/v1/shard-0.txt" "$G1" 2>&1); RC=$?
[ "$RC" -eq 0 ] && ok || bad "G1: a clean tree must be rc 0 under --gate (rc=$RC) [$OUT]"
has "--- tests/mc/m-test.sh rc=0" "$OUT" && ok || bad "G1: --gate must sweep tests/mc like the bare lane did [$OUT]"
has "--- tests/a-test.sh rc=0" "$OUT" && ok || bad "G1: every test gets a '--- <path> rc= <secs>s' line [$OUT]"
[ "$(vget tests "$T/v1/shard-0.txt")" = 2 ] && ok || bad "G1: verdict tests= must be 2: $(cat "$T/v1/shard-0.txt" 2>/dev/null)"
[ "$(vget pure "$T/v1/shard-0.txt")" = pass ] && ok || bad "G1: pure=pass expected: $(cat "$T/v1/shard-0.txt" 2>/dev/null)"
[ "$(vget trace "$T/v1/shard-0.txt")" = clean ] && ok || bad "G1: trace=clean expected: $(cat "$T/v1/shard-0.txt" 2>/dev/null)"
has "GATE: pure-logic pass" "$OUT" && ok || bad "G1: the summary line must state both verdicts [$OUT]"

# ── G2. a failing test with a clean trace: pure=fail, trace=clean, rc 1, and
#    the failing test's own output is in the log.
G2=$(mktree failing)
printf '#!/bin/bash\necho "ok-test: 1 pass, 0 fail"\n' > "$G2/tests/ok-test.sh"
printf '#!/bin/bash\necho "FAIL: the-assertion-that-broke"\nexit 1\n' > "$G2/tests/broken-test.sh"
OUT=$("$RUN" --gate --verdict "$T/v2.txt" "$G2" 2>&1); RC=$?
[ "$RC" -eq 1 ] && ok || bad "G2: a failing test must make --gate rc 1 (rc=$RC) [$OUT]"
[ "$(vget pure "$T/v2.txt")" = fail ] && ok || bad "G2: pure=fail expected: $(cat "$T/v2.txt" 2>/dev/null)"
[ "$(vget trace "$T/v2.txt")" = clean ] && ok || bad "G2: a failing test is NOT a trace hit — trace=clean expected: $(cat "$T/v2.txt" 2>/dev/null)"
[ "$(vget failed "$T/v2.txt")" = 1 ] && ok || bad "G2: failed=1 expected: $(cat "$T/v2.txt" 2>/dev/null)"
has "the-assertion-that-broke" "$OUT" && ok || bad "G2: the failing test's output must be printed [$OUT]"
has "ok-test: 1 pass" "$OUT" && bad "G2: a PASSING test's output is noise and must not be printed [$OUT]" || ok

# ── G3. a passing test that deletes outside a temp root: pure=pass,
#    trace=dirty, rc 1. One verdict must never hide the other.
G3=$(mktree hit)
cat > "$G3/tests/hit-test.sh" <<'FIXEOF'
#!/bin/bash
rm -rf /nonexistent-trace-safety-gate/harness
exit 0
FIXEOF
OUT=$("$RUN" --gate --verdict "$T/v3.txt" "$G3" 2>&1); RC=$?
[ "$RC" -eq 1 ] && ok || bad "G3: a hit must make --gate rc 1 (rc=$RC) [$OUT]"
[ "$(vget pure "$T/v3.txt")" = pass ] && ok || bad "G3: the test passed — pure=pass expected: $(cat "$T/v3.txt" 2>/dev/null)"
[ "$(vget trace "$T/v3.txt")" = dirty ] && ok || bad "G3: trace=dirty expected: $(cat "$T/v3.txt" 2>/dev/null)"
has "HIT hit-test.sh rm /nonexistent-trace-safety-gate/harness" "$OUT" && ok || bad "G3: the hit must be printed by name [$OUT]"

# ── G4. a timeout is a FAILURE under --gate (it was only counted before).
G4=$(mktree slow)
cat > "$G4/tests/hang-test.sh" <<'FIXEOF'
#!/bin/bash
sleep 30  # determinism: ok the sleep IS the fixture; the runner's 1s timeout is the assertion
FIXEOF
OUT=$(TRACE_SAFETY_TEST_TIMEOUT=1 "$RUN" --gate --verdict "$T/v4.txt" "$G4" 2>&1); RC=$?
[ "$RC" -eq 1 ] && ok || bad "G4: a timed-out test must make --gate rc 1 (rc=$RC) [$OUT]"
[ "$(vget pure "$T/v4.txt")" = fail ] && ok || bad "G4: pure=fail expected on a timeout: $(cat "$T/v4.txt" 2>/dev/null)"
has "TIMEOUT hang-test.sh" "$OUT" && ok || bad "G4: the timeout must be named [$OUT]"

# ── G5. a scan that did not complete writes NO verdict: a missing file is
#    what turns both fan-in checks red.
G5=$(mktree empty)
rm -f "$T/v5.txt"
OUT=$("$RUN" --gate --verdict "$T/v5.txt" "$G5" 2>&1); RC=$?
[ "$RC" -eq 2 ] && ok || bad "G5: an empty corpus is rc 2 under --gate too (rc=$RC) [$OUT]"
[ ! -e "$T/v5.txt" ] && ok || bad "G5: rc 2 must leave NO verdict file: $(cat "$T/v5.txt" 2>/dev/null)"
mkdir -p "$T/deadbash"; ln -sf /bin/true "$T/deadbash/bash"
OUT=$(PATH="$T/deadbash:$PATH" "$RUN" --gate --verdict "$T/v5b.txt" "$G1" 2>&1); RC=$?
{ [ "$RC" -eq 2 ] && [ ! -e "$T/v5b.txt" ]; } && ok \
  || bad "G5: an untraceable run must be rc 2 with no verdict file (rc=$RC) [$OUT]"

# ── G6. --verdict without --gate is refused: the old lane has one verdict.
OUT=$("$RUN" --verdict "$T/v6.txt" "$G1" 2>&1); RC=$?
[ "$RC" -eq 2 ] && ok || bad "G6: --verdict without --gate must be rc 2 (rc=$RC) [$OUT]"

# ── G7. without --gate nothing changed: tests/mc is not swept, a failing test
#    is counted and does not set rc.
OUT=$("$RUN" --list "$G1" 2>&1); RC=$?
[ "$RC" -eq 0 ] && [ "$OUT" = "tests/a-test.sh" ] && ok \
  || bad "G7: the plain lane must list tests/*.sh only (rc=$RC) [$OUT]"
OUT=$("$RUN" --gate --list "$G1" 2>&1)
has "tests/mc/m-test.sh" "$OUT" && ok || bad "G7: --gate --list must include tests/mc [$OUT]"
OUT=$("$RUN" "$G2" 2>&1); RC=$?
[ "$RC" -eq 0 ] && ok || bad "G7: the plain lane never judges a failing test (rc=$RC) [$OUT]"

# ── G8. the same basename in tests/ and tests/mc/ runs twice, as two tests.
G8=$(mktree twin)
printf '#!/bin/bash\nexit 0\n' > "$G8/tests/same-test.sh"
printf '#!/bin/bash\necho "FAIL: the-mc-twin"\nexit 1\n' > "$G8/tests/mc/same-test.sh"
OUT=$("$RUN" --gate --verdict "$T/v8.txt" "$G8" 2>&1); RC=$?
{ [ "$(vget tests "$T/v8.txt")" = 2 ] && [ "$(vget failed "$T/v8.txt")" = 1 ]; } && ok \
  || bad "G8: two suites sharing a basename are two tests, one failing: $(cat "$T/v8.txt" 2>/dev/null) [$OUT]"
has "the-mc-twin" "$OUT" && ok || bad "G8: the mc twin's own output must be printed [$OUT]"

echo "trace-safety-gate: $PASS pass, $FAIL fail"
[ "$FAIL" -eq 0 ]
