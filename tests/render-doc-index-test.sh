#!/bin/bash
# tests/render-doc-index-test.sh — bin/render-doc-index.sh builds docs/notes/INDEX.md.
#
# The index is the only thing that makes a pile of dated notes readable, so what
# it is worth is the RENDERED FILE: heading order, entry order, and the notes it
# refuses to drop. Every case below drives the real script against a scratch
# notes dir through DOC_NOTES_DIR/DOC_NOTES_INDEX and asserts on the file it
# wrote — never on the script's source.
#
# The negatives carry the weight here. An untagged note must land under
# `untagged` rather than vanish, a `Doc:` line inside a fenced code block must
# not tag anything, and two runs over the same directory must be byte-identical:
# an index that churns is the file-collision problem this whole change removes,
# reappearing one level down.
#
# Every date in this suite is a literal in a filename. Nothing reads a clock.
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
R="$DIR/bin/render-doc-index.sh"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

if [ ! -x "$R" ]; then
  echo "FAIL: bin/render-doc-index.sh is missing"
  echo "render-doc-index-test: 0 pass, 1 fail"
  exit 1
fi

# note <dir> <filename> <title> <doc-line-value-or-empty>
note() {
  local d="$1" f="$2" t="$3" doc="$4"
  mkdir -p "$d"
  {
    echo "# $t"
    echo
    [ -n "$doc" ] && echo "Doc: $doc"
    echo
    echo "Body of $t."
  } > "$d/$f"
}

# lineno <file> <fixed-string> -> line number, or empty when absent
lineno() { grep -nF -m1 -e "$2" "$1" 2>/dev/null | cut -d: -f1; }

# before <file> <earlier> <later> -> rc 0 when both are present and in that order
before() {
  local a b
  a=$(lineno "$1" "$2"); b=$(lineno "$1" "$3")
  [ -n "$a" ] && [ -n "$b" ] && [ "$a" -lt "$b" ]
}

# ── 1. three notes, two doc tags: grouped, configured order, newest first ────
N1="$T/n1"; O1="$T/out1/INDEX.md"; mkdir -p "$T/out1"
note "$N1" 2026-09-10-BH-1-a.md "Note A" "EVENTS"
note "$N1" 2026-09-12-BH-2-b.md "Note B" "MERGE-CONDUCTOR"
note "$N1" 2026-09-14-BH-3-c.md "Note C" "EVENTS"
DOC_NOTES_DIR="$N1" DOC_NOTES_INDEX="$O1" "$R" >/dev/null 2>&1
RC=$?
[ "$RC" = 0 ] && ok || bad "1: render exited $RC on three notes"
[ -f "$O1" ] && ok || bad "1: no INDEX.md written"
before "$O1" '## MERGE-CONDUCTOR' '## EVENTS' && ok \
  || bad "1: headings are not in the configured order (MERGE-CONDUCTOR before EVENTS)"
before "$O1" '2026-09-14-BH-3-c.md' '2026-09-10-BH-1-a.md' && ok \
  || bad "1: entries under EVENTS are not newest-first"
grep -qxF -- '- 2026-09-14 — [Note C](2026-09-14-BH-3-c.md)' "$O1" && ok \
  || bad "1: the entry line for Note C is not the documented shape"
before "$O1" '2026-09-12-BH-2-b.md' '## EVENTS' && ok \
  || bad "1: the MERGE-CONDUCTOR note is not under its own heading"
# a MERGE-CONDUCTOR-only note must not be repeated under EVENTS
[ "$(grep -cF '2026-09-12-BH-2-b.md' "$O1")" = 1 ] && ok \
  || bad "1: the MERGE-CONDUCTOR note is listed more than once"

