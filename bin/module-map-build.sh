#!/bin/bash
# bin/module-map-build.sh [--root <dir>] [--write|--check] [<dir>...]
#
# Generate and check <dir>/MODULES, the load order bin/lib/module-map.sh's
# mm_load reads. The order comes from each module's own header line,
# `# module: <name> after: <deps>` (the grammar is in bin/lib/module-map.sh).
# A new module is one new file plus `bin/module-map-build.sh --write`: no
# existing file, and no hand-written list, changes. docs/MODULE-MAP.md.
#
# <dir> is a path under --root (bin/lib/mc). With no <dir>, every directory
# under <root>/bin/lib/ that holds a MODULES file or a .sh file with a
# "# module:" line in its first 30 lines.
#
# VALIDATION runs before any write and in --check; each failure prints one
# line on stderr:
#   * every mm_order error (malformed header, name not the basename, unknown
#     dep, cycle, zero modules)
#   * a function defined in two modules of the same dir:
#     `module-map: <dir>: <fn> is defined in <dir>/a.sh and <dir>/b.sh`
#   * a top-level `declare`, `typeset` or `local` with no -g in a module:
#     mm_load sources at function scope, so that variable would be lost
# BOTH SCANS ARE STATIC: sourcing a module in CI needs that module's env. A
# definition is a line matching `^[[:space:]]*(function[[:space:]]+)?<ident>
# [[:space:]]*\(\)`; `function f {` with no parens is not seen. "Top level" is
# column 0: a declare indented under an `if` at the top level is not seen.
# Lines inside a heredoc (`<<WORD`, `<<-'WORD'`, `<<"WORD"` up to WORD) are
# skipped by both scans; a heredoc that never closes is a finding, so a
# false `<<` match is loud instead of hiding the rest of the file.
#
#   --write         rewrite <dir>/MODULES (atomically, only when the bytes
#                   differ); writes nothing when validation fails
#   --check         validate, then compare with the committed <dir>/MODULES;
#                   rc 1 when it is missing or different. Prints
#                   `module-map: <n> dir(s) ok (<dirs>)` only when every dir passed.
#   (none)          print the order of one dir
#   --root <dir>    the repo root (default: this script's repo)
#
# Exit: 0 OK, 1 a check or validation failure, 2 a usage error.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
MODE="print"
DIRS=()
while [ $# -gt 0 ]; do
  case "$1" in
    --root)    [ $# -ge 2 ] || { echo "module-map-build.sh: --root needs a directory" >&2; exit 2; }; ROOT="$2"; shift 2 ;;
    --write)   MODE="write"; shift ;;
    --check)   MODE="check"; shift ;;
    -h|--help) awk 'NR > 1 { if ($0 !~ /^#/) exit; print }' "$0"; exit 0 ;;
    -*)        echo "module-map-build.sh: unexpected argument $1" >&2; exit 2 ;;
    *)         DIRS+=("$1"); shift ;;
  esac
done

# shellcheck source=bin/lib/module-map.sh
. "$HERE/lib/module-map.sh" || exit 2

ROOT=$(cd "$ROOT" 2>/dev/null && pwd) || { echo "module-map-build.sh: --root is not a directory" >&2; exit 2; }
cd "$ROOT"
export LC_ALL=C

