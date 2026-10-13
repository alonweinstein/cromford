#!/bin/bash
# tests/fleet-propagate-test.sh — bin/fleet-propagate.sh: a merge to main reaches
# every box and every pool image within one tick, and says honestly what it did.
#
# WHAT THIS PINS. Before 2026-09-14 harness code reached the boxes only at 05:17Z
# and the pool images only at 05:40Z, so the shapes that matter are the ones that
# used to be invisible for a day:
#   * a commit that touches nothing the fleet runs must NOT ssh nine boxes and
#     rebake nine images — it records the sha and skips;
#   * a bin/ commit must reach EVERY box the registry names (once each, with
#     `ssh -n` — without it the first ssh eats the loop's stdin and the rest are
#     silently skipped) and rebake EVERY pool flag;
#   * a partial success is never reported as success: one box rc!=0 is ONE
#     --critical alert naming it, while project-6's known-broken warm bake is
#     reported and tolerated;
#   * a tick that lands on a running propagation leaves, rather than piling on;
#   * --check writes nothing at all.
#
# Everything outside the script is stubbed through PATH ($T/bin) and a scratch
# HARNESS ($H/bin): ssh, crontab, pgrep, fleet-conf/box-for, harness-sync,
# fly-image-build and lane-alert. git is REAL, against a scratch origin — the
# range arithmetic (LAST..NEW) is half of what this script decides.
#
# Run from anywhere: tests/fleet-propagate-test.sh   (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

H="$T/harness"
mkdir -p "$H/bin" "$H/logs" "$H/state" "$H/locks" "$H/flags" "$T/bin"
cp "$DIR/bin/fleet-propagate.sh" "$H/bin/"
scratch_install_closure bin/lib/fleet-paths.sh "$H" >/dev/null || exit 1   # BH-5247: FLEET_PATHS, or the run fails closed
echo hub > "$H/state/box-id"

# ── the fixture fleet: two boxes, three projects (two share a box, so "every
#    box once" is a real assertion), plus a pool flag that is NOT an app flag.
cat > "$H/fleet.conf" <<'EOF'
alpha-os Acme/alpha-os https://alpha.example /api/board 2 box-alpha 10.0.0.1
beta     Acme/beta     -                     -          4 box-beta  10.0.0.2
gamma    Acme/gamma    -                     -          6 box-beta  10.0.0.2
EOF
cp "$DIR/bin/fleet-conf.sh" "$DIR/bin/box-for.sh" "$H/bin/"
: > "$H/flags/fly-pool-app-alpha-os"
: > "$H/flags/fly-pool-app-project-6"
: > "$H/flags/fly-pool-beta"          # the pool-state flag, not an app flag

# ── stubs ────────────────────────────────────────────────────────────────────
cat > "$T/bin/ssh" <<'EOF'
#!/bin/bash
printf '%s\n' "$*" >> "$SSH_CALLS"
IP=""; for A in "$@"; do case "$A" in root@*) IP="${A#root@}" ;; esac; done
if [ -n "${SSH_FAIL_IP:-}" ] && [ "$IP" = "$SSH_FAIL_IP" ]; then echo "0000000"; exit 7; fi
echo "cafe123456789"; exit 0
EOF
# pgrep is stubbed to "nothing running": a REAL fly-image-build.sh on the box
# running this test would otherwise make the defer guard fire and the run skip.
cat > "$T/bin/pgrep" <<'EOF'
#!/bin/bash
[ -n "${PGREP_HIT:-}" ] && { echo 4242; exit 0; }
exit 1
EOF
cat > "$T/bin/crontab" <<'EOF'
#!/bin/bash
if [ "${1:-}" = "-l" ]; then cat "$LIVE_CRON" 2>/dev/null; exit 0; fi
cp "$1" "$INSTALLED_CRON"; exit 0
EOF
cat > "$H/bin/harness-sync.sh" <<'EOF'
#!/bin/bash
echo "synced (stub)"; exit "${HARNESS_SYNC_RC:-0}"
EOF
cat > "$H/bin/fly-image-build.sh" <<'EOF'
#!/bin/bash
printf '%s\n' "$1" >> "$BAKE_CALLS"
[ "$1" = "${BAKE_FAIL:-}" ] && exit 1
exit 0
EOF
cat > "$H/bin/lane-alert.sh" <<'EOF'
#!/bin/bash
printf '%s\n' "$*" >> "$ALERTS"
exit 0
EOF
chmod +x "$T/bin"/* "$H/bin"/*

# ── a real scratch repo: bare origin + the hub's checkout ────────────────────
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@x GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@x
git init -q --bare "$T/origin"
git init -q -b main "$T/src" 2>/dev/null || { git init -q "$T/src"; git -C "$T/src" checkout -q -b main; }
git -C "$T/src" remote add origin "$T/origin"
mkdir -p "$T/src/bin" "$T/src/docs" "$T/src/cron"
echo "echo v1" > "$T/src/bin/run-build.sh"
echo "readme" > "$T/src/docs/README.md"
printf '2,12 * * * * /root/harness/bin/run-triage.sh alpha-os\n' > "$T/src/cron/hub.cron"
# The render the hub would install: the live lane plus one more line.
cat > "$T/src/bin/render-crontab.sh" <<'EOF'
#!/bin/bash
printf '2,12 * * * * /root/harness/bin/run-triage.sh alpha-os\n*/5 * * * * /root/harness/bin/fleet-propagate.sh\n'
EOF
chmod +x "$T/src/bin/render-crontab.sh"
git -C "$T/src" add -A && git -C "$T/src" commit -qm init && git -C "$T/src" push -q origin main
git -C "$T/origin" symbolic-ref HEAD refs/heads/main
git clone -q "$T/origin" "$T/checkout"
printf '2,12 * * * * /root/harness/bin/run-triage.sh alpha-os\n' > "$T/livecron"

