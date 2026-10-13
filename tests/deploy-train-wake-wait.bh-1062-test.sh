#!/bin/bash
# tests/deploy-train-wake-wait.bh-1062-test.sh — the deploy train's poll wait is
# WAKE-AWARE (BH-1062): it still sleeps a whole TRAIN_POLL_SECS when nothing
# happens, but it returns EARLY, within one ≤5s slice, once the deploy wake class
# has written state/deploy-wake-<project> — and it consumes that file.
#
# WHAT IS MEASURED. Not a source pattern: the epoch of the version-endpoint curl
# the train makes after its first wait, against the epoch of the departure hook
# POST it makes immediately before entering the loop. Both come from the same
# stubbed curl, so the delta is the wait itself with no process-start skew in it.
#
# Run from anywhere: HARNESS_TEST_SANDBOX=1 bash tests/deploy-train-wake-wait.bh-1062-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
export HARNESS="$T" TRAIN_POLLS=3 TRAIN_POLL_SECS=6
PASS=0; FAIL=0
ok()   { PASS=$((PASS+1)); }
bad()  { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

mkdir -p "$T/bin" "$T/env" "$T/logs" "$T/locks" "$T/state/deploy-queue/p" "$T/calls" "$T/builds/b1"
# a two-commit repo standing in for /root/repos/<project>; origin/main = HEAD
git init -q "$T/repo" && (cd "$T/repo" && git -c user.email=t@t -c user.name=t commit -q --allow-empty -m one \
  && git -c user.email=t@t -c user.name=t commit -q --allow-empty -m two \
  && git init -q --bare "$T/origin.git" && git remote add origin "$T/origin.git" && git push -q origin HEAD:main \
  && git update-ref refs/remotes/origin/main HEAD)
TARGET=$(git -C "$T/repo" rev-parse HEAD); OLD=$(git -C "$T/repo" rev-parse HEAD~1)
export DEPLOY_TRAIN_REPO_DIR="$T/repo"

cat > "$T/bin/fleet-conf.sh" <<'SH'
#!/bin/bash
echo "org/repo"
SH
cat > "$T/bin/beat.sh" <<'SH'
#!/bin/bash
echo "$1" >> "$HARNESS/calls/beat"
SH
# One stub, two records: the departure hook POST stamps calls/depart, every
# version read stamps calls/version. Production never serves TARGET here, so the
# train polls all TRAIN_POLLS times and the first entry is the first wait.
cat > "$T/bin/curl" <<'SH'
#!/bin/bash
case "$*" in
  *POST*) date +%s.%N >> "$HARNESS/calls/depart" ;;
  *)      date +%s.%N >> "$HARNESS/calls/version"; printf '{"sha":"%s"}' "$(cat "$HARNESS/live")" ;;
esac
SH
cat > "$T/bin/gh" <<'SH'
#!/bin/bash
echo "$*" >> "$HARNESS/calls/gh"; echo "https://github.com/org/repo/pull/1"
SH
# flock is Linux-only; the train's slot lock is not under test here.
cat > "$T/bin/flock" <<'SH'
#!/bin/bash
exit 0
SH
printf '%s\n' 'job_ledger_put() { :; }' > "$T/bin/jobs-client.sh"
chmod +x "$T/bin/"*; export PATH="$T/bin:$PATH"
printf 'VERSION_URL=https://example.test/api/internal/version\nDEPLOY_HOOK_URL=https://example.test/hook\nDEPLOY_ROLLBACK=off\n' > "$T/env/p.env"
echo "PR_CREATED https://github.com/org/repo/pull/77" > "$T/builds/b1/RESULT"
printf '%s' "$OLD" > "$T/live"

