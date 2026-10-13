#!/bin/bash
# tests/reconcile-prs-backstop-window.bh-1292-test.sh — BH-1292 I2: the wake
# backstop paste in the REAL bin/reconcile-prs.sh passes an explicit 300s
# window. A wake-launched run stamps and then refuses the closure it was woken
# for (it is younger than MC_CLOSED_SETTLE, 180s), so the 1800s default stood
# the */10 cron lane down for up to half an hour and a closed-unmerged row
# cleared late. 300s is longer than the settle window plus the 15-45s wake
# latency, and shorter than the 600s cron period.
# Run from anywhere: HARNESS_TEST_SANDBOX=1 bash tests/reconcile-prs-backstop-window.bh-1292-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

export HARNESS="$T"
mkdir -p "$T/bin" "$T/bin/lib" "$T/env" "$T/logs" "$T/locks" "$T/state" "$T/flags" "$T/calls"
printf 'HARNESS_SECRET=s\nCONSOLE_URL=https://console.test\n' > "$T/env/global.env"

# The real lane and the real backstop library.
cp "$DIR/bin/reconcile-prs.sh"  "$T/bin/reconcile-prs.sh"
cp "$DIR/bin/lib/wake-lanes.sh" "$T/bin/lib/wake-lanes.sh"
chmod +x "$T/bin/reconcile-prs.sh"
# BH-1583: the lane runs only on the reconcile owner and reads its knobs with no
# literal; this fixture box is armed as the owner (tests/lib/reconcile-fixture.sh).
. "$(dirname "$0")/lib/reconcile-fixture.sh" || exit 1
rcfx_arm "$T" "$DIR" || exit 1

# A flag_active that answers from files.
cat > "$T/bin/jobs-client.sh" <<'SH'
#!/bin/bash
flag_active() { [ -f "${HARNESS:-/root/harness}/flags/${1:-}" ]; }
SH
chmod +x "$T/bin/jobs-client.sh"

cat > "$T/bin/curl" <<'SH'
#!/bin/bash
echo "$*" >> "$HARNESS/calls/curl"
printf '{}\n200'
SH
cat > "$T/bin/gh" <<'SH'
#!/bin/bash
echo "$*" >> "$HARNESS/calls/gh"
echo '[]'
SH
cat > "$T/bin/setsid" <<'SH'
#!/bin/bash
exec "$@"
SH
cat > "$T/bin/flock" <<'SH'
#!/bin/bash
exit 0
SH
chmod +x "$T/bin/curl" "$T/bin/gh" "$T/bin/setsid" "$T/bin/flock"
export PATH="$T/bin:$PATH"

reset() {
  rm -rf "$T/calls" "$T/state" "$T/flags" "$T/logs"
  mkdir -p "$T/calls" "$T/state" "$T/flags" "$T/logs" "$T/state/wake-ran"
  touch "$T/flags/wake-lanes-pr-closed"
}
# The lane's own console read is the evidence that it ran: the backstop paste
# sits above it, so /api/builds/unmerged appears exactly when the tick did work.
unmerged() {
  local n
  n=$(grep -c '/api/builds/unmerged' "$T/calls/curl" 2>/dev/null)
  case "$n" in ''|*[!0-9]*) n=0 ;; esac
  printf '%s' "$n"
}
stamp() { echo $(( $(date +%s) - $1 )) > "$T/state/wake-ran/reconcile-prs-fleet"; }

# ---------------------------------------------------------------------------
# A. a stamp 1000s old is stale under the lane's 300s window -> the lane runs
# ---------------------------------------------------------------------------
reset; stamp 1000
( unset WAKE_LAUNCH; "$T/bin/reconcile-prs.sh" >/dev/null 2>&1 )
[ "$(unmerged)" -ge 1 ] && ok || bad "1000s stamp: reconcile-prs must read the console (got $(unmerged))"

# ---------------------------------------------------------------------------
# B. a stamp inside the window still stands the tick down, and says so
# ---------------------------------------------------------------------------
reset; stamp 200
( unset WAKE_LAUNCH; "$T/bin/reconcile-prs.sh" >/dev/null 2>&1 ); RC=$?
[ "$RC" = 0 ] && ok || bad "200s stamp: reconcile-prs must exit 0 (got $RC)"
[ "$(unmerged)" = 0 ] && ok || bad "200s stamp: reconcile-prs must not read the console (got $(unmerged))"
grep -q 'reconcile-prs\[fleet\]: cron tick skipped' "$T/logs/wake-backstop.log" 2>/dev/null && ok \
  || bad "200s stamp: wake-backstop.log must record the skip (got '$(cat "$T/logs/wake-backstop.log" 2>/dev/null)')"
grep -q '(backstop 300s)' "$T/logs/wake-backstop.log" 2>/dev/null && ok \
  || bad "200s stamp: the skip line must name the 300s window (got '$(cat "$T/logs/wake-backstop.log" 2>/dev/null)')"

# ---------------------------------------------------------------------------
# C. one second past the window the lane runs again (boundary)
# ---------------------------------------------------------------------------
reset; stamp 301
( unset WAKE_LAUNCH; "$T/bin/reconcile-prs.sh" >/dev/null 2>&1 )
[ "$(unmerged)" -ge 1 ] && ok || bad "301s stamp: reconcile-prs must read the console (got $(unmerged))"

# ---------------------------------------------------------------------------
# D. the per-call window is the lane's own number, not a re-spelling of the
#    WAKE_BACKSTOP_S default: the env value does not widen it back to 1800
# ---------------------------------------------------------------------------
reset; stamp 1000
( unset WAKE_LAUNCH; WAKE_BACKSTOP_S=1800 "$T/bin/reconcile-prs.sh" >/dev/null 2>&1 )
[ "$(unmerged)" -ge 1 ] && ok || bad "WAKE_BACKSTOP_S=1800 must not widen the lane's 300s window (got $(unmerged))"

# ---------------------------------------------------------------------------
# E. unchanged contract: a wake launch always runs and always re-stamps
# ---------------------------------------------------------------------------
reset; stamp 1000
NOW=$(date +%s)
WAKE_LAUNCH=1 "$T/bin/reconcile-prs.sh" >/dev/null 2>&1
[ "$(unmerged)" -ge 1 ] && ok || bad "WAKE_LAUNCH=1: reconcile-prs must read the console (got $(unmerged))"
STAMPED=$(tr -dc '0-9' < "$T/state/wake-ran/reconcile-prs-fleet" 2>/dev/null)
[ -n "$STAMPED" ] && [ "$STAMPED" -ge "$NOW" ] && ok \
  || bad "WAKE_LAUNCH=1 must re-stamp state/wake-ran/reconcile-prs-fleet (got '${STAMPED:-}')"

# ---------------------------------------------------------------------------
echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
