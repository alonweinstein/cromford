#!/bin/bash
# tests/mc/driver-complete-test.sh — the COMPLETENESS half of BH-477's last
# slice (BH-685): the driver, bin/merge-conductor.sh, is thinned to dispatch and
# the tick loop, and every helper it used to define answers from the module
# tests/mc/expected-map.d/ (the union of its fragments) assigns it.
#
# tests/mc/lib-complete-test.sh asserts the same thing for the 256 functions the
# lib shed (origin=lib rows). This file is its twin for the helpers that came
# out of the DRIVER (origin=driver rows), plus the negative half the move is
# judged by: the five names the ticket keeps in the driver must still be defined
# BY the driver, and must own no map row at all.
#
# WHAT IT PINS, AND WHY
#   1. map hygiene. One origin=driver row per moved helper, and not one row for
#      flag_on / use_token / reset_token / pr_worker / tick_project. A row for a
#      kept name is how a later slice would "tidily" move the helper that pages
#      under the conductor's own dedupe flag out of the lane that owns it.
#   2. every origin=driver row is DEFINED, after sourcing the lib shim, by the
#      module the row names. `shopt -s extdebug` + `declare -F` is the runtime
#      answer to "who defines this" — a grep cannot tell a definition from a
#      mention in a comment, nor which of two definitions won. lost/moved are
#      reported separately so a drop reads differently from a misplacement.
#   3. the driver still defines the five kept names, and none of the moved ones.
#      This half must read the driver's SOURCE (the driver is a lane entry point
#      with a fleet loop at the bottom; sourcing it runs a tick), so it is
#      guarded: an empty or unreadable driver fails here rather than passing
#      vacuously on zero matches.
#
# The shim is sourced from a FIXTURE-SHAPED scratch copy under $T, the same
# shape the other two suites use, so the source loop's BASH_SOURCE resolution is
# what is under test rather than $HARNESS. No clock, no network, no gh, no git.
#
# Run from anywhere: tests/mc/driver-complete-test.sh   (exit 0 = all pass)
set -uo pipefail
# shellcheck source=tests/lib/scratch.sh
. "$(dirname "$0")/../lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/../.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

LIB="$DIR/bin/lib/merge-conductor-lib.sh"
MCD="$DIR/bin/lib/mc"
# The union of tests/mc/expected-map.d/*.tsv (Lane E fragments).
# shellcheck source=tests/lib/mc-expected-map.sh
. "$(dirname "$0")/../lib/mc-expected-map.sh" || exit 1
MAP="$T/expected-map.tsv"
mc_expected_map "$DIR/tests/mc/expected-map.d" "$MAP" 2>"$T/map.err" && ok \
  || bad "1: tests/mc/expected-map.d must assemble: $(head -3 "$T/map.err" | tr '\n' ' ')"
DRV="$DIR/bin/merge-conductor.sh"
KEPT="flag_on use_token reset_token pr_worker tick_project"

# ── 1. map hygiene ──────────────────────────────────────────────────────────
ROWS=$(awk -F'\t' '$3=="driver"{n++} END{print n+0}' "$MAP")
[ "$ROWS" -eq 60 ] && ok \
  || bad "1: $MAP must carry 60 origin=driver rows, got $ROWS"
DUPS=$(awk -F'\t' '$3=="driver"{print $2}' "$MAP" | sort | uniq -d | tr '\n' ' ')
[ -z "$DUPS" ] && ok || bad "1: origin=driver row listed twice: $DUPS"
MODBAD=$(awk -F'\t' '$3=="driver" && $1!="locks" && $1!="classify" && $1!="queue" \
                     && $1!="rebase" && $1!="settle" && $1!="log"{print $1}' "$MAP" \
         | sort -u | tr '\n' ' ')
[ -z "$MODBAD" ] && ok || bad "1: origin=driver row names a module that is not in the split: $MODBAD"
for n in $KEPT; do
  if awk -F'\t' -v n="$n" '$2==n{f=1} END{exit !f}' "$MAP"; then
    bad "1: $n stays in bin/merge-conductor.sh and must own no row in the map"
  else ok; fi
done

