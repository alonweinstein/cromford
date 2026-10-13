#!/bin/bash
# tests/file-children.bh-1347-test.sh — file_children resolves its lane module
# by ONE rule, for EVERY --kind (BH-1347).
#
# WHAT IS UNDER TEST. bin/lib/file-children.sh sources the lane module
# (fc-issues.sh / fc-board.sh) for the lane it resolved, and the rule is the one
# the library's own header states: the module BESIDE the copy of the library
# that was sourced wins, $HARNESS/bin/lib is the fallback, and rc 3 with one
# FILE_CHILDREN_UNIMPLEMENTED line is what happens when neither exists. BH-982's
# fix round added an `if [ "$kind" = rollout ]` branch that answered the rollout
# kind ONLY from $HARNESS/bin/lib, so a checkout that is not the live harness —
# a test tree, a worktree, a box mid-propagate — silently lost its own module.
# This suite pins the single rule at the library seam; the production entry
# point (bin/run-rollout.sh driven end to end) is pinned by
# tests/run-rollout.bh-984-test.sh.
#
# Every assertion is on an artifact the drive produced (who.txt, pipeline.log)
# or on the real exit code, never on the library's source text.
#
# No network, no model call, no gh, no secrets, nothing written outside $T.
#   tests/file-children.bh-1347-test.sh      (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

# LIB_OVERRIDE runs the same five cases against a DIFFERENT copy of the library.
# That is how this ticket's red proof was taken (the merge-base copy, which
# fails cases 1 and 2); unset, it is this checkout's own library.
LIB="${LIB_OVERRIDE:-$DIR/bin/lib/file-children.sh}"
if [ ! -r "$LIB" ]; then
  echo "FAIL: $LIB is missing"
  echo "file-children.bh-1347: 0 pass, 1 fail"
  exit 1
fi

# ---------------------------------------------------------------------------
# scratch harness + two scratch CHECKOUTS
#
# $T/h is the live-box stand-in ($HARNESS): fleet.conf and bin/fleet-conf.sh,
# with bin/lib EMPTY to start with. $T/own and $T/plain are checkouts of the
# library somewhere else, which is the only place the two rules can disagree:
# $T/own carries a lane module beside the library, $T/plain carries none. Both
# keep the bin/lib shape because file_children resolves fleet-conf.sh at
# `<its own dir>/../fleet-conf.sh` before it falls back to $HARNESS.
# ---------------------------------------------------------------------------
mkdir -p "$T/h/bin/lib" "$T/b"
cp "$DIR/bin/fleet-conf.sh" "$T/h/bin/"
cat > "$T/h/fleet.conf" <<'CONF'
# <project> <repo> <prod> <board-api-prefix> <offset> [box] [ip]
scoutish      example-org/scoutish   https://scoutish.example  -           9 box-1 10.0.0.9
widget-os     example-org/widget-os  https://widget.example    /api/board  2 box-1 10.0.0.2
CONF

for tree in own plain; do
  mkdir -p "$T/$tree/bin/lib"
  cp "$LIB" "$T/$tree/bin/lib/file-children.sh"
  cp "$DIR/bin/fleet-conf.sh" "$T/$tree/bin/"
done
OWN="$T/own/bin/lib/file-children.sh"
PLAIN="$T/plain/bin/lib/file-children.sh"

cat > "$T/own/bin/lib/fc-issues.sh" <<'SH'
#!/bin/bash
# shellcheck shell=bash
fc_file_issues() { printf 'beside %s %s\n' "$FC_LANE" "$FC_KIND" > "$FC_BUILD/who.txt"; return 0; }
SH

# drive <library> <project> <kind> — a fresh build dir, then one file_children
# call in its own process. Returns the call's REAL rc.
drive() {
  local lib="$1" project="$2" kind="$3" rc=0
  rm -rf "$T/b"; mkdir -p "$T/b"
  ( env HARNESS="$T/h" FLEET_CONF="$T/h/fleet.conf" \
      bash -c 'set -u; . "$1"; file_children "$3" 552 TK-552 "$2" "$2/children.json" --kind "$4"' \
      _ "$lib" "$T/b" "$project" "$kind" ) || rc=$?
  return "$rc"
}

who() { cat "$T/b/who.txt" 2>/dev/null; }

