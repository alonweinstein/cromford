#!/bin/bash
# tests/trace-safety-sigpipe.bh-5544-test.sh — bin/test-trace-safety.sh starts
# every test with SIGPIPE at its default action, even when the runner itself
# was started with SIGPIPE ignored (BH-5544).
#
# WHY. The CI runners start their steps with SIGPIPE ignored (PR #5221). An
# ignored disposition survives every exec, and bash cannot reset a signal that
# was ignored at its entry. So a test that was green on every laptop saw EPIPE
# (`write error: Broken pipe`, rc 1) in a shard where it expects SIGPIPE (rc
# 141). Both shard jobs start every suite through this runner (P6), so the
# runner is the one place the start state is set.
#   P0  the fixture is not vacuous: started ignored it sees rc 1, started
#       normally it sees rc 141.
#   P1  --gate started with SIGPIPE ignored: the fixture passes, pure=pass.
#   P2  control, a normal start: pure=pass.
#   P3  the bare lane started ignored: no `EXIT 1 pipe-test.sh`.
#   P4  a real failure under an ignored start is still rc 1, pure=fail.
#   P5  a test that ignores SIGPIPE on purpose still gets it ignored.
#   P6  harness-ci.yml and harness-nightly.yml run the shards through --gate.
# Run from anywhere: HARNESS_TEST_SANDBOX=1 bash tests/trace-safety-sigpipe.bh-5544-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
RUN="$DIR/bin/test-trace-safety.sh"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
has() { case "$2" in *"$1"*) return 0 ;; esac; return 1; }
# The runner needs timeout(1). A dev Mac without coreutils skips; CI never may.
if ! command -v timeout >/dev/null 2>&1; then
  [ -n "${CI:-}" ] && { echo "FAIL: no timeout(1) on a CI runner"; exit 1; }
  echo "trace-safety-sigpipe.bh-5544: no timeout(1) on PATH — skipping on this dev machine"; exit 0
fi
if [ "$(id -u)" -eq 0 ]; then export HARNESS_TEST_SANDBOX=1; fi

# IGN: start a command with SIGPIPE ignored, the way a CI step starts. DFL:
# start it at the default, so the controls hold even when this suite itself
# was started with SIGPIPE ignored.
if env --ignore-signal=PIPE true >/dev/null 2>&1 && env --default-signal=PIPE true >/dev/null 2>&1; then
  IGN=(env --ignore-signal=PIPE); DFL=(env --default-signal=PIPE)
elif command -v perl >/dev/null 2>&1; then
  # shellcheck disable=SC2016 # perl code, not shell
  IGN=(perl -e '$SIG{PIPE} = "IGNORE"; exec { $ARGV[0] } @ARGV or exit 127')
  # shellcheck disable=SC2016 # perl code, not shell
  DFL=(perl -e '$SIG{PIPE} = "DEFAULT"; exec { $ARGV[0] } @ARGV or exit 127')
else
  [ -n "${CI:-}" ] && { echo "FAIL: neither GNU env nor perl can start a command with SIGPIPE ignored"; exit 1; }
  echo "trace-safety-sigpipe.bh-5544: cannot start a command with SIGPIPE ignored — skipping on this dev machine"; exit 0
fi

mktree() { mkdir -p "$T/$1/tests/mc"; printf '%s\n' "$T/$1"; }
vget() { sed -n "s/^$1=//p" "$2" 2>/dev/null | head -1; }

# The pipe fixture: `yes` into `head -n1`. At SIGPIPE's default `yes` dies of
# it (rc 141); with SIGPIPE ignored it gets EPIPE and exits 1.
P=$(mktree p)
cat > "$P/tests/pipe-test.sh" <<'FIXEOF'
#!/bin/bash
yes 2>/dev/null | head -n1 >/dev/null
rc=${PIPESTATUS[0]}
echo "pipe-rc=$rc"
[ "$rc" = 141 ]
FIXEOF
# A fixture that ignores SIGPIPE itself, as backup-freshness.bh-1308 does.
Q=$(mktree q)
cat > "$Q/tests/ign-test.sh" <<'FIXEOF'
#!/bin/bash
err=$( ( trap '' PIPE; yes | head -n1 >/dev/null ) 2>&1 )
case "$err" in *"Broken pipe"*) exit 0 ;; esac
echo "FAIL: no Broken pipe with SIGPIPE ignored on purpose: [$err]"
exit 1
FIXEOF
# A fixture that fails for a reason that is not a pipe.
R=$(mktree r)
printf '#!/bin/bash\necho "FAIL: x"\nexit 1\n' > "$R/tests/fail-test.sh"

