#!/bin/bash
# Conflict-aware scheduling (SCALE-PLAN wave 1): may <candidate-build-dir> run
# concurrently with the OTHER running builds of this project?
# Overlap rule: two builds conflict when any planned path of one equals, or is a
# path-prefix of, a planned path of the other (file==file, dir contains file).
# Each side is its touch-files.txt when that build declares its files
# (touch-source=declared, bin/touch-files.sh, BH-5965), else planned-files.txt.
# usage: conflict-check.sh <project> <candidate-build-dir>
#   exit 0 = disjoint (safe to run)   exit 1 = overlap (defer; reason on stdout)
set -uo pipefail
PROJECT="${1:?project}"
CAND="${2:?candidate build dir}"
HARNESS="${HARNESS:-/root/harness}"   # same seam as run-build.sh:11 / plan-overlap.sh:47
tf() { # tf <build-dir> — the file list that build is judged on
  [ "$(cat "$1/touch-source" 2>/dev/null)" = declared ] && [ -s "$1/touch-files.txt" ] && { echo "$1/touch-files.txt"; return; }
  echo "$1/planned-files.txt"
}
CFILES=$(tf "$CAND")
[ -s "$CFILES" ] || exit 0   # no plan data -> cannot judge -> allow (old behavior)

for D in "$HARNESS"/builds/"$PROJECT"-*; do
  [ -d "$D" ] || continue
  [ "$D" = "$CAND" ] && continue
  [ -f "$D/RESULT" ] && continue                      # finished
  OFILES=$(tf "$D")
  [ -s "$OFILES" ] || continue                        # pre-wave-1 build
  # running = dir touched in the last 4h without a RESULT
  [ -n "$(find "$D" -maxdepth 1 -mmin -240 -print -quit 2>/dev/null)" ] || continue
  OVERLAP=$(awk 'NR==FNR{a[$0];next}
    {
      for (p in a) {
        if ($0==p || index($0,p"/")==1 || index(p,$0"/")==1) { print p" ~ "$0; exit }
      }
    }' "$CFILES" "$OFILES")
  if [ -n "$OVERLAP" ]; then
    echo "CONFLICT with $(basename "$D"): $OVERLAP"
    exit 1
  fi
done
exit 0
