#!/bin/bash
# tests/lanes-registry-stamp-owner.bh-1304-test.sh — _lr_stamp refuses a stamp
# directory it does not own, and the loader keeps working when it does.
#
# WHY (BH-1304, item 2; BH-1247 review r4 § Suggestions). The stamp lives at
# ${TMPDIR:-/tmp}/harness-lanes-<uid>/stamp-<digest>. That directory is created
# 0700 so nobody else can put anything in it — but on a shared host somebody can
# get there FIRST, and `mkdir -p` succeeds silently on a directory that is
# already there. The harness then writes its staleness key into another user's
# directory (or, through a planted symlink, into any path that user chose),
# which is the same swallow-the-symlink shape the per-uid directory was added
# for in the first place.
#
# So the rule under test is: a pre-existing stamp directory is USED only if it
# is a real directory owned by this euid. A symlink, or somebody else's
# directory, is REFUSED — `_lr_stamp` prints nothing and returns 1.
#
# AND THE NEGATIVE CARRIES THE WEIGHT. A refusal must not turn into a failure to
# read the registry: a lane that cannot resolve its kill switch fails OPEN
# today, and the loader keeps that. On a refusal it re-renders into the repo (no
# stamp = stale), it never writes into the refused directory, and it never
# writes a render into the CALLER'S CWD — that last one is the trap in the
# read-only-tree fallback, where `dirname ""` is `.`.
#
# Run from anywhere: tests/lanes-registry-stamp-owner.bh-1304-test.sh
# (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null 2>&1 \
  || { echo "lanes-registry-stamp-owner.bh-1304-test: SKIPPED — jq is not installed (bin/lanes-build.sh needs it)"; exit 0; }

UIDN=$(id -u)

# ── the fixture: the REAL loader and the REAL composer over sources of our own
#    shape. Nothing here restates what either script does; both are executed.
TEMPLATE="$T/template"
mkdir -p "$TEMPLATE/bin/lib" "$TEMPLATE/catalog/lanes.d"
cp "$DIR/bin/lanes-build.sh" "$TEMPLATE/bin/lanes-build.sh" || { echo "FAIL: cannot copy bin/lanes-build.sh"; exit 1; }
cp "$DIR/bin/lib/lanes-registry.sh" "$TEMPLATE/bin/lib/lanes-registry.sh" || { echo "FAIL: cannot copy bin/lib/lanes-registry.sh"; exit 1; }
chmod +x "$TEMPLATE/bin/lanes-build.sh"
printf '{"version":1,"note":"fixture registry for tests/lanes-registry-stamp-owner.bh-1304-test.sh"}\n' \
  > "$TEMPLATE/catalog/lanes.d/_registry.json"
printf '{"id":"aaa-one","box":"hub","cadence_min":10}\n'  > "$TEMPLATE/catalog/lanes.d/aaa-one.json"
printf '{"id":"bbb-two","box":"hub","cadence_min":30}\n'  > "$TEMPLATE/catalog/lanes.d/bbb-two.json"

mkrepo() { # mkrepo <name> — prints the path to a fresh copy of the fixture
  local d="$T/$1"
  scratch_rm "$d" || exit 1
  cp -a "$TEMPLATE" "$d" || exit 1
  printf '%s' "$d"
}

# ============================================================================
# A. BASELINE — a directory we create ourselves is created 0700, owned by us,
#    and used. Without this case every refusal below could be a function that
#    simply never works.
# ============================================================================
REPOA=$(mkrepo rA); mkdir -p "$T/tmpA"
ADIR="$T/tmpA/harness-lanes-$UIDN"
( export TMPDIR="$T/tmpA"
  . "$REPOA/bin/lib/lanes-registry.sh" || exit 9
  S=$(_lr_stamp "$REPOA/catalog/lanes.json") || exit 1
  printf '%s' "$S" > "$T/A.stamp"
); RCA=$?
[ "$RCA" = 0 ] && ok || bad "A: _lr_stamp must succeed against a fresh TMPDIR (rc $RCA)"
case "$(cat "$T/A.stamp" 2>/dev/null)" in
  "$ADIR"/stamp-[0-9]*) ok ;;
  *) bad "A: the stamp must live in the per-uid dir under TMPDIR, got '$(cat "$T/A.stamp" 2>/dev/null)'" ;;
