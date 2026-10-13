#!/bin/bash
# bin/render-doc-index.sh [--check] [notes-dir] [out-file]
#
# Render docs/notes/INDEX.md from the dated notes in docs/notes/.
#
# The five contract docs became changelogs: 5,625 lines of "since 2026-09-1x
# this changed" prose, and on 2026-09-16 nine of seventeen builds were deferred
# on file overlap in exactly those files. The new shape is one note per change,
# named docs/notes/<YYYY-MM-DD>-<KEY>-<slug>.md, plus this index over them.
#
# A note is tagged by one line naming the docs it belongs to:
#
#     Doc: EVENTS, BUILD-CONCURRENCY
#
# First such line outside a code fence (``` or ~~~) wins, names are matched case-insensitively
# against DOC_NOTES_TAGS, and a note with no usable tag lands under `untagged`
# rather than being dropped. The title is the note's first `# ` heading (falling
# back to the filename stem); the date is the filename's YYYY-MM-DD prefix
# (falling back to `unknown`, sorted last in its group).
#
# DETERMINISM IS THE POINT. This reads no clock, no hostname, and prints no
# counts: two runs over the same directory are byte-identical, so a docs pass
# that re-renders it produces an empty diff instead of a new collision on a file
# every build wants to touch.
#
#   bin/render-doc-index.sh                      # docs/notes/ -> docs/notes/INDEX.md
#   bin/render-doc-index.sh path/to/notes out.md # explicit
#   DOC_NOTES_DIR=… DOC_NOTES_INDEX=… bin/render-doc-index.sh
#   DOC_NOTES_TAGS="EVENTS FOO" bin/render-doc-index.sh   # heading order
#   bin/render-doc-index.sh --check              # is INDEX.md what a render writes?
#   bin/render-doc-index.sh --check path/to/notes out.md
#
# rc 0 = rendered (or nothing to render). rc 1 = the write failed, and the
# previous INDEX.md is left exactly as it was.
#
# --check (BH-1162) renders into a temp file and compares it with the index. It
# never writes the index. rc 0 = in sync. rc 1 = stale or missing, with a short
# diff. rc 2 = the check could not run (no notes dir, the render failed).
set -uo pipefail
# Byte-identical means byte-identical on every box: the two sorts below collate
# in the caller's locale otherwise, and `…-a-b.md` / `…-ab.md` swap places
# between C and en_US.UTF-8.
export LC_ALL=C
CHECK=0
if [ "${1:-}" = "--check" ]; then CHECK=1; shift; fi
SELF_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$SELF_DIR/.." && pwd)"

NOTES_DIR="${1:-${DOC_NOTES_DIR:-$ROOT/docs/notes}}"
OUT="${2:-${DOC_NOTES_INDEX:-$NOTES_DIR/INDEX.md}}"
TAGS="${DOC_NOTES_TAGS:-MERGE-CONDUCTOR BUILD-CONCURRENCY RUN-BUILD-GRAPH OPERATOR-SETUP EVENTS}"

if [ ! -d "$NOTES_DIR" ]; then
  if [ "$CHECK" = 1 ]; then
    echo "render-doc-index: no $NOTES_DIR — nothing to check." >&2
    exit 2
  fi
  echo "render-doc-index: no $NOTES_DIR — nothing to render."
  exit 0
fi

