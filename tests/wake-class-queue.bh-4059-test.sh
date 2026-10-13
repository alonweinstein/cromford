#!/bin/bash
# tests/wake-class-queue.bh-4059-test.sh — a `queue` wake (a fly build landing
# in build_queue) launches fly-dispatch and fly-pool-tick on the hub, once per
# drain however many wakes it holds; unarmed, off the hub, or under
# flags/wake-lanes-off it asks for nothing and launches nothing (BH-4169, the
# first slice of BH-4059).
#
# Drives the REAL bin/wake-loop.sh, bin/lib/wake-class-queue.sh and
# bin/jobs-client.sh against tests/lib/wake-claim-stub.sh, with recorders for
# the lanes it may launch. flag_active reads flags/<name>.
#
# Run from anywhere: HARNESS_TEST_SANDBOX=1 bash tests/wake-class-queue.bh-4059-test.sh
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
unset WAKE_CLAIM_LIMIT HUB_BOX_NAME CLAIM_ALL COOL_MODE CLAIM_MODE CURSOR_PUT_MODE CURSOR_GET_MODE
export BOX_NAME=box-hub

# The real loop, the wake-classes lib and the class under test.
cp "$DIR/bin/wake-loop.sh" "$T/bin/wake-loop.sh"
cp "$DIR/bin/lib/wake-lanes.sh" "$T/bin/lib/wake-lanes.sh"
[ -f "$DIR/bin/lib/wake-class-queue.sh" ] && cp "$DIR/bin/lib/wake-class-queue.sh" "$T/bin/lib/wake-class-queue.sh"
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

Q() { printf '{"id":%s,"repo":"harness/build-queue","kind":"queue","key":"%s","event":"build_queue.insert","at":"2026-10-03T20:40:04Z"}' "$1" "${2:-project-3:TK-1}"; }
P() { printf '{"id":%s,"repo":"example-org/project-3","kind":"pr","key":"%s","event":"pull_request.synchronize","at":"2026-10-03T20:40:04Z"}' "$1" "${2:-7}"; }
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
# The kinds_all_repos of the FIRST claim this run sent, as compact JSON.
claim_kinds() { wcs_log | sed -n 's#^POST /api/wakes/claim ##p' | head -1 | jq -c '.kinds_all_repos' 2>/dev/null; }

# --- AT-S1: armed hub, one queue row -> fly-dispatch + fly-pool-tick once ----
reset
touch "$T/flags/wake-lanes-queue"
wakes "$(Q 1)"
run
[ "$(calls fly-dispatch)" = 1 ] && ok || bad "S1a one queue wake must launch fly-dispatch once (got $(calls fly-dispatch))"
[ "$(calls fly-pool-tick)" = 1 ] && ok || bad "S1b one queue wake must launch fly-pool-tick once (got $(calls fly-pool-tick))"
[ "$(calls fly-results-ingest)" = 0 ] && ok || bad "S1c fly-results-ingest has no lock of its own and must not be wake-launched (got $(calls fly-results-ingest))"
LOG | grep -q 'wake classes armed:.* queue' && ok || bad "S1d the armed line must name queue: $(LOG | grep armed)"
grep -qE 'not a fleet repo|unknown kind' <<<"$(LOG)" && bad "S1e the queue row was dropped by the generic path: $(LOG | grep -E 'not a fleet repo|unknown kind')" || ok
# TEST-CHANGE (BH-4057): the hub also claims every repo's lead-land rows, because only the hub lands.
[ "$(claim_kinds)" = '["pr","checks","lead-land","queue"]' ] && ok || bad "S1f the hub's claim must ask for queue rows (kinds_all_repos=$(claim_kinds))"
LOG | grep -q 'queue\[fleet\] (1 wake(s)): launched fly-dispatch.sh' && ok || bad "S1g the launch line must say queue[fleet] (1 wake(s)): $(LOG | grep 'queue\[')"

