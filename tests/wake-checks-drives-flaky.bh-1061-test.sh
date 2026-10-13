#!/bin/bash
# tests/wake-checks-drives-flaky.bh-1061-test.sh — check_suite.completed wakes
# drive flaky-detect once per project, per the BH-1061 contract.
#
# flaky-detect is a hub lane, so the loop runs as the hub (box-hub),
# which claims every repo's checks rows (BH-2637); the worker is
# tests/lib/wake-claim-stub.sh and the flaky-detect cooldown is its row.
#
# Run from anywhere: HARNESS_TEST_SANDBOX=1 bash tests/wake-checks-drives-flaky.bh-1061-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
. "$(dirname "$0")/lib/wake-claim-stub.sh" || exit 1
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }

export HARNESS="$T"
mkdir -p "$T/bin" "$T/bin/lib" "$T/env" "$T/logs" "$T/locks" "$T/state" "$T/flags" "$T/calls" "$T/fakebin"
printf 'HARNESS_SECRET=s\nJOBS_URL=https://jobs.test\n' > "$T/env/global.env"
export WAKE_LOOP_CYCLES=1 WAKE_LOOP_INTERVAL_S=0
unset WAKE_CLAIM_LIMIT HUB_BOX_NAME CLAIM_ALL COOL_MODE CLAIM_MODE CURSOR_PUT_MODE CURSOR_GET_MODE
export BOX_NAME=box-hub

# Real loop and lib.
cp "$DIR/bin/wake-loop.sh"   "$T/bin/wake-loop.sh"
cp "$DIR/bin/lib/wake-lanes.sh" "$T/bin/lib/wake-lanes.sh"
[ -f "$DIR/bin/lib/wake-class-flaky.sh" ] && cp "$DIR/bin/lib/wake-class-flaky.sh" "$T/bin/lib/wake-class-flaky.sh"

