# tests/lib/rb-all.sh — the pipeline as ONE text, whatever state the split is in.
# Sourced by the suites that READ bin/run-build.sh, never executed. Not a suite:
# tests/*.sh does not glob tests/lib/.
#
# WHY FLATTEN AND NOT CONCATENATE (BH-478). The driver is being split into stage
# modules under bin/lib/rb/, one part at a time. Fifty-odd suites read the
# driver as a single file — some extract a block by its markers, some compare
# line numbers between two blocks, some count strings across the whole text. If
# they read the driver plus a pile of modules, the answer would depend on the
# order the parts of the split happened to merge. Flattening puts every moved
# body back exactly where its call site is, so the text these suites read is the
# pipeline in its ORIGINAL order at every state of the split: none moved, some
# moved, all moved. No merge order among the later parts can turn a suite red.
#
# The module list is read off the driver's own RB_MODULES= line, so the driver
# stays the single source of truth for which files hold stage bodies.
#
# The grammar, from the seam contract: a stage entry is `rb_<name>() {` at
# column 0 in one of the modules, closed by `} # end rb_<name>` at column 0, and
# the driver calls it as a line that is exactly `rb_<name>`. Anything else — a
# call with arguments, an indented call, a comment, an assignment — is not a
# call site and copies through untouched. A bare call no module defines copies
# through too: the flatten never invents text it cannot find.
#
# A module that OPENS a stage function and never closes it is an error, not a
# body that runs to EOF. Copying the rest of the module in would hand every
# reader suite a pipeline text nobody wrote, and the suites would report their
# own findings about it; so the flatten says which module and which function on
# stderr, removes the half-written output, and returns non-zero.
#
# No trap, no clock, no mktemp: the caller passes the output path out of its own
# scratch tree and owns its lifetime.
# shellcheck shell=bash

rb_all() { # rb_all <repo-dir> <out-file>  -> prints <out-file>; the pipeline as ONE text
  local repo="$1" out="$2" drv="$1/bin/run-build.sh" RB_MODULES="" line name mod hit
  eval "$(grep -m1 '^RB_MODULES=' "$drv")"
  : > "$out"
  while IFS= read -r line || [ -n "$line" ]; do
    if [[ "$line" =~ ^rb_[a-z_]+$ ]]; then
      name=$line; hit=""
      for mod in $RB_MODULES; do
        [ -r "$repo/bin/lib/rb/$mod.sh" ] || continue
        grep -q "^${name}() {\$" "$repo/bin/lib/rb/$mod.sh" || continue
        if ! awk -v n="$name" '
              $0==n"() {"      { f=1; opened=1; next }
              $0=="} # end "n  { closed=1; exit }
              f
              END              { if (opened && !closed) exit 3 }' \
              "$repo/bin/lib/rb/$mod.sh" >> "$out"; then
          echo "rb_all: bin/lib/rb/$mod.sh opens $name but never closes it" >&2
          rm -f "$out"
          return 1
        fi
        hit=1; break
      done
      [ -n "$hit" ] || printf '%s\n' "$line" >> "$out"
    else
      printf '%s\n' "$line" >> "$out"
    fi
  done < "$drv"
  printf '%s\n' "$out"
}
