#!/bin/bash
# tests/scratch-immutable-cleanup.bh-5007-test.sh — BH-5007: tests/lib/scratch.sh
# owns its tree even when a suite armed chattr +a/+i inside it.
#
# tests/harden-state-test.sh runs the real bin/harden-state.sh against a scratch
# harness, which sets +a on eight ledgers, and leaves the cleanup to this
# library's EXIT trap. `rm -rf` cannot unlink a +a or +i file even as root, so
# 20 of 27 /tmp/scratch.* trees on box-small were exactly those eight
# ledgers. What is proved here, by running a child that sources the library:
#   S1. the EXIT trap removes a tree holding a +a file and a +i file;
#   S2. sourcing the library again in the same shell (__scratch_cleanup_old)
#       removes the first tree with a +i file inside;
#   S3. the path guard is unchanged: scratch_cleanup /etc is still refused.
# Needs chattr that works (root on ext4/overlay); otherwise SKIP, exit 0.
# Run from anywhere: tests/scratch-immutable-cleanup.bh-5007-test.sh
set -u
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
# A red run must not leak itself: clear the attributes before the library's
# own cleanup runs.
__bh5007_exit() {
  chattr -R -ia "$T" 2>/dev/null
  __scratch_exit_trap
}
trap __bh5007_exit EXIT

probe="$T/probe"
: > "$probe"
if ! chattr +i "$probe" 2>/dev/null; then
  echo "SKIP: chattr unsupported here"
  exit 0
fi
chattr -i "$probe" 2>/dev/null
rm -f "$probe"

mkdir -p "$T/inner"
LIB="$DIR/tests/lib/scratch.sh"

# ── S1: the EXIT trap removes a tree with +a and +i files in it ──────────────
TMPDIR="$T/inner" bash -c '. "$0" || exit 1
  touch "$SCRATCH/a" "$SCRATCH/b"
  chattr +a "$SCRATCH/a" && chattr +i "$SCRATCH/b" || exit 3
  echo "$SCRATCH" > "$1"' "$LIB" "$T/s1.path" 2>"$T/s1.err"
RC=$?
S1=$(cat "$T/s1.path" 2>/dev/null)
if [ "$RC" != 0 ] || [ -z "$S1" ]; then
  bad "S1 the child could not arm its tree (rc=$RC, $(cat "$T/s1.err"))"
elif [ -e "$S1" ]; then
  bad "S1 the child's scratch tree $S1 survived its EXIT trap (left: $(ls -A "$S1" | tr '\n' ' '))"
else
  ok
fi

# ── S2: re-sourcing removes the previous tree, +i file and all ───────────────
TMPDIR="$T/inner" bash -c '. "$0" || exit 1
  touch "$SCRATCH/b"; chattr +i "$SCRATCH/b" || exit 3
  echo "$SCRATCH" > "$1"
  . "$0" || exit 1
  [ -e "$(cat "$1")" ] && echo kept > "$2"
  exit 0' "$LIB" "$T/s2.path" "$T/s2.kept" 2>"$T/s2.err"
RC=$?
S2=$(cat "$T/s2.path" 2>/dev/null)
if [ "$RC" != 0 ] || [ -z "$S2" ]; then
  bad "S2 the child could not arm its tree (rc=$RC, $(cat "$T/s2.err"))"
elif [ -e "$T/s2.kept" ] || [ -e "$S2" ]; then
  bad "S2 re-sourcing scratch.sh left the first tree $S2 behind"
else
  ok
fi

# ── S3: the guard is byte-for-byte the old one ───────────────────────────────
out=$(scratch_cleanup /etc 2>&1); RC=$?
[ "$RC" = 1 ] && [[ $out == *"refusing path outside SCRATCH"* ]] && [ -d /etc ] && ok \
  || bad "S3 scratch_cleanup /etc must still be refused (rc=$RC, '$out')"

# The children's leftovers, if any, are the outer suite's to remove.
chattr -R -ia "$T/inner" 2>/dev/null

echo "scratch-immutable-cleanup.bh-5007: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