# ===========================================================================
# C1 — the module beside the sourced library dispatches for --kind rollout,
# with $HARNESS/bin/lib empty. This is the ticket's reproduction.
# ===========================================================================
[ -z "$(ls -A "$T/h/bin/lib")" ] \
  && ok || bad "C1 needs an empty \$HARNESS/bin/lib, found: $(ls -A "$T/h/bin/lib")"
RC=0; drive "$OWN" scoutish rollout || RC=$?
[ "$RC" -eq 0 ] \
  && ok || bad "C1 a module beside the library must dispatch for --kind rollout (rc=$RC): $(cat "$T/b/pipeline.log" 2>/dev/null)"
[ "$(who)" = 'beside issues rollout' ] \
  && ok || bad "C1 the beside module ran and --kind rollout reached it: '$(who)'"

# ===========================================================================
# C2 — beside BEATS the $HARNESS copy for --kind rollout. Not "is consulted":
# wins. Both modules exist here and only one may have written who.txt.
# ===========================================================================
cat > "$T/h/bin/lib/fc-issues.sh" <<'SH'
#!/bin/bash
# shellcheck shell=bash
fc_file_issues() { printf 'harness-fallback %s %s\n' "$FC_LANE" "$FC_KIND" > "$FC_BUILD/who.txt"; return 0; }
SH
RC=0; drive "$OWN" scoutish rollout || RC=$?
[ "$RC" -eq 0 ] \
  && ok || bad "C2 both modules present must still dispatch (rc=$RC)"
[ "$(who)" = 'beside issues rollout' ] \
  && ok || bad "C2 the module beside the library wins over \$HARNESS/bin/lib: '$(who)'"

# ===========================================================================
# C3 — with NO module beside it, the $HARNESS/bin/lib fallback still runs for
# --kind rollout. The revert keeps the fallback, it does not swap the order.
# ===========================================================================
RC=0; drive "$PLAIN" scoutish rollout || RC=$?
[ "$RC" -eq 0 ] \
  && ok || bad "C3 the \$HARNESS/bin/lib fallback must dispatch for --kind rollout (rc=$RC)"
[ "$(who)" = 'harness-fallback issues rollout' ] \
  && ok || bad "C3 the fallback module ran: '$(who)'"

# ===========================================================================
# C4 — no module in EITHER place is rc 3, once, and never silent. widget-os is
# the board lane, and bin/lib/fc-board.sh ships nowhere, so this is the honest
# no-filer case: nothing has to be deleted to produce it.
# ===========================================================================
RC=0; drive "$PLAIN" widget-os rollout || RC=$?
[ "$RC" -eq 3 ] \
  && ok || bad "C4 no lane module anywhere must answer 3 (rc=$RC)"
[ "$(grep -c 'FILE_CHILDREN_UNIMPLEMENTED board' "$T/b/pipeline.log" 2>/dev/null)" = 1 ] \
  && ok || bad "C4 rc 3 is paired with exactly one log line: $(cat "$T/b/pipeline.log" 2>/dev/null)"
[ ! -e "$T/b/who.txt" ] \
  && ok || bad "C4 no lane function may have run: '$(who)'"

# ===========================================================================
# C5 — the lints this repo runs over its own test files
# ===========================================================================
if [ -x "$DIR/bin/test-determinism-lint.sh" ]; then
  DL=$("$DIR/bin/test-determinism-lint.sh" "$DIR/tests/file-children.bh-1347-test.sh" 2>&1) \
    && ok || bad "this suite must pass the determinism lint: $DL"
else
  echo "note: bin/test-determinism-lint.sh absent — the C5 lint assertion did not run"
fi
# shellcheck source=bin/lib/test-home-lib.sh
. "$DIR/bin/lib/test-home-lib.sh" 2>/dev/null
if command -v th_is_own >/dev/null 2>&1; then
  th_is_own tests/file-children.bh-1347-test.sh BH-1347 \
    && ok || bad "this suite must be recognised as BH-1347's own test file"
else
  echo "note: bin/lib/test-home-lib.sh absent — the test-home assertion did not run"
fi

echo "file-children.bh-1347: $PASS pass, $FAIL fail"
[ "$FAIL" -eq 0 ]