commit() { # commit <path> <content>
  mkdir -p "$(dirname "$T/src/$1")"; echo "$2" > "$T/src/$1"
  git -C "$T/src" add -A && git -C "$T/src" commit -qm "$1" && git -C "$T/src" push -q origin main
}
run() { # run [flags...]
  # POOL_IMAGE_MIN_AGE_MIN=0 is the documented per-merge mode: what this suite
  # pins is "every pool bakes once per merge", and its sections commit seconds
  # apart. The bake debounce that BH-821 added has its own suite,
  # tests/fleet-propagate.bh-821-test.sh.
  : > "$T/ssh.calls"; : > "$T/bake.calls"; : > "$T/alerts"
  ( HARNESS="$H" HARNESS_CHECKOUT="${HARNESS_CHECKOUT:-$T/checkout}" POOL_IMAGE_MIN_AGE_MIN=0 \
    FLEET_PROPAGATE_PATH="$T/bin:/usr/bin:/bin:/usr/local/bin" \
    SSH_CALLS="$T/ssh.calls" BAKE_CALLS="$T/bake.calls" ALERTS="$T/alerts" \
    LIVE_CRON="$T/livecron" INSTALLED_CRON="$T/installed.cron" \
    SSH_FAIL_IP="${SSH_FAIL_IP:-}" BAKE_FAIL="${BAKE_FAIL:-}" \
    bash "$H/bin/fleet-propagate.sh" "$@" ) > "$T/out" 2>"$T/err"
}
nssh()   { grep -c . "$T/ssh.calls"  2>/dev/null | head -1; }
nbake()  { grep -c . "$T/bake.calls" 2>/dev/null | head -1; }
nalert() { grep -c . "$T/alerts"     2>/dev/null | head -1; }
jsonq()  { jq -r "$1" "$H/state/fleet-propagate.json" 2>/dev/null; }

# Side-branch guard cases need their own checkouts because a Fly builder child
# bash sees the filesystem snapshot from the first subshell fork (case 1).
# Create them once here, before that fork, so fleet-propagate sees them.
for B in pr908 pr909 pr910; do
  git -C "$T/src" checkout -q -b "$B"
  echo "branch $B" > "$T/src/bin/$B"
  git -C "$T/src" add -A && git -C "$T/src" commit -qm "$B" && git -C "$T/src" push -q -u origin "$B"
  git -C "$T/src" checkout -q main
  rm -f "$T/src/bin/$B"
done
git clone -q -b pr908 "$T/origin" "$T/checkout-pr908"
git clone -q -b pr909 "$T/origin" "$T/checkout-pr909"
echo dirty > "$T/checkout-pr909/dirty"
git clone -q -b pr910 "$T/origin" "$T/checkout-pr910"