esac
[ -d "$ADIR" ] && [ ! -L "$ADIR" ] && ok || bad "A: _lr_stamp must create $ADIR as a real directory"
[ "$(stat -c %a "$ADIR" 2>/dev/null)" = 700 ] \
  && ok || bad "A: the per-uid dir must be 0700, got $(stat -c %a "$ADIR" 2>/dev/null)"
[ -O "$ADIR" ] && ok || bad "A: the per-uid dir must be owned by the caller"

( export TMPDIR="$T/tmpA"
  cd "$T" || exit 9
  . "$REPOA/bin/lib/lanes-registry.sh" || exit 9
  P=$(lanes_json_path "$REPOA") || exit 1
  printf '%s' "$P" > "$T/A.path"
); RCA2=$?
[ "$RCA2" = 0 ] && ok || bad "A: lanes_json_path must render and return 0 (rc $RCA2)"
[ "$(cat "$T/A.path" 2>/dev/null)" = "$REPOA/catalog/lanes.json" ] \
  && ok || bad "A: lanes_json_path must print the canonical render path, got '$(cat "$T/A.path" 2>/dev/null)'"
[ -s "$REPOA/catalog/lanes.json" ] && ok || bad "A: the render must exist and be non-empty"
[ "$(jq -r '.lanes|length' "$REPOA/catalog/lanes.json" 2>/dev/null)" = 2 ] \
  && ok || bad "A: the render must hold both fixture lanes: $(head -c 200 "$REPOA/catalog/lanes.json" 2>/dev/null)"
[ -n "$(ls -1 "$ADIR"/stamp-* 2>/dev/null)" ] \
  && ok || bad "A: a render into a dir we own must leave its stamp there: $(ls -A "$ADIR" 2>/dev/null)"

# ============================================================================
# B. A PLANTED SYMLINK IS REFUSED. `-O` follows symlinks, so a link into a
#    directory we DO own would pass an ownership test on its own — the threat
#    the per-uid directory was added for is somebody choosing where our write
#    lands, not who owns the far end.
# ============================================================================
REPOB=$(mkrepo rB); mkdir -p "$T/tmpB" "$T/elsewhereB"
ln -s "$T/elsewhereB" "$T/tmpB/harness-lanes-$UIDN" || { echo "FAIL: cannot plant the symlink"; exit 1; }
( export TMPDIR="$T/tmpB"
  . "$REPOB/bin/lib/lanes-registry.sh" || exit 9
  S=$(_lr_stamp "$REPOB/catalog/lanes.json") || { printf '' > "$T/B.stamp"; exit 1; }
  printf '%s' "$S" > "$T/B.stamp"
); RCB=$?
[ "$RCB" != 0 ] && ok || bad "B: a planted symlink must be refused, got rc $RCB"
[ ! -s "$T/B.stamp" ] && ok || bad "B: a refused stamp dir must print NOTHING, got '$(cat "$T/B.stamp" 2>/dev/null)'"

( export TMPDIR="$T/tmpB"
  cd "$T" || exit 9
  . "$REPOB/bin/lib/lanes-registry.sh" || exit 9
  P=$(lanes_json_path "$REPOB") || exit 1
  printf '%s' "$P" > "$T/B.path"
); RCB2=$?
[ "$RCB2" = 0 ] && ok || bad "B: the loader must still render when the stamp dir is refused (fail-open), rc $RCB2"
[ "$(cat "$T/B.path" 2>/dev/null)" = "$REPOB/catalog/lanes.json" ] \
  && ok || bad "B: the loader must still print the canonical path, got '$(cat "$T/B.path" 2>/dev/null)'"
