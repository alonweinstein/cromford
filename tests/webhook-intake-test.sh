#!/bin/bash
# tests/webhook-intake-test.sh — Jira/Linear webhook intake on the jobs worker
# (BH-4079), and the two shell-side promises it leans on.
#
# The receivers live in worker/jobs/src/lib/tracker-webhooks.js and
# worker/jobs/src/routes/webhooks.js; their node suite is
# worker/jobs/test/webhook-intake.bh-4079.test.js, run below. What this file
# adds is the part the node suite cannot see: a tracker webhook only ever turns
# into a wake ROW, and the box side must keep the "events, not polling" bargain:
#   (a) no wake rows -> the REAL bin/wake-loop.sh launches no triage and no
#       model call, and un-brakes no project (no state/wake-<project>);
#   (b) the REAL bin/triage-gate.sh answers SKIP on an unchanged board with no
#       wake file, and RUN event-wake once state/wake-<project> is there.
# Run from anywhere: HARNESS_TEST_SANDBOX=1 bash tests/webhook-intake-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
"$DIR/bin/llm-sites-build.sh" --compose --repo "$DIR" >/dev/null || { echo "FAIL: cannot compose catalog/llm-sites.json"; exit 1; }
. "$(dirname "$0")/lib/wake-claim-stub.sh" || exit 1
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null || { echo "webhook-intake: jq missing — skipping"; exit 0; }

LIB="$DIR/worker/jobs/src/lib/tracker-webhooks.js"
ROUTE="$DIR/worker/jobs/src/routes/webhooks.js"
NODE_TEST="$DIR/worker/jobs/test/webhook-intake.bh-4079.test.js"

# --- 1: the receivers exist ---------------------------------------------------
[ -f "$DIR/worker/jobs/src/lib/tracker-webhooks.js" ] && ok || bad "missing $LIB"
[ -f "$DIR/worker/jobs/src/routes/webhooks.js" ] && ok || bad "missing $ROUTE"

# --- 2: the node suite --------------------------------------------------------
if ! command -v node >/dev/null 2>&1; then
  echo "webhook-intake: node suite SKIPPED — node is not installed on this box"
elif [ "$(node -p 'process.versions.node.split(".")[0]')" -lt 22 ]; then
  echo "webhook-intake: node suite SKIPPED — node < 22 has no node:sqlite"
elif ! "$DIR/bin/lanes-build.sh" --root "$DIR" --write >/dev/null 2>&1; then
  # worker/jobs/src/lib/core.js imports the generated catalog/lanes.json
  # statically (BH-1247), so nothing below would load without it.
  bad "catalog/lanes.json could not be composed from catalog/lanes.d"
elif [ ! -f "$NODE_TEST" ]; then
  bad "missing node suite $NODE_TEST"
else
  OUT=$(cd "$DIR/worker/jobs" && node --test "$NODE_TEST" 2>&1); RC=$?
  if [ "$RC" -eq 0 ]; then ok; else bad "node suite rc=$RC"; printf '%s\n' "$OUT" | grep -E '^not ok|error:' | head -20; fi
fi

# --- 3 (a): no events -> no triage, no model call -----------------------------
# The harness of tests/wake-loop-claims.bh-2637-test.sh: the REAL loop, the REAL
# jobs-client and wake-class libs, tests/lib/wake-claim-stub.sh as the worker.
H="$T/h"
export HARNESS="$H" WAKE_LOOP_CYCLES=1 WAKE_LOOP_INTERVAL_S=0 WCS_WAKES="$T/wakes.json"
unset WAKE_CLAIM_LIMIT HUB_BOX_NAME CLAIM_ALL COOL_MODE CLAIM_MODE CURSOR_PUT_MODE CURSOR_GET_MODE
CALLS="$T/model-calls.log"
mkdir -p "$H/bin/lib/jobs" "$H/env" "$H/logs" "$H/locks" "$H/state/wcs" "$H/flags"
printf 'HARNESS_SECRET=s\nJOBS_URL=https://jobs.test\n' > "$H/env/global.env"
# The loop and every bin/lib file it sources (BH-4552 scratch_install_closure).
for s in bin/wake-loop.sh bin/jobs-client.sh; do
  scratch_install_closure "$s" "$H" >/dev/null || { echo "closure install failed: $s"; exit 1; }
done
wcs_install "$H/bin"
wcs_identity "$H/bin" || { echo "wcs_identity failed"; exit 1; }
cat > "$H/bin/fleet-conf.sh" <<'SH'
#!/bin/bash
[ "$1" = "--projects" ] && { printf 'project-3\n'; exit 0; }
case "$1/$2" in
  project-3/repo)   echo example-org/project-3 ;;
  project-3/box)    echo box-project-3-1 ;;
  */board_prefix) echo /api/board ;;
  *) exit 1 ;;
