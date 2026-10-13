#!/bin/bash
# tests/lib/mc-expected-map.sh — assemble the conductor's function ownership map
# from its fragments (Lane E, 2026-09-24). Sourced, never run.
#
#   mc_expected_map <fragment-dir> <out-file>
#
# The map used to be ONE file, tests/mc/expected-map.tsv, and every PR that
# added a conductor function appended to it and to its one-line header comment,
# so any two such PRs conflicted. It is now tests/mc/expected-map.d/*.tsv: the
# base rows in 00-lib.tsv / 00-driver.tsv, and one fragment per later change,
# named for its ticket (BH-1234.tsv). Rows are a set — no reader depends on
# their order — so the union is simply every fragment, in C-locale name order.
#
# A row is `module<TAB>function<TAB>origin`; `#` lines and blank lines are
# comments. The assembler refuses (rc 1, one stderr line per finding naming
# file:line) a row that is not three fields, a module outside the six, an origin
# other than lib|driver, and a function claimed by two rows anywhere in the
# directory, and any symlinked *.tsv (rc 1). rc 2 = nothing to assemble (no directory, or no *.tsv in it). On
# any refusal <out-file> is still written with what was read, so a caller that
# carries on reports its own findings rather than a missing file.
mc_expected_map() {
  local d="${1:?mc_expected_map: fragment dir}" out="${2:?mc_expected_map: out file}"
  local -a frags=()
  local f
  : > "$out" || return 2
  if [ -d "$d" ]; then
    while IFS= read -r f; do [ -n "$f" ] && frags+=("$f"); done \
      < <(find "$d" -maxdepth 1 -type f -name '*.tsv' | LC_ALL=C sort)
  fi
  # A symlinked fragment is refused, not skipped: `-type f` above would drop it
  # without a word, and a row nobody reads is a row nobody checks.
  local links
  links=$(find "$d" -maxdepth 1 -type l -name '*.tsv' 2>/dev/null | LC_ALL=C sort | sed 's#.*/##' | tr '\n' ' ')
  if [ -n "$links" ]; then
    echo "mc_expected_map: symlinked fragment(s) refused — commit the rows as a regular file: $links" >&2
    return 1
  fi
  if [ "${#frags[@]}" -eq 0 ]; then
    echo "mc_expected_map: $d holds no *.tsv fragment" >&2
    return 2
  fi
  # The union is written BY the validator, one record per line, so a fragment
  # with no final newline cannot glue its last row to the next file's first.
  awk -F'\t' -v out="$out" '
    FNR == 1 { base = FILENAME; sub(/.*\//, "", base) }
    { print > out }
    /^[[:space:]]*(#|$)/ { next }
    {
      where = base ":" FNR
      if (NF != 3) { print "mc_expected_map: " where ": not module<TAB>function<TAB>origin: " $0 > "/dev/stderr"; bad++; next }
      if ($1 !~ /^(log|locks|classify|queue|rebase|settle)$/) { print "mc_expected_map: " where ": module \"" $1 "\" is not one of log locks classify queue rebase settle" > "/dev/stderr"; bad++ }
      if ($3 !~ /^(lib|driver)$/) { print "mc_expected_map: " where ": origin \"" $3 "\" is not lib or driver" > "/dev/stderr"; bad++ }
      if ($2 in seen) { print "mc_expected_map: " where ": " $2 " is already assigned at " seen[$2] > "/dev/stderr"; bad++ }
      else seen[$2] = where
    }
    END { exit bad ? 1 : 0 }
  ' "${frags[@]}"
}