# ── 1. nothing moved: exit 0, silently ──────────────────────────────────────
# No state file yet, so LAST is the checkout's own HEAD — a first run propagates
# nothing rather than re-syncing a fleet that is already there.
run; RC=$?
[ "$RC" = 0 ] && ok || bad "an unchanged origin must exit 0 (rc=$RC)"
[ -s "$T/out" ] && bad "an unchanged origin must be silent (got: $(cat "$T/out"))" || ok
[ ! -f "$H/state/fleet-propagate.json" ] && ok || bad "an unchanged origin must write no state"
[ ! -s "$H/logs/fleet-propagate.log" ] && ok || bad "an unchanged origin must write no log line"
[ "$(nssh)" = 0 ] && [ "$(nbake)" = 0 ] && ok || bad "an unchanged origin must not touch the fleet"

# ── 2. a change OUTSIDE the fleet paths: record the sha and skip ─────────────
commit docs/README.md "v2"
NEW=$(git -C "$T/src" rev-parse HEAD)
run; RC=$?
[ "$RC" = 0 ] && ok || bad "a non-fleet change must exit 0 (rc=$RC)"
[ "$(jsonq .last_sha)" = "$NEW" ] && ok || bad "a skipped change must still record last_sha (got $(jsonq .last_sha))"
[ "$(jsonq .skipped)" = true ] && ok || bad "a skipped change must be recorded as skipped"
[ "$(nssh)" = 0 ] && ok || bad "a docs-only change must ssh NO box (got $(nssh))"
[ "$(nbake)" = 0 ] && ok || bad "a docs-only change must rebake NO image (got $(nbake))"
[ "$(nalert)" = 0 ] && ok || bad "a skipped tick must not alert (got: $(cat "$T/alerts"))"

# ── 3. a bin/ change: every box once, every pool once, honest json ───────────
commit bin/run-build.sh "echo v2"
NEW=$(git -C "$T/src" rev-parse HEAD)
run; RC=$?
[ "$RC" = 0 ] && ok || bad "a good propagation must exit 0 (rc=$RC)"
[ "$(nssh)" = 2 ] && ok || bad "each of the two fixture BOXES must be ssh'd exactly once (got $(nssh): $(cat "$T/ssh.calls"))"
[ "$(grep -c -- '^-n ' "$T/ssh.calls")" = 2 ] && ok \
  || bad "every ssh inside the loop must pass -n, or the first one eats stdin and the rest are skipped"
grep -q 'root@10.0.0.1' "$T/ssh.calls" && grep -q 'root@10.0.0.2' "$T/ssh.calls" && ok \
  || bad "both registry addresses must be reached: $(cat "$T/ssh.calls")"
grep -q 'update-runners.sh' "$T/ssh.calls" && ok || bad "the box lane must run update-runners.sh"
[ "$(sort "$T/bake.calls" | tr '\n' ' ')" = "alpha-os project-6 " ] && ok \
  || bad "exactly the fly-pool-app-* projects must be rebaked (got: $(cat "$T/bake.calls"))"
[ "$(jsonq .hub)" = ok ] && ok || bad "hub must be recorded ok (got $(jsonq .hub))"
[ "$(jsonq '.boxes["box-alpha"].rc')" = 0 ] && ok || bad "a box's rc must be recorded"
[ "$(jsonq '.boxes["box-beta"].sha')" = "cafe123456789" ] && ok \
  || bad "the sha the box actually landed on must be recorded (got $(jsonq '.boxes["box-beta"].sha'))"
[ "$(jsonq '.pools["alpha-os"].status')" = ok ] && ok || bad "a pool result must be recorded"
[ "$(jsonq '.changed_paths|index("bin/run-build.sh")')" != null ] && ok \
  || bad "the changed fleet path must be in the record"
[ "$(jsonq .last_sha)" = "$NEW" ] && ok || bad "last_sha must advance to origin/main"
[ "$(nalert)" = 1 ] && ok || bad "exactly one alert per run (got $(nalert): $(cat "$T/alerts"))"
grep -q -- '--critical' "$T/alerts" && bad "a full success must not be critical: $(cat "$T/alerts")" || ok
grep -q '2/2 boxes synced' "$T/alerts" && ok || bad "the alert must name the counts: $(cat "$T/alerts")"
# BH-2337: a full success is a notice — ALERTS.log line only, no alert row.
grep -q '^--log-only fleet-propagate propagated ' "$T/alerts" && ok || bad "a full success must be --log-only: $(cat "$T/alerts")"
grep -q . "$H/logs/fleet-propagate.log" && ok || bad "a propagation must append a log line"
# The crontab is NOT re-rendered for a change that cannot have moved it: the
# render's base is the repo's cron/<box>.cron, so installing it every five
# minutes would drop any line added live and never committed.
[ "$(jsonq .cron)" = not-needed ] && ok || bad "a bin/-only change must not touch the crontab (got $(jsonq .cron))"
[ ! -f "$T/installed.cron" ] && ok || bad "a bin/-only change installed a crontab"

