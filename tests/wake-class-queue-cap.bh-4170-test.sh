#!/bin/bash
# tests/wake-class-queue-cap.bh-4170-test.sh — the queue wake class's
# per-invocation cap WAKE_QUEUE_PER_TICK (default 1, 0 = unlimited, a
# non-number is 1 said once). A launch over the cap writes
# state/wake-queue-owed, and the next invocation's first drain pays it, even
# an empty one; the marker clears only when a lane actually started (BH-4170,
# slice 2 of BH-4059).
#
# Drives the REAL bin/wake-loop.sh, bin/lib/wake-class-queue.sh and
# bin/jobs-client.sh against tests/lib/wake-claim-stub.sh, with recorders for
# the lanes it may launch. WAKE_LOOP_CYCLES=N with WAKE_CLAIM_LIMIT=1 gives
# one fresh queue row to each of N drains of ONE invocation.
#
# Run from anywhere: HARNESS_TEST_SANDBOX=1 bash tests/wake-class-queue-cap.bh-4170-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
. "$(dirname "$0")/lib/wake-claim-stub.sh" || exit 1
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }

export HARNESS="$T"
mkdir -p "$T/bin/lib/jobs" "$T/env" "$T/logs" "$T/locks" "$T/state" "$T/flags" "$T/calls"
printf 'HARNESS_SECRET=s\nJOBS_URL=https://jobs.test\n' > "$T/env/global.env"
export WAKE_LOOP_CYCLES=1 WAKE_LOOP_INTERVAL_S=0
unset WAKE_CLAIM_LIMIT WAKE_QUEUE_PER_TICK HUB_BOX_NAME CLAIM_ALL COOL_MODE CLAIM_MODE CURSOR_PUT_MODE CURSOR_GET_MODE
export BOX_NAME=box-hub