# ── the driver: who defines each name, read at runtime ──────────────────────
cat > "$T/who.sh" <<'WHO'
#!/bin/bash
set -uo pipefail
shopt -s extdebug
# shellcheck source=/dev/null
. "$1" || exit 3
command -v mc_classify >/dev/null || exit 3
while IFS= read -r n; do
  [ -n "$n" ] || continue
  d=$(declare -F "$n" 2>/dev/null) || { printf '%s\t-\n' "$n"; continue; }
  f=${d##* }
  printf '%s\t%s\n' "$n" "$(basename "$f" .sh)"
done
WHO

mkdir -p "$T/h/bin/lib/mc" "$T/h/logs" "$T/h/state"
cp "$LIB" "$T/h/bin/lib/" || bad "could not copy the shim into the scratch tree"
cp "$MCD"/*.sh "$T/h/bin/lib/mc/" || bad "could not copy the modules into the scratch tree"

awk -F'\t' '$3=="driver"{print $2}' "$MAP" | sort > "$T/names.txt"
HARNESS="$T/h" bash "$T/who.sh" "$T/h/bin/lib/merge-conductor-lib.sh" < "$T/names.txt" \
  > "$T/who.out" 2>"$T/who.err"
WRC=$?
[ "$WRC" -eq 0 ] && ok \
  || bad "the shim must source in a fixture-shaped copy (rc=$WRC): $(tail -2 "$T/who.err" | tr '\n' ' ')"

# ── 2. every origin=driver row is defined, by the module the map names ──────
MISSING=0; WRONG=0
while IFS=$'\t' read -r want name; do
  [ -n "$name" ] || continue
  got=$(awk -F'\t' -v n="$name" '$1==n{print $2}' "$T/who.out")
  if [ "$got" = "-" ] || [ -z "$got" ]; then
    MISSING=$((MISSING+1))
    echo "  lost: $name is in the map under mc/$want.sh and nothing defines it"
  elif [ "$got" != "$want" ]; then
    WRONG=$((WRONG+1))
    echo "  moved: $name is defined by mc/$got.sh; the map says mc/$want.sh"
  fi
done < <(awk -F'\t' '$3=="driver"{print $1"\t"$2}' "$MAP")
[ "$MISSING" -eq 0 ] && ok \
  || bad "2: $MISSING moved helper(s) are not defined at all — the move dropped them"
[ "$WRONG" -eq 0 ] && ok \
  || bad "2: $WRONG moved helper(s) are defined by a module the map does not name"

# ── 3. the driver defines the five kept names and none of the moved ones ───
# Guarded first: a driver that vanished or stopped defining functions would
# otherwise satisfy "defines none of the moved ones" on zero matches.
DEFS="$T/driver-defs.txt"
grep -nE '^[a-zA-Z_][a-zA-Z0-9_]*\(\)' "$DRV" 2>/dev/null \
  | sed -E 's/^[0-9]+:([a-zA-Z_][a-zA-Z0-9_]*)\(\).*/\1/' | sort -u > "$DEFS"
NDEF=$(grep -c . "$DEFS" || true)
if [ -s "$DRV" ] && [ "$NDEF" -ge 5 ]; then ok
else bad "3: $DRV must exist and define its kept helpers (found $NDEF definitions)"; fi
for n in $KEPT; do
  grep -qxF "$n" "$DEFS" && ok || bad "3: bin/merge-conductor.sh must still define $n"
done
STILL=0
while read -r n; do
  [ -n "$n" ] || continue
  if grep -qxF "$n" "$DEFS"; then
    STILL=$((STILL+1))
    echo "  still in the driver: $n is mapped to a module and bin/merge-conductor.sh defines it"
  fi
done < "$T/names.txt"
[ "$STILL" -eq 0 ] && ok \
  || bad "3: $STILL mapped helper(s) are still defined by bin/merge-conductor.sh"
EXTRA=$(comm -23 "$DEFS" <(printf '%s\n' $KEPT | sort) | tr '\n' ' ')
[ -z "$EXTRA" ] && ok \
  || bad "3: bin/merge-conductor.sh defines helpers outside its kept five: $EXTRA"

echo "mc/driver-complete-test: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
