#!/bin/bash
# tests/docker-image-ratchet-test.sh — only two files may name the local test
# image, and the count of them never goes up (BH-1205).
#
# WHY. bin/run-tests-in-docker.sh builds `cromford-tests:<tag>` once and
# keeps it, so the tag is a cache key: every place that spells it is a place
# that must move when the package list moves. That already bit this repo —
# three harness-sync suites went on printing "rsync missing — skipping" on the
# Mac drain because a machine held the old tag (BH-1128, the reason the tag
# carries a suffix at all).
#
# BH-1205 adds a SECOND way to run the suite (bin/remote-gate.sh, on the shared
# Fly host). The docker runner stays — it is what somebody without Fly access
# uses — but a third caller that hardcodes the image, instead of calling the
# runner, would be a third thing to keep in sync and a third thing to forget.
# This ratchet is the thing that says so, at the moment it is written.
#
# It scans executable text only (*.sh, *.yml, *.yaml). Prose may name the image
# as often as it likes: a doc that is out of date is wrong, not broken.
#
# Run from anywhere: tests/docker-image-ratchet-test.sh   (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

# The allowlist. Adding a line here is a decision somebody makes in a diff, not
# a thing that happens by accident.
#   bin/run-tests-in-docker.sh              builds and runs the image
#   tests/run-tests-in-docker.bh-1128-test.sh  pins the tag-moves-with-packages rule
#   tests/docker-image-ratchet-test.sh      this file, which has to name it to find it
ALLOWED="bin/run-tests-in-docker.sh
tests/run-tests-in-docker.bh-1128-test.sh
tests/docker-image-ratchet-test.sh"

IMAGE_NAME='cromford-tests'

# .claude is pruned with the rest: a Mac checkout keeps stale
# .claude/worktrees/agent-*, each a FULL copy of this repo, so an unpruned scan
# finds eleven more copies of the runner and calls them violations. CI (git
# archive), docker and the Fly host (rsync --exclude .claude) never see them,
# which is the worst kind of red — only on the machine you are sitting at.
FOUND=$(cd "$DIR" && find . \( -name .git -o -name node_modules -o -name .wrangler -o -name dist -o -name .claude \) -prune -o \
  -type f \( -name '*.sh' -o -name '*.yml' -o -name '*.yaml' \) -print 2>/dev/null \
  | sed 's|^\./||' | LC_ALL=C sort \
  | while IFS= read -r f; do grep -q "$IMAGE_NAME" "$DIR/$f" 2>/dev/null && printf '%s\n' "$f"; done)

EXTRA=""
while IFS= read -r f; do
  [ -n "$f" ] || continue
  case "
$ALLOWED
" in *"
$f
"*) continue ;; esac
  EXTRA="$EXTRA $f"
done <<EOF
$FOUND
EOF
[ -z "$EXTRA" ] && ok || bad "1 these files hardcode the test image and are not on the allowlist:$EXTRA (call bin/run-tests-in-docker.sh or bin/remote-gate.sh instead, or add the file to ALLOWED here and say why)"

# A ratchet that finds nothing is a ratchet that has stopped working — the
# vacuous green this repo has been bitten by more than once.
N=$(printf '%s\n' "$FOUND" | grep -c . || true)
[ "$N" -ge 2 ] && ok || bad "2 the scan found $N files naming $IMAGE_NAME (expected at least the runner and its suite) — the ratchet is scanning for nothing"

# Both allowlisted non-self entries must still exist, so a rename cannot leave
# the list pointing at nothing while the ratchet reports green.
GONE=""
while IFS= read -r f; do
  [ -n "$f" ] || continue
  [ -f "$DIR/$f" ] || GONE="$GONE $f"
done <<EOF
$ALLOWED
EOF
[ -z "$GONE" ] && ok || bad "3 the allowlist names files that do not exist:$GONE"

echo "docker-image-ratchet: $PASS passed, $FAIL failed  ($N files name the image)"
[ "$FAIL" -eq 0 ]
