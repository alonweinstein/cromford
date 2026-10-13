#!/bin/bash
# tests/scratch-lib-test.sh — self-test for tests/lib/scratch.sh.
#
# Tests the safety guard, the harness-var unset, the read-only temp tree, the
# path-rejecting helpers, and the EXIT cleanup trap. Runs as root on the box
# with HARNESS_TEST_SANDBOX=1 so the live /root/harness does not block it.
set -uo pipefail
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

# --- source under the normal (root + live harness + sandbox) path ------------
export HARNESS=/root/harness
export H=/root/harness
export HARNESS_CHECKOUT=/root/harness
export HARNESS_ENV_DIR=/run/harness-env

# shellcheck source=lib/scratch.sh
. "$DIR/tests/lib/scratch.sh" || exit 1

# 1. harness vars are unset after sourcing
[ -z "${HARNESS:-}" ] && ok || bad "HARNESS was not unset"
[ -z "${H:-}" ] && ok || bad "H was not unset"
[ -z "${HARNESS_CHECKOUT:-}" ] && ok || bad "HARNESS_CHECKOUT was not unset"
[ -z "${HARNESS_ENV_DIR:-}" ] && ok || bad "HARNESS_ENV_DIR was not unset"

# 2. T is a writable directory under /tmp (or $TMPDIR)
[ -d "$T" ] && ok || bad "T is not a directory"
case "$T" in
  "${TMPDIR:-/tmp}"/scratch.??????) ok ;;
  *) bad "T is not a scratch tree under ${TMPDIR:-/tmp}: $T" ;;
esac
[ "$(stat -c %a "$T")" = "755" ] && ok || bad "T is not mode 755: $(stat -c %a "$T")"
# the tree must be writable — every ported test writes straight into it, and
# under a non-root runner mode 555 would fail on the first write.
( : > "$T/writable" ) 2>/dev/null && ok || bad "T is not writable"
rm -f "$T/writable"

# 3. scratch_rm refuses a path outside SCRATCH
OUTSIDE="/tmp/outside-scratch-$$"
touch "$OUTSIDE"
scratch_rm "$OUTSIDE" && bad "scratch_rm accepted a path outside SCRATCH" || ok
[ -e "$OUTSIDE" ] && ok || bad "scratch_rm deleted a file outside SCRATCH"
rm -f "$OUTSIDE"

# 4. scratch_rm removes a file inside SCRATCH (the touch rc is checked, or a
# write that never happened reads as a delete that worked)
touch "$T/x" && ok || bad "could not create a file inside SCRATCH"
[ -e "$T/x" ] && ok || bad "file inside SCRATCH was not created"
scratch_rm "$T/x" && ok || bad "scratch_rm failed on a file inside SCRATCH"
[ -e "$T/x" ] && bad "scratch_rm did not delete the file inside SCRATCH" || ok

# 5. root + fake live harness + no sandbox aborts the SOURCING SCRIPT, not just
# the source. A `return` here would end the source and let the test run on with
# T unset; the assertion after the source must never be reached.
FAKE=$(mktemp -d)
# The guard only fires for uid 0, and CI does not run as root — so `id -u` is
# stubbed rather than skipping the case there. A guard that is only exercised on
# the one machine that runs as root is a guard nobody tests.
FAKEBIN=$(mktemp -d)
cat > "$FAKEBIN/id" <<'ID_EOF'
#!/bin/bash
[ "${1:-}" = "-u" ] && { echo 0; exit 0; }
exec /usr/bin/id "$@"
ID_EOF
chmod +x "$FAKEBIN/id"
PROBE=$(mktemp "${TMPDIR:-/tmp}"/scratch-probe.XXXXXX)
cat > "$PROBE" <<PROBE_EOF
#!/bin/bash
set -uo pipefail
. "$DIR/tests/lib/scratch.sh"
echo REACHED
PROBE_EOF
chmod +x "$PROBE"
RC=0
OUT=$(PATH="$FAKEBIN:$PATH" HARNESS_ROOT_OVERRIDE="$FAKE" HARNESS_TEST_SANDBOX= bash "$PROBE" 2>&1) || RC=$?
[ "$RC" -eq 1 ] && ok || bad "root with fake live harness and no sandbox did not abort (rc=$RC)"
grep -q REACHED <<<"$OUT" && bad "the sourcing script kept running after the guard fired" || ok
grep -q 'refusing to run as root' <<<"$OUT" && ok || bad "the guard did not say why it refused: $OUT"
rm -f "$PROBE" "$FAKEBIN/id"
rmdir "$FAKEBIN"
rmdir "$FAKE"

# 6. root + fake live harness + sandbox=1 proceeds — and a child source must NOT
# delete the tree of the shell that spawned it.
FAKE=$(mktemp -d)
MINE=$T
touch "$MINE/keep"
RC=0
( export HARNESS_ROOT_OVERRIDE="$FAKE" HARNESS_TEST_SANDBOX=1; . "$DIR/tests/lib/scratch.sh"; [ -n "${T:-}" ]; ) || RC=$?
[ "$RC" -eq 0 ] && ok || bad "root with fake live harness and sandbox=1 did not proceed (rc=$RC)"
[ -e "$MINE/keep" ] && ok || bad "a child source deleted its parent's scratch tree"
rmdir "$FAKE"

# 7. EXIT trap removes SCRATCH
# MARK is a path under this shell's own tree, not a bare mktemp -d: the scratch
# check wants every recursive delete in tests/ to be one scratch_rm can prove it
# owns, and the child below writes into it, so it must outlive the child's tree.
MARK="$T/exit-trap-mark"; mkdir -p "$MARK"
RC=0
( export HARNESS_TEST_SANDBOX=1; . "$DIR/tests/lib/scratch.sh"; printf '%s' "$SCRATCH" > "$MARK/dir"; exit 0; ) || RC=$?
[ "$RC" -eq 0 ] && ok || bad "child source for EXIT-trap test failed (rc=$RC)"
[ -s "$MARK/dir" ] && ok || bad "child did not record SCRATCH path"
REMOVED=$(cat "$MARK/dir")
[ -d "$REMOVED" ] && bad "EXIT trap did not remove SCRATCH" || ok
[ -e "$MINE/keep" ] && ok || bad "the child's EXIT trap removed its parent's scratch tree"
chmod -R +w "$MARK"
scratch_rm "$MARK"

# 8. re-sourcing in the same shell creates a fresh tree and removes the old one.
# The old tree is re-created here first, so it is known-live when the assertion
# runs — asserting on a tree something else already deleted proves nothing.
. "$DIR/tests/lib/scratch.sh" || exit 1
OLD=$SCRATCH
[ -d "$OLD" ] && ok || bad "re-source did not create a live tree to replace"
. "$DIR/tests/lib/scratch.sh" || exit 1
[ "$SCRATCH" != "$OLD" ] && ok || bad "re-source did not create a fresh SCRATCH"
[ -d "$OLD" ] && bad "re-source leaked the old SCRATCH" || ok

echo "scratch-lib: $PASS pass, $FAIL fail"
[ "$FAIL" -eq 0 ]