# ── 3b. a cron/ change DOES render and install, behind the drop guard ────────
commit cron/hub.cron '# v2
2,12 * * * * /root/harness/bin/run-triage.sh alpha-os'
run
[ "$(jsonq .cron)" = installed ] && ok || bad "a cron/ change must render and install (got $(jsonq .cron))"
grep -q 'fleet-propagate.sh' "$T/installed.cron" 2>/dev/null && ok || bad "the rendered crontab must be what got installed"
# and the guard: a render that would drop a LIVE triage lane installs nothing.
rm -f "$T/installed.cron"
printf '2,12 * * * * /root/harness/bin/run-triage.sh alpha-os\n5,15 * * * * /root/harness/bin/run-triage.sh beta\n' > "$T/livecron"
commit cron/hub.cron '# v3
2,12 * * * * /root/harness/bin/run-triage.sh alpha-os'
run
[ "$(jsonq .cron)" = "refused-would-drop-a-live-lane" ] && ok \
  || bad "a render missing a LIVE lane must be refused (got $(jsonq .cron))"
[ ! -f "$T/installed.cron" ] && ok || bad "a refused render must install nothing"
grep -q -- '--critical' "$T/alerts" && ok || bad "a refused crontab must not pass silently: $(cat "$T/alerts")"
printf '2,12 * * * * /root/harness/bin/run-triage.sh alpha-os\n' > "$T/livecron"

# ── 4. one box fails: exactly one --critical alert, naming it ───────────────
commit bin/run-build.sh "echo v3"
SSH_FAIL_IP=10.0.0.2 run
[ "$(nalert)" = 1 ] && ok || bad "a failed box must still produce exactly ONE alert (got $(nalert))"
grep -q -- '--critical' "$T/alerts" && ok || bad "a failed box must be --critical: $(cat "$T/alerts")"
grep -q 'box-beta(rc=7)' "$T/alerts" && ok \
  || bad "the alert must name the box and its rc: $(cat "$T/alerts")"
[ "$(jsonq '.boxes["box-beta"].rc')" = 7 ] && ok || bad "the box's rc must reach the record"
[ "$(jsonq '.boxes["box-alpha"].rc')" = 0 ] && ok || bad "the healthy box must still be ok"
grep -q '1/2 boxes synced' "$T/alerts" && ok || bad "the alert must not round a partial up: $(cat "$T/alerts")"
grep -q -- '--log-only' "$T/alerts" && bad "BH-2337: a partial propagate must stay an alert, never --log-only: $(cat "$T/alerts")" || ok

# ── 5. project-6's warm-bake failure is now reported honestly (BH-407) ─────
commit bin/run-build.sh "echo v4"
# BH-3680: first-fail paging pinned; the default (warn while a retry is queued) is tests/fleet-propagate.bh-3680-test.sh
PROPAGATE_PAGE_ON_FIRST_FAIL=1 BAKE_FAIL=project-6 run
[ "$(jsonq '.pools["project-6"].status')" = "fail" ] && ok \
  || bad "project-6 must be recorded fail (got $(jsonq '.pools["project-6"].status'))"
[ "$(nalert)" = 1 ] && ok || bad "still exactly one alert (got $(nalert))"
grep -q -- '--critical' "$T/alerts" && ok \
  || bad "project-6's warm-bake failure must now make the run critical: $(cat "$T/alerts")"
grep -q 'known-fail' "$T/alerts" && bad "the alert must not say known-fail: $(cat "$T/alerts")" || ok
# and a DIFFERENT pool failing is still critical
commit bin/run-build.sh "echo v5"
# BH-3680: first-fail paging pinned; the default (warn while a retry is queued) is tests/fleet-propagate.bh-3680-test.sh
PROPAGATE_PAGE_ON_FIRST_FAIL=1 BAKE_FAIL=alpha-os run
grep -q -- '--critical' "$T/alerts" && ok || bad "a non-project-6 pool failure must be critical: $(cat "$T/alerts")"

