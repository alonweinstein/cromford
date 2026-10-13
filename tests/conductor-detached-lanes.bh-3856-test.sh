#!/bin/bash
# tests/conductor-detached-lanes.bh-3856-test.sh — conductor-detached-lanes-test
# must leave nothing behind in the tree it is run from.
#
# THE INCIDENT THIS PINS (BH-3856). The suite's agent-call.sh stub wrote its
# verdict to "$4" — the 1200 timeout, not the <out> the real caller passes as
# "$5" — and probe_lane spawned its lanes from the caller's cwd and killed only
# the lane's bash. On a loaded box the re-review lane reached the stub before
# the kill, the orphaned stub woke after the suite had exited, and a file named
# 1200 appeared in the repo root. Gate runners then saw a dirty tree.
#
# HOW. Run the suite FROM the repo root with CDL_PROBES_ONLY=1 (it waits until
# the re-review lane is inside the stub, kills the probes, runs section 1b and
# exits before section 2)
# and FAKE_AGENT_SLEEP=8, then outwait the stub and compare the tree.
#
# Run from anywhere: tests/conductor-detached-lanes.bh-3856-test.sh  (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq    >/dev/null || { echo "jq missing — skipping"; exit 0; }
command -v flock >/dev/null || { echo "flock missing — skipping"; exit 0; }

# 1. The tree as it stands before the suite runs.
GIT=0
if git -C "$DIR" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  GIT=1; git -C "$DIR" status --porcelain --untracked-files=all > "$T/before"
else
  echo "NOTE: not a git checkout — porcelain check skipped; the stray-file check still runs"
fi
# 2. A 1200 that was already there is not this run's.
HAD1200=0; [ -e "$DIR/1200" ] && HAD1200=1

# 3. The suite, probes only, from the repo root, with the stub asleep at the kill.
( cd "$DIR" && HARNESS_TEST_SANDBOX="${HARNESS_TEST_SANDBOX:-}" CDL_PROBES_ONLY=1 FAKE_AGENT_SLEEP=8 \
    bash "$DIR/tests/conductor-detached-lanes-test.sh" ) > "$T/child.out" 2>&1
rc=$?
[ "$rc" = 0 ] && ok || bad "the probes-only suite exited rc $rc: $(cat "$T/child.out")"
grep -q 'probes-only: agent-call reached' "$T/child.out" && ok \
  || bad "the probes-only run never reached agent-call.sh, so the orphan case did not run: $(cat "$T/child.out")"
grep -q ' 0 failed$' "$T/child.out" && ok || bad "the probes-only suite reported failures: $(cat "$T/child.out")"

# 4. Longer than FAKE_AGENT_SLEEP=8 plus the 5 s reap bound: a surviving stub
#    would have written by now. A negative check has no event to wait on, so
#    poll for the stray file and stop the moment it lands; only a clean run
#    spends the whole window.
DEADLINE=$((SECONDS + 11))
while [ "$SECONDS" -lt "$DEADLINE" ]; do
  [ "$HAD1200" = 0 ] && [ -e "$DIR/1200" ] && break
  sleep 1
done

# 5. Nothing new in the tree.
STRAY=0
if [ "$HAD1200" = 0 ]; then
  if [ -e "$DIR/1200" ]; then STRAY=1
    bad "$DIR/1200 appeared — an orphaned agent-call stub wrote its verdict to the timeout argument in the caller's cwd"
  else ok; fi
fi
if [ "$GIT" = 1 ]; then
  git -C "$DIR" status --porcelain --untracked-files=all > "$T/after"
  if cmp -s "$T/before" "$T/after"; then ok
  else bad "git status --porcelain changed across the suite:"; diff "$T/before" "$T/after"; fi
fi
# Clean up only what this run provably wrote: the stub's own 17-byte verdict.
[ "$STRAY" = 1 ] && [ -f "$DIR/1200" ] && [ "$(stat -c %s "$DIR/1200")" -lt 64 ] \
  && [ "$(cat "$DIR/1200")" = "VERDICT: APPROVE" ] && rm -f "$DIR/1200"

echo "conductor-detached-lanes.bh-3856-test: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