[ -s "$REPOB/catalog/lanes.json" ] && ok || bad "B: the loader must still write a non-empty render"
[ -z "$(ls -A "$T/elsewhereB" 2>/dev/null)" ] \
  && ok || bad "B: nothing may be written through the planted symlink: $(ls -A "$T/elsewhereB" 2>/dev/null)"

( export TMPDIR="$T/tmpB"
  . "$REPOB/bin/lib/lanes-registry.sh" || exit 9
  lanes_stamp_write "$REPOB"
); RCB3=$?
[ "$RCB3" != 0 ] \
  && ok || bad "B: lanes_stamp_write must report the refusal, not a silent success (rc $RCB3)"
[ -z "$(ls -A "$T/elsewhereB" 2>/dev/null)" ] \
  && ok || bad "B: lanes_stamp_write wrote through the planted symlink: $(ls -A "$T/elsewhereB" 2>/dev/null)"

# ============================================================================
# C. SOMEBODY ELSE'S DIRECTORY IS REFUSED — the case the `-O` test exists for,
#    and the one `mkdir -p` used to accept without a word.
# ============================================================================
REPOC=$(mkrepo rC); mkdir -p "$T/tmpC"
CDIR="$T/tmpC/harness-lanes-$UIDN"
mkdir -m 700 "$CDIR"
CHOWNED=0
if [ "$UIDN" = 0 ]; then
  chown 65534:65534 "$CDIR" 2>/dev/null && CHOWNED=1
elif sudo -n true >/dev/null 2>&1; then
  sudo -n chown 65534:65534 "$CDIR" 2>/dev/null && CHOWNED=1
fi
if [ "$CHOWNED" != 1 ]; then
  echo "lanes-registry-stamp-owner.bh-1304-test: SKIPPED case C — cannot chown a directory to another uid without root or passwordless sudo"
else
  ( export TMPDIR="$T/tmpC"
    . "$REPOC/bin/lib/lanes-registry.sh" || exit 9
    S=$(_lr_stamp "$REPOC/catalog/lanes.json") || { printf '' > "$T/C.stamp"; exit 1; }
    printf '%s' "$S" > "$T/C.stamp"
  ); RCC=$?
  [ "$RCC" != 0 ] && ok || bad "C: a pre-planted dir owned by another uid must be refused, got rc $RCC"
  [ ! -s "$T/C.stamp" ] && ok || bad "C: a refused stamp dir must print NOTHING, got '$(cat "$T/C.stamp" 2>/dev/null)'"

  ( export TMPDIR="$T/tmpC"
    cd "$T" || exit 9
    . "$REPOC/bin/lib/lanes-registry.sh" || exit 9
    P=$(lanes_json_path "$REPOC") || exit 1
    printf '%s' "$P" > "$T/C.path"
  ); RCC2=$?
  [ "$RCC2" = 0 ] && ok || bad "C: the loader must still render when the stamp dir is foreign (fail-open), rc $RCC2"
  [ "$(cat "$T/C.path" 2>/dev/null)" = "$REPOC/catalog/lanes.json" ] \
    && ok || bad "C: the loader must still print the canonical path, got '$(cat "$T/C.path" 2>/dev/null)'"
  [ -s "$REPOC/catalog/lanes.json" ] && ok || bad "C: the loader must still write a non-empty render"
  [ -z "$(ls -A "$CDIR" 2>/dev/null)" ] \
    && ok || bad "C: nothing may be written into another user's directory: $(ls -A "$CDIR" 2>/dev/null)"

  ( export TMPDIR="$T/tmpC"
    . "$REPOC/bin/lib/lanes-registry.sh" || exit 9
    lanes_stamp_write "$REPOC"
  ); RCC3=$?
  [ "$RCC3" != 0 ] \
    && ok || bad "C: lanes_stamp_write must report the refusal, not a silent success (rc $RCC3)"
  [ -z "$(ls -A "$CDIR" 2>/dev/null)" ] \
    && ok || bad "C: lanes_stamp_write wrote into another user's directory: $(ls -A "$CDIR" 2>/dev/null)"