enqueue() { printf '%s %s\n' "$TARGET" "$T/builds/b1" > "$T/state/deploy-queue/p/$(( $(date +%s) - 1800 ))-${TARGET:0:8}"; }
prep() { rm -rf "$T/calls" "$T/state/deploy-queue/p"; mkdir -p "$T/calls" "$T/state/deploy-queue/p"; rm -f "$T/state/deploy-wake-p"; enqueue; }
run() { "$DIR/bin/deploy-train.sh" p >/dev/null 2>&1; }
first() { head -1 "$T/calls/$1" 2>/dev/null | tr -dc '0-9.'; }
# wait_delta — SUB-SECOND seconds between the departure hook and the FIRST
# version read. Whole-second epochs cannot carry this measurement: the two
# answers under test are 5s (returned early on the wake file) and 6s (slept the
# whole TRAIN_POLL_SECS), and two floor()s of readings 5.0s apart land 5 or 6
# apart depending only on where the departure fell inside its second.
wait_delta() {
  local d v
  d=$(first depart); v=$(first version)
  [ -n "${d:-}" ] && [ -n "${v:-}" ] || { echo 999; return; }
  awk -v a="$d" -v b="$v" 'BEGIN{ printf "%.2f", b - a }'
}
# le/ge — float compare, so the bounds below can be tighter than one second.
le() { awk -v a="$1" -v b="$2" 'BEGIN{ exit !(a <= b) }'; }
ge() { awk -v a="$1" -v b="$2" 'BEGIN{ exit !(a >= b) }'; }

# ---------------------------------------------------------------------------
# 1. the wake file appears ~2s after departure: the first slice that notices it
#    returns at t≈5, and the file is consumed.
# ---------------------------------------------------------------------------
prep
NOW=$(date +%s)
( sleep 2; printf '%s\n' "$TARGET" > "$T/state/deploy-wake-p" ) &
run
D1=$(wait_delta)
{ ge "$D1" 4.5 && le "$D1" 5.9; } && ok || bad "a wake file 2s after departure must end the wait at the 5s slice, not at the full 6s (got ${D1}s)"
[ -e "$T/state/deploy-wake-p" ] && bad "the wake file must be consumed by the wait" || ok
DEP1=$(first depart)
le "$DEP1" "$(( NOW + 5 ))" && ok || bad "departure must happen promptly after launch, or the delta above is not the wait (NOW=$NOW depart=$DEP1)"

# ---------------------------------------------------------------------------
# 2. no wake file: the full TRAIN_POLL_SECS is slept, and all 3 polls still run.
# ---------------------------------------------------------------------------
prep
run
D2=$(wait_delta)
ge "$D2" 6 && ok || bad "with no wake file the first wait must be the full 6s (got ${D2}s)"
[ "$(wc -l < "$T/calls/version" | tr -d ' ')" = 3 ] && ok || bad "TRAIN_POLLS must still be 3 (got $(wc -l < "$T/calls/version" | tr -d ' '))"

# ---------------------------------------------------------------------------
# 3. a PRE-EXISTING wake file (stale, from a finished train) is consumed by the
#    first slice: one early curl, and gone.
# ---------------------------------------------------------------------------
prep
printf '%s\n' "$TARGET" > "$T/state/deploy-wake-p"
run
D3=$(wait_delta)
le "$D3" 1 && ok || bad "a pre-existing wake file must be consumed before the first sleep (got ${D3}s)"
[ -e "$T/state/deploy-wake-p" ] && bad "a stale wake file must be removed by the first slice" || ok

# ---------------------------------------------------------------------------
# 4. TRAIN_POLL_SECS=0 still falls straight through (the ledger/alert-only suites).
# ---------------------------------------------------------------------------
prep
( export TRAIN_POLL_SECS=0; run )
D4=$(wait_delta)
le "$D4" 1 && ok || bad "TRAIN_POLL_SECS=0 must not sleep (got ${D4}s)"
[ "$(wc -l < "$T/calls/version" | tr -d ' ')" = 3 ] && ok || bad "TRAIN_POLL_SECS=0 must still record 3 polls (got $(wc -l < "$T/calls/version" | tr -d ' '))"

# ---------------------------------------------------------------------------
echo "deploy-train-wake-wait.bh-1062-test: $PASS pass, $FAIL fail"
[ "$FAIL" -eq 0 ]