# --- AT-S2: five queue rows in one drain -> one launch of each ---------------
reset
touch "$T/flags/wake-lanes-queue"
wakes "$(Q 1 project-3:TK-1)" "$(Q 2 project-3:TK-2)" "$(Q 3 project-3:TK-3)" "$(Q 4 project-4:TK-9)" "$(Q 5 project-3:build-x)"
run
[ "$(calls fly-dispatch)" = 1 ] && ok || bad "S2a five wakes in one drain must launch fly-dispatch once (got $(calls fly-dispatch))"
[ "$(calls fly-pool-tick)" = 1 ] && ok || bad "S2b five wakes in one drain must launch fly-pool-tick once (got $(calls fly-pool-tick))"
LOG | grep -q 'queue\[fleet\] (5 wake(s))' && ok || bad "S2c the launch line must count the 5 coalesced wakes: $(LOG | grep 'queue\[')"

# --- AT-S3: unarmed -> nothing asked, nothing launched; kill switch beats arm -
reset
wakes "$(Q 1)"
run
[ "$(calls fly-dispatch)$(calls fly-pool-tick)" = 00 ] && ok || bad "S3a an unarmed class must launch nothing (dispatch=$(calls fly-dispatch) pool=$(calls fly-pool-tick))"
# TEST-CHANGE (BH-4057): the hub also claims every repo's lead-land rows, because only the hub lands.
[ "$(claim_kinds)" = '["pr","checks","lead-land"]' ] && ok || bad "S3b an unarmed class must leave the claim byte-identical (kinds_all_repos=$(claim_kinds))"
reset
touch "$T/flags/wake-lanes-queue" "$T/flags/wake-lanes-off"
wakes "$(Q 1)"
run
[ "$(calls fly-dispatch)$(calls fly-pool-tick)" = 00 ] && ok || bad "S3c wake-lanes-off must beat the class flag (dispatch=$(calls fly-dispatch))"
# TEST-CHANGE (BH-4057): the hub also claims every repo's lead-land rows, because only the hub lands.
[ "$(claim_kinds)" = '["pr","checks","lead-land"]' ] && ok || bad "S3d wake-lanes-off must leave the claim byte-identical (kinds_all_repos=$(claim_kinds))"

# --- AT-S4: off the hub -> no queue kind claimed, nothing launched ------------
reset
touch "$T/flags/wake-lanes-queue"
wakes "$(Q 1)"
BOX_NAME=box-project-3-2 run
[ "$(calls fly-dispatch)$(calls fly-pool-tick)" = 00 ] && ok || bad "S4a a non-hub box must not launch the fly lanes (dispatch=$(calls fly-dispatch))"
grep -q '"queue"' <<<"$(wcs_log | grep '^POST /api/wakes/claim')" && bad "S4b a non-hub claim must not ask for queue rows: $(wcs_log | grep claim | head -1)" || ok
# And the loop's own guard, against a mis-filtering worker that hands one over.
reset
touch "$T/flags/wake-lanes-queue"
wakes "$(Q 1)"
CLAIM_ALL=1 BOX_NAME=box-project-3-2 run
[ "$(calls fly-dispatch)$(calls fly-pool-tick)" = 00 ] && ok || bad "S4c a queue row a non-hub box was handed anyway must launch nothing (dispatch=$(calls fly-dispatch))"
# Not even an attempt: launch() would refuse a hub lane here too, so the line
# is what proves the class itself stood down rather than leaning on that.
grep -q 'queue\[fleet\]' <<<"$(LOG)" && bad "S4d a non-hub box must not try a queue launch: $(LOG | grep 'queue\[')" || ok

# --- AT-S6: the conductor path is untouched by queue rows beside it ----------
reset
touch "$T/flags/wake-lanes-queue"
wakes "$(Q 1)" "$(P 2 7)" "$(Q 3 project-3:TK-2)"
run
[ "$(calls merge-conductor)" = 1 ] && ok || bad "S6a a pr wake beside queue wakes must still launch merge-conductor once (got $(calls merge-conductor))"
[ "$(calls fly-dispatch)" = 1 ] && ok || bad "S6b and the queue wakes still launch fly-dispatch once (got $(calls fly-dispatch))"

echo "wake-class-queue.bh-4059-test: $PASS pass, $FAIL fail"
[ "$FAIL" -eq 0 ]