fi

# ============================================================================
# D. NO RENDER EVER LANDS IN THE CALLER'S CWD. When catalog/ cannot be written
#    the loader falls back to a render beside the stamp dir — and the stamp dir
#    is now refusable, so the path it derives that name from can be empty.
#    `dirname ""` is `.`, which would drop render-<key>.json into whatever
#    directory the lane happened to be running from.
#
#    Root ignores mode bits, so there is no way to make catalog/ unwritable for
#    it; this case belongs to the non-root runner (CI).
# ============================================================================
if [ "$UIDN" = 0 ]; then
  echo "lanes-registry-stamp-owner.bh-1304-test: SKIPPED case D — root ignores the chmod that makes catalog/ unwritable"
else
  REPOD=$(mkrepo rD); mkdir -p "$T/tmpD" "$T/elsewhereD" "$T/cwdD"
  ln -s "$T/elsewhereD" "$T/tmpD/harness-lanes-$UIDN"

  # D1. no render anywhere: catalog/ unwritable, stamp dir refused, nothing served
  rm -f "$REPOD/catalog/lanes.json"
  chmod 555 "$REPOD/catalog"
  ( export TMPDIR="$T/tmpD"
    cd "$T/cwdD" || exit 9
    . "$REPOD/bin/lib/lanes-registry.sh" || exit 9
    lanes_json_path "$REPOD" > "$T/D.path" 2> "$T/D.err"
  ); RCD=$?
  [ "$RCD" != 0 ] \
    && ok || bad "D: with no writable catalog, no stamp dir and no previous render the loader must fail, got rc $RCD ('$(cat "$T/D.path" 2>/dev/null)')"
  [ -z "$(ls -A "$T/cwdD" 2>/dev/null)" ] \
    && ok || bad "D: a render leaked into the caller's CWD: $(ls -A "$T/cwdD" 2>/dev/null)"
  [ -z "$(ls -A "$T/elsewhereD" 2>/dev/null)" ] \
    && ok || bad "D: a render leaked through the planted symlink: $(ls -A "$T/elsewhereD" 2>/dev/null)"

  # D2. an existing render is still served (fail-open), and still writes nothing
  chmod 755 "$REPOD/catalog"
  "$REPOD/bin/lanes-build.sh" --root "$REPOD" --write >/dev/null 2>&1 \
    || bad "D: the fixture render could not be composed"
  chmod 555 "$REPOD/catalog"
  ( export TMPDIR="$T/tmpD"
    cd "$T/cwdD" || exit 9
    . "$REPOD/bin/lib/lanes-registry.sh" || exit 9
    P=$(lanes_json_path "$REPOD") || exit 1
    printf '%s' "$P" > "$T/D2.path"
  ); RCD2=$?
  [ "$RCD2" = 0 ] && ok || bad "D: an existing render must still be served (fail-open), rc $RCD2"
  [ "$(cat "$T/D2.path" 2>/dev/null)" = "$REPOD/catalog/lanes.json" ] \
    && ok || bad "D: the last-resort path must be the existing render, got '$(cat "$T/D2.path" 2>/dev/null)'"
  [ -z "$(ls -A "$T/cwdD" 2>/dev/null)" ] \
    && ok || bad "D: a render leaked into the caller's CWD on the last-resort path: $(ls -A "$T/cwdD" 2>/dev/null)"
  [ -z "$(ls -A "$T/elsewhereD" 2>/dev/null)" ] \
    && ok || bad "D: a render leaked through the planted symlink on the last-resort path: $(ls -A "$T/elsewhereD" 2>/dev/null)"
  chmod 755 "$REPOD/catalog"
fi

echo "lanes-registry-stamp-owner.bh-1304-test: $PASS pass, $FAIL fail"
[ "$FAIL" -eq 0 ]