# ── 2. an untagged note lands under `untagged`, which is LAST ────────────────
N2="$T/n2"; O2="$T/out2/INDEX.md"; mkdir -p "$T/out2"
mkdir -p "$N2"; cp "$N1"/*.md "$N2/"
note "$N2" 2026-09-13-BH-4-d.md "Note D" ""
note "$N2" 2026-09-11-BH-5-e.md "Note E" "zz-custom"
DOC_NOTES_DIR="$N2" DOC_NOTES_INDEX="$O2" "$R" >/dev/null 2>&1
grep -qF '2026-09-13-BH-4-d.md' "$O2" && ok || bad "2: the untagged note was dropped"
before "$O2" '## untagged' '2026-09-13-BH-4-d.md' && ok \
  || bad "2: the untagged note is not under '## untagged'"
[ "$(grep -F '## ' "$O2" | tail -1)" = '## untagged' ] && ok \
  || bad "2: '## untagged' is not the last heading"
before "$O2" '## zz-custom' '## untagged' && ok \
  || bad "2: an unknown tag does not sort before untagged"

# ── 3. a `Doc:` line inside a fence tags nothing ─────────────────────────────
N3="$T/n3"; O3="$T/out3/INDEX.md"; mkdir -p "$N3" "$T/out3"
{
  echo "# Note F"
  echo
  echo '```'
  echo "Doc: MERGE-CONDUCTOR"
  echo '```'
  echo
  echo "Doc: EVENTS"
  echo
  echo "Body of Note F."
} > "$N3/2026-09-15-BH-6-f.md"
DOC_NOTES_DIR="$N3" DOC_NOTES_INDEX="$O3" "$R" >/dev/null 2>&1
grep -qF '## EVENTS' "$O3" && ok || bad "3: the real Doc: line did not tag the note"
grep -qF '## MERGE-CONDUCTOR' "$O3" && bad "3: a fenced Doc: line tagged the note" || ok

# 3b. a tilde fence is a fence too — markdown allows either, and a note showing
# a Doc: line as an EXAMPLE is exactly the note that fences it.
N3B="$T/n3b"; O3B="$T/out3b/INDEX.md"; mkdir -p "$N3B" "$T/out3b"
{
  echo "# Note F2"
  echo
  echo '~~~'
  echo "Doc: MERGE-CONDUCTOR"
  echo '~~~'
  echo
  echo "Doc: EVENTS"
} > "$N3B/2026-09-15-BH-6-f2.md"
DOC_NOTES_DIR="$N3B" DOC_NOTES_INDEX="$O3B" "$R" >/dev/null 2>&1
grep -qF '## EVENTS' "$O3B" && ok || bad "3b: the real Doc: line did not tag the note"
grep -qF '## MERGE-CONDUCTOR' "$O3B" && bad "3b: a tilde-fenced Doc: line tagged the note" || ok

# ── 4. an empty notes dir renders an honest empty index ─────────────────────
N4="$T/n4"; O4="$T/out4/INDEX.md"; mkdir -p "$N4" "$T/out4"
DOC_NOTES_DIR="$N4" DOC_NOTES_INDEX="$O4" "$R" >/dev/null 2>&1
RC=$?
[ "$RC" = 0 ] && ok || bad "4: an empty notes dir exited $RC"
grep -qF 'No notes yet.' "$O4" && ok || bad "4: the empty index does not say so"

# ── 5. a missing notes dir writes nothing and says so ───────────────────────
O5="$T/out5/INDEX.md"; mkdir -p "$T/out5"
OUT=$(DOC_NOTES_DIR="$T/does-not-exist" DOC_NOTES_INDEX="$O5" "$R" 2>&1)
RC=$?
[ "$RC" = 0 ] && ok || bad "5: a missing notes dir exited $RC"
[ ! -e "$O5" ] && ok || bad "5: a missing notes dir still wrote an index"
grep -qF 'nothing to render' <<<"$OUT" && ok || bad "5: no 'nothing to render' message"

# ── 6. two renders of the same dir are byte-identical ───────────────────────
A="$T/out6-a.md"; B="$T/out6-b.md"
DOC_NOTES_DIR="$N1" DOC_NOTES_INDEX="$A" "$R" >/dev/null 2>&1
DOC_NOTES_DIR="$N1" DOC_NOTES_INDEX="$B" "$R" >/dev/null 2>&1
cmp -s "$A" "$B" && ok || bad "6: two renders of the same notes dir differ"

# ── 7. a note tagged to two docs appears under both, once each ──────────────
N7="$T/n7"; O7="$T/out7/INDEX.md"; mkdir -p "$T/out7"
note "$N7" 2026-09-16-BH-7-g.md "Note G" "EVENTS, OPERATOR-SETUP"
DOC_NOTES_DIR="$N7" DOC_NOTES_INDEX="$O7" "$R" >/dev/null 2>&1
[ "$(grep -cF '2026-09-16-BH-7-g.md' "$O7")" = 2 ] && ok \
  || bad "7: a two-tag note is not listed once under each heading"
before "$O7" '## OPERATOR-SETUP' '## EVENTS' && ok \
  || bad "7: two-tag note headings are not in configured order"

# ── 7b. an undated note renders `unknown` and sorts LAST in its group ────────
# Entries go newest-first, and letters collate after digits, so a plain reverse
# sort on the filename put an undated note at the TOP — the opposite of what the
# script documents.
N7B="$T/n7b"; O7B="$T/out7b/INDEX.md"; mkdir -p "$T/out7b"
note "$N7B" 2026-09-10-BH-8-h.md "Note H" "EVENTS"
note "$N7B" 2026-09-14-BH-9-i.md "Note I" "EVENTS"
note "$N7B" undated-note.md "Note U" "EVENTS"
DOC_NOTES_DIR="$N7B" DOC_NOTES_INDEX="$O7B" "$R" >/dev/null 2>&1
grep -qxF -- '- unknown — [Note U](undated-note.md)' "$O7B" && ok \
  || bad "7b: the undated note is missing or not rendered with date 'unknown'"
before "$O7B" '2026-09-14-BH-9-i.md' '2026-09-10-BH-8-h.md' && ok \
  || bad "7b: the dated entries are not newest-first"
before "$O7B" '2026-09-10-BH-8-h.md' 'undated-note.md' && ok \
  || bad "7b: the undated note does not sort last in its group"

# ── 8. a failed write leaves the previous index alone ───────────────────────
# 8a runs everywhere: a destination directory that does not exist is the same
# failure branch, and root cannot ignore it the way it ignores mode 0555.
OUT=$(DOC_NOTES_DIR="$N1" DOC_NOTES_INDEX="$T/no-such-dir/INDEX.md" "$R" 2>&1)
RC=$?
[ "$RC" = 1 ] && ok || bad "8a: a missing out dir exited $RC, expected 1"
[ ! -e "$T/no-such-dir/INDEX.md" ] && ok || bad "8a: it wrote an index anyway"
grep -qF 'left unchanged' <<<"$OUT" && ok || bad "8a: the failure message is not honest about the write"

if [ "$(id -u)" -eq 0 ]; then
  echo "  (running as root — the unwritable-dir case is skipped; root ignores 0555)"
else
  RO="$T/out8"; mkdir -p "$RO"
  printf 'PREVIOUS INDEX\n' > "$RO/INDEX.md"
  chmod 555 "$RO"
  DOC_NOTES_DIR="$N1" DOC_NOTES_INDEX="$RO/INDEX.md" "$R" >/dev/null 2>&1
  RC=$?
  chmod 755 "$RO"
  [ "$RC" = 1 ] && ok || bad "8: an unwritable out dir exited $RC, expected 1"
  [ "$(cat "$RO/INDEX.md")" = "PREVIOUS INDEX" ] && ok \
    || bad "8: a failed render clobbered the existing index"
fi

echo "render-doc-index-test: $PASS pass, $FAIL fail"
[ "$FAIL" = 0 ]