esac
SH
# Every lane a wake can buy records into ONE log; run-triage and agent-call are
# the two this case is about (a triage tick, or any model call at all).
for s in run-triage agent-call review-prs deploy-train postmerge-qa rebase-train merge-conductor; do
  printf '#!/bin/bash\necho "%s $*" >> "%s"\n' "$s" "$CALLS" > "$H/bin/$s.sh"
done
printf '#!/bin/bash\nexit 1\n' > "$H/bin/unblocked-children.sh"
printf '#!/bin/bash\necho "[]"\n' > "$H/bin/gh"
printf '#!/bin/bash\nexec "$@"\n' > "$H/bin/setsid"
chmod +x "$H/bin/"*.sh "$H/bin/gh" "$H/bin/setsid"
for c in push pr-ci deploy pr-closed flaky split-chain; do touch "$H/flags/wake-lanes-$c"; done
printf '{"wakes":[]}' > "$T/wakes.json"
: > "$CALLS"
PATH="$H/bin:$PATH" BOX_NAME=box-project-3-1 "$H/bin/wake-loop.sh" >/dev/null 2>&1
sleep 0.5   # a launched lane is detached; give a wrong one the time to land
wcs_log | grep -q '^POST /api/wakes/claim' && ok \
  || bad "(a) the loop never asked the worker for wakes, so the case proves nothing: $(wcs_log) $(cat "$H/logs/wake-loop.log" 2>/dev/null)"
[ ! -s "$CALLS" ] && ok || bad "(a) zero wake rows must buy no triage and no model call: $(cat "$CALLS")"
[ ! -e "$H/state/wake-project-3" ] && ok || bad "(a) zero wake rows must not write state/wake-project-3"
STRAY=$(find "$H/state" -maxdepth 1 -name 'wake-*' ! -name 'wake-cursor*' 2>/dev/null)
[ -z "$STRAY" ] && ok || bad "(a) zero wake rows wrote wake state: $STRAY"
unset HARNESS WAKE_LOOP_CYCLES WAKE_LOOP_INTERVAL_S WCS_WAKES

# --- 4 (b): the gate skips without a wake file and runs with one --------------
# The harness of tests/gate-prs-fingerprint-test.sh: the REAL gate on a
# GitHub-Issues project `p`, a REST-shaped gh. --seed stores the fingerprint AND
# stamps state/p.gate-meta, so the daily-sweep arm stays quiet.
G="$T/g"
mkdir -p "$G/bin" "$G/state" "$G/flags" "$G/logs" "$G/env" "$G/fakebin"
cat > "$G/bin/fleet-conf.sh" <<'SH'
#!/bin/bash
case "$1 ${2:-}" in "p board_prefix") echo "-" ;; "p repo") echo "o/r" ;; *) exit 1 ;; esac
SH
chmod +x "$G/bin/fleet-conf.sh"
cat > "$G/fakebin/gh" <<'SH'
#!/bin/bash
[ "${1:-}" = api ] || exit 1
shift
P=""
while [ $# -gt 0 ]; do
  case "$1" in
    -i) shift ;;
    -X|-f|-F|-H) shift 2 ;;
    -*) shift ;;
    *) P="$1"; shift; break ;;
  esac
done
case "$P" in
  repos/o/r/issues*) BODY='[{"number":7,"state":"open","title":"Add sort","comments":2,"updated_at":"x"}]' ;;
  repos/o/r/pulls*)  BODY='[]' ;;
  *) exit 1 ;;
esac
printf 'HTTP/2.0 200\r\n\r\n%s\n' "$BODY"
SH
chmod +x "$G/fakebin/gh"
gate() { ( export PATH="$G/fakebin:$PATH" HARNESS="$G"; "$DIR/bin/triage-gate.sh" p "$@" 2>"$T/gate-err.txt" ); }

OUT=$(gate --seed)
grep -q '^SEEDED' <<<"$OUT" && ok || bad "(b) seed failed: $OUT $(cat "$T/gate-err.txt")"
OUT=$(gate)
grep -q '^SKIP' <<<"$OUT" && ok || bad "(b) an unchanged board with no wake file must SKIP: $OUT $(cat "$T/gate-err.txt")"
touch "$G/state/wake-p"
OUT=$(gate)
[ "$OUT" = "RUN event-wake" ] && ok || bad "(b) state/wake-p must answer RUN event-wake: $OUT"
[ ! -e "$G/state/wake-p" ] && ok || bad "(b) the wake file is one-shot and must be consumed"
OUT=$(gate)
grep -q '^SKIP' <<<"$OUT" && ok || bad "(b) the tick after a consumed wake must SKIP again: $OUT"

echo "webhook-intake (BH-4079): $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