# ── 6. the lock: a tick that lands on a running propagation leaves ───────────
commit bin/run-build.sh "echo v6"
BEFORE=$(jsonq .last_sha)
# The holder keeps the flock until the test removes $HOLD, and the test waits
# for the "held" marker before running — a fixed sleep on either side is a race.
HOLD="$T/hold-lock"; HELD="$T/lock-held"
: > "$HOLD"; rm -f "$HELD"
(
  exec 9>"$H/locks/fleet-propagate.lock"
  flock 9
  : > "$HELD"
  while [ -e "$HOLD" ]; do sleep 0.1; done
) &
HOLDER=$!
for _i in $(seq 1 100); do [ -e "$HELD" ] && break; sleep 0.1; done
[ -e "$HELD" ] && ok || bad "the lock holder never acquired the lock"
run; RC=$?
[ "$RC" = 0 ] && ok || bad "a held lock must exit 0, not error (rc=$RC)"
[ "$(nssh)" = 0 ] && [ "$(nbake)" = 0 ] && ok || bad "a held lock must not pile a second propagation on"
[ "$(jsonq .last_sha)" = "$BEFORE" ] && ok || bad "a deferred tick must not advance last_sha"
rm -f "$HOLD"; wait "$HOLDER" 2>/dev/null

# ── 7. --check writes nothing ───────────────────────────────────────────────
snapshot() { find "$H/state" "$H/logs" -type f -exec md5sum {} \; 2>/dev/null | sort; }
BEFORE_SNAP=$(snapshot)
run --check; RC=$?
[ "$RC" = 0 ] && ok || bad "--check must exit 0 (rc=$RC)"
[ "$(snapshot)" = "$BEFORE_SNAP" ] && ok || bad "--check wrote to \$H/state or \$H/logs:
$(diff <(printf '%s\n' "$BEFORE_SNAP") <(snapshot))"
[ "$(nssh)" = 0 ] && [ "$(nbake)" = 0 ] && ok || bad "--check must not ssh or bake"
grep -q 'bin/run-build.sh' "$T/out" && ok || bad "--check must print the changed fleet paths: $(cat "$T/out")"
grep -q 'box-alpha' "$T/out" && ok || bad "--check must print the boxes it would sync: $(cat "$T/out")"
grep -q 'project-6' "$T/out" && ok || bad "--check must print the pools it would rebake: $(cat "$T/out")"

# ── 8. side branch guard: clean + unused forces back to main ────────────────
commit bin/run-build.sh "echo v8"
GCHECK="$T/checkout-pr908"
HARNESS_CHECKOUT="$GCHECK" run; RC=$?
[ "$RC" = 0 ] && ok || bad "a clean unused side branch must exit 0 (rc=$RC)"
[ "$(jsonq .hub)" = ok ] && ok || bad "a clean side branch forced back to main must record hub=ok (got $(jsonq .hub))"
[ "$(jsonq .hub_reason)" = "" ] && ok || bad "a clean success must leave hub_reason empty (got '''$(jsonq .hub_reason)''')"
grep -q 'forced back to main' "$H/logs/fleet-propagate.log" && ok || bad "the log must say the checkout was forced back to main"
[ "$(git -C "$GCHECK" branch --show-current 2>/dev/null)" = main ] && ok || bad "the guard checkout must end on main"

# ── 8b. detached HEAD is "not main" too: `branch --show-current` prints empty
#        with rc 0 there, which used to skip the guard entirely ──────────────
commit bin/run-build.sh "echo v8b"
git -C "$GCHECK" checkout -q --detach
HARNESS_CHECKOUT="$GCHECK" run; RC=$?
[ "$RC" = 0 ] && ok || bad "a clean unused detached HEAD must exit 0 (rc=$RC)"
[ "$(jsonq .hub)" = ok ] && ok || bad "a detached HEAD forced back to main must record hub=ok (got $(jsonq .hub))"
grep -q 'checkout was on HEAD, forced back to main' "$H/logs/fleet-propagate.log" && ok || bad "the log must name the detached HEAD as HEAD"
[ "$(git -C "$GCHECK" branch --show-current 2>/dev/null)" = main ] && ok || bad "the detached checkout must end on main"