# One record per (tag, note): ORDER<TAB>TAG<TAB>DKEY<TAB>FILE<TAB>DATE<TAB>TITLE.
# ORDER is zero-padded so a plain string sort puts the configured docs first in
# their configured order, then unknown tags alphabetically, then untagged.
# DKEY exists because entries sort DESCENDING inside a heading and letters
# collate after digits: sorting the filename alone put `undated-note.md` above
# every dated entry, the opposite of what this file documents. `1<date>` for a
# dated note, `0` for an undated one, so reversed it lands last in its group.
RECORDS=""
while IFS= read -r F; do
  [ -n "$F" ] || continue
  BASE="${F##*/}"
  case "$BASE" in INDEX.md|README.md) continue ;; esac
  case "$BASE" in
    [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]-*) DATE="${BASE:0:10}" ;;
    *) DATE="unknown" ;;
  esac
  case "$DATE" in unknown) DKEY="0" ;; *) DKEY="1$DATE" ;; esac
  REC=$(awk -v base="$BASE" -v date="$DATE" -v dkey="$DKEY" -v tags="$TAGS" '
    BEGIN {
      n = split(tags, TL, /[ ,]+/)
      for (i = 1; i <= n; i++) if (TL[i] != "") { CANON[toupper(TL[i])] = TL[i]; ORD[TL[i]] = i }
      fence = 0; title = ""; doc = ""
    }
    /^[[:space:]]*(```|~~~)/ { fence = 1 - fence; next }
    fence { next }
    title == "" && /^#[[:space:]]/ {
      title = $0; sub(/^#[[:space:]]+/, "", title); sub(/[[:space:]]+$/, "", title)
    }
    doc == "" && tolower($0) ~ /^[[:space:]]*doc:/ { doc = substr($0, index($0, ":") + 1) }
    END {
      if (title == "") { title = base; sub(/\.md$/, "", title) }
      emitted = 0
      n = split(doc, P, ",")
      for (i = 1; i <= n; i++) {
        t = P[i]
        gsub(/^[[:space:]]+/, "", t); gsub(/[[:space:]]+$/, "", t)
        if (t == "") continue
        if (toupper(t) in CANON) t = CANON[toupper(t)]
        if (t in seen) continue
        seen[t] = 1
        order = (t in ORD) ? sprintf("%03d", ORD[t]) : "500"
        printf "%s\t%s\t%s\t%s\t%s\t%s\n", order, t, dkey, base, date, title
        emitted++
      }
      if (emitted == 0) printf "999\tuntagged\t%s\t%s\t%s\t%s\n", dkey, base, date, title
    }
  ' "$F") || { echo "render-doc-index: could not read $F" >&2; exit $((1 + CHECK)); }
  RECORDS="$RECORDS$REC"$'\n'
done <<< "$(find "$NOTES_DIR" -maxdepth 1 -type f -name '*.md' | sort)"

# Write through a temp file in the destination directory: a failed render must
# leave the old index standing rather than half-written.
# --check renders into $TMPDIR instead and never touches the destination.
OUT_DIR="$(dirname "$OUT")"
[ "$CHECK" = 1 ] && OUT_DIR="${TMPDIR:-/tmp}"
TMP=$(mktemp "$OUT_DIR/.render-doc-index.XXXXXX" 2>/dev/null) || {
  echo "render-doc-index: cannot write in $OUT_DIR — $OUT left unchanged." >&2
  exit $((1 + CHECK))
}

{
  echo "# Notes index"
  echo
  echo "Rendered by \`bin/render-doc-index.sh\` from the notes in this directory."
  echo "Do not hand-edit: the next docs pass overwrites it. To record a change, add"
  echo "\`docs/notes/<YYYY-MM-DD>-<KEY>-<slug>.md\` with a \`Doc:\` line naming the docs"
  echo "it belongs to, and re-render."
  if [ -z "${RECORDS//[$'\n']/}" ]; then
    echo
    echo "No notes yet."
  else
    PREV=""
    while IFS=$'\t' read -r _ TAG _ FILE DATE TITLE; do
      [ -n "$TAG" ] || continue
      if [ "$TAG" != "$PREV" ]; then
        echo
        echo "## $TAG"
        echo
        PREV="$TAG"
      fi
      echo "- $DATE — [$TITLE]($FILE)"
    done <<< "$(printf '%s' "$RECORDS" | sort -t$'\t' -k1,1 -k2,2 -k3,3r -k4,4r)"
  fi
} > "$TMP" || {
  rm -f "$TMP"
  echo "render-doc-index: write to $OUT_DIR failed — $OUT left unchanged." >&2
  exit $((1 + CHECK))
}

if [ "$CHECK" = 1 ]; then
  if cmp -s "$TMP" "$OUT"; then
    rm -f "$TMP"
    exit 0
  fi
  echo "render-doc-index: $OUT is stale — run bin/render-doc-index.sh"
  if [ -e "$OUT" ]; then
    diff -u "$OUT" "$TMP" | head -n 40
  else
    echo "render-doc-index: $OUT does not exist"
  fi
  rm -f "$TMP"
  exit 1
fi

chmod 644 "$TMP"
mv "$TMP" "$OUT" || {
  rm -f "$TMP"
  echo "render-doc-index: could not move the rendered index onto $OUT." >&2
  exit 1
}
echo "render-doc-index: wrote $OUT"
exit 0