if [ "${#DIRS[@]}" = 0 ]; then
  if [ -d bin/lib ]; then
    while IFS= read -r d; do
      if [ -f "$d/MODULES" ] || awk 'FNR <= 30 && /^# module:/ { found = 1; exit } END { exit !found }' "$d"/*.sh 2>/dev/null; then
        DIRS+=("$d")
      fi
    done < <(find bin/lib -mindepth 1 -type d | sort)
  fi
else
  for i in "${!DIRS[@]}"; do
    d=${DIRS[$i]%/}; d=${d#"$ROOT"/}
    [ -d "$d" ] || { echo "module-map-build.sh: no directory $d under $ROOT" >&2; exit 2; }
    DIRS[$i]=$d
  done
fi

if [ "$MODE" = print ] && [ "${#DIRS[@]}" != 1 ]; then
  echo "module-map-build.sh: printing wants exactly one dir, found ${#DIRS[@]} (${DIRS[*]:-none})" >&2; exit 2
fi

TMP=$(mktemp -d "${TMPDIR:-/tmp}/module-map-build.XXXXXX")
trap 'rm -rf "$TMP"' EXIT

# scan <dir> — the static scans over every .sh with a "# module:" line.
# rc 0 clean, 1 a finding (each printed).
scan() {
  local dir="$1" f
  local -a mods=()
  for f in "$dir"/*.sh; do
    [ -f "$f" ] || continue
    awk 'FNR <= 30 && /^# module:/ { found = 1; exit } END { exit !found }' "$f" && mods+=("$f")
  done
  [ "${#mods[@]}" -gt 0 ] || return 0
  awk -v dir="$dir" '
    function unclosed() {
      printf "module-map: %s: %s:%d: heredoc <<%s never closes (a static scan would skip the rest of the file)\n", dir, prev, hdline, hd > "/dev/stderr"; bad = 1
    }
    FNR == 1 { if (hd != "") unclosed(); hd = ""; strip = 0; prev = FILENAME }
    hd != "" {
      line = $0; sub(/\r$/, "", line)
      if (strip) sub(/^\t+/, "", line)
      if (line == hd) hd = ""
      next
    }
    {
      if (match($0, /^[[:space:]]*(function[[:space:]]+)?[A-Za-z_][A-Za-z0-9_:.-]*[[:space:]]*\(\)/)) {
        fn = substr($0, RSTART, RLENGTH)
        sub(/^[[:space:]]*/, "", fn); sub(/^function[[:space:]]+/, "", fn); sub(/[[:space:]]*\(\)$/, "", fn)
        if ((fn in where) && where[fn] != FILENAME) {
          printf "module-map: %s: %s is defined in %s and %s\n", dir, fn, where[fn], FILENAME > "/dev/stderr"; bad = 1
        } else if (!(fn in where)) where[fn] = FILENAME
      }
      if (match($0, /^(declare|typeset|local)([[:space:]]|$)/)) {
        rest = $0; sub(/^(declare|typeset|local)/, "", rest); g = 0
        while (match(rest, /^[[:space:]]+-[A-Za-z]+/)) {
          if (substr(rest, RSTART, RLENGTH) ~ /g/) g = 1
          rest = substr(rest, RSTART + RLENGTH)
        }
        if (!g || $0 ~ /^local/) {
          printf "module-map: %s: %s:%d: top-level \"%s\" with no -g: mm_load sources at function scope, so it would be lost\n", dir, FILENAME, FNR, $0 > "/dev/stderr"; bad = 1
        }
      }
      line = $0; gsub(/<<</, "", line)
      if (match(line, /<<-?[[:space:]]*["\047]?[A-Za-z_][A-Za-z0-9_]*["\047]?/)) {
        w = substr(line, RSTART, RLENGTH)
        strip = (w ~ /^<<-/)
        sub(/^<<-?[[:space:]]*/, "", w); gsub(/["\047]/, "", w)
        hd = w; hdline = FNR
      }
    }
    END { if (hd != "") unclosed(); exit bad }
  ' "${mods[@]}"
}

# render <dir> <out> — validate <dir> and write its MODULES content to <out>.
# rc 0 valid, 1 invalid (every reason printed).
render() {
  local dir="$1" out="$2" bad=0 order
  order=$(mm_order "$dir") || bad=1
  scan "$dir" || bad=1
  [ "$bad" = 0 ] || return 1
  {
    echo "# $dir/MODULES — generated by bin/module-map-build.sh from each module's \"# module:\" header. Never hand-edit; run bin/module-map-build.sh --write."
    printf '%s\n' "$order"
  } > "$out"
}

rc=0
n=0
for d in "${DIRS[@]}"; do
  n=$((n + 1))
  out="$TMP/$n"
  if ! render "$d" "$out"; then
    rc=1; continue
  fi
  case "$MODE" in
    print)
      grep -v '^#' "$out" ;;
    check)
      if [ ! -f "$d/MODULES" ] || ! cmp -s "$out" "$d/MODULES"; then
        echo "$d/MODULES: stale — run bin/module-map-build.sh --write" >&2; rc=1
      fi ;;
    write)
      if [ ! -f "$d/MODULES" ] || ! cmp -s "$out" "$d/MODULES"; then
        cp "$out" "$d/.MODULES.tmp.$$" && mv -f "$d/.MODULES.tmp.$$" "$d/MODULES"
        echo "module-map: wrote $d/MODULES"
      fi ;;
  esac
done
if [ "$MODE" = check ] && [ "$rc" = 0 ]; then
  echo "module-map: ${#DIRS[@]} dir(s) ok (${DIRS[*]})"
fi
exit "$rc"