# The REAL jobs-client: the wake routes go to the stub worker, and flag_active
# reads flags/<name> (the flag sync's `{}` answer leaves the files alone).
mkdir -p "$T/bin/lib/jobs"
cp "$DIR/bin/jobs-client.sh" "$T/bin/"
cp "$DIR"/bin/lib/jobs/*.sh "$T/bin/lib/jobs/"
wcs_install "$T/bin"
wcs_identity "$T/bin" || { echo "wcs_identity failed"; exit 1; }

# Registry with one project on another box. flaky-detect is a hub lane, so the
# hub's loop launches it for that project; we assert the local recorder.
cat > "$T/bin/fleet-conf.sh" <<'SH'
#!/bin/bash
[ "$1" = "--projects" ] && { printf 'project-3\n'; exit 0; }
case "$1/$2" in
  project-3/repo) echo example-org/project-3 ;;
  project-3/box)  echo box-project-3-2 ;;
  project-3/board_prefix) echo /api/feature-board ;;
  *) exit 1 ;;
esac
SH
chmod +x "$T/bin/fleet-conf.sh"

cat > "$T/bin/unblocked-children.sh" <<'SH'
#!/bin/bash
exit 1
SH
chmod +x "$T/bin/unblocked-children.sh"

# Recorders for legacy lanes and the flaky lane.
for s in merge-conductor deploy-train postmerge-qa run-triage; do
  cat > "$T/bin/$s.sh" <<SH
#!/bin/bash
echo "\$*" >> "\$HARNESS/calls/$s"
SH
  chmod +x "$T/bin/$s.sh"
done
cat > "$T/bin/flaky-detect.sh" <<'SH'
#!/bin/bash
echo "$*" >> "$HARNESS/calls/flaky-detect"
SH
chmod +x "$T/bin/flaky-detect.sh"

# curl (every wake route is the stub worker's), gh, ssh, setsid.
cat > "$T/bin/curl" <<'SH'
#!/bin/bash
"$(dirname "$0")/wcs-routes" "$@" && exit 0
printf '{}\n200'
SH
chmod +x "$T/bin/curl"

cat > "$T/bin/ssh" <<'SH'
#!/bin/bash
echo "$*" >> "$HARNESS/calls/ssh"
SH
chmod +x "$T/bin/ssh"

cat > "$T/bin/gh" <<'SH'
#!/bin/bash
echo "$*" >> "$HARNESS/calls/gh"
echo '[]'
SH
chmod +x "$T/bin/gh"

cat > "$T/bin/setsid" <<'SH'
#!/bin/bash
exec "$@"
SH
chmod +x "$T/bin/setsid"

W() { printf '{"id":%s,"repo":"%s","kind":"%s","key":"%s","event":"%s","at":"2026-09-19T11:39:04Z"}' "$1" "${2:-example-org/project-3}" "$3" "${4:-key}" "${5:-check_suite.completed}"; }
wakes() { printf '{"wakes":[%s]}' "$(printf '%s,' "$@" | sed 's/,$//')" > "$T/wakes.json"; }
reset() {
  rm -rf "$T/calls" "$T/state" "$T/flags" "$T/logs"
  mkdir -p "$T/calls" "$T/state" "$T/flags" "$T/logs"
}
settle() {
  local prev="" cur i
  for i in $(seq 1 12); do
    sleep 0.25
    cur=$(cat "$T/calls/"* 2>/dev/null | wc -c | tr -d ' ')
    [ "$cur" = "$prev" ] && [ "$i" -ge 2 ] && return 0
    prev="$cur"
  done
  return 0
}
run() { PATH="$T/bin:$PATH" "$T/bin/wake-loop.sh"; RC=$?; settle; return "$RC"; }
calls() { [ -f "$T/calls/$1" ] && wc -l < "$T/calls/$1" | tr -d ' ' || echo 0; }

# ---------------------------------------------------------------------------
# 1. flag on + check_suite.completed -> one flaky-detect call with --days 1
# ---------------------------------------------------------------------------
reset
touch "$T/flags/wake-lanes-flaky"
wakes "$(W 1 example-org/project-3 checks suite1 check_suite.completed)"
run
[ "$(calls flaky-detect)" = 1 ] && ok || bad "check_suite.completed must call flaky-detect once (got $(calls flaky-detect))"
grep -qx 'project-3 --days 1' "$T/calls/flaky-detect" && ok || bad "flaky-detect argv must be 'project-3 --days 1'"
[ -s "$T/state/wcs/cool/flaky-detect-project-3" ] && grep '/api/wakes/cooldown/take' "$T/state/wcs/curl.log" | grep '"project":"project-3"' | grep -q '21600' && ok || bad "the hub must take the flaky-detect[project-3] cooldown row with the 6h window (requests: $(wcs_log | grep cooldown))"

# ---------------------------------------------------------------------------
# 2. check_run.completed must NOT drive flaky detection
# ---------------------------------------------------------------------------
reset
touch "$T/flags/wake-lanes-flaky"
wakes "$(W 2 example-org/project-3 checks run1 check_run.completed)"
run
[ "$(calls flaky-detect)" = 0 ] && ok || bad "check_run.completed must not call flaky-detect (got $(calls flaky-detect))"

# ---------------------------------------------------------------------------
# 3. two suite rows inside 6h coalesce to one call
# ---------------------------------------------------------------------------
reset
touch "$T/flags/wake-lanes-flaky"
wakes "$(W 3 example-org/project-3 checks suite1 check_suite.completed)" "$(W 4 example-org/project-3 checks suite2 check_suite.completed)"
run
[ "$(calls flaky-detect)" = 1 ] && ok || bad "two suite rows in one drain must coalesce to one flaky-detect (got $(calls flaky-detect))"

# ---------------------------------------------------------------------------
# 4. the conductor count is unchanged (no pr wake -> no merge-conductor)
# ---------------------------------------------------------------------------
reset
touch "$T/flags/wake-lanes-flaky"
wakes "$(W 5 example-org/project-3 checks suite1 check_suite.completed)"
run
[ "$(calls merge-conductor)" = 1 ] && ok || bad "checks wakes must still drive merge-conductor once (got $(calls merge-conductor))"

# ---------------------------------------------------------------------------
# 5. flag off -> 0 flaky calls
# ---------------------------------------------------------------------------
reset
wakes "$(W 6 example-org/project-3 checks suite1 check_suite.completed)"
run
[ "$(calls flaky-detect)" = 0 ] && ok || bad "flag off must suppress flaky-detect (got $(calls flaky-detect))"

# ---------------------------------------------------------------------------
# 6. global wake-lanes-off suppresses the class
# ---------------------------------------------------------------------------
reset
touch "$T/flags/wake-lanes-flaky" "$T/flags/wake-lanes-off"
wakes "$(W 7 example-org/project-3 checks suite1 check_suite.completed)"
run
[ "$(calls flaky-detect)" = 0 ] && ok || bad "wake-lanes-off must suppress flaky-detect (got $(calls flaky-detect))"

# ---------------------------------------------------------------------------
# Second half needs flag_active so the backstop can consult flags/wake-lanes-flaky.
mkdir -p "$T/bin"
cat > "$T/bin/jobs-client.sh" <<'SH'
#!/bin/bash
flag_active() { [ -f "${HARNESS:-/root/harness}/flags/${1:-}" ]; }
SH
chmod +x "$T/bin/jobs-client.sh"

# 7. second half: real flaky-detect.sh flag on + 1h-old stamp -> no gh api call
# ---------------------------------------------------------------------------
reset
touch "$T/flags/wake-lanes-flaky"
mkdir -p "$T/state/wake-ran" "$T/logs"
old=$(date +%s); before=$old; printf '%s' "$(( old - 3600 ))" > "$T/state/wake-ran/flaky-detect-project-3"
mkdir -p "$T/fleet.conf.stub"
printf 'project-3 example-org/project-3 https://project-3.example /api/board 2 box-project-3-2\n' > "$T/fleet.conf"
# Make a fake gh that records calls and a fake fleet-conf.
cat > "$T/fakebin/gh" <<'SH'
#!/bin/bash
printf '%s\n' "$*" >> "$HARNESS/calls/gh-api"
echo '[]'
SH
chmod +x "$T/fakebin/gh"
cat > "$T/fakebin/fleet-conf.sh" <<'SH'
#!/bin/bash
[ "$1" = "--projects" ] && { echo project-3; exit 0; }
case "$1 $2" in
  "project-3 repo") echo example-org/project-3 ;;
esac
SH
chmod +x "$T/fakebin/fleet-conf.sh"
mkdir -p "$T/bin/lib"
cp "$DIR/bin/lib/flaky.sh" "$T/bin/lib/flaky.sh" 2>/dev/null || true
( PATH="$T/fakebin:$T/bin:$PATH" HARNESS="$T" "$DIR/bin/flaky-detect.sh" project-3 ) >/dev/null 2>&1 || true
[ "$(calls gh-api 2>/dev/null || echo 0)" = 0 ] && ok || bad "1h-old stamp with flag on must skip before gh api (got $(calls gh-api 2>/dev/null || echo 0))"

# ---------------------------------------------------------------------------
# 8. second half: WAKE_LAUNCH=1 forces the run
# ---------------------------------------------------------------------------
reset
touch "$T/flags/wake-lanes-flaky"
mkdir -p "$T/state/wake-ran" "$T/logs"
old=$(date +%s); before=$old; printf '%s' "$(( old - 3600 ))" > "$T/state/wake-ran/flaky-detect-project-3"
printf 'project-3 example-org/project-3 https://project-3.example /api/board 2 box-project-3-2\n' > "$T/fleet.conf"
cat > "$T/fakebin/gh" <<'SH'
#!/bin/bash
printf '%s\n' "$*" >> "$HARNESS/calls/gh-api"
echo '[]'
SH
chmod +x "$T/fakebin/gh"
cat > "$T/fakebin/fleet-conf.sh" <<'SH'
#!/bin/bash
[ "$1" = "--projects" ] && { echo project-3; exit 0; }
case "$1 $2" in
  "project-3 repo") echo example-org/project-3 ;;
esac
SH
chmod +x "$T/fakebin/fleet-conf.sh"
mkdir -p "$T/bin/lib"
cp "$DIR/bin/lib/flaky.sh" "$T/bin/lib/flaky.sh" 2>/dev/null || true
( PATH="$T/fakebin:$T/bin:$PATH" HARNESS="$T" WAKE_LAUNCH=1 "$DIR/bin/flaky-detect.sh" project-3 ) >/dev/null 2>&1 || true
new=$(cat "$T/state/wake-ran/flaky-detect-project-3" 2>/dev/null || echo 0)
[ "$new" -ge "$before" ] && ok || bad "WAKE_LAUNCH=1 must refresh the flaky-detect stamp (before=$before initial=$((before-3600)) new=$new)"
[ "$(calls gh-api 2>/dev/null || echo 0)" -ge 1 ] && ok || bad "WAKE_LAUNCH=1 must reach gh api (got $(calls gh-api 2>/dev/null || echo 0))"

# ---------------------------------------------------------------------------
# 9. WC_FLAKEY_PROJECTS resets after dispatch (round-4): a later non-empty
# drain of ANY class must not re-fire a stale project's flaky-detect.
# Exercises the class file's functions directly with cooled()/launch()
# stubbed, so the assertion is not masked by cooled's own real cooldown
# window the way a second real wake-loop.sh drain would be.
# ---------------------------------------------------------------------------
reset
H="$T"; SELF="$T/bin"
. "$DIR/bin/lib/wake-class-flaky.sh"
cooled() { return 0; }
launch() { echo "$*" >> "$T/calls/dispatch-launch"; }
wc_flaky_row project-3 checks k1 check_suite.completed example-org/project-3 1
wc_flaky_dispatch
[ "$(calls dispatch-launch)" = 1 ] && ok || bad "first dispatch must launch flaky-detect once (got $(calls dispatch-launch))"
[ -z "$WC_FLAKEY_PROJECTS" ] && ok || bad "WC_FLAKEY_PROJECTS must reset after dispatch (got '$WC_FLAKEY_PROJECTS')"
before_launch=$(calls dispatch-launch)
wc_flaky_dispatch
[ "$(calls dispatch-launch)" = "$before_launch" ] && ok || bad "empty dispatch must not re-fire flaky-detect (got $(calls dispatch-launch), was $before_launch)"

# ---------------------------------------------------------------------------
echo "wake-checks-drives-flaky.bh-1061-test: $PASS pass, $FAIL fail"
[ "$FAIL" -eq 0 ]