cp "$DIR/bin/wake-loop.sh" "$T/bin/wake-loop.sh"
cp "$DIR/bin/lib/wake-lanes.sh" "$T/bin/lib/wake-lanes.sh"
cp "$DIR/bin/lib/wake-class-queue.sh" "$T/bin/lib/wake-class-queue.sh"
cp "$DIR/bin/jobs-client.sh" "$T/bin/"
cp "$DIR"/bin/lib/jobs/*.sh "$T/bin/lib/jobs/"
wcs_install "$T/bin"
wcs_identity "$T/bin" || { echo "wcs_identity failed"; exit 1; }

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
printf '#!/bin/bash\nexit 1\n' > "$T/bin/unblocked-children.sh"
printf '#!/bin/bash\necho "[]"\n' > "$T/bin/gh"
printf '#!/bin/bash\nexec "$@"\n' > "$T/bin/setsid"
chmod +x "$T/bin/unblocked-children.sh" "$T/bin/gh" "$T/bin/setsid"
for s in fly-dispatch fly-pool-tick fly-results-ingest merge-conductor deploy-train postmerge-qa run-triage; do
  printf '#!/bin/bash\necho "$*" >> "$HARNESS/calls/%s"\n' "$s" > "$T/bin/$s.sh"
  chmod +x "$T/bin/$s.sh"
done

Q() { printf '{"id":%s,"repo":"harness/build-queue","kind":"queue","key":"%s","event":"build_queue.insert","at":"2026-10-03T20:40:04Z"}' "$1" "${2:-project-3:TK-$1}"; }
wakes() { printf '{"wakes":[%s]}' "$(printf '%s,' "$@" | sed 's/,$//')" > "$T/wakes.json"; }
reset() {
  rm -rf "$T/calls" "$T/state" "$T/flags" "$T/logs"
  mkdir -p "$T/calls" "$T/state" "$T/flags" "$T/logs"
  printf '{"wakes":[]}' > "$T/wakes.json"
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
LOG() { cat "$T/logs/wake-loop.log" 2>/dev/null; }
# A count, never a pipe into grep -q (a negative under pipefail is SIGPIPE-prone).
nlog() { local out; out=$(LOG); grep -c -- "$1" <<<"$out"; }
OWED="$T/state/wake-queue-owed"
HELD='queue: fly launch held — per-tick cap 1 reached'

# --- C1: cap 1, a fresh queue row in each of two drains -> one launch, owed --
reset
touch "$T/flags/wake-lanes-queue"
wakes "$(Q 1)" "$(Q 2)"
WAKE_QUEUE_PER_TICK=1 WAKE_LOOP_CYCLES=2 WAKE_CLAIM_LIMIT=1 run
[ "$(nlog 'queue\[fleet\] (1 wake(s)): launched fly-dispatch.sh')" = 1 ] && ok || bad "C1 setup: drain 1 must launch on its own row: $(LOG | grep 'queue')"
[ "$(calls fly-dispatch)" = 1 ] && ok || bad "C1a cap 1 must allow ONE fly-dispatch launch per invocation (got $(calls fly-dispatch))"
[ "$(calls fly-pool-tick)" = 1 ] && ok || bad "C1a cap 1 must allow ONE fly-pool-tick launch per invocation (got $(calls fly-pool-tick))"
[ -e "$OWED" ] && ok || bad "C1b the held launch must write state/wake-queue-owed"
[ "$(nlog "$HELD")" = 1 ] && ok || bad "C1b one held line expected (got $(nlog "$HELD")): $(LOG | grep 'queue')"

# --- C1c/C1d: the next invocation's EMPTY drain pays the debt ----------------
printf '{"wakes":[]}' > "$T/wakes.json"
WAKE_QUEUE_PER_TICK=1 WAKE_LOOP_CYCLES=1 run
[ "$(nlog 'queue\[fleet\] (owed): launched fly-dispatch.sh')" = 1 ] && ok || bad "C1c an empty next drain must pay the owed launch: $(LOG | grep 'queue')"
[ "$(calls fly-dispatch)$(calls fly-pool-tick)" = 22 ] && ok || bad "C1c the owed pay must launch both lanes (dispatch=$(calls fly-dispatch) pool=$(calls fly-pool-tick))"
[ -e "$OWED" ] && bad "C1d the marker must be gone once a lane started" || ok

# --- C1e: three drains held past the cap -> still one held line, one launch --
reset
touch "$T/flags/wake-lanes-queue"
wakes "$(Q 1)" "$(Q 2)" "$(Q 3)"
WAKE_QUEUE_PER_TICK=1 WAKE_LOOP_CYCLES=3 WAKE_CLAIM_LIMIT=1 run
[ "$(nlog 'queue\[fleet\] (1 wake(s)): launched')" -ge 1 ] && ok || bad "C1e setup: the drains must see their rows: $(LOG | grep 'queue')"
[ "$(calls fly-dispatch)" = 1 ] && ok || bad "C1e three drains under cap 1 must launch once (got $(calls fly-dispatch))"
[ "$(nlog "$HELD")" = 1 ] && ok || bad "C1e one held line per invocation (got $(nlog "$HELD"))"
[ -e "$OWED" ] && ok || bad "C1e the marker must stay owed"

# --- C2: a non-number is 1 (said once), never 0; 0 is unlimited -------------
reset
touch "$T/flags/wake-lanes-queue"
wakes "$(Q 1)" "$(Q 2)" "$(Q 3)"
WAKE_QUEUE_PER_TICK=abc WAKE_LOOP_CYCLES=3 WAKE_CLAIM_LIMIT=1 run
[ "$(calls fly-dispatch)" = 1 ] && [ -e "$OWED" ] && ok || bad "C2a WAKE_QUEUE_PER_TICK=abc must act as 1 (dispatch=$(calls fly-dispatch), owed=$([ -e "$OWED" ] && echo y || echo n))"
[ "$(nlog "WAKE_QUEUE_PER_TICK='abc' is not a number — using 1")" = 1 ] && ok || bad "C2b one not-a-number line per invocation (got $(nlog 'is not a number'))"
reset
touch "$T/flags/wake-lanes-queue"
wakes "$(Q 1)" "$(Q 2)"
WAKE_QUEUE_PER_TICK=0 WAKE_LOOP_CYCLES=2 WAKE_CLAIM_LIMIT=1 run
[ "$(calls fly-dispatch)" = 2 ] && ok || bad "C2c WAKE_QUEUE_PER_TICK=0 must be unlimited (dispatch=$(calls fly-dispatch))"
[ -e "$OWED" ] && bad "C2c unlimited must write no marker" || ok
[ "$(nlog 'fly launch held')" = 0 ] && ok || bad "C2c unlimited must hold nothing: $(LOG | grep held)"

# --- C3: the debt clears only when a lane actually started ------------------
reset
touch "$T/flags/wake-lanes-queue" "$OWED"
chmod -x "$T/bin/fly-dispatch.sh" "$T/bin/fly-pool-tick.sh"
run
[ -e "$OWED" ] && ok || bad "C3a an owed pay where no lane could start must stay owed"
[ "$(calls fly-dispatch)$(calls fly-pool-tick)" = 00 ] && ok || bad "C3a nothing could start, nothing recorded"
[ "$(nlog 'queue\[fleet\] (owed): .*not executable')" -ge 1 ] && ok || bad "C3a the owed pay must have been attempted: $(LOG | grep 'queue')"
chmod +x "$T/bin/fly-dispatch.sh" "$T/bin/fly-pool-tick.sh"
run
[ "$(calls fly-dispatch)" = 1 ] && ok || bad "C3b once the lanes can start the owed pay launches (got $(calls fly-dispatch))"
[ -e "$OWED" ] && bad "C3b the marker must be gone after a lane started" || ok

# --- C4: the knob is registered where the lib reads it -----------------------
jq -e '.knobs[]|select(.env=="WAKE_QUEUE_PER_TICK")|select(.type=="int" and .default==1 and .min==0 and .max==60 and .read_in=="bin/lib/wake-class-queue.sh")' \
  "$DIR/catalog/lanes.d/wake-loop.json" >/dev/null && ok || bad "C4 WAKE_QUEUE_PER_TICK must be registered on wake-loop (int, default 1, 0..60, read_in the lib)"

# --- C5: off the hub -> no cap, no marker activity --------------------------
reset
touch "$T/flags/wake-lanes-queue" "$OWED"
touch -d '2026-01-01T00:00:00Z' "$OWED"
before=$(stat -c %Y "$OWED")
WAKE_QUEUE_PER_TICK=abc BOX_NAME=box-project-3-2 run
[ "$(nlog 'queue\[fleet\]')" = 0 ] && ok || bad "C5a a non-hub box must not try a queue launch: $(LOG | grep 'queue\[')"
[ "$(nlog 'is not a number')" = 0 ] && ok || bad "C5b a non-hub box must not read the cap"
[ -e "$OWED" ] && [ "$(stat -c %Y "$OWED")" = "$before" ] && ok || bad "C5c a non-hub box must leave the marker untouched"

echo "wake-class-queue-cap.bh-4170-test: $PASS pass, $FAIL fail"
[ "$FAIL" -eq 0 ]