# ── P0. the fixture is not vacuous ──────────────────────────────────────────
OUT=$("${IGN[@]}" bash "$P/tests/pipe-test.sh" 2>&1); RC=$?
[ "$RC" -eq 1 ] && has "pipe-rc=1" "$OUT" && ok \
  || bad "P0 started ignored the fixture must see EPIPE (rc 1, pipe-rc=1), got rc=$RC [$OUT]"
OUT=$("${DFL[@]}" bash "$P/tests/pipe-test.sh" 2>&1); RC=$?
[ "$RC" -eq 0 ] && has "pipe-rc=141" "$OUT" && ok \
  || bad "P0 started normally the fixture must see SIGPIPE (rc 0, pipe-rc=141), got rc=$RC [$OUT]"

# ── P1. a shard started with SIGPIPE ignored gives its tests the default ────
OUT=$("${IGN[@]}" "$RUN" --gate --verdict "$T/v1.txt" "$P" 2>&1); RC=$?
[ "$RC" -eq 0 ] && ok || bad "P1 --gate started with SIGPIPE ignored: rc=$RC (want 0) [$OUT]"
has "--- tests/pipe-test.sh rc=0" "$OUT" && ok || bad "P1 the pipe test must pass under an ignored start [$OUT]"
[ "$(vget pure "$T/v1.txt")" = pass ] && ok || bad "P1 pure=pass expected: $(cat "$T/v1.txt" 2>/dev/null)"
[ "$(vget failed "$T/v1.txt")" = 0 ] && ok || bad "P1 failed=0 expected: $(cat "$T/v1.txt" 2>/dev/null)"

# ── P2. control: a normal start ─────────────────────────────────────────────
OUT=$("${DFL[@]}" "$RUN" --gate --verdict "$T/v2.txt" "$P" 2>&1); RC=$?
[ "$RC" -eq 0 ] && ok || bad "P2 --gate started normally: rc=$RC (want 0) [$OUT]"
[ "$(vget pure "$T/v2.txt")" = pass ] && ok || bad "P2 pure=pass expected: $(cat "$T/v2.txt" 2>/dev/null)"

# ── P3. the reset reaches the bare lane too ─────────────────────────────────
OUT=$("${IGN[@]}" "$RUN" "$P" 2>&1); RC=$?
has "TRACE: 1 tests, 0 nonzero exit(s), 0 hit(s)" "$OUT" && ok \
  || bad "P3 the bare lane started ignored must count 0 nonzero exits (rc=$RC) [$OUT]"
has "EXIT 1 pipe-test.sh" "$OUT" && bad "P3 the bare lane saw the pipe test fail on EPIPE [$OUT]" || ok

# ── P4. a failure is still a failure ────────────────────────────────────────
OUT=$("${IGN[@]}" "$RUN" --gate --verdict "$T/v4.txt" "$R" 2>&1); RC=$?
[ "$RC" -eq 1 ] && ok || bad "P4 a failing test under an ignored start must make --gate rc 1 (rc=$RC) [$OUT]"
[ "$(vget pure "$T/v4.txt")" = fail ] && ok || bad "P4 pure=fail expected: $(cat "$T/v4.txt" 2>/dev/null)"

# ── P5. a test can still ignore SIGPIPE on purpose ──────────────────────────
OUT=$("${IGN[@]}" "$RUN" --gate --verdict "$T/v5.txt" "$Q" 2>&1); RC=$?
[ "$RC" -eq 0 ] && ok || bad "P5 a test that ignores SIGPIPE itself: rc=$RC (want 0) [$OUT]"
[ "$(vget pure "$T/v5.txt")" = pass ] && ok || bad "P5 pure=pass expected: $(cat "$T/v5.txt" 2>/dev/null)"

# ── P6. both shard jobs start every suite through this runner ───────────────
for wf in harness-ci.yml harness-nightly.yml; do
  body=$(cat "$DIR/.github/workflows/$wf" 2>/dev/null)
  case "$body" in
    *"bin/test-trace-safety.sh --gate"*) ok ;;
    *) bad "P6 .github/workflows/$wf does not run bin/test-trace-safety.sh --gate: its shards miss the SIGPIPE reset" ;;
  esac
done

echo "trace-safety-sigpipe.bh-5544: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
