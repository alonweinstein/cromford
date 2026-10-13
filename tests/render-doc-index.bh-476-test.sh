#!/bin/bash
# tests/render-doc-index.bh-476-test.sh — the index collates the same way on
# every box.
#
# The renderer's own header promises "two runs over the same directory are
# byte-identical", and the whole point of that promise is that a docs pass on
# one machine re-renders the file a docs pass on another machine wrote without
# producing a diff. Two `sort` calls stood between it and the caller's locale:
# under a C locale `-` (0x2D) sorts before `b`, under en_US.UTF-8 punctuation is
# ignored at the first level, so `…-a-b.md` and `…-ab.md` swap places and the
# index churns on a file nobody edited. the operator's review of #786 called it.
#
# This drives the real bin/render-doc-index.sh and asserts on the RENDERED FILE.
# Every date is a literal in a filename; nothing reads a clock.
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
R="$DIR/bin/render-doc-index.sh"
PASS=0; FAIL=0; SKIP=0
ok()   { PASS=$((PASS+1)); }
bad()  { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
skip() { SKIP=$((SKIP+1)); echo "skipped: $1"; }

if [ ! -x "$R" ]; then
  echo "FAIL: bin/render-doc-index.sh is missing"
  echo "render-doc-index.bh-476-test: 0 pass, 1 fail, 0 skip"
  exit 1
fi

# Three notes, same date, same tag: only the filename orders them. `A`, `a-b`
# and `ab` are the three shapes that disagree between collations — case, and a
# punctuation character against a letter.
N="$T/notes"; mkdir -p "$N"
note() { # note <filename> <title>
  {
    echo "# $2"
    echo
    echo "Doc: EVENTS"
    echo
    echo "Body of $2."
  } > "$N/$1"
}
note 2026-09-10-BH-1-A.md   "A note"
note 2026-09-10-BH-1-a-b.md "a-b note"
note 2026-09-10-BH-1-ab.md  "ab note"

# Render OUTSIDE the notes dir, or the index becomes a note on the next run.
mkdir -p "$T/out"

render() { # render <out-file> [locale]
  if [ -n "${2:-}" ]; then
    LC_ALL="$2" LANG="$2" DOC_NOTES_DIR="$N" DOC_NOTES_INDEX="$1" "$R" >/dev/null 2>&1
  else
    DOC_NOTES_DIR="$N" DOC_NOTES_INDEX="$1" "$R" >/dev/null 2>&1
  fi
}

# Entries sort DESCENDING inside a heading, and in C order `ab` > `a-b` > `A`.
EXPECT='- 2026-09-10 — [ab note](2026-09-10-BH-1-ab.md)
- 2026-09-10 — [a-b note](2026-09-10-BH-1-a-b.md)
- 2026-09-10 — [A note](2026-09-10-BH-1-A.md)'

entries() { # entries <index-file> -> the `- ` lines under ## EVENTS
  sed -n '/^## EVENTS$/,$p' "$1" | grep '^- '
}

# ── 1. the caller's own locale renders the documented order ─────────────────
O1="$T/out/default.md"
render "$O1"
RC=$?
[ "$RC" = 0 ] && ok || bad "1: the render exited $RC, expected 0"
if [ -f "$O1" ]; then
  GOT=$(entries "$O1")
  [ "$GOT" = "$EXPECT" ] && ok || bad "1: wrong entry order under the caller's locale:
$GOT"
else
  bad "1: nothing was rendered"
fi

# ── 2. a second render is byte-identical (the header's own promise) ─────────
O2="$T/out/default-again.md"
render "$O2"
cmp -s "$O1" "$O2" && ok || bad "2: two runs over the same directory differ"

# ── 3. and a run under a non-C locale renders the same bytes ───────────────
# en_US.UTF-8 is the collation that reorders `a-b`/`ab`. Where it is not
# installed this is a SKIP, not a pass: the fix is applied on the reading of
# glibc's collation, and only a box that has the locale can witness it.
LOC=$(locale -a 2>/dev/null | grep -iE '^en_US\.(UTF-8|utf8)$' | head -1)
if [ -n "$LOC" ]; then
  O3="$T/out/en-us.md"
  render "$O3" "$LOC"
  RC=$?
  [ "$RC" = 0 ] && ok || bad "3: the $LOC render exited $RC, expected 0"
  if [ -f "$O3" ]; then
    GOT=$(entries "$O3")
    [ "$GOT" = "$EXPECT" ] && ok || bad "3: wrong entry order under $LOC:
$GOT"
    cmp -s "$O1" "$O3" && ok || bad "3: the $LOC render differs from the default-locale one"
  else
    bad "3: nothing was rendered under $LOC"
  fi
else
  skip "en_US.UTF-8 is not installed on this box — the cross-locale render is unproven here"
fi

echo "render-doc-index.bh-476-test: $PASS pass, $FAIL fail, $SKIP skip"
[ "$FAIL" = 0 ]