# ── 9. side branch guard: dirty tree refuses and stays dirty ─────────────────
commit bin/run-build.sh "echo v9"
BEFORE=$(jsonq .last_sha)
GCHECK="$T/checkout-pr909"
HARNESS_CHECKOUT="$GCHECK" run; RC=$?
[ "$RC" = 0 ] && ok || bad "a dirty side branch must exit 0 (rc=$RC)"
[ "$(jsonq .hub)" = fail ] && ok || bad "a dirty side branch must record hub=fail (got $(jsonq .hub))"
[ "$(jsonq .hub_reason)" = "checkout on pr909, dirty" ] && ok || bad "hub_reason must name branch and dirty (got '''$(jsonq .hub_reason)''')"
grep -q 'checkout on pr909 (dirty)' "$H/logs/fleet-propagate.log" && ok || bad "log must name the dirty branch"
[ -f "$GCHECK/dirty" ] && ok || bad "the dirty file must not be removed"
[ "$(git -C "$GCHECK" branch --show-current 2>/dev/null)" = pr909 ] && ok || bad "the guard checkout must stay on the dirty branch"
# A refusal STOPS the tick: nothing is ssh'd or baked, the missed range is kept.
[ "$(nssh)" = 0 ] && ok || bad "a refused tick must ssh NO box (got $(nssh): $(cat "$T/ssh.calls"))"
[ "$(nbake)" = 0 ] && ok || bad "a refused tick must rebake NO image (got $(nbake): $(cat "$T/bake.calls"))"
[ "$(jsonq .last_sha)" = "$BEFORE" ] && ok || bad "a refused tick must not advance last_sha (got $(jsonq .last_sha), want $BEFORE)"
[ "$(nalert)" = 1 ] && grep -q -- '--critical' "$T/alerts" && ok || bad "a refused tick is exactly one --critical alert (got $(nalert): $(cat "$T/alerts"))"

# ── 9b. dirty branch with NOTHING new: still 0 ssh, 0 bakes, no dirty marks ──
# NEW = LAST used to skip the drain short-circuit (HUB != ok) and fall through
# into a full propagation at an unchanged sha, every five minutes.
NEW=$(git -C "$T/src" rev-parse HEAD)
jq --arg s "$NEW" '.last_sha=$s' "$H/state/fleet-propagate.json" > "$H/state/fp.tmp" && mv "$H/state/fp.tmp" "$H/state/fleet-propagate.json"
rm -f "$H"/state/fly/*.image-dirty 2>/dev/null
HARNESS_CHECKOUT="$GCHECK" run; RC=$?
[ "$RC" = 0 ] && ok || bad "a refused no-change tick must exit 0 (rc=$RC)"
[ "$(jsonq .hub)" = fail ] && ok || bad "a refused no-change tick must record hub=fail (got $(jsonq .hub))"
[ "$(nssh)" = 0 ] && ok || bad "a refused no-change tick must ssh NO box (got $(nssh))"
[ "$(nbake)" = 0 ] && ok || bad "a refused no-change tick must rebake NO image (got $(nbake))"
[ -z "$(ls "$H"/state/fly/*.image-dirty 2>/dev/null)" ] && ok || bad "a refused tick must leave no image-dirty markers: $(ls "$H"/state/fly/ 2>/dev/null)"
[ "$(jsonq .last_sha)" = "$NEW" ] && ok || bad "a refused no-change tick must keep last_sha (got $(jsonq .last_sha))"

# ── 10. side branch guard: in-use checkout refuses ──────────────────────────
commit bin/run-build.sh "echo v10"
GCHECK="$T/checkout-pr910"
# exec, so the pid we kill IS the process holding the cwd (not a subshell that
# would leave its sleep sitting in $T past teardown).
( cd "$GCHECK" && exec sleep 10 ) & INUSE=$!
for _i in $(seq 1 100); do [ "$(readlink /proc/$INUSE/cwd 2>/dev/null)" -ef "$GCHECK" ] && break; sleep 0.1; done
[ "$(readlink /proc/$INUSE/cwd 2>/dev/null)" -ef "$GCHECK" ] && ok || bad "the in-use holder never reached $GCHECK"
HARNESS_CHECKOUT="$GCHECK" run; RC=$?
kill "$INUSE" 2>/dev/null; wait "$INUSE" 2>/dev/null
[ "$RC" = 0 ] && ok || bad "an in-use side branch must exit 0 (rc=$RC)"
[ "$(jsonq .hub)" = fail ] && ok || bad "an in-use side branch must record hub=fail (got $(jsonq .hub))"
[ -n "$(jsonq .hub_reason)" ] && grep -q 'checkout on pr910, in-use by pid' <<<"$(jsonq .hub_reason)" && ok || bad "hub_reason must name branch and in-use pid (got '''$(jsonq .hub_reason)''')"
grep -q 'checkout on pr910 (in-use' "$H/logs/fleet-propagate.log" && ok || bad "log must name the in-use branch"
git -C "$GCHECK" checkout -q main
git -C "$GCHECK" branch -D pr910 2>/dev/null || true
echo "fleet-propagate-test: $PASS pass, $FAIL fail"
[ "$FAIL" = 0 ]
